# lib/help.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → runtime/*/runtime.sh → help

# =============================================================================
# help : les commandes communes à tous les runtimes, puis l'aide du runtime
# actif (fonction de contrat aide). L'aide d'un autre runtime :
# LLM_RUNTIME=<nom> ./setup-llm.sh --help
# =============================================================================

cmd_help() {
  local n
  cat <<HELP
setup-llm.sh : un service LLM en conteneur sur :$SERVER_PORT, moteur au choix (Strix Halo)

Usage : ./setup-llm.sh [commande] [options]

Runtimes (runtime/<nom>/, contrat : runtime/CONTRAT.md) :
$(for n in ${RUNTIMES[@]+"${RUNTIMES[@]}"}; do
    if [[ "$n" == "$RT" ]]; then printf '  * %-22s %s\n' "$n" "${RT_DESCRIPTION[$n]:-}"
    else printf '    %-22s %s\n' "$n" "${RT_DESCRIPTION[$n]:-}"; fi
  done)
  (* = runtime actif : LLM_RUNTIME, sinon runtime.conf, sinon $RUNTIME_DEFAUT)

Commandes communes (elles visent le runtime actif) :
  --runtime                Les runtimes présents, l'actif et celui qui tourne
  --runtime <nom> [args]   BASCULE : <nom> devient le runtime actif (mémorisé
                           dans runtime.conf) et démarre, ce qui arrête celui
                           qui tenait le port. Ses prérequis sont vérifiés
                           avant de toucher à quoi que ce soit ; si le
                           démarrage échoue, l'ancien runtime est remis
  --setup [args]           Installe le runtime actif (dépendances,
                           téléchargements ; arguments propres au runtime).
                           Un autre que l'actif, sans basculer :
                           LLM_RUNTIME=<nom> ./setup-llm.sh --setup …
  --start [args]           Démarre le runtime actif (défaut sans argument) :
                           son .env régénéré, tout autre runtime arrêté,
                           conteneur recréé (docker compose up -d
                           --force-recreate), puis ATTENTE de /health - la
                           commande ne rend la main que quand le service
                           répond sur :$SERVER_PORT
  --stop                   Arrête le conteneur du runtime actif
  --restart [args]         --stop puis --start. Jamais « docker compose
                           restart », qui garderait l'ancienne image,
                           l'ancienne ligne de commande et l'ancien .env
  --status                 Runtime actif, état du conteneur (docker compose
                           ps) et réponse de /health
  --logs [-f] [--tail N]   Journaux du conteneur (docker compose logs)
  --en-marche              Pour les scripts : code 0 si le conteneur du
                           runtime actif tourne, 1 sinon, sans rien afficher
  --help, -h               Cette aide

Fichier (à côté du script, local, non versionné) :
  runtime.conf             le runtime actif, une ligne ; écrit par --runtime

HELP
  _rt aide
}
