# AGENTS.md — instructions pour les agents (et les humains pressés)

Le dépôt est découpé en **runtimes** (un dossier `runtime/<nom>/` par moteur,
autonome) au-dessus d'un socle générique (`lib/`). Avant d'éditer quoi que ce
soit, lire le module concerné **et** : `ARCHITECTURE.md` (socle) et
`runtime/CONTRAT.md` pour tout ce qui touche à `lib/`, à `setup-llm.sh` ou à
la forme d'un runtime ; l'`ARCHITECTURE.md` ou le `README.md` du runtime pour
ce qui lui est propre (`runtime/llama-cpp-rocm-strix/ARCHITECTURE.md`,
`runtime/gufo/README.md` et `docs/GUFO.md`). Les commentaires du code contiennent la connaissance métier (contraintes
llama.cpp, raisons de chaque flag, historique) : la déplacer est permis, la
résumer ou la supprimer, non.

## Contraintes non négociables

1. **Comportement identique** à confs égales : `models.ini` byte-identique,
   mêmes CLI, mêmes sorties, mêmes fichiers. Le point d'entrée reste
   `./setup-llm.sh <commande>`. Tout service est un **conteneur** lancé par
   `docker compose`, décrit par le `docker-compose.yml` versionné de son
   runtime et un `.env` généré hors du dépôt (`~/models/.env` pour
   `llama-cpp-rocm-strix`, `~/llm/gufo-test/.env` pour `gufo`), piloté par les
   `_svc_*` de `lib/svc.sh` : aucun `docker compose` d'un service ailleurs dans
   le dépôt, et **jamais** `docker compose restart`.
   Corollaire du découpage : **rien dans `lib/` ne nomme un runtime** (hormis
   `RUNTIME_DEFAUT`), et **un runtime ne nomme pas les autres**. Un
   comportement propre à un moteur passe par une fonction ou une déclaration
   de `runtime/CONTRAT.md`, jamais par un `if` sur son nom ; si le contrat ne
   suffit pas, c'est le contrat qu'on étend, avec son test.
2. **Bash pur, `set -euo pipefail`**, pas de dépendance nouvelle
   (bash ≥ 4.3, python3 stdlib, curl, sed/awk, paru, hf, gum optionnel).
   Pas de framework, pas de bats.
3. **KISS, édits chirurgicaux** : pas de réécriture « pour faire propre »,
   pas de renommage sans collision réelle, pas d'abstraction spéculative.
   (Le découpage en runtimes du 09/10/2026, demandé par l'utilisateur, a
   déplacé presque tous les fichiers ; ce n'est pas un précédent. Le contrat
   s'arrête au cycle de vie : ne pas y faire entrer les mesures.)
4. **Français** dans le code, les commentaires, les messages et la doc.
5. (runtime `llama-cpp-rocm-strix`) Le routeur lit `models.ini` **au démarrage seulement** : toute mesure
   dépendant d'un paramètre de modèle lit `/v1/models` → `status.args`
   (état réel), jamais le script ni le ini. Déjà fait dans `cmd_spec_test` —
   ne pas le régresser. Même règle pour `gufo` : `gufo-llama-swap.yaml` (seule
   description de ses lignes de commande) et `IMAGE` (seul endroit où sa
   version est écrite) ne valent qu'après un `--restart`.
6. Les sous-commandes d'un runtime ne s'exécutent que sous lui. Pour en lancer
   une quand un autre est l'actif de la machine :
   `LLM_RUNTIME=<nom> ./setup-llm.sh <commande>`. Ne jamais écrire
   `runtime.conf` à la main ni basculer (`--runtime <nom>`) sans demande :
   c'est un choix utilisateur, et une bascule coupe le service.

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

`./tests/sh-unit.sh` lance tout : le contrat sur chaque runtime, le pilotage
générique sur deux runtimes factices, puis les `tests/sh-unit.sh` de chaque
runtime (lançables seuls). Un contrôle ne vit qu'à UN endroit : ce qui vaut
pour tout runtime (ordre du démarrage, jamais `compose restart`, `.env` non
réécrit à contenu identique, échec rapide sur un conteneur sorti, règles
communes du compose, forme de l'étiquette) est dans le test de la racine et
n'est pas répété dans ceux des runtimes.

- Toute modif de `lib/`, de `setup-llm.sh`, de `runtime/CONTRAT.md`, ou d'un
  `runtime.sh` / `docker-compose.yml` de runtime ⇒ `./tests/sh-unit.sh`
  (`--contrat` pour la seule partie générique pendant l'écriture d'un
  runtime). Le rendu par le vrai `docker compose config` est sauté sans
  docker : le dire.
- Toute modif de `runtime/gufo/` (runtime.sh, compose, `gufo-llama-swap.yaml`,
  `Dockerfile.routeur`, `IMAGE`, `download.sh`) ⇒
  `runtime/gufo/tests/sh-unit.sh` : contenu du `.env`, image = la ligne de
  `IMAGE` et aucune version en dur ailleurs, cohérence de la configuration
  llama-swap (noms, `stop` transmis, contexte annoncé, groupes, binaire
  épinglé par SHA-256), modèle préchargé gardé par `--restart`, valeurs du
  banc à part, poids partagés tous téléchargeables (`du_parc`).
- Toute modif de `generate_models_ini`, d'un modèle (`runtime/llama-cpp-rocm-strix/lib/models.sh`) ou du
  découpage ⇒ comparer le ini généré avant/après (`generate_models_ini` se
  source sans réseau ni service) et signaler tout écart involontaire dans le
  commit. (Le test golden du refactor a été retiré une fois la migration
  validée — commit du 15/08/2026.)
- Toute modif d'un `runtime/llama-cpp-rocm-strix/py/*.py` ⇒ `runtime/llama-cpp-rocm-strix/tests/py-golden.sh`. Si la sortie
  change : mettre à jour la fixture attendue **et** vérifier les `sed`/`grep`
  bash qui la consomment (`PP=`/`G=`/`A=`, `GEN=`/`ACC=`/`DN=`, `REC=`).
- Toute modif de `spec_analyze.py` ⇒ aussi `python3 runtime/llama-cpp-rocm-strix/tests/py-unit.py`
  (tests unitaires de `fit_alpha`/`fit_timing`/`predict`/`recommend` sur
  données synthétiques exactes).
- Toute modif de `_llama_build` (`lib/common.sh` du runtime), de `runtime/llama-cpp-rocm-strix/lib/image.sh` (image),
  de `runtime/llama-cpp-rocm-strix/lib/compose.sh` (`.env` généré), de `runtime/llama-cpp-rocm-strix/docker-compose.yml`,
  de `runtime/llama-cpp-rocm-strix/lib/setup.sh` (`--cleanup`) ou de `runtime/llama-cpp-rocm-strix/lib/ini.sh` / `runtime/llama-cpp-rocm-strix/lib/models.sh`
  (ini généré) ⇒ `runtime/llama-cpp-rocm-strix/tests/sh-unit.sh` : forme de l'étiquette de moteur
  (`strix-<engine7>+r<rocm7>`, lue par un `grep` sur les deux `ARG` `*_REV` de
  `runtime/llama-cpp-rocm-strix/Dockerfile.rocm-strix`, sans lancer de conteneur), `--image-build`
  qui passe bien par `docker compose build` sans se bloquer sur l'absence
  d'image, et pour le service : forme du compose versionné (bloc `build`,
  `cap_drop ALL`, `seccomp`, ligne de commande du routeur), contenu du `.env`
  (gid numériques, `--models-max` suivant `preload.conf`, `COMPOSE_FILE`),
  rendu par le vrai `docker compose config`, `--cleanup` qui épargne les deux
  artefacts générés et les dossiers du parc réservés par un autre runtime
  (`RT_PARC_RESERVE`), et `--migrate-off-systemd` idempotente ; et pour le ini :
  device `ROCm0` partout et aucun `Vulkan0`, `fit = off` / `load-mode = none` /
  cache K et V `f16` dans l'en-tête, `spec-draft-ngl = all` injecté sur chaque
  drafter séparé, `batch-size` 16384 sur la seule section autorisée, et le
  garde-fou qui refuse les autres, surcharges `--spec-ab` comprises.
- `bash -n` sur chaque fichier touché ; `shellcheck` si dispo (signaler
  plutôt que refactorer ; le style SC2155-like existant est assumé).

## Règles de terrain

- Les scripts sont appelés **par chemin absolu**, depuis `SCRIPT_DIR` (racine
  du dépôt) ou le dossier du runtime (`python3 "$LLAMA_DIR/py/x.py"`,
  `"$GUFO_DIR/download.sh"`) - les commandes du dépôt sont lancées
  depuis n'importe où.
- Les prompts de mesure vivent dans `prompts/`. **Toute modification d'un
  prompt invalide les comparaisons avec les runs antérieurs de
  `spec-tests.log`** : le signaler dans le message de commit et le récap ;
  ne jamais modifier un prompt au détour d'un autre changement. `prompts/` et
  `bench-agentic/` sont PARTAGÉS par tous les runtimes : y toucher invalide
  les comparaisons de chacun.
- Ne pas éditer `~/models/models.ini`, `~/models/.env` ni
  `~/llm/gufo-test/.env` : ils sont
  **générés**, non versionnés, et réécrits (`regen_models_ini`, `regen_env`).
  Le `.env` est régénéré à chaque `--start` ; les tuners qui
  surchargent le ini le temps d'une mesure n'y touchent pas.
- Les fichiers `.conf` (`runtime.conf`, `preload.conf`, `spec-nmax.conf`, `spec-ngram.conf`),
  à la racine du dépôt,
  sont des **choix utilisateur** : ne pas les régénérer ni
  les « corriger » sans demande. Les .conf et les journaux de `logs/` sont
  locaux, non versionnés (.gitignore) ; tout nouveau journal va dans `logs/`
  avec la version de llama.cpp en colonne.

## Procédure d'ajout d'un modèle (runtime llama-cpp-rocm-strix)

Détail, commandes et critères de passage dans la skill locale
`.claude/skills/ajout-modele/SKILL.md` (à charger dès qu'on ajoute, remplace
ou re-qualifie un modèle). Les sept étapes, dans l'ordre, une seule à la fois
(un seul GPU). Machine de mesure distante : pousser, `git pull --ff-only`
là-bas, lancer, ne rien commiter sur place.

1. **Fiche du modèle** : valider les informations de base à partir du
   guide unsloth (`https://unsloth.ai/docs/models/<modèle>` : sampling
   officiel, quant conseillée, contexte, commande llama.cpp, note MTP) croisé
   avec la model card HF (repo et fichier GGUF, architecture et support
   llama.cpp, thinking, état récurrent ou SWA, vision, date d'upload). Livrable : le bloc `runtime/llama-cpp-rocm-strix/lib/models.sh` avec son commentaire métier,
   ini généré inchangé ailleurs.
2. **MTP ou pas MTP** : tête MTP présente dans le GGUF ? spéculation voulue
   sur ce modèle (parallel 1, cache-reuse 0, pas de mmproj, réserve sur le
   rollback GDN en agentic) ? Livrable : `spec-type` choisi, acceptance
   visible dans un premier `--spec-test`.
3. **Justesse d'abord** (`--bench-sanity`, BLOQUANTE) : le moteur du service
   n'a plus qu'un device (`ROCm0`, image HIP seule), il n'y a plus de
   `--bench-devices`. Ce qui reste de cette étape est ce qui la justifiait :
   regarder le texte GÉNÉRÉ, pas seulement les t/s. DeepSeek V4 sur le ROCm
   système répondait un charabia à 550 t/s et a été couronné deux fois avant
   qu'un garde-fou existe. `runtime/llama-cpp-rocm-strix/tools/qualif-modele.sh` s'arrête si elle échoue.
4. **`--spec-tune`** : longueur de draft MTP mesurée (en `draft-mtp` seul
   si le `spec-type` est une liste), écrite dans `spec-nmax.conf`.
5. **`--spec-ngram-tune`** (si `ngram-map-k` dans le `spec-type`) : courbe
   `t_forward(batch)` puis arbitrage réel, écrit dans `spec-ngram.conf`.
   Modèle sans MTP : la courbe seule d'abord, service arrêté,
   `REPS=5 runtime/llama-cpp-rocm-strix/tools/bench-spec-batch.sh <gguf>` (llama-bench de l'IMAGE depuis le
   18/09/2026, donc le moteur qui sert), pour
   connaître les deux tailles à mesurer ; puis `ngram-map-k` dans le
   `spec-type` et le tune, qui mesure une référence sans spéculation et
   n'écrit rien si aucun `size_m` ne la bat. La courbe ne décide jamais
   seule (DeepSeek V4 : +9 % réels malgré une courbe « défavorable »).
   Toute autre comparaison (min-hits, size-n, k4v, taille hors tune) :
   `--spec-ab <modèle> <n> - <variante>...`, rien d'écrit, bilan comparé.
6. **`--bench` final et récap de performance** (plus, selon le rôle :
   `--bench-parallel` si `parallel > 1`, `--bench-cache` si agentic,
   `--bench-load` si chargé à la demande) : un tableau partageable (configuration,
   prompt t/s, gen t/s, acceptance, source et prompt de mesure),
   avec machine, build llama.cpp, quant et date ; les chiffres résumés vont
   aussi dans le commentaire du bloc, seul endroit versionné.
7. **`--bench-agentic <modèle> 3`** : le modèle en vraie boucle de tool
   calls (pi en conteneur jetable, `bench-agentic/`, en direct sur `:8009`) :
   appel froid à part, puis médianes par scénario (PASS, temps mur, part du
   cache, prefill et décode réels). Ligne dans `docs/HISTORIQUE.md`
   (« Boucle agentic réelle ») et dans le commentaire du bloc.

## Procédure de mise à jour du moteur (runtime llama-cpp-rocm-strix)

Détail dans la skill locale `.claude/skills/maj-moteur/SKILL.md` (à charger
dès qu'on demande si le moteur ou l'image est à jour, ou qu'on veut la mettre à
jour). Les révisions de l'image (`ARG ENGINE_REV` et `ARG ROCM_SYSTEMS_REV` de
`runtime/llama-cpp-rocm-strix/Dockerfile.rocm-strix`, Dockerfile amont et patchs suivis dans
`runtime/llama-cpp-rocm-strix/AMONT.md`) ne bougent **jamais toutes seules** : une image est une
série de mesures. `.claude/skills/maj-moteur/check.sh` compare les quatre
pièces à leur amont en lecture seule et affiche les évolutions par partie ;
l'update (édition des `ARG`, commit qui dit pourquoi, `--image-build` puis
`--restart` sur la machine du service) ne se fait que sur accord explicite,
et impose une remesure, justesse d'abord (`--bench-sanity` avant tout
chiffre).

## Montée de version de gufo (runtime gufo)

Détail dans `docs/GUFO.md`, « Checklist de montée de version ». Les étapes de
lecture passent par `runtime/gufo/tools/gufo-amont.sh` (lecture seule) ;
**rien n'est appliqué sans question posée à l'utilisateur et réponse reçue**.
L'update : la ligne de `runtime/gufo/IMAGE`, un commit qui dit pourquoi,
`LLM_RUNTIME=gufo ./setup-llm.sh --setup image` sur la machine, puis
`runtime/gufo/bench/remesure.sh`, justesse d'abord. Toute réponse à un ticket
amont est rédigée puis montrée à l'utilisateur avant publication.

## Où ajouter…

- **Un runtime** : un dossier `runtime/<nom>/`, en suivant `runtime/CONTRAT.md`
  (« Ajouter un runtime : la marche ») jusqu'à ce que
  `./tests/sh-unit.sh --contrat` passe. Rien à modifier dans `lib/` ni dans
  `setup-llm.sh` : s'il le faut, c'est que le contrat est incomplet, à dire
  avant de coder. Puis la table des runtimes du README et d'ARCHITECTURE.md.

- **Un modèle** (llama-cpp-rocm-strix) : un bloc dans `runtime/llama-cpp-rocm-strix/lib/models.sh` (`download_hf` + `llama_model`,
  `groupe` si nouvelle famille), voir le README du runtime (« Ajouter un modèle ») et la
  procédure ci-dessus. L'ordre de déclaration est l'ordre d'émission du ini.
  Les garde-fous de `_preload_sanity` sont dérivés (même GGUF, suffixe
  `-mtp`) : nommer la variante MTP `<clé>-mtp`, rien à coder.
- **Un modèle** (gufo, seulement s'il le sert : GGUF imposés) : un bloc dans
  `runtime/gufo/gufo-llama-swap.yaml` avec son commentaire métier, son groupe
  et son `capabilities.context` ; sa cible dans `runtime/gufo/download.sh` ;
  son nom court dans `GUFO_MODELES` et dans les `modele_gufo` des bancs s'il
  est préchargeable.
- **Une mesure** (jamais dans `lib/` : les mesures sont propres à chaque
  runtime ; gufo : un script de `runtime/gufo/bench/`, résultats dans
  `GUFO_DATA/resultats/`). llama-cpp-rocm-strix : `cmd_bench_*` dans son propre `runtime/llama-cpp-rocm-strix/lib/bench/bench-<mesure>.sh`
  (noyau `_bench_one` et sélections dans `runtime/llama-cpp-rocm-strix/lib/bench/bench.sh`) ou `cmd_spec_*` dans
  `runtime/llama-cpp-rocm-strix/lib/spec.sh`, l'analyse dans un `runtime/llama-cpp-rocm-strix/py/*.py` à sorties contractuelles
  (lignes `CLÉ=` consommées par le bash, fixture + référence dans
  `runtime/llama-cpp-rocm-strix/tests/py-golden.sh`), un journal TSV dans `logs/` avec le build
  (`_llama_build`) et son device réel, puis la doc : table des commandes du
  README du runtime, son aide (`lib/aide.sh`), tableau des scripts et des journaux de son ARCHITECTURE.md.
  Tout verdict automatique a son garde-fou contre les mesures fausses
  (sortie dégénérée, réponse fausse) : un backend cassé produit des t/s
  superbes.
- **Une sous-commande d'un runtime** : la fonction `cmd_*` dans le module
  adapté du runtime (ou un nouveau module sourcé depuis son `runtime.sh`), son
  nom dans `RT_COMMANDES[<nom>]`, une entrée dans `rt_<id>_commande`, une ligne
  dans `rt_<id>_aide` (le test du contrat refuse une sous-commande absente de
  l'aide, ou déjà prise par un autre runtime).
- **Une commande commune** (rare : elle doit valoir pour tout runtime) : dans
  `lib/svc.sh`, le `case` de `setup-llm.sh`, `lib/help.sh`, `runtime/CONTRAT.md`
  et le test de la racine.
