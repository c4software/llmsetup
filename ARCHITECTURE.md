# ARCHITECTURE

## Flux de données

```
lib/models.sh (déclarations : download_hf/llama_model/groupe → MODEL_INI, défauts)
        │
        ▼                    surcharges
generate_models_ini  ◄──  bench-devices.conf   (device par GGUF)
   (lib/ini.sh)      ◄──  spec-nmax.conf       (spec-draft-n-max par modèle)
        │            ◄──  spec-ngram.conf      (spec-ngram-map-k-size-m par modèle)
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
  `_dl`, `_dl_shard`, `_maybe_restart_service`, `_llama_build` : version
  courte de llama.cpp, journalisée partout) et **toutes les variables
  globales de config** : `MODELS_BASE`, `CONFIG_DIR`, `BENCH_CONF`,
  `PRELOAD_CONF`, `SPEC_TEST_URL`, `LOG_DIR` (+ migration des journaux de la
  racine), `SPEC_LOG`, `BENCH_LOG`, `SPEC_CONF`, `SPEC_NGRAM_CONF`, `SERVICE_NAME`,
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
- `ini.sh` : loaders des quatre confs (`load_bench_conf`, `load_preload_conf`,
  `load_spec_conf`, `load_spec_ngram_conf`), `_preset_model_key`,
  `_preset_nmax` et `_preset_ngram_m` (surcharge conf > défaut script ;
  `SPEC_NMAX_FORCE` / `SPEC_NGRAM_FORCE` + `*_PRESET` priment, posés par les
  tuners pour tester une valeur sans l'écrire), `generate_models_ini`
  (applique aussi `SPEC_TYPE_FORCE` + `SPEC_TYPE_FORCE_PRESET` : spec-type
  remplacé le temps d'une mesure, `draft-mtp` pour `--spec-tune` sur une
  liste, `none` pour la référence de `--spec-ngram-tune` sans MTP ; et
  `SPEC_AB_OVERRIDES` + `SPEC_AB_PRESET` : surcharges libres de `--spec-ab`,
  via `_apply_overrides`).
- `preload.sh` : sélection interactive (`select_preload_models`, gum ou
  fallback numéroté), `_save_preload_conf`, `_preload_sanity` (garde-fous
  doublons de poids, dérivés des déclarations : même GGUF partagé ou paire de
  dossiers `<clé>`/`<clé>-mtp`), `cmd_preload`.
- `setup.sh` : `cmd_setup` (dépendances, ROCm best-effort, téléchargements),
  `cmd_update` (= setup avec `REFRESH=1`, `hf` compare les etags),
  `cmd_cleanup` (piloté par `KNOWN_FILES`, dry-run par défaut).
- `bench.sh` : `cmd_bench` (mesure API du serveur en l'état, journal
  `logs/bench.log` + comparaison au run précédent), `cmd_bench_parallel`
  (salves de 1 puis n requêtes simultanées, `parallel` réel lu sur
  `/v1/models`, agrégat par `py/parallel_agg.py`), `cmd_bench_cache` (quatre
  requêtes froid / suite / édition au milieu / identique, part servie du cache
  par `py/cache_stats.py`), `cmd_bench_sanity` / `_bench_sanity_one`
  (justesse, `py/check_answer.py`, appliquée par `cmd_bench_devices` avant
  chaque device), `cmd_bench_load` (restart + première requête chronométrée,
  TTFT à chaud), `_bench_one`,
  sélections, `cmd_bench_devices` (comparaison automatique des devices d'un
  modèle : device forcé via `BENCH_DEVICE_FORCE`, ini régénéré + restart par
  device, verdict = temps d'un tour d'usage simulé `PP/prefill + GEN/décode`
  (profil `BENCH_PROFILE_PP`/`BENCH_PROFILE_GEN`, défaut 2000/3000 ; à <2 %
  d'écart le device par défaut est préféré), vainqueur écrit dans
  `bench-devices.conf` via `_bench_save_device`), `cmd_list_devices`.
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
| `timings.py --spec <json> <passe> <flag>` | idem + `spec` si modèle spéculatif, `specmix` si spec-type en liste (acceptance agrégée sur les implémentations, stats au niveau slot côté serveur) | ligne + `GEN=`/`ACC=`/`DN= DA= PN=` | `cmd_spec_test` (spec.sh) |
| `build_body.py <modèle> <max_tokens> <seed> <fichier prompt> [fichier...]` (contenus joints par une ligne vide) | fichiers de `prompts/` | body JSON (`json.dumps`) sur stdout | `_bench_one`, `cmd_spec_test` |
| `spec_server_nmax.py <modèle> [flag]` | JSON de `/v1/models` sur stdin | valeur réelle du flag (défaut `--spec-draft-n-max` ; aussi `--spec-type`, `--spec-ngram-map-k-size-m`), vide si absent | `cmd_spec_test` |
| `batch_curve.py <modèle> <device> <depth> [tsv] [rec]` | jsonl de `llama-bench -o jsonl` sur stdin (plusieurs balayages concaténés, le plus récent fait foi) | tableau batch/size_m/coût/seuil/gain, marches, baisses au-delà du bruit, tailles dominées, verdict ; `SIZEM_SAFE=`/`SIZEM_LARGE=`/`STEP_LO=`/`STEP_HI=` si `rec` ; append TSV si fichier donné | `cmd_spec_ngram_tune`, `tools/bench-spec-batch.sh` |
| `depth_curve.py <modèle> <device> <pp> <gen> [tsv] [rec]` | jsonl de `llama-bench -d` sur stdin | tableau prefill/décode/tour simulé par profondeur, dégradation de 0 à la profondeur max, `TOUR_<depth>=` si `rec` ; append TSV | `tools/bench-depth.sh` |
| `check_answer.py <json> <attendu>` | réponse `/v1/chat/completions` | ligne lisible ; code 0 si la valeur attendue est dans la réponse (ou le raisonnement), 1 sinon | `_bench_sanity_one` (bench.sh, aussi appelé par `cmd_bench_devices`) |
| `cache_stats.py <json> <étiquette>` | réponse `/v1/chat/completions` | ligne lisible + `PN=` (tokens du prompt) `CN=` (servis du cache) `PMS=` (prefill ms) | `cmd_bench_cache` |
| `parallel_agg.py <temps_mur_s> <réponse.json>...` | réponses d'une salve de requêtes simultanées | ligne lisible + `AGG=` (tokens / temps mur) `MED=` (décode médian par requête) `TOK=` `ERR=` | `_bench_parallel_salve` (bench.sh) |
| `bench_compare.py <bench.log> <modèle>...` | `logs/bench.log` (TSV) | pour chaque modèle, écart prefill/décode au run précédent du même GGUF/device, build rappelé s'il a changé, drapeau à ±5 % | `cmd_bench` |
| `spec_analyze.py <log> <modèle> <gguf> <device> <k> [rec]` | `logs/spec-tests.log` (TSV) | rapport texte + `REC=k` si demandé ; **réécrit le log** (quarantaine) | `_spec_analyze` (spec.sh) |

## Prompts de mesure (`prompts/`)

Texte brut (français, multiligne autorisé), chargé par `build_body.py` qui
fait l'échappement JSON — plus aucun texte pré-échappé dans le bash.

| Fichier | Consommé par | Contenu |
|---|---|---|
| `spec-test.txt` | `cmd_spec_test` | prompt de référence (module `inventory.py` + tests pytest — code structuré = meilleur cas MTP) ; seul prompt qui alimente la calibration α |
| `spec-refactor.txt` | `cmd_spec_ngram_tune` (via `cmd_spec_test`) | le même module fourni dans le contexte, avec des blocs à recopier exactement puis à remplacer (forme oldString/newString d'opencode) : le seul cas où un n-gram a des hits, donc le seul qui départage deux `size_m` |
| `bench-context.txt` | `_bench_one` | contexte réaliste du bench : cahier des charges du système que la tâche demande d'implémenter (long prefill varié ; taille réelle = `n=` de la passe 1) |
| `bench-sanity.txt` | `_bench_sanity_one` | recopie exacte d'un code (`LAMPADAIRE-2719`) : contrôle de justesse d'un device, volontairement trivial pour ne tester que le backend, pas le modèle |
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

Journal `logs/spec-tests.log` (TSV) : `date modèle gguf device nmax gen acc
drafted accepted predicted spectype prompt build`. Les colonnes 11 et 12
datent du support des listes et du prompt paramétrable, la 13 du passage en
`logs/` ; absentes = `draft-mtp` seul sur `spec-test.txt`, build inconnu. `spec_analyze.py` écarte (sans quarantaine : ils sont
valides, juste hors modèle) les runs en spec-type mixte, dont le k varie
par forward, et ceux d'un autre prompt ; sans ce filtre le garde-fou
tokens/forward > k+1 les commenterait tous. C'est pourquoi `--spec-tune`
mesure en `draft-mtp` seul (`SPEC_TYPE_FORCE=draft-mtp`).

## Réglage n-gram (`batch_curve.py`, `--spec-ngram-tune`)

Un draft de `size_m` tokens est vérifié dans un forward de batch
`size_m + 1`. Le gain ne dépend que de la forme de `t_forward(batch)`, qui
a des marches : ggml change de noyau selon la taille du batch (Vulkan :
`mul_mat_vec_max_cols = 8`, x2 entre batch 8 et 9, mesuré sur un dense et
un MoE). Deux régimes seulement ont du sens, le script sort les deux :
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

## Journaux de mesure (`logs/`)

Tous locaux (.gitignore), TSV en append, une ligne par mesure, toujours avec
le build de llama.cpp : un chiffre sans son build ne se compare pas. Une
colonne nouvelle s'ajoute à droite avec un défaut pour les lignes courtes.

| Fichier | Écrit par | Colonnes |
|---|---|---|
| `spec-tests.log` | `cmd_spec_test` | `date modèle gguf device nmax gen acc drafted accepted predicted spectype prompt build` |
| `bench.log` | `_bench_one` | `date modèle gguf device build prefill décode acceptance passes prefill_cache` ; lu par `bench_compare.py` |
| `bench-parallel.log` | `cmd_bench_parallel` | `date modèle device build parallel_srv n agrégé décode_par_requête passes` |
| `bench-cache.log` | `cmd_bench_cache` | `date modèle device build part_suite part_edit part_identique ms_froid ms_suite ms_edit ms_identique` |
| `bench-agentic.log` | `cmd_bench_agentic` | `date modèle device build scénario verdict mur_s prompt_tok cache_tok gen_tok prefill_tps decode_tps` (une ligne par scénario) |
| `bench-load.log` | `cmd_bench_load` | `date modèle gguf device build taille chargement_s ttft_chaud_ms` |
| `spec-batch.log` / `.tsv` | `tools/bench-spec-batch.sh` | lisible / `date modele device depth fa_reel batch t_forward_ms sd_ms cout_rel gain_max` |
| `bench-depth.log` / `.tsv` | `tools/bench-depth.sh` | lisible / `date modele device depth pp_ts pp_sd tg_ts tg_sd tour_s` |

`device` est l'état réel du serveur (`/v1/models`, flag `--device`) partout
où le serveur est en cause, le device demandé pour les outils `llama-bench`.

## Outils hors service (`tools/`)

`bench-spec-batch.sh` : balayage `llama-bench` brut d'un ou plusieurs GGUF
sur un ou plusieurs devices, sans passer par le service (à arrêter soi-même
pour une mesure propre, l'état est journalisé). Journal lisible
`logs/spec-batch.log` et TSV `logs/spec-batch.tsv`. Sert à
explorer ; pour régler, `--spec-ngram-tune`. Les autres fichiers de `tools/`
(sync opencode, extension pi) sont décrits dans le README.

`bench-depth.sh` : même principe avec `llama-bench -d` (profondeur de KV
avant la mesure) : prefill et décode à 0 / 16k / 32k (64k sur demande), KV
en q8_0 comme le service, tour simulé par profondeur et par device. Journal
`logs/bench-depth.log` + `.tsv`.

## Invariants (à ne pas casser)

- `models.ini` **byte-identique** à confs égales : `generate_models_ini` est
  déterministe, toute variation vient d'un choix explicite (modèle ou conf).
- Sorties des `py/*.py` au caractère près — `tests/py-golden.sh`
  (fixtures capturées sur le code inline d'origine).
- `parallel = 1` sur tous les modèles MTP (contrainte llama.cpp np/mmproj).
- `--cleanup` piloté uniquement par `KNOWN_FILES`.
- Restart requis après toute régénération du ini (routeur = lecture au boot).
- Mesures spec : l'état réel vient de `/v1/models`, jamais du script/ini.
- `spec-type` peut être une liste : tester l'appartenance
  (`_preset_has_spec_type`), jamais un grep ancré sur `= draft-mtp`.
- Les lignes existantes des journaux (`logs/*.log`) restent lisibles : toute
  colonne nouvelle s'ajoute à droite avec un défaut pour les lignes courtes.
- Tout journal de mesure porte la version de llama.cpp (`_llama_build`) : un
  chiffre sans son build ne se compare pas.
- Entrée non interactive (`! -t 0`) gérée partout : jamais de question, jamais
  de restart automatique.
