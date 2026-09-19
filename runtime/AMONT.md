# runtime/ — provenance et écarts avec l'amont

`runtime/Dockerfile.rocm-strix` n'est pas un fichier du dépôt : c'est une copie
d'un Dockerfile amont, modifiée. Ce fichier dit d'où elle vient, ce qui a été
changé et comment la resynchroniser. Toute modification locale non listée ici
est un bug de suivi.

## Provenance

| | |
|---|---|
| Dépôt amont | [kyuz0/amd-strix-halo-toolboxes](https://github.com/kyuz0/amd-strix-halo-toolboxes) |
| Source | `toolboxes/Dockerfile.rocm-10.0-strix-llama` sur la branche `main` (PR [#133](https://github.com/kyuz0/amd-strix-halo-toolboxes/pull/133), mergée le 18/09/2026, merge `66da820`) |
| Commit du fichier en amont | `b6a3c5f` |
| Commit repris initialement | `3e78780` (commit de la PR), le 17/09/2026 |
| Resynchronisé | 18/09/2026 : contenu amont identique, aucun changement à reprendre |

La PR est mergée, mais l'amont **ne publie pas d'image** pour ce Dockerfile :
son README dit « Manual build only », et le tag
`docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-10.0-strix-llama` est absent du
registre au 18/09/2026. La vendorisation reste donc nécessaire. Et même si une
image était publiée un jour, le build local resterait le choix du dépôt : c'est
lui qui permet d'épingler les révisions du moteur et du runtime, ce que l'amont
refuse (écart 1). À surveiller : l'apparition de ce tag sur docker.io, et les
commits amont sur le fichier.

Ce que l'image contient, dans l'ordre du Dockerfile : Fedora 44, SDK ROCm 10.0.0
gfx1151 (flux TheRock), un ROCr + HIP **retained-PM4** compilé depuis
`pwilkin/rocm-systems:ilintar-experiments` et installé dans `/opt/strix/lib`
(en tête de `LD_LIBRARY_PATH`, jamais dans `ld.so.conf`), puis le moteur
`halo-box/strix-llama.cpp` construit en **HIP seul** (pas de Vulkan) avec deux
patchs. Étage final `fedora-minimal:44`.

Fichiers vendorisés avec lui, inchangés byte pour byte :

- `patches/llama-grammar.patch` — `MAX_REPETITION_THRESHOLD` 2000 → 100000
  (schémas d'outils complexes, issue amont #70). Le dépôt vit en agentic : sans
  lui, les grammaires de tool calls cassent.
- `patches/llama-cpp-25992-rocm-host-buffer.patch` — contournement de
  llama.cpp #25992 (buffers hôte ROCm sur APU intégré), d'après la PR amont
  #25863. Le Dockerfile échoue si le patch ne s'applique plus **et** n'est pas
  déjà présent : c'est voulu, on ne veut pas d'image silencieusement différente.

## Écarts avec l'amont

1. **Épinglage des révisions, avec valeurs par défaut.** Deux `ARG` ajoutés :
   `ENGINE_REV` (à côté de `REPO`/`BRANCH`) et `ROCM_SYSTEMS_REV` (à côté de
   `ROCM_SYSTEMS_REPO`/`ROCM_SYSTEMS_BRANCH`). Contrairement à l'amont, ils ont
   une **valeur par défaut épinglée**, dans le fichier : ce sont elles qui sont
   servies, et un bloc « Révisions épinglées » en tête du Dockerfile dit d'où
   elles viennent et comment les faire évoluer. Vidées, le comportement redevient
   celui de l'amont (HEAD de la branche). Renseignées, le build fait
   `git fetch origin <rev>` puis `git checkout --detach <rev>` après le clone. Le
   clone de `rocm-systems` reste blobless et n'a jamais été superficiel ; celui
   du moteur non plus. Rien d'autre n'a bougé dans les deux clones.
   Motif : l'amont assume explicitement de ne rien épingler (« never commit
   pins », `--no-cache` comme seul mécanisme de rafraîchissement). Ici une image
   est le moteur d'un service dont on compare les mesures d'une semaine à
   l'autre : un moteur qui change tout seul rend la série incomparable.
   L'historique git de ce fichier est le journal des révisions.
2. **Chemin des patchs.** `COPY llama-grammar.patch` →
   `COPY patches/llama-grammar.patch`, idem pour celui de #25992. Le contexte de
   build amont est `toolboxes/` (à plat, partagé par une douzaine de
   Dockerfiles) ; ici c'est `runtime/`, et les deux patchs tiennent dans
   `runtime/patches/`.
3. **`gguf-vram-estimator.py` retiré.** L'amont le copie deux fois
   (`/usr/local/bin`, étages builder et final). C'est une aide interactive du
   toolbox : rien dans le build ni dans le dépôt ne l'appelle. Retiré plutôt que
   vendorisé, donc **deux `COPY` et deux `chmod` en moins**. C'est le seul
   fichier annexe de l'amont qui ne soit pas repris.
4. **Garde sur les quatre binaires.** Un `RUN` ajouté dans l'étage builder,
   après `cmake --install build` : il vérifie que `llama-server`, `llama-bench`,
   `llama-cli` et `llama-quantize` sont exécutables dans `/usr/local/bin` (seul
   chemin que l'étage final recopie) et les copie depuis `build/bin` si une
   cible cessait d'être installée en amont. Aujourd'hui `cmake --install` les y
   met tous les quatre : la garde ne change rien, elle empêche de livrer une
   image amputée que seul l'usage révélerait.
5. **En-tête de commentaire** ajouté en tête de fichier : provenance, renvoi
   ici, commande de build (`docker compose build`), et le bloc « Révisions
   épinglées » de l'écart 1.

Rien d'autre n'est modifié : ni les dépôts et branches par défaut, ni les
options cmake du moteur (`GGML_HIP_GRAPHS`, `GGML_HIP_NO_VMM`, `gfx1151`…), ni
les portes de correction (`test-backend-sched-ring`, `grep DEBUG_HIP_GRAPH_PM4`,
`ldd` sur `libggml-hip`), ni `versions.txt`, ni les variables d'environnement de
l'étage final (`DEBUG_HIP_GRAPH_PM4=1`, `GPU_MAX_HW_QUEUES=1`,
`HSA_OVERRIDE_GFX_VERSION=11.5.1`, l'ordre de `LD_LIBRARY_PATH`). En
particulier, **ne pas ajouter `GGML_CUDA_ENABLE_UNIFIED_MEMORY`** : l'amont
documente qu'il corrompt le contexte de draft MTP sous graphes HIP.

Ce qui n'est pas repris de la PR : le `README.md` et le `docs/building.md`
amont, et l'entrée de `refresh-toolboxes.sh` (le lanceur de toolbox amont, dont
les protections `--group-add video --group-add render --group-add sudo` sont
remplacées ici par `_dk_run`, qui passe des gid numériques et ne donne pas
`sudo`).

## Resynchroniser

1. Lire le fichier amont sur `main` :
   `gh api repos/kyuz0/amd-strix-halo-toolboxes/contents/toolboxes/Dockerfile.rocm-10.0-strix-llama?ref=main --jq .content | base64 -d`.
2. Diffusion à la main contre ce fichier, en ne réappliquant que les cinq écarts
   ci-dessus. `diff` direct inutile : les `ARG`, l'en-tête et le chemin des
   patchs le brouillent.
3. Récupérer aussi les patchs amont s'ils ont bougé (`toolboxes/*.patch` : ils
   sont partagés entre Dockerfiles et changent sans que celui-ci change).
4. Mettre à jour les lignes « Commit du fichier en amont » et
   « Resynchronisé » ci-dessus, puis `./setup-llm.sh --image-build` (ou
   `cd ~/models && docker compose build`), `--restart` et une campagne de
   mesures : un changement de Dockerfile vaut un changement de moteur.


## L'image ne contient que le moteur

Décision du 17/09/2026, vérifiée sur le Dockerfile vendorisé : **aucun modèle,
aucune configuration, aucun cache, aucun état** ne rentre dans l'image. Les
seuls `COPY` sont :

| Ligne | Ce qui entre | Pourquoi |
|---|---|---|
| `COPY patches/*.patch /tmp/` | les deux patchs | appliqués au moteur pendant le build (étage builder, jamais dans l'étage final) |
| `COPY --from=builder /opt/strix/lib` | ROCr + HIP retained-PM4 | le runtime, exécution |
| `COPY --from=builder /opt/strix/versions.txt` | les révisions compilées | traçabilité |
| `COPY --from=builder /usr/local/` | binaires et bibliothèques du moteur | exécution |
| `COPY --from=builder …/*rpc-server` | `rpc-server` | binaire du moteur (amont) |

Pas de `ADD`, pas de `VOLUME`, pas d'`ENTRYPOINT` figé, `CMD` = un shell. Les
poids arrivent par un montage en lecture seule au **même chemin absolu**
(`_dk_run`, `~/models`), `models.ini` reste dans `~/models` sur l'hôte. Une
image est donc jetable : la reconstruire ne perd rien.

Conséquence à tenir en resynchronisant : si l'amont ajoute un `COPY` d'outil,
de modèle ou de configuration, il ne se reprend pas (c'est ce qui est arrivé à
`gguf-vram-estimator.py`, écart 3).

## Gestion des images (simplifiée le 18/09/2026)

- **Un seul tag : `llm-rocm-strix:latest`.** Pas de tag daté, pas de collection
  d'anciennes images gardées en filet. Ce qu'une image contient se lit dans
  `/opt/strix/versions.txt` ; ce qui a été demandé se lit dans les deux `ARG`
  de ce Dockerfile, dont l'historique git est le journal des révisions.
- **Construire : `cd ~/models && docker compose build`** (`docker-compose.yml`, ici,
  porte ce Dockerfile en bloc `build` ; le `.env` de `~/models`, généré par
  `lib/compose.sh`, lui donne le contexte et le tag).
  `./setup-llm.sh --image-build` n'est qu'un raccourci vers cette commande.
- **Ménage à la main.** Après un build, l'image remplacée devient une image sans
  tag : `docker image prune` la retire, **sans `-a`** et jamais
  `docker system prune` : la machine héberge d'autres images
  (`bench-agentic-pi`, `ghcr.io/peonist-ai/halogen-flash-server`). Le cache de
  build docker n'est pas purgé non plus : `docker builder prune`, à la main, si
  la place manque.

## Ce qui n'est pas ici

- **Pas de valeur machine dans `docker-compose.yml`.** Le compose du service
  est ici, versionné ; ses gid, chemins, `--models-max` et tag d'image sont
  des variables `${VAR:?}`, écrites dans `~/models/.env` par le dépôt
  (`lib/compose.sh`), à côté de `models.ini`.
- **Pas de couche d'abstraction au-dessus.** Il n'y a plus (18/09/2026) de
  `runtime/image.conf`, de `LABEL llm-setup.*`, de promotion sous tag
  temporaire, de purge par label, de `logs/images.tsv`, ni de commandes
  `--image-update` / `--image-status` : un Dockerfile et un compose suffisent.
- `--image-build` ne redémarre aucun service : une image neuve n'est servie
  qu'au prochain `--restart`.
