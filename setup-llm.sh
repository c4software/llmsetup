#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-llm.sh — llama-server router mode natif
#
# Backend : ROCm0, et lui seul.
#   - Le service tourne dans un CONTENEUR construit en HIP seul (runtime/,
#     cf. lib/runtime.sh) : l'image n'expose que ROCm0. Il n'y a plus de
#     comparaison de devices, plus de bench-devices.conf et plus de
#     --bench-devices depuis le 18/09/2026.
#   - Les outils HORS service (llama-bench des courbes de batch, llama-server
#     jetable de tools/spec-isolate.sh) tournent dans la MÊME image, par
#     _dk_run. Le fork Vulkan et les backends ggml en paquets Arch ont été
#     retirés le 18/09/2026 : plus aucun binaire llama-* de l'hôte.
#   - ./setup-llm.sh --bench <modèle|all> : mesure le serveur tel qu'il
#     tourne via son API (prefill, décode médian, acceptance MTP). N'écrit
#     rien. ./setup-llm.sh --bench-sanity : le moteur répond-il JUSTE.
# =============================================================================

# =============================================================================
# Point d'entrée — le corps du script vit dans lib/ (voir ARCHITECTURE.md).
#
# Ordre de source IMPOSÉ : common (helpers + variables globales de config,
# dont les chemins *_CONF et SERVICE_NAME) → svc (pilotage du service, utilisé
# dès common par _maybe_restart_service) → models (déclaration des modèles :
# téléchargements, chemins, corps MODEL_INI) → ini (génération, référence les
# modèles) → compose (docker-compose.yml généré : a besoin de CONFIG_DIR et de
# load_preload_conf) → le reste (préload/setup/bench/spec référencent ini).
# Toute variable globale doit être définie avant les fonctions qui l'utilisent.
# =============================================================================

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/svc.sh"
source "$SCRIPT_DIR/lib/models.sh"
source "$SCRIPT_DIR/lib/ini.sh"
source "$SCRIPT_DIR/lib/compose.sh"
source "$SCRIPT_DIR/lib/preload.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$SCRIPT_DIR/lib/runtime.sh"
source "$SCRIPT_DIR/lib/bench/bench.sh"
source "$SCRIPT_DIR/lib/bench/bench-parallel.sh"
source "$SCRIPT_DIR/lib/bench/bench-cache.sh"
source "$SCRIPT_DIR/lib/bench/bench-load.sh"
source "$SCRIPT_DIR/lib/bench/bench-agentic.sh"
source "$SCRIPT_DIR/lib/spec.sh"
source "$SCRIPT_DIR/lib/service.sh"
source "$SCRIPT_DIR/lib/help.sh"

# =============================================================================
# Entrypoint
# =============================================================================

case "${1:-}" in
  --setup)             cmd_setup ;;
  --update)            cmd_update "${2:-}" ;;
  --cleanup)           cmd_cleanup "${2:-}" ;;
  --bench)             cmd_bench "${2:-}" "${3:-}" ;;
  --bench-parallel)    cmd_bench_parallel "${2:-}" "${3:-}" "${4:-}" ;;
  --bench-cache)       cmd_bench_cache "${2:-}" ;;
  --bench-agentic)     cmd_bench_agentic "${2:-}" "${3:-}" "${4:-}" ;;
  --bench-sanity)      cmd_bench_sanity "${2:-}" ;;
  --bench-load)        cmd_bench_load "${2:-}" ;;
  --preload)           cmd_preload ;;
  --image-build)       cmd_image_build "${2:-}" ;;
  --image-update)      cmd_image_update "${2:-}" "${3:-}" ;;
  --image-status)      cmd_image_status ;;
  --list-devices)      cmd_list_devices ;;
  --spec-test)         cmd_spec_test "${2:-}" "${3:-}" "${4:-}" ;;
  --spec-tune)         cmd_spec_tune "${2:-}" "${3:-}" "${4:-}" ;;
  --spec-ngram-tune)   cmd_spec_ngram_tune "${2:-}" "${3:-}" "${4:-}" ;;
  --spec-ab)           shift; cmd_spec_ab "$@" ;;
  --start | "")        cmd_start ;;
  --stop)              cmd_stop ;;
  --restart)           cmd_restart ;;
  --status)            cmd_status ;;
  --logs)              shift; cmd_logs "$@" ;;
  --migrate-off-systemd) cmd_migrate_off_systemd ;;
  --help | -h)         cmd_help ;;
  *) cmd_help >&2; error "Commande inconnue : '$1'" ;;
esac
