# ARCHITECTURE

## Flux de données

```
lib/presets.sh (MODEL_INI, défauts)
        │
        ▼                    surcharges
generate_models_ini  ◄──  bench-devices.conf   (device par GGUF)
   (lib/ini.sh)      ◄──  spec-nmax.conf       (spec-draft-n-max par preset)
        │            ◄──  preload.conf         (load-on-startup)
        ▼
~/models/models.ini  ──►  llama-server --models-preset (router mode)
                          ⚠ lu AU DÉMARRAGE SEULEMENT → restart requis
```

Le script ne parle jamais directement aux GGUF pour mesurer : `--bench` et
`--spec-test` passent par l'API du serveur **tel qu'il tourne**
(`/v1/chat/completions`, `/v1/models`). Toute mesure dépendant d'un paramètre
de preset lit l'état réel du serveur (`/v1/models` → `status.args`), pas le
script ni le ini — c'est l'invariant n° 1 de `cmd_spec_test`, à ne pas
régresser.

## Ordre de source et dépendances

`setup-llm.sh` (point d'entrée) définit `SCRIPT_DIR` puis source, dans cet
ordre imposé :

```
common → models → presets → ini → preload → setup → bench → spec → service → help
```

- `common.sh` : helpers (`info/warn/error`, `_key`, `_skip`, `_path_for_key`,
  `_dl`, `_dl_shard`, `_maybe_restart_service`) et **toutes les variables
  globales de config** : `MODELS_BASE`, `CONFIG_DIR`, `BENCH_CONF`,
  `PRELOAD_CONF`, `SPEC_TEST_URL`, `SPEC_LOG`, `SPEC_CONF`, `SERVICE_NAME`,
  `SERVICE_FILE`, `REFRESH`/`ONLY`, plus les migrations one-shot des `.conf`
  depuis `$CONFIG_DIR`. Elles vivent ici parce que plusieurs modules les
  consomment (`_maybe_restart_service` utilise `SERVICE_NAME`, `cmd_bench`
  utilise `SPEC_TEST_URL`) — définies **avant** toute fonction qui les utilise.
- `models.sh` : repos/fichiers HF (`MODEL_*_REPO/FILE`), chemins `*_PATH`,
  `KNOWN_FILES` (inventaire, source unique de `--cleanup` et des mkdir),
  `ROCM_PKGS`.
- `presets.sh` : `DEFAULT_DEVICE`, `BENCH_DEVICES`, `MODEL_INI[...]` (corps des
  presets **avec leurs commentaires métier** : sampling officiels, contraintes
  cache/MTP/SWA, historique des choix) et `PRESET_ORDER` (l'ordre d'émission —
  `declare -A` ne préserve pas l'ordre d'insertion).
- `ini.sh` : loaders des trois confs (`load_bench_conf`, `load_preload_conf`,
  `load_spec_conf`), `_preset_model_key`, `_preset_nmax` (surcharge
  conf > défaut script, `SPEC_NMAX_FORCE` prime — utilisé par `--spec-tune`),
  `generate_models_ini`.
- `preload.sh` : sélection interactive (`select_preload_models`, gum ou
  fallback numéroté), `_save_preload_conf`, `_preload_sanity` (garde-fous
  doublons de GGUF), `cmd_preload`.
- `setup.sh` : `cmd_setup` (dépendances, ROCm best-effort, téléchargements),
  `cmd_update` (= setup avec `REFRESH=1`, `hf` compare les etags),
  `cmd_cleanup` (piloté par `KNOWN_FILES`, dry-run par défaut).
- `bench.sh` : `cmd_bench` (mesure API du serveur en l'état), `_bench_one`,
  sélections, `cmd_list_devices`.
- `spec.sh` : `cmd_spec_test`, `cmd_spec_tune`, `_spec_save_conf`, sélection
  des presets MTP ; l'analyse est déléguée à `lib/py/spec_analyze.py`.
- `service.sh` : `cmd_start` (`--models-max` = préchargés + 1, min 2),
  `cmd_install_service` (service **système**, `ExecStart` via `realpath` du
  script, `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` posé d'office pour ROCm/iGPU),
  `cmd_uninstall_service`.
- `help.sh` : `cmd_help`.

Les fichiers de conf restent à côté du **point d'entrée** (`SCRIPT_DIR`),
jamais dans les sous-dossiers.

## Scripts Python (`lib/py/`)

Appelés par chemin absolu `python3 "$SCRIPT_DIR/lib/py/x.py"` (jamais relatif
au cwd : le service systemd démarre ailleurs). Python 3 stdlib uniquement.
Leurs sorties sont contractuelles : le bash les consomme au `sed -n`/`grep`
près — voir `tests/py-golden.sh`.

| Script | Entrées | Sorties | Appelé par |
|---|---|---|---|
| `timings.py --bench <json> <passe>` | réponse `/v1/chat/completions` en argv | ligne d'affichage + `PP=`/`G=`/`A=` | `_bench_one` (bench.sh) |
| `timings.py --spec <json> <passe> <flag>` | idem + `spec` si preset spéculatif | ligne + `GEN=`/`ACC=`/`DN= DA= PN=` | `cmd_spec_test` (spec.sh) |
| `build_body.py <preset> <max_tokens> <seed> <prompt> [--filler-file F --filler-repeat N]` | fichiers de `lib/prompts/` | body JSON (`json.dumps`) sur stdout | `_bench_one`, `cmd_spec_test` |
| `spec_server_nmax.py <preset>` | JSON de `/v1/models` sur stdin | n-max réel du serveur (vide si absent) | `cmd_spec_test` |
| `spec_analyze.py <log> <preset> <gguf> <device> <k> [rec]` | `spec-tests.log` (TSV) | rapport texte + `REC=k` si demandé ; **réécrit le log** (quarantaine) | `_spec_analyze` (spec.sh) |

## Prompts de mesure (`lib/prompts/`)

Texte brut (français, multiligne autorisé), chargé par `build_body.py` qui
fait l'échappement JSON — plus aucun texte pré-échappé dans le bash.

| Fichier | Consommé par | Contenu |
|---|---|---|
| `spec-test.txt` | `cmd_spec_test` | prompt de référence (module `inventory.py` + tests pytest — code structuré = meilleur cas MTP) |
| `bench-task.txt` | `_bench_one` | tâche posée après le préfixe de remplissage |
| `bench-filler.txt` | `_bench_one` | phrase ~20 tokens, répétée `BENCH_FILLER_REPEAT` (400) fois → prefill ~8K. ⚠ La ligne se termine par **un espace significatif** avant le newline |

**⚠ Comparabilité.** Modifier un de ces fichiers invalide les comparaisons
avec les runs journalisés et la calibration n-max : après un changement de
`spec-test.txt`, les anciennes lignes de `spec-tests.log` ne sont plus
comparables — repartir sur un journal vierge (ou laisser la quarantaine et
l'écart de mesures le révéler). Idem pour le bench : les tableaux avant/après
modification de `bench-task.txt` ou `bench-filler.txt` ne se comparent pas.
Ne jamais modifier un prompt au détour d'un autre changement ; le signaler
dans le message de commit.

## Cycle de vie d'un preset

1. Défaut : corps `MODEL_INI[preset]` (presets.sh), device hérité du `[*]`
   (Vulkan0).
2. Surcharges appliquées par `generate_models_ini` :
   `bench-devices.conf` (ligne `device =` si le vainqueur du GGUF ≠ défaut ;
   clé = **dossier du GGUF**, donc partagée entre presets d'un même fichier),
   `spec-nmax.conf` (substitution de `spec-draft-n-max`),
   `preload.conf` (ajout de `load-on-startup = true`).
3. Émission dans l'ordre `PRESET_ORDER`, avec les séparateurs de groupe.
4. Le routeur charge le ini au démarrage ; ce qui tourne se lit sur
   `/v1/models` (`status.args`), pas dans le ini.

## Modèle d'analyse n-max (`spec_analyze.py`)

Par forward, k tokens draftés, acceptés en séquence avec probabilité α par
position : tokens/forward `T(k) = 1 + Σ_{i=1..k} α^i` ; temps/forward
`t(k) = t_base + k·t_draft` → `t/s = T(k)/t(k)`. α est ajusté (bissection)
sur le run courant, `t_base`/`t_draft` par régression sur les runs à n-max
distincts (même preset/GGUF/device, un point par n-max : le plus récent).
Recommandation : à <2 % du max, le plus petit k (l'acceptance chute sur du
texte moins prévisible que le prompt de test) ; les **mesures priment sur le
modèle** (REC= = meilleur mesuré). Garde-fou : tokens/forward > k+1 = run
incohérent (ini changé sans restart) → quarantaine automatique dans le log
(ligne commentée `;`). Limites : α supposé constant par position et par type
de texte ; t(k) affine ; le modèle sert à suggérer le prochain k à mesurer,
pas à remplacer la mesure.

## Invariants (à ne pas casser)

- `models.ini` **byte-identique** à confs égales : `generate_models_ini` est
  déterministe, toute variation vient d'un choix explicite (preset ou conf).
- Sorties des `lib/py/*.py` au caractère près — `tests/py-golden.sh`
  (fixtures capturées sur le code inline d'origine).
- `parallel = 1` sur tous les presets MTP (contrainte llama.cpp np/mmproj).
- `--cleanup` piloté uniquement par `KNOWN_FILES`.
- Restart requis après toute régénération du ini (routeur = lecture au boot).
- Mesures spec : l'état réel vient de `/v1/models`, jamais du script/ini.
- Entrée non interactive (`! -t 0`) gérée partout : jamais de question, jamais
  de restart automatique.
