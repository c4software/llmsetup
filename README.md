# LLM Setup

LLM Setup pilote un `llama-server` en router mode natif sur une machine Strix Halo
(bigchuck : Ryzen AI Max+ 395, 124 Go unifiés, CachyOS/Arch), avec un seul point
d'entrée, `./setup-llm.sh`, et un moteur : une image ROCm construite
localement (`runtime/`), qui embarque
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) en HIP
seul. Depuis le 18/09/2026 c'est le SEUL moteur du dépôt, pour le service comme
pour les outils : le fork Vulkan installé sur l'hôte a été retiré.

Ce qu'il gère :

- téléchargement des GGUF depuis Hugging Face (`hf`, mises à jour par etags) ;
- génération de `~/models/models.ini` : les réglages de chaque modèle vivent
  dans `lib/models.sh` avec leurs justifications en commentaire ;
- préchargement always-on ou chargement à la demande (LRU) ;
- mesure des perfs par l'API du serveur (`--bench`, `--bench-sanity`) et
  réglage de la spéculation par mesure : drafter (`spec-draft-n-max`,
  calibration α) et n-gram (`spec-ngram-map-k-size-m`) ;
- construction et suivi du moteur (image), service en conteneur.

Le service tourne sur une image ROCm construite localement (`runtime/`), qui
n'expose qu'un device, `ROCm0` : depuis le 18/09/2026 il n'y a plus de choix de
backend, plus de `--bench-devices` et plus de `bench-devices.conf`. Les outils
hors service (`llama-bench` des courbes de batch, `llama-server` jetable de
`tools/spec-isolate.sh`) tournent dans la MÊME image, par `docker run`. Tout
est piloté par des fichiers de conf locaux à côté du script (non versionnés,
propres à la machine). Le `models.ini` est généré, jamais édité.

Historique et campagnes de mesure détaillées : [docs/HISTORIQUE.md](docs/HISTORIQUE.md).

## Prérequis

- Arch/CachyOS, `paru`, bash 4.3 ou plus, python3 (stdlib seule), curl.
- **docker et son démon activé au boot** (`systemctl enable --now docker`) :
  le service llama-server est un **conteneur**, décrit par
  `runtime/docker-compose.yml` et un `.env` généré dans `~/models`. Sans démon actif au boot, le
  service ne revient pas après un redémarrage de la machine - c'est `docker`
  qui remplace le `loginctl enable-linger` d'avant.
- `hf` (python-huggingface-hub, python-hf-xet). `gum` optionnel (menus).
- **Aucun paquet llama.cpp ni ggml sur l'hôte.** Depuis le 18/09/2026 le dépôt
  n'appelle plus aucun binaire `llama-*` de l'hôte : le service et les outils
  hors service tournent dans l'image, qui embarque son propre ROCm. `llama-cpp`,
  `ggml-cpu`, `ggml-vulkan`, `ggml-hip` et le runtime ROCm de l'hôte
  (`rocm-hip-runtime`, `hipblas`, `rocblas`, `hipblaslt`) ne sont plus ni
  requis ni installés par `--setup`. Le dépôt ne désinstalle rien : sur une
  machine qui les a déjà, les retirer à la main si la place manque
  (`paru -Rns llama-cpp ggml-cpu ggml-vulkan ggml-hip rocm-hip-runtime hipblas rocblas hipblaslt`).

## Installation

```bash
./setup-llm.sh --setup        # dépendances, GGUF, préchargement, models.ini + .env du service
./setup-llm.sh --image-build  # moteur conteneurisé (40 à 60 min à froid)
./setup-llm.sh --start        # monte le conteneur et ATTEND que /health réponde
```

Le service ensuite :

```bash
./setup-llm.sh --status            # docker compose ps + réponse de /health
./setup-llm.sh --logs -f           # journaux du conteneur
./setup-llm.sh --restart           # stop puis start (.env régénéré, conteneur recréé)
./setup-llm.sh --stop
```

À la main, sans passer par le dépôt (même conteneur, mêmes journaux) :

```bash
cd ~/models && docker compose ps
cd ~/models && docker compose logs -f
```

Le compose est **versionné** (`runtime/docker-compose.yml`) et lu tel quel par
docker. Tout ce qui varie d'une machine à l'autre y est une variable
obligatoire (`${VAR:?}`) : gid numériques de `render` et `video`, chemins
absolus, `--models-max`, tag de l'image. Ces valeurs vivent dans `~/models/.env`,
**généré** (`lib/compose.sh`) au même titre que `models.ini` : non versionné,
pas à éditer, réécrit par `--start` à chaque démarrage. Le `.env` porte aussi
`COMPOSE_FILE`, ce qui rend l'usage manuel possible depuis `~/models` sans
`-f`. Le compose fixe aussi `seccomp=unconfined` - **exigé par ROCr**, dont les ioctl du KFD sortent du profil seccomp par défaut de docker.
C'est le seul assouplissement, et il est compensé : `cap_drop: [ALL]`,
`no-new-privileges`, aucun `privileged`, aucun accès à `docker.sock`, `~/models`
monté en lecture seule et un seul volume inscriptible hors du parc
(`~/.local/state/llm-setup/cache`).

Étiquette des mesures : elle vient des `LABEL` de l'image servie et vaut
`strix-<engine7>+r<rocm7>` (colonne build des journaux). Chaque bump de l'image
ouvre une **nouvelle série** ; les séries ne se comparent pas
(cf. ARCHITECTURE.md, comparabilité des journaux).

## Moteur conteneurisé

Le moteur est une **image docker** construite par le dépôt : ROCm 10.0
gfx1151, un runtime ROCr/HIP retained-PM4 recompilé, et
`halo-box/strix-llama.cpp` construit en HIP seul. Le Dockerfile est vendorisé
dans `runtime/` depuis la PR 133 de
[`kyuz0/amd-strix-halo-toolboxes`](https://github.com/kyuz0/amd-strix-halo-toolboxes),
mergée le 18/09/2026 ; l'amont ne publie pas d'image pour ce Dockerfile, d'où
le build local. Provenance, écarts exacts et procédure de resynchronisation
dans [`runtime/AMONT.md`](runtime/AMONT.md).

Tout tient en **deux fichiers** : le Dockerfile vendorisé, qui porte les
révisions, et `runtime/docker-compose.yml`, dont le bloc `build` pointe sur
`runtime/` (par `RUNTIME_DIR` du `.env`). Il n'y a pas de couche au-dessus.

> ⚠ **C'est le moteur du service, et celui des outils hors service.**
> Construire ne redémarre rien : une image neuve n'est servie qu'au prochain
> `./setup-llm.sh --restart`, qui régénère le `.env` et recrée le conteneur.

```bash
./setup-llm.sh --image-build    # 40 à 60 min à froid
cd ~/models && docker compose build   # exactement la même chose, à la main
```

Ce qui tient l'ensemble :

- `runtime/Dockerfile.rocm-strix` (**versionné**) porte les **révisions
  épinglées** dans deux `ARG` (`ENGINE_REV`, `ROCM_SYSTEMS_REV`), avec en tête
  un bloc « Révisions épinglées » qui dit d'où elles viennent et comment les
  faire évoluer. Son historique git **est** le journal des révisions, et le
  retour arrière consiste à y remettre les anciennes valeurs, puis à
  reconstruire.
- **Un seul tag**, `llm-rocm-strix:latest` : une image se reconstruit en
  quelques minutes, on n'en collectionne pas. Ce qu'elle contient RÉELLEMENT se
  lit dans `/opt/strix/versions.txt`, dedans ; ce qui a été demandé se lit dans
  les `ARG` du Dockerfile, d'où vient aussi l'étiquette de toutes les mesures
  (`_llama_build`, forme `strix-<engine7>+r<rocm7>`).
- L'image ne contient **que le moteur et son runtime** : pas de modèle, pas de
  configuration, pas d'état. `~/models` est monté en lecture seule au même
  chemin absolu au moment de lancer un binaire.
- Après un build, l'image remplacée perd son tag. La retirer à la main par
  `docker image prune` (**sans `-a`**, qui toucherait aux images des autres
  outils de la machine.

**Une image = une série de mesures** : un changement de révision n'est pas
comparable à ce qui précède, d'où le bump à la main, commité avec sa raison.

## Sous-commandes

| Commande | Rôle |
|---|---|
| `--setup` | Installe les dépendances (curl, `hf`), vérifie docker (démon actif et activé au boot, utilisateur dans le groupe `docker`) et l'image du moteur, télécharge les GGUF manquants, sélectionne le préchargement, génère le ini |
| `--update [modèle]` | Comme `--setup`, mais laisse `hf` comparer les etags : seul ce qui a bougé est retéléchargé |
| `--cleanup [--yes]` | Supprime les dossiers et GGUF orphelins (dry-run par défaut) |
| `--preload` | Re-sélectionne les modèles always-on et régénère le ini |
| `--bench [modèle\|all] [n]` | Mesure le serveur tel qu'il tourne : prefill, décode médian, acceptance MTP, tableau récapitulatif. N'écrit rien ; avant de charger un modèle, décharge les plus gros modèles résidents si la RAM ne suffit pas (`BENCH_NO_UNLOAD=1` pour désactiver) |
| `--bench-parallel [modèle] [n] [passes]` | Débit sous `n` requêtes simultanées (défaut : le `parallel` du modèle) : agrégé et décode par requête contre 1 requête ; montre ce que vaut `parallel = N` et la file d'attente au-delà |
| `--bench-cache [modèle]` | Efficacité du cache de prompt sur le pattern agentic (contexte froid, tour suivant, édition au premier tiers, requête identique) : part du prompt servie du cache et prefill à chaque fois ; c'est la mesure de `cache-ram` / `ctx-checkpoints` / `cache-reuse` |
| `--bench-sanity [modèle\|all]` | Recopie exacte d'un code (`prompts/bench-sanity.txt`, trivial pour ne tester que le backend) : complète le garde-fou anti-charabia, qui n'attrape pas un texte propre et faux. Première étape, **bloquante**, de `tools/qualif-modele.sh` |
| `--bench-agentic [modèle] [passes] [N]` | Une vraie boucle de tool calls : pi (conteneur jetable, `bench-agentic/`) joue un appel froid (prompt système) puis N passes de 5 scénarios en direct sur llama-server ; par scénario PASS/passes et médianes (temps mur, prompt et part du cache, générés, prefill et décode t/s réels). 3e argument `N` > 1 : chaque passe joue la suite seule puis à `N` boucles pi **simultanées** (orchestrateur + sous-agents), avec le facteur de débit de tâches et le décode agrégé |
| `--bench-load [modèle\|all]` | Temps de chargement + premier token après restart, puis TTFT à chaud : ce que coûte un modèle à la demande (base pour `preload.conf` et `--models-max`) |
| `--image-build [--no-cache]` | Construit l'image du moteur **conteneurisé** (`runtime/`) sur les révisions épinglées dans les `ARG` de `runtime/Dockerfile.rocm-strix`. Raccourci vers `cd ~/models && docker compose build`, rien de plus. L'image remplacée perd son tag : `docker image prune` (sans `-a`) la retire, à la main. **C'est le moteur du service** : une image neuve n'est servie qu'au prochain `--restart` |
| `--list-devices` | Étiquette du moteur, puis les devices exposés par l'**image** ; alerte si `ROCm0` manque |
| `--spec-test [modèle] [n] [prompt]` | Décode réel via l'API (spéculation incluse), journalise, calibre et persiste le n-max dès 2 valeurs mesurées. Prompt par défaut `spec-test.txt` ; un autre prompt est journalisé à part et ne calibre pas |
| `--spec-tune [modèle] [k1,k2,..] [n]` | Boucle automatique sur plusieurs n-max avec restart entre chaque, retient le meilleur mesuré |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | A/B de réglages spéculatifs sur mesure réelle : chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |
| `--spec-ngram-tune [modèle] [n] [prompt]` | Règle la longueur de draft n-gram (`spec-ngram-map-k-size-m`) : courbe `t_forward(batch)` pour localiser la marche de noyau ggml, puis arbitrage des candidats sur mesure réelle (prompt de refactor par défaut) |
| `--start` | Démarre le service : `.env` régénéré dans `~/models`, conteneur recréé, puis **attente de `/health`** - la commande ne rend la main que quand le routeur répond sur le port 8009 |
| `--stop` | Arrête le conteneur (SIGINT, jusqu'à 180 s : le déchargement des préchargés est long) |
| `--restart` | `--stop` puis `--start`. Jamais `docker compose restart`, qui garderait l'ancienne image, l'ancienne ligne de commande et l'ancien `--models-max` |
| `--status` | `docker compose ps` et réponse de `/health` |
| `--logs [-f] [--tail N]` | Journaux du conteneur |
| `--migrate-off-systemd` | **Temporaire** : débranche l'ancienne unité systemd user (stop, disable, suppression, `daemon-reload`) et vérifie que le port 8009 est libre. Idempotente ; à jouer une fois avant le premier `--start` |
| `--help` | Aide, liste des modèles et des clés de téléchargement |

## Workflow typique

```bash
./setup-llm.sh --setup                # première mise en place
./setup-llm.sh --update               # 1. modèles (etags)
./setup-llm.sh --image-build          # 2. moteur du service, après un bump de
                                      #    révision dans le Dockerfile
./setup-llm.sh --restart              # 3. appliquer
./setup-llm.sh --bench all            # 4. perfs de tous les modèles présents : régressions
./setup-llm.sh --bench-sanity <m>     # le moteur répond-il juste ?
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
`logs/bench.log` avec le build et le mode d'alimentation de l'APU (colonne
`ec_mode`, lue sur le contrôleur embarqué : `balanced`, `performance`, ou
`inconnu` si le sysfs se tait, jamais bloquant), et comparé au run précédent du
même modèle, GGUF et device : un écart de plus de 5 % est signalé, le changement
de build rappelé. La référence est cherchée d'abord parmi les runs du même mode
EC ; à défaut, le dernier run sert quand même de référence avec la mention
« mode EC différent : X contre Y, écart non comparable ». Mesuré le 16/09/2026,
`balanced` coûte 10 à 13 % de décode (3 % sur un dense) : au-dessus du seuil de
5 %, il inventerait une régression à lui seul.

Comparabilité : les chiffres dépendent des prompts de `prompts/`. Modifier
`bench-context.txt` ou `bench-task.txt` invalide la comparaison avec les
tableaux antérieurs ; ne jamais les toucher au détour d'un autre changement.

**Garde mémoire et OOM.** Le routeur évince en LRU sans connaître la taille des
modèles : deux géants résidents suffisent à dépasser les 124 Go et l'OOM killer
prend le routeur (deux fois le 13/09/2026). Une garde mémoire précède donc
chaque chargement (`--bench`, `--bench-sanity`, `--bench-cache`,
`--bench-parallel`, `--spec-test`, `--spec-ab`) : taille estimée contre mémoire
disponible, puis déchargement par l'API des plus gros résidents, jamais un
préchargé tant qu'un autre peut partir, sans restart (`BENCH_NO_UNLOAD=1` la
désactive, `BENCH_ROOM_MARGE_PCT` change la marge).

Chaque mesure écrit son journal TSV dans `logs/` (avec le build) et se lit
seule ; la procédure d'ajout d'un modèle (`AGENTS.md`, skill `ajout-modele`) dit
laquelle lancer selon le rôle du modèle.

| Commande | Question à laquelle elle répond | Méthode |
|---|---|---|
| `--bench-sanity [modèle\|all]` | Le backend produit-il un texte juste ? | recopie exacte d'un code (`prompts/bench-sanity.txt`), trivial pour ne tester que le backend ; complète le garde-fou anti-charabia de `timings.py` (mot dominant, mots distincts, répétition périodique de caractères), qui ne voit pas un texte propre et faux |
| `--bench-parallel [modèle] [n] [passes]` | Que vaut `parallel = N` ? | salves de 1 puis n requêtes simultanées (spec-test.txt, 400 tokens), débit agrégé et décode médian par requête ; `parallel` réel lu sur `/v1/models`, au-delà les requêtes font la queue |
| `--bench-cache [modèle]` | Combien du prompt est repayé à chaque tour ? | quatre requêtes : contexte froid, tour suivant, édition au premier tiers (préfixe commun 2/3, au-dessus du seuil `slot-prompt-similarity 0.5`), requête identique ; part servie du cache (`cache_n`) et prefill |
| `--bench-agentic [modèle] [passes] [N]` | Que vaut le modèle en boucle agentic, seul puis à `N` boucles en même temps ? | pi dans un conteneur (`bench-agentic/`, réseau hôte) joue un appel froid puis N passes de 5 scénarios de tool calls en direct sur `:8009` ; delta de `/metrics?model=` par scénario : prompt (part du cache), généré, prefill et décode t/s, plus PASS et temps mur, médianes sur les passes. À `N` > 1, chaque passe est jouée seule puis par `N` conteneurs simultanés : facteur de débit de tâches `(N x solo) / parallèle`, décode agrégé lu sur `/metrics` autour de la salve |
| `--spec-test [modèle] [n] [prompt]` | Que rend la spéculation en décode réel ? | une requête par passe via l'API, décode et acceptance médians, journal `logs/spec-tests.log` et calibration du n-max dès 2 valeurs mesurées ; prompt par défaut `spec-test.txt`, un autre prompt est journalisé à part et ne calibre pas |
| `--bench-load [modèle\|all]` | Que coûte un modèle à la demande ? | restart du service, première requête chronométrée (chargement + premier token), puis TTFT à chaud |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | Ce réglage vaut-il mieux que celui-là ? | chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée au ini, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |

`--spec-ngram-tune` règle en mesurant : il cherche la longueur de draft n-gram
(courbe `t_forward(batch)` par `llama-bench` service arrêté, pour localiser la
marche de noyau ggml, puis arbitrage réel des candidats sur
`prompts/spec-refactor.txt`, écrit dans `spec-ngram.conf`). Depuis le
18/09/2026 cette courbe est tracée par le `llama-bench` de l'IMAGE, donc par le
moteur qui sert : les `size-m` retenus avant cette date l'ont été sur le fork
Vulkan et n'ont pas été re-tracés. Formules, garde-fous et limites :
ARCHITECTURE.md.
Méthodes détaillées et exemples mesurés : docs/HISTORIQUE.md.

## Parc au 18/09/2026, moteur conteneurisé ROCm0

Une ligne par section servie du `models.ini`, dans l'ordre d'émission. Toutes
les mesures viennent du `--bench` du dépôt, 3 passes, le 18/09/2026, sur la
série `strix-8c1c282+r7dda3ac` (moteur halo-box/strix-llama.cpp `8c1c282`,
runtime ROCr retained-PM4 `7dda3ac`), device `ROCm0`, mode EC `performance`.
Réglages communs à tout le parc, posés une fois dans les flags globaux :
`fit off`, `load-mode none`, cache K et V `f16`. Il n'y a plus de colonne
Device : l'image n'expose qu'un device, et plus aucune section ne déclare le
sien.

Lecture des colonnes : *micro-lot* = `ubatch-size` servi (le défaut du moteur
est 2048, une seule section en sort) ; *acceptance* vide = pas de spéculation ;
*cache long* = part du prompt restaurée au tour suivant sur un prompt de 20 000
tokens, la seule mesure de cache qui ait un sens ici (`--bench-cache` travaille
sur 1 400 tokens, cf. les règles apprises plus bas) ; *agentic* = score du
`--bench-agentic` du 18/09/2026, `n/j` = non joué ; la dernière colonne compare
au dernier `--bench` du même modèle sur l'ancien moteur (fork strix-0007bc6,
Vulkan0), deux séries distinctes, un ordre de grandeur, pas une comparaison à
la décimale.

| Modèle (section) | Quant et taille | Réglage spéculatif | Micro-lot | Prefill t/s | Décode t/s | Acceptance | Cache long | Agentic | Contre le fork Vulkan0 (prefill / décode) |
|---|---|---|---|---|---|---|---|---|---|
| ornith-1.5-9b-mtp-nothink | Q8_0, 9,79 Go (GGUF fusionné tiers protoLabsAI, tête MTP nextn distillée) | spec-type `ngram-map-k,draft-mtp`, size-m 7, min-hits 2, tête MTP embarquée, n-max 3, parallel 1 | 2048 | 1134 | 41,7 | 0,565 | 97 à 98 % | 14/16 | 828 / 39,5, soit +37 % et +5,6 % |
| ornith-1.5-35b-a3b-mtp | Q4_K_M, 21,7 Go (même GGUF) | spec-type `ngram-map-k,draft-mtp`, size-m 7, min-hits 2, tête MTP embarquée, n-max 4, parallel 1 | 2048 | 1306 | 75,9 | 0,615 | 97 % | 16/16 | 1073 / 76,2, soit +22 % et -0,4 % |
| lfm2.5-2.6b | Q8_0, 2,87 Go (+ drafter DSpark 0,36 Go) | spec-type `draft-dspark`, drafter DSpark officiel Liquid AI Q8_0, n-max 3, parallel 1 | 2048 | 3749 | 120,3 | 0,505 | 97 % | 16/16 | 2875 / 108,8, soit +30 % et +10,6 % |
| qwen3-coder-next | UD-Q4_K_XL, 47 Go (+ drafter DFlash 0,51 Go) | spec-type `draft-dflash`, drafter DFlash z-lab Q8_0 (conversion transmutator), n-max 7, parallel 1 | 2048 | 1022 | 56,0 | 0,515 | 97 % | 16/16 | 727 / 52,2, soit +41 % et +7,3 % |
| qwen3.8-27b-dflash-nothink | UD-Q4_K_XL, 17 Go (+ drafter DFlash 2 z-lab 2,0 Go) | spec-type `ngram-map-k,draft-dflash`, size-m 47, min-hits 2, n-max 7, parallel 1 | 2048 | 270 | 37,1 | 0,675 | 97 à 98 % | 16/16 | 302 / 32,2, soit -11 % et +15 % |
| muse-glimmer-30b-dflash | UD-Q4_K_XL, 15,9 Go (+ drafter DFlash 2 3,0 Go) | spec-type `ngram-map-k,draft-dflash`, size-m 7, min-hits 2, n-max 7, `reasoning_strength` low et reasoning-budget 4096, parallel 1 | 2048 | 346 | 31,6 | 0,625 | 100 % | n/j | 277 / 40,5, soit +25 % et -22 % (décode très bruité, cf. `lib/models.sh`) |
| deepseek-v4-flash | UD-IQ3_XXS, 104 Go (+ drafter DSpark 10,9 Go) | spec-type `ngram-map-k,draft-dspark`, size-m 7, min-hits 2, drafter DSpark unsloth Q8_0, n-max 3, reasoning-budget 6144 (soft 0,6 / 0,85, grâce 192), parallel 1 | 2048 | 131 | 26,3 | 0,685 | 100 % | n/j | 196 / 28,8, soit -33 % et -8,7 % |
| qwen3.8-flash-next-mtp-nothink | Signal-3.8-Flash-Next (fine-tune agentionai) AP-Q4_K_XL, 94,2 Gio (+ tête MTP shared Q8_0 unsloth 2,8 Go et mmproj BF16) | spec-type `draft-mtp,ngram-mod`, tête MTP shared sans renommage, n-max 3, `lazy-mode on-direct`, ctx 262144, batch 16384, parallel 1 | 4096 | 835 | 46,7 | 0,455 | 79 % | 16/16 | 364 / 52,4, soit +129 % et -11 % (même quant des deux côtés) |
| qwen3.8-flash-next-mtp-nothink-large-ub | même GGUF, même tête MTP, même mmproj | identique à la section de base, `ubatch-size` 16384 (gros prefills à froid, 22/09/2026) | 16384 | 1 090 à 1 110 (20 à 40 k tokens, à froid) | n/j | n/j | 18 % | n/j | n/j |

Ce que la bascule a changé au bilan : le prefill monte sur sept sections sur
neuf (+22 à +129 %, Flash-Next en tête avec son batch de 16384) et recule sur
deux, `deepseek-v4-flash` (-33 %) et `qwen3.8-27b-dflash-nothink` (-11 %) ; le
décode, lui, bouge peu (-1 à +11 %), sauf `muse-glimmer-30b-dflash` (-22 %,
série bien trop bruitée pour conclure, cf. `lib/models.sh`) et Flash-Next
(-11 %, mais son réglage spéculatif a changé en même temps que le moteur). Le
27B échange 11 % de prefill contre 15 % de décode : ce compromis n'est pas
tranché, il demande un `--bench-agentic` comparé, pas un `--bench`.

Composition du parc, pour mémoire : tout modèle qui dispose d'un drafter le
sert à un slot. `parallel 4` ne subsistait qu'à l'endroit où la concurrence
était réelle (`ornith-1.5-35b-a3b-parallel`, 2 à 3 slots au journal du
service, 144 à 146 t/s agrégés à 4 requêtes au `--bench-parallel` du
18/09/2026) ; cette section a été retirée le 22/09/2026, usage mono-utilisateur,
il n'y a plus de multi-slot dans le parc. Est arrivée le même jour la variante
`qwen3.8-flash-next-mtp-nothink-large-ub` (ubatch 16384, gros prefills à
froid). Ont quitté le parc : la section thinking du 27B (13/09/2026), `laguna-s-2.1` et
`qwen3.5-9b`, remplacée par `ornith-1.5-9b-mtp-nothink` (15/09/2026),
`gpt-oss` (16/09/2026) et `lfm2.5-8b-a1b-nothink` (18/09/2026, échec de la
boucle agentic sur les deux moteurs). Est arrivée le 16/09/2026
`muse-glimmer-30b-dflash`, concurrent direct du 27B. Les cinq sections nothink
déclarent `reasoning = off`, option native de llama-server, depuis le
17/09/2026. Justifications et mesures complètes : commentaires de
`lib/models.sh` et `docs/HISTORIQUE.md`.

### Avant : les deux moteurs précédents

Le parc a connu trois moteurs, donc trois séries de mesures, qui ne se
comparent pas à la décimale : le paquet Arch `llama-cpp` (`bNNNNN`, 21/08 au
05/09/2026), le fork Vulkan `strix-llama.cpp` installé sur l'hôte
(`strix-0007bc6`, Vulkan0, 12 au 17/09/2026) et l'image ROCm du 18/09/2026. La
table du fork, ligne par ligne, avec les écarts contre le paquet, n'est plus
reprise ici : elle survit dans la colonne « contre le fork Vulkan0 » ci-dessus
et, complète, dans `docs/HISTORIQUE.md` (« Résultats mesurés », « Paquet Arch
contre fork : mesures » et « Passage au fork »). Le fork apportait le prefill
sur tout le parc contre le paquet, les drafters externes (DFlash, DSpark), le
graphe MTP `qwen4exp` et `ngram-on-disk` ; l'image garde cette dorsale, ces
clés restent servies, et `ngram-on-disk` y est devenu l'alias déprécié de
`lazy-mode on`. Les essais écartés après mesure (speculative prefill, lossy et
cache de prompt à 0 % ; draft adaptatif, 2 % sous le draft fixe ; drafter
DFlash de gpt-oss, refusé au chargement, d'où la
[PR #62](https://github.com/halo-box/strix-llama.cpp/pull/62), qui vaut pour
les futurs drafters à biais) et la contrepartie du fork sur le découpage des
mat-vec batchés ([issue #50](https://github.com/halo-box/strix-llama.cpp/issues/50))
sont racontés au même endroit.

### Règles apprises sur ce moteur

- **Les points de reprise du cache de prompt sont pris aux frontières de
  micro-lot.** Un `ubatch-size` géant annule donc le cache de prompt : sur
  Flash-Next à `ubatch` 16384, un tour suivant à 20k tokens ne restaurait que
  18 % du contexte, contre 79 % à 4096, pour 8 % de prefill en moins. C'est
  aussi pourquoi `--bench-cache` est **aveugle sur cette section** : son prompt
  de 1 399 tokens tient dans un seul micro-lot, aucun point de reprise n'est
  pris, l'outil affiche 0 % et ne mesure rien. Sur cette section, la seule
  mesure valable est un prompt long.
- **`batch-size` / `ubatch-size` 16384 est une erreur de segmentation**
  (code 139) dès un prompt de 8k tokens sur tous les modèles SAUF Flash-Next,
  et coûte environ 33 Gio de tampons. `generate_models_ini` refuse toute valeur
  au-delà de 4096 hors liste blanche (`INI_BIG_BATCH_OK`), y compris quand elle
  vient d'une surcharge `--spec-ab`. Monter le micro-lot ailleurs a été mesuré
  et écarté : sur le 27B, `ubatch` 4096 perd sur les trois axes à la fois
  (cache long 90 % contre 97, prefill -15 %, décode -20 %).
- **`lazy-mode on-direct` est obligatoire avec `load-mode none`** sur
  Flash-Next : c'est lui qui laisse sur disque la table n-gram
  `per_layer_token_embd` de 28,8 Go, que `load-mode none` chargerait sinon
  entièrement en mémoire.
- **`--load-mode mmap` est disqualifié** : DeepSeek met plus de 13 minutes à
  charger. `none` partout.
- **DeepSeek est servi seul** : 9 Gio libres une fois chargé, 206 s de
  chargement. Aucun autre modèle ne tient à côté, la garde mémoire des `--bench`
  évince le reste avant de le charger.
- **`GGML_CUDA_ENABLE_UNIFIED_MEMORY` est interdit** sur ce runtime : chaque
  allocation passerait par `hipMallocManaged` et la sortie se corrompt. La
  variable n'est plus exportée nulle part dans le dépôt, et un test de
  `tests/sh-unit.sh` interdit sa présence dans `runtime/docker-compose.yml`.
- **`seccomp=unconfined` est exigé par ROCr**, dont les ioctl du KFD sortent du
  profil seccomp par défaut de docker. C'est le seul assouplissement du
  conteneur, et il est compensé : `cap_drop: [ALL]`, `no-new-privileges`, aucun
  `privileged`, aucun accès à `docker.sock`, `~/models` monté en lecture seule
  et un seul volume inscriptible hors du parc.

![Prefill : fork Vulkan0 contre moteur conteneurisé ROCm0](docs/graphs/prefill.svg)

![Décode : fork Vulkan0 contre moteur conteneurisé ROCm0](docs/graphs/decode.svg)

![Écart du moteur conteneurisé, en % du fork Vulkan0](docs/graphs/ecarts.svg)

Ces trois figures sont générées par `python3 py/perf_graphs.py` depuis
`docs/perfs.tsv` (une ligne par section servie, deux séries : fork Vulkan0 et
moteur conteneurisé ROCm0) : à régénérer, avec le TSV mis à jour, dès que la
table ci-dessus change.

## Fichiers de configuration

À côté du script, locaux et non versionnés (propres à la machine) :

| Fichier | Rôle |
|---|---|
| `preload.conf` | modèles préchargés, un par ligne |
| `spec-nmax.conf` | modèle = spec-draft-n-max retenu par les mesures |
| `spec-ngram.conf` | modèle = spec-ngram-map-k-size-m retenu par les mesures |
| `logs/spec-tests.log` | journal TSV des runs `--spec-test` |
| `logs/bench.log` | journal TSV des `--bench` (avec le build llama.cpp et le mode EC en queue) ; chaque `--bench` se compare au run précédent du même modèle/GGUF/device et du même mode EC, et signale un écart de plus de 5 % |
| `logs/bench-parallel.log` | journal TSV des `--bench-parallel` |
| `logs/bench-agentic.log` | journal TSV des `--bench-agentic` (une ligne par scénario, colonne `N` en queue = boucles simultanées) |
| `logs/bench-cache.log` | journal TSV des `--bench-cache` |
| `logs/bench-load.log` | journal TSV des `--bench-load` |
| `logs/spec-batch.log` / `.tsv` | journal des balayages `tools/bench-spec-batch.sh` |
| `logs/spec-isolate/<tag>/` | sorties de `tools/spec-isolate.sh` : `serveur.log`, `mesures.tsv`, `gen-*.txt` |
| `logs/qualif/<tag>/` | sorties de `tools/qualif-modele.sh` : un journal par étape (`01-devices.log` … `07-agentic.log`) et `resume.md` (tableau de perfs) |

Versionnés, eux (ils décrivent ce qu'on construit, pas la machine) :

| Fichier | Rôle |
|---|---|
| `runtime/Dockerfile.rocm-strix` | copie vendorisée du Dockerfile amont (PR 133, mergée), qui porte aussi les **révisions épinglées** du moteur et du runtime ROCr (`ARG ENGINE_REV`, `ARG ROCM_SYSTEMS_REV`) ; son historique git est le journal des révisions. Écarts et resynchronisation dans `runtime/AMONT.md` |
| `runtime/patches/` | les deux patchs que le build applique au moteur |

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
- `llama_model <section> "<corps ini>"` déclare la section ; deux sections
  peuvent partager le même `*_PATH` (Ornith depuis le 15/09/2026 : section de
  base à 4 slots et variante `-mtp` mono-utilisateur ; les deux sections
  Qwen3.8-27B jusqu'au 13/09/2026 ; lfm2.5 la journée du 15/09/2026, le temps
  de sa variante `-parallel`), et les garde-fous de préchargement en dérivent ;
- `groupe "; --- titre ---"` avant le premier `llama_model` d'une famille.

La suite (device, spéculation, mesures, récap partageable) est la procédure en
sept étapes de la skill locale `.claude/skills/ajout-modele/SKILL.md`, résumée
dans `AGENTS.md`.

## Outils (tools/)

| Fichier | Rôle |
|---|---|
| `opencode-sync-model.sh` | Synchronise la liste des modèles du serveur (`/v1/models`) dans la config opencode (`~/.config/opencode/opencode.json`, provider `llamaswap`). Variables : `ENDPOINT`, `CONFIG`, `PROVIDER` |
| `bench-spec-batch.sh` | Courbe brute `t_forward(batch)` d'un ou plusieurs GGUF par `llama-bench`, hors service, sur un ou plusieurs devices de l'image (`DEV=ROCm0`, `IMAGE`, `BATCHES`, `REPS`, `DEPTH`, `FA`). Analyse par `py/batch_curve.py`, journal `spec-batch.log` + `spec-batch.tsv`. Pour régler un modèle, préférer `--spec-ngram-tune` |
| `spec-isolate.sh` | Test isolé d'un réglage spéculatif AVANT sa déclaration dans `lib/models.sh` : `tools/spec-isolate.sh <tag> -- <args llama-server...>` monte un serveur jetable sur `PORT` (8099) avec les arguments bruts, mesure acceptance, prefill, décode et sanité de la sortie (`py/spec_isolate_bench.py`), puis relance le service. Variables : `PORT`, `NP` (salve simultanée en plus), `PASSES`, `PROMPTS`, `MAX_TOKENS`, `OUT`, `IMAGE` (autre image docker, pour mesurer un patch sans toucher au moteur servi). Le serveur jetable tourne DANS l'image, port publié sur `127.0.0.1` et conteneur nommé, que le trap supprime (`docker rm -f`). Refuse de démarrer si un `--bench*` / `--spec*` ou un conteneur `bench-agentic-*` tourne. Sorties dans `logs/spec-isolate/<tag>/`. À confirmer ensuite sur le service par `--spec-ab` |
| `qualif-modele.sh` | Qualification d'un modèle DÉJÀ déclaré et servi : `tools/qualif-modele.sh <section>` enchaîne les étapes 3, 5, 6 et 7 de la skill ajout-modele (`--bench-sanity`, `--spec-ab` sur `spec-refactor.txt` puis `spec-test.txt`, `--bench`, `--bench-cache`, `--bench-load`, `--bench-agentic`), une à la fois (un seul GPU), lit le drafter et le `size-m` réellement servis dans `status.args` de `/v1/models`, et écrit `logs/qualif/<tag>/resume.md` (tableau de perfs prêt à coller) plus un journal par étape. Options : `--passes`, `--size-m`, `--sans-agentic`, `--sans-cache`, `--sans-load`, `--tag`. Une étape en échec n'arrête pas les suivantes (code de retour non nul), **sauf la justesse** : un moteur qui répond faux arrête la qualification. Refuse de démarrer si un `--bench*` / `--spec*`, un `spec-isolate.sh` ou un conteneur `bench-agentic-*` tourne. N'écrit ni `lib/models.sh` ni les `.conf` ; ne joue ni le test isolé ni `--spec-tune` |
| `bench-depth.sh` | Prefill et décode selon la profondeur de contexte (`llama-bench -d`, défaut 0 / 16k / 32k), avec un tour simulé recalculé à chaque profondeur : c'est le régime agentic réel. Tourne sur le `llama-bench` de l'**image**, donc sur le moteur qui sert (`DEV`, `CTK`/`CTV` f16, `IMAGE`). Journal `logs/bench-depth.log` + `.tsv` |
| `py/perf_graphs.py` | Régénère les trois SVG de `docs/graphs/` (prefill, décode, écarts en %) à partir de `docs/perfs.tsv`, en rendu sobre (barres pleines, fond blanc). Aucune dépendance, aucun service : `python3 py/perf_graphs.py [<tsv> [<dossier>]]`. À relancer après toute modification du TSV |
| `llm-proxy.ts` | Extension pi / omp : découvre les modèles `text-generation` du proxy Albert (`/v1/models`, ctx, coûts, reasoning déduit de l'id) et enregistre le provider `albert`. A copier dans `~/.pi/agent/extensions/` et `~/.omp/agent/extensions/` (une seule extension provider par agent). Endpoint `http://llmproxy` et clé en dur pour l'instant (à passer sur `process.env` avant diffusion) |

Les scripts shell pointent sur `http://bigchuck:8009` par défaut (surchargeable par variable d'environnement).

## FAQ

**Un modèle échoue au chargement, ROCm0 a disparu.**
`--list-devices` demande ses devices à l'image du service et alerte si `ROCm0`
manque : c'est le device de tout le ini, sans lui rien ne charge. Reconstruire
l'image (`--image-build`) et vérifier `/dev/kfd`, `/dev/dri` et les groupes
`render` et `video` de l'hôte.

**Je peux éditer models.ini ?**
Non, il est régénéré à chaque `--setup`, `--preload` ou `--spec-*`.
Éditer les fichiers `.conf` ou `lib/models.sh`.

**Pourquoi `parallel = 1` sur les modèles spéculatifs ?**
Par choix mesuré, pas par interdit. Cette FAQ a répondu jusqu'au 15/09/2026
« contrainte llama.cpp : `-np` supérieur à 1 et `--mmproj` ne sont pas
supportés avec MTP » ; cette phrase vient d'une doc unsloth de juin/juillet
2026 et n'existe pas dans la dorsale `strix-llama.cpp` que sert l'image
(vérifié le 15/09/2026 sur le commit `0007bc6`, moteur du service à cette
date) : le serveur y drafte tous les slots en un
appel, `draft-dflash` et `draft-dspark` sont explicitement multi-séquences,
`draft-mtp` est vectorisé par séquence. Seul interdit qui demeure : `--mmproj`
avec un drafter.

Ce que la mesure du 15/09/2026 a établi (`--bench-parallel`,
`tools/spec-isolate.sh NP=N`, `--bench-agentic <m> 2 N`) :

- des slots vides ne coûtent rien : une requête seule tourne à la même vitesse
  à `parallel` 1, 2 ou 4 ; seul le contexte par slot baisse (`ctx-size` est un
  pool partagé) ;
- sous charge, l'agrégé suit le batch de vérification `parallel x (n-max + 1)`
  contre le seuil de 8 colonnes du noyau mat-vec (mesuré le 15/09/2026 sur
  ggml-vulkan, non rejoué sur le moteur conteneurisé) : à 8 ou moins, gain (DeepSeek
  DSpark np 2 x1,22 en salves ; Ornith sans spéculation np 4 x1,93) ; au-delà,
  tout retombe sous x1 (27B DFlash np 2 x0,89, Coder-Next np 2 et 4 x0,86 et
  x0,92) ;
- le MTP multi-slot s'effondre même sous le seuil (qwen3.5-9b MTP n-max 1 à
  np 2 : 24 t/s agrégés contre 80,8 sans spéculation à np 4) ;
- en boucle agentic réelle, DeepSeek à 2 boucles ne rend que x1,16 de tâches
  pour une latence doublée : remis à 1. Ornith sans spéculation tient 3 boucles
  (40/40, cache 88 à 94 %, x2,33) : parallel 4 gardé.

D'où le parc du 15/09 : parallel 1 partout où il y a un drafter, parallel 4 sans
spéculation au seul endroit où la concurrence est réelle
(`ornith-1.5-35b-a3b-parallel`, 2 à 3 slots au journal du service ; section
retirée le 22/09/2026, usage mono-utilisateur). Les
variantes `-parallel` de lfm2.5 et du 9b, créées le
15/09/2026 pour garder l'ancien réglage à 4 slots, ont été retirées le soir
même : aucune concurrence n'a jamais été observée sur ces deux modèles, et pas
de parallel si perte de perf. Détail par modèle dans `lib/models.sh` et
`docs/HISTORIQUE.md`, paragraphe « Multi-slot et drafters ».
