# LLM Setup

LLM Setup pilote un `llama-server` en router mode natif sur une machine Strix Halo
(bigchuck : Ryzen AI Max+ 395, 124 Go unifiés, CachyOS/Arch), avec un seul point
d'entrée, `./setup-llm.sh`, et un moteur : le fork
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp),
construit localement (depuis le 12/09/2026, le paquet Arch `llama-cpp` ne sert
plus que de secours).

Ce qu'il gère :

- téléchargement des GGUF depuis Hugging Face (`hf`, mises à jour par etags) ;
- génération de `~/models/models.ini` : les réglages de chaque modèle vivent
  dans `lib/models.sh` avec leurs justifications en commentaire ;
- préchargement always-on ou chargement à la demande (LRU) ;
- mesure des perfs par l'API du serveur (`--bench`, `--bench-devices`) et
  réglage de la spéculation par mesure : drafter (`spec-draft-n-max`,
  calibration α) et n-gram (`spec-ngram-map-k-size-m`) ;
- installation et suivi du moteur, service systemd user.

Les backends ggml (Vulkan par défaut, ROCm/HIP optionnel) sont des paquets
Arch séparés. Tout est piloté par des fichiers de conf locaux à côté du script
(non versionnés, propres à la machine). Le `models.ini` est généré, jamais édité.

Historique et campagnes de mesure détaillées : [docs/HISTORIQUE.md](docs/HISTORIQUE.md).

## Prérequis

- Arch/CachyOS, `paru`, bash 4.3 ou plus, python3 (stdlib seule), curl.
- `hf` (python-huggingface-hub, python-hf-xet). `gum` optionnel (menus).
- Paquets llama.cpp : `llama-cpp`, plus les backends ggml splittés :
  `ggml-cpu` et `ggml-vulkan` (obligatoires, installés par `--setup`).
- Pour ROCm0 : `ggml-hip` et le runtime ROCm (`rocm-hip-runtime`, `hipblas`,
  `rocblas`, `hipblaslt`). Le runtime seul ne suffit pas. Contrôle :
  `rocminfo | grep gfx` doit donner `gfx1151`.

## Installation

```bash
./setup-llm.sh --setup            # dépendances, GGUF, préchargement, models.ini
./setup-llm.sh --install-service  # service systemd user llama-server (démarrage au boot via linger)
systemctl --user start llama-server
```

En fin de `--setup`, si le fork n'est pas le moteur résolu, son installation est
**proposée** (défaut oui, `--setup-fork` derrière ; en entrée non interactive
rien n'est fait et la commande est rappelée) : les réglages du parc en dépendent.

## Moteur : fork strix-llama.cpp

Le fork apporte les clés de réglage dont le parc dépend (n-gram sur disque,
budget de réflexion, drafter externe, MTP de Qwen3.8-Flash-Next) et gagne le
prefill sur tout le parc. Il est construit dans `~/llm/strix-llama.cpp` et
exposé par quatre liens (`llama-server`, `llama-bench`, `llama-cli`,
`llama-quantize`) dans `~/.local/bin`, que l'unité systemd met en tête du PATH.

```bash
./setup-llm.sh --setup-fork   # installe ou réinstalle (clone si besoin, build, liens)
./setup-llm.sh --update-fork  # suivi d'amont du fork déjà en place
systemctl --user restart llama-server
./setup-llm.sh --list-devices # quel binaire répond, et sa version
./setup-llm.sh --unset-fork   # retire les liens : retour au paquet Arch
```

**Épingler un commit.** Une resynchronisation d'amont peut faire régresser un
modèle sans rien casser ailleurs (13/09/2026 : le passage à `6548035`, sync
b10917, fait tomber le prefill batché de Qwen3.8-27B de 69 à 58 t/s en pp7 et
de 79 à 52 en pp8, alors que `0007bc6` était bon). On revient alors à un commit
connu et on y reste tant que l'amont n'est pas corrigé :

```bash
./setup-llm.sh --setup-fork 0007bc6 "sync b10917 : régression pp7/pp8 sur Qwen3.8-27B"
./setup-llm.sh --setup-fork   # sans argument : dépingle et reprend la branche
```

L'argument est un commit, un tag ou une branche : `git fetch`, puis `checkout`
détaché (commit, tag) ou suivi de branche (`checkout` + `pull --ff-only`),
rebuild et liens comme d'habitude. L'épinglage est écrit dans `fork.conf`
(local, non versionné, `pin = <commit>` et `raison = <texte>` facultative, aussi
prise dans `$FORK_PIN_REASON`). Tant qu'il tient, `--update-fork` ne tire plus
rien : il annonce le commit épinglé et sa raison, montre quand même le changelog
en attente en amont (pour voir passer le correctif) et rappelle la commande de
reprise. `--list-devices` et la fin de `--setup` affichent l'épinglage.

`--update-fork` est la commande de suivi au quotidien, à lancer juste après un
`--update` : elle refuse d'agir si le fork n'est pas cloné ou si les liens ne
viennent pas de lui, refuse un arbre sale, `git fetch` seulement, affiche le
**changelog** trié (les commits propres au fork ; les commits llama.cpp d'amont
réduits à un compte) puis **demande confirmation** avant de tirer et
reconstruire : sans « o », rien n'est tiré (`FORK_UPDATE_YES=1` vaut
confirmation, entrée non interactive = rien). Ni `--setup-fork` ni
`--update-fork` ne redémarre le service ni ne lance de mesure.

Deux pièges. Les binaires portent un RUNPATH absolu vers leur dossier `build` :
déplacer `~/llm/strix-llama.cpp` impose un rebuild (`--setup-fork`), jamais un
`mv`. Et le routeur refuse toute clé ini inconnue sans démarrer du tout : les
clés propres au fork (`ngram-on-disk`, `reasoning-budget-*`,
`spec-draft-adaptive`, `spec-prefill*` — liste `FORK_ONLY_KEYS` dans
`lib/fork.sh`) font échouer le paquet Arch, et `--start` refuse de lancer un
moteur upstream sur un tel ini, en nommant le modèle et la clé. Pour revenir au
paquet Arch : retirer ces clés de `lib/models.sh`, puis `--preload` (régénère le
ini) avant le restart.

Étiquette des mesures : chaque bump du fork ouvre une **nouvelle série**,
étiquetée au commit (`strix-<commit>` en colonne build des journaux, `bNNNNN`
pour un build upstream). Les deux séries ne se comparent pas
(cf. ARCHITECTURE.md, comparabilité des journaux).

## Sous-commandes

| Commande | Rôle |
|---|---|
| `--setup` | Installe les dépendances, propose ROCm, télécharge les GGUF manquants, sélectionne le préchargement, génère le ini, propose le fork s'il n'est pas le moteur |
| `--update [modèle]` | Comme `--setup`, mais laisse `hf` comparer les etags : seul ce qui a bougé est retéléchargé |
| `--cleanup [--yes]` | Supprime les dossiers et GGUF orphelins (dry-run par défaut) |
| `--preload` | Re-sélectionne les modèles always-on et régénère le ini |
| `--bench [modèle\|all] [n]` | Mesure le serveur tel qu'il tourne : prefill, décode médian, acceptance MTP, tableau récapitulatif. N'écrit rien ; avant de charger un modèle, décharge les plus gros modèles résidents si la RAM ne suffit pas (`BENCH_NO_UNLOAD=1` pour désactiver) |
| `--bench-devices [modèle] [devices] [n]` | Compare les devices d'un modèle (défaut Vulkan0,ROCm0) : bench avec restart par device, verdict par temps de tour simulé, vainqueur écrit dans `bench-devices.conf` (détail dans ARCHITECTURE.md) |
| `--bench-parallel [modèle] [n] [passes]` | Débit sous `n` requêtes simultanées (défaut : le `parallel` du modèle) : agrégé et décode par requête contre 1 requête ; montre ce que vaut `parallel = N` et la file d'attente au-delà |
| `--bench-cache [modèle]` | Efficacité du cache de prompt sur le pattern agentic (contexte froid, tour suivant, édition au premier tiers, requête identique) : part du prompt servie du cache et prefill à chaque fois ; c'est la mesure de `cache-ram` / `ctx-checkpoints` / `cache-reuse` |
| `--bench-sanity [modèle\|all]` | Recopie exacte d'un code (`prompts/bench-sanity.txt`, trivial pour ne tester que le backend) : un device qui répond faux est exclu de `--bench-devices`, en plus du garde-fou anti-charabia |
| `--bench-agentic [modèle] [passes] [N]` | Une vraie boucle de tool calls : pi (conteneur jetable, `bench-agentic/`) joue un appel froid (prompt système) puis N passes de 5 scénarios en direct sur llama-server ; par scénario PASS/passes et médianes (temps mur, prompt et part du cache, générés, prefill et décode t/s réels). 3e argument `N` > 1 : chaque passe joue la suite seule puis à `N` boucles pi **simultanées** (orchestrateur + sous-agents), avec le facteur de débit de tâches et le décode agrégé |
| `--bench-load [modèle\|all]` | Temps de chargement + premier token après restart, puis TTFT à chaud : ce que coûte un modèle à la demande (base pour `preload.conf` et `--models-max`) |
| `--setup-fork [commit] [raison]` | Installe ou met à jour le moteur : fork [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp), build cmake Vulkan et liens dans `~/.local/bin`. Avec un commit (ou tag, ou branche) : épingle le moteur dessus et l'écrit dans `fork.conf` ; sans argument, dépingle et reprend la branche (voir « Moteur ») |
| `--update-fork` | Suivi d'amont du moteur, juste après un `--update` : `git fetch`, changelog des commits reçus et confirmation, puis mise à jour du fork **déjà installé** (`git pull --ff-only`, rebuild et liens), s'arrête si rien n'a bougé, ne redémarre rien et ne mesure rien. Si le moteur est épinglé (`fork.conf`), ne tire rien et se contente du changelog en attente (voir « Moteur ») |
| `--unset-fork` | Retire les liens du fork : retour au paquet Arch au prochain restart |
| `--list-devices` | Moteur résolu (paquet Arch ou fork) avec sa version, backends ggml installés et devices exposés, croisés avec `bench-devices.conf` |
| `--spec-test [modèle] [n] [prompt]` | Décode réel via l'API (spéculation incluse), journalise, calibre et persiste le n-max dès 2 valeurs mesurées. Prompt par défaut `spec-test.txt` ; un autre prompt est journalisé à part et ne calibre pas |
| `--spec-tune [modèle] [k1,k2,..] [n]` | Boucle automatique sur plusieurs n-max avec restart entre chaque, retient le meilleur mesuré |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | A/B de réglages spéculatifs sur mesure réelle : chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |
| `--spec-ngram-tune [modèle] [n] [prompt]` | Règle la longueur de draft n-gram (`spec-ngram-map-k-size-m`) : courbe `t_forward(batch)` pour localiser la marche de noyau ggml, puis arbitrage des candidats sur mesure réelle (prompt de refactor par défaut) |
| `--start` | Lance llama-server sur le port 8009 (commande du service) |
| `--install-service`, `--uninstall-service` | Service systemd user (systemctl --user) |
| `--help` | Aide, liste des modèles et des clés de téléchargement |

## Workflow typique

```bash
./setup-llm.sh --setup                # première mise en place
./setup-llm.sh --update               # 1. modèles (etags)
./setup-llm.sh --update-fork          # 2. moteur (rebuild + liens si bump)
systemctl --user restart llama-server # 3. appliquer
./setup-llm.sh --bench all            # 4. perfs de tous les modèles présents : régressions
./setup-llm.sh --bench-devices        # Vulkan ou ROCm pour un modèle ?
./setup-llm.sh --spec-tune            # règle spec-draft-n-max d'un modèle à drafter
./setup-llm.sh --spec-ngram-tune      # règle la longueur de draft n-gram
./setup-llm.sh --spec-ab <m> 4 - base "spec-ngram-map-k-min-hits=1"   # compare des réglages
./setup-llm.sh --bench-parallel <m>   # ce que vaut parallel = N
./setup-llm.sh --bench-cache <m>      # part du prompt repayée à chaque tour (agentic)
./setup-llm.sh --bench-load <m>       # coût d'une bascule LRU
./setup-llm.sh --bench-agentic <m> 3  # vraie boucle de tool calls (pi), PASS/FAIL et t/s réels
./setup-llm.sh --bench-agentic <m> 2 3  # les mêmes à 3 boucles simultanées : débit de tâches
```

## Mesurer

Le script ne mesure jamais les GGUF directement : tout passe par l'API du
serveur tel qu'il tourne (`/v1/chat/completions`), donc avec les réglages réels
du `models.ini` (quantisation du cache KV, flash-attn, spéculation incluse). Un
chiffre de bench est un chiffre de production, pas un `llama-bench` sur les
poids nus, et toute mesure dépendant d'un paramètre de modèle lit l'état réel du
serveur (`/v1/models`), jamais le script ni le ini.

`--bench` envoie n passes (défaut 3) par modèle, toutes avec le même prompt :

- la passe 1 porte un long contexte réaliste (`prompts/bench-context.txt`, un
  cahier des charges, plus la tâche `prompts/bench-task.txt`). Le serveur doit
  le calculer entièrement : c'est la mesure de prefill. La taille qui fait foi
  est le `n=` affiché sur la passe, pas une taille visée ;
- les passes suivantes resoumettent le même contexte, servi par le prompt
  cache : le temps est dominé par la génération, c'est la mesure de décode (et
  d'acceptance le cas échéant). Le récap donne la médiane hors passe 1.

La mesure est passive : rien n'est écrit, pas de restart, pas de purge de cache.
Si la passe 1 a été partiellement servie par le cache, le prefill est marqué `*`
au récap : non comparable, jamais corrigé. Chaque `--bench` est journalisé dans
`logs/bench.log` avec le build et comparé au run précédent du même modèle, GGUF
et device : un écart de plus de 5 % est signalé, le changement de build rappelé.

Comparabilité : les chiffres dépendent des prompts de `prompts/`. Modifier
`bench-context.txt` ou `bench-task.txt` invalide la comparaison avec les
tableaux antérieurs ; ne jamais les toucher au détour d'un autre changement.

**Garde mémoire et OOM.** Le routeur évince en LRU sans connaître la taille des
modèles : deux géants résidents suffisent à dépasser les 124 Go et l'OOM killer
prend le routeur (deux fois le 13/09/2026). Une garde mémoire précède donc
chaque chargement (`--bench`, `--bench-devices`, `--bench-cache`,
`--bench-parallel`, `--spec-test`, `--spec-ab`) : taille estimée contre mémoire
disponible, puis déchargement par l'API des plus gros résidents, jamais un
préchargé tant qu'un autre peut partir, sans restart (`BENCH_NO_UNLOAD=1` la
désactive, `BENCH_ROOM_MARGE_PCT` change la marge).

Chaque mesure écrit son journal TSV dans `logs/` (avec le build) et se lit
seule ; la procédure d'ajout d'un modèle (`AGENTS.md`, skill `ajout-modele`) dit
laquelle lancer selon le rôle du modèle.

| Commande | Question à laquelle elle répond | Méthode |
|---|---|---|
| `--bench-sanity [modèle\|all]` | Le backend produit-il un texte juste ? | recopie exacte d'un code (`prompts/bench-sanity.txt`), trivial pour ne tester que le backend ; `--bench-devices` l'applique avant chaque device, en plus du garde-fou anti-charabia de `timings.py` (mot dominant, mots distincts, répétition périodique de caractères) |
| `--bench-parallel [modèle] [n] [passes]` | Que vaut `parallel = N` ? | salves de 1 puis n requêtes simultanées (spec-test.txt, 400 tokens), débit agrégé et décode médian par requête ; `parallel` réel lu sur `/v1/models`, au-delà les requêtes font la queue |
| `--bench-cache [modèle]` | Combien du prompt est repayé à chaque tour ? | quatre requêtes : contexte froid, tour suivant, édition au premier tiers (préfixe commun 2/3, au-dessus du seuil `slot-prompt-similarity 0.5`), requête identique ; part servie du cache (`cache_n`) et prefill |
| `--bench-agentic [modèle] [passes] [N]` | Que vaut le modèle en boucle agentic, seul puis à `N` boucles en même temps ? | pi dans un conteneur (`bench-agentic/`, réseau hôte) joue un appel froid puis N passes de 5 scénarios de tool calls en direct sur `:8009` ; delta de `/metrics?model=` par scénario : prompt (part du cache), généré, prefill et décode t/s, plus PASS et temps mur, médianes sur les passes. À `N` > 1, chaque passe est jouée seule puis par `N` conteneurs simultanés : facteur de débit de tâches `(N x solo) / parallèle`, décode agrégé lu sur `/metrics` autour de la salve |
| `--spec-test [modèle] [n] [prompt]` | Que rend la spéculation en décode réel ? | une requête par passe via l'API, décode et acceptance médians, journal `logs/spec-tests.log` et calibration du n-max dès 2 valeurs mesurées ; prompt par défaut `spec-test.txt`, un autre prompt est journalisé à part et ne calibre pas |
| `--bench-load [modèle\|all]` | Que coûte un modèle à la demande ? | restart du service, première requête chronométrée (chargement + premier token), puis TTFT à chaud |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | Ce réglage vaut-il mieux que celui-là ? | chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée au ini, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |

`--bench-devices` et `--spec-ngram-tune` règlent en mesurant : le premier
compare Vulkan0 et ROCm0 d'un modèle (restart par device, verdict par temps de
tour simulé `2000/prefill + 3000/décode`, vainqueur écrit dans
`bench-devices.conf`), le second cherche la longueur de draft n-gram (courbe
`t_forward(batch)` par `llama-bench` service arrêté, pour localiser la marche de
noyau ggml, puis arbitrage réel des candidats sur `prompts/spec-refactor.txt`,
écrit dans `spec-ngram.conf`). Formules, garde-fous et limites : ARCHITECTURE.md.
Méthodes détaillées et exemples mesurés : docs/HISTORIQUE.md.

## Parc au 15/09/2026

Une ligne par section servie du `models.ini` (la section thinking du 27B,
doublon sur le même GGUF et deux fois plus lente, a été retirée le 13/09/2026,
cf. `docs/HISTORIQUE.md`) ; depuis le 15/09/2026 ornith-1.5-35b-a3b en a deux,
sur le même GGUF : la section de base sert la concurrence (parallel 4, sans
spéculation), la variante `-mtp` le mono-utilisateur (parallel 1, spéculation).
Même jour, même logique pour lfm2.5-2.6b et qwen3.5-9b, dans l'autre sens :
le drafter y apporte assez (x1,76 et x2,1 en test isolé) pour que la section
principale passe en spéculation à un slot, le réglage multi-slot d'avant
restant servi sous le nom `-parallel`. Le 9b spéculé tourne sur un AUTRE GGUF
(repo MTP d'unsloth, dossier `qwen3.5-9b-mtp/`), le LFM2.5 sur le même GGUF
plus un drafter DSpark. Les deux sections spéculées ont été mesurées le
15/09/2026 tel que servi : le drafter rend +59 % de décode au LFM2.5 et +29 %
au 9b contre la variante `-parallel` re-mesurée le même jour, en échange de
20 % et 5,8 % de prefill, le drafter décodant aussi le prompt. Les colonnes
`-parallel` gardent les chiffres du 13/09/2026, série de référence de ce
réglage.
Réglages exacts dans `lib/models.sh` ; toutes les mesures sont celles du fork strix-0007bc6
(Vulkan0, `--bench` 3 passes, les 12, 13 et 15/09/2026). Acceptance vide = pas de
spéculation. La dernière colonne situe le décode contre la dernière mesure du
paquet Arch (série `bNNNNN`, 21/08 au 05/09/2026) : deux séries distinctes, un
ordre de grandeur, pas une comparaison à la décimale.

| Modèle (section) | Quant et taille | Device | Réglage spéculatif | Prefill t/s | Décode t/s | Acceptance | Écart décode contre paquet |
|---|---|---|---|---|---|---|---|
| lfm2.5-2.6b | Q8_0, 2,7 Go (+ drafter DSpark 0,36 Go) | Vulkan0 | spec-type `draft-dspark`, drafter DSpark officiel Liquid AI Q8_0, n-max 3, parallel 1 (KV f16) | 2875 | 108,8 | 0,50 | jamais mesuré au paquet (réglage du 15/09/2026) |
| lfm2.5-2.6b-parallel | Q8_0, 2,7 Go (même GGUF) | Vulkan0 | aucun, parallel 4 (KV f16) | 3048 | 70,8 | — | +4,6 % |
| qwen3.5-9b | UD-Q6_K_XL, 8,4 Go (GGUF MTP unsloth, dossier `qwen3.5-9b-mtp/`) | Vulkan0 | spec-type `ngram-map-k,draft-mtp`, size-m 7, min-hits 2, tête MTP embarquée, n-max 4, parallel 1 | 745 | 33,0 | 0,58 | jamais mesuré au paquet (réglage du 15/09/2026) |
| qwen3.5-9b-parallel | UD-Q6_K_XL, 8,2 Go (GGUF sans MTP) | Vulkan0 | aucun, parallel 4 | 971 | 25,7 | — | 0 % |
| ornith-1.5-35b-a3b | Q4_K_M, 22 Go | Vulkan0 | aucun, parallel 4 (cache-type-v q8_0) | 1129 | 73,3 | — | +3,7 % |
| ornith-1.5-35b-a3b-mtp | Q4_K_M, 22 Go (même GGUF) | Vulkan0 | spec-type `ngram-map-k,draft-mtp`, size-m 7, min-hits 2, tête MTP embarquée, n-max 4, parallel 1 | 1073 | 76,2 | 0,55 | non mesuré au paquet |
| qwen3.8-27b-dflash-nothink | UD-Q4_K_XL, 17 Go (même GGUF) | Vulkan0 | spec-type `ngram-map-k,draft-dflash`, size-m 47, min-hits 2, drafter DFlash 2 z-lab Q8_0, n-max 7, parallel 1 | 359 | 32,6 | 0,595 | +11 % (paquet en MTP n-max 6) |
| qwen3.8-flash-next-mtp-nothink | UD-IQ4_XS, 94 Go | Vulkan0 | spec-type `ngram-map-k,draft-mtp`, size-m 7, min-hits 2, sidecar MTP Q8_0 renommé, n-max 4, `ngram-on-disk`, parallel 1 | 383 | 50,0 | 0,87 | +93 % (paquet en n-gram seul, le MTP n'y existe pas) |
| qwen3-coder-next | UD-Q4_K_XL, 47 Go (+ drafter DFlash 0,51 Go) | Vulkan0 | spec-type `draft-dflash`, drafter DFlash z-lab Q8_0 (conversion transmutator), n-max 7, parallel 1 | 727 | 52,2 | 0,515 | +19 % (paquet en n-gram seul) |
| gpt-oss | UD-Q4_K_XL, 59 Go | Vulkan0 | spec-type `ngram-map-k`, size-m 7, min-hits 2, parallel 1 | 599 | 52,9 | 0,57 | +2 % |
| laguna-s-2.1 | UD-Q4_K_XL, 73 Go | Vulkan0 | spec-type `ngram-map-k`, size-m 7, min-hits 2, parallel 1 (DFlash refusé par le fork) | 346 | 29,6 | 0,80 | -2 % |
| deepseek-v4-flash | UD-IQ3_XXS, 104 Go (+ drafter DSpark 10,9 Go) | Vulkan0 | spec-type `ngram-map-k,draft-dspark`, size-m 7, min-hits 2, drafter DSpark unsloth Q8_0, n-max 3, reasoning-budget 6144 (soft 0,6 / 0,85, grâce 192), KV f16, parallel 1 (parallel 2 essayé et retiré le 15/09 : x1,16 de tâches au bench agentic à 2 boucles, latence doublée) | 196 | 28,8 | 0,69 | +134 % (paquet en n-gram seul, 19,9 sur le fork en n-gram seul) |

![Prefill paquet contre fork](docs/graphs/prefill.svg)

![Décode paquet contre fork](docs/graphs/decode.svg)

![Écart du fork en % du paquet](docs/graphs/ecarts.svg)

Ces trois figures sont générées par `python3 py/perf_graphs.py` depuis
`docs/perfs.tsv` (une ligne par section servie) : à régénérer, avec le TSV mis
à jour, dès que la table ci-dessus change.

Ce que le fork apporte : le prefill sur tout le parc (+16 à +110 %), le décode
partout où la spéculation change de régime (DeepSeek V4 +135 % avec le drafter DSpark, Flash-Next dont
le MTP n'existe pas sur le paquet +93 %, le 27B via DFlash 2), et
`ngram-on-disk` (Flash-Next chargé en 72 Go au lieu d'environ 100, à perfs
égales). Écartés après mesure : le speculative prefill (lossy, cache de prompt à
0 %), le draft adaptatif (2 % sous le draft fixe), le DFlash de Laguna S 2.1
(drafter refusé). Contrepartie, le découpage des mat-vec batchés (-7,4 % au
batch de 7), contournée par modèle et signalée en amont :
[issue #50](https://github.com/halo-box/strix-llama.cpp/issues/50).

## Fichiers de configuration

À côté du script, locaux et non versionnés (propres à la machine) :

| Fichier | Rôle |
|---|---|
| `bench-devices.conf` | clé (dossier GGUF) = device (Vulkan0/ROCm0), écrit par `--bench-devices`, édition manuelle OK |
| `preload.conf` | modèles préchargés, un par ligne |
| `fork.conf` | épinglage du moteur : `pin = <commit>` et `raison = <texte>`, écrit par `--setup-fork <commit>`, retiré par `--setup-fork` sans argument |
| `spec-nmax.conf` | modèle = spec-draft-n-max retenu par les mesures |
| `spec-ngram.conf` | modèle = spec-ngram-map-k-size-m retenu par les mesures |
| `logs/spec-tests.log` | journal TSV des runs `--spec-test` |
| `logs/bench.log` | journal TSV des `--bench` (avec le build llama.cpp) ; chaque `--bench` se compare au run précédent du même modèle/GGUF/device et signale un écart de plus de 5 % |
| `logs/bench-parallel.log` | journal TSV des `--bench-parallel` |
| `logs/bench-agentic.log` | journal TSV des `--bench-agentic` (une ligne par scénario, colonne `N` en queue = boucles simultanées) |
| `logs/bench-cache.log` | journal TSV des `--bench-cache` |
| `logs/bench-load.log` | journal TSV des `--bench-load` |
| `logs/spec-batch.log` / `.tsv` | journal des balayages `tools/bench-spec-batch.sh` |

Côté `~/models/` : `models.ini`, généré. Ne jamais l'éditer : relancer
`--preload` ou `--setup`. Le routeur ne le lit qu'au démarrage, toute
modification demande un restart du service.

## Ajouter un modèle

Tout se passe dans `lib/models.sh` : un bloc de deux appels, à la position
voulue dans le ini (l'ordre de déclaration est l'ordre d'émission), puis
`./setup-llm.sh --setup` télécharge le GGUF, régénère `models.ini` et propose
le redémarrage. Rien d'autre à toucher.

```bash
# Mon-Modele 7B : pourquoi ce repo et ce quant (taille, reco amont, date)
download_hf mon-modele-7b "org/Mon-Modele-7B-GGUF" \
  MON_MODELE_7B_PATH="Mon-Modele-7B-UD-Q4_K_XL.gguf"

# Mon-Modele 7B : justification des réglages (sampling officiel, cache,
#   contraintes) ; ce commentaire est la connaissance métier du modèle
llama_model mon-modele-7b "
model            = $MON_MODELE_7B_PATH
ctx-size         = 32768
cache-ram        = 2048
temp             = 0.7
top-k            = 20
parallel         = 4"
```

- `download_hf <dossier> <repo> VAR=<fichier>` déclare le fichier (chemin,
  inventaire pour `--cleanup`, téléchargement) ; `download_hf_shards` pour un
  modèle en shards (shard 00001 et sous-dossier de quant) ;
- `derive_gguf <dossier> VAR=<fichier> <source> <script>` déclare un GGUF
  **produit en local** à partir d'un fichier déjà déclaré (aucun repo ne le
  porte) : même inventaire `--cleanup`, et `--setup` lance le script après les
  téléchargements si le fichier manque ou si la source a bougé. Unique cas : le
  sidecar MTP de Qwen3.8-Flash-Next renommé pour le fork ;
- `llama_model <section> "<corps ini>"` déclare la section ; deux sections
  peuvent partager le même `*_PATH` (cas des deux sections Qwen3.8-27B jusqu'au
  13/09/2026), et les garde-fous de
  préchargement en dérivent ;
- `groupe "; --- titre ---"` avant le premier `llama_model` d'une famille.

La suite (device, spéculation, mesures, récap partageable) est la procédure en
sept étapes de la skill locale `.claude/skills/ajout-modele/SKILL.md`, résumée
dans `AGENTS.md`.

## Outils (tools/)

| Fichier | Rôle |
|---|---|
| `opencode-sync-model.sh` | Synchronise la liste des modèles du serveur (`/v1/models`) dans la config opencode (`~/.config/opencode/opencode.json`, provider `llamaswap`). Variables : `ENDPOINT`, `CONFIG`, `PROVIDER` |
| `bench-spec-batch.sh` | Courbe brute `t_forward(batch)` d'un ou plusieurs GGUF par `llama-bench`, hors service, sur un ou plusieurs devices (`DEV=Vulkan0,ROCm0`, `BATCHES`, `REPS`, `DEPTH`, `FA`). Analyse par `py/batch_curve.py`, journal `spec-batch.log` + `spec-batch.tsv`. Pour régler un modèle, préférer `--spec-ngram-tune` |
| `bench-depth.sh` | Prefill et décode selon la profondeur de contexte (`llama-bench -d`, défaut 0 / 16k / 32k, KV q8_0 comme le service), par device, avec le tour simulé de `--bench-devices` recalculé à chaque profondeur : c'est le régime agentic réel, où le classement des devices peut s'inverser. Journal `logs/bench-depth.log` + `.tsv` |
| `mtp-rename-hc-head.py` | Renomme les trois tenseurs du mixeur final des hyper-connexions d'un sidecar MTP Qwen3.8-Flash-Next (`blk.<n>.nextn.hc_head_*` chez unsloth, convention de la PR mainline #28243) vers les noms que lit le fork strix-llama.cpp (`output_hc_*`). Données recopiées telles quelles. `PYTHONPATH=$HOME/llm/strix-llama.cpp/gguf-py python3 tools/mtp-rename-hc-head.py <in> <out>` ; appelé aussi par `--setup`. Inutile sur un moteur mainline portant #28243 |
| `py/perf_graphs.py` | Régénère les trois SVG de `docs/graphs/` (prefill, décode, écarts en %) à partir de `docs/perfs.tsv`, en rendu sobre (barres pleines, fond blanc). Aucune dépendance, aucun service : `python3 py/perf_graphs.py [<tsv> [<dossier>]]`. À relancer après toute modification du TSV |
| `llm-proxy.ts` | Extension pi / omp : découvre les modèles `text-generation` du proxy Albert (`/v1/models`, ctx, coûts, reasoning déduit de l'id) et enregistre le provider `albert`. A copier dans `~/.pi/agent/extensions/` et `~/.omp/agent/extensions/` (une seule extension provider par agent). Endpoint `http://llmproxy` et clé en dur pour l'instant (à passer sur `process.env` avant diffusion) |

Les scripts shell pointent sur `http://bigchuck:8009` par défaut (surchargeable par variable d'environnement).

## FAQ

**Un modèle échoue au chargement, ROCm0 a disparu.**
`--list-devices` croise `bench-devices.conf` avec les devices réellement
exposés. Réinstaller `ggml-hip`, ou forcer Vulkan0 dans la conf puis `--preload`.

**Je peux éditer models.ini ?**
Non, il est régénéré à chaque `--setup`, `--preload` ou `--spec-*`.
Éditer les fichiers `.conf` ou `lib/models.sh`.

**Pourquoi `parallel = 1` sur les modèles spéculatifs ?**
Par choix, pas par interdit. Cette FAQ a répondu jusqu'au 15/09/2026
« contrainte llama.cpp : `-np` supérieur à 1 et `--mmproj` ne sont pas
supportés avec MTP » ; cette phrase vient d'une doc unsloth de juin/juillet
2026 et n'existe pas dans le moteur servi (fork strix-llama.cpp, commit
`0007bc6`, vérifié le 15/09/2026) : le serveur y drafte tous les slots en un
appel, `draft-dflash` et `draft-dspark` sont explicitement multi-séquences,
`draft-mtp` est vectorisé par séquence mais n'a jamais été éprouvé à `-np` > 1
(non éprouvé, pas interdit). Ce qui décide vraiment, modèle par modèle :
`ctx-size` est un pool partagé (chaque slot reçoit `ctx-size / parallel`), la
mémoire de KV, le batch de vérification qui vaut jusqu'à
`parallel x (n-max + 1)` et franchit vite le seuil de 8 colonnes de
ggml-vulkan, et le rendement réel de la spéculation, qui s'effondre quand les
voies se multiplient. Une campagne de mesure multi-slot est en cours : les
valeurs actuelles sont inchangées en attendant. Seul interdit qui demeure : le
`--mmproj` reste incompatible avec un drafter.
