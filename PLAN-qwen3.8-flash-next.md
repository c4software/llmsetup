# Plan de reprise : Qwen3.8-Flash-Next (branche qwen3.8-flash-next)

Fichier temporaire, à supprimer au merge de la branche. Rédigé le 27/08/2026,
révisé le 04/09/2026.

## État au 04/09/2026 (révisé, cf. « Ce qui a changé » plus bas)

- Bloc `qwen3.8-flash-next-nothink` dans `lib/models.sh` : shards UD-IQ4_XS
  (93,7 Go), nothink + sampling instruct (temp 0.7, top-p 0.80, top-k 20,
  presence 1.5), `spec-type = ngram-map-k` (size-m 7, min-hits 2),
  cache-type-v q8_0, cache-reuse 0, jinja, parallel 1.
  Plus de `draft-mtp` ni de `spec-draft-n-max`, section renommée (voir plus bas).
- GGUF téléchargé sur bigchuck : `~/models/qwen3.8-flash-next/UD-IQ4_XS/`
  (3 shards : 10,9 Mo + 49,8 Go + 43,8 Go). Shards inchangés sur HF au 04/09,
  le ré-upload redouté n'a pas eu lieu : pas de `--update` à prévoir.
  ATTENTION : `models.ini` de bigchuck contient encore la section sous son
  ANCIEN nom `qwen3.8-flash-next-mtp-nothink` ; il sera régénéré au prochain
  `--preload`. `bench-devices.conf` n'est pas concerné (clé = dossier GGUF,
  pas le nom de section). `preload.conf` : si l'ancien nom y figure, la ligne
  est ignorée en silence puis supprimée au `--preload` ; re-cocher la section
  `-nothink` à ce moment-là si on veut le modèle préchargé.
- bigchuck est sur la branche `qwen3.8-flash-next`. La branche a été mise à
  jour depuis master par un MERGE (pas un rebase) le 04/09, précisément pour
  que le `git pull --ff-only` de bigchuck continue de fonctionner.
- Upstream : PR ggml-org/llama.cpp #27742 (arch `qwen4exp`) mergée le 27/08 à
  19:32 UTC, dans b10661. DFlash2 (#27342) mergée le même jour.
- Bloquant : paquet Arch `llama-cpp` en 0.3.0-1 (b10621 sur bigchuck), sans
  `qwen4exp`. Tout le reste attend.
- Décisions prises : quant IQ4_XS (validée, pas le Q4_K_XL à 111 Go) ; pas de
  test DFlash2 ni DFlash v1 pour l'instant.
- Surveillance du paquet : bot Hermes, source
  https://archlinux.org/packages/extra/x86_64/llama-cpp/json/, réglé le 27/08
  sur « pkgver != 0.2.0 ». À RECONFIGURER : ce test a déclenché à tort le 30/08
  sur 0.3.0, qui ne contient pas `qwen4exp`. Une alerte reste utile comme
  déclencheur, mais elle ne vaut que comme invitation à lancer le `strings` de
  l'étape 1, jamais comme feu vert.

## Jalon 1 : FAIT le 05/09/2026 (étapes 1 à 8), reste 9 et 10

- Paquet `extra/llama-cpp 0.4.0-1.1` (build 10809, ggml 0.23.0) installé sur
  bigchuck le 05/09 à 11:36, `strings` confirme `qwen4exp`.
- bigchuck était sur `master`, remis sur la branche. Le dépôt y est dans
  `~/llm/llmsetup` (les `.conf` sont dans le dépôt, pas dans `~/models`).
- `--update` : shards inchangés (etags identiques). `--preload` : seule la
  section `-nothink` a été ajoutée au ini, l'ancienne n'y était plus.
- Mesures reportées dans le commentaire du bloc et le README : Vulkan0
  (ROCm0 exclu, charabia), ngram-map-k 7 = 54,0 t/s contre 25,1 sans
  (spec-refactor), bench 197 / 25,9 t/s, cache 62 %, chargement 14 s à chaud.
- Note d'outillage : `--bench-devices <modèle> Vulkan0 3` refuse un seul
  device (« moins de 2 devices »), et un `--bench` lancé juste après le
  restart final d'un `--spec-ab` échoue (« ne répond pas ») : attendre que
  `/v1/models` réponde avant d'enchaîner.
- Reste : étape 9 (merge dans master, suppression de ce fichier, bigchuck
  sur master) et étape 10 (re-bench du parc après le bump ggml 0.22 → 0.23).

## Ce qui a changé depuis le 27/08

1. **Le paquet a bougé sans débloquer.** 0.2.0 (b10566) puis 0.3.0-1 le 30/08
   (b10621), déjà installé sur bigchuck. Mais v0.3.0 est taguée le 25/08 et le
   commit de merge `6c84c7d5d8` est 39 commits devant elle : pas de `qwen4exp`.
   Le PKGBUILD source `#tag=v${pkgver}`, donc les tags stables semver et non les
   pre-releases `bXXXXX`. L'attente porte sur la prochaine coupe stable (aucune
   après v0.3.0 au 04/09, upstream à b10797), pas sur un rebuild.
   **La surveillance sur changement de pkgver est donc fausse** : elle a déjà
   déclenché à tort sur 0.3.0. Seul contrôle fiable :
   `strings /usr/lib/libllama.so* | grep -x qwen4exp`.
2. **Le MTP a quitté le GGUF principal.** Depuis le 01/09 unsloth publie la
   tête en sidecar dans `MTP/` du repo (recommandé
   `mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf`, 2,60 Go, annoncé 1,3x à 1,7x).
   Leur README : un build ggml-org standard ne peut rien en faire, mainline n'a
   ni graphe MTP pour `qwen4exp`, ni emprunt de tenseurs entre modèles, ni
   `--spec-type draft-mtp` pour cette arch. C'est la PR #28243, encore en
   **draft** au 04/09.
   D'où le repli déjà prévu, appliqué : `draft-mtp` retiré, section renommée
   `qwen3.8-flash-next-nothink`.

Le travail se scinde donc en deux jalons indépendants.

## Jalon 1 : un tag stable contenant `qwen4exp` (sans MTP)

Sur bigchuck, dans `~/llm/llmsetup` (branche `qwen3.8-flash-next`,
`git pull --ff-only` d'abord si la branche a bougé) :

1. Mise à jour et contrôle du support :
   `paru -Syu llama-cpp ggml-vulkan ggml-hip ggml-cpu`
   `strings /usr/lib/libllama.so* | grep -x qwen4exp` (doit sortir une ligne)
   `llama-server --version` (noter le build : il va dans tous les logs).
2. Régénérer le ini sous le NOUVEAU nom de section :
   `cp ~/models/models.ini /tmp/models.ini.avant`, `./setup-llm.sh --preload`,
   `diff` : la section `-mtp-nothink` doit disparaître au profit de
   `-nothink`. Rien à corriger dans les .conf (voir « État ») : au plus
   re-cocher `-nothink` dans le sélecteur de `--preload`. Pas de `--update` :
   les shards HF sont inchangés.
3. `systemctl --user restart llama-server`, puis une requête
   chat/completions sur `qwen3.8-flash-next-nothink` (le routeur ne charge
   qu'à la première requête, et `status.args` n'existe qu'une fois le modèle
   chargé) : autant en faire le contrôle de justesse (fonction Python qui
   inverse une liste chaînée). Ensuite `curl localhost:8009/v1/models` et
   vérifier `--spec-type ngram-map-k` dans `status.args` (l'étape 2 de la
   skill, volet MTP, est sans objet à ce jalon), et
   `journalctl --user -u llama-server` sans warn/error/CPU fallback.
4. Étape 3 (device) : `./setup-llm.sh --bench-devices qwen3.8-flash-next-nothink`.
   ROCm0 suspect (DeepSeek V4 et Qwen3-Coder-Next y sortent du charabia) :
   lire le texte généré, pas seulement les t/s. Optionnel pour l'agentic long :
   `tools/bench-depth.sh` (service arrêté).
5. Étape 4 (spec-tune MTP) : SAUTÉE à ce jalon, pas de tête chargeable.
6. Étape 5 (n-gram) : `./setup-llm.sh --spec-ngram-tune qwen3.8-flash-next-nothink 4`.
   Sans MTP, `--spec-test` affiche la mesure mais ne l'écrit pas dans
   `logs/spec-tests.log` (pas de n-max) : noter les chiffres à la main.
   Attendre un surcoût fixe par pas spéculatif (GDN + MoE 512 experts, comme
   Qwen3-Coder-Next où size_m 7 a divisé le débit par 2). Le tune ne mesure
   que les deux candidats issus de la courbe (pas des valeurs au choix), donc
   comparer explicitement 7, 47 et l'absence de spéculation :
   `./setup-llm.sh --spec-ab qwen3.8-flash-next-nothink 4 - "spec-type=none" "spec-ngram-map-k-size-m=7" "spec-ngram-map-k-size-m=47"`
   et ne garder `ngram-map-k` dans le bloc que s'il bat `none`.
7. Étape 6 : `./setup-llm.sh --bench qwen3.8-flash-next-nothink 3`,
   `--bench-cache` (part du prompt repayée, état récurrent : attendre 62 à
   66 %), `--bench-load` (bascule LRU de 94 Go : attendre > 90 s).
8. Reporter les chiffres (date, build, quant, device, prompt) dans le
   commentaire du bloc, tableau récap dans le message de commit et le README.
   Commit par étape, rien d'édité sur bigchuck (les .conf s'y écrivent seuls).
9. Merger la branche dans master, supprimer ce fichier, remettre bigchuck sur
   master (`git checkout master && git pull --ff-only`).
10. Bump ggml 0.22 : relancer `--bench` sur les autres modèles du parc, le
    journal signale les écarts > 5 %.

## Jalon 2 : MTP par le fork — DÉBLOQUÉ le 12/09/2026 (renommage du sidecar)

Ce jalon attendait la PR mainline #28243 (graphe MTP `qwen4exp`, emprunt de
tenseurs entre modèles, `--spec-type draft-mtp` pour cette arch). Le passage du
service au fork halo-box/strix-llama.cpp le 12/09/2026 l'a débloqué : le fork a
un graphe MTP `qwen4exp` et un drafter externe (`spec-draft-model`).

Le premier essai du 12/09 avait échoué : le fork refusait les deux sidecars
unsloth (autonome 4,1 Go et « shared- » 2,8 Go) sur
`check_tensor_dims: tensor 'output_hc_norm.weight' not found`, et Flash-Next ne
chargeait plus du tout ; retour au n-gram seul le soir même. Cause trouvée dans
la foulée : simple divergence de NOMS. Le graphe MTP du fork
(`src/models/qwen4exp.cpp`, `graph_mtp`) lit le mixeur final des
hyper-connexions sous `output_hc_{norm,down,up}.weight` (niveau modèle), unsloth
le range sous `blk.48.nextn.hc_head_{norm,down,up}.weight` (convention #28243).
Mêmes formes (10240 ; 10240x320 ; 320x10240), mêmes types (F32, Q8_0, Q8_0) :
renommer les trois tenseurs suffit, aucune conversion.

### FAIT

- `tools/mtp-rename-hc-head.py` (gguf-py du fork via `PYTHONPATH`) : renomme les
  trois tenseurs, recopie les données telles quelles.
- Sortie sur bigchuck : `~/models/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-strix-Q8_0.gguf`
  (4,1 Go), déclarée dans `lib/models.sh` par `derive_gguf` (KNOWN_FILES, et
  `--setup` la reproduit si elle manque ou si la source a bougé). La variante
  « shared- » n'est plus déclarée (le fork ne sait pas emprunter les tenseurs du
  modèle hôte) ; son fichier reste sur disque, `--cleanup` ne le purge pas.
- Chargement validé sur le fork (instance isolée, `draft-mtp` seul, n-max 4,
  ngram-on-disk) : sortie cohérente, `draft acceptance = 0.64 (215/336)`,
  40,3 t/s sur 300 tokens de code. Les `blk.48.indexer.*` du sidecar sont
  ignorés par le fork (« unused tensor », sans effet).
- Bloc remis en `spec-type = ngram-map-k,draft-mtp` (ngram-map-k 7, min-hits 2,
  `spec-draft-n-max` 4, `ngram-on-disk`), sans `spec-draft-adaptive`.

### À FAIRE (sur bigchuck, dans l'ordre)

1. `git pull --ff-only`, `./setup-llm.sh --preload` (régénère le ini), restart,
   puis une requête sur le modèle et `curl localhost:8009/v1/models` :
   `status.args` doit porter `--spec-type ngram-map-k,draft-mtp` et le GGUF
   `-strix-`.
2. `./setup-llm.sh --spec-test qwen3.8-flash-next-nothink` : l'acceptance doit
   être un nombre, pas « n/a » (c'est le contrôle que le MTP tourne vraiment).
3. `./setup-llm.sh --bench qwen3.8-flash-next-nothink 3`, à comparer à la
   référence n-gram seul sur le fork : 414 t/s prefill, 30,9 t/s décode
   (strix-0007bc6, Vulkan0, ngram-on-disk). Garder le mode mixte seulement s'il
   la bat.
4. Si gardé : `./setup-llm.sh --spec-tune qwen3.8-flash-next-nothink` (mesure en
   `draft-mtp` seul, écrit `spec-nmax.conf`), puis renommer la section en
   `qwen3.8-flash-next-mtp-nothink` (le garde-fou de préchargement en dérive) et
   reporter les chiffres dans le commentaire du bloc et le README.

Note : l'alternative « binaires prébuilts unsloth » (tag `b10715-mix-86bd2d3`
ou plus récent) ou un build de la PR sortirait du paquet Arch, donc du mode de
fonctionnement du dépôt, et rendrait les mesures incomparables aux tableaux
existants. Non retenu sauf décision explicite. Le jour où #28243 est mergée et
portée par le moteur, le sidecar unsloth se lira tel quel et le renommage (donc
`derive_gguf` et le script) deviendra inutile.

## Pistes gardées pour plus tard (non engagées)

- DFlash2 sur Qwen3.8-27B : drafter `z-lab/Qwen3.8-27B-DFlash2-GGUF` (Q8_0
  2,1 Go), même paquet requis. Mesure : `--spec-ab qwen3.8-27b 4 - base
  "spec-type=draft-dflash;spec-draft-model=<gguf>;spec-draft-n-max=7;cache-reuse=0"`.
- DFlash v1 sur qwen3.6-35b-a3b-nothink : drafter
  `Anbeeld/Qwen3.6-35B-A3B-DFlash-GGUF` (Q8_0 0,42 Go), supporté dès b10566.
- Vision Flash-Next : `mmproj-F16.gguf` publié, incompatible MTP, non prévu.
- GLM-5.3-Flash : même famille de blocage (aucune PR mergée, et UD-IQ3_XXS à
  120 Go ne rentre pas sur 124 Go), vérifié le 04/09. Rien d'engagé.
