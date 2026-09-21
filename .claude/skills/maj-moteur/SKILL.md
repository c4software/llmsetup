---
name: maj-moteur
description: Vérifier si l'image ROCm du service est en retard sur ses amonts (fork halo-box/strix-llama.cpp, runtime ROCr pwilkin/rocm-systems, Dockerfile kyuz0 et ses patchs), afficher les évolutions par partie, puis, sur accord, faire bouger les révisions épinglées, reconstruire et redémarrer. À charger dès qu'on demande si le moteur ou l'image est à jour, ou qu'on veut la mettre à jour.
---

# Mettre à jour le moteur : vérifier, montrer, puis seulement agir

L'image `llm-rocm-strix:latest` (voir `runtime/AMONT.md`) épingle quatre choses,
chacune avec son amont. Rien ne se met à jour tout seul, c'est voulu : une
image est une série de mesures. Cette skill fait le tour des quatre en lecture
seule, montre ce qui a changé, et n'enclenche l'update que sur un « oui »
explicite de l'utilisateur, partie par partie.

| Partie | Épinglé où | Amont |
|---|---|---|
| Moteur llama.cpp | `ARG ENGINE_REV`, `runtime/Dockerfile.rocm-strix` | `halo-box/strix-llama.cpp`, branche `master` |
| Runtime ROCr/HIP retained-PM4 | `ARG ROCM_SYSTEMS_REV`, même fichier | `pwilkin/rocm-systems`, branche `ilintar-experiments` |
| Dockerfile lui-même | ligne « Commit du fichier en amont » de `runtime/AMONT.md` | `kyuz0/amd-strix-halo-toolboxes`, `toolboxes/Dockerfile.rocm-10.0-strix-llama` sur `main` |
| Les deux patchs | `runtime/patches/*.patch` | `toolboxes/*.patch` du même dépôt (partagés entre Dockerfiles, bougent seuls) |

Une cinquième ligne, pour information : le tag d'image publié en amont
(absent au 18/09/2026, « Manual build only »). Même s'il apparaît, le build
local reste le choix du dépôt (écart 1 d'`AMONT.md`).

## Étape 1 : le check (lecture seule, depuis n'importe quelle machine)

```bash
.claude/skills/maj-moteur/check.sh
```

Sortie : un bloc par partie (épinglé, amont, état, et si en retard la liste des
commits et des fichiers touchés), les PR ouvertes du fork pour information,
l'image locale si elle existe (`/opt/strix/versions.txt`, ce qui a réellement
été compilé), puis deux lignes contractuelles :

```
A_JOUR=Moteur,Runtime ROCr/HIP,Dockerfile amont,Patchs
EN_RETARD=
```

Code de retour 0 si tout est à jour, 1 sinon. « injoignable » partout = quota
de l'API GitHub anonyme épuisé, pas un amont disparu : le script prend
`GH_TOKEN`, sinon `gh auth token`. Rien n'est écrit, rien n'est construit.

## Étape 2 : présenter les évolutions, partie par partie

Pour chaque partie EN RETARD, résumer à l'utilisateur, en français et sans
jargon inutile :

- **ce que ça change pour ce parc** : lire les titres de commits et les fichiers
  touchés sous l'angle des modèles servis (`lib/models.sh`) et des chemins
  chauds du dépôt. Repères : `ggml-cuda/` = kernels HIP (décode, prefill, MMQ,
  flash attention) ; `common/speculative.cpp`, `spec`, `mtp`, `draft` = la
  spéculation (n-max, acceptance, `spec-nmax.conf` à re-tuner) ; `server` =
  cache de prompt et tool calls ; `qwen4exp` = Flash-Next ; `gdn` = les GDN
  (Ornith, Qwen3.5/3.8) ; `deepseek` = DeepSeek V4 ; `convert_hf_to_gguf.py` et
  `conversion/` = sans effet sur un GGUF déjà servi.
- **le risque** : un changement de kernel HIP peut modifier la justesse, pas
  seulement la vitesse (DeepSeek V4 à 550 t/s de charabia, AGENTS.md).
- **ce qu'il faudra remesurer** (étape 4).

Pour le Dockerfile amont et les patchs : lire le diff amont (commande donnée
par le script), ne retenir que ce qui n'est pas un des cinq écarts assumés
d'`AMONT.md`, et refuser tout nouveau `COPY` de modèle, d'outil ou de
configuration (l'image ne contient que le moteur). `gguf-vram-estimator.py`
est le précédent.

Puis **demander** quelles parties mettre à jour. Sans réponse (entrée non
interactive, utilisateur absent), s'arrêter là : le rapport est le livrable.
Ne jamais enchaîner l'étape 3 de sa propre initiative.

## Étape 3 : l'update (sur accord seulement)

Une révision qui bouge = un NOUVEAU MOTEUR : les chiffres pris avant ne se
comparent plus à ceux pris après (`_llama_build` étiquette les journaux
`strix-<engine7>+r<rocm7>`, lus sur les deux `ARG`).

1. **Moteur ou runtime** : remplacer la valeur de l'`ARG` concerné dans
   `runtime/Dockerfile.rocm-strix` par le sommet donné par le check, ET la
   copie de cette valeur dans le bloc de commentaires « Révisions épinglées »
   en tête du fichier (date d'épinglage comprise). Deux lignes par révision,
   rien d'autre.
2. **Dockerfile amont** : suivre « Resynchroniser » d'`AMONT.md` (diff à la
   main, cinq écarts réappliqués), mettre à jour les lignes « Commit du fichier
   en amont » et « Resynchronisé ». **Patchs** : recopier byte pour byte dans
   `runtime/patches/`.
3. Vérifier que rien d'autre n'a bougé : `git diff --stat` ne doit lister que
   `runtime/`. Puis `./tests/sh-unit.sh` (forme de l'étiquette de moteur,
   `--image-build` par `docker compose build`).
4. **Commiter en disant POURQUOI** : le correctif attendu ou la mesure visée,
   les PR ou commits amont repris, et la phrase « nouveau moteur : les mesures
   antérieures ne se comparent plus ». Ne rien commiter sur la machine du
   service.
5. **Construire et redémarrer, sur la machine du service** (bigchuck, dépôt
   `~/llm/llmsetup`, shell zsh : passer par `bash -c` ou un script) :

   ```bash
   git push
   ssh bigchuck 'cd ~/llm/llmsetup && git pull --ff-only && ./setup-llm.sh --image-build'
   ssh bigchuck 'cd ~/llm/llmsetup && ./setup-llm.sh --restart'
   ```

   Compter 40 à 60 minutes à froid (ROCr, HIP et le moteur sont compilés).
   `--image-build` ne redémarre rien : l'image neuve n'est servie qu'au
   `--restart`. Jamais `docker compose restart` (AGENTS.md). Prévenir avant :
   le redémarrage coupe le service.
6. Relire `docker run --rm --entrypoint cat llm-rocm-strix:latest /opt/strix/versions.txt`
   sur la machine du service : ce sont les révisions réellement compilées, à
   comparer aux `ARG`.

## Étape 4 : remesurer avant de faire confiance

Justesse d'abord, comme pour un modèle ajouté (skill `ajout-modele`, étape 3) :

1. `./setup-llm.sh --bench-sanity` sur le modèle le plus servi : regarder le
   texte GÉNÉRÉ. Un kernel cassé produit des t/s superbes.
2. `./setup-llm.sh --bench` sur les modèles de `preload.conf`, et
   `--bench-agentic <modèle> 3` sur ceux qui servent en agentic.
3. Si un commit repris touche la spéculation ou les kernels de décode :
   `--spec-test` pour vérifier l'acceptance, et re-`--spec-tune` seulement si
   elle a bougé (les `.conf` sont des choix utilisateur, ne pas les régénérer
   sans demande).
4. Tableau de synthèse « X contre Y, soit +N % » par modèle, ligne dans
   `docs/HISTORIQUE.md`, et les chiffres résumés dans le commentaire du bloc
   `lib/models.sh` concerné, seul endroit versionné.

Retour arrière : remettre les anciennes valeurs des `ARG` (l'historique git du
Dockerfile est le journal), commiter, `--image-build`, `--restart`.
