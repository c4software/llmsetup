# lib/runtime.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Moteur conteneurisé : image ROCm Strix Halo (runtime/)
#
# SEUL moteur du dépôt depuis le 18/09/2026 (le fork Vulkan de lib/fork.sh a été
# retiré ce jour-là). Il vient de la PR 133 de kyuz0/amd-strix-halo-toolboxes :
# ROCm 10.0 gfx1151 + un ROCr/HIP retained-PM4 compilé depuis
# pwilkin/rocm-systems, et halo-box/strix-llama.cpp construit en HIP seul.
# Provenance et écarts : runtime/AMONT.md.
#
# Tout tient en DEUX fichiers depuis le 18/09/2026 : runtime/Dockerfile.rocm-strix
# (qui porte les deux révisions épinglées, en ARG, avec leur mode d'emploi) et le
# compose généré par lib/compose.sh (qui porte le bloc build:). Il n'y a plus de
# image.conf, plus d'étiquettes llm-setup.*, plus de promotion sous tag
# temporaire, plus de purge par label, plus de journal images.tsv : changer de
# moteur, c'est éditer un ARG du Dockerfile et reconstruire.
#
# ⚠ Cette image EST le moteur du service : le compose généré la nomme par
# _image_ref, et _svc_restart la reprend. Une image neuve n'est donc servie
# qu'au prochain redémarrage - --image-build ne redémarre rien. Les outils HORS
# service (llama-bench des courbes de batch, llama-server jetable de
# tools/spec-isolate.sh) tournent dans la MÊME image, par _dk_run.
#
# L'image ne contient QUE le moteur et son runtime : pas de modèle, pas de
# configuration, pas de cache, pas d'état. Les poids arrivent par un montage en
# lecture seule (compose généré, ou _dk_run), le ini vit dans ~/models. Une
# image est donc jetable : UN SEUL tag, ${IMAGE_NAME}:latest, et ce qu'elle
# contient vraiment se lit dans /opt/strix/versions.txt dedans.
#
# ⚠ Comparabilité : une image = une série de mesures. Un chiffre ne se compare
# qu'à un autre pris sous les mêmes révisions ; d'où l'épinglage dans le
# Dockerfile, dont l'historique git est le journal des révisions.
# =============================================================================

RUNTIME_DIR="$SCRIPT_DIR/runtime"
IMAGE_DOCKERFILE="$RUNTIME_DIR/Dockerfile.rocm-strix"

# Nom et tag de l'image locale, écrits ici et nulle part ailleurs. Le tag est
# unique : pas de tag daté, pas de collection d'anciennes images en filet.
IMAGE_NAME="llm-rocm-strix"
IMAGE_TAG="latest"

# _image_tag - le tag de l'image courante. Constant ; la fonction reste pour que
# les appelants n'aient pas à connaître la valeur.
_image_tag() { echo "$IMAGE_TAG"; }

# _image_ref - nom:tag de l'image courante, ou rien (code 1) s'il n'y en a pas.
_image_ref() {
  local ref="${IMAGE_NAME}:$(_image_tag)"
  docker image inspect "$ref" >/dev/null 2>&1 || return 1
  printf '%s\n' "$ref"
}

# =============================================================================
# --image-build
# =============================================================================

# cmd_image_build [--no-cache] - RACCOURCI vers `docker compose build`.
#
# Le compose généré porte le contexte (runtime/) et le Dockerfile : construire
# passe donc par lui, exactement comme à la main (cd ~/models && docker compose
# build). Rien d'autre n'est fait ici : pas de tag temporaire, pas de promotion,
# pas de vérification d'après-coup, pas de purge, pas de journal. Ce que l'image
# contient se lit dans /opt/strix/versions.txt ; ce qui a été demandé se lit
# dans le git log du Dockerfile.
#
# Ne touche à aucun service : une image neuve n'est servie qu'au prochain
# --restart, et elle ouvre sa propre série de mesures.
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

  # Le compose est la description du build autant que celle du service : il est
  # régénéré d'abord. COMPOSE_SKIP_IMAGE_CHECK=1 parce qu'ici, justement,
  # l'image peut ne pas exister encore (premier build de la machine).
  COMPOSE_SKIP_IMAGE_CHECK=1 regen_compose \
    || error "docker-compose.yml non généré (voir ci-dessus), rien n'a été construit."

  info "Image  : ${IMAGE_NAME}:$(_image_tag)"
  info "Révisions : celles des ARG de $IMAGE_DOCKERFILE (git log -p dessus)."
  info "Construction (compter 40 à 60 minutes à froid : ROCr, HIP et le moteur sont compilés)."

  docker compose -f "$COMPOSE_FILE" build "${cache_opt[@]+"${cache_opt[@]}"}" \
    || error "docker compose build en échec, l'image précédente reste en place."

  info "${IMAGE_NAME}:$(_image_tag) construite."
  info "   L'image qu'elle remplace a perdu son tag : la retirer à la main par"
  info "   docker image prune (SANS -a, qui toucherait aux images des autres outils)."
  info "   Le service tourne encore sur l'ancienne : ./setup-llm.sh --restart"
  info "   l'applique, et ouvre une nouvelle série de mesures."
}

# =============================================================================
# Exécution dans l'image
# =============================================================================

# _dk_run <binaire> [args...] — lance un binaire de l'image courante.
#
# Protections validées en exécution réelle sur bigchuck le 17/09/2026 ; elles
# remplacent celles du lanceur amont (refresh-toolboxes.sh), qui donne le groupe
# sudo au conteneur. Point par point :
#   --device /dev/kfd --device /dev/dri : les deux seuls accès matériels dont le
#     backend HIP a besoin. Pas de --privileged, jamais, et pas de docker.sock.
#   --group-add <gid numériques> : les gid de render et video sont ceux de
#     L'HÔTE et n'ont aucune raison d'exister dans l'image Fedora (ils n'y
#     existent pas). Passer les noms échoue donc ; getent résout sur l'hôte.
#   seccomp=unconfined : exigé par ROCm (ioctl du KFD hors profil par défaut).
#     Compensé par no-new-privileges et cap-drop=ALL, qui ne coûtent rien ici.
#   --shm-size 8g, memlock illimité : llama.cpp mmap les poids et épingle des
#     buffers ; les défauts docker (64 Mio, memlock bas) font échouer le
#     chargement des gros GGUF.
#   ~/models monté au MÊME chemin absolu, en lecture seule : les chemins de
#     models.ini sont absolus et doivent rester valides des deux côtés, et rien
#     ici n'a de raison d'écrire dans les poids. C'est aussi ce qui permet à
#     l'image de ne contenir AUCUN modèle et de rester jetable.
#   --network none par défaut : une mesure n'a pas à sortir. Deux surcharges,
#     pour les outils qui doivent exposer un port (tools/spec-isolate.sh monte
#     un llama-server jetable sur 127.0.0.1:8099) :
#       DK_RUN_PUBLISH=127.0.0.1:8099:8099  publication de port ; elle impose
#         un réseau, le défaut passe donc à "bridge" dès qu'elle est posée.
#         TOUJOURS la borner à 127.0.0.1 : rien de ce dépôt n'a à écouter sur
#         le réseau.
#       DK_RUN_NAME=<nom>                   --name du conteneur, pour qu'un trap
#         puisse faire `docker rm -f <nom>` : un conteneur lancé en arrière-plan
#         survit au shell qui l'a lancé, et tuer le `docker run` ne suffit pas.
#     DK_RUN_NET reste pour forcer le réseau à la main (host, none, bridge).
#     Le service, lui, passe par le compose, jamais par ces variables.
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

  # Port publié et nom de conteneur : options optionnelles, jamais posées vides
  # (docker refuse un --name vide, et un -p vide n'a pas de sens).
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
