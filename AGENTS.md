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
  les « corriger » sans demande. Les .conf et les journaux de `logs/` sont
  locaux, non versionnés (.gitignore) ; tout nouveau journal va dans `logs/`
  avec la version de llama.cpp en colonne.

## Procédure d'ajout d'un modèle

Détail, commandes et critères de passage dans la skill locale
`.claude/skills/ajout-modele/SKILL.md` (à charger dès qu'on ajoute, remplace
ou re-qualifie un modèle). Les sept étapes, dans l'ordre, une seule à la fois
(un seul GPU). Machine de mesure distante : pousser, `git pull --ff-only`
là-bas, lancer, ne rien commiter sur place.

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
3. **Device d'abord** (`--bench-devices`) : ROCm0 ou Vulkan0, écrit dans
   `bench-devices.conf` ; les seuils de noyau qui règlent la spéculation
   dépendent du backend, donc avant les étapes 4 et 5. Regarder le texte
   généré, pas seulement les t/s (DeepSeek V4 / ROCm0 : charabia à 550 t/s,
   maintenant détecté par `timings.py`, à vérifier à la main si « trop beau »).
   Un modèle absent de `bench-devices.conf` tourne sur le défaut (Vulkan0)
   sans avoir été mesuré : ce n'est pas un choix.
4. **`--spec-tune`** : longueur de draft MTP mesurée (en `draft-mtp` seul
   si le `spec-type` est une liste), écrite dans `spec-nmax.conf`.
5. **`--spec-ngram-tune`** (si `ngram-map-k` dans le `spec-type`) : courbe
   `t_forward(batch)` puis arbitrage réel, écrit dans `spec-ngram.conf`.
   Modèle sans MTP : la courbe seule d'abord, service arrêté,
   `DEV=Vulkan0,ROCm0 REPS=5 tools/bench-spec-batch.sh <gguf>`, pour
   connaître les deux tailles à mesurer ; puis `ngram-map-k` dans le
   `spec-type` et le tune, qui mesure une référence sans spéculation et
   n'écrit rien si aucun `size_m` ne la bat. La courbe ne décide jamais
   seule (DeepSeek V4 : +9 % réels malgré une courbe « défavorable »).
   Toute autre comparaison (min-hits, size-n, k4v, taille hors tune) :
   `--spec-ab <modèle> <n> - <variante>...`, rien d'écrit, bilan comparé.
6. **`--bench` final et récap de performance** (plus, selon le rôle :
   `--bench-parallel` si `parallel > 1`, `--bench-cache` si agentic,
   `--bench-load` si chargé à la demande) : un tableau partageable (configuration,
   device, prompt t/s, gen t/s, acceptance, source et prompt de mesure),
   avec machine, build llama.cpp, quant et date ; les chiffres résumés vont
   aussi dans le commentaire du bloc, seul endroit versionné.
7. **`--bench-agentic <modèle> 3`** : le modèle en vraie boucle de tool
   calls (pi en conteneur jetable, `bench-agentic/`, en direct sur `:8009`) :
   appel froid à part, puis médianes par scénario (PASS, temps mur, part du
   cache, prefill et décode réels). Ligne dans le README et le bloc.

## Où ajouter…

- **Un modèle** : un bloc dans `lib/models.sh` (`download_hf` + `llama_model`,
  `groupe` si nouvelle famille), voir README.md (« Ajouter un modèle ») et la
  procédure ci-dessus. L'ordre de déclaration est l'ordre d'émission du ini.
  Les garde-fous de `_preload_sanity` sont dérivés (même GGUF, suffixe
  `-mtp`) : nommer la variante MTP `<clé>-mtp`, rien à coder.
- **Une mesure** : `cmd_bench_*` dans son propre `lib/bench/bench-<mesure>.sh`
  (noyau `_bench_one` et sélections dans `lib/bench/bench.sh`) ou `cmd_spec_*` dans
  `lib/spec.sh`, l'analyse dans un `py/*.py` à sorties contractuelles
  (lignes `CLÉ=` consommées par le bash, fixture + référence dans
  `tests/py-golden.sh`), un journal TSV dans `logs/` avec le build
  (`_llama_build`) et son device réel, puis la doc : table des commandes du
  README, `cmd_help`, tableau des scripts et des journaux d'ARCHITECTURE.md.
  Tout verdict automatique a son garde-fou contre les mesures fausses
  (sortie dégénérée, réponse fausse) : un backend cassé produit des t/s
  superbes.
- **Une sous-commande** : la fonction `cmd_*` dans le module `lib/` adapté
  (ou un nouveau module sourcé depuis le point d'entrée), une entrée dans le
  `case` de `setup-llm.sh`, une ligne dans `cmd_help` (`lib/help.sh`).
