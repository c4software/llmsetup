# runtime/llama-cpp-rocm-strix/runtime.sh - sourcé par setup-llm.sh (ne pas
# exécuter directement). Point d'entrée du runtime (runtime/CONTRAT.md).

# =============================================================================
# llama-cpp-rocm-strix : llama-server en router mode natif, conteneurisé
#
# Backend : ROCm0, et lui seul.
#   - Le service tourne dans un CONTENEUR construit en HIP seul
#     (Dockerfile.rocm-strix, cf. lib/image.sh) : l'image n'expose que ROCm0.
#     Il n'y a plus de comparaison de devices, plus de bench-devices.conf et
#     plus de --bench-devices depuis le 18/09/2026.
#   - Les outils HORS service (llama-bench des courbes de batch, llama-server
#     jetable de tools/spec-isolate.sh) tournent dans la MÊME image, par
#     _dk_run. Le fork Vulkan et les backends ggml en paquets Arch ont été
#     retirés le 18/09/2026 : plus aucun binaire llama-* de l'hôte.
#   - ./setup-llm.sh --bench <modèle|all> : mesure le serveur tel qu'il
#     tourne via son API (prefill, décode médian, acceptance MTP). N'écrit
#     rien. ./setup-llm.sh --bench-sanity : le moteur répond-il JUSTE.
#
# Ordre de source IMPOSÉ (lib/common.sh et lib/svc.sh du dépôt sont déjà
# chargés) : common (variables globales du runtime, dont les chemins *_CONF et
# SERVICE_NAME) → models (déclaration des modèles : téléchargements, chemins,
# corps MODEL_INI) → ini (génération, référence les modèles) → compose (.env
# du service : a besoin de CONFIG_DIR et de load_preload_conf) → le reste
# (préload/setup/bench/spec référencent ini) → aide → contrat (branche le tout sur le
# pilotage générique). Toute variable globale doit être définie avant les
# fonctions qui l'utilisent.
# =============================================================================

source "$SCRIPT_DIR/runtime/llama-cpp-rocm-strix/lib/common.sh"
source "$LLAMA_DIR/lib/models.sh"
source "$LLAMA_DIR/lib/ini.sh"
source "$LLAMA_DIR/lib/compose.sh"
source "$LLAMA_DIR/lib/preload.sh"
source "$LLAMA_DIR/lib/setup.sh"
source "$LLAMA_DIR/lib/image.sh"
source "$LLAMA_DIR/lib/bench/bench.sh"
source "$LLAMA_DIR/lib/bench/bench-parallel.sh"
source "$LLAMA_DIR/lib/bench/bench-cache.sh"
source "$LLAMA_DIR/lib/bench/bench-load.sh"
source "$LLAMA_DIR/lib/bench/bench-agentic.sh"
source "$LLAMA_DIR/lib/bench/bench-prefill.sh"
source "$LLAMA_DIR/lib/spec.sh"
source "$LLAMA_DIR/lib/service.sh"
source "$LLAMA_DIR/lib/aide.sh"
source "$LLAMA_DIR/lib/contrat.sh"
