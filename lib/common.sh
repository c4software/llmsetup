# lib/common.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

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
  systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null || return 0
  local reply="n"
  if [[ -t 0 ]]; then
    read -r -p "Le service $SERVICE_NAME tourne — redémarrer maintenant pour appliquer ? [O/n] " reply
    reply="${reply:-o}"
  else
    warn "Service $SERVICE_NAME actif — redémarrage non effectué (entrée non interactive)."
    warn "  Appliquer : systemctl --user restart $SERVICE_NAME"
    return 0
  fi
  if [[ "$reply" =~ ^[oOyY]$ ]]; then
    info "Redémarrage de $SERVICE_NAME..."
    systemctl --user restart "$SERVICE_NAME" \
      && info "✅ $SERVICE_NAME redémarré." \
      || warn "Redémarrage en échec — voir : journalctl --user -u $SERVICE_NAME -e"
  else
    info "Redémarrage sauté — appliquer plus tard : systemctl --user restart $SERVICE_NAME"
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
CONFIG_DIR="$MODELS_BASE"

# Port du routeur llama-server (service --start et mesures via l'API)
SERVER_PORT=8009

# Device retenu par GGUF — clé = dossier sous $MODELS_BASE.
# Format : "clé = device", commentaires ";". Édition manuelle (guidée par
# les mesures de --bench, qui n'écrit rien lui-même).
# Vit À CÔTÉ DU SCRIPT (local, non versionné — .gitignore), pas dans $MODELS_BASE.
BENCH_CONF="$SCRIPT_DIR/bench-devices.conf"

# =============================================================================
# PRÉCHARGEMENT (always-on)
#
# La liste des modèles préchargés (load-on-startup) vit dans preload.conf
# (à côté du script, comme bench-devices.conf — local, non versionné),
# alimenté par la sélection interactive à cases à cocher du --setup (gum si
# présent, fallback bash sinon) ou par ./setup-llm.sh --preload. Un modèle
# sélectionné devient always-on (load-on-startup=true) ; les autres sont
# chargés à la demande et évincés par le LRU de --models-max (dérivé
# automatiquement : nb préchargés + 1 slot LRU).
# =============================================================================

PRELOAD_CONF="$SCRIPT_DIR/preload.conf"

SPEC_TEST_URL="http://localhost:$SERVER_PORT"
# Journal des runs (à côté du script) — sert à l'analyse n-max : dès 2 runs à
# des n-max différents sur le même modèle/GGUF/device, le script calibre un
# modèle simple et prédit la courbe t/s(n-max).
SPEC_LOG="$SCRIPT_DIR/spec-tests.log"
# Surcharges spec-draft-n-max par modèle (à côté du script, comme
# bench-devices.conf) — écrit par --spec-tune, appliqué par generate_models_ini
# par-dessus la valeur de MODEL_INI (qui reste le défaut). Format "modèle = k".
SPEC_CONF="$SCRIPT_DIR/spec-nmax.conf"
# Surcharges spec-ngram-map-k-size-m par modèle (même statut que spec-nmax.conf :
# choix utilisateur, local, non versionné). Écrit par --spec-ngram-tune, appliqué
# par generate_models_ini par-dessus la valeur de MODEL_INI. Format "modèle = m".
# La longueur de draft n-gram dépend du couple (modèle, device) : le coût d'un
# forward de batch m+1 dépend du noyau ggml retenu, qui n'est pas le même d'un
# backend à l'autre — d'où une conf locale plutôt qu'une valeur dans le script.
SPEC_NGRAM_CONF="$SCRIPT_DIR/spec-ngram.conf"

SERVICE_NAME="llama-server"
# Service systemd USER : piloté par systemctl --user, démarre au
# boot sans session via loginctl enable-linger (posé par --install-service)
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
