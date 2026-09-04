# lib/setup.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# setup
# =============================================================================

# Runtime ROCm + backend ggml-hip — installés en best-effort par --setup
# (jamais bloquant). ggml-hip est le backend HIP splitté d'extra/ggml : sans
# lui, ROCm0 n'est pas exposé même runtime installé.
# gfx1151 requis côté rocblas/hipblaslt : contrôler avec `rocminfo | grep gfx`.
ROCM_PKGS=(rocm-hip-runtime hipblas rocblas hipblaslt ggml-hip)

cmd_setup() {
  info "Vérification des dépendances..."
  # ggml-cpu + ggml-vulkan : backends splittés d'extra/ggml (optdeps, donc
  # à imposer — sans ggml-vulkan plus de Vulkan0, sans ggml-cpu plus d'ops CPU)
  PACMAN_PKGS=(curl llama-cpp ggml-cpu ggml-vulkan python-huggingface-hub python-hf-xet)
  MISSING=()
  for pkg in "${PACMAN_PKGS[@]}"; do
    paru -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
  done
  [[ ${#MISSING[@]} -gt 0 ]] && paru -S --noconfirm "${MISSING[@]}"
  command -v hf >/dev/null || error "hf introuvable"

  # --- Runtime ROCm + ggml-hip : best-effort, jamais bloquant ---------------
  # (backend HIP splitté : ggml-hip requis EN PLUS du runtime pour voir ROCm0)
  info "Vérification du runtime ROCm (optionnel)..."
  local rocm_missing=() rocm_to_install=()
  local pkg
  for pkg in "${ROCM_PKGS[@]}"; do
    if paru -Qi "$pkg" &>/dev/null; then
      continue
    elif paru -Si "$pkg" &>/dev/null; then
      rocm_to_install+=("$pkg")
    else
      rocm_missing+=("$pkg")
    fi
  done
  if [[ ${#rocm_to_install[@]} -gt 0 ]]; then
    warn "Paquets ROCm à installer (backend ROCm0 pour --bench) : ${rocm_to_install[*]}"
    local reply="n"
    if [[ -t 0 ]]; then
      read -r -p "Installer le runtime ROCm ? [o/N] " reply
    else
      warn "Entrée non interactive — installation ROCm sautée par défaut."
    fi
    if [[ "$reply" =~ ^[oOyY]$ ]]; then
      paru -S --noconfirm "${rocm_to_install[@]}" \
        || warn "Installation ROCm en échec — Vulkan0 reste pleinement fonctionnel."
    else
      info "Runtime ROCm non installé — le setup continue sur Vulkan0 seul."
      info "  (relancer --setup plus tard pour l'ajouter et débloquer ROCm0 dans --bench)"
    fi
  fi
  if [[ ${#rocm_missing[@]} -gt 0 ]]; then
    warn "Paquets ROCm introuvables dans les dépôts : ${rocm_missing[*]}"
    warn "  → le défaut Vulkan0 du models.ini reste pleinement fonctionnel sans ;"
    warn "    ROCm0 n'apparaîtra simplement pas dans --bench."
  fi
  if command -v rocminfo >/dev/null 2>&1; then
    if rocminfo 2>/dev/null | grep -q gfx1151; then
      info "ROCm OK : gfx1151 (Strix Halo) détecté."
    else
      warn "rocminfo présent mais gfx1151 non détecté — rocblas/hipblaslt sans"
      warn "  support gfx1151 ? (alternative AUR : rocm-nightly-gfx1151-bin)"
    fi
  fi
  # -------------------------------------------------------------------------

  info "Création des dossiers..."
  local f
  for f in "${KNOWN_FILES[@]}"; do
    mkdir -p "$(dirname "$f")"
  done

  # Téléchargements pilotés par les déclarations de models.sh (DL_SPECS),
  # dans l'ordre de déclaration (= ordre du ini)
  local spec mode cible repo arg
  for spec in "${DL_SPECS[@]}"; do
    IFS=$'\t' read -r mode cible repo arg <<< "$spec"
    case "$mode" in
      plat)  _dl "$cible" "$repo" "$arg" ;;
      shard) _dl_shard "$cible" "$repo" "$arg" ;;
    esac
  done

  info "Sélection des modèles préchargés au démarrage..."
  select_preload_models

  info "Génération de models.ini..."
  regen_models_ini

  info "✅ Config générée : $CONFIG_DIR/models.ini"
  info "Setup terminé → ./setup-llm.sh --start"
  info "Changer le préchargement → ./setup-llm.sh --preload"
  info "Mesurer les perfs → ./setup-llm.sh --bench [modèle|all]"
  info "Devices exposés → ./setup-llm.sh --list-devices"

  _maybe_restart_service
}

# =============================================================================
# update — retélécharge uniquement les fichiers modifiés en amont
#
# `hf download --local-dir` conserve les métadonnées de chaque fichier dans
# <dossier>/.cache/huggingface/download/. Au second passage il compare l'etag
# distant et ne retransfère que ce qui a réellement bougé — le reste ne coûte
# qu'une requête HEAD. Le seul travail du script est donc de ne PAS court-
# circuiter sur "fichier déjà présent" (REFRESH=1).
#
# Note : la toute première mise à jour d'un fichier téléchargé avant que les
# métadonnées n'existent oblige hf à recalculer son sha256 en local — comptez
# une lecture disque complète du GGUF, sans réseau.
#
# Updates amont connus (juillet/août 2026) à rattraper si téléchargés avant :
#   --update laguna-s-2.1   (fix rope/context 256K YaRN + fixes poolside)
#   --update qwen3.8-27b    (repo day-zero mi-août, template/quants mouvants)
#   --update qwopus3.6-27b-coder-mtp  (repo squashé, re-validation etags)
# =============================================================================

cmd_update() {
  ONLY="${1:-}"
  REFRESH=1

  if [[ -n "$ONLY" ]]; then
    [[ -d "$MODELS_BASE/$ONLY" ]] || error "Modèle inconnu : '$ONLY' (voir $MODELS_BASE/)"
    info "Vérification des mises à jour pour '$ONLY'..."
  else
    info "Vérification des mises à jour pour tous les modèles..."
  fi

  warn "Prévoir 2× la taille du plus gros fichier remplacé (écriture en .incomplete puis move)."
  warn "Un restart du service sera proposé en fin de run (poids mmap'és sur l'ancien inode sinon)."

  cmd_setup
}

# =============================================================================
# cleanup — supprime ce qui n'est plus référencé dans KNOWN_FILES
#
# Deux niveaux :
#   1. dossiers de premier niveau sous $MODELS_BASE dont plus aucun modèle ne
#      dépend (ex. qwen3.6-27b, qwen3.6-27b-mtp après leur remplacement par
#      qwen3.8-27b)
#   2. .gguf orphelins à l'intérieur d'un dossier encore référencé (ex. l'ancien
#      quant après un changement de UD-Q6_K_XL vers UD-Q4_K_XL)
#
# Les modèles en shards sont protégés au niveau du dossier de quant : KNOWN_FILES
# ne cite que le shard 00001, les suivants ne doivent évidemment pas sauter.
#
# Dry-run par défaut ; --yes pour exécuter réellement.
# =============================================================================

_in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

cmd_cleanup() {
  local assume_yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1

  [[ -d "$MODELS_BASE" ]] || error "$MODELS_BASE introuvable"

  local f d parent
  local -a keep_keys=() keep_files=() keep_dirs=()

  for f in "${KNOWN_FILES[@]}"; do
    d="$(dirname "$f")"
    parent="$(dirname "$d")"
    keep_keys+=("$(_key "$f")")
    if [[ "$parent" == "$MODELS_BASE" ]]; then
      # fichier plat : on protège le fichier lui-même
      keep_files+=("$f")
    else
      # layout en shards : on protège tout le dossier de quant
      keep_dirs+=("$d")
    fi
  done

  local -a doomed=()

  # 1. dossiers de modèle entiers
  while IFS= read -r d; do
    _in_list "$(basename "$d")" "${keep_keys[@]}" || doomed+=("$d")
  done < <(find "$MODELS_BASE" -mindepth 1 -maxdepth 1 -type d ! -name '.cache' | sort)

  # 2. .gguf orphelins dans les dossiers conservés
  while IFS= read -r f; do
    _in_list "$(_key "$f")" "${keep_keys[@]}" || continue  # déjà couvert par 1.
    _in_list "$f" "${keep_files[@]}" && continue
    _in_list "$(dirname "$f")" "${keep_dirs[@]}" && continue
    doomed+=("$f")
  done < <(find "$MODELS_BASE" -mindepth 2 -type f -name '*.gguf' | sort)

  if [[ ${#doomed[@]} -eq 0 ]]; then
    info "Rien à nettoyer, $MODELS_BASE est aligné sur le script."
    return
  fi

  warn "À supprimer (${#doomed[@]} entrée(s)) :"
  for f in "${doomed[@]}"; do
    echo "  $(du -sh "$f" 2>/dev/null | cut -f1)  $f"
  done

  if [[ "$assume_yes" -eq 0 ]]; then
    info "Dry-run — relance avec './setup-llm.sh --cleanup --yes' pour supprimer."
    return
  fi

  for f in "${doomed[@]}"; do
    rm -rf -- "$f"
    info "Supprimé : $f"
  done

  # dossiers de quant vidés + métadonnées hf devenues orphelines
  find "$MODELS_BASE" -mindepth 2 -type d -empty -delete 2>/dev/null || true

  info "✅ Nettoyage terminé."

  _maybe_restart_service
}
