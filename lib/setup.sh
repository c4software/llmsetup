# lib/setup.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# setup
# =============================================================================

# Dépendances de l'hôte, réduites au strict nécessaire depuis le 18/09/2026.
#
# Ce qui est parti ce jour-là, avec le fork : llama-cpp et les backends ggml
# splittés (ggml-cpu, ggml-vulkan, ggml-hip), et le runtime ROCm de l'hôte
# (rocm-hip-runtime, hipblas, rocblas, hipblaslt) qu'installait ROCM_PKGS en
# best-effort. Plus aucun binaire llama-* ni aucun backend ggml n'est appelé
# sur l'hôte : le service ET les outils hors service tournent dans l'image, qui
# embarque son propre ROCm. Les paquets déjà installés sur une machine ne sont
# PAS désinstallés par le dépôt (--setup n'a jamais rien désinstallé) : les
# retirer à la main si la place manque.
#
# Reste donc : curl, hf (python-huggingface-hub + python-hf-xet) pour les
# téléchargements, docker et son démon pour le moteur.
cmd_setup() {
  info "Vérification des dépendances..."
  PACMAN_PKGS=(curl python-huggingface-hub python-hf-xet)
  MISSING=()
  for pkg in "${PACMAN_PKGS[@]}"; do
    paru -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
  done
  [[ ${#MISSING[@]} -gt 0 ]] && paru -S --noconfirm "${MISSING[@]}"
  command -v hf >/dev/null || error "hf introuvable"

  info "Création des dossiers..."
  local f
  for f in "${KNOWN_FILES[@]}"; do
    mkdir -p "$(dirname "$f")"
  done

  # Téléchargements pilotés par les déclarations de models.sh (DL_SPECS),
  # dans l'ordre de déclaration (= ordre du ini)
  # p1/p2 : sens dépendant du mode : repo + fichier (plat), repo + glob (shard).
  # (le mode "derive", fichier calculé en local après coup, a disparu le
  # 18/09/2026 avec son seul usage, cf. lib/models.sh)
  local spec mode cible p1 p2
  for spec in "${DL_SPECS[@]}"; do
    IFS=$'\t' read -r mode cible p1 p2 <<< "$spec"
    case "$mode" in
      plat)   _dl "$cible" "$p1" "$p2" ;;
      shard)  _dl_shard "$cible" "$p1" "$p2" ;;
    esac
  done

  # --- Moteur : docker + image ---------------------------------------------
  # Le dépôt ne lance plus aucun binaire de l'hôte : le service monte un
  # conteneur décrit par le compose généré, et les outils passent par _dk_run.
  # Sans docker ou sans image, --setup va jusqu'au bout (les poids et le ini
  # sont utiles quand même) mais le dit.
  _setup_check_docker

  info "Sélection des modèles préchargés au démarrage..."
  select_preload_models

  info "Génération de models.ini et du docker-compose.yml..."
  regen_models_ini
  # Le compose n'est pas indispensable au reste du setup : _svc_start le
  # régénère de toute façon. Le générer ici sert à échouer TÔT et clairement
  # (image absente, groupe render manquant) plutôt qu'au premier --start.
  regen_compose || warn "docker-compose.yml non généré (voir ci-dessus) - --start le retentera."

  info "✅ Config générée : $CONFIG_DIR/models.ini"
  info "Setup terminé → ./setup-llm.sh --start"
  info "Changer le préchargement → ./setup-llm.sh --preload"
  info "Mesurer les perfs → ./setup-llm.sh --bench [modèle|all]"
  info "Devices exposés par l'image → ./setup-llm.sh --list-devices"

  _maybe_restart_service
}

# Moteur : docker et l'image du dépôt. Jamais bloquant - un --setup sert aussi
# à télécharger des poids sur une machine qui ne servira rien.
# Isolée de cmd_setup pour être testable seule : cmd_setup fait paru, hf et
# réseau, cette fonction ne lit que l'état de docker.
_setup_check_docker() {
  info "Vérification du moteur (docker + image)..."
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker introuvable : le service tourne en CONTENEUR, il ne démarrera pas ici."
    warn "  Installer docker, activer le démon au boot, puis ./setup-llm.sh --image-build."
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    warn "Le démon docker ne répond pas (non démarré, ou utilisateur hors du groupe docker)."
    warn "  Sans lui, ni --image-build ni --start ne fonctionnent."
    warn "  Démon      : sudo systemctl enable --now docker"
    warn "  Groupe     : sudo usermod -aG docker \$USER (puis rouvrir la session)"
    return 0
  fi
  # Activé AU BOOT, et pas seulement démarré : c'est docker qui relance le
  # conteneur au redémarrage de la machine (restart: unless-stopped), il a
  # remplacé le loginctl enable-linger de l'unité systemd. Un démon actif mais
  # non activé donne un service qui ne revient pas après un reboot.
  if command -v systemctl >/dev/null 2>&1; then
    if ! systemctl is-enabled docker >/dev/null 2>&1; then
      warn "  Le démon docker n'est pas activé au boot : le service ne reviendra pas"
      warn "  après un redémarrage de la machine. sudo systemctl enable --now docker"
    fi
  fi
  # Appartenance au groupe docker : docker info a répondu, donc l'accès marche
  # dans CE shell ; le contrôle sert aux sessions où il passerait par sudo.
  if ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    warn "  \$USER n'est pas dans le groupe docker (l'accès actuel passe par autre chose)."
    warn "  sudo usermod -aG docker \$USER, puis rouvrir la session."
  fi
  local ref
  if ref="$(_image_ref 2>/dev/null)"; then
    info "  Image du moteur : $ref (étiquette des mesures : $(_llama_build))"
  else
    warn "  Aucune image du moteur ici - ./setup-llm.sh --image-build (40 à 60 min à froid)."
  fi
  return 0
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
#   --update qwen3.8-27b    (repo day-zero mi-août, template/quants mouvants)
#   (l'entrée laguna-s-2.1, fix rope/context 256K YaRN + fixes poolside, est
#    tombée avec le retrait du modèle le 15/09/2026 : docs/HISTORIQUE.md)
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

  # Suivi du moteur : les modèles viennent d'être mis à jour, le MOTEUR qui les
  # sert ne l'est pas par cette commande. Il vit dans l'image, dont les
  # révisions sont épinglées à la main dans runtime/Dockerfile.rocm-strix : rien
  # n'est lancé automatiquement ici, ni bump du moteur, ni restart, ni mesure.
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
# ⚠ Les deux artefacts GÉNÉRÉS de $MODELS_BASE - `models.ini` (lib/ini.sh) et
# `docker-compose.yml` (lib/compose.sh) - sont hors d'atteinte PAR
# CONSTRUCTION, et les deux `find` ci-dessous ne doivent donc jamais être
# « corrigés » en ce sens : le premier ne liste que des DOSSIERS de premier
# niveau (`-maxdepth 1 -type d`), le second que des fichiers `*.gguf` à partir
# de la profondeur 2 (`-mindepth 2 -name '*.gguf'`). Ces deux fichiers sont des
# fichiers de premier niveau qui ne sont pas des .gguf : aucune des deux
# recherches ne peut les voir. Les élargir (retirer `-maxdepth`, viser `-type f`
# à la racine) supprimerait la configuration du service à chaque --cleanup,
# alors qu'elle se régénère certes, mais pas au milieu d'un run.
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
