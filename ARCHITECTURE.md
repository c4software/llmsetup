# ARCHITECTURE

## Flux de données

```
lib/models.sh (déclarations : download_hf/llama_model/groupe → MODEL_INI, défauts)
        │
        ▼                    surcharges
generate_models_ini  ◄──  bench-devices.conf   (device par GGUF)
   (lib/ini.sh)      ◄──  spec-nmax.conf       (spec-draft-n-max par modèle)
        │            ◄──  preload.conf         (load-on-startup)
        ▼
~/models/models.ini  ──►  llama-server --models-preset (router mode)
                          ⚠ lu AU DÉMARRAGE SEULEMENT → restart requis
```

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
common → models → ini → preload → setup → bench → spec → service → help
```

- `common.sh` : helpers (`info/warn/error`, `_key`, `_skip`,
  `_dl`, `_dl_shard`, `_maybe_restart_service`) et **toutes les variables
  globales de config** : `MODELS_BASE`, `CONFIG_DIR`, `BENCH_CONF`,
  `PRELOAD_CONF`, `SPEC_TEST_URL`, `SPEC_LOG`, `SPEC_CONF`, `SERVICE_NAME`,
  `SERVICE_FILE`, `REFRESH`/`ONLY`. Elles vivent ici parce que plusieurs modules les
  consomment (`_maybe_restart_service` utilise `SERVICE_NAME`, `cmd_bench`
  utilise `SPEC_TEST_URL`) — définies **avant** toute fonction qui les utilise.
- `models.sh` : `DEFAULT_DEVICE` et la **déclaration des modèles**, un bloc
  par modèle **avec ses commentaires métier** (sampling officiels, contraintes
  cache/MTP/SWA, historique des choix, repo/quant). Quatre helpers déclaratifs :
  `download_hf`/`download_hf_shards` (définissent les chemins `*_PATH`,
  alimentent `KNOWN_FILES` — inventaire, source unique de `--cleanup` et des
  mkdir — et `DL_SPECS`, consommé en boucle par `cmd_setup`), `groupe`
  (en-têtes de groupe du ini, `GROUPE_AVANT`), `llama_model` (corps `MODEL_INI[...]`
  et `PRESET_ORDER` = ordre de déclaration = ordre d'émission — `declare -A`
  ne préserve pas l'ordre d'insertion). Un `download_hf` peut servir
  plusieurs sections (même GGUF) et porter plusieurs fichiers (drafter externe).
- `ini.sh` : loaders des trois confs (`load_bench_conf`, `load_preload_conf`,
  `load_spec_conf`), `_preset_model_key`, `_preset_nmax` (surcharge
  conf > défaut script, `SPEC_NMAX_FORCE` prime — utilisé par `--spec-tune`),
  `generate_models_ini`.
- `preload.sh` : sélection interactive (`select_preload_models`, gum ou
  fallback numéroté), `_save_preload_conf`, `_preload_sanity` (garde-fous
  doublons de poids, dérivés des déclarations : même GGUF partagé ou paire de
  dossiers `<clé>`/`<clé>-mtp`), `cmd_preload`.
- `setup.sh` : `cmd_setup` (dépendances, ROCm best-effort, téléchargements),
  `cmd_update` (= setup avec `REFRESH=1`, `hf` compare les etags),
  `cmd_cleanup` (piloté par `KNOWN_FILES`, dry-run par défaut).
- `bench.sh` : `cmd_bench` (mesure API du serveur en l'état), `_bench_one`,
  sélections, `cmd_bench_devices` (comparaison automatique des devices d'un
  modèle : device forcé via `BENCH_DEVICE_FORCE`, ini régénéré + restart par
  device, verdict = temps d'un tour d'usage simulé `PP/prefill + GEN/décode`
  (profil `BENCH_PROFILE_PP`/`BENCH_PROFILE_GEN`, défaut 2000/3000 ; à <2 %
  d'écart le device par défaut est préféré), vainqueur écrit dans
  `bench-devices.conf` via `_bench_save_device`), `cmd_list_devices`.
- `spec.sh` : `cmd_spec_test`, `cmd_spec_tune`, `_spec_save_conf`, sélection
  des modèles MTP ; l'analyse est déléguée à `py/spec_analyze.py`.
- `service.sh` : `cmd_start` (`--models-max` = préchargés + 1, min 2),
  `cmd_install_service` (service **user** piloté par `systemctl --user`, linger
  activé pour le démarrage au boot, `ExecStart` via `realpath` du
  script, `GGML_CUDA_ENABLE_UNIFIED_MEMORY=1` posé d'office pour ROCm/iGPU),
  `cmd_uninstall_service`.
- `help.sh` : `cmd_help`.

Les fichiers de conf restent à côté du **point d'entrée** (`SCRIPT_DIR`),
jamais dans les sous-dossiers.

## Scripts Python (`py/`)

Appelés par chemin absolu `python3 "$SCRIPT_DIR/py/x.py"` (jamais relatif
au cwd : le service systemd démarre ailleurs). Python 3 stdlib uniquement.
Leurs sorties sont contractuelles : le bash les consomme au `sed -n`/`grep`
près — voir `tests/py-golden.sh`.

| Script | Entrées | Sorties | Appelé par |
|---|---|---|---|
| `timings.py --bench <json> <passe>` | réponse `/v1/chat/completions` en argv | ligne d'affichage + `PP=`/`G=`/`A=` (+ `PPCACHED=1` si `cache_n` > 0 en passe 1 → prefill marqué `*` au récap) | `_bench_one` (bench.sh) |
| `timings.py --spec <json> <passe> <flag>` | idem + `spec` si modèle spéculatif | ligne + `GEN=`/`ACC=`/`DN= DA= PN=` | `cmd_spec_test` (spec.sh) |
| `build_body.py <modèle> <max_tokens> <seed> <fichier prompt> [fichier...]` (contenus joints par une ligne vide) | fichiers de `prompts/` | body JSON (`json.dumps`) sur stdout | `_bench_one`, `cmd_spec_test` |
| `spec_server_nmax.py <modèle>` | JSON de `/v1/models` sur stdin | n-max réel du serveur (vide si absent) | `cmd_spec_test` |
| `spec_analyze.py <log> <modèle> <gguf> <device> <k> [rec]` | `spec-tests.log` (TSV) | rapport texte + `REC=k` si demandé ; **réécrit le log** (quarantaine) | `_spec_analyze` (spec.sh) |

## Prompts de mesure (`prompts/`)

Texte brut (français, multiligne autorisé), chargé par `build_body.py` qui
fait l'échappement JSON — plus aucun texte pré-échappé dans le bash.

| Fichier | Consommé par | Contenu |
|---|---|---|
| `spec-test.txt` | `cmd_spec_test` | prompt de référence (module `inventory.py` + tests pytest — code structuré = meilleur cas MTP) |
| `bench-context.txt` | `_bench_one` | contexte réaliste du bench : cahier des charges du système que la tâche demande d'implémenter (long prefill varié ; taille réelle = `n=` de la passe 1) |
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

1. Défaut : corps `MODEL_INI[modèle]` (models.sh), device hérité du `[*]`
   (Vulkan0).
2. Surcharges appliquées par `generate_models_ini` :
   `bench-devices.conf` (ligne `device =` si le vainqueur du GGUF ≠ défaut ;
   clé = **dossier du GGUF**, donc partagée entre modèles d'un même fichier),
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

## Verdict de --bench-devices (temps de tour simulé)

Comparer deux devices sur deux métriques (prefill t/s, décode t/s) ne
tranche pas quand chacun gagne la sienne : ROCm est souvent devant en
prefill, Vulkan en décode. Le verdict ramène donc la comparaison à un seul
scalaire : le temps d'un tour d'usage type,

```
t(device) = PP_froid / prefill_t/s  +  GEN / décode_t/s
```

avec par défaut `PP_froid = 2000` tokens de prefill froid et `GEN = 3000`
tokens générés (variables d'environnement `BENCH_PROFILE_PP` /
`BENCH_PROFILE_GEN`, surchargables à l'appel sans toucher au script). Le
profil représente un tour agentic : un morceau de contexte nouveau à
calculer réellement, puis une réponse longue. Les tokens resservis par le
prompt cache sont volontairement hors profil : leur coût réel est quasi
nul (cf. les passes 2+ du bench, n=4 calculés sur ~1400), les compter
n'ajouterait que du bruit sans changer l'ordre.

Le vainqueur est le temps minimal, affiché en colonne « tour simulé (s) »
du tableau. Deux garde-fous :

- à moins de 2 % d'écart, le device par défaut (`DEFAULT_DEVICE`) est
  préféré : on ne change pas de backend sur du bruit de mesure ;
- un prefill marqué `*` (passe 1 partiellement servie par le cache) entre
  dans le calcul sans l'astérisque mais reste signalé au tableau. Le cas
  est théorique ici : le restart entre devices garantit un cache froid.

Les entrées du calcul sont les médianes de `_bench_one` (prefill de la
passe 1, décode hors passe 1), donc les mêmes chiffres et les mêmes
prompts que `--bench` : un tableau `--bench-devices` se compare à un
tableau `--bench` de la même époque de prompts. Limites assumées : le
modèle est linéaire (pas de dépendance du prefill à la taille du contexte
ni du décode à la profondeur), et l'acceptance MTP n'entre pas dans la
formule, elle est déjà incluse dans le décode mesuré.

Exemple (qwen3.8-27b-mtp-nothink, 2026-08-16) : Vulkan0 307 pp / 29,9 tg
donne 106,7 s ; ROCm0 356 pp / 21,8 tg donne 143,3 s. Le gain de prefill
de ROCm (+16 %) ne compense pas son décode plus lent (-27 %) : sur ce
profil, le décode domine dès que GEN/décode dépasse largement
PP/prefill, ce qui est le cas de tous les modèles denses de ce parc.

## Invariants (à ne pas casser)

- `models.ini` **byte-identique** à confs égales : `generate_models_ini` est
  déterministe, toute variation vient d'un choix explicite (modèle ou conf).
- Sorties des `py/*.py` au caractère près — `tests/py-golden.sh`
  (fixtures capturées sur le code inline d'origine).
- `parallel = 1` sur tous les modèles MTP (contrainte llama.cpp np/mmproj).
- `--cleanup` piloté uniquement par `KNOWN_FILES`.
- Restart requis après toute régénération du ini (routeur = lecture au boot).
- Mesures spec : l'état réel vient de `/v1/models`, jamais du script/ini.
- Entrée non interactive (`! -t 0`) gérée partout : jamais de question, jamais
  de restart automatique.
