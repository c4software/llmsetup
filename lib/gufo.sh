# lib/gufo.sh : sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → gufo → help

# =============================================================================
# gufo : moteur alternatif à la place du service sur SERVER_PORT
#
# gufo (docs/GUFO.md) ne sert qu'un modèle par processus et n'accepte que ses
# propres GGUF : il ne s'intègre pas au routeur, il PREND SA PLACE sur le port.
# Même schéma que le service : compose versionné (runtime-gufo/
# docker-compose.yml, un service par modèle, sélectionné par profil) et .env
# généré ici, dans GUFO_DATA, avec les seules valeurs machine. Un seul moteur
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
#   GUFO_ENV_FILE  .env écrit (défaut GUFO_DATA/.env)
# =============================================================================

GUFO_DIR="$SCRIPT_DIR/runtime-gufo"
GUFO_COMPOSE_FILE="$GUFO_DIR/docker-compose.yml"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
GUFO_IMAGE="${GUFO_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime:latest}"
GUFO_PROJET="${GUFO_PROJET:-gufo}"
GUFO_ENV_FILE="${GUFO_ENV_FILE:-$GUFO_DATA/.env}"
GUFO_MODELES=(27b flashnext 27b-q4km deepseek)

# generate_gufo_env <modèle> - le .env de runtime-gufo/docker-compose.yml, sur
# stdout. Échoue (sans rien écrire) si un groupe GPU manque.
generate_gufo_env() {
  local modele="$1" gid_render gid_video
  gid_render="$(_compose_gid render)" || return 1
  gid_video="$(_compose_gid video)" || return 1
  cat <<ENV
# GÉNÉRÉ par ./setup-llm.sh --gufo (lib/gufo.sh) - NE PAS ÉDITER
# Valeurs machine de $GUFO_COMPOSE_FILE ; réécrit à chaque --gufo.
# Usage manuel : cd $GUFO_DATA && docker compose ps | logs -f
COMPOSE_FILE=$GUFO_COMPOSE_FILE
COMPOSE_PROJECT_NAME=$GUFO_PROJET
COMPOSE_PROFILES=$modele
GUFO_IMAGE=$GUFO_IMAGE
GUFO_CONTENEUR=$GUFO_CONTENEUR
GUFO_RESTART=${GUFO_RESTART:-unless-stopped}
GUFO_PORT=${GUFO_PORT:-$SERVER_PORT}
GUFO_SESSIONS=${GUFO_SESSIONS:-2}
SVC_UID=$(id -u)
SVC_GID=$(id -g)
GID_RENDER=$gid_render
GID_VIDEO=$gid_video
MODELS_BASE=$MODELS_BASE
GUFO_DATA=$GUFO_DATA
ENV
}

# _gufo_compose [args compose...] - docker compose sur le compose de gufo et
# SON .env (projet, profil, valeurs machine).
_gufo_compose() {
  docker compose --project-directory "$GUFO_DATA" --env-file "$GUFO_ENV_FILE" \
    -f "$GUFO_COMPOSE_FILE" "$@"
}

# _gufo_wait_ready [timeout=600] - /health de gufo, ou échec rapide si le
# conteneur est sorti (fichier absent, format refusé…). Flash-Next à froid :
# ~80 s.
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

# cmd_gufo [modèle] - arrête le service, lance gufo sur le port (modèle 27b
# par défaut). Échec : gufo retiré et service relancé, jamais un port vide.
cmd_gufo() {
  local modele="${1:-27b}" m ok=0
  for m in "${GUFO_MODELES[@]}"; do [[ "$m" == "$modele" ]] && ok=1; done
  (( ok )) || error "Modèle gufo inconnu : '$modele' (${GUFO_MODELES[*]})"
  command -v docker >/dev/null 2>&1 || error "docker introuvable"
  docker image inspect "$GUFO_IMAGE" >/dev/null 2>&1 \
    || error "Image $GUFO_IMAGE absente - ./setup-llm.sh --gufo-download image"

  mkdir -p "$GUFO_DATA/models" "$GUFO_DATA/cache"
  local tmp; tmp="$(mktemp)"
  generate_gufo_env "$modele" > "$tmp" || { rm -f "$tmp"; error ".env de gufo non généré (groupes GPU)"; }
  mv -f "$tmp" "$GUFO_ENV_FILE"

  info "gufo '$modele' à la place du service sur :${GUFO_PORT:-$SERVER_PORT} (données : $GUFO_DATA)"
  cmd_stop
  # down d'abord : un autre profil (autre modèle) tient peut-être le conteneur ;
  # puis le nom lui-même, au cas où un gufo aurait été lancé hors compose.
  _gufo_compose down --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$GUFO_CONTENEUR" >/dev/null 2>&1 || true
  _gufo_compose up -d || { _gufo_compose down >/dev/null 2>&1 || true; cmd_start; error "compose up de gufo en échec, service relancé"; }
  if ! _gufo_wait_ready; then
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
  _gufo_actif || error "gufo ne tourne pas - ./setup-llm.sh --gufo [${GUFO_MODELES[*]}]"
  docker logs -f "$GUFO_CONTENEUR" 2>&1 | grep --line-buffered "event=completed"
}

# cmd_gufo_download <image|flashnext|deepseek|27b-q4km|all> - image et GGUF de
# référence, dans GUFO_DATA/models.
cmd_gufo_download() {
  [[ -n "${1:-}" ]] || error "--gufo-download attend : image, flashnext, deepseek, 27b-q4km ou all"
  GUFO_DATA="$GUFO_DATA" GUFO_IMAGE="$GUFO_IMAGE" "$GUFO_DIR/download.sh" "$1"
}
