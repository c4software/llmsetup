#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-llm.sh — llama-server router mode natif
#
# Backends : Vulkan (défaut) + ROCm/HIP optionnel.
#   - Depuis le split Arch de mi-août 2026, extra/ggml n'embarque PLUS les
#     backends : ils sont en optdeps séparés (ggml-cpu, ggml-vulkan, ggml-hip,
#     ggml-cuda, ggml-blas, ggml-openvino) chargés dynamiquement s'ils sont
#     présents. Vulkan0 requiert ggml-vulkan, ROCm0 requiert ggml-hip + le
#     runtime ROCm — le runtime seul ne fait plus apparaître ROCm0.
#   - ./setup-llm.sh --bench <modèle|all> : mesure le serveur tel qu'il
#     tourne via son API (prefill, décode médian, acceptance MTP). N'écrit
#     rien. Le device par GGUF vit dans bench-devices.conf (à côté du
#     script) : rempli par --bench-devices (comparaison automatique
#     Vulkan/ROCm avec restarts) ou à la main, appliqué au prochain
#     --preload/--setup + restart. Sans conf, tout reste sur Vulkan0.
# =============================================================================

# =============================================================================
# Point d'entrée — le corps du script vit dans lib/ (voir ARCHITECTURE.md).
#
# Ordre de source IMPOSÉ : common (helpers + variables globales de config,
# dont les chemins *_CONF et SERVICE_NAME) → models (déclaration des modèles :
# téléchargements, chemins, corps MODEL_INI) → ini (génération, référence les
# modèles) → le reste (préload/setup/bench/spec référencent ini). Toute
# variable globale doit être définie avant les fonctions qui l'utilisent.
# =============================================================================

SCRIPT_DIR="$(dirname "$(realpath "$0")")"

source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/models.sh"
source "$SCRIPT_DIR/lib/ini.sh"
source "$SCRIPT_DIR/lib/preload.sh"
source "$SCRIPT_DIR/lib/setup.sh"
source "$SCRIPT_DIR/lib/bench.sh"
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
  --bench-devices)     cmd_bench_devices "${2:-}" "${3:-}" "${4:-}" ;;
  --bench-parallel)    cmd_bench_parallel "${2:-}" "${3:-}" "${4:-}" ;;
  --bench-cache)       cmd_bench_cache "${2:-}" ;;
  --bench-agentic)     cmd_bench_agentic "${2:-}" ;;
  --bench-sanity)      cmd_bench_sanity "${2:-}" ;;
  --bench-load)        cmd_bench_load "${2:-}" ;;
  --preload)           cmd_preload ;;
  --list-devices)      cmd_list_devices ;;
  --spec-test)         cmd_spec_test "${2:-}" "${3:-}" "${4:-}" ;;
  --spec-tune)         cmd_spec_tune "${2:-}" "${3:-}" "${4:-}" ;;
  --spec-ngram-tune)   cmd_spec_ngram_tune "${2:-}" "${3:-}" "${4:-}" ;;
  --spec-ab)           shift; cmd_spec_ab "$@" ;;
  --start | "")        cmd_start ;;
  --install-service)   cmd_install_service ;;
  --uninstall-service) cmd_uninstall_service ;;
  --help | -h)         cmd_help ;;
  *) cmd_help >&2; error "Commande inconnue : '$1'" ;;
esac
