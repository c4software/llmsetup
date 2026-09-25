# lib/gufo.sh : sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → gufo → help

# =============================================================================
# gufo : moteur alternatif à la place du service sur SERVER_PORT
#
# gufo (docs/GUFO.md) ne sert qu'un modèle par processus et n'accepte que ses
# propres GGUF : il ne s'intègre pas au routeur, il PREND SA PLACE sur le port.
# Même schéma que le service : compose versionné (runtime-gufo/
# docker-compose.yml) et .env généré ici, dans GUFO_DATA, avec les seules
# valeurs machine. gufo démarre toujours derrière llama-swap
# (runtime-gufo/gufo-llama-swap.yaml, seule description des lignes de
# commande) : le client choisit le modèle par le champ « model », llama-swap
# arrête un processus gufo pour lancer l'autre ; --gufo [modèle] ne choisit
# que le modèle préchargé. Un seul moteur
# à la fois (même port, un GPU) : --gufo arrête le service, --gufo-off
# supprime gufo (compose down) et relance le service, --start et --restart du
# service refusent tant que gufo tourne (_gufo_refuse, lib/svc.sh). Le dernier
# lancé repart seul au démarrage de la machine (restart: unless-stopped des
# deux côtés, l'autre étant arrêté ou supprimé).
#
# Variables (environnement), pour les bancs de runtime-gufo/bench/ surtout :
#   GUFO_DATA      données hors dépôt et hors ~/models : models/ (GGUF de
#                  référence), cache/ (cache disque), resultats/, .env
#                  (défaut ~/llm/gufo-test)
#   GUFO_IMAGE     image (défaut ghcr.io/gufo-org/toolboxes/gufo-runtime:latest)
#   GUFO_SESSIONS  sessions (défaut 2)
#   GUFO_PORT      port hôte (défaut SERVER_PORT)
#   GUFO_RESTART   politique de redémarrage (défaut unless-stopped)
#   GUFO_PROJET    projet compose (défaut gufo) ; GUFO_CONTENEUR (lib/common.sh)
#   GUFO_PRECHARGE modèle préchargé (défaut qwen3.8-flash-next ; --gufo <modèle>)
#   GUFO_ENV_FILE  .env écrit (défaut GUFO_DATA/.env)
# =============================================================================

GUFO_DIR="$SCRIPT_DIR/runtime-gufo"
GUFO_COMPOSE_FILE="$GUFO_DIR/docker-compose.yml"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
GUFO_IMAGE="${GUFO_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime:latest}"
GUFO_PROJET="${GUFO_PROJET:-gufo}"
GUFO_ENV_FILE="${GUFO_ENV_FILE:-$GUFO_DATA/.env}"
# Noms courts acceptés par --gufo, et le modèle de gufo-llama-swap.yaml qu'ils
# désignent (le nom complet est accepté aussi).
declare -A GUFO_MODELES=(
  [27b]=qwen3.8-27b
  [flashnext]=qwen3.8-flash-next
  [deepseek]=deepseek-v4-flash
)

# _gufo_nom <court|complet> - le nom de modèle de gufo-llama-swap.yaml, ou
# échec si inconnu.
_gufo_nom() {
  local k
  [[ -n "${1:-}" ]] || return 1
  [[ -n "${GUFO_MODELES[$1]:-}" ]] && { echo "${GUFO_MODELES[$1]}"; return 0; }
  for k in "${!GUFO_MODELES[@]}"; do
    [[ "${GUFO_MODELES[$k]}" == "$1" ]] && { echo "$1"; return 0; }
  done
  return 1
}

# generate_gufo_env [modèle préchargé] - le .env de runtime-gufo/
# docker-compose.yml, sur stdout. Échoue (sans rien écrire) si un groupe GPU
# manque.
generate_gufo_env() {
  local precharge="${1:-${GUFO_PRECHARGE:-qwen3.8-flash-next}}" gid_render gid_video
  gid_render="$(_compose_gid render)" || return 1
  gid_video="$(_compose_gid video)" || return 1
  cat <<ENV
# GÉNÉRÉ par ./setup-llm.sh --gufo (lib/gufo.sh) - NE PAS ÉDITER
# Valeurs machine de $GUFO_COMPOSE_FILE ; réécrit à chaque --gufo.
# Usage manuel : cd $GUFO_DATA && docker compose ps | logs -f
COMPOSE_FILE=$GUFO_COMPOSE_FILE
COMPOSE_PROJECT_NAME=$GUFO_PROJET
GUFO_IMAGE=$GUFO_IMAGE
GUFO_CONTENEUR=$GUFO_CONTENEUR
GUFO_RESTART=${GUFO_RESTART:-unless-stopped}
GUFO_PORT=${GUFO_PORT:-$SERVER_PORT}
GUFO_SESSIONS=${GUFO_SESSIONS:-2}
GUFO_RUNTIME_DIR=$GUFO_DIR
GUFO_ROUTEUR_IMAGE=gufo-routeur:latest
GUFO_PRECHARGE=$precharge
SVC_UID=$(id -u)
SVC_GID=$(id -g)
GID_RENDER=$gid_render
GID_VIDEO=$gid_video
MODELS_BASE=$MODELS_BASE
GUFO_DATA=$GUFO_DATA
ENV
}

# _gufo_compose [args compose...] - docker compose sur le compose de gufo et
# SON .env (projet, valeurs machine).
_gufo_compose() {
  docker compose --project-directory "$GUFO_DATA" --env-file "$GUFO_ENV_FILE" \
    -f "$GUFO_COMPOSE_FILE" "$@"
}

# _gufo_wait_ready [timeout=600] - /health de llama-swap, ou échec rapide si
# le conteneur est sorti.
_gufo_wait_ready() {
  local timeout="${1:-600}" t=0 port="${GUFO_PORT:-$SERVER_PORT}"
  until curl -sf "http://localhost:$port/health" >/dev/null 2>&1; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$GUFO_CONTENEUR" 2>/dev/null || true)" != "true" ]]; then
      warn "$GUFO_CONTENEUR s'est arrêté pendant le chargement :"
      docker logs --tail 20 "$GUFO_CONTENEUR" 2>&1 | sed 's/^/  /' >&2 || true
      return 1
    fi
    (( t >= timeout )) && { warn "$GUFO_CONTENEUR ne répond pas après ${timeout} s."; return 1; }
    sleep 2; t=$((t + 2))
  done
  return 0
}

# _gufo_wait_precharge <modèle> - llama-swap répond tout de suite, le modèle
# préchargé suit ; /upstream/<modèle>/health attend qu'il soit prêt (et le
# charge s'il ne l'est pas). Flash-Next ou DeepSeek à froid : ~80 s.
_gufo_wait_precharge() {
  local port="${GUFO_PORT:-$SERVER_PORT}" m="$1"
  info "  llama-swap prêt, chargement de $m..."
  curl -sf -m 600 "http://localhost:$port/upstream/$m/health" >/dev/null 2>&1 \
    || { warn "$m n'a pas répondu par le routeur."; docker logs --tail 20 "$GUFO_CONTENEUR" 2>&1 | sed 's/^/  /' >&2 || true; return 1; }
  return 0
}

# cmd_gufo [modèle préchargé] - arrête le service, lance gufo derrière
# llama-swap sur le port (Flash-Next préchargé par défaut ; 27b, flashnext,
# deepseek ou le nom complet). Échec : gufo retiré et service relancé, jamais
# un port vide.
cmd_gufo() {
  local modele
  modele="$(_gufo_nom "${1:-${GUFO_PRECHARGE:-qwen3.8-flash-next}}")" \
    || error "Modèle gufo inconnu : '${1:-}' (${!GUFO_MODELES[*]}, ou ${GUFO_MODELES[*]})"
  command -v docker >/dev/null 2>&1 || error "docker introuvable"
  docker image inspect "$GUFO_IMAGE" >/dev/null 2>&1 \
    || error "Image $GUFO_IMAGE absente - ./setup-llm.sh --gufo-download image"

  mkdir -p "$GUFO_DATA/models" "$GUFO_DATA/cache"
  local tmp; tmp="$(mktemp)"
  generate_gufo_env "$modele" > "$tmp" || { rm -f "$tmp"; error ".env de gufo non généré (groupes GPU)"; }
  mv -f "$tmp" "$GUFO_ENV_FILE"

  info "gufo (llama-swap, $modele préchargé) à la place du service sur :${GUFO_PORT:-$SERVER_PORT} (données : $GUFO_DATA)"
  cmd_stop
  # down d'abord (gufo déjà lancé, autre préchargement), puis le nom lui-même,
  # au cas où un gufo aurait été lancé hors compose.
  _gufo_compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$GUFO_CONTENEUR" >/dev/null 2>&1 || true
  _gufo_compose up -d || { _gufo_compose down >/dev/null 2>&1 || true; cmd_start; error "compose up de gufo en échec, service relancé"; }
  if ! _gufo_wait_ready || ! _gufo_wait_precharge "$modele"; then
    _gufo_compose down >/dev/null 2>&1 || true
    cmd_start
    error "gufo n'a pas démarré, service relancé"
  fi
  info "✅ gufo prêt : $(curl -s "http://localhost:${GUFO_PORT:-$SERVER_PORT}/v1/models" | head -c 200)"
  info "  Retour au service : ./setup-llm.sh --gufo-off"
}

# cmd_gufo_off - supprime gufo (compose down : il ne repartira pas au
# démarrage) puis relance le service.
cmd_gufo_off() {
  if [[ -f "$GUFO_ENV_FILE" ]]; then
    _gufo_compose down --remove-orphans || warn "compose down de gufo en échec"
  fi
  # Filet : un conteneur gufo lancé hors compose.
  docker rm -f "$GUFO_CONTENEUR" >/dev/null 2>&1 || true
  [[ "${GUFO_SANS_SERVICE:-0}" == 1 ]] && return 0
  cmd_start
}

# cmd_gufo_logs - requêtes de gufo au fil de l'eau (une ligne par requête).
cmd_gufo_logs() {
  _gufo_actif || error "gufo ne tourne pas - ./setup-llm.sh --gufo [${!GUFO_MODELES[*]}]"
  docker logs -f "$GUFO_CONTENEUR" 2>&1 | grep --line-buffered "event=completed"
}

# cmd_gufo_download <image|flashnext|deepseek|tts|asr|qwen-image|all> - image et poids de
# référence, dans GUFO_DATA/models.
cmd_gufo_download() {
  [[ -n "${1:-}" ]] || error "--gufo-download attend : image, flashnext, deepseek, tts, asr, qwen-image ou all"
  GUFO_DATA="$GUFO_DATA" GUFO_IMAGE="$GUFO_IMAGE" "$GUFO_DIR/download.sh" "$1"
}
