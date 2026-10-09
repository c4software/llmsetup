#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-llm.sh — un service LLM en conteneur, moteur au choix
#
# Le dépôt est découpé en RUNTIMES depuis le 09/10/2026 : un dossier
# runtime/<nom>/ par moteur, autonome, qui respecte runtime/CONTRAT.md.
#   - runtime/llama-cpp-rocm-strix/ : llama-server en router mode natif, image
#     ROCm construite localement (le moteur historique du dépôt, et le défaut) ;
#   - runtime/gufo/ : gufo derrière llama-swap.
# Un seul runtime tient le port à la fois (un GPU). Tout démarrage passe par
# docker compose : un compose versionné par runtime, un .env généré.
#   - ./setup-llm.sh --runtime          les runtimes, l'actif, celui qui tourne
#   - ./setup-llm.sh --runtime <nom>    bascule (arrête l'ancien, démarre le
#                                       nouveau, le mémorise dans runtime.conf)
#   - LLM_RUNTIME=<nom> ./setup-llm.sh <commande>   vise un runtime pour UNE
#                                       commande, sans rien mémoriser
# =============================================================================

# =============================================================================
# Point d'entrée — le corps du script vit dans lib/ (générique) et dans
# runtime/<nom>/ (un moteur), voir ARCHITECTURE.md.
#
# Ordre de source IMPOSÉ : common (helpers, MODELS_BASE, SERVER_PORT, registre
# des runtimes) → svc (pilotage générique du conteneur) → le runtime.sh de
# CHAQUE runtime, dans l'ordre alphabétique des dossiers (chacun se déclare et
# définit ses fonctions de contrat ; tous sont chargés, pour pouvoir arrêter
# celui qui tient le port et lister les commandes de chacun) → help.
# Les source restent au niveau du script, jamais dans une fonction : un
# `declare -A` d'un module sourcé depuis une fonction lui serait local.
# =============================================================================

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/svc.sh"
for _rt_fichier in "$RUNTIMES_DIR"/*/runtime.sh; do
  [[ -f "$_rt_fichier" ]] || continue
  RUNTIMES+=("$(basename "$(dirname "$_rt_fichier")")")
  source "$_rt_fichier"
done
unset _rt_fichier
source "$SCRIPT_DIR/lib/help.sh"

# Runtime visé par cette commande.
RT="$(_rt_actif)"
_rt_existe "$RT" \
  || error "Runtime inconnu : '$RT' (présents : ${RUNTIMES[*]:-aucun} ; choix dans $RUNTIME_CONF ou LLM_RUNTIME)"

# =============================================================================
# Entrypoint
# =============================================================================

case "${1:-}" in
  --runtime)           shift; cmd_runtime "$@" ;;
  --setup)             shift; _rt setup "$@" ;;
  --start)             shift; cmd_start "$@" ;;
  "")                  cmd_start ;;
  --stop)              cmd_stop ;;
  --restart)           shift; cmd_restart "$@" ;;
  --status)            cmd_status ;;
  --logs)              shift; cmd_logs "$@" ;;
  --en-marche)         cmd_en_marche ;;
  --help | -h)         cmd_help ;;
  *)
    # Sous-commande d'un runtime : celle du runtime visé s'exécute, celle d'un
    # autre se refuse en le nommant (un --bench du routeur llama-server n'a
    # aucun sens contre gufo).
    if [[ " ${RT_COMMANDES[$RT]:-} " == *" $1 "* ]]; then
      _rt commande "$@"
    elif _proprio="$(_rt_proprietaire "$1")"; then
      error "'$1' est une commande du runtime $_proprio, l'actif est $RT - LLM_RUNTIME=$_proprio ./setup-llm.sh $1 … (ou ./setup-llm.sh --runtime $_proprio)"
    else
      cmd_help >&2; error "Commande inconnue : '$1'"
    fi ;;
esac
