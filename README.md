# LLM Setup

LLM Setup sert des modèles de langage sur une machine Strix Halo (bigchuck :
Ryzen AI Max+ 395, 124 Go unifiés, CachyOS/Arch), avec un seul point d'entrée,
`./setup-llm.sh`, et **un moteur au choix**. Chaque moteur est un *runtime* :
un dossier autonome de `runtime/`, toujours lancé dans un conteneur par
`docker compose`, qui respecte un contrat commun.

| Runtime | Moteur | Documentation |
|---|---|---|
| [`llama-cpp-rocm-strix`](runtime/llama-cpp-rocm-strix/) (défaut) | `llama-server` en router mode natif, image ROCm construite localement ([halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp) en HIP seul) : tout le parc, `models.ini` généré, réglage de la spéculation, bancs | [README](runtime/llama-cpp-rocm-strix/README.md), [ARCHITECTURE](runtime/llama-cpp-rocm-strix/ARCHITECTURE.md), [docs/HISTORIQUE.md](docs/HISTORIQUE.md) |
| [`gufo`](runtime/gufo/) | [gufo](https://github.com/gufo-org/gufo) derrière llama-swap : Qwen3.8-27B, Flash-Next, DeepSeek V4 Flash, voix, transcription, image | [README](runtime/gufo/README.md), [docs/GUFO.md](docs/GUFO.md), [docs/HISTORIQUE-GUFO.md](docs/HISTORIQUE-GUFO.md) |

Un seul runtime tient le port `:8009` à la fois (un GPU) : démarrer l'un
arrête l'autre, et les clients ne changent pas d'adresse.

Écrire un nouveau runtime : [`runtime/CONTRAT.md`](runtime/CONTRAT.md).
Architecture commune : [`ARCHITECTURE.md`](ARCHITECTURE.md).

## Prérequis

- Arch/CachyOS, `paru`, bash 4.3 ou plus, python3 (stdlib seule), curl.
- **docker et son démon activé au boot** (`systemctl enable --now docker`) :
  tout runtime est un conteneur, et c'est docker qui le relance au
  redémarrage de la machine.
- Utilisateur dans les groupes `docker`, `render` et `video`.
- Le reste dépend du runtime (voir son README).

## Commandes communes

Elles visent le **runtime actif** : celui de `runtime.conf` (fichier local,
écrit par `--runtime`), à défaut `llama-cpp-rocm-strix`.

| Commande | Rôle |
|---|---|
| `--runtime` | Les runtimes présents, l'actif, celui qui tourne |
| `--runtime <nom> [args]` | **Bascule** : `<nom>` devient l'actif et démarre, ce qui arrête celui qui tenait le port. Ses prérequis sont vérifiés avant de toucher à quoi que ce soit ; si le démarrage échoue, l'ancien runtime est remis |
| `--setup [args]` | Installe le runtime actif (dépendances, image, poids) |
| `--start [args]` | Démarre (commande par défaut) : `.env` régénéré, autre runtime arrêté, conteneur recréé, attente de `/health` |
| `--stop` | Arrête le conteneur |
| `--restart [args]` | `--stop` puis `--start` ; jamais `docker compose restart` |
| `--status` | Runtime actif, état du conteneur, réponse de `/health` |
| `--logs [-f] [--tail N]` | Journaux du conteneur |
| `--help` | Ces commandes, puis l'aide du runtime actif |

`LLM_RUNTIME=<nom> ./setup-llm.sh <commande>` vise un runtime pour **une**
commande, sans rien mémoriser. C'est ainsi qu'on installe un runtime avant d'y
basculer, ou qu'on lit son aide :

```bash
./setup-llm.sh --runtime                       # où en est-on ?
LLM_RUNTIME=gufo ./setup-llm.sh --setup image  # installer gufo, le service tourne toujours
LLM_RUNTIME=gufo ./setup-llm.sh --help         # ses commandes
./setup-llm.sh --runtime gufo                  # basculer
./setup-llm.sh --runtime llama-cpp-rocm-strix  # revenir
```

Les **sous-commandes d'un runtime** (`--bench`, `--spec-tune`, `--preload`,
`--image-build`… pour `llama-cpp-rocm-strix` ; `--requetes` pour `gufo`) ne
s'exécutent que sous ce runtime : demandées sous un autre, elles sont refusées
en le nommant.

## Ce qui est commun, ce qui ne l'est pas

| À la racine | Rôle |
|---|---|
| `setup-llm.sh`, `lib/` | Point d'entrée et pilotage générique : aucun moteur n'y est nommé |
| `runtime/CONTRAT.md` | Ce qu'un runtime doit fournir |
| `prompts/` | Prompts de mesure, partagés pour comparer deux runtimes à requêtes identiques |
| `bench-agentic/` | Client pi en conteneur jetable : la boucle agentique réelle, jouée contre n'importe quel runtime |
| `tests/sh-unit.sh` | Vérifie le contrat et le pilotage, puis lance les tests de chaque runtime |
| `docs/` | Journaux datés et documents de travail |
| `tools/` | Outils côté client (ci-dessous) |
| `runtime.conf`, `*.conf`, `logs/` | Choix et mesures propres à la machine, non versionnés |

Tout le reste est dans le dossier d'un runtime : son image, ses poids, ses
réglages, ses mesures, ses outils, ses tests. **Les mesures ne sont pas
communes** : chaque moteur expose autre chose, chacun a ses bancs.

## Outils côté client (tools/)

| Fichier | Rôle |
|---|---|
| `opencode-sync-model.sh` | Synchronise la liste des modèles du serveur (`/v1/models`) dans la config opencode (`~/.config/opencode/opencode.json`, provider `llamaswap`). Variables : `ENDPOINT`, `CONFIG`, `PROVIDER` |
| `llm-proxy.ts` | Extension pi / omp : découvre les modèles `text-generation` du proxy Albert (`/v1/models`, ctx, coûts, reasoning déduit de l'id) et enregistre le provider `albert`. A copier dans `~/.pi/agent/extensions/` et `~/.omp/agent/extensions/` (une seule extension provider par agent). Variables : `LLM_PROXY_URL` (défaut `http://llmproxy`), `LLM_PROXY_API_KEY` ou `LLM_PROXY_KEY` |
| `gufo-media.ts` | Extension pi / omp : outils `image_generation` (Qwen-Image, PNG 512x512 par défaut dans le dossier de travail), `modifier_image` (édition d'une ou plusieurs images de référence, résultat `<image>-edit.png` à côté, rapport conservé à la surface de 512x512) et `parler` (Qwen3-TTS, lecture en flux par `pw-play`, premier son en 0,5 s ; voix intégrée, ou décrite par VoiceDesign) sur gufo via le proxy (`bigchuck/…`), et leurs commandes directes, sans passer par le modèle : `/image [LxH] <prompt>`, `/image-edit <fichier>... <consigne>` et `/parler [voix décrite] <texte>`. Une image décharge le LLM de la conversation (groupe « gros » de `runtime/gufo/gufo-llama-swap.yaml`). Variables : `LLM_PROXY_URL` (défaut `http://llmproxy`), `LLM_PROXY_KEY`, `GUFO_IMAGE_MODEL`, `GUFO_IMAGE_SIZE` (défaut `512x512`), `GUFO_TTS_MODEL`, `GUFO_TTS_DESIGN_MODEL`, `GUFO_PLAYER` (lecteur de PCM brut sur l'entrée standard). A copier à côté de `llm-proxy.ts` |

Les scripts shell pointent sur `http://bigchuck:8009` par défaut (surchargeable par variable d'environnement).
Les outils propres à un moteur sont dans son runtime
(`runtime/llama-cpp-rocm-strix/tools/`, `runtime/gufo/tools/`).

## Tests

```bash
./tests/sh-unit.sh             # contrat, pilotage, puis les tests de chaque runtime
./tests/sh-unit.sh --contrat   # contrat et pilotage seuls (écriture d'un runtime)
```

Sans GPU, sans démon docker, sans réseau.
