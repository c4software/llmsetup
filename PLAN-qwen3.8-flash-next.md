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

## Jalon 2 : merge de la PR MTP #28243

Indépendant du jalon 1 et postérieur : la PR est en draft au 04/09. Elle
apporte le graphe MTP `qwen4exp`, l'emprunt de tenseurs entre modèles et
`--spec-type draft-mtp` pour cette arch. À sa merge, puis à son arrivée dans un
tag stable :

1. Déclarer le sidecar dans le bloc (`download_hf` sur le même repo,
   `QWEN38_FLASH_NEXT_MTP_PATH="MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"`,
   2,60 Go ; `_dl` recrée le sous-dossier `MTP/` sous le dossier modèle depuis
   le 04/09) et le télécharger par `--setup`. La variante `shared-` emprunte
   embeddings et projection de sortie au modèle hôte ; les fichiers autonomes
   ne servent qu'aux builds sans cet emprunt.
2. Remettre `spec-type = ngram-map-k,draft-mtp` et `spec-draft-n-max = 4`,
   ET transmettre le sidecar à llama-server : les blocs MTP existants n'ont
   pas de clé pour ça (tête embarquée dans leur GGUF). Clé attendue
   `spec-draft-model = $QWEN38_FLASH_NEXT_MTP_PATH` (le seul précédent de
   drafter externe, cf. commentaire laguna), À CONFIRMER sur la PR #28243
   avant le restart : sans elle llama-server ne trouve pas de tête MTP et le
   « n/a » de l'étape 3 arrive après un chargement de 94 Go sans en donner la
   cause. Renommer la section en `qwen3.8-flash-next-mtp-nothink`.
3. Vérifier l'acceptance (`--spec-test ... 2`, pas de « n/a »), puis refaire
   l'étape 4 de la skill (`--spec-tune 2,4,6,8 4`) et re-arbitrer l'étape 5,
   la courbe n-gram change quand le MTP occupe le batch.
4. Re-mesurer l'étape 6 et comparer au tableau du jalon 1 : c'est le seul
   chiffre qui dit ce que le MTP rapporte vraiment ici.

Note : l'alternative « binaires prébuilts unsloth » (tag `b10715-mix-86bd2d3`
ou plus récent) ou un build de la PR sortirait du paquet Arch, donc du mode de
fonctionnement du dépôt, et rendrait les mesures incomparables aux tableaux
existants. Non retenu sauf décision explicite.

## Pistes gardées pour plus tard (non engagées)

- DFlash2 sur Qwen3.8-27B : drafter `z-lab/Qwen3.8-27B-DFlash2-GGUF` (Q8_0
  2,1 Go), même paquet requis. Mesure : `--spec-ab qwen3.8-27b 4 - base
  "spec-type=draft-dflash;spec-draft-model=<gguf>;spec-draft-n-max=7;cache-reuse=0"`.
- DFlash v1 sur qwen3.6-35b-a3b-nothink : drafter
  `Anbeeld/Qwen3.6-35B-A3B-DFlash-GGUF` (Q8_0 0,42 Go), supporté dès b10566.
- Vision Flash-Next : `mmproj-F16.gguf` publié, incompatible MTP, non prévu.
- GLM-5.3-Flash : même famille de blocage (aucune PR mergée, et UD-IQ3_XXS à
  120 Go ne rentre pas sur 124 Go), vérifié le 04/09. Rien d'engagé.
