# runtime/gufo/runtime.sh - sourcé par setup-llm.sh (ne pas exécuter
# directement). Point d'entrée du runtime (runtime/CONTRAT.md).

# =============================================================================
# gufo : moteur HIP spécialisé Strix Halo, derrière llama-swap
#
# gufo (docs/GUFO.md) ne sert qu'un modèle par processus et n'accepte que ses
# propres GGUF : il ne s'intègre pas au routeur llama-server, c'est un runtime
# à part. Compose versionné (docker-compose.yml) et .env généré ici, dans
# GUFO_DATA, avec les seules valeurs machine. gufo démarre toujours derrière
# llama-swap (gufo-llama-swap.yaml, seule description des lignes de
# commande) : le client choisit le modèle par le champ « model », llama-swap
# arrête un processus gufo pour lancer l'autre ; --start [modèle] ne choisit
# que le modèle préchargé.
#
# Jusqu'au 09/10/2026 ce module était lib/gufo.sh, un « moteur alternatif »
# branché à côté du service : commandes --gufo, --gufo-off, --gufo-logs,
# --gufo-download, garde d'exclusivité écrite à la main (_gufo_refuse dans
# lib/svc.sh). Depuis le découpage en runtimes il n'a plus de pilotage à lui :
# le générique (lib/svc.sh) régénère le .env, arrête le runtime qui tenait le
# port, recrée le conteneur et attend /health ; il ne reste ici que ce que
# gufo a de propre. Correspondance :
#   --gufo [modèle]        LLM_RUNTIME=gufo ./setup-llm.sh --start [modèle],
#                          ou --runtime gufo pour y basculer durablement
#   --gufo-off             --runtime llama-cpp-rocm-strix (ou --stop)
#   --gufo-logs            --requetes
#   --gufo-download <quoi> --setup <quoi>
#
# Variables (environnement), pour les bancs de bench/ surtout :
#   GUFO_DATA      données hors dépôt et hors ~/models : resultats/, essais/,
#                  .env (défaut ~/llm/gufo-test). Les poids propres à gufo
#                  n'y sont plus depuis le 09/10/2026 : ils vivent avec le
#                  parc, dans $MODELS_BASE/gufo (un seul dossier de modèles à
#                  copier d'une machine à l'autre), que le --cleanup du
#                  runtime llama-cpp-rocm-strix épargne
#   GUFO_CACHE     cache disque de gufo, 16 Gio au plus (défaut
#                  ~/.local/state/llm-setup/gufo-cache, à côté du cache du
#                  runtime llama-cpp-rocm-strix ; dans GUFO_DATA/cache avant
#                  le 09/10/2026). Partagé par l'usage réel et les bancs,
#                  comme avant
#   GUFO_IMAGE     image (défaut : la ligne de IMAGE, SEUL endroit
#                  où la version est épinglée ; download.sh, bench/remesure.sh
#                  et tools/gufo-amont.sh lisent le même fichier, et
#                  Dockerfile.routeur la reçoit du .env. Épinglée : gufo publie
#                  des versions depuis le 28/09/2026 et une image est une série
#                  de mesures, docs/GUFO.md)
#   GUFO_SESSIONS  sessions (défaut 2)
#   GUFO_PORT      port hôte (défaut SERVER_PORT ; le pilotage attend /health
#                  sur SERVER_PORT, le changer ne sert qu'à lire un .env)
#   GUFO_RESTART   politique de redémarrage (défaut unless-stopped)
#   GUFO_PROJET    projet compose (défaut gufo)
#   GUFO_CONTENEUR conteneur (défaut gufo-8009 ; gufo-banc pour les bancs)
#   GUFO_PRECHARGE modèle préchargé (--start <modèle> prime ; à défaut des
#                  deux, celui du .env en place, sinon qwen3.8-flash-next)
#   GUFO_ENV_FILE  .env écrit (défaut GUFO_DATA/.env)
# =============================================================================

GUFO_DIR="$SCRIPT_DIR/runtime/gufo"
GUFO_CONTENEUR="${GUFO_CONTENEUR:-gufo-8009}"
GUFO_COMPOSE_FILE="$GUFO_DIR/docker-compose.yml"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
GUFO_CACHE="${GUFO_CACHE:-$HOME/.local/state/llm-setup/gufo-cache}"
GUFO_IMAGE="${GUFO_IMAGE:-$(<"$GUFO_DIR/IMAGE")}"
GUFO_PROJET="${GUFO_PROJET:-gufo}"
GUFO_ENV_FILE="${GUFO_ENV_FILE:-$GUFO_DATA/.env}"
# Noms courts acceptés par --start, et le modèle de gufo-llama-swap.yaml qu'ils
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

# _gufo_precharge [modèle] - le modèle à précharger, en nom de
# gufo-llama-swap.yaml : l'argument de --start, sinon GUFO_PRECHARGE, sinon
# celui du .env en place (un --restart ou une bascule reprennent le modèle qui
# servait, au lieu de retomber sur le défaut), sinon qwen3.8-flash-next.
# Échec si le nom est inconnu.
_gufo_precharge() {
  local m="${1:-${GUFO_PRECHARGE:-}}"
  if [[ -z "$m" && -f "$GUFO_ENV_FILE" ]]; then
    m="$(sed -n 's/^GUFO_PRECHARGE=//p' "$GUFO_ENV_FILE")"
  fi
  _gufo_nom "${m:-qwen3.8-flash-next}"
}

# generate_gufo_env [modèle préchargé] - le .env de docker-compose.yml, sur
# stdout. Échoue (sans rien écrire) si le modèle est inconnu ou si un groupe
# GPU manque.
generate_gufo_env() {
  local precharge gid_render gid_video
  precharge="$(_gufo_precharge "${1:-}")" \
    || { warn "Modèle gufo inconnu : '${1:-${GUFO_PRECHARGE:-}}' (${!GUFO_MODELES[*]}, ou ${GUFO_MODELES[*]})" >&2; return 1; }
  gid_render="$(_compose_gid render)" || return 1
  gid_video="$(_compose_gid video)" || return 1
  cat <<ENV
# GÉNÉRÉ par ./setup-llm.sh --start (runtime/gufo/runtime.sh) - NE PAS ÉDITER
# Valeurs machine de $GUFO_COMPOSE_FILE ; réécrit à chaque --start.
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
GUFO_CACHE=$GUFO_CACHE
ENV
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

# =============================================================================
# Contrat (runtime/CONTRAT.md)
# =============================================================================

RT_CONTENEUR[gufo]="$GUFO_CONTENEUR"
RT_ENV_FILE[gufo]="$GUFO_ENV_FILE"
RT_DESCRIPTION[gufo]="gufo derrière llama-swap : Qwen3.8-27B, Flash-Next, DeepSeek V4 Flash, voix, transcription, image"
# Flash-Next ou DeepSeek à froid : ~80 s, plus la construction de l'image du
# routeur au premier passage ; marge pour un disque chargé.
RT_DELAI_DEMARRAGE[gufo]=600
RT_COMMANDES[gufo]="--requetes"
# $MODELS_BASE/gufo : les poids propres à gufo (download.sh), que le --cleanup
# du runtime llama-cpp-rocm-strix verrait sinon comme orphelins (plus de 250 Go).
RT_PARC_RESERVE[gufo]="gufo"

# check - docker, compose du dépôt, image de gufo présente (compose
# construirait sinon l'image du routeur sur une base qu'il irait tirer seul),
# gid de render et video.
rt_gufo_check() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker introuvable - gufo tourne en conteneur, il ne peut pas démarrer ici." >&2
    return 1
  fi
  [[ -f "$GUFO_COMPOSE_FILE" ]] \
    || { warn "$GUFO_COMPOSE_FILE absent : le dépôt est incomplet." >&2; return 1; }
  if ! docker image inspect "$GUFO_IMAGE" >/dev/null 2>&1; then
    warn "Image $GUFO_IMAGE absente - LLM_RUNTIME=gufo ./setup-llm.sh --setup image" >&2
    return 1
  fi
  local g
  for g in render video; do
    _compose_gid "$g" >/dev/null || return 1
  done
  return 0
}

# env [modèle préchargé] - le .env, sur stdout.
rt_gufo_env() {
  generate_gufo_env "${1:-}"
}

# avant_demarrage - dossiers de l'hôte que le compose monte : sans eux docker
# les créerait en root.
rt_gufo_avant_demarrage() {
  mkdir -p "$GUFO_DATA" "$GUFO_CACHE"
}

# pret - /health de llama-swap a répondu (pilotage générique) ; reste le
# modèle préchargé, lu dans le .env qui vient d'être écrit.
rt_gufo_pret() {
  local m
  m="$(sed -n 's/^GUFO_PRECHARGE=//p' "$GUFO_ENV_FILE")"
  _gufo_wait_precharge "$m"
}

# setup <image|27b|flashnext|deepseek|tts|asr|qwen-image|qwen-image-heretic|all>
# - image et poids de référence (download.sh), dans $MODELS_BASE.
rt_gufo_setup() {
  [[ -n "${1:-}" ]] || error "--setup (runtime gufo) attend : image, 27b, flashnext, deepseek, tts, asr, qwen-image, qwen-image-heretic ou all"
  MODELS_BASE="$MODELS_BASE" GUFO_IMAGE="$GUFO_IMAGE" "$GUFO_DIR/download.sh" "$1"
}

# etiquette - version de gufo servie : le tag de l'image épinglée.
rt_gufo_etiquette() {
  printf 'gufo-%s\n' "${GUFO_IMAGE##*:}"
}

# etat - les modèles que llama-swap expose.
rt_gufo_etat() {
  info "  $(curl -s "$SVC_URL/v1/models" 2>/dev/null | head -c 200)"
}

# commande <sous-commande> - --requetes : les requêtes de gufo au fil de l'eau
# (une ligne event=completed par requête ; l'ancien --gufo-logs).
rt_gufo_commande() {
  case "${1:-}" in
    --requetes)
      _svc_is_active || error "gufo ne tourne pas - ./setup-llm.sh --start [${!GUFO_MODELES[*]}]"
      docker logs -f "$GUFO_CONTENEUR" 2>&1 | grep --line-buffered "event=completed" ;;
    *) error "Sous-commande inconnue du runtime gufo : '${1:-}'" ;;
  esac
}

# aide - sous-commandes, fichiers et workflow du runtime.
rt_gufo_aide() {
  cat <<HELP
Runtime gufo : gufo derrière llama-swap (docs/GUFO.md, runtime/gufo/README.md)

Commandes du runtime :
  --setup <quoi>           Image et poids de gufo (runtime/gufo/download.sh) :
                           image, 27b, flashnext, deepseek, tts, asr,
                           qwen-image, qwen-image-heretic ou all
  --start [modèle]         (commande commune) [modèle] = préchargé : flashnext,
                           27b, deepseek ; sans argument, celui du .env en
                           place, sinon flashnext. Le client choisit ensuite
                           qwen3.8-27b, qwen3.8-flash-next, deepseek-v4-flash
                           ou Qwen-Image-2.1-heretic par le champ « model » (un
                           seul chargé à la fois, bascule automatique), plus la
                           synthèse vocale Qwen3-TTS (trois variantes) et la
                           transcription Qwen3-ASR, chargées à côté.
                           2 sessions (GUFO_SESSIONS)
  --restart [modèle]       (commande commune) garde le modèle préchargé du .env
  --requetes               Requêtes de gufo au fil de l'eau, une ligne par
                           requête

Fichiers versionnés (runtime/gufo/) :
  IMAGE                    l'image de gufo épinglée, une ligne : SEUL endroit
                           où la version est écrite
  gufo-llama-swap.yaml     SEULE description des lignes de commande de gufo,
                           modèle par modèle ; lu au démarrage
  docker-compose.yml       le conteneur, sans valeur machine
  Dockerfile.routeur       image de gufo + llama-swap épinglé par SHA-256
Fichiers générés (GUFO_DATA, défaut ~/llm/gufo-test - ne pas éditer) :
  .env                     valeurs machine ; régénéré à chaque --start ; usage
                           manuel : cd ~/llm/gufo-test && docker compose ps
  banc.env, resultats/     le .env et les sorties des bancs

Mesures (hors point d'entrée) :
  runtime/gufo/bench/run.sh gufo <cas>...      banc HTTP
  runtime/gufo/bench/agentic.sh gufo <cas>...  boucle agentique pi
  runtime/gufo/bench/remesure.sh               les deux, après une montée de version
  runtime/gufo/tools/gufo-amont.sh             releases, images et tickets amont
HELP
}
