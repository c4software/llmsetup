# runtime-gufo : gufo à la place du service, et ses bancs

[gufo](https://github.com/gufo-org/gufo) est un moteur HIP spécialisé
Strix Halo, évalué contre le service le 24/09/2026 : verdict, paramètres et
tickets amont dans [`docs/GUFO.md`](../docs/GUFO.md), mesures datées dans
[`docs/HISTORIQUE-GUFO.md`](../docs/HISTORIQUE-GUFO.md). En
résumé : bien configuré, il fait le même travail agentique en 30 % de temps
en moins sur le 27B et Flash-Next, mais il ne sert qu'un modèle par
processus et n'accepte que ses propres GGUF. Il ne s'intègre pas au routeur
du service : il **prend sa place** sur `:8009`, les deux sont exclusifs.

## Mise en route, depuis un clone

Sur la machine du service (bigchuck), le service déjà installé
(`./setup-llm.sh --setup`, qui télécharge les GGUF du parc) :

```bash
./setup-llm.sh --gufo-download image       # l'image de gufo (8,3 Go)
./setup-llm.sh --gufo-download flashnext   # Flash-Next UD-Q4_K_XL (104 Go), seulement pour flashnext
./setup-llm.sh --gufo-download deepseek    # DeepSeek IQ2XXS + DSpark (93 Go), si voulu
./setup-llm.sh --gufo-download tts         # synthèse vocale, trois variantes (13,5 Go), si voulu
./setup-llm.sh --gufo-download asr         # transcription (4,7 Go), si voulu
./setup-llm.sh --gufo-download qwen-image  # génération d'images (33 Go, licence non commerciale), si voulu
./setup-llm.sh --gufo-download qwen-image-heretic  # son encodeur « abliterated » (16,3 Go), la variante servie
./setup-llm.sh --gufo                      # Flash-Next préchargé ; ou --gufo 27b, --gufo deepseek
./setup-llm.sh --gufo-off                  # retour au service
```

gufo démarre **toujours derrière llama-swap** (la voie que gufo recommande) :
le client choisit `qwen3.8-27b`, `qwen3.8-flash-next` ou `deepseek-v4-flash`
par le champ `model`, comme avec le routeur du service, et llama-swap arrête
un gufo pour lancer l'autre. Un seul modèle est chargé à la fois (aucune
paire ne tient dans 124 Gio) ; l'argument de `--gufo` ne choisit que le
modèle préchargé (Flash-Next par défaut). Mesuré sur bigchuck le
25/09/2026, entre le 27B et Flash-Next : bascule vers le 27B 64,6 s, retour vers Flash-Next 31,4 s,
relais sans coût (décode vu du client 47,4 t/s contre 47,6 mesurés par
gufo). Les clients agentiques doivent faire pointer tous leurs rôles
(principal et tâches annexes, le « Haiku » de Claude Code) sur le même
modèle, sinon chaque requête annexe déclenche une bascule.

Au-delà du texte, le même llama-swap sert les autres modèles de gufo, sous
les routes OpenAI habituelles :

| Modèle (`model`) | Route | Chargement |
|---|---|---|
| `qwen3-tts-12hz-1.7b-customvoice`, `-voice-design`, `-base` | `/v1/audio/speech`, `/v1/audio/voices` | groupe « voix » : une variante à la fois, À CÔTÉ du modèle de texte, jamais déchargée par lui ; déchargée après 60 s sans requête (gufo-org/gufo#272) |
| `qwen3-asr-1.7b` | `/v1/audio/transcriptions` | groupe « transcription » : à côté de tout, jamais déchargé par un autre modèle ; déchargé après 60 s sans requête (gufo-org/gufo#272) |
| `Qwen-Image-2.1-heretic` (encodeur de texte « abliterated ») | `/v1/images/generations`, `/v1/images/edits` | groupe « gros » avec les LLM : une image décharge le LLM en cours, et l'inverse |

Le flux WebSocket de la synthèse (`/v1/audio/speech/stream`) n'est pas une
route de llama-swap : `/upstream/<modèle>/v1/audio/speech/stream`. Mesuré le
25/09/2026 : synthèse 2,5 fois le temps réel, transcription fidèle en 3 s,
image 1024² en 90 s ; Flash-Next, voix et transcription ensemble laissent
14 Gio libres (détail dans `docs/HISTORIQUE-GUFO.md`).

Par le proxy (`http://llmproxy`), les mêmes modèles sont préfixés
`bigchuck/` ; pour pi et omp, `tools/gufo-media.ts` ajoute les outils
`image_generation` et `parler`.

Le 27B tourne avec les fichiers du parc, rien d'autre à télécharger.
`./setup-llm.sh --status` dit qui tient le port, `--gufo-logs` suit les
requêtes de gufo.

## Le dossier

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | Le conteneur, versionné : image gufo + llama-swap, périphériques GPU, utilisateur de l'hôte, volumes, `restart: ${GUFO_RESTART}`. Aucune valeur machine : tout vient du `.env` |
| `Dockerfile.routeur` | L'image : celle de gufo plus le binaire llama-swap, épinglé par version et SHA-256 ; construite par compose |
| `IMAGE` | L'image de gufo épinglée, une ligne (`ghcr.io/gufo-org/toolboxes/gufo-runtime:<version>`) : SEUL endroit à éditer pour changer de version. Défaut de `GUFO_IMAGE` pour `lib/gufo.sh`, `download.sh`, `bench/remesure.sh` et `tools/gufo-amont.sh` ; `Dockerfile.routeur` la reçoit du `.env` |
| `gufo-llama-swap.yaml` | La SEULE description des lignes de commande de gufo, modèle par modèle, versionnée, sans valeur machine (`${env.VAR}`) : réglages et leur origine, groupe exclusif, préchargement |
| `download.sh image\|flashnext\|deepseek\|tts\|asr\|qwen-image\|all` | Image et GGUF de référence de gufo, aux révisions épinglées par ses guides (`./setup-llm.sh --gufo-download`) |
| `bench/run.sh gufo\|llama <cas>...` | Banc HTTP (`bench/mesure.py`) : justesse, `--bench`, `spec-refactor`, prefill long avec aiguille, cache au tour 2 |
| `bench/agentic.sh gufo\|llama <cas>...` | Boucle pi de `bench-agentic/`, contre gufo ou le service, sans toucher `logs/` |
| `bench/remesure.sh [cas...]` | Remesure après une montée de version (checklist de `docs/GUFO.md`) : `run.sh` puis `agentic.sh` sur gufo (défaut 27b flashnext), `SANS_CACHE=1` pour la même boucle sans `--cache-disk`, journaux agentiques rangés dans `resultats/agentic/<date>-<version>/` (`avant/`, `avec-cache/`, `sans-cache/`), bilan par `bench/journal.py`, gufo d'usage réel relancé s'il tournait |
| `bench/capture.py <sortie.jsonl> [port]` | Relais d'enregistrement : écoute sur `:8019`, transmet à `:8009` et garde le corps de chaque requête, pour avoir l'enveloppe exacte d'un client (prompt système, outils, paramètres) |
| `bench/rejeu.py <session> <motif> <N> <sortie> <bras>...` | Rejoue N fois par bras la requête qu'une session pi envoie après un résultat d'outil donné, avec l'enveloppe capturée (`nom=capture.jsonl[,champ=valeur...]`, par exemple `presence_penalty=0.0` ou `reasoning_effort=low`), bras alternés ; décompte par bras de l'outil appelé, du texte émis et du `newText` (`docs/HISTORIQUE-GUFO.md`, gufo#388) |
| `bench/journal.py <journal>...` | Bilan d'un journal gufo : sources du cache et ratés, prompt repris, temps en prefill et en décode, premier token des petites requêtes, acceptance, points de reprise écrits ou refusés |

Le `.env` est généré par `./setup-llm.sh --gufo` (`lib/gufo.sh`) dans
`GUFO_DATA`, comme celui du service dans `~/models`. Il porte `COMPOSE_FILE`
et le modèle préchargé, d'où l'usage à la main :

```bash
cd ~/llm/gufo-test && docker compose ps     # ou logs -f
```

Nom exposé par gufo : `qwen3.8-27b` ou `qwen3.8-flash-next` (via le proxy :
`bigchuck/<nom>`), distinct des sections du service.

## Où vont les données

Les poids propres à gufo (`--gufo-download`) vont avec le parc, dans
`~/models/gufo` (`MODELS_BASE/gufo`), depuis le 09/10/2026 : un seul dossier
de modèles à copier d'une machine à l'autre. `--cleanup` épargne ce dossier
par son nom (aucun modèle de `lib/models.sh` ne le référence, il le verrait
sinon orphelin). Avant cette date ils étaient dans `GUFO_DATA/models`.

Le reste est hors du dépôt et hors de `~/models`, dans `GUFO_DATA`, par
défaut `~/llm/gufo-test` :

- `.env` (usage réel) et `banc.env` (bancs) : générés ;
- `cache/` : cache disque de gufo (16 Gio au plus) ;
- `resultats/` : sorties des bancs.

Variables : `GUFO_DATA`, `MODELS_BASE` (téléchargement seul), `GUFO_IMAGE`, `GUFO_SESSIONS` (défaut 2 ; `SESSIONS`
pour les bancs, défaut 1), `PASSES` (banc agentique). Les bancs posent
eux-mêmes `GUFO_PROJET=gufo-banc`, `GUFO_CONTENEUR=gufo-banc`,
`GUFO_RESTART=no` et leur `.env`.

## Règles

- Un seul moteur à la fois sur `:8009` : `--gufo` arrête le service,
  `--gufo-off` supprime gufo et relance le service, `--start` et `--restart`
  refusent tant que gufo tourne. Le dernier lancé repart seul au démarrage
  de la machine.
- Les bancs retirent un gufo d'usage réel au départ et relancent le service
  à la fin.
- Garder la configuration de gufo stable : la changer (`GUFO_SESSIONS`…) rend
  son cache disque inutilisable.
- `stop` et `stop_sequences` : gérés par gufo depuis le 25/09/2026
  (gufo-org/gufo#260), transmis tels quels ; llama-swap ne les retire plus.
- Modifier `gufo-llama-swap.yaml` demande de relancer `--gufo` (lu au
  démarrage) ; `tests/sh-unit.sh` en vérifie la cohérence (noms, `stop` transmis,
  groupe exclusif).
