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

1. **Épinglage des révisions.** Deux `ARG` ajoutés : `ENGINE_REV` (à côté de
   `REPO`/`BRANCH`) et `ROCM_SYSTEMS_REV` (à côté de `ROCM_SYSTEMS_REPO`/
   `ROCM_SYSTEMS_BRANCH`). Vides, le comportement est celui de l'amont (HEAD de
   la branche). Renseignés, le build fait `git fetch origin <rev>` puis
   `git checkout --detach <rev>` après le clone. Le clone de `rocm-systems`
   reste blobless et n'a jamais été superficiel ; celui du moteur non plus. Rien
   d'autre n'a bougé dans les deux clones.
   Motif : l'amont assume explicitement de ne rien épingler (« never commit
   pins », `--no-cache` comme seul mécanisme de rafraîchissement). Ici une image
   est le moteur d'un service dont on compare les mesures d'une semaine à
   l'autre : un moteur qui change tout seul rend la série incomparable.
2. **Étiquettes.** Trois `LABEL` sur l'étage final : `llm-setup.engine_rev`,
   `llm-setup.rocm_rev`, `llm-setup.build_date`, alimentées par les `ARG` du
   même nom (plus `BUILD_DATE`) redéclarés dans cet étage. Un `LABEL` ne sait
   pas lire `/opt/strix/versions.txt`, qui n'existe qu'une fois le build fait :
   les valeurs sont donc résolues AVANT le build par `--image-build`
   (`git ls-remote` quand la révision n'est pas épinglée), et `--image-build`
   revérifie après coup qu'elles correspondent à `versions.txt`. `versions.txt`
   reste inchangé et reste la source de vérité ; les étiquettes évitent d'avoir
   à démarrer l'image pour savoir ce qu'elle contient.
3. **Chemin des patchs.** `COPY llama-grammar.patch` →
   `COPY patches/llama-grammar.patch`, idem pour celui de #25992. Le contexte de
   build amont est `toolboxes/` (à plat, partagé par une douzaine de
   Dockerfiles) ; ici c'est `runtime/`, et les deux patchs tiennent dans
   `runtime/patches/`.
4. **`gguf-vram-estimator.py` retiré.** L'amont le copie deux fois
   (`/usr/local/bin`, étages builder et final). C'est une aide interactive du
   toolbox : rien dans le build ni dans le dépôt ne l'appelle. Retiré plutôt que
   vendorisé, donc **deux `COPY` et deux `chmod` en moins**. C'est le seul
   fichier annexe de l'amont qui ne soit pas repris.
5. **Garde sur les quatre binaires.** Un `RUN` ajouté dans l'étage builder,
   après `cmake --install build` : il vérifie que `llama-server`, `llama-bench`,
   `llama-cli` et `llama-quantize` sont exécutables dans `/usr/local/bin` (seul
   chemin que l'étage final recopie) et les copie depuis `build/bin` si une
   cible cessait d'être installée en amont. Aujourd'hui `cmake --install` les y
   met tous les quatre : la garde ne change rien, elle empêche de livrer une
   image amputée que seul l'usage révélerait.
6. **En-tête de commentaire** ajouté en tête de fichier (provenance, renvoi ici,
   rappel que le build passe par `--image-build`).

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
2. Diffusion à la main contre ce fichier, en ne réappliquant que les six écarts
   ci-dessus. `diff` direct inutile : les `ARG`, les `LABEL` et le chemin des
   patchs le brouillent.
3. Récupérer aussi les patchs amont s'ils ont bougé (`toolboxes/*.patch` : ils
   sont partagés entre Dockerfiles et changent sans que celui-ci change).
4. Mettre à jour les lignes « Commit du fichier en amont » et
   « Resynchronisé » ci-dessus, puis
   `./setup-llm.sh --image-build` et une campagne de mesures : un changement de
   Dockerfile vaut un changement de moteur.


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
`gguf-vram-estimator.py`, écart 4).

## Gestion des images (décision du 17/09/2026)

- **Un seul tag : `llm-rocm-strix:latest`.** Pas de tag daté, pas de collection
  d'anciennes images gardées en filet. Une image se reconstruit en quelques
  minutes depuis `runtime/image.conf`, et **l'historique git de ce fichier EST
  le journal des révisions**. La traçabilité repose sur les trois `LABEL`, sur
  `/opt/strix/versions.txt` et sur `logs/images.tsv`.
- **Build sous tag temporaire.** `--image-build` construit
  `llm-rocm-strix:build`, vérifie `versions.txt` et les quatre binaires, et ne
  promeut en `:latest` qu'ensuite. Un build raté ou une vérification en échec
  laissent `:latest` **intacte** : c'est le seul filet qui reste.
- **Ménage ciblé.** Après une promotion, les images **sans tag qui portent
  `llm-setup.engine_rev`** sont supprimées (l'ancienne `:latest` et les restes
  de builds précédents). Jamais de `docker system prune`, jamais de
  `docker image prune -a`, et rien qui ne porte pas notre étiquette : la machine
  héberge d'autres images (`bench-agentic-pi`,
  `ghcr.io/peonist-ai/halogen-flash-server`, `llama-rocm-10.0-strix-llama:pr133`).
- **Cache de build non purgé.** `docker builder prune` ne sait pas filtrer sur
  l'origine d'un cache et la machine construit aussi d'autres images :
  `--image-status` affiche la place qu'il prend et la commande à lancer à la
  main, rien de plus. Pas d'export `docker save` non plus.
- **Pas de `--image-rollback`.** Revenir en arrière, c'est remettre les
  anciennes révisions dans `image.conf` (`git revert`, ou
  `--image-update <engine-rev> <rocm-rev>`) puis `--image-build`.

## Ce qui n'est pas ici

- **Pas de `docker-compose.yml` ici.** Le compose du service est GÉNÉRÉ par le
  dépôt (`lib/compose.sh`) et déposé dans `~/models`, à côté de `models.ini`.
- `--image-build`, `--image-update` et `--image-status` ne redémarrent aucun
  service : une image neuve n'est servie qu'au prochain `--restart`.
