# llm-setup

Pilote un `llama-server` en **router mode natif** sur une machine Strix Halo
(Ryzen AI Max+ 395, 128 Go unifiés, CachyOS/Arch). Un seul point d'entrée,
`./setup-llm.sh`, qui : télécharge les GGUF (via `hf`), génère
`~/models/models.ini` (presets + flags mûris dans les commentaires de
`lib/presets.sh`), gère le préchargement always-on vs LRU, mesure les perfs
par l'API du serveur, règle la spéculation MTP (`spec-draft-n-max`) par
mesure/calibration, et installe le service systemd. Les backends ggml
(Vulkan par défaut, ROCm/HIP optionnel) sont des paquets Arch séparés depuis
le split de mi-août 2026. Tout le comportement est piloté par des fichiers de
conf versionnables à côté du script — le `models.ini` lui-même est généré,
jamais édité.

## Prérequis

- Arch/CachyOS, `paru`, bash ≥ 4.3, python3 (stdlib seule), curl, `hf`
  (python-huggingface-hub + python-hf-xet), `gum` optionnel (menus à cocher).
- Paquets llama.cpp : `llama-cpp` + backends ggml **splittés** — `ggml-cpu`,
  `ggml-vulkan` (obligatoires, installés par `--setup`), et pour ROCm0 :
  `ggml-hip` **plus** le runtime ROCm (`rocm-hip-runtime hipblas rocblas
  hipblaslt`) — le runtime seul ne fait plus apparaître ROCm0. Contrôle :
  `rocminfo | grep gfx` doit donner gfx1151.

## Installation

```bash
./setup-llm.sh --setup            # dépendances, GGUF, préchargement, models.ini
./setup-llm.sh --install-service  # service systemd llama-server (boot)
sudo systemctl start llama-server
```

## Sous-commandes

| Commande | Rôle |
|---|---|
| `--setup` | Dépendances (paru), ROCm proposé, téléchargement des GGUF manquants, sélection du préchargement, génération du ini |
| `--update [modèle]` | Comme `--setup` mais laisse `hf` comparer les etags (ne retélécharge que ce qui a bougé) |
| `--cleanup [--yes]` | Supprime dossiers/GGUF orphelins (hors `KNOWN_FILES`) ; dry-run par défaut |
| `--preload` | Re-sélectionne les presets always-on, régénère le ini |
| `--bench [preset\|all] [n]` | Perfs du serveur tel qu'il tourne : prefill ~8K + décode médian + acceptance, récapitulatif ; n'écrit rien |
| `--list-devices` | Backends ggml installés + devices exposés, croisés avec `bench-devices.conf` |
| `--spec-test [preset] [n]` | Décode réel via l'API (spéculation incluse), journalise, et dès 2 n-max mesurés : calibre, recommande et persiste |
| `--spec-tune [preset] [k1,k2,..] [n]` | Boucle automatique sur plusieurs n-max (restart entre chaque), retient le meilleur mesuré |
| `--start` | Lance llama-server sur :8009 (commande du service) |
| `--install-service` / `--uninstall-service` | Service systemd système |
| `--help` | Aide + liste des presets et clés modèles |

## Workflow typique

```bash
./setup-llm.sh --setup            # première mise en place
./setup-llm.sh --bench all        # perfs de tous les presets présents
./setup-llm.sh --spec-tune        # règle spec-draft-n-max d'un preset MTP (2,4,6)
./setup-llm.sh --update qwen3.8-27b   # après un re-upload unsloth
```

## Fichiers de conf (à côté du script, versionnés — ce sont des choix)

| Fichier | Rôle |
|---|---|
| `bench-devices.conf` | clé (dossier GGUF) = device (Vulkan0/ROCm0) ; édition manuelle |
| `preload.conf` | presets préchargés (always-on), un par ligne ; `--models-max` = nb de lignes + 1 slot LRU |
| `spec-nmax.conf` | `preset = spec-draft-n-max` retenu par `--spec-tune`/`--spec-test` ; supprimer une ligne = retour au défaut du script |
| `spec-tests.log` | journal TSV des runs `--spec-test` (local, **non versionné** — .gitignore) |

Côté `~/models/` : `models.ini`, **généré** — ne jamais l'éditer, relancer
`--preload`/`--setup`. Le routeur ne le lit **qu'au démarrage** : toute
modification exige un restart du service.

## Ajouter un modèle

C'est aujourd'hui volontairement **5 endroits** (non fusionnés, cf. dette dans
AGENTS.md), tous dans `lib/` :

1. `lib/models.sh` : variables `MODEL_<NOM>_REPO` / `MODEL_<NOM>_FILE`
   (+ `_FILE_GLOB`/`_FILE_ENTRY` pour les shards) ;
2. `lib/models.sh` : le chemin `<NOM>_PATH` puis l'entrée dans `KNOWN_FILES`
   (source unique de `--cleanup` — un modèle retiré d'ici devient supprimable) ;
3. `lib/presets.sh` : le corps `MODEL_INI[<preset>]` avec son commentaire
   métier (sampling, cache, contraintes MTP…) ;
4. `lib/presets.sh` : la position dans `PRESET_ORDER` (ordre d'émission du ini) ;
5. `lib/setup.sh` : la ligne `_dl`/`_dl_shard` dans `cmd_setup`.

Puis `./setup-llm.sh --update <dossier>` pour télécharger et régénérer.

## FAQ courte

- **Un preset échoue au chargement, device ROCm0 disparu ?** → `--list-devices`
  (croise `bench-devices.conf` avec les devices réellement exposés ; réinstaller
  `ggml-hip` ou forcer Vulkan0 dans la conf puis `--preload`).
- **Je peux éditer models.ini ?** Non — regénéré à chaque `--setup`/`--preload`/
  `--spec-*`. Éditer les `.conf` ou `lib/presets.sh`.
- **Pourquoi `parallel = 1` sur les presets MTP ?** Contrainte llama.cpp :
  `-np > 1` et `--mmproj` non supportés avec MTP (doc unsloth, juin/juillet
  2026). Un preset non-MTP séparé sur le même GGUF rend le parallélisme.
