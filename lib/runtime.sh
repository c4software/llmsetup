# lib/runtime.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Moteur conteneurisé : image ROCm Strix Halo (runtime/)
#
# Seul moteur du dépôt depuis le 18/09/2026. Source : PR 133 de
# kyuz0/amd-strix-halo-toolboxes (ROCm 10.0 gfx1151, ROCr/HIP retained-PM4,
# halo-box/strix-llama.cpp en HIP seul). Provenance et écarts : runtime/AMONT.md.
#
# Deux fichiers : runtime/Dockerfile.rocm-strix (révisions épinglées en ARG) et
# runtime/docker-compose.yml (bloc build, valeurs machine dans ~/models/.env).
# Changer de moteur = éditer un ARG, reconstruire, --restart.
#
# L'image ne contient que le moteur : pas de modèle, pas de config, pas d'état.
# Un seul tag, ${IMAGE_NAME}:latest ; le contenu réel se lit dans
# /opt/strix/versions.txt. Une image = une série de mesures (comparabilité).
# =============================================================================

RUNTIME_DIR="$SCRIPT_DIR/runtime"
IMAGE_DOCKERFILE="$RUNTIME_DIR/Dockerfile.rocm-strix"

IMAGE_NAME="llm-rocm-strix"
IMAGE_TAG="latest"

_image_tag() { echo "$IMAGE_TAG"; }

# _image_ref - nom:tag de l'image locale, ou rien (code 1) si elle n'existe pas.
_image_ref() {
  local ref="${IMAGE_NAME}:$(_image_tag)"
  docker image inspect "$ref" >/dev/null 2>&1 || return 1
  printf '%s\n' "$ref"
}

# =============================================================================
# --image-build
# =============================================================================

# cmd_image_build [--no-cache] - raccourci vers `docker compose build`.
# Ne redémarre rien : l'image neuve n'est servie qu'au prochain --restart.
cmd_image_build() {
  local arg="${1:-}"
  local -a cache_opt=()
  case "$arg" in
    "")          ;;
    --no-cache)  cache_opt=(--no-cache) ;;
    *)           error "--image-build : argument inconnu '$arg' (attendu : --no-cache)." ;;
  esac

  command -v docker >/dev/null 2>&1 || error "docker introuvable : l'image ne peut pas être construite ici."
  [[ -f "$IMAGE_DOCKERFILE" ]] || error "$IMAGE_DOCKERFILE absent : le dépôt est incomplet."

  # COMPOSE_SKIP_IMAGE_CHECK=1 : au premier build de la machine, l'image
  # n'existe pas encore.
  COMPOSE_SKIP_IMAGE_CHECK=1 regen_env \
    || error ".env non généré (voir ci-dessus), rien n'a été construit."

  info "Image  : ${IMAGE_NAME}:$(_image_tag)"
  info "Révisions : celles des ARG de $IMAGE_DOCKERFILE (git log -p dessus)."
  info "Construction (compter 40 à 60 minutes à froid : ROCr, HIP et le moteur sont compilés)."

  _svc_compose build "${cache_opt[@]+"${cache_opt[@]}"}" \
    || error "docker compose build en échec, l'image précédente reste en place."

  info "${IMAGE_NAME}:$(_image_tag) construite."
  info "   L'ancienne image a perdu son tag : docker image prune (SANS -a) la retire."
  info "   Le service tourne encore sur l'ancienne : ./setup-llm.sh --restart l'applique."
}

# =============================================================================
# Exécution dans l'image
# =============================================================================

# _dk_run <binaire> [args...] — lance un binaire de l'image (outils hors
# service : llama-bench, llama-server jetable de tools/spec-isolate.sh).
#
# Mêmes réglages que le compose du service, validés le 17/09/2026 :
#   /dev/kfd + /dev/dri            seuls accès matériels du backend HIP
#   --group-add <gid numériques>   render et video n'existent pas dans l'image
#   seccomp=unconfined             exigé par ROCr ; compensé par
#                                  no-new-privileges et cap-drop=ALL
#   --shm-size 8g, memlock -1      mmap et buffers épinglés des gros GGUF
#   ~/models au même chemin, :ro   models.ini porte des chemins absolus
#   --network none                 une mesure n'a pas à sortir
# Jamais --privileged, jamais docker.sock.
#
# Surcharges :
#   DK_RUN_PUBLISH=127.0.0.1:P:P   publie un port (réseau bridge par défaut).
#                                  Toujours borné à 127.0.0.1.
#   DK_RUN_NAME=<nom>              --name, pour qu'un trap puisse docker rm -f.
#   DK_RUN_NET=<host|none|bridge>  force le réseau.
_dk_run() {
  local bin="${1:-}"
  [[ -n "$bin" ]] || error "_dk_run : binaire manquant."
  shift

  command -v docker >/dev/null 2>&1 || error "docker introuvable."
  local ref
  ref="$(_image_ref)" || error "Aucune image ${IMAGE_NAME}:$(_image_tag) ici — ./setup-llm.sh --image-build d'abord."

  local -a gids=()
  local g gid
  for g in render video; do
    gid="$(getent group "$g" 2>/dev/null | cut -d: -f3)"
    if [[ "$gid" =~ ^[0-9]+$ ]]; then
      gids+=(--group-add "$gid")
    else
      warn "Groupe $g introuvable sur l'hôte — accès GPU probablement refusé dans le conteneur."
    fi
  done

  local -a extra=()
  local net_defaut="none"
  if [[ -n "${DK_RUN_PUBLISH:-}" ]]; then
    extra+=(-p "$DK_RUN_PUBLISH")
    net_defaut="bridge"
  fi
  [[ -n "${DK_RUN_NAME:-}" ]] && extra+=(--name "$DK_RUN_NAME")

  docker run --rm \
    --device /dev/kfd --device /dev/dri \
    ${gids[@]+"${gids[@]}"} \
    --security-opt seccomp=unconfined \
    --security-opt no-new-privileges \
    --cap-drop=ALL \
    --shm-size 8g \
    --ulimit memlock=-1:-1 \
    -v "$MODELS_BASE:$MODELS_BASE:ro" \
    --network "${DK_RUN_NET:-$net_defaut}" \
    ${extra[@]+"${extra[@]}"} \
    --entrypoint "$bin" \
    "$ref" "$@"
}
