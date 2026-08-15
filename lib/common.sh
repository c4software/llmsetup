# lib/common.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

# =============================================================================
# Helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Propose un restart du service systemd si actif — appelé en fin de setup /
# update / cleanup / preload (config ou poids modifiés). Rappel : les poids
# déjà mmap'és restent sur l'ancien inode tant que le serveur n'a pas redémarré.
# Non-interactif : jamais de restart automatique, juste le rappel.
_maybe_restart_service() {
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || return 0
  local reply="n"
  if [[ -t 0 ]]; then
    read -r -p "Le service $SERVICE_NAME tourne — redémarrer maintenant pour appliquer (sudo) ? [O/n] " reply
    reply="${reply:-o}"
  else
    warn "Service $SERVICE_NAME actif — redémarrage non effectué (entrée non interactive)."
    warn "  Appliquer : sudo systemctl restart $SERVICE_NAME"
    return 0
  fi
  if [[ "$reply" =~ ^[oOyY]$ ]]; then
    info "Redémarrage de $SERVICE_NAME..."
    sudo systemctl restart "$SERVICE_NAME" \
      && info "✅ $SERVICE_NAME redémarré." \
      || warn "Redémarrage en échec — voir : journalctl -u $SERVICE_NAME -e"
  else
    info "Redémarrage sauté — appliquer plus tard : sudo systemctl restart $SERVICE_NAME"
  fi
}

# REFRESH=1 : on ne court-circuite plus sur "fichier déjà présent", on laisse
#   `hf download` comparer les etags et ne retélécharger que ce qui a bougé.
# ONLY : si non vide, ne traite que le modèle dont le dossier porte ce nom.
REFRESH=0
ONLY=""

# Clé d'un modèle = premier segment sous $MODELS_BASE
# (fonctionne pour les fichiers plats comme pour les dossiers de shards)
_key() {
  local p="${1#"$MODELS_BASE"/}"
  echo "${p%%/*}"
}

_skip() {
  [[ -n "$ONLY" && "$(_key "$1")" != "$ONLY" ]]
}

# Résout la clé d'un modèle (nom de dossier) vers son chemin dans KNOWN_FILES
_path_for_key() {
  local key="$1" f
  for f in "${KNOWN_FILES[@]}"; do
    if [[ "$(_key "$f")" == "$key" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

_dl() {
  local target="$1" repo="$2"
  shift 2
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement $(basename "$target")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" "$@" --local-dir "$(dirname "$target")"
}

_dl_shard() {
  local target="$1" repo="$2" glob="$3"
  local shard_dir dest_dir
  shard_dir="$(dirname "$target")"
  dest_dir="$(dirname "$shard_dir")"
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement shards $(basename "$shard_dir")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" --include "$glob" --local-dir "$dest_dir"
}

# =============================================================================
# CHEMINS
# =============================================================================

MODELS_BASE="$HOME/models"
CONFIG_DIR="$HOME/models"

# Fichier des vainqueurs par modèle — clé = dossier sous $MODELS_BASE.
# Format : "clé = device", commentaires ";". Édition manuelle possible
# (conservée tant que la clé n'est pas re-benchée).
# Vit À CÔTÉ DU SCRIPT (versionnable avec lui), pas dans $MODELS_BASE.
BENCH_CONF="$SCRIPT_DIR/bench-devices.conf"

# Migration depuis l'ancien emplacement ($CONFIG_DIR) — one-shot, idempotent
if [[ -f "$CONFIG_DIR/bench-devices.conf" && ! -f "$BENCH_CONF" ]]; then
  mv "$CONFIG_DIR/bench-devices.conf" "$BENCH_CONF"
  echo "[INFO] bench-devices.conf migré : $CONFIG_DIR → $SCRIPT_DIR"
fi
# =============================================================================
# PRÉCHARGEMENT (always-on)
#
# La liste des modèles préchargés (load-on-startup) vit dans preload.conf
# (à côté du script, comme bench-devices.conf — versionnable avec lui),
# alimenté par la sélection interactive à cases à cocher du --setup (gum si
# présent, fallback bash sinon) ou par ./setup-llm.sh --preload. Un modèle
# sélectionné devient always-on (load-on-startup=true) ; les autres sont
# chargés à la demande et évincés par le LRU de --models-max (dérivé
# automatiquement : nb préchargés + 1 slot LRU).
# =============================================================================

PRELOAD_CONF="$SCRIPT_DIR/preload.conf"
DEFAULT_PRELOAD=(qwen3.5-9b qwen3.6-35b-a3b-nothink)

# Migration depuis l'ancien emplacement ($CONFIG_DIR) — one-shot, idempotent
if [[ -f "$CONFIG_DIR/preload.conf" && ! -f "$PRELOAD_CONF" ]]; then
  mv "$CONFIG_DIR/preload.conf" "$PRELOAD_CONF"
  echo "[INFO] preload.conf migré : $CONFIG_DIR → $SCRIPT_DIR"
fi

SPEC_TEST_URL="http://localhost:8009"
# Journal des runs (à côté du script) — sert à l'analyse n-max : dès 2 runs à
# des n-max différents sur le même modèle/GGUF/device, le script calibre un
# modèle simple et prédit la courbe t/s(n-max).
SPEC_LOG="$SCRIPT_DIR/spec-tests.log"
# Surcharges spec-draft-n-max par modèle (à côté du script, comme
# bench-devices.conf) — écrit par --spec-tune, appliqué par generate_models_ini
# par-dessus la valeur de MODEL_INI (qui reste le défaut). Format "modèle = k".
SPEC_CONF="$SCRIPT_DIR/spec-nmax.conf"

SERVICE_NAME="llama-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
