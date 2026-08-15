# Refactor de setup-llm.sh : découpage modulaire + documentation

## Contexte

`setup-llm.sh` est un script bash (~2000 lignes) qui pilote un `llama-server` en router mode natif sur une machine Strix Halo (Ryzen AI Max+ 395, 128 Go unifiés, CachyOS/Arch, backends ggml Vulkan + ROCm). Il gère : téléchargement des GGUF (hf), génération de `~/models/models.ini`, préchargement, bench Vulkan0 vs ROCm0, test/tuning de la spéculation MTP, service systemd. Il a grossi de façon organique dans une seule file et je veux le passer en dépôt git modulaire, sans changer son comportement.

Lis d'abord **tout** le script avant de proposer quoi que ce soit : les commentaires contiennent la connaissance métier (contraintes llama.cpp, raisons de chaque flag ini, historique des choix). Elle doit être conservée intégralement — la déplacer, oui ; la résumer ou la supprimer, non.

## Contraintes non négociables

1. **Comportement identique.** Le `models.ini` généré doit être byte-identique avant/après refactor, à `preload.conf`, `bench-devices.conf`, `spec-nmax.conf` égaux. Toutes les sous-commandes (`--setup --update --cleanup --preload --bench --list-devices --spec-test --spec-tune --start --install-service --uninstall-service --help`) gardent la même interface CLI, les mêmes sorties, les mêmes fichiers.
2. **Point d'entrée inchangé.** `./setup-llm.sh <commande>` reste la seule commande ; le service systemd l'appelle avec `--start` via `realpath` du script (voir `cmd_install_service`). Les fichiers de conf restent à côté du point d'entrée (`SCRIPT_DIR`), pas dans les sous-dossiers.
3. **Bash pur, `set -euo pipefail`**, pas de dépendance nouvelle (déjà utilisés : bash ≥ 4.3, python3, curl, sed/awk, paru, hf, gum optionnel). Pas de framework, pas de bats.
4. **KISS et édits chirurgicaux.** Pas de réécriture "pour faire propre" : on déplace, on `source`, on ne réinvente rien. Pas de renommage de fonctions ni de variables sauf collision réelle. Pas d'abstraction spéculative.
5. **Pièges bash déjà rencontrés à ne pas réintroduire** : sous `set -e`, une fonction qui se termine par `[[ … ]] && …` faux retourne 1 et tue le script (préférer `if` ou `return 0` explicite) ; `((n++))` sur 0 retourne 1 ; `declare -A` ne préserve pas l'ordre (d'où `PRESET_ORDER`). `mapfile`/`gum` avec fallback numéroté si gum absent ; entrée non interactive (`! -t 0`) gérée partout.
6. Français dans le code, les commentaires, les messages et la doc (conventions existantes).
7. **Le routeur llama-server lit `models.ini` au démarrage seulement.** Toute mesure qui dépend d'un paramètre de preset (n-max, device…) doit lire l'état réel du serveur (`/v1/models` → `status.args`), pas le script ni le ini — c'est déjà fait dans `cmd_spec_test`, ne le régresse pas.

## Python : sortir les heredocs

Le script embarque aujourd'hui du Python inline (`python3 - … <<'PY'`) à plusieurs endroits : parse JSON de `llama-bench` (`_bench_parse_json`), score geomean (`_bench_score`), tests de comparaison flottante (`python3 -c "…float…"` dans `_bench_one`), parse des `timings` d'une réponse `/v1/chat/completions` et calcul d'acceptance (dans `cmd_spec_test`), lecture du n-max réel sur `/v1/models` (dans `cmd_spec_test`), et surtout l'analyse n-max (`_spec_analyze`, ~80 lignes : ajustement de α, régression `t_base`/`t_draft`, prédiction, recommandation). Tout ça doit devenir des fichiers `.py` externes, versionnés et testables :

```
lib/py/
  bench_parse.py     # stdin/argv : json llama-bench → "pp4096=… pp16384=… tg128=…" ; option --score → geomean
  spec_timings.py    # json réponse chat/completions + n° de passe + flag spec → ligne d'affichage + GEN=/ACC=/DN= (même format qu'aujourd'hui)
  spec_server_nmax.py# json /v1/models + preset → n-max réel (vide si absent)
  spec_analyze.py    # spec-tests.log + preset gguf device k [rec] → rapport texte (+ "REC=k" si demandé)
```

Règles pour ce découpage Python :
- **Interfaces stables** : mêmes entrées (argv/stdin), mêmes sorties texte au caractère près — les fonctions bash qui les appellent font du `sed -n 's/^GEN=//p'` etc. sur cette sortie ; le golden test ne couvre pas ce chemin, donc **capture des sorties de référence** : sauvegarde dans `tests/fixtures/` un JSON de `llama-bench`, une réponse `/v1/chat/completions` avec `timings` (dont `draft_n`/`draft_n_accepted`), un `/v1/models`, et un `spec-tests.log` à 3 lignes (les vraies mesures qui sont dans les commentaires du preset `qwen3.8-27b-mtp-nothink` : k2=22.2, k4=25.5, k6=26.0), et écris `tests/py-golden.sh` qui exécute les 4 scripts sur ces fixtures et `diff` contre des sorties attendues générées **avec le code inline actuel avant extraction**.
- Python 3 stdlib uniquement (déjà le cas), pas de `pip`, un shebang `#!/usr/bin/env python3`, `chmod +x`, mais appelés depuis bash via `python3 "$SCRIPT_DIR/lib/py/x.py"` (chemin absolu dérivé de `SCRIPT_DIR`, jamais relatif au cwd — le service systemd démarre ailleurs).
- Les micro-comparaisons `python3 -c "…sys.exit(0 if float(a) > float(b)…)"` dans `_bench_one` peuvent rester inline **ou** passer par `awk` (`awk -v a= -v b= 'BEGIN{exit !(a>b)}'`) — au choix, mais une seule convention, et dis laquelle. Ne crée pas un `.py` pour ça.
- `spec_analyze.py` : c'est le seul avec de la logique ; garde son texte de sortie identique, mais structure-le en fonctions (`fit_alpha`, `fit_timing`, `predict`, `recommend`) avec un `main()` — c'est ce qui permettra plus tard de le tester ou de changer le modèle sans toucher au bash. Conserve le commentaire de tête qui décrit le modèle (`T(k) = 1 + Σαⁱ`, `t(k) = t_base + k·t_draft`, règle « à <2 %, le plus petit k », garde-fou « tokens/forward > k+1 = run incohérent »).
- Le bash garde uniquement l'orchestration (curl, boucles, restart, écriture des conf/log). Zéro logique métier calculée en bash qui pourrait l'être en Python déjà appelé.

## Découpage attendu

Proposition de départ (à ajuster si tu vois mieux, en le justifiant en une phrase) :

```
setup-llm.sh              # entrée : set -euo pipefail, SCRIPT_DIR, source lib/*, dispatch case
lib/
  models.sh               # variables MODEL_*_REPO/FILE, chemins, KNOWN_FILES
  presets.sh              # MODEL_INI[...] + PRESET_ORDER + commentaires métier des presets
  ini.sh                  # load_*_conf, _preset_nmax, generate_models_ini
  common.sh               # couleurs, info/warn/error, _key, _skip, _path_for_key, _dl, _dl_shard, _maybe_restart_service
  preload.sh              # preload.conf, select_preload_models, _preload_sanity, cmd_preload
  setup.sh                # cmd_setup, cmd_update, cmd_cleanup (+ _in_list)
  bench.sh                # cmd_bench et helpers _bench_*, cmd_list_devices
  spec.sh                 # cmd_spec_test, cmd_spec_tune, _spec_* — orchestration seule, appelle lib/py/spec_*.py
  py/                     # scripts Python externes (voir section dédiée)
  service.sh              # cmd_start, cmd_install_service, cmd_uninstall_service
  help.sh                 # cmd_help
```

Ordre de `source` à respecter : `common` → `models` → `presets` → `ini` → le reste (les presets référencent les chemins, `ini` référence les presets, `spec/bench` référencent `ini`). Toute variable globale de config (`MODELS_BASE`, `CONFIG_DIR`, `SERVICE_NAME`, `SPEC_TEST_URL`, `BENCH_*`, `*_CONF`) définie **avant** les fonctions qui l'utilisent — aujourd'hui `SERVICE_NAME` est défini tard dans le fichier et ça marche parce que bash résout à l'appel ; garde-le fonctionnel mais range-le au bon endroit.

Ajouter un `.gitignore` : `spec-tests.log` (journal local), et laisser versionnés `bench-devices.conf`, `preload.conf`, `spec-nmax.conf` (ce sont des choix, pas des sorties).

## Vérification (à faire, à me montrer)

- `bash -n` sur chaque fichier.
- **Test golden du ini** : avant de toucher quoi que ce soit, génère `models.ini` avec le script actuel dans un `$HOME` factice (les fonctions se sourcent, `generate_models_ini` s'appelle sans réseau ni service) → `golden.ini`. Après refactor, régénère et `diff` — doit être vide. Fais-le aussi avec un `spec-nmax.conf` et un `bench-devices.conf` factices pour couvrir les surcharges. Mets ce test dans `tests/golden-ini.sh` (bash, ~30 lignes) pour qu'il reste rejouable.
- `./setup-llm.sh --help` et `--spec-test nope` (doit sortir "Preset inconnu"), `--bench` non interactif (état des lieux, sans service) — sans réseau, sans sudo.
- `tests/py-golden.sh` : les 4 scripts Python sur les fixtures → diff vide contre les sorties de référence.
- `shellcheck` si dispo : ne corrige que ce qui est réel (SC2155-like à ignorer, on garde le style existant), et signale plutôt que de refactorer.

## Documentation à écrire

- **README.md** : quoi/pourquoi en 10 lignes, prérequis (paquets Arch, split ggml → `ggml-cpu`, `ggml-vulkan`, `ggml-hip` + runtime ROCm), install (`--setup`, `--install-service`), tableau des sous-commandes, workflow typique (`--setup` → `--bench all` → `--spec-tune`), les fichiers de conf et leur rôle, comment ajouter un modèle (variables + `KNOWN_FILES` + `MODEL_INI` + `PRESET_ORDER` + ligne `_dl` — c'est aujourd'hui 5 endroits, documente-les tels quels, ne les fusionne pas dans ce PR), FAQ courte (device ROCm0 disparu → `--list-devices` ; ini regénéré donc jamais éditer à la main ; MTP = `parallel 1`).
- **ARCHITECTURE.md** : flux de données (script → conf files → `models.ini` → llama-server), rôle de chaque module de `lib/` et de chaque script `lib/py/` (entrées/sorties, qui l'appelle), ordre de source et dépendances entre modules, cycle de vie d'un preset (défaut `MODEL_INI` → surcharges `bench-devices.conf`/`spec-nmax.conf`/`preload.conf` → ini), le modèle d'analyse n-max (formule `t/s = (1+Σαⁱ)/(t_base + k·t_draft)`, ce qu'il approxime, ses limites), les invariants (ini byte-identique, `parallel 1` sur MTP, `--cleanup` piloté par `KNOWN_FILES`, restart requis car le routeur lit le ini au démarrage). Reprends les blocs de commentaires métier du script comme source, ne les paraphrase pas de mémoire.
- **AGENTS.md** : instructions pour toi et les futurs agents : les contraintes ci-dessus (comportement identique, KISS, bash pur, français), les pièges bash, "lire le module + `ARCHITECTURE.md` avant d'éditer", "toute modif de `generate_models_ini` ou d'un preset ⇒ relancer `tests/golden-ini.sh` et mettre à jour `golden.ini` volontairement (jamais en silence)", "toute modif d'un `lib/py/*.py` ⇒ `tests/py-golden.sh`, et si la sortie change, mettre à jour la fixture attendue **et** vérifier le `sed`/`grep` bash qui la consomme", "les scripts Python sont appelés par chemin absolu depuis `SCRIPT_DIR`", "ne pas éditer `models.ini`", "les fichiers `.conf` sont des choix utilisateur, ne pas les régénérer sans demande", où ajouter un modèle, où ajouter une sous-commande (fichier + `case` + `cmd_help`).

## Déroulé demandé

1. Lecture complète, puis un plan court (découpage final + ce que tu ferais différemment de la proposition et pourquoi). Attends ma validation.
2. `golden.ini` généré depuis le script actuel + `tests/golden-ini.sh` ; fixtures + sorties de référence des heredocs Python + `tests/py-golden.sh` (générées avec le code inline, avant extraction).
3. Découpage bash, un module à la fois, `bash -n` + golden après chaque étape.
4. Extraction des Python vers `lib/py/`, un script à la fois, `tests/py-golden.sh` après chacun.
5. Docs.
6. Récap final : ce qui a bougé, ce qui n'a pas bougé, ce que tu as vu et volontairement pas touché (dette à traiter dans des PR séparés — ex. les 5 endroits pour ajouter un modèle, `SERVICE_NAME` défini tard, l'absence de tests unitaires sur `spec_analyze.py` maintenant qu'il est isolable).
