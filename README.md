# LLM Setup

LLM Setup pilote un `llama-server` en router mode natif sur une machine Strix Halo
(Ryzen AI Max+ 395, 128 Go unifiés, CachyOS/Arch), avec un seul point d'entrée :
`./setup-llm.sh`.

Ce qu'il gère :

- téléchargement des GGUF depuis Hugging Face (`hf`, mises à jour par etags) ;
- génération de `~/models/models.ini` : les réglages de chaque modèle vivent
  dans `lib/presets.sh` avec leurs justifications en commentaire ;
- préchargement always-on ou chargement à la demande (LRU) ;
- mesure des perfs par l'API du serveur (`--bench`, `--spec-test`) ;
- réglage de la spéculation MTP (`spec-draft-n-max`) par mesure et calibration ;
- service systemd.

Les backends ggml (Vulkan par défaut, ROCm/HIP optionnel) sont des paquets
Arch séparés depuis le split de mi-août 2026. Tout est piloté par des fichiers
de conf versionnés à côté du script. Le `models.ini` est généré, jamais édité.

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

À côté du script, versionnés (ce sont des choix, pas des sorties) :

| Fichier | Rôle |
|---|---|
| `bench-devices.conf` | clé (dossier GGUF) = device (Vulkan0/ROCm0), édition manuelle |
| `preload.conf` | modèles préchargés, un par ligne |
| `spec-nmax.conf` | modèle = spec-draft-n-max retenu par les mesures |
| `spec-tests.log` | journal TSV des runs `--spec-test`, local, non versionné |

Côté `~/models/` : `models.ini`, généré. Ne jamais l'éditer : relancer
`--preload` ou `--setup`. Le routeur ne le lit qu'au démarrage, toute
modification demande un restart du service.

## Ajouter un modèle

Cinq endroits, volontairement non fusionnés (voir la dette dans AGENTS.md) :

1. `lib/models.sh` : variables `MODEL_<NOM>_REPO` et `MODEL_<NOM>_FILE`
   (`_FILE_GLOB` et `_FILE_ENTRY` pour les shards) ;
2. `lib/models.sh` : le chemin `<NOM>_PATH`, puis l'entrée dans `KNOWN_FILES`
   (source unique de `--cleanup`) ;
3. `lib/presets.sh` : le corps `MODEL_INI[<modèle>]` avec son commentaire
   (sampling, cache, contraintes MTP) ;
4. `lib/presets.sh` : la position dans `PRESET_ORDER` (ordre d'émission du ini) ;
5. `lib/setup.sh` : la ligne `_dl` ou `_dl_shard` dans `cmd_setup`.

Puis `./setup-llm.sh --update <dossier>` pour télécharger et régénérer.

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
Éditer les fichiers `.conf` ou `lib/presets.sh`.

**Pourquoi `parallel = 1` sur les modèles MTP ?**
Contrainte llama.cpp : `-np` supérieur à 1 et `--mmproj` ne sont pas supportés
avec MTP. Un modèle non-MTP séparé sur le même GGUF rend le parallélisme.
