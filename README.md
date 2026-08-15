# LLM Setup

LLM Setup pilote un `llama-server` en router mode natif sur une machine Strix Halo
(Ryzen AI Max+ 395, 128 Go unifiés, CachyOS/Arch), avec un seul point d'entrée :
`./setup-llm.sh`.

Ce qu'il gère :

- téléchargement des GGUF depuis Hugging Face (`hf`, mises à jour par etags) ;
- génération de `~/models/models.ini` : les réglages de chaque modèle vivent
  dans `lib/models.sh` avec leurs justifications en commentaire ;
- préchargement always-on ou chargement à la demande (LRU) ;
- mesure des perfs par l'API du serveur (`--bench`, `--spec-test`) ;
- réglage de la spéculation MTP (`spec-draft-n-max`) par mesure et calibration ;
- service systemd.

Les backends ggml (Vulkan par défaut, ROCm/HIP optionnel) sont des paquets
Arch séparés depuis le split de mi-août 2026. Tout est piloté par des fichiers
de conf locaux à côté du script (non versionnés, propres à la machine). Le `models.ini` est généré, jamais édité.

## Prérequis

- Arch/CachyOS, `paru`, bash 4.3 ou plus, python3 (stdlib seule), curl.
- `hf` (python-huggingface-hub, python-hf-xet). `gum` optionnel (menus).
- Paquets llama.cpp : `llama-cpp`, plus les backends ggml splittés :
  `ggml-cpu` et `ggml-vulkan` (obligatoires, installés par `--setup`).
- Pour ROCm0 : `ggml-hip` et le runtime ROCm (`rocm-hip-runtime`, `hipblas`,
  `rocblas`, `hipblaslt`). Le runtime seul ne suffit pas. Contrôle :
  `rocminfo | grep gfx` doit donner `gfx1151`.

## Installation

```bash
./setup-llm.sh --setup            # dépendances, GGUF, préchargement, models.ini
./setup-llm.sh --install-service  # service systemd llama-server (démarrage au boot)
sudo systemctl start llama-server
```

## Sous-commandes

| Commande | Rôle |
|---|---|
| `--setup` | Installe les dépendances, propose ROCm, télécharge les GGUF manquants, sélectionne le préchargement, génère le ini |
| `--update [modèle]` | Comme `--setup`, mais laisse `hf` comparer les etags : seul ce qui a bougé est retéléchargé |
| `--cleanup [--yes]` | Supprime les dossiers et GGUF orphelins (dry-run par défaut) |
| `--preload` | Re-sélectionne les modèles always-on et régénère le ini |
| `--bench [modèle\|all] [n]` | Mesure le serveur tel qu'il tourne : prefill, décode médian, acceptance MTP, tableau récapitulatif. N'écrit rien |
| `--list-devices` | Backends ggml installés et devices exposés, croisés avec `bench-devices.conf` |
| `--spec-test [modèle] [n]` | Décode réel via l'API (spéculation incluse), journalise, calibre et persiste le n-max dès 2 valeurs mesurées |
| `--spec-tune [modèle] [k1,k2,..] [n]` | Boucle automatique sur plusieurs n-max avec restart entre chaque, retient le meilleur mesuré |
| `--start` | Lance llama-server sur le port 8009 (commande du service) |
| `--install-service`, `--uninstall-service` | Service systemd système |
| `--help` | Aide, liste des modèles et des clés de téléchargement |

## Workflow typique

```bash
./setup-llm.sh --setup                # première mise en place
./setup-llm.sh --bench all            # perfs de tous les modèles présents
./setup-llm.sh --spec-tune            # règle spec-draft-n-max d'un modèle MTP
./setup-llm.sh --update qwen3.8-27b   # après un re-upload unsloth
```

## Fichiers de configuration

À côté du script, locaux et non versionnés (propres à la machine) :

| Fichier | Rôle |
|---|---|
| `bench-devices.conf` | clé (dossier GGUF) = device (Vulkan0/ROCm0), édition manuelle |
| `preload.conf` | modèles préchargés, un par ligne |
| `spec-nmax.conf` | modèle = spec-draft-n-max retenu par les mesures |
| `spec-tests.log` | journal TSV des runs `--spec-test` |

Côté `~/models/` : `models.ini`, généré. Ne jamais l'éditer : relancer
`--preload` ou `--setup`. Le routeur ne le lit qu'au démarrage, toute
modification demande un restart du service.

## Ajouter un modèle

Un seul endroit : un bloc dans `lib/models.sh`, à la position voulue dans le
ini (l'ordre de déclaration est l'ordre d'émission) :

1. `download_hf <dossier> <repo> VAR_PATH=<fichier>` (ou
   `download_hf_shards` avec le shard 00001 ; plusieurs `VAR=` pour un
   drafter MTP externe) — définit le chemin, alimente `KNOWN_FILES`
   (source unique de `--cleanup`) et les téléchargements de `--setup` ;
2. `llama_model <section> "<corps ini>"` avec son commentaire métier (sampling,
   cache, contraintes MTP) — un `download_hf` peut servir plusieurs
   sections (même GGUF) ;
3. `groupe "; --- titre ---"` avant le premier `llama_model` si nouvelle famille.

Exemple complet (le corps ini reprend la variable définie par
`download_hf`, qui doit donc être déclaré avant) :

```bash
groupe "; --- Mon-Modele 7B (nouvelle famille) ---"

# Mon-Modele 7B : pourquoi ce repo et ce quant (taille, reco amont, date)
download_hf mon-modele-7b "org/Mon-Modele-7B-GGUF" \
  MON_MODELE_7B_PATH="Mon-Modele-7B-UD-Q4_K_XL.gguf"

# Mon-Modele 7B : justification des réglages (sampling officiel, cache,
#   contraintes) ; ce commentaire est la connaissance métier du modèle
llama_model mon-modele-7b "
model            = $MON_MODELE_7B_PATH
ctx-size         = 32768
cache-ram        = 2048
temp             = 0.7
top-k            = 20
top-p            = 0.8
min-p            = 0.0
parallel         = 4"
```

Variantes : `download_hf_shards` prend le shard 00001 avec son sous-dossier
de quant (le glob de téléchargement en est dérivé) ; un appel `download_hf`
peut porter plusieurs `VAR=fichier` (ex : modèle + drafter spéculatif externe) ;
deux `llama_model` peuvent référencer le même `*_PATH` (même GGUF, cas Qwen3.8-27B).

Puis `./setup-llm.sh --update <dossier>` pour télécharger et régénérer.
Les garde-fous de préchargement (poids dupliqués) sont dérivés des
déclarations : même GGUF partagé, ou dossiers `<clé>` et `<clé>-mtp` — nommer
la variante MTP avec le suffixe `-mtp` suffit, rien d'autre à maintenir.

## Outils (tools/)

| Fichier | Rôle |
|---|---|
| `opencode-sync-model.sh` | Synchronise la liste des modèles du serveur (`/v1/models`) dans la config opencode (`~/.config/opencode/opencode.json`, provider `llamaswap`). Variables : `ENDPOINT`, `CONFIG`, `PROVIDER` |
| `llm-setup.ts` | Extension pi : découvre les modèles sur `/v1/models` (ctx, n-predict, reasoning depuis `status.args`) et enregistre le provider `llamaswap`. A copier dans `~/.pi/agent/extensions/`. Variable : `LLAMASWAP_ENDPOINT` |

Les deux pointent sur `http://bigchuck:8009` par défaut (surchargeable par variable d'environnement).

## FAQ

**Un modèle échoue au chargement, ROCm0 a disparu.**
`--list-devices` croise `bench-devices.conf` avec les devices réellement
exposés. Réinstaller `ggml-hip`, ou forcer Vulkan0 dans la conf puis `--preload`.

**Je peux éditer models.ini ?**
Non, il est régénéré à chaque `--setup`, `--preload` ou `--spec-*`.
Éditer les fichiers `.conf` ou `lib/models.sh`.

**Pourquoi `parallel = 1` sur les modèles MTP ?**
Contrainte llama.cpp : `-np` supérieur à 1 et `--mmproj` ne sont pas supportés
avec MTP. Un modèle non-MTP séparé sur le même GGUF rend le parallélisme.
