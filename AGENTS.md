# AGENTS.md — instructions pour les agents (et les humains pressés)

Lire le module concerné **et** `ARCHITECTURE.md` avant d'éditer quoi que ce
soit. Les commentaires du code contiennent la connaissance métier (contraintes
llama.cpp, raisons de chaque flag, historique) : la déplacer est permis, la
résumer ou la supprimer, non.

## Contraintes non négociables

1. **Comportement identique** à confs égales : `models.ini` byte-identique,
   mêmes CLI, mêmes sorties, mêmes fichiers. Le point d'entrée reste
   `./setup-llm.sh <commande>` (le service systemd l'appelle via `realpath`).
2. **Bash pur, `set -euo pipefail`**, pas de dépendance nouvelle
   (bash ≥ 4.3, python3 stdlib, curl, sed/awk, paru, hf, gum optionnel).
   Pas de framework, pas de bats.
3. **KISS, édits chirurgicaux** : pas de réécriture « pour faire propre »,
   pas de renommage sans collision réelle, pas d'abstraction spéculative.
4. **Français** dans le code, les commentaires, les messages et la doc.
5. Le routeur lit `models.ini` **au démarrage seulement** : toute mesure
   dépendant d'un paramètre de modèle lit `/v1/models` → `status.args`
   (état réel), jamais le script ni le ini. Déjà fait dans `cmd_spec_test` —
   ne pas le régresser.

## Pièges bash déjà rencontrés (ne pas réintroduire)

- Sous `set -e`, une fonction qui **se termine** par `[[ … ]] && …` faux
  retourne 1 et tue le script → `if` ou `return 0` explicite
  (cf. `_preload_sanity`).
- `((n++))` sur 0 retourne 1.
- `declare -A` ne préserve pas l'ordre → `PRESET_ORDER`.
- `mapfile`/`gum` avec fallback numéroté si gum absent ; entrée non
  interactive (`! -t 0`) gérée partout (pas de question, pas de restart auto).
- Micro-comparaisons numériques : convention **awk**
  (`awk 'BEGIN{exit !(a>b)}'`-like, cf. les médianes) — pas de `python3 -c`
  pour ça.

## Tests — quand relancer quoi

- Toute modif de `generate_models_ini`, d'un modèle (`lib/models.sh`) ou du
  découpage ⇒ comparer le ini généré avant/après (`generate_models_ini` se
  source sans réseau ni service) et signaler tout écart involontaire dans le
  commit. (Le test golden du refactor a été retiré une fois la migration
  validée — commit du 15/08/2026.)
- Toute modif d'un `py/*.py` ⇒ `./tests/py-golden.sh`. Si la sortie
  change : mettre à jour la fixture attendue **et** vérifier les `sed`/`grep`
  bash qui la consomment (`PP=`/`G=`/`A=`, `GEN=`/`ACC=`/`DN=`, `REC=`).
- Toute modif de `spec_analyze.py` ⇒ aussi `python3 tests/py-unit.py`
  (tests unitaires de `fit_alpha`/`fit_timing`/`predict`/`recommend` sur
  données synthétiques exactes).
- `bash -n` sur chaque fichier touché ; `shellcheck` si dispo (signaler
  plutôt que refactorer ; le style SC2155-like existant est assumé).

## Règles de terrain

- Les scripts Python sont appelés **par chemin absolu depuis `SCRIPT_DIR`**
  (`python3 "$SCRIPT_DIR/py/x.py"`) — le service systemd démarre ailleurs.
- Les prompts de mesure vivent dans `prompts/`. **Toute modification d'un
  prompt invalide les comparaisons avec les runs antérieurs de
  `spec-tests.log`** : le signaler dans le message de commit et le récap ;
  ne jamais modifier un prompt au détour d'un autre changement.
  
- Ne pas éditer `~/models/models.ini` (généré).
- Les fichiers `.conf` (`bench-devices.conf`, `preload.conf`,
  `spec-nmax.conf`, `spec-ngram.conf`) sont des **choix utilisateur** : ne pas les régénérer ni
  les « corriger » sans demande. Les .conf et spec-tests.log sont locaux,
  non versionnés (.gitignore).

## Procédure d'ajout d'un modèle

Détail, commandes et critères de passage dans la skill locale
`.claude/skills/ajout-modele/SKILL.md` (à charger dès qu'on ajoute, remplace
ou re-qualifie un modèle). Les six étapes, dans l'ordre, une seule à la fois
(un seul GPU) :

1. **Fiche du modèle** : valider les informations de base à partir du
   guide unsloth (`https://unsloth.ai/docs/models/<modèle>` : sampling
   officiel, quant conseillée, contexte, commande llama.cpp, note MTP) croisé
   avec la model card HF (repo et fichier GGUF, architecture et support
   llama.cpp, thinking, état récurrent ou SWA, vision, date d'upload). Livrable : le bloc `lib/models.sh` avec son commentaire métier,
   ini généré inchangé ailleurs.
2. **MTP ou pas MTP** : tête MTP présente dans le GGUF ? spéculation voulue
   sur ce modèle (parallel 1, cache-reuse 0, pas de mmproj, réserve sur le
   rollback GDN en agentic) ? Livrable : `spec-type` choisi, acceptance
   visible dans un premier `--spec-test`.
3. **`--spec-tune`** : longueur de draft MTP mesurée, écrite dans
   `spec-nmax.conf`.
4. **`--spec-ngram-tune`** (si `ngram-map-k` dans le `spec-type`) : courbe
   `t_forward(batch)` puis arbitrage réel, écrit dans `spec-ngram.conf`.
5. **`--bench-devices`** puis **`--bench`** : ROCm0 ou Vulkan0, écrit dans
   `bench-devices.conf`. Si le device change, refaire 3 et 4 (les seuils
   dépendent du backend).
6. **Récap de performance** : un tableau partageable (configuration,
   device, prompt t/s, gen t/s, acceptance, source et prompt de mesure),
   avec machine, build llama.cpp, quant et date ; les chiffres résumés vont
   aussi dans le commentaire du bloc, seul endroit versionné.

## Où ajouter…

- **Un modèle** : un bloc dans `lib/models.sh` (`download_hf` + `llama_model`,
  `groupe` si nouvelle famille), voir README.md (« Ajouter un modèle ») et la
  procédure ci-dessus. L'ordre de déclaration est l'ordre d'émission du ini.
  Les garde-fous de `_preload_sanity` sont dérivés (même GGUF, suffixe
  `-mtp`) : nommer la variante MTP `<clé>-mtp`, rien à coder.
- **Une sous-commande** : la fonction `cmd_*` dans le module `lib/` adapté
  (ou un nouveau module sourcé depuis le point d'entrée), une entrée dans le
  `case` de `setup-llm.sh`, une ligne dans `cmd_help` (`lib/help.sh`).
