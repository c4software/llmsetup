# lib/contrat.sh - sourcé par runtime.sh (ne pas exécuter directement)
# Ordre de source du runtime : common → models → ini → compose → preload → setup → image → bench → bench-parallel → bench-cache → bench-load → bench-agentic → bench-prefill → spec → service → aide → contrat

# =============================================================================
# Le runtime llama-cpp-rocm-strix vu par le pilotage générique
# (runtime/CONTRAT.md)
#
# Ce module ne contient AUCUNE logique : il déclare le runtime et branche les
# fonctions du contrat sur celles qui existaient avant le découpage du
# 09/10/2026 (generate_env, _compose_check, cmd_setup, _llama_build…), dont
# aucune n'a été renommée. Il est séparé de runtime.sh pour que les tests et
# les outils hors service puissent le sourcer sans charger la déclaration des
# modèles (lib/models.sh).
# =============================================================================

# SERVICE_NAME (lib/common.sh du runtime) est à la fois le nom du service et
# celui du conteneur ; ENV_FILE (lib/compose.sh) est ~/models/.env, à côté de
# models.ini.
RT_CONTENEUR[llama-cpp-rocm-strix]="$SERVICE_NAME"
RT_ENV_FILE[llama-cpp-rocm-strix]="$ENV_FILE"
RT_DESCRIPTION[llama-cpp-rocm-strix]="llama-server en router mode, image ROCm construite localement (HIP seul, device ROCm0)"
# Plafond d'attente de /health : un parc préchargé de plusieurs dizaines de Go
# met des minutes à revenir.
RT_DELAI_DEMARRAGE[llama-cpp-rocm-strix]=300
# Arrêt : SIGINT (stop_signal du compose) puis jusqu'à 180 s, le déchargement
# des modèles préchargés prend du temps.
RT_DELAI_ARRET[llama-cpp-rocm-strix]=180
# Sous-commandes propres au runtime : tout ce que le point d'entrée portait
# avant le découpage, hors cycle de vie.
RT_COMMANDES[llama-cpp-rocm-strix]="--update --cleanup --preload --image-build --list-devices --bench --bench-parallel --bench-cache --bench-agentic --bench-sanity --bench-load --bench-prefill --spec-test --spec-tune --spec-ngram-tune --spec-ab --migrate-off-systemd"

# check - prérequis du service : docker, compose du dépôt, image locale,
# models.ini, gid de render et video. Explique sur stderr, sans effet de bord.
rt_llama_cpp_rocm_strix_check() {
  _compose_check
}

# env - le .env de docker-compose.yml, sur stdout (vérifie lui-même les
# prérequis et échoue sans rien écrire s'ils manquent).
rt_llama_cpp_rocm_strix_env() {
  generate_env
}

# avant_demarrage - dossier du cache, ménage de l'ancien compose généré, et
# l'annonce de ce qui va être servi.
rt_llama_cpp_rocm_strix_avant_demarrage() {
  _llama_preparer
  load_preload_conf
  local models_max=$(( ${#PRELOADED[@]} + 1 ))   # même dérivation que generate_env, sans plancher
  info "  router mode sur $BIND_ADDR:$SERVER_PORT, préchargés : $(_preload_summary) - models-max=$models_max"
}

# setup - dépendances, téléchargements des GGUF, préchargement, models.ini.
rt_llama_cpp_rocm_strix_setup() {
  cmd_setup
}

# etiquette - version du moteur servi, pour les journaux de mesure.
rt_llama_cpp_rocm_strix_etiquette() {
  _llama_build
}

# etat - rien de plus que /health : la WebUI est servie sur le même port.
rt_llama_cpp_rocm_strix_etat() {
  info "  WebUI comprise. Modèles et arguments réels : curl -s $SPEC_TEST_URL/v1/models"
}

# commande <sous-commande> [args...] - les sous-commandes de RT_COMMANDES,
# avec le passage d'arguments qu'avait le `case` de setup-llm.sh.
rt_llama_cpp_rocm_strix_commande() {
  case "${1:-}" in
    --update)            cmd_update "${2:-}" ;;
    --cleanup)           cmd_cleanup "${2:-}" ;;
    --bench)             cmd_bench "${2:-}" "${3:-}" ;;
    --bench-parallel)    cmd_bench_parallel "${2:-}" "${3:-}" "${4:-}" ;;
    --bench-cache)       cmd_bench_cache "${2:-}" ;;
    --bench-agentic)     cmd_bench_agentic "${2:-}" "${3:-}" "${4:-}" ;;
    --bench-sanity)      cmd_bench_sanity "${2:-}" ;;
    --bench-load)        cmd_bench_load "${2:-}" ;;
    --bench-prefill)     cmd_bench_prefill "${2:-}" "${3:-}" "${4:-}" ;;
    --preload)           cmd_preload ;;
    --image-build)       cmd_image_build "${2:-}" ;;
    --list-devices)      cmd_list_devices ;;
    --spec-test)         cmd_spec_test "${2:-}" "${3:-}" "${4:-}" ;;
    --spec-tune)         cmd_spec_tune "${2:-}" "${3:-}" "${4:-}" ;;
    --spec-ngram-tune)   cmd_spec_ngram_tune "${2:-}" "${3:-}" "${4:-}" ;;
    --spec-ab)           shift; cmd_spec_ab "$@" ;;
    --migrate-off-systemd) cmd_migrate_off_systemd ;;
    *) error "Sous-commande inconnue du runtime llama-cpp-rocm-strix : '${1:-}'" ;;
  esac
}
