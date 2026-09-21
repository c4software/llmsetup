#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# image/setup-image.sh — génération d'images en local, à côté du parc LLM
#
# Même approche que setup-llm.sh sur la branche du moteur conteneurisé,
# réduite à l'essentiel : des déclarations de fichiers HF en tête de script
# (source unique des téléchargements, de l'inventaire et des chemins servis),
# un compose VERSIONNÉ (image/docker-compose.yml) dont les valeurs machine vont
# dans un .env généré sous ~/models (ici ~/models/image/.env, à côté des
# poids, comme ~/models/.env pour le parc LLM), pas de systemd (le démon
# docker relance le conteneur, restart: unless-stopped), un pilotage
# --start/--stop/--restart/--status/--logs qui attend que le serveur réponde,
# et un --test de première mesure.
#
# Moteur : stable-diffusion.cpp (leejet), image officielle
# ghcr.io/leejet/stable-diffusion.cpp:master-vulkan. Choix fait le 21/09/2026
# (voir README, « Images ») :
#   - seule pile où Qwen-Image-2.1 est supporté officiellement (PR leejet
#     #1994 fusionnée le 20/09/2026, jour de la sortie du modèle), avec des
#     GGUF publiés par l'auteur du moteur lui-même ;
#   - backend Vulkan (RADV) : le seul connu stable sur gfx1151 sans runtime
#     recompilé ; le parc LLM tourne sur un ROCm retained-PM4 rebâti dans
#     runtime/, ce qui n'existe pas pour sd.cpp, et PyTorch/ROCm sur Strix Halo
#     reste hors matrice officielle AMD ;
#   - l'image embarque le pilote (mesa-vulkan-drivers d'Ubuntu 24.04) : rien
#     à installer sur l'hôte à part docker, le GPU se passe par /dev/dri.
#     Réserve : cette Mesa est plus ancienne que celle d'Arch (26.2 sur
#     bigchuck), si les chiffres déçoivent, un build natif Vulkan est le repli ;
#   - sd-server expose /v1/images/generations et /v1/images/edits
#     (compatibles OpenAI), une interface web sur /, une API native sous
#     /sdcpp/v1/. Port hôte 7979, à côté du routeur LLM en 8009.
#
# Un seul GPU : sd-server garde ses poids chargés (DiT 7,7 Go + encodeur
# 8,7 Go en Q8_0). La mémoire unifiée laisse la place au routeur LLM, mais deux
# charges lourdes en même temps se partagent le même silicium : --test refuse
# de tourner si le service d'images est déjà actif.
# =============================================================================

SCRIPT_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# -----------------------------------------------------------------------------
# Emplacements. Les poids vivent sous ~/models/image/<modèle>/ (un dossier par
# modèle, comme les GGUF du parc sous ~/models/<clé>/), le .env et les images
# produites dans ~/models/image/ aussi. Un seul sous-dossier de ~/models, pour
# que `setup-llm.sh --cleanup`, qui purge tout dossier de premier niveau
# inconnu de lib/models.sh, n'y touche pas : il l'exclut nommément
# (cmd_cleanup, lib/setup.sh).
# -----------------------------------------------------------------------------
MODELS_BASE="$HOME/models"
IMAGE_BASE="$MODELS_BASE/image"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"   # versionné
ENV_FILE="$IMAGE_BASE/.env"                      # généré, comme ~/models/.env
OUTPUT_DIR="$IMAGE_BASE/output"
LOG_DIR="$REPO_DIR/logs"
TEST_LOG="$LOG_DIR/image-test.log"

SD_IMAGE="ghcr.io/leejet/stable-diffusion.cpp:master-vulkan"
SERVER_PORT=7979
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"
SERVER_URL="http://localhost:$SERVER_PORT"
SERVICE_NAME="sd-server"      # = container_name du compose, via le .env

# REFRESH=1 (--update) : hf compare les etags au lieu de sauter les fichiers
# présents. ONLY : ne traite que le modèle dont le dossier porte ce nom.
REFRESH=0
ONLY=""

# =============================================================================
# Déclarations (source unique : téléchargements, inventaire, chemins servis)
# =============================================================================

KNOWN_FILES=()
DL_SPECS=()

# download_hf <dossier> <repo> VAR=<chemin dans le repo>...
#   Chemin absolu posé dans $VAR. `hf download` recrée sous --local-dir le
#   chemin relatif au repo (vae/x.safetensors reste en sous-dossier vae/),
#   même règle que le download_hf de lib/models.sh.
download_hf() {
  local dossier="$1" repo="$2"; shift 2
  local spec var entry cible
  for spec in "$@"; do
    var="${spec%%=*}"; entry="${spec#*=}"
    cible="$IMAGE_BASE/$dossier/$entry"
    printf -v "$var" '%s' "$cible"
    KNOWN_FILES+=("$cible")
    DL_SPECS+=("$cible"$'\t'"$repo"$'\t'"$entry")
  done
}

# --- Qwen-Image-2.1 ----------------------------------------------------------
# Modèle de génération et d'édition d'images d'Alibaba, sorti le 20/09/2026 :
# DiT single-stream 7 B (32 couches), encodeur texte Qwen3-VL-8B, VAE RGBA
# 64 canaux propre à cette version (celui de Qwen-Image 1.0 et de Wan 2.2 ne
# convient PAS). Un seul checkpoint remplace Qwen-Image, Qwen-Image-Edit et
# Qwen-Image-Layered : texte-vers-image, édition jusqu'à 10 images de
# référence, transparence native. Dimensions multiples de 32.
#
# LICENCE : Qwen Research License, usage NON COMMERCIAL seulement (les versions
# précédentes étaient Apache 2.0). Pour un usage commercial : Qwen-Image 2.0.
#
# Quant : Q8_0 du DiT (7,69 Go, leejet) et Q8_0 de l'encodeur (8,71 Go, Qwen
# officiel). La doc de sd.cpp montre Q4_K_M pour l'encodeur ; en mémoire
# unifiée la place ne manque pas et le Q8_0 évite de douter de la qualité
# avant d'avoir mesuré. Le Q8_0 du DiT est signalé comme cassé sur certains
# environnements ComfyUI (« shape mismatch », 20/09/2026) : si sd.cpp refuse
# de le charger, repli sur qwen_image_2.1-Q6_K.gguf (6,0 Go).
# Le mmproj (projecteur vision de l'encodeur) ne sert qu'à l'édition avec
# image de référence ; déclaré d'emblée pour que /v1/images/edits fonctionne
# sans second setup.
#
# Sampling (dans image/docker-compose.yml) : --cfg-scale 6.0 et
# --sampling-method euler, valeurs de la doc sd.cpp (docs/qwen_image_2.1.md) ;
# le schedule flow dépendant de la résolution est choisi automatiquement.
# Steps : défaut du moteur, à mesurer.
download_hf qwen-image-2.1 leejet/Qwen-Image-2.1-GGUF \
  QWEN_IMAGE_DIT_PATH=qwen_image_2.1-Q8_0.gguf
download_hf qwen-image-2.1 Comfy-Org/Qwen-Image-2.1 \
  QWEN_IMAGE_VAE_PATH=vae/qwen_image_2.1_vae_bf16.safetensors
download_hf qwen3-vl-8b Qwen/Qwen3-VL-8B-Instruct-GGUF \
  QWEN3_VL_PATH=Qwen3VL-8B-Instruct-Q8_0.gguf \
  QWEN3_VL_MMPROJ_PATH=mmproj-Qwen3VL-8B-Instruct-F16.gguf

# Arguments de modèle, pour sd-cli (--test) : les mêmes que ceux que le compose
# tire du .env pour sd-server. ~/models est monté au MÊME chemin absolu dans le
# conteneur, les chemins de l'hôte y valent tels quels.
SD_MODEL_ARGS=(
  --diffusion-model "$QWEN_IMAGE_DIT_PATH"
  --vae "$QWEN_IMAGE_VAE_PATH"
  --llm "$QWEN3_VL_PATH"
  --llm_vision "$QWEN3_VL_MMPROJ_PATH"
  --cfg-scale 6.0
  --sampling-method euler
  --diffusion-fa
)

# =============================================================================
# Helpers
# =============================================================================

_key() {
  local p="${1#"$IMAGE_BASE"/}"
  echo "${p%%/*}"
}

_skip() {
  [[ -n "$ONLY" && "$(_key "$1")" != "$ONLY" ]]
}

# _dl <cible absolue> <repo> <chemin dans le repo> — copie de lib/common.sh
_dl() {
  local target="$1" repo="$2" entry="$3"
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement $(basename "$target")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" "$entry" --local-dir "${target%/"$entry"}"
}

# Étiquette de moteur pour les journaux, pendant du _llama_build du parc LLM :
# commit court de stable-diffusion.cpp lu sur le label OCI de l'image, sinon
# sept caractères du digest, sinon « ? ». Le tag master-vulkan bouge à chaque
# commit amont : sans cette colonne, deux mesures ne se comparent pas.
_sd_build() {
  local rev digest
  rev="$(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$SD_IMAGE" 2>/dev/null || true)"
  if [[ -n "$rev" ]]; then echo "sdcpp-${rev:0:7}"; return 0; fi
  digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$SD_IMAGE" 2>/dev/null || true)"
  digest="${digest#*@sha256:}"
  if [[ -n "$digest" && "$digest" != *"$SD_IMAGE"* ]]; then echo "sdcpp-${digest:0:7}"; return 0; fi
  echo "?"
}

# Mode d'alimentation EC de la machine (cf. _ec_power_mode, lib/common.sh) :
# 10 à 13 % de décode d'écart côté LLM entre balanced et performance, la
# colonne sert à ne comparer que des runs de même mode. Jamais bloquant.
EC_POWER_MODE_FILE="${EC_POWER_MODE_FILE:-/sys/class/ec_su_axb35/apu/power_mode}"
_ec_power_mode() {
  local m=""
  [[ -r "$EC_POWER_MODE_FILE" ]] && m="$(tr -d '[:space:]' < "$EC_POWER_MODE_FILE" 2>/dev/null || true)"
  printf '%s\n' "${m:-inconnu}"
  return 0
}

# gid NUMÉRIQUE d'un groupe de l'hôte (même raison que _compose_gid,
# lib/compose.sh : le nom n'existe pas dans l'image). Message sur stderr, la
# fonction est appelée en substitution de commande.
_gid() {
  local g="$1" gid
  gid="$(getent group "$g" 2>/dev/null | cut -d: -f3)"
  if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
    warn "Groupe '$g' introuvable sur l'hôte (getent group $g) : le conteneur" >&2
    warn "  n'aurait aucun accès au GPU. .env non généré." >&2
    return 1
  fi
  printf '%s\n' "$gid"
}

# =============================================================================
# .env : les valeurs machine du compose (cf. lib/compose.sh)
# =============================================================================

_compose_check() {
  command -v docker >/dev/null 2>&1 || { warn "docker introuvable - le service tourne en conteneur." >&2; return 1; }
  [[ -f "$COMPOSE_FILE" ]] || { warn "$COMPOSE_FILE absent : le dépôt est incomplet." >&2; return 1; }
  if ! docker image inspect "$SD_IMAGE" >/dev/null 2>&1; then
    warn "Image $SD_IMAGE absente : ./image/setup-image.sh --setup la tire." >&2
    return 1
  fi
  local g
  for g in render video; do
    _gid "$g" >/dev/null || return 1
  done
  return 0
}

# generate_env — sur STDOUT, sans effet de bord (diffable, testable).
generate_env() {
  _compose_check || return 1
  cat <<ENV
# GÉNÉRÉ par ./image/setup-image.sh - NE PAS ÉDITER
# Valeurs machine de $COMPOSE_FILE ; réécrit à chaque --start.
# Usage manuel : cd $IMAGE_BASE && docker compose ps | logs -f
COMPOSE_FILE=$COMPOSE_FILE
SERVICE_NAME=$SERVICE_NAME
IMAGE_REF=$SD_IMAGE
SERVER_PORT=$SERVER_PORT
BIND_ADDR=$BIND_ADDR
MODELS_BASE=$MODELS_BASE
OUTPUT_DIR=$OUTPUT_DIR
RUN_UID=$(id -u)
RUN_GID=$(id -g)
GID_RENDER=$(_gid render)
GID_VIDEO=$(_gid video)
DIT_PATH=$QWEN_IMAGE_DIT_PATH
VAE_PATH=$QWEN_IMAGE_VAE_PATH
LLM_PATH=$QWEN3_VL_PATH
LLM_VISION_PATH=$QWEN3_VL_MMPROJ_PATH
ENV
}

# regen_env — écrit $ENV_FILE par un temporaire, remplace seulement si le
# contenu diffère (même règle que lib/compose.sh).
regen_env() {
  mkdir -p "$IMAGE_BASE" "$OUTPUT_DIR"
  local tmp
  tmp="$(mktemp)" || { warn ".env non régénéré (mktemp)."; return 1; }
  if ! generate_env > "$tmp"; then rm -f "$tmp"; return 1; fi
  if [[ -f "$ENV_FILE" ]] && cmp -s "$tmp" "$ENV_FILE"; then rm -f "$tmp"; return 0; fi
  mv -f "$tmp" "$ENV_FILE" || { rm -f "$tmp"; warn "Écriture de $ENV_FILE en échec."; return 1; }
  chmod 0644 "$ENV_FILE" 2>/dev/null || true
  info ".env régénéré : $ENV_FILE"
}

# =============================================================================
# Pilotage du conteneur (cf. lib/svc.sh : mêmes règles, un seul point d'appel)
# =============================================================================

_svc_compose() {
  [[ -f "$ENV_FILE" ]] || { warn "$ENV_FILE absent - --setup ou --start le génère."; return 1; }
  docker compose --project-directory "$IMAGE_BASE" -f "$COMPOSE_FILE" "$@"
}

_svc_is_active() {
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$SERVICE_NAME" 2>/dev/null || true)" == "true" ]]
}

# Attente de /v1/models, sortie anticipée si le conteneur meurt (poids
# absent, Q8_0 refusé, GPU non vu par RADV).
_svc_wait_ready() {
  local timeout="${1:-300}" t=0 annonce=0 etat code
  while :; do
    if curl -sf "$SERVER_URL/v1/models" >/dev/null 2>&1; then
      [[ "$annonce" -eq 1 ]] && info "  $SERVICE_NAME prêt après $t s."
      return 0
    fi
    etat="$(docker inspect -f '{{.State.Status}}' "$SERVICE_NAME" 2>/dev/null || true)"
    if [[ "$etat" == "exited" || "$etat" == "dead" ]]; then
      code="$(docker inspect -f '{{.State.ExitCode}}' "$SERVICE_NAME" 2>/dev/null || true)"
      warn "$SERVICE_NAME est sorti (code ${code:-?}) après $t s, sans répondre sur $SERVER_URL."
      warn "  Journaux : ./image/setup-image.sh --logs --tail 50"
      return 1
    fi
    if [[ "$annonce" -eq 0 ]]; then
      info "  attente de $SERVICE_NAME sur $SERVER_URL ($timeout s max, chargement des poids)..."
      annonce=1
    fi
    if [[ "$t" -ge "$timeout" ]]; then
      warn "$SERVICE_NAME ne répond toujours pas après $timeout s."
      warn "  Journaux : ./image/setup-image.sh --logs --tail 50"
      return 1
    fi
    sleep 2
    t=$(( t + 2 ))
  done
}

# JAMAIS `docker compose restart` : il garderait l'ancienne image et
# l'ancienne commande. Stop puis start, et le start régénère le .env.
_svc_start() {
  regen_env || return 1
  _svc_compose up -d --force-recreate --remove-orphans || return 1
  _svc_wait_ready
}

_svc_stop() {
  _svc_is_active || return 0
  if [[ -f "$ENV_FILE" ]]; then
    _svc_compose stop -t 30 || return 1
  else
    docker stop -t 30 "$SERVICE_NAME" >/dev/null || return 1
  fi
}

# =============================================================================
# Commandes
# =============================================================================

cmd_setup() {
  info "Vérification des dépendances..."
  command -v hf >/dev/null || error "hf introuvable (python-huggingface-hub, python-hf-xet)"
  command -v docker >/dev/null || error "docker introuvable (le service tourne en conteneur)"
  docker info >/dev/null 2>&1 || error "le démon docker ne répond pas (non démarré, ou $USER hors du groupe docker)"
  docker compose version >/dev/null 2>&1 || error "docker compose introuvable (paquet docker-compose)"
  if command -v systemctl >/dev/null 2>&1 && ! systemctl is-enabled docker >/dev/null 2>&1; then
    warn "Le démon docker n'est pas activé au boot : le service ne reviendra pas après"
    warn "  un redémarrage de la machine. sudo systemctl enable --now docker"
  fi
  [[ -e /dev/dri/renderD128 ]] || warn "/dev/dri/renderD128 absent : aucun GPU à passer au conteneur"

  local avant apres
  avant="$(_sd_build)"
  info "Image $SD_IMAGE (tag glissant : suit master amont)..."
  docker pull "$SD_IMAGE"
  apres="$(_sd_build)"
  if [[ "$avant" != "$apres" ]]; then
    info "  moteur : $avant → $apres (une image neuve n'est servie qu'au prochain --restart)"
  else
    info "  moteur : $apres, inchangé"
  fi

  info "Création des dossiers..."
  local f
  for f in "${KNOWN_FILES[@]}"; do
    mkdir -p "$(dirname "$f")"
  done
  mkdir -p "$OUTPUT_DIR"

  local spec cible repo entry
  for spec in "${DL_SPECS[@]}"; do
    IFS=$'\t' read -r cible repo entry <<< "$spec"
    _dl "$cible" "$repo" "$entry"
  done

  info "Génération du .env du service..."
  regen_env || warn ".env non généré (voir ci-dessus) - --start le retentera."

  info "Setup terminé."
  info "  Première image   → ./image/setup-image.sh --test   (service arrêté, chronométrée)"
  info "  Service          → ./image/setup-image.sh --start  (puis --status, --logs -f)"
  info "  API              → $SERVER_URL/v1/images/generations (web : $SERVER_URL/)"

  if _svc_is_active; then
    warn "$SERVICE_NAME tourne : image ou poids retéléchargés ne sont servis qu'après ./image/setup-image.sh --restart"
  fi
}

cmd_update() {
  REFRESH=1
  ONLY="${1:-}"
  cmd_setup
}

cmd_start() {
  local f
  for f in "${KNOWN_FILES[@]}"; do
    [[ -f "$f" ]] || error "Poids manquant : $f — lance --setup"
  done
  _compose_check || error "Le service ne peut pas démarrer ici (voir ci-dessus)."
  info "Démarrage de $SERVICE_NAME (moteur $(_sd_build)) sur $BIND_ADDR:$SERVER_PORT..."
  _svc_start || error "Démarrage de $SERVICE_NAME en échec - ./image/setup-image.sh --logs --tail 50"
  info "✅ $SERVICE_NAME répond sur $SERVER_URL (web comprise)."
}

cmd_stop() {
  if ! _svc_is_active; then
    info "$SERVICE_NAME n'est pas en marche, rien à arrêter."
    return 0
  fi
  _svc_stop || error "Arrêt de $SERVICE_NAME en échec"
  info "✅ $SERVICE_NAME arrêté."
}

cmd_restart() {
  _svc_stop || warn "Arrêt de $SERVICE_NAME en échec - démarrage tenté quand même."
  cmd_start
}

cmd_status() {
  if [[ -f "$ENV_FILE" ]]; then
    _svc_compose ps -a || true
  else
    warn "$ENV_FILE absent (service jamais démarré)."
  fi
  echo ""
  if _svc_is_active; then
    if curl -sf "$SERVER_URL/v1/models" >/dev/null 2>&1; then
      info "✅ $SERVICE_NAME en marche, moteur $(_sd_build), répond sur $SERVER_URL."
    else
      warn "$SERVICE_NAME en marche mais ne répond pas encore (chargement des poids ?)."
      warn "  Suivre : ./image/setup-image.sh --logs -f"
    fi
  else
    warn "$SERVICE_NAME n'est pas en marche - ./image/setup-image.sh --start"
  fi
  return 0
}

cmd_logs() {
  local -a args=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -f | --follow) args+=(--follow); shift ;;
      --tail)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || error "--logs --tail attend un nombre de lignes."
        args+=(--tail "$2"); shift 2 ;;
      "") shift ;;
      *) error "--logs : argument inconnu '$1' (attendu : -f, --tail N)." ;;
    esac
  done
  _svc_compose logs --no-color ${args[@]+"${args[@]}"}
}

# Première mesure : une image texte-vers-image par sd-cli dans la même image
# Docker, mêmes poids et même sampling que le service, temps mur chronométré,
# journal TSV dans logs/ avec le commit du moteur et le mode EC. Variables : W,
# H (défaut 1024, multiples de 32), STEPS (défaut du moteur si vide), SEED (42).
# C'est le pendant du --bench du parc LLM, réduit à ce qu'on sait mesurer
# avant d'avoir un service : la qualité se juge à l'œil sur le PNG produit.
cmd_test() {
  local prompt="${1:-A lovely cat holding a sign that says 'bigchuck', studio photo}"
  local w="${W:-1024}" h="${H:-1024}" steps="${STEPS:-}" seed="${SEED:-42}"
  if _svc_is_active; then
    error "$SERVICE_NAME tourne déjà : un seul GPU, arrêter le service avant --test (./image/setup-image.sh --stop)"
  fi
  (( w % 32 == 0 && h % 32 == 0 )) || error "W et H doivent être multiples de 32 (reçu ${w}x${h})"
  local f
  for f in "${KNOWN_FILES[@]}"; do
    [[ -f "$f" ]] || error "Poids manquant : $f — lance --setup"
  done
  regen_env || error "Le test ne peut pas tourner ici (voir ci-dessus)."

  mkdir -p "$LOG_DIR/image-test"
  local ts fichier journal build ec
  ts="$(date +%Y%m%d-%H%M%S)"
  fichier="test-$ts.png"
  journal="$LOG_DIR/image-test/$ts.log"
  build="$(_sd_build)"
  ec="$(_ec_power_mode)"

  local -a extra=()
  [[ -n "$steps" ]] && extra+=(--steps "$steps")
  info "Génération ${w}x${h}, seed $seed${steps:+, $steps steps}, moteur $build, mode EC $ec..."
  info "  prompt : $prompt"
  local t0 t1 rc=0
  t0="$(date +%s.%N)"
  # `run` ne publie pas de port et ne crée pas le service : un sd-cli jetable
  # avec les montages, l'uid et les groupes du compose.
  _svc_compose run --rm --no-deps --entrypoint /sd-cli sd \
    "${SD_MODEL_ARGS[@]}" ${extra[@]+"${extra[@]}"} \
    -p "$prompt" -W "$w" -H "$h" -s "$seed" -v -o "/output/$fichier" \
    2>&1 | tee "$journal" || rc=$?
  t1="$(date +%s.%N)"
  local mur
  mur="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"

  if [[ $rc -ne 0 || ! -s "$OUTPUT_DIR/$fichier" ]]; then
    warn "Génération en échec (rc=$rc) — journal : $journal"
    warn "  Pistes : GPU non vu par RADV dans le conteneur (grep -i vulkan $journal),"
    warn "  Q8_0 du DiT refusé (repli Q6_K, cf. commentaire du bloc), mémoire."
    return 1
  fi

  # Temps du moteur seul, tel que sd-cli le journalise (sampling), pour séparer
  # le chargement des poids du coût par image.
  local sampling
  sampling="$(grep -oE 'sampling completed, taking [0-9.]+s' "$journal" | tail -1 | grep -oE '[0-9.]+s' || true)"

  [[ -f "$TEST_LOG" ]] || printf 'date\tbuild\tdit\tencodeur\ttaille\tsteps\tseed\tmur_s\tsampling\tfichier\tec\n' > "$TEST_LOG"
  printf '%s\t%s\t%s\t%s\t%sx%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "$build" "$(basename "$QWEN_IMAGE_DIT_PATH")" "$(basename "$QWEN3_VL_PATH")" \
    "$w" "$h" "${steps:-défaut}" "$seed" "$mur" "${sampling:-n/a}" "$fichier" "$ec" >> "$TEST_LOG"

  info "✅ $OUTPUT_DIR/$fichier"
  info "  temps mur ${mur}s (chargement compris), sampling ${sampling:-n/a} — journal $journal, TSV $TEST_LOG"
  info "  Regarder l'image : le texte du panneau doit être lisible, pas de charabia ni d'aplat uniforme."
}

cmd_help() {
  cat <<HELP
setup-image.sh — génération d'images en local (stable-diffusion.cpp, Vulkan, conteneur)

Usage : ./image/setup-image.sh [commande]

Commandes :
  --setup                  Vérifie hf et docker, tire l'image $SD_IMAGE,
                           télécharge les poids manquants sous $IMAGE_BASE/<modèle>/,
                           génère $ENV_FILE (valeurs machine de image/docker-compose.yml)
  --update [modèle]        Comme --setup mais retire l'image amont et laisse hf comparer
                           les etags (modèle = dossier, ex. qwen-image-2.1)
  --test [prompt]          Une image texte-vers-image chronométrée par sd-cli, mêmes poids
                           et sampling que le service ; PNG dans $OUTPUT_DIR,
                           ligne TSV dans logs/image-test.log (commit du moteur, mode EC).
                           Variables : W, H (1024, multiples de 32), STEPS, SEED (42).
                           Refuse si $SERVICE_NAME tourne (un seul GPU)
  --start                  .env régénéré, conteneur recréé, attente de la réponse
  --stop | --restart       Arrêt propre ; restart = stop puis start (jamais compose restart)
  --status | --logs [-f] [--tail N]
  --help

Le service est un conteneur (restart: unless-stopped) : pas d'unité systemd, c'est le
démon docker qui le relance au boot. Usage manuel : cd $IMAGE_BASE && docker compose ps
API OpenAI-compatible : $SERVER_URL/v1/images/generations et /v1/images/edits, web sur /.
Licence Qwen-Image-2.1 : usage non commercial seulement.
HELP
}

case "${1:-}" in
  --setup)      cmd_setup ;;
  --update)     cmd_update "${2:-}" ;;
  --test)       cmd_test "${2:-}" ;;
  --start)      cmd_start ;;
  --stop)       cmd_stop ;;
  --restart)    cmd_restart ;;
  --status)     cmd_status ;;
  --logs)       shift; cmd_logs "$@" ;;
  --help|-h|"") cmd_help ;;
  *) cmd_help >&2; error "Commande inconnue : '$1'" ;;
esac
