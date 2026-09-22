# ARCHITECTURE

## Flux de données

```
lib/models.sh (déclarations : download_hf/llama_model/groupe → MODEL_INI, défauts)
        │
        ▼                    surcharges
generate_models_ini  ◄──  spec-nmax.conf       (spec-draft-n-max par modèle)
   (lib/ini.sh)
        │            ◄──  spec-ngram.conf      (spec-ngram-map-k-size-m par modèle)
        │            ◄──  preload.conf         (load-on-startup)
        ▼
~/models/models.ini  ──►  llama-server --models-preset (router mode)
                          ⚠ lu AU DÉMARRAGE SEULEMENT → restart requis
```

Le service est un **conteneur**, décrit par `runtime/docker-compose.yml`
(versionné, variables `${VAR:?}` pour tout ce qui dépend de la machine) et par
un `.env` généré à côté du ini, du même statut que lui (produit, non versionné,
jamais édité à la main) :

```
runtime/Dockerfile.rocm-strix ─┐  (ARG ENGINE_REV, ARG ROCM_SYSTEMS_REV)
runtime/docker-compose.yml    ─┤  (versionné : bloc build, ${VAR:?})
preload.conf                  ─┤
lib/compose.sh                ─┴─► regen_env ──► ~/models/.env
                                     (gid, chemins, --models-max, IMAGE_REF, COMPOSE_FILE)
                                                   │        │
                              docker compose build ┘        │
                                   → llm-rocm-strix:latest  │
                                                   │
                        _svc_start ────────────────┘
                        docker compose --project-directory ~/models up -d --force-recreate
                                                   │
                                                   ▼
   conteneur « llama-server »            hôte
   ┌──────────────────────────┐          ┌──────────────────────────────┐
   │ /usr/local/bin/llama-    │          │                              │
   │   server (image)         │          │                              │
   │ --models-preset          │◄── ro ───┤ ~/models  (MÊME chemin       │
   │   ~/models/models.ini    │          │            absolu, en :ro)   │
   │ --host 0.0.0.0 --port … ─┼── :8009 ─┤ $BIND_ADDR:8009 (défaut      │
   │ /var/cache/llama   (rw)  │◄── rw ───┤ 0.0.0.0, comme l'ancien      │
   │ /dev/kfd, /dev/dri       │◄─────────┤ --host 0.0.0.0 de l'unité)   │
   └──────────────────────────┘          │ ~/.local/state/llm-setup/    │
                                         │   cache                      │
                                         └──────────────────────────────┘
```

`~/models` est monté **au même chemin absolu** des deux côtés : `models.ini`
porte des chemins absolus de l'hôte et n'a donc jamais à être réécrit pour le
conteneur. En lecture seule : le moteur n'a rien à écrire dans les poids.

Le script ne parle jamais directement aux GGUF pour mesurer : `--bench` et
`--spec-test` passent par l'API du serveur **tel qu'il tourne**
(`/v1/chat/completions`, `/v1/models`). Toute mesure dépendant d'un paramètre
de modèle lit l'état réel du serveur (`/v1/models` → `status.args`), pas le
script ni le ini — c'est l'invariant n° 1 de `cmd_spec_test`, à ne pas
régresser.

## Ordre de source et dépendances

`setup-llm.sh` (point d'entrée) définit `SCRIPT_DIR` puis source, dans cet
ordre imposé :

```
common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help
```

- `common.sh` : helpers (`info/warn/error`, `_key`, `_skip`,
  `_dl`, `_dl_shard`, `_maybe_restart_service`, `_llama_build` : version
  courte de llama.cpp, journalisée partout ; `_ensure_room_for` : garde
  mémoire avant chargement d'un modèle, cf. plus bas) et **toutes les variables
  globales de config** : `MODELS_BASE`, `CONFIG_DIR`, `PRELOAD_CONF`, `SPEC_TEST_URL`, `LOG_DIR` (+ migration des journaux de la
  racine), `SPEC_LOG`, `BENCH_LOG`, `SPEC_CONF`, `SPEC_NGRAM_CONF`, `SERVICE_NAME`,
  `SERVICE_FILE`, `REFRESH`/`ONLY`. Elles vivent ici parce que plusieurs modules les
  consomment (`_maybe_restart_service` utilise `SERVICE_NAME`, `cmd_bench`
  utilise `SPEC_TEST_URL`) — définies **avant** toute fonction qui les utilise.
- `svc.sh` : **le seul point d'appel de `docker compose` pour le service**.
  `_svc_compose` (`--project-directory $CONFIG_DIR -f runtime/docker-compose.yml` :
  le `.env` est lu dans le dossier de projet), `_svc_start` (régénère le `.env`, `up -d --force-recreate --remove-orphans`,
  puis `_svc_wait_ready`), `_svc_stop [timeout=180]`, `_svc_restart` (stop puis
  start), `_svc_is_active` (`docker inspect` sur le nom du conteneur),
  `_svc_installed` (`.env` générable : docker, image locale, `models.ini`),
  `_svc_wait_ready [timeout=300]` (boucle `/health`, sortie anticipée avec le
  code de sortie si le conteneur est `exited`), `_svc_logs`, et les commandes
  `cmd_start` / `cmd_stop` / `cmd_restart` / `cmd_status` / `cmd_logs`.
  Sourcé juste après `common.sh` parce que `_maybe_restart_service` en dépend.
  Ne pas confondre avec le compose **jetable** de `bench-agentic/`, qui lance le
  client pi et ne sert aucun modèle.
- `models.sh` : `DEFAULT_DEVICE` (`ROCm0`, device unique de l'image),
  `INI_BATCH_MAX` / `INI_BIG_BATCH_OK` (garde-fou `batch-size`) et la
  **déclaration des modèles**, un bloc
  par modèle **avec ses commentaires métier** (sampling officiels, contraintes
  cache/MTP/SWA, historique des choix, repo/quant). Quatre helpers déclaratifs :
  `download_hf`/`download_hf_shards` (définissent les chemins `*_PATH`,
  alimentent `KNOWN_FILES` — inventaire, source unique de `--cleanup` et des
  mkdir — et `DL_SPECS`, consommé en boucle par `cmd_setup`), `groupe`
  (en-têtes de groupe du ini, `GROUPE_AVANT`), `llama_model` (corps `MODEL_INI[...]`
  et `PRESET_ORDER` = ordre de déclaration = ordre d'émission — `declare -A`
  ne préserve pas l'ordre d'insertion). Un `download_hf` peut servir
  plusieurs sections (même GGUF) et porter plusieurs fichiers (drafter externe).
- `ini.sh` : loaders des trois confs (`load_preload_conf`,
  `load_spec_conf`, `load_spec_ngram_conf`),
  `_preset_nmax` et `_preset_ngram_m` (surcharge conf > défaut script ;
  `SPEC_NMAX_FORCE` / `SPEC_NGRAM_FORCE` + `*_PRESET` priment, posés par les
  tuners pour tester une valeur sans l'écrire), `generate_models_ini`
  (applique aussi `SPEC_TYPE_FORCE` + `SPEC_TYPE_FORCE_PRESET` : spec-type
  remplacé le temps d'une mesure, `draft-mtp` pour `--spec-tune` sur une
  liste, `none` pour la référence de `--spec-ngram-tune` sans MTP ; et
  `SPEC_AB_OVERRIDES` + `SPEC_AB_PRESET` : surcharges libres de `--spec-ab`,
  via `_apply_overrides`). Émet aussi les **quatre injections** de device
  (`device`, `device-draft`, `spec-draft-ngl = all`, `mmproj-device`, toutes
  sur `DEFAULT_DEVICE`), le **garde-fou `batch-size`/`ubatch-size`**
  (`_ini_guard_batch`, refus au-delà de `INI_BATCH_MAX` hors
  `INI_BIG_BATCH_OK`, surcharges `--spec-ab` comprises) et l'avertissement
  `_ini_warn_conf_nmax` (une valeur locale de `spec-nmax.conf` qui contredit
  le dépôt).
- `compose.sh` : **génération du `.env`** de `$CONFIG_DIR` (`~/models`, à côté
  de `models.ini`), les valeurs machine de `runtime/docker-compose.yml` :
  `COMPOSE_FILE`, `SERVICE_NAME`, `IMAGE_REF`, `RUNTIME_DIR`, `SERVER_PORT`,
  `BIND_ADDR`, `CONFIG_DIR`, `MODELS_BASE`, `CACHE_DIR`, `SVC_UID`, `SVC_GID`
  (le conteneur tourne avec l'uid:gid de l'utilisateur, pas en root, depuis le
  22/09/2026), `GID_RENDER`, `GID_VIDEO`, `MODELS_MAX`. `generate_env` écrit sur **stdout** (aucun effet
  de bord, donc testable et diffable), `regen_env` l'écrit sur disque par un
  fichier temporaire et **ne remplace que si le contenu diffère**.
  `_compose_check` valide les prérequis avant d'écrire une seule ligne (docker,
  compose du dépôt, image locale via `_image_ref`, `models.ini`, gid de
  `render` et `video`), `_compose_gid` résout un groupe de l'hôte en **nombre**.
  `COMPOSE_FILE`, `ENV_FILE`, `BIND_ADDR` (défaut `0.0.0.0`) et
  `COMPOSE_CACHE_DIR` (`~/.local/state/llm-setup/cache`) vivent ici.
- `preload.sh` : sélection interactive (`select_preload_models`, gum ou
  fallback numéroté), `_save_preload_conf`, `_preload_sanity` (garde-fous
  doublons de poids, dérivés des déclarations : même GGUF partagé ou paire de
  dossiers `<clé>`/`<clé>-mtp`), `cmd_preload`.
- `setup.sh` : `cmd_setup` (dépendances - curl et `hf` seulement depuis le
  18/09/2026, plus aucun paquet llama.cpp ni ggml -, téléchargements, puis
  `_setup_check_docker` : docker présent, démon qui répond ET activé au boot,
  utilisateur dans le groupe `docker`, image du moteur présente ; jamais
  bloquant, isolée de `cmd_setup` pour être testable sans réseau),
  `cmd_update` (= setup avec `REFRESH=1`, `hf` compare les etags),
  `cmd_cleanup` (piloté par `KNOWN_FILES`, dry-run par défaut).
- `runtime.sh` : **le moteur**, conteneurisé (dossier `runtime/`, voir plus
  bas), pour le service comme pour les outils hors service. Module volontairement
  court depuis le 18/09/2026 : `IMAGE_NAME` / `IMAGE_TAG` (tag unique `latest`),
  `_image_tag` / `_image_ref`, `cmd_image_build [--no-cache]` (RACCOURCI :
  `regen_env` puis `_svc_compose build` :
  pas de tag temporaire, pas de promotion, pas de vérification d'après-coup, pas
  de purge, pas de journal), et `_dk_run <binaire> [args]` (exécution dans l'image :
  `/dev/kfd` + `/dev/dri`, gid NUMÉRIQUES de `render` et `video` via `getent`,
  `seccomp=unconfined` compensé par `no-new-privileges` et `cap-drop=ALL`,
  `--shm-size 8g`, memlock illimité, `~/models` monté au MÊME chemin absolu en
  lecture seule, `--network none` par défaut — jamais `--privileged`, jamais
  `docker.sock`. `DK_RUN_PUBLISH=127.0.0.1:<port>:<port>` publie un port, borné
  à la loopback, et bascule le réseau par défaut sur `bridge` ; `DK_RUN_NAME`
  nomme le conteneur pour qu'un trap puisse faire `docker rm -f` : les deux
  servent au `llama-server` jetable de `tools/spec-isolate.sh`).
  ⚠ Cette image EST le moteur du service (`IMAGE_REF` du `.env` vient de `_image_ref`),
  mais aucune de ces commandes ne redémarre quoi que ce soit : une image neuve
  n'est servie qu'au prochain `--restart`. Une image = une série de mesures.
- `bench/bench.sh` (noyau) : `_bench_one` (une mesure API, `BENCH_ROW`, précédée
  de la garde mémoire `_ensure_room_for`), les
  sélections (`_bench_presets`, `_bench_select_presets`, `_bench_select_one`)
  et `cmd_bench` (mesure du serveur en l'état, journal `logs/bench.log` +
  comparaison au run précédent). Une mesure = un module `bench/bench-*.sh` qui
  réutilise ce noyau :
  `bench.sh` porte aussi `cmd_bench_sanity` / `_bench_sanity_one` (justesse,
  `py/check_answer.py` ; première étape **bloquante** de
  `tools/qualif-modele.sh`) et `cmd_list_devices` (étiquette du moteur, puis
  les devices de l'**image** par `_dk_run llama-bench --list-devices`). Le
  module `bench/bench-devices.sh` et `--bench-devices` ont été retirés le
  18/09/2026 : l'image n'expose qu'un device.
- `bench/bench-parallel.sh` : `cmd_bench_parallel` (salves de 1 puis n requêtes
  simultanées, `parallel` réel lu sur `/v1/models`, agrégat par
  `py/parallel_agg.py`).
- `bench/bench-cache.sh` : `cmd_bench_cache` (quatre requêtes froid / suite /
  édition au premier tiers / identique, part servie du cache par
  `py/cache_stats.py`).
- `bench/bench-load.sh` : `cmd_bench_load` (restart + première requête
  chronométrée, TTFT à chaud).
- `bench/bench-agentic.sh` : `cmd_bench_agentic` (un client réel, pi, en conteneur
  jetable `bench-agentic/`, appel froid puis N passes de cinq scénarios de
  tool calls en direct sur le serveur ; delta de `/metrics?model=` par
  scénario, médianes en awk, journal `logs/bench-agentic.log`).
  3e argument `N` > 1 (`_bench_agentic_parallele`) : le cas orchestrateur +
  sous-agents, N boucles pi simultanées sur le même modèle. Chaque passe joue
  la suite seule (référence solo de la même exécution) puis la même suite dans
  N conteneurs lancés ensemble (`&` + `wait`, un `/work` jetable par conteneur,
  réseau hôte sans port publié, noms `bench-agentic-<pid>-p<passe>-i<inst>`
  tués par un trap INT/TERM ; image construite une fois avant la salve).
  Bilan : facteur de débit de tâches `(N x temps solo) / temps parallèle`,
  et décode / prefill / part du cache agrégés lus sur `/metrics?model=` côté
  hôte avant et après la salve (les deltas des N conteneurs se recouvrent,
  leurs t/s ne s'additionnent pas). Conséquence pour le tableau par scénario
  de la salve : seuls PASS et temps mur y sont propres, les colonnes venant
  de `/metrics` sortent en `n/c` (console et journal), le débit de la salve
  se lit sur la ligne de bilan agrégée. Le `parallel` réel vient de `/v1/models`
  → `status.args` (`py/spec_server_nmax.py --parallel`, comme
  `bench-parallel`) : N n'est pas plafonné, un dépassement est un `warn`.
  `N = 1` est le chemin historique, inchangé.
- `spec.sh` : `cmd_spec_test` (3e argument = prompt, journalisé),
  `cmd_spec_tune`, `cmd_spec_ngram_tune` (courbe `llama-bench` service
  arrêté, raffinement en boucle bornée sur les `STEP_LO/HI` de
  `batch_curve.py`, puis arbitrage par `cmd_spec_test` sur
  `spec-refactor.txt` ; médianes exposées via `SPEC_TEST_MED_GEN/ACC`),
  `cmd_spec_ab` (variantes `clé=val;…` appliquées par `SPEC_AB_OVERRIDES` /
  `_apply_overrides` dans `generate_models_ini`, restart + `cmd_spec_test`
  par variante, bilan comparé, rien d'écrit),
  `_spec_save_conf`, `_spec_save_ngram_conf`, `_preset_spec_types` /
  `_preset_has_spec_type` (un `spec-type` peut être une liste : ne jamais
  ancrer un grep sur `= draft-mtp`), sélection des modèles MTP et n-gram ;
  l'analyse est déléguée à `py/spec_analyze.py` et `py/batch_curve.py`.
- `service.sh` : ne contient plus que `cmd_migrate_off_systemd`, commande
  **temporaire** de bascule (stop, disable, suppression de l'unité,
  `daemon-reload`, contrôle que le port 8009 est libre). Idempotente, à retirer
  quand le parc sera passé. L'unité systemd, `--install-service`, le linger et
  le PATH de l'unité ont disparu avec la conteneurisation.
- `help.sh` : `cmd_help`.

Les fichiers de conf restent à côté du **point d'entrée** (`SCRIPT_DIR`),
jamais dans les sous-dossiers.

## Scripts Python (`py/`)

Appelés par chemin absolu `python3 "$SCRIPT_DIR/py/x.py"` (jamais relatif
au cwd : les commandes du dépôt sont lancées depuis n'importe où).
Python 3 stdlib uniquement.
Leurs sorties sont contractuelles : le bash les consomme au `sed -n`/`grep`
près — voir `tests/py-golden.sh`.

| Script | Entrées | Sorties | Appelé par |
|---|---|---|---|
| `timings.py --bench <json> <passe>` | réponse `/v1/chat/completions` en argv | ligne d'affichage + `PP=`/`G=`/`A=` (+ `PPCACHED=1` si `cache_n` > 0 en passe 1 → prefill marqué `*` au récap) | `_bench_one` (bench.sh) |
| `timings.py --spec <json> <passe> <flag>` | idem + `spec` si modèle spéculatif, `specmix` si spec-type en liste (acceptance agrégée sur les implémentations, stats au niveau slot côté serveur) | ligne + `GEN=`/`ACC=`/`DN= DA= PN=` | `cmd_spec_test` (spec.sh) |
| `build_body.py <modèle> <max_tokens> <seed> <fichier prompt> [fichier...]` (contenus joints par une ligne vide) | fichiers de `prompts/` | body JSON (`json.dumps`) sur stdout | `_bench_one`, `cmd_spec_test` |
| `spec_server_nmax.py <modèle> [flag]` | JSON de `/v1/models` sur stdin | valeur réelle du flag (défaut `--spec-draft-n-max` ; aussi `--spec-type`, `--spec-ngram-map-k-size-m`), vide si absent | `cmd_spec_test` |
| `batch_curve.py <modèle> <device> <depth> [tsv] [rec]` | jsonl de `llama-bench -o jsonl` sur stdin (plusieurs balayages concaténés, le plus récent fait foi) | tableau batch/size_m/coût/seuil/gain, marches, baisses au-delà du bruit, tailles dominées, verdict ; `SIZEM_SAFE=`/`SIZEM_LARGE=`/`STEP_LO=`/`STEP_HI=` si `rec` ; append TSV si fichier donné | `cmd_spec_ngram_tune`, `tools/bench-spec-batch.sh` |
| `depth_curve.py <modèle> <device> <pp> <gen> [tsv] [rec]` | jsonl de `llama-bench -d` sur stdin | tableau prefill/décode/tour simulé par profondeur, dégradation de 0 à la profondeur max, `TOUR_<depth>=` si `rec` ; append TSV | `tools/bench-depth.sh` |
| `spec_isolate_bench.py --port --tag --out --prompts --passes --max-tokens --np [--seed] [--temp]` | le serveur jetable de `tools/spec-isolate.sh` sur `--port` | tableau par passe (prefill, décode, acceptance, sanité, aperçu), salve simultanée si `--np > 1`, médianes hors 1re passe ; append `<out>/mesures.tsv` et `<out>/gen-*.txt` | `tools/spec-isolate.sh` |
| `check_answer.py <json> <attendu>` | réponse `/v1/chat/completions` | ligne lisible ; code 0 si la valeur attendue est dans la réponse (ou le raisonnement), 1 sinon | `_bench_sanity_one` (bench.sh) |
| `cache_stats.py <json> <étiquette>` | réponse `/v1/chat/completions` | ligne lisible + `PN=` (tokens du prompt) `CN=` (servis du cache) `PMS=` (prefill ms) | `cmd_bench_cache` |
| `parallel_agg.py <temps_mur_s> <réponse.json>...` | réponses d'une salve de requêtes simultanées | ligne lisible + `AGG=` (tokens / temps mur) `MED=` (décode médian par requête) `TOK=` `ERR=` | `_bench_parallel_salve` (bench.sh) |
| `bench_compare.py <bench.log> <modèle>...` | `logs/bench.log` (TSV) | pour chaque modèle, écart prefill/décode au run précédent du même GGUF/device **et du même mode EC** (à défaut, le dernier run avec la mention « mode EC différent »), build rappelé s'il a changé, drapeau à ±5 % | `cmd_bench` |
| `spec_analyze.py <log> <modèle> <gguf> <device> <k> [rec]` | `logs/spec-tests.log` (TSV) | rapport texte + `REC=k` si demandé ; **réécrit le log** (quarantaine) | `_spec_analyze` (spec.sh) |
| `perf_graphs.py [<tsv> [<dossier>]]` | `docs/perfs.tsv` (TSV versionné, une ligne par section servie, deux séries : fork Vulkan0 et moteur conteneurisé ROCm0) | `docs/graphs/prefill.svg`, `decode.svg`, `ecarts.svg` (SVG statiques, rendu sobre, tracé déterministe → sortie reproductible) | personne : lancé à la main quand la table du parc change (README, skill `ajout-modele` étape 6) |

## Prompts de mesure (`prompts/`)

Texte brut (français, multiligne autorisé), chargé par `build_body.py` qui
fait l'échappement JSON — plus aucun texte pré-échappé dans le bash.

| Fichier | Consommé par | Contenu |
|---|---|---|
| `spec-test.txt` | `cmd_spec_test` | prompt de référence (module `inventory.py` + tests pytest — code structuré = meilleur cas MTP) ; seul prompt qui alimente la calibration α |
| `spec-refactor.txt` | `cmd_spec_ngram_tune` (via `cmd_spec_test`) | le même module fourni dans le contexte, avec des blocs à recopier exactement puis à remplacer (forme oldString/newString d'opencode) : le seul cas où un n-gram a des hits, donc le seul qui départage deux `size_m` |
| `bench-context.txt` | `_bench_one` | contexte réaliste du bench : cahier des charges du système que la tâche demande d'implémenter (long prefill varié ; taille réelle = `n=` de la passe 1) |
| `bench-sanity.txt` | `_bench_sanity_one` | recopie exacte d'un code (`LAMPADAIRE-2719`) : contrôle de justesse du moteur, volontairement trivial pour ne tester que le backend, pas le modèle |
| `bench-task.txt` | `_bench_one` | tâche de génération posée après le contexte (référence les sections du cahier des charges) |

**⚠ Comparabilité.** Modifier un de ces fichiers invalide les comparaisons
avec les runs journalisés et la calibration n-max : après un changement de
`spec-test.txt`, les anciennes lignes de `spec-tests.log` ne sont plus
comparables — repartir sur un journal vierge (ou laisser la quarantaine et
l'écart de mesures le révéler). Idem pour le bench : les tableaux avant/après
modification de `bench-task.txt` ou `bench-context.txt` ne se comparent pas.
Ne jamais modifier un prompt au détour d'un autre changement ; le signaler
dans le message de commit.

## Cycle de vie d'un modèle

1. Défaut : corps `MODEL_INI[modèle]` (models.sh), plus les flags globaux du
   `[*]` (device `ROCm0`, `fit = off`, `load-mode = none`, cache K et V `f16`).
2. Surcharges appliquées par `generate_models_ini` :
   `spec-nmax.conf` (substitution de `spec-draft-n-max`),
   `spec-ngram.conf` (substitution de `spec-ngram-map-k-size-m`),
   `preload.conf` (ajout de `load-on-startup = true`).
3. Émission dans l'ordre `PRESET_ORDER`, avec les séparateurs de groupe.
4. Le routeur charge le ini au démarrage ; ce qui tourne se lit sur
   `/v1/models` (`status.args`), pas dans le ini.

## Modèle d'analyse n-max (`spec_analyze.py`)

Par forward, k tokens draftés, acceptés en séquence avec probabilité α par
position : tokens/forward `T(k) = 1 + Σ_{i=1..k} α^i` ; temps/forward
`t(k) = t_base + k·t_draft` → `t/s = T(k)/t(k)`. α est ajusté (bissection)
sur le run courant, `t_base`/`t_draft` par régression sur les runs à n-max
distincts (même modèle/GGUF/device, un point par n-max : le plus récent).
Recommandation : à <2 % du max, le plus petit k (l'acceptance chute sur du
texte moins prévisible que le prompt de test) ; les **mesures priment sur le
modèle** (REC= = meilleur mesuré). Garde-fou : tokens/forward > k+1 = run
incohérent (ini changé sans restart) → quarantaine automatique dans le log
(ligne commentée `;`). Limites : α supposé constant par position et par type
de texte ; t(k) affine ; le modèle sert à suggérer le prochain k à mesurer,
pas à remplacer la mesure.

Journal `logs/spec-tests.log` (TSV) : `date modèle gguf device nmax gen acc
drafted accepted predicted spectype prompt build ec_mode`. Les colonnes 11 et 12
datent du support des listes et du prompt paramétrable, la 13 du passage en
`logs/`, la 14 du mode d'alimentation de l'APU (16/09/2026) ; absentes =
`draft-mtp` seul sur `spec-test.txt`, build et mode inconnus. `spec_analyze.py` écarte (sans quarantaine : ils sont
valides, juste hors modèle) les runs en spec-type mixte, dont le k varie
par forward, et ceux d'un autre prompt ; sans ce filtre le garde-fou
tokens/forward > k+1 les commenterait tous. C'est pourquoi `--spec-tune`
mesure en `draft-mtp` seul (`SPEC_TYPE_FORCE=draft-mtp`).

## Réglage n-gram (`batch_curve.py`, `--spec-ngram-tune`)

Un draft de `size_m` tokens est vérifié dans un forward de batch
`size_m + 1`. Le gain ne dépend que de la forme de `t_forward(batch)`, qui
a des marches : ggml change de noyau selon la taille du batch (mesuré sur
ggml-vulkan, `mul_mat_vec_max_cols = 8`, x2 entre batch 8 et 9, sur un dense
et un MoE ; seuil non rejoué sur le moteur HIP de l'image, les `size-m`
antérieurs au 18/09/2026 en découlent). Deux régimes seulement ont du sens, le script sort les deux :
**sûr** = plus grande taille sous la première marche (seuil de non-perte
minimal), **large** = taille qui maximise `gain = batch / coût relatif` sous
`PART_SEUIL_MAX` (25 % du draft). Une marche est un saut de coût **par unité
de batch** > `FACTEUR_MARCHE` (1,5) : normaliser est indispensable, la pente
d'un MoE double aussi le coût entre 1 et 8 sans changer de noyau. Mais un
balayage grossier ne peut pas voir une marche entre deux de ses points (x2,13
entre 8 et 9 se dilue en x1,11 par unité entre 8 et 16) : les sauts bruts
suspects entre batches non consécutifs sont renvoyés en `STEP_LO/HI` et le
bash les raffine batch par batch, en boucle bornée, jusqu'à ce qu'il n'en
reste plus. Les baisses de `t_forward` ne sont signalées qu'au-delà de
3 sigma (bruit combiné). L'arbitrage final est une mesure réelle : la
courbe ne connaît ni la longueur des répétitions rencontrées, ni la
fréquence des hits, ni leur acceptance, et un miss ne coûte qu'une sonde de
hash. Quand aucune taille ne passe `PART_SEUIL_MAX`, `candidats()` se replie
sur deux tailles à mesurer (la plus grande <= `SIZEM_REPLI` = 7, et le
meilleur gain brut) au lieu de conclure (DeepSeek V4 : +9 % réels avec 7
malgré un seuil de 45 %). Sur un modèle sans MTP le tune mesure d'abord une
référence en `spec-type none` (`SPEC_TYPE_FORCE`) et n'écrit rien si aucun
`size_m` ne la bat. `min-hits`
n'est pas réglé (second ordre, restarts multipliés), il vit dans
`lib/models.sh`.

## Le device : plus de choix depuis le 18/09/2026

Le moteur du service est l'image de `runtime/`, construite en **HIP seul** :
elle n'expose que `ROCm0`. `--bench-devices`, `bench-devices.conf`,
`BENCH_DEVICE*`, `_bench_save_device` et `lib/bench/bench-devices.sh` ont donc
été retirés, et `DEFAULT_DEVICE` (`lib/models.sh`) est la seule valeur écrite
dans le ini, sur quatre lignes par section : `device`, `device-draft`,
`spec-draft-ngl = all` et `mmproj-device`, pour qu'aucun morceau du modèle
(drafter, projecteur vision) n'atterrisse ailleurs que sur sa cible.

Ce qui en reste :

- **`--bench-sanity`** (la question de contrôle, `prompts/bench-sanity.txt`) :
  c'était la porte d'entrée de `--bench-devices`, c'est maintenant la première
  étape, **bloquante**, de `tools/qualif-modele.sh`. Elle attrape un texte
  propre mais faux, là où le garde-fou « sortie dégénérée » de `timings.py`
  attrape le charabia. Les deux servent : un backend cassé produit des t/s
  superbes (DeepSeek V4 sur le ROCm système, 550 t/s de « Nous dev dev dev »).
- **`--list-devices`** : un contrôle, plus un choix. Il montre l'étiquette du
  moteur, puis les devices de l'IMAGE (`_dk_run llama-bench --list-devices`),
  et alerte si `ROCm0` manque : sans lui, rien ne charge.
- **le verdict de tour simulé** (`t = PP_froid/prefill + GEN/décode`, profil
  2000 / 3000) n'a plus de commande, mais il reste la bonne façon de trancher
  un compromis prefill contre décode à la main : c'est ainsi que se lit le cas
  `qwen3.8-27b-dflash-nothink` sur le nouveau moteur (+26 % de décode, -24 % de
  prefill, cf. son bloc). Limites inchangées : modèle linéaire, acceptance déjà
  incluse dans le décode mesuré.

Historique, pour mémoire : le verdict comparait Vulkan0 et ROCm0 parce que
chacun gagnait une métrique (exemple du 16/08/2026, qwen3.8-27b-mtp-nothink :
Vulkan0 307 pp / 29,9 tg = 106,7 s ; ROCm0 356 / 21,8 = 143,3 s). Ce ROCm0-là
est le ROCm SYSTÈME, sans rapport avec le runtime retained-PM4 de l'image.

## Garde mémoire avant chargement (`_ensure_room_for`)

Le routeur charge un modèle à la première requête et évince en LRU, sans
regarder les tailles : sur 124 Go de RAM unifiée, évincer lfm2.5 (3 Go) pour
faire entrer DeepSeek (104 Go) pendant que Laguna (73 Go) tient encore finit
par l'OOM killer (deux routeurs tués le 13/09/2026, mesures perdues, service
coupé le temps du `Restart=on-failure`).

`_ensure_room_for <modèle>` (lib/common.sh) est donc appelé avant la première
requête de chaque mesure (`_bench_one`, `_bench_sanity_one`, `cmd_bench_cache`,
`cmd_bench_parallel`, `cmd_spec_test`, donc aussi `--spec-ab`). Dans l'ordre :

1. taille estimée du modèle = somme des GGUF de sa ligne `model =` (shards
   compris : le ini ne nomme que le premier, le routeur charge la série) plus
   son `spec-draft-model`, majorée de `BENCH_ROOM_MARGE_PCT` % (défaut 10) pour
   le KV. La taille disque est une borne **basse** assumée : la garde doit être
   du bon ordre de grandeur, pas juste ;
2. mémoire disponible = colonne `available` de `free -b` ;
3. tant qu'elle manque : déchargement par `POST /models/unload` du plus gros
   modèle chargé (`GET /models`, `status.value = loaded`) qui n'est pas dans
   `preload.conf` — un préchargé seulement s'il ne reste que lui, avec un
   `warn` ; puis attente courte (`BENCH_ROOM_TIMEOUT`, défaut 30 s) que `free`
   reflète la libération, le routeur répondant avant que le noyau rende les
   pages ;
4. place toujours introuvable = `warn` et chargement tenté quand même.

Jamais de restart, rien d'écrit, et `BENCH_NO_UNLOAD=1` désactive tout : la
mesure redevient strictement passive. Limite connue : le modèle chargé est
mmap'é, donc une partie de ses pages est comptée par `free` comme cache
récupérable — la garde sous-estime plutôt qu'elle ne surestime la place, d'où
la marge et le `warn` final.

## Journaux de mesure (`logs/`)

Tous locaux (.gitignore), TSV en append, une ligne par mesure, toujours avec
le build de llama.cpp : un chiffre sans son build ne se compare pas. Une
colonne nouvelle s'ajoute à droite avec un défaut pour les lignes courtes.

| Fichier | Écrit par | Colonnes |
|---|---|---|
| `spec-tests.log` | `cmd_spec_test` | `date modèle gguf device nmax gen acc drafted accepted predicted spectype prompt build ec_mode` |
| `bench.log` | `_bench_one` | `date modèle gguf device build prefill décode acceptance passes prefill_cache ec_mode` ; lu par `bench_compare.py` |
| `bench-parallel.log` | `cmd_bench_parallel` | `date modèle device build parallel_srv n agrégé décode_par_requête passes` |
| `bench-cache.log` | `cmd_bench_cache` | `date modèle device build part_suite part_edit part_identique ms_froid ms_suite ms_edit ms_identique` |
| `bench-agentic.log` | `cmd_bench_agentic` | `date modèle device build passe scénario verdict mur_s prompt_tok cache_tok gen_tok prefill_tps decode_tps N` (une ligne par scénario et par passe, passe 0 = appel froid ; `N` = boucles simultanées de la salve, 1 pour la référence solo ; colonne ajoutée en queue le 15/09/2026, les lignes antérieures à 13 colonnes restent lisibles ; sur les lignes `N > 1`, `prompt_tok`..`decode_tps` valent `n/c`, chaque conteneur lisant le compteur global du serveur) |
| `bench-load.log` | `cmd_bench_load` | `date modèle gguf device build taille chargement_s ttft_chaud_ms` |
| `spec-batch.log` / `.tsv` | `tools/bench-spec-batch.sh` | lisible / `date modele device depth fa_reel batch t_forward_ms sd_ms cout_rel gain_max` |
| `bench-depth.log` / `.tsv` | `tools/bench-depth.sh` | lisible / `date modele device depth pp_ts pp_sd tg_ts tg_sd tour_s` |
| `qualif/<tag>/` | `tools/qualif-modele.sh` | `01-devices.log` … `07-agentic.log` (sortie brute de chaque étape) et `resume.md` (en-tête, tableau de perfs, table des étapes) |
| `spec-isolate/<tag>/mesures.tsv` | `tools/spec-isolate.sh` | `date tag prompt np mesure pp gen n draft_n accepted acceptance sain agrege ec_mode` (`agrege` vide sur les passes séquentielles, débit agrégé de la salve sur les lignes np > 1 ; à côté de `serveur.log` et des `gen-*.txt` du même dossier) |

`device` est l'état réel du serveur (`/v1/models`, flag `--device`) partout
où le serveur est en cause, le device demandé pour les outils `llama-bench`.

## Outils hors service (`tools/`)

`bench-spec-batch.sh` : balayage `llama-bench` brut d'un ou plusieurs GGUF
sur un ou plusieurs devices, sans passer par le service (à arrêter soi-même
pour une mesure propre, l'état est journalisé). Journal lisible
`logs/spec-batch.log` et TSV `logs/spec-batch.tsv`. Sert à
explorer ; pour régler, `--spec-ngram-tune`. Les autres fichiers de `tools/`
(sync opencode, extension pi) sont décrits dans le README.

`spec-isolate.sh <tag> -- <args llama-server...>` : monte un `llama-server`
JETABLE (port 8099 par défaut, jamais 8009) avec les arguments bruts passés
après `--`, mesure la spéculation par `py/spec_isolate_bench.py`, le tue et
relance le service. Sert AVANT la déclaration d'un modèle dans `lib/models.sh`
(étape 2 de la skill ajout-modele) : le drafter se charge-t-il, quelle
acceptance, quel `spec-draft-n-max`. Rien n'est écrit dans le ini ni dans les
`.conf`. Le service est arrêté par l'outil et relancé par son trap (EXIT, INT,
TERM) ; l'outil REFUSE de démarrer si une mesure du dépôt tourne déjà
(`setup-llm.sh --bench*` / `--spec*`, conteneur `bench-agentic-*`) : un seul
GPU. Variables : `PORT`, `NP` (ajoute `-np` et une salve simultanée),
`PASSES`, `PROMPTS`, `MAX_TOKENS`, `OUT`. Sorties dans
`logs/spec-isolate/<tag>/`. Le verdict se confirme ensuite sur le service par
`--spec-ab` / `--spec-test`.

`qualif-modele.sh <section> [options]` : enchaîne, sur un modèle DÉJÀ déclaré
dans `lib/models.sh` et servi par le routeur, les étapes 3, 5, 6 et 7 de la
skill ajout-modele : `--bench-sanity` (bloquante), `--spec-ab` (sur `spec-refactor.txt`
puis `spec-test.txt`), `--bench`, `--bench-cache`, `--bench-load` et
`--bench-agentic`, toutes en séquence (un seul GPU) et toutes avec leur entrée
sur `/dev/null`. Les variantes de `--spec-ab` sont dérivées du drafter et du
`size-m` RÉELLEMENT servis, lus dans `status.args` de `/v1/models`. Mêmes
refus de démarrage que `spec-isolate.sh` (mesure du dépôt en cours,
`spec-isolate.sh`, conteneur `bench-agentic-*`). Sorties dans
`logs/qualif/<tag>/` : un journal par étape et `resume.md`, le tableau de
l'étape 6 rempli par parsing des bilans (codes ANSI filtrés, `n/c` quand un
motif manque). Une étape en échec n'arrête pas les suivantes ; code de retour
non nul si l'une a échoué, sauf l'étape de justesse, qui ARRÊTE la
qualification. N'écrit ni `lib/models.sh` ni les `.conf` ; ne joue ni le
test isolé ni `--spec-tune`.

`bench-depth.sh` : même principe avec `llama-bench -d` (profondeur de KV
avant la mesure) : prefill et décode à 0 / 16k / 32k (64k sur demande), KV
en q8_0 comme le service, tour simulé par profondeur et par device. Journal
`logs/bench-depth.log` + `.tsv`.

## Moteur conteneurisé (`runtime/`)

Dossier **versionné**, consommé par `lib/runtime.sh` et par personne d'autre.

| Fichier | Rôle |
|---|---|
| `Dockerfile.rocm-strix` | copie vendorisée du Dockerfile de la PR 133 de `kyuz0/amd-strix-halo-toolboxes` (ROCm 10.0 gfx1151 + ROCr/HIP retained-PM4 de `pwilkin/rocm-systems` + `halo-box/strix-llama.cpp` en HIP seul), qui porte aussi les **révisions épinglées** dans deux `ARG` et, en tête, le bloc « Révisions épinglées » qui dit comment les faire bouger |
| `patches/` | les deux patchs que le build applique au moteur (grammaire, contournement llama.cpp #25992) |
| `AMONT.md` | provenance, **liste exacte des écarts** avec l'amont, procédure de resynchronisation |

Trois choix structurent le reste :

1. **L'image ne contient que le moteur et son runtime** — pas de modèle, pas de
   configuration, pas de cache, pas d'état. Les poids arrivent par le montage en
   lecture seule (compose du service, ou `_dk_run`), `models.ini` reste dans
   `~/models`. Une image est donc jetable, et un `COPY` amont d'outil ou de
   données ne se reprend pas.
2. **Un seul tag, `llm-rocm-strix:latest`.** Reconstruire prend quelques
   minutes, on ne collectionne pas les images. Ce qu'une image contient
   RÉELLEMENT se lit dans `/opt/strix/versions.txt`, dedans ; ce qui a été
   demandé se lit dans les deux `ARG` du Dockerfile, dont **l'historique git EST
   le journal des révisions**. Il n'y a pas de rollback par tag : revenir en
   arrière, c'est y remettre les anciennes révisions et reconstruire. L'image
   remplacée perd son tag et se retire à la main (`docker image prune`, jamais
   `-a` : la machine héberge les images d'autres outils).
3. **Un Dockerfile et un compose, rien entre les deux.** Le bloc `build` de
   `runtime/docker-compose.yml` porte le contexte (`RUNTIME_DIR`) et le Dockerfile ;
   `--image-build` n'est qu'un raccourci vers `docker compose build`. La couche
   d'abstraction du 17/09/2026 (`image.conf`, `LABEL llm-setup.*`, promotion
   sous tag temporaire, purge par label, `logs/images.tsv`, `--image-update`,
   `--image-status`) a été retirée le 18/09/2026 : trop lourde pour ce qu'elle
   protégeait.

L'épinglage des deux `ARG` est le seul écart de fond avec l'amont, qui assume
de ne rien épingler. Le motif : un moteur qui change tout seul rend les séries
de mesures incomparables.

## Invariants (à ne pas casser)

- `models.ini` **byte-identique** à confs égales : `generate_models_ini` est
  déterministe, toute variation vient d'un choix explicite (modèle ou conf).
- Sorties des `py/*.py` au caractère près — `tests/py-golden.sh`
  (fixtures capturées sur le code inline d'origine).
- `parallel` est un choix par modèle (contexte par slot, mémoire, rendement
  mesuré de la spéculation), pas une contrainte de `spec-type` : le « np > 1
  non supporté avec MTP » affirmé ici jusqu'au 15/09/2026 venait d'une doc
  unsloth, absente de la dorsale `strix-llama.cpp` que sert l'image (vérifié
  le 15/09/2026 sur le fork, moteur du service à cette date) ; seul `--mmproj`
  reste incompatible avec un drafter.
- `--cleanup` piloté uniquement par `KNOWN_FILES`. Les deux artefacts générés
  de `~/models` (`models.ini`, `.env`) sont hors d'atteinte **par
  construction** : le premier `find` ne liste que des dossiers de premier
  niveau, le second que des `*.gguf` à partir de la profondeur 2. Ne pas
  « corriger » ces `find`.
- Aucun ménage d'images automatique : après un build, l'image remplacée perd
  son tag et attend un `docker image prune` **à la main, sans `-a`**. Jamais
  `docker system prune`, jamais une image taguée qu'on n'a pas construite.
- Les révisions du moteur ne vivent qu'à UN endroit, les deux `ARG` de
  `runtime/Dockerfile.rocm-strix`, et ne bougent qu'à la main, dans un commit
  qui dit pourquoi.
- Restart requis après toute régénération du ini (routeur = lecture au boot).
- **Jamais `docker compose restart`** : il relance le conteneur existant, donc
  l'ancienne image, l'ancienne ligne de commande et l'ancien `--models-max`.
  `_svc_restart` est un `stop` puis un `start`.
- Le `.env` est **régénéré à chaque démarrage** (`_svc_start`), jamais édité :
  `--models-max` suit `preload.conf`, `RUNTIME_DIR` suit le dépôt, les gid
  suivent l'hôte. Le compose, lui, est versionné et ne porte **aucune** valeur
  machine : chaque variable y est obligatoire (`${VAR:?}`), un `.env` incomplet
  fait refuser le fichier par docker au lieu de monter un service à moitié.
- Les tuners (`--spec-ab`, `--spec-tune`, `--spec-ngram-tune`, `--bench-load`)
  ne régénèrent que le **ini** (`regen_models_ini`), jamais le compose : leurs
  surcharges sont temporaires et n'ont rien à voir avec la forme du service.
  `regen_models_ini` n'appelle donc pas `regen_env`.
- L'attente de `/health` vit à UN seul endroit, `_svc_wait_ready` (appelée par
  `_svc_start` / `_svc_restart`) : plus de boucle recopiée dans les mesures.
  Une commande qui rend la main a un service qui répond, ou elle a échoué.
- `seccomp=unconfined` est le seul assouplissement du conteneur (exigé par les
  ioctl du KFD côté ROCr) ; il est compensé par `cap_drop: [ALL]` et
  `no-new-privileges`. Jamais `privileged`, jamais `docker.sock`, jamais
  `network_mode: host`, jamais de `mem_limit` (la garde mémoire raisonne sur le
  `available` de l'hôte).
- Mesures spec : l'état réel vient de `/v1/models`, jamais du script/ini.
- Une mesure ne redémarre pas le routeur pour faire de la place : la garde
  mémoire (`_ensure_room_for`) ne décharge que par l'API, jamais un modèle
  préchargé tant qu'un autre peut partir, et n'échoue jamais une campagne —
  place introuvable = `warn` puis chargement tenté quand même.
- `spec-type` peut être une liste : tester l'appartenance
  (`_preset_has_spec_type`), jamais un grep ancré sur `= draft-mtp`.
- Les lignes existantes des journaux (`logs/*.log`) restent lisibles : toute
  colonne nouvelle s'ajoute à droite avec un défaut pour les lignes courtes.
- Tout journal de mesure porte l'étiquette du moteur SERVI (`_llama_build`) :
  un chiffre sans son build ne se compare pas. L'étiquette est une CHAÎNE, pas
  un nombre - `strix-<engine7>+r<rocm7>`, lue par un `grep` sur les deux `ARG`
  `*_REV` de `runtime/Dockerfile.rocm-strix` (repli : `?`). Jamais en lançant un
  conteneur : la fonction est appelée à chaque journal. C'est la SEULE
  étiquette du dépôt depuis le retrait du fork (18/09/2026) : le service et les
  outils hors service tournent sur la même image. Chaque révision d'image ouvre
  une série distincte, jamais comparable à une autre.
- Entrée non interactive (`! -t 0`) gérée partout : jamais de question, jamais
  de restart automatique.
