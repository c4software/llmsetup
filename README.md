# LLM Setup

LLM Setup pilote un `llama-server` en router mode natif sur une machine Strix Halo
(Ryzen AI Max+ 395, 128 Go unifiés, CachyOS/Arch), avec un seul point d'entrée :
`./setup-llm.sh`.

Ce qu'il gère :

- téléchargement des GGUF depuis Hugging Face (`hf`, mises à jour par etags) ;
- génération de `~/models/models.ini` : les réglages de chaque modèle vivent
  dans `lib/models.sh` avec leurs justifications en commentaire ;
- préchargement always-on ou chargement à la demande (LRU) ;
- mesure des perfs par l'API du serveur (`--bench`, `--bench-devices`,
  `--spec-test`) ;
- réglage de la spéculation par mesure : MTP (`spec-draft-n-max`, calibration
  α) et n-gram (`spec-ngram-map-k-size-m`, courbe de coût du batch puis
  arbitrage réel) ;
- service systemd user.

Les backends ggml (Vulkan par défaut, ROCm/HIP optionnel) sont des paquets
Arch séparés depuis le split de mi-août 2026. Tout est piloté par des fichiers
de conf locaux à côté du script (non versionnés, propres à la machine). Le `models.ini` est généré, jamais édité.

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

## Moteur : fork strix-llama.cpp

Depuis le 12/09/2026 le service ne tourne plus sur le paquet Arch `llama-cpp`
mais sur le fork [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp),
construit localement dans `~/llm/strix-llama.cpp` et exposé par quatre liens
(`llama-server`, `llama-bench`, `llama-cli`, `llama-quantize`) dans
`~/.local/bin`, que l'unité systemd met en tête du PATH.

```bash
./setup-llm.sh --setup-fork   # installe ET met à jour (clone ou git pull --ff-only, build, liens)
systemctl --user restart llama-server
./setup-llm.sh --list-devices # quel binaire répond, et sa version
./setup-llm.sh --unset-fork   # retire les liens : retour au paquet Arch
```

Le paquet Arch reste installé, c'est lui qui reprend la main sans les liens.
Deux pièges :

- les binaires portent un RUNPATH absolu vers leur dossier `build` : déplacer
  `~/llm/strix-llama.cpp` impose un rebuild (`--setup-fork`), jamais un `mv` ;
- le routeur refuse toute clé ini qu'il ne connaît pas, et l'échec n'est pas
  local au modèle fautif : c'est le routeur **entier** qui ne démarre pas. Les
  clés propres au fork (`ngram-on-disk`, `reasoning-budget-*`,
  `spec-draft-adaptive`, `spec-prefill*` — liste `FORK_ONLY_KEYS` dans
  `lib/fork.sh`) font donc
  échouer le paquet Arch. Le dépôt ne gère pas deux moteurs : il ne filtre ni ne
  réécrit rien, mais `--start` refuse de lancer un moteur upstream sur un tel
  ini, en nommant le modèle et la clé. Pour rester sur le paquet Arch : retirer
  ces clés de `lib/models.sh`, puis `--preload` (régénère le ini) avant le
  restart.

Comparabilité : les mesures faites sous le fork forment une **nouvelle série**.
La colonne build des journaux porte `strix-<commit>` au lieu de `bNNNNN`, et ces
deux séries ne se comparent pas (cf. ARCHITECTURE.md, comparabilité des
journaux) — le fork décode Qwen3.8-Flash-Next à 27 t/s contre 21 sous Arch.

Ce que le fork apporte aujourd'hui côté réglages (détail et mesures dans les
commentaires de `lib/models.sh`) : `ngram-on-disk` laisse la table n-gram de
28,8 Go de Qwen3.8-Flash-Next sur disque (72 Go de mémoire utilisée au lieu
d'environ 100, à prefill et décode identiques, mesuré le 12/09/2026), les
`reasoning-budget-*` plafonnent la réflexion des modèles thinking, et
`spec-draft-adaptive` dimensionne le draft sur l'acceptance mesurée (--spec-ab du
12/09/2026 sur les 27B MTP : 2 % sous le draft fixe, non retenu). Il
apporte aussi le **speculative prefill** (`spec-prefill*`) : un petit modèle
estime l'importance des tokens du prompt et le gros n'en prefille qu'une
fraction (`spec-prefill-p`, 0,30 par défaut). Contrairement au MTP et aux
n-grams, c'est **lossy** — les tokens élagués sont perdus — et, mesuré le
12/09/2026 sur qwen3.8-27b, il neutralise le cache de prompt (0 % même sur une
requête identique) : retiré, perdant en boucle agentic. Le graphe MTP `qwen4exp` et
le drafter externe (`spec-draft-model`) viennent du fork également, ce qui
débloque le MTP de Qwen3.8-Flash-Next (jalon 2), à une condition : le sidecar
MTP d'unsloth doit d'abord être **renommé** par `tools/mtp-rename-hc-head.py`
(voir Outils). Le fork lit le mixeur des hyper-connexions sous
`output_hc_{norm,down,up}`, unsloth le range sous
`blk.<n>.nextn.hc_head_*` (convention de la PR mainline #28243) : sans
renommage, `check_tensor_dims: tensor 'output_hc_norm.weight' not found` et le
modèle ne charge pas du tout. Le renommage est automatique au `--setup`
(`derive_gguf` dans `lib/models.sh`). Le DFlash du fork ne débloque rien sur
Laguna S 2.1, refusé comme sur le paquet Arch (12/09/2026), mais il accepte le
drafter DFlash 2 officiel de Qwen3.8-27B (z-lab, 2,0 Go) : il y remplace la
tête MTP depuis le 13/09/2026 (`qwen3.8-27b-dflash-nothink`, +12 à +18 % de
décode selon le prompt).

Une contrepartie mesurée : le fork découpe les mat-vec batchés en colonnes
(4/2/1), ce qui coûte jusqu'à -7,4 % sur un batch de 7 (voir la ligne du
27B dans « Paquet Arch contre fork »). `GGML_VK_MMV_NO_SPLIT=1` annule la
pénalité, mais désactive le découpage pour **tout** le parc, Flash-Next
compris, qui lui en profite : non retenu. Le réglage par modèle (n-max qui
évite le pire cas) suffit ; une issue en amont sur le découpage serait
recevable.

## Sous-commandes

| Commande | Rôle |
|---|---|
| `--setup` | Installe les dépendances, propose ROCm, télécharge les GGUF manquants, sélectionne le préchargement, génère le ini |
| `--update [modèle]` | Comme `--setup`, mais laisse `hf` comparer les etags : seul ce qui a bougé est retéléchargé |
| `--cleanup [--yes]` | Supprime les dossiers et GGUF orphelins (dry-run par défaut) |
| `--preload` | Re-sélectionne les modèles always-on et régénère le ini |
| `--bench [modèle\|all] [n]` | Mesure le serveur tel qu'il tourne : prefill, décode médian, acceptance MTP, tableau récapitulatif. N'écrit rien |
| `--bench-devices [modèle] [devices] [n]` | Compare les devices d'un modèle (défaut Vulkan0,ROCm0) : bench avec restart par device, verdict par temps de tour simulé, vainqueur écrit dans `bench-devices.conf` (détail dans ARCHITECTURE.md) |
| `--bench-parallel [modèle] [n] [passes]` | Débit sous `n` requêtes simultanées (défaut : le `parallel` du modèle) : agrégé et décode par requête contre 1 requête ; montre ce que vaut `parallel = N` et la file d'attente au-delà |
| `--bench-cache [modèle]` | Efficacité du cache de prompt sur le pattern agentic (contexte froid, tour suivant, édition au premier tiers, requête identique) : part du prompt servie du cache et prefill à chaque fois ; c'est la mesure de `cache-ram` / `ctx-checkpoints` / `cache-reuse` |
| `--bench-sanity [modèle\|all]` | Recopie exacte d'un code (`prompts/bench-sanity.txt`, trivial pour ne tester que le backend) : un device qui répond faux est exclu de `--bench-devices`, en plus du garde-fou anti-charabia |
| `--bench-agentic [modèle] [passes]` | Une vraie boucle de tool calls : pi (conteneur jetable, `bench-agentic/`) joue un appel froid (prompt système) puis N passes de 5 scénarios en direct sur llama-server ; par scénario PASS/passes et médianes (temps mur, prompt et part du cache, générés, prefill et décode t/s réels) |
| `--bench-load [modèle\|all]` | Temps de chargement + premier token après restart, puis TTFT à chaud : ce que coûte un modèle à la demande (base pour `preload.conf` et `--models-max`) |
| `--setup-fork` | Installe ou met à jour le moteur : fork [halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp), build cmake Vulkan et liens dans `~/.local/bin` (voir « Moteur ») |
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
./setup-llm.sh --bench all            # perfs de tous les modèles présents
./setup-llm.sh --bench-devices        # Vulkan ou ROCm pour un modèle ?
./setup-llm.sh --spec-tune            # règle spec-draft-n-max d'un modèle MTP
./setup-llm.sh --spec-ngram-tune      # règle la longueur de draft n-gram
./setup-llm.sh --spec-ab <m> 4 - base "spec-ngram-map-k-min-hits=1"   # compare des réglages
./setup-llm.sh --bench-parallel <m>   # ce que vaut parallel = N
./setup-llm.sh --bench-cache <m>      # part du prompt repayée à chaque tour (agentic)
./setup-llm.sh --bench-load <m>       # coût d'une bascule LRU
./setup-llm.sh --bench-agentic <m> 3  # vraie boucle de tool calls (pi), PASS/FAIL et t/s réels
./setup-llm.sh --update qwen3.8-27b   # après un re-upload unsloth
./setup-llm.sh --bench all            # après chaque mise à jour de llama-cpp : régressions
```

## Mesures de perfs (--bench)

Le script ne mesure jamais les GGUF directement : tout passe par l'API du
serveur tel qu'il tourne (`/v1/chat/completions`), donc avec les réglages
réels du `models.ini` (quantisation du cache KV, flash-attn, spéculation MTP
incluse). Un chiffre de bench est un chiffre de production, pas un
`llama-bench` sur les poids nus.

`--bench` envoie n passes (défaut 3) par modèle, toutes avec le même prompt :

- la passe 1 porte un long contexte réaliste (`prompts/bench-context.txt`,
  un cahier des charges, plus la tâche `prompts/bench-task.txt`). Le serveur
  doit le calculer entièrement : c'est la mesure de prefill. La taille qui
  fait foi est le `n=` affiché sur la passe, pas une taille visée ;
- les passes suivantes resoumettent le même contexte, servi par le prompt
  cache : le temps est dominé par la génération, c'est la mesure de décode
  (et d'acceptance MTP le cas échéant). Le récap donne la médiane hors
  passe 1.

La mesure est passive : rien n'est écrit, pas de restart, pas de purge de
cache. Si la passe 1 a été partiellement servie par le cache (le modèle
avait déjà vu un préfixe du prompt), le prefill est marqué `*` au récap :
signalé comme non comparable, jamais corrigé.

Comparabilité : les chiffres dépendent des prompts de `prompts/`. Modifier
`bench-context.txt` ou `bench-task.txt` invalide la comparaison avec les
tableaux antérieurs ; ne jamais les toucher au détour d'un autre changement.

**⚠ `--bench all` et les géants.** Le bench ne décharge rien : c'est le routeur
qui charge à la demande et évince en LRU, sans connaître la taille des modèles.
Enchaîner plusieurs modèles de 60 à 104 Go avec `--models-max 2` (préchargé + 1)
peut donc demander plus que les 124 Go de la machine : pendant la campagne du
13/09/2026 l'OOM killer a tué le routeur deux fois (détail plus bas, « Paquet
Arch contre fork »). Décharger explicitement le modèle précédent
(`POST /models/unload`) ou ordonner la suite du plus petit au plus gros.

Chaque `--bench` est journalisé dans `logs/bench.log` avec le build de
llama.cpp et comparé au run précédent du même modèle, GGUF et device : un
écart de plus de 5 % sur le prefill ou le décode est signalé, le changement
de build rappelé. `./setup-llm.sh --bench all` après chaque mise à jour du
paquet suffit donc à voir une régression (b10433 a cassé DeepSeek sur ROCm0
en silence : rien ne l'aurait vu sans mesure).

## Mesures complémentaires

Chacune écrit son journal TSV dans `logs/` (avec le build) et se lit seule ;
la procédure d'ajout d'un modèle (`AGENTS.md`, skill `ajout-modele`) dit
laquelle lancer selon le rôle du modèle.

| Commande | Question à laquelle elle répond | Méthode |
|---|---|---|
| `--bench-sanity [modèle\|all]` | Le backend produit-il un texte juste ? | recopie exacte d'un code (`prompts/bench-sanity.txt`), trivial pour ne tester que le backend ; `--bench-devices` l'applique avant chaque device, en plus du garde-fou anti-charabia de `timings.py` (mot dominant, mots distincts, répétition périodique de caractères) |
| `--bench-parallel [modèle] [n] [passes]` | Que vaut `parallel = N` ? | salves de 1 puis n requêtes simultanées (spec-test.txt, 400 tokens), débit agrégé et décode médian par requête ; `parallel` réel lu sur `/v1/models`, au-delà les requêtes font la queue |
| `--bench-cache [modèle]` | Combien du prompt est repayé à chaque tour ? | quatre requêtes : contexte froid, tour suivant, édition au premier tiers (préfixe commun 2/3, au-dessus du seuil `slot-prompt-similarity 0.5`), requête identique ; part servie du cache (`cache_n`) et prefill |
| `--bench-agentic [modèle] [passes]` | Que vaut le modèle en boucle agentic ? | pi dans un conteneur (`bench-agentic/`, réseau hôte) joue un appel froid puis N passes de 5 scénarios de tool calls en direct sur `:8009` ; delta de `/metrics?model=` par scénario : prompt (part du cache), généré, prefill et décode t/s, plus PASS et temps mur, médianes sur les passes |
| `--bench-load [modèle\|all]` | Que coûte un modèle à la demande ? | restart du service, première requête chronométrée (chargement + premier token), puis TTFT à chaud |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | Ce réglage vaut-il mieux que celui-là ? | chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée au ini, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |
| `tools/bench-depth.sh <gguf>` | Et à 32k de contexte ? | `llama-bench -d`, hors service, prefill et décode à 0 / 16k / 32k par device, tour simulé par profondeur |
| `tools/bench-spec-batch.sh <gguf>` | Quelle longueur de draft n-gram le device amortit-il ? | `llama-bench -p`, courbe `t_forward(batch)`, marches de noyau, candidats sûr et large |

## Choix du device (--bench-devices)

Chaque modèle peut tourner sur Vulkan0 (défaut) ou ROCm0, et le meilleur
choix varie selon le modèle : ROCm est souvent devant en prefill, Vulkan en
décode. `--bench-devices` tranche automatiquement, sans édition manuelle :

```bash
./setup-llm.sh --bench-devices                          # choix interactif du modèle
./setup-llm.sh --bench-devices qwen3.8-27b-dflash-nothink  # modèle donné
./setup-llm.sh --bench-devices <modèle> Vulkan0,ROCm0 5 # devices et passes explicites
```

Déroulé : pour chaque device (croisé avec ceux réellement exposés par
`llama-bench --list-devices`, un backend absent est exclu), le script
régénère le ini avec le device forcé, redémarre le service par
`systemctl --user restart` (les modèles préchargés se rechargent, prévoir
la durée) et lance la même mesure que `--bench`. Le restart entre deux
devices garantit un cache froid : les prefills se comparent à conditions
égales. Une interruption en cours de route restaure la config non forcée.

Le verdict est le temps d'un tour d'usage simulé :

```
t(device) = 2000 tokens de prefill froid / prefill t/s + 3000 générés / décode t/s
```

Un seul scalaire tranche toujours, y compris quand un device gagne le
prefill et l'autre le décode. Exemple réel (qwen3.8-27b-mtp-nothink, 16/08/2026, avant son renommage
en qwen3.8-27b-dflash-nothink) :
ROCm0 gagne le prefill (356 contre 307 t/s) mais perd le décode (21,8
contre 29,9 t/s) ; en temps de tour, Vulkan0 fait 106,7 s contre 143,3 s
et l'emporte nettement. Le profil se surcharge à l'appel pour un usage
différent, par exemple `BENCH_PROFILE_PP=8000 BENCH_PROFILE_GEN=500` pour
du gros contexte à réponse courte. À moins de 2 % d'écart, le device par
défaut est conservé (pas de bascule sur du bruit de mesure).

Le vainqueur est écrit dans `bench-devices.conf` (clé = dossier du GGUF,
donc partagée entre les variantes d'un même fichier), le ini est régénéré
et le service redémarre sur la config retenue. Le fichier reste éditable à
la main pour forcer un choix. Formule, garde-fous et limites : section
dédiée dans ARCHITECTURE.md.

## Spéculation n-gram (--spec-ngram-tune)

Un `spec-type` peut être une liste (`ngram-map-k,draft-mtp`) : llama.cpp
essaie les implémentations dans son ordre de priorité (draftless d'abord) et
la première qui produit un draft gagne le pas de décode. `ngram-map-k`
construit sa table à partir du prompt entier : en édition agentic, où le
modèle recopie des blocs du fichier lu, un hit drafte jusqu'à `size_m`
tokens d'un coup, vérifiés dans un seul forward de batch `size_m + 1`.

Le bon `size_m` dépend donc de la forme de `t_forward(batch)` sur le device,
qui n'est pas une pente lisse : ggml change de noyau selon la taille du
batch (sur Vulkan, x2 entre batch 8 et 9, denses comme MoE). Les tailles
juste au-dessus d'une marche sont les pires. `--spec-ngram-tune` fait le
travail en deux temps :

1. courbe par `llama-bench`, service arrêté, balayage grossier puis
   raffinement automatique autour des sauts suspects ; sortie : un candidat
   « sûr » (sous la marche, ne peut pas perdre) et un « large » (amortit le
   coût fixe, gagne si les répétitions sont longues) ;
2. arbitrage réel : chaque candidat est écrit, le service redémarré, et
   `--spec-test` mesuré sur `prompts/spec-refactor.txt` (recopie de blocs
   exacts puis remplacement, la forme du oldString/newString d'opencode ;
   `spec-test.txt` écrit du neuf et ne produit aucun hit). Le gagnant va
   dans `spec-ngram.conf` ; à moins de 2 % d'écart, le plus petit.

Mesuré le 21/08/2026 sur Vulkan0 : les deux denses 27B d'alors, le Qwen3.8 Q4
et le Qwopus Q5 (retiré du parc depuis), retiennent 47 (+8 % et +16 % sur 7),
le 35B-A3B MoE retient 7 (sa pente sous la marche
est trop raide pour amortir un draft large). Un run en `spec-type` mixte est
journalisé mais exclu de la calibration α (k variable par forward) ; pour la
même raison `--spec-tune` mesure en `draft-mtp` seul le temps du réglage.

Pour explorer sans régler (autre GGUF, comparer ROCm0 et Vulkan0, modèle
sans MTP) : `tools/bench-spec-batch.sh` (voir Outils).

## Résultats mesurés (bigchuck)

Machine : AMD Ryzen AI MAX+ 395 (Radeon 8060S, 124 Go de mémoire unifiée),
CachyOS. Moteur courant : fork **strix-0007bc6** depuis le 12/09/2026 (voir
« Moteur »), campagne `--bench` du parc entier les 12 et 13/09/2026, 3 passes,
Vulkan0. Les chiffres du paquet Arch (**b10433 / ggml 0.20.0** et
**b10548 / ggml 0.20.2** pour gpt-oss et Laguna, **b10566** pour ornith,
**b10809 / ggml 0.23.0** pour Flash-Next) restent entre parenthèses : ce sont
deux séries distinctes, qui ne se comparent pas à la décimale ; la colonne
build des journaux `logs/` fait foi. Les réglages de spéculation, les courbes
de batch, le cache de prompt et les temps de chargement des sections suivantes
datent des campagnes du paquet (21 au 28/08/2026) et n'ont pas été re-mesurés
sur le fork, sauf mention. Médianes hors première passe, 4 passes sauf
mention. Les lignes `spec-test.txt` (écriture d'un module
de zéro, meilleur cas MTP) et `spec-refactor.txt` (recopie de blocs exacts,
le cas n-gram) ne se comparent pas entre elles.

### Récapitulatif par modèle

| Modèle | GGUF | Device | Réglage retenu | Prefill t/s | Gen t/s | État |
|---|---|---|---|---|---|---|
| lfm2.5-2.6b | Q8_0 (2,7 Go) | Vulkan0 (mesuré) | parallel 4 | **3048** (2279 au paquet b10433) | **70,8** (67,7 au paquet ; 205 agrégés à 4 requêtes, x3,06) | fork strix-0007bc6, 13/09/2026 ; cache tour suivant 62 % ; chargement 0,5 s, TTFT 27 ms |
| qwen3.5-9b | UD-Q6_K_XL (8,2 Go) | Vulkan0 (mesuré) | parallel 4 | **971** (837 au paquet b10433) | **25,7** (25,7 au paquet ; 78,6 agrégés à 4, x3,06) | fork strix-0007bc6, 13/09/2026 ; cache 62 % ; chargement 1,9 s |
| ornith-1.5-35b-a3b | Q4_K_M (22 Go) | Vulkan0 (mesuré : ROCm0 931 / 57,6) | parallel 4, sans spéculation | **1129** (974 au paquet b10566) | **73,3** (70,7 au paquet ; 136,8 agrégés à 4, x1,93) | fork strix-0007bc6, 13/09/2026 ; cache 62 % ; remplace les trois Qwen3.6-35B-A3B le 28/08/2026 |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0 (mesuré) | **draft-dflash 7** (DFlash 2 z-lab, retenu le 13/09/2026 sur le fork ; spec-prefill essayé et retiré, cache de prompt à 0 %) | 215 au paquet b10433 (289 → 183 à 32k en llama-bench) ; pas de mesure fork sans spec-prefill | **24,5** (spec-test, +99 %) (12,1 sans spéculation ; --bench à refaire) | paquet b10433, 21/08/2026 (seul modèle non re-mesuré sur le fork) ; reasoning-budget 4096 (fork) ; spec-prefill lossy et incompatible avec le cache de prompt, perdant en agentic |
| qwen3.8-27b-dflash-nothink | idem | Vulkan0 (mesuré) | ngram-map-k 47 + **draft-dflash 7** (drafter DFlash 2 z-lab, 2,0 Go ; remplace la tête MTP le 13/09/2026 : le batch de vérification 8 se découpe en 4+4 et échappe au pire cas du découpage mat-vec) | **360** (261 au paquet b10433) | **à mesurer par `--bench`** sur ce réglage (26,6 acc. 0,59 en MTP n-max 6 ; 29,5 acc. 0,65 au paquet) ; **64,5** (refactor, acc. 0,67) et **35,9** (générique, acc. 0,70) en `--spec-ab` | fork strix-0007bc6, 13/09/2026 ; DFlash 2 bat la tête MTP sur les deux prompts (+12 % en refactor, +18 % en générique) et annule le retrait de décode du fork ; réglage non mesuré sur le paquet Arch ; chargement 4,4 s |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go) | Vulkan0 (mesuré) | ngram-map-k 7 | **205** (110 au paquet b10433) | **19,9** (acc. 0,65 ; 12,3 au paquet) | fork strix-0007bc6, 13/09/2026, plus gros gain de décode du parc (+62 %) ; ROCm0 inutilisable (b10433) ; cache 99 % (attention pure) ; reasoning-budget 6144 (fork) |
| qwen3-coder-next | UD-Q4_K_XL (47 Go) | Vulkan0 (mesuré, ROCm0 exclu) | ngram-map-k 47 (compromis : +47 % refactor, -5 % générique) | **763** (468 au paquet b10433) | **48,7** (bench, acc. 0,27 ; 43,7 au paquet) ; 68,7 (refactor, paquet) | fork strix-0007bc6, 13/09/2026 ; ROCm0 répond « LAMPAMPAMP… » ; cache 64 % ; chargement 72 s depuis le disque |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE) | Vulkan0 (mesuré : ROCm0 219 / 31,5, juste lent) | ngram-map-k 7 | **599** (333 au paquet b10548) | **52,9** (bench, acc. 0,57 ; 51,9 au paquet) ; 59,8 (refactor, paquet) | fork strix-0007bc6, 13/09/2026 ; cache 99 % (attention, pas d'état récurrent) ; chargement 91 s depuis le disque |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 (mesuré : ROCm0 320 / 23,6) | **ngram-map-k 7** seul (draft-dflash refusé par le mainline `wrong number of tensors; expected 76, got 69` **et** par le fork le 12/09/2026 : `failed to load draft model`) | **346** (255 au paquet b10548) | **29,6** (bench, acc. 0,80 ; 30,3 acc. 0,835 au paquet) ; 53,0 (refactor, +85 %, paquet) | fork strix-0007bc6, 13/09/2026 ; cache 99 % ; chargement 67 s depuis le disque |
| qwen3.8-flash-next-mtp-nothink | UD-IQ4_XS (94 Go, MoE, GDN) | Vulkan0 (mesuré, ROCm0 exclu) | **ngram-map-k 7** + **draft-mtp 4** (confirmé, k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7) sur le fork (sidecar autonome Q8_0 renommé par `tools/mtp-rename-hc-head.py` ; le mainline ne sait toujours pas le charger, PR #28243) | **383** (414 en n-gram seul sur le fork ; 197 au paquet b10809) | **50,0** (bench mixte, acc. 0,87 ; 30,9 en n-gram seul sur le fork, 25,9 au paquet) ; **54,0** (refactor, +115 %) | fork strix-0007bc6, 12/09/2026 (le MTP n'existe pas sur le paquet) ; ROCm0 répond « LAMPAMPAMP… » ; cache 62 % ; chargement 14 s (cache de pages chaud) |

Prefill et Gen : valeur du fork strix-0007bc6 en gras, valeur du paquet Arch
entre parenthèses. Médianes hors première passe ; « cache » = part du prompt
servie du cache pour tour suivant / édition au milieu / requête identique.
Détail et écarts en pourcentage ci-dessous.

Historique du parc : qwen3.8-27b-mtp-nothink renommé qwen3.8-27b-dflash-nothink
le 13/09/2026 : tête MTP remplacée par le drafter DFlash 2. Le même jour,
qwopus3.6-27b-coder-mtp-nothink a été retiré, plus utilisé ; ses mesures
restent dans `logs/`. Avant lui, les trois Qwen3.6-35B-A3B ont été remplacés
par ornith-1.5-35b-a3b le 28/08/2026.

### Paquet Arch contre fork : mesures

Protocole `--bench` du dépôt (prefill de la passe 1 à froid, décode médian des
passes suivantes, acceptance médiane), sauf mention. Colonne « paquet » :
dernière valeur de la série `bNNNNN` dans `logs/bench.log` pour ce modèle.
Colonne « fork » : campagne `--bench` 3 passes, Vulkan0, `strix-0007bc6`, les
12 et 13/09/2026, parc entier.

| Modèle | Paquet (prefill / gen) | Fork strix-0007bc6 (prefill / gen) | Écart prefill | Écart gen | Note |
|---|---|---|---|---|---|
| lfm2.5-2.6b | 2279 / 67,7 (b10433, 21/08) | 3048 / 70,8 (13/09) | +33,7 % | +4,6 % | bench.log du 02/09 (b10621) donnait déjà 2743 / 69,4 : l'essentiel de l'écart de prefill vient du build, pas du fork (+11 % sur cette base) |
| qwen3.5-9b | 837 / 25,7 (b10433, 21/08) | 971 / 25,7 (13/09) | +16,0 % | 0 % | décode identique au dixième ; bench.log 02/09 (b10621) 25,59, prefill inexploitable (67, contaminé par le cache) |
| ornith-1.5-35b-a3b | 974 / 70,7 (b10566, 28/08) | 1129 / 73,3 (13/09) | +15,9 % | +3,7 % | sans spéculation des deux côtés |
| qwen3.8-27b (thinking) | 215 / 12,1 (b10433, 21/08) | réglage différent : draft-dflash 7, spec-test 24,5 t/s acc. 0,42 contre 12,3 sans (13/09) ; --bench à refaire | n/a | +99 % (spec-test) | seule mesure fork disponible : 759 / 12,2 le 12/09 à 23:15, mais avec `spec-prefill-p` 0,30, option retirée depuis (cache de prompt à 0 %) ; bench.log 02/09 (b10621) : 239 / 12,13 |
| qwen3.8-27b-dflash-nothink | 261 / 29,5 / acc. 0,65 (b10433, 21/08) | 360 / 26,6 / acc. 0,59 (13/09, ancien réglage MTP n-max 6) | +37,9 % | -9,8 % en MTP, **réglage changé depuis** | le seul écart de décode négatif du parc **s'expliquait** par le découpage des mat-vec batchés du fork (colonnes 4/2/1, restreint à q8_0 et q6_K par sa PR #27 ; le UD-Q4_K_XL porte 110 tenseurs q8_0 et 56 q6_K), à son pire cas au batch de vérification 7 = n-max 6 + 1, découpé en 4+2+1. llama-bench du 13/09 (Vulkan0, `-b 8 -ub 8 -r 3`) : pp7 68,9 t/s contre 74,4 avec `GGML_VK_MMV_NO_SPLIT=1` et 74,5 au paquet b10809 (-7,4 %), pp5 54,2 contre 56,9 (-4,7 %), pp4 47,8 contre 47,7 (aucune pénalité). Le réglage du fork n'est plus celui du paquet : **ngram 47 + draft-dflash n-max 7** (drafter DFlash 2 z-lab), qui bat la tête MTP sur les deux prompts en `--spec-ab` du 13/09 (4 passes, décode médian hors 1re passe). Sur spec-refactor.txt : 64,5 t/s acc. 0,67 contre 57,6 / 0,71 en MTP n-max 4 et 53,8 / 0,67 en n-max 6 ; spec-test.txt : 35,9 / 0,70 contre 30,5 / 0,65 en MTP n-max 4 (draft-dflash seul : 47,0 / 0,96 en refactor, 37,0 / 0,77 en générique). Le batch de vérification vaut alors 8, découpé en 4+4 : le pire cas du découpage est contourné. `--bench` sur ce réglage à venir, les 26,6 t/s ci-contre valent pour l'ancien MTP |
| qwen3.8-flash-next-mtp-nothink | 197 / 25,9 / acc. 0,75 (b10809, 05/09) | 414 / 30,9 / acc. 0,80 en n-gram seul avec `ngram-on-disk` (12/09) | +110,2 % | +19,3 % | à réglage égal (n-gram seul) ; sur spec-refactor.txt le paquet fait 54,0 en n-gram seul |
| qwen3.8-flash-next-mtp-nothink (n-gram + draft-mtp 4) | impossible sur le paquet | 383 / 50,0 / acc. 0,87 (12/09) | +94,4 % contre le paquet en n-gram seul | +93,1 % contre le paquet en n-gram seul | le MTP n'existe pas sur le paquet (sidecar refusé) ; `--spec-tune` draft-mtp seul k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7 ; `--spec-test` mixte 48,8 acc. 0,86 |
| qwen3-coder-next | 468 / 43,7 (b10433, 21/08) | 763 / 48,7 / acc. 0,27 (13/09) | +63,0 % | +11,4 % | acceptance n-gram inchangée (0,29 au paquet) : le gain vient du moteur, pas de la spéculation |
| gpt-oss | 333 / 51,9 (b10548, 21/08) | 599 / 52,9 / acc. 0,57 (13/09) | +79,9 % | +1,9 % | décode neutre ; le fork journalise une acceptance n-gram là où le paquet n'en donnait pas |
| laguna-s-2.1 | 255 / 30,3 / acc. 0,835 (b10548, 21/08) | 346 / 29,6 / acc. 0,80 (13/09) | +35,7 % | -2,3 % | dans le bruit de mesure ; DFlash refusé par le fork comme par le paquet (12/09) |
| deepseek-v4-flash | 110 / 12,3 (b10433, 21/08) | 205 / 19,9 / acc. 0,65 (13/09) | +86,4 % | +61,8 % | plus gros gain de décode du parc ; reasoning-budget 6144 posé au passage (seuil non atteint sur le test fait) |

Deux valeurs de la colonne paquet diffèrent au chiffre près de la table du parc
d'origine, qui arrondissait un autre run du même jour : qwen3-coder-next 468 au
lieu de 457, laguna-s-2.1 255 au lieu de 247. C'est `logs/bench.log` qui fait foi.

Bilan. Le fork gagne le prefill sur tout le parc, de +16 % (qwen3.5-9b,
ornith) à +86 % (DeepSeek V4), et gagne nettement le décode partout où la
spéculation change de régime : DeepSeek +62 %, qwen3-coder-next +12 %, et
Qwen3.8-Flash-Next dont le MTP n'existe tout simplement pas sur le paquet
(50,0 t/s contre 25,9, +93 %). Ailleurs il est neutre : le décode des petits
modèles, de gpt-oss et de Laguna bouge de moins de 5 % dans un sens ou dans
l'autre, soit la dispersion normale des passes. Le seul écart négatif était le
27B en `--bench` (-10 %, acceptance 0,59 contre 0,65) : ce n'était pas de la
dispersion, mais le découpage mat-vec du fork au batch de vérification 7. Il
passe au gain net avec le drafter DFlash 2 en n-max 7, qui bat la tête MTP de
+12 % en refactor (64,5 contre 57,6 t/s) et de +18 % en générique (35,9 contre
30,5) et dont le batch de vérification 8 se découpe en 4+4, hors du pire cas.
Le fork ne perd donc nulle part, et il apporte le sidecar MTP de Flash-Next et
les clés que le paquet ne sait pas charger.

Trois mesures du fork n'entrent pas dans le tableau. Le draft adaptatif
(`spec-draft-adaptive`) rend 2 % de moins que le draft fixe sur les deux 27B MTP
d'alors, qwen3.8-27b-mtp-nothink et le qwopus depuis retiré
(`--spec-ab` du 12/09), il n'est pas retenu. Le speculative prefill sur
qwen3.8-27b passe la boucle agentic (`--bench-agentic` 11/11 PASS, prefill
345 t/s) mais met `--bench-cache` à 0 % même sur requête identique : retiré.
Côté mémoire, `ngram-on-disk` charge Qwen3.8-Flash-Next en 72 Go en instance
seule (79 Go via le routeur, avec lfm2.5 et le sidecar MTP) au lieu d'environ
100, à prefill et décode inchangés.

**⚠ OOM du noyau pendant `--bench all`.** Le routeur a été tué deux fois par
l'OOM killer pendant la campagne du 13/09, à chaque fois au chargement d'un
géant alors qu'un autre était encore résident : Laguna (73 Go) chargé pendant
que gpt-oss (59 Go) tenait encore la mémoire, puis DeepSeek (104 Go) chargé
après avoir évincé lfm2.5 (le LRU) au lieu de Laguna. `--models-max 2`
(préchargé + 1) autorise cette somme, et la politique LRU ne connaît pas la
taille des modèles. Le service se relance seul (`Restart=on-failure`) et la
mesure en cours est perdue. Pour un `--bench all` ou toute suite de gros
modèles : décharger explicitement le précédent par le `POST /models/unload`
du routeur, ou ordonner la suite du plus petit au plus gros.

Les deux séries ne se comparent pas à la décimale : builds et jours différents,
et les passes MTP sont dispersées. Détail des runs dans `logs/bench.log` et
`logs/spec-tests.log` sur bigchuck.

### Spéculation

| Modèle | GGUF | Device | Configuration | Gen t/s | Acceptance | Prompt |
|---|---|---|---|---|---|---|
| qwen3.8-27b-dflash-nothink | UD-Q4_K_XL (17 Go) | Vulkan0 | draft-mtp n-max 2 | 26,8 | 0,95 | spec-test |
| | | | draft-mtp n-max 4 | 31,8 | 0,85 | spec-test |
| | | | draft-mtp n-max 6 (retenu par --spec-tune au paquet) | 33,1 | 0,75 | spec-test |
| | | | ngram-map-k 7 + mtp 4 | 44,0 | 0,94 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 47,4 | 0,73 | spec-refactor |
| | | | ngram-map-k 47 + mtp 6 (retenu au paquet) | 56,1 | 0,80 | spec-refactor |
| | | ROCm0 (15/08) | draft-mtp n-max 2 / 4 / 6 | 22,2 / 25,5 / 26,0 | | spec-test |
| | | Vulkan0, fork (13/09) | ngram-map-k 47 + mtp 6 | 54,1 | 0,668 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 (retenu jusqu'au 13/09) | 57,8 | 0,712 | spec-refactor : +6,8 %, le batch de vérification à 5 échappe au découpage mat-vec 4+2+1 |
| | | Vulkan0, fork (13/09), drafter DFlash 2 | ngram-map-k 47 + mtp 6 / mtp 4 | 53,8 / 57,6 | 0,67 / 0,71 | spec-refactor, série `--spec-ab` du réglage DFlash (référence MTP) |
| | | | **ngram-map-k 47 + draft-dflash 7** (retenu) | **64,5** | 0,67 | spec-refactor : +12 % contre le meilleur MTP ; batch de vérification 8 découpé en 4+4, hors du pire cas du découpage mat-vec |
| | | | draft-dflash 7 seul | 47,0 | 0,96 | spec-refactor : acceptance quasi parfaite, mais sans les hits n-gram |
| | | | ngram-map-k 47 + mtp 4 / draft-mtp seul | 30,5 / 29,7 | 0,65 / 0,74 | spec-test : référence MTP en générique |
| | | | **ngram-map-k 47 + draft-dflash 7** (retenu) | **35,9** | 0,70 | spec-test : +18 % contre le MTP |
| | | | draft-dflash 7 seul | 37,0 | 0,77 | spec-test : 3 % devant la liste en générique pur (peu de hits n-gram), la liste est gardée pour le régime agentic |
| qwen3.6-35b-a3b-mtp-nothink (retiré le 28/08/2026) | UD-Q4_K_XL (MoE) | Vulkan0 | ngram-map-k 7 + mtp 4 | 110,3 | 0,93 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 105,3 | 0,71 | spec-refactor |
| qwen3-coder-next | UD-Q4_K_XL (MoE, GDN) | Vulkan0 | sans spéculation | 46,8 | | spec-refactor |
| | | | ngram-map-k 7 | 20,8 | 0,98 | spec-refactor : surcoût fixe par pas spéculatif, un petit draft ne l'amortit pas |
| | | | **ngram-map-k 47** (retenu) | **68,7** | | spec-refactor |
| | | | ngram-map-k 47 | 44,5 (min-hits 4 : 44,8) | 0,23 | spec-test : -5 % sans répétitions |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE, SWA) | Vulkan0 | sans spéculation | 51,7 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **59,8** | | spec-refactor |
| | | | ngram-map-k 47 | 52,7 | | spec-refactor : le grand draft paie son batch x14,7 |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 | sans spéculation | 28,7 | | spec-refactor (b10548) |
| | | | **ngram-map-k 7** (retenu) | **53,0** | | spec-refactor : +85 %, le plus gros gain n-gram mesuré |
| | | | ngram-map-k 47 | 39,9 | | spec-refactor |
| | | | draft-dflash (n-max 15 ou 7) | échec | | mainline b10548 : refuse le drafter, 69 tenseurs créés au lieu des 76 du fichier |
| | | | ngram-map-k 7 + draft-dflash 7 | échec | | fork strix-0007bc6 (12/09/2026) : il revendique DFlash, mais son loader ne crée toujours aucun `attn_gate` — `common_speculative_init_result: failed to load draft model`, retour au n-gram seul |
| qwen3.8-flash-next-mtp-nothink | UD-IQ4_XS (94 Go, MoE, GDN) | Vulkan0 | sans spéculation | 25,1 | | spec-refactor (b10809, 05/09/2026) |
| | | | **ngram-map-k 7** (retenu) | **54,0** | 0,95 | spec-refactor : +115 %, le petit draft gagne malgré la famille GDN + MoE |
| | | | ngram-map-k 47 | 48,2 | 0,86 | spec-refactor : une passe sur quatre illisible (seed 44), reproductible |
| | | | **ngram-map-k 7 + draft-mtp 4** (retenu) | **50,0** | 0,87 | fork strix-0007bc6, sidecar autonome Q8_0 (4,1 Go) renommé par `tools/mtp-rename-hc-head.py` ; --bench du 12/09/2026 : prefill 383 t/s, contre 414 / 30,9 en n-gram seul sur le même fork (+62 % de décode, -7 % de prefill) ; --spec-test 4 passes : 48,8 t/s, acceptance 0,86 |
| | | | draft-mtp seul, n-max 2 / 4 / 6 / 8 | 43,0 / **50,7** / 49,5 / 32,7 | 0,95 / 0,90 / 0,84 / 0,80 | --spec-tune du 12/09/2026 (spec-test.txt, 4 passes) : n-max 4 retenu (spec-nmax.conf) ; la chute à 8 est la marche de la courbe entre les batchs 8 et 9 |
| | | ROCm0 | sans spéculation | **charabia**, exclu | | bench-devices, question de contrôle |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go, MoE) | Vulkan0 | sans spéculation | 11,3 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **12,3** | 0,9 sur les hits | spec-refactor |
| | | | ngram-map-k 31 | 11,8 | 0,27 à 0,66 | spec-refactor |
| | | ROCm0 | sans spéculation | ~550 (**charabia**, exclu) | | bench |

Prefill (passe 1, cache froid) : 27B ~220 t/s sur spec-test, ~275 t/s sur
spec-refactor ; 35B-A3B ~865 t/s ; DeepSeek 108 à 120 t/s (Vulkan0).

### Courbes de batch

Sur Vulkan0 (`tools/bench-spec-batch.sh`, reps=5) :

| GGUF | batch 1 | batch 8 | batch 9 | batch 48 | Lecture |
|---|---|---|---|---|---|
| Qwen3.8-27B Q4 | 83 ms | 101 ms | 215 ms | 283 ms | marche x2,13 entre 8 et 9, plateau jusqu'à 16 |
| Qwopus3.6-27B Q5 (retiré le 13/09/2026) | 89 ms | 106 ms | 257 ms | 310 ms | marche x2,42 |
| Qwen3.6-35B-A3B Q4 (MoE) | 17 ms | 33 ms | 68 ms | 136 ms | marche x2,06, mais pente raide sous la marche (batch 8 = 1,9x) |
| DeepSeek-V4-Flash IQ3 (MoE) | 83 ms | 302 ms | | 1087 ms | pas de marche, x3,6 dès le batch 8 : la courbe disait « non », la mesure a dit +9 % |
| Qwen3-Coder-Next Q4 (MoE, GDN) | 21 ms | 46 ms | marche | 199 ms | x2,16 au batch 8 ; en réel, surcoût fixe par pas spéculatif, seul 47 gagne |
| gpt-oss-120b Q4 (MoE, SWA) | 17 ms | 57 ms | | 246 ms | x3,4 au batch 8, x14,7 au batch 48 ; en réel size_m 7 = +16 % |
| Laguna-S-2.1 Q4 (MoE) | 33 ms | 95 ms | | 540 ms | x2,9 au batch 8, x16,5 au batch 48 ; en réel size_m 7 = +85 % |
| Qwen3.8-Flash-Next IQ4 (MoE, GDN) | 41 ms | 94 ms | 238 ms | 515 ms | marche x2,5 entre 8 et 9, x12,6 au batch 48 ; en réel size_m 7 = +115 % (b10809) |

### Profondeur de contexte

`tools/bench-depth.sh`, 27B Q4, KV q8_0, sans spéculation, reps=2 :

| Device | depth 0 | depth 16k | depth 32k | Tour simulé 0 → 32k |
|---|---|---|---|---|
| Vulkan0 | 289 pp / 12,25 tg | 222 / 11,83 | 183 / 11,50 | 252 s → 272 s (x1,08) |
| ROCm0 | 352 pp / 11,97 tg | 263 / 10,73 | 214 / 9,54 | 256 s → 324 s (x1,26) |

ROCm0 prefill plus vite à vide mais décode moins bien, et se dégrade deux
fois plus vite en profondeur : Vulkan0 gagne à toutes les profondeurs sur ce
GGUF, et l'écart se creuse en contexte long (le régime agentic).

### Concurrence, cache de prompt, chargement

`--bench-parallel`, spec-test.txt, 400 tokens, 2 salves :

| Modèle | parallel | 1 requête | 4 requêtes | Lecture |
|---|---|---|---|---|
| qwen3.5-9b | 4 | 25,7 t/s | 78,6 t/s agrégés (x3,06), 20,1 t/s par requête | le `parallel 4` des tâches auxiliaires est justifié |
| lfm2.5-2.6b | 4 | 67,4 t/s | 205 t/s agrégés (x3,06), 52 t/s par requête | idem |
| ornith-1.5-35b-a3b | 4 | 70,7 t/s | 136,8 t/s agrégés à 4 (x1,93), 35 t/s par requête | le MoE s'amortit moins bien qu'un dense : chaque requête route ses propres experts (le Qwen3.6 qu'il remplace faisait x1,43 à 2) |

### Boucle agentic réelle (--bench-agentic)

pi 0.84.3 en conteneur, appel froid puis 3 passes de 5 scénarios de tool calls en direct sur `:8009`, médianes, bigchuck, b10566, 28/08/2026 :

| Modèle | Verdict | Scénario | Mur | Prompt (part du cache) | Généré | Prefill | Décode |
|---|---|---|---|---|---|---|---|
| ornith-1.5-35b-a3b | 16/16 | froid (prompt système de pi) | 1,5 s | 1 523 tok (66 %) | 2 | 820 t/s | n/s |
| | 3/3 | write+bash+read | 2,8 s | 4 833 tok (98 %) | 133 | 228 t/s | 72,3 t/s |
| | 3/3 | edit | 4,1 s | 6 605 tok (91 %) | 181 | 518 t/s | 71,0 t/s |
| | 3/3 | création module + tests | 11,0 s | 5 876 tok (89 %) | 666 | 525 t/s | 70,9 t/s |
| | 3/3 | bug sans toucher au test | 7,2 s | 9 447 tok (91 %) | 361 | 508 t/s | 71,0 t/s |

Lecture : le décode en boucle d'outils (71 t/s) rejoint le `--bench` (70,7) ; le cache sert 89 à 98 % tant que la conversation ne fait que s'allonger, et le préfixe de pi survit d'un conteneur à l'autre (cache-ram). La variance est celle du modèle : le scénario 5 a pris 18 s (1 069 tokens, trois tours) sur une passe et 7 s sur les deux autres ; le tout premier run du jour l'avait fait en 49 s et 65 k tokens de prompt cumulés (28 % repayés, décode apparent 8 t/s : le coût GDN quand les tours s'enchaînent).

### Réglages n-gram alternatifs

`--spec-ab`, 27B, n-max 6, spec-refactor.txt, 4 passes :

| Variante | Gen t/s | Acceptance | Lecture |
|---|---|---|---|
| base (ngram-map-k 47, min-hits 2, draft-mtp 6) | **56,1** | 0,80 | +18 % sur le même réglage n-gram avec n-max 4 (47,4) : le n-max 6 profite aussi au mode mixte |
| min-hits 1 | 55,8 | 0,80 | équivalent, 2 gardé |
| ngram-map-k4v 47, min-hits 2 | 44,9 | 0,91 | -20 % : drafte moins souvent malgré une meilleure acceptance |

`--bench-cache`, bench-context.txt ~1370 tokens :

| Modèle | Architecture | Tour suivant | Édition au 1er tiers | Requête identique |
|---|---|---|---|---|
| qwen3.5-9b | hybride SWA/GDN | 62 % (847 tok) | 0 % | 63 % (861 tok) |
| ornith-1.5-35b-a3b | GDN, MoE | 62 % (883 tok) | 0 % | 64 % (897 tok) |
| lfm2.5-2.6b | conv récurrente (autre tokenizer) | 62 % (864 tok) | 0 % | 63 % (876 tok) |
| qwen3-coder-next | GDN, MoE | 64 % (962 tok) | 0 % | 66 % (978 tok) |
| qwen3.8-flash-next-mtp-nothink | GDN, MoE | 62 % (883 tok) | 0 % | 64 % (897 tok) |
| **deepseek-v4-flash** | **attention pure (MLA)** | **99 %** | **0 %** | **100 %** |
| **gpt-oss** | **attention + SWA, MoE** | **99 %** | **4 %** | **100 %** |
| **laguna-s-2.1** | **attention SWA + globale, MoE** | **99 %** | **2 %** | **100 %** |

Deux enseignements. DeepSeek et gpt-oss tranchent le premier : les
architectures à état récurrent (GDN, conv) ne restaurent leur état qu'à un
checkpoint, pas au token près, et repaient ~37 % du prompt même sur une
requête identique ; sans état récurrent (attention pure, SWA comprise) tout
est servi. Le second vaut
pour tous : une édition en amont du prompt, même avec 2/3 de préfixe commun
(au-dessus du seuil `slot-prompt-similarity 0.5`), donne **0 %** partout,
attention pure comprise. Le cache de prompt du serveur ne sert que les
**continuations** (le prompt en cache doit être un préfixe exact du nouveau) ;
toute modification en amont repaie tout le contexte. En boucle agentic, cela
signifie : ne jamais réécrire l'historique (compaction, tronquage de
résultats d'outils) si on tient au cache.

`--bench-load`, restart puis première requête. Le chiffre dépend d'abord de
l'état du cache de pages du noyau : fichier chaud (benché à l'instant) ou
relu depuis le disque.

| Modèle | Taille | Chargement + 1er token | TTFT à chaud | État du cache de pages |
|---|---|---|---|---|
| lfm2.5-2.6b | 2,7 Go | 0,5 s | 27 ms | chaud |
| qwen3.5-9b | 8,2 Go | 1,9 s | 65 ms | chaud |
| qwen3.8-27b | 17 Go | 4,4 s | 165 ms | chaud (~4 Go/s) |
| qwen3-coder-next | 47 Go | 72 s | 406 ms | disque |
| gpt-oss | 59 Go | 91 s | 86 ms | disque |
| laguna-s-2.1 | 69 Go | 67 s | 173 ms | disque |
| qwen3.8-flash-next-mtp-nothink | 88 Go | 14,1 s | 86 ms | chaud (après la campagne de mesures) |

Une bascule LRU entre modèles moyens coûte quelques secondes si le fichier
est encore en cache de pages, une minute et plus s'il a été évincé (les
104 Go de DeepSeek évincent tout le reste).

### Enseignements

Sur Qwen3-Coder-Next (GDN + MoE), chaque pas spéculatif porte un surcoût
fixe de plusieurs centaines de millisecondes (état récurrent à sauvegarder et
restaurer) : un petit draft divise le débit par deux malgré 98 % d'acceptance,
seul un grand draft l'amortit, et le gain en refactor (+47 %) se paie en
génération générique (-5 %). Le « régime sûr » n'existe pas sur cette arch.

La marche Vulkan 8→9 (`mul_mat_vec_max_cols = 8`) vaut pour
les denses comme pour les MoE ; le régime large (47) gagne sur les denses,
le régime sûr (7) sur les MoE ; l'optimum du n-max MTP dépend du device
(4 sur ROCm0, 6 sur Vulkan0 pour le même GGUF) ; ROCm0 est inutilisable sur
DeepSeek V4 avec ce build (sortie dégénérée silencieuse, détectée depuis par
le garde-fou de `timings.py`).

## Fichiers de configuration

À côté du script, locaux et non versionnés (propres à la machine) :

| Fichier | Rôle |
|---|---|
| `bench-devices.conf` | clé (dossier GGUF) = device (Vulkan0/ROCm0), écrit par `--bench-devices`, édition manuelle OK |
| `preload.conf` | modèles préchargés, un par ligne |
| `spec-nmax.conf` | modèle = spec-draft-n-max retenu par les mesures |
| `spec-ngram.conf` | modèle = spec-ngram-map-k-size-m retenu par les mesures |
| `logs/spec-tests.log` | journal TSV des runs `--spec-test` |
| `logs/bench.log` | journal TSV des `--bench` (avec le build llama.cpp) ; chaque `--bench` se compare au run précédent du même modèle/GGUF/device et signale un écart de plus de 5 % |
| `logs/bench-parallel.log` | journal TSV des `--bench-parallel` |
| `logs/bench-agentic.log` | journal TSV des `--bench-agentic` (une ligne par scénario) |
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
top-p            = 0.8
min-p            = 0.0
parallel         = 4"
```

- `download_hf <dossier> <repo> VAR=<fichier>` déclare le fichier (chemin,
  inventaire pour `--cleanup`, téléchargement) ; pour un modèle en shards,
  `download_hf_shards` avec le shard 00001 et son sous-dossier de quant.
- `derive_gguf <dossier> VAR=<fichier> <source> <script>` déclare un GGUF
  **produit en local** à partir d'un fichier déjà déclaré (aucun repo ne le
  porte) : même inventaire `--cleanup`, et `--setup` lance le script après les
  téléchargements si le fichier manque ou si la source a bougé. Unique cas :
  le sidecar MTP de Qwen3.8-Flash-Next renommé pour le fork.
- `llama_model <section> "<corps ini>"` déclare la section ; deux sections
  peuvent partager le même `*_PATH` (cas Qwen3.8-27B, thinking et MTP).
- `groupe "; --- titre ---"` avant le premier `llama_model` d'une nouvelle
  famille, pour l'en-tête dans le ini.
- Variante MTP : nommer la section `<clé>-mtp`, les garde-fous de
  préchargement en dérivent.

Ensuite, pour choisir le device et régler la spéculation : la procédure
d'`AGENTS.md` (skill `ajout-modele`).

## Outils (tools/)

| Fichier | Rôle |
|---|---|
| `opencode-sync-model.sh` | Synchronise la liste des modèles du serveur (`/v1/models`) dans la config opencode (`~/.config/opencode/opencode.json`, provider `llamaswap`). Variables : `ENDPOINT`, `CONFIG`, `PROVIDER` |
| `bench-spec-batch.sh` | Courbe brute `t_forward(batch)` d'un ou plusieurs GGUF par `llama-bench`, hors service, sur un ou plusieurs devices (`DEV=Vulkan0,ROCm0`, `BATCHES`, `REPS`, `DEPTH`, `FA`). Analyse par `py/batch_curve.py`, journal `spec-batch.log` + `spec-batch.tsv`. Pour régler un modèle, préférer `--spec-ngram-tune` |
| `bench-depth.sh` | Prefill et décode selon la profondeur de contexte (`llama-bench -d`, défaut 0 / 16k / 32k, KV q8_0 comme le service), par device, avec le tour simulé de `--bench-devices` recalculé à chaque profondeur : c'est le régime agentic réel, où le classement des devices peut s'inverser. Journal `logs/bench-depth.log` + `.tsv` |
| `mtp-rename-hc-head.py` | Renomme les trois tenseurs du mixeur final des hyper-connexions d'un sidecar MTP Qwen3.8-Flash-Next (`blk.<n>.nextn.hc_head_*` chez unsloth, convention de la PR mainline #28243) vers les noms que lit le fork strix-llama.cpp (`output_hc_*`). Données recopiées telles quelles. `PYTHONPATH=$HOME/llm/strix-llama.cpp/gguf-py python3 tools/mtp-rename-hc-head.py <in> <out>` ; appelé aussi par `--setup`. Inutile sur un moteur mainline portant #28243 |
| `llm-proxy.ts` | Extension pi / omp : découvre les modèles `text-generation` du proxy Albert (`/v1/models`, ctx, coûts, reasoning déduit de l'id) et enregistre le provider `albert`. A copier dans `~/.pi/agent/extensions/` et `~/.omp/agent/extensions/` (une seule extension provider par agent). Endpoint `http://llmproxy` et clé en dur pour l'instant (à passer sur `process.env` avant diffusion) |

Les scripts shell pointent sur `http://bigchuck:8009` par défaut (surchargeable par variable d'environnement).

## FAQ

**Un modèle échoue au chargement, ROCm0 a disparu.**
`--list-devices` croise `bench-devices.conf` avec les devices réellement
exposés. Réinstaller `ggml-hip`, ou forcer Vulkan0 dans la conf puis `--preload`.

**Je peux éditer models.ini ?**
Non, il est régénéré à chaque `--setup`, `--preload` ou `--spec-*`.
Éditer les fichiers `.conf` ou `lib/models.sh`.

**Pourquoi `parallel = 1` sur les modèles MTP ?**
Contrainte llama.cpp : `-np` supérieur à 1 et `--mmproj` ne sont pas supportés
avec MTP. Un modèle non-MTP séparé sur le même GGUF rend le parallélisme.
