# lib/svc.sh - sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Pilotage du service - couche unique au-dessus de docker compose
#
# Tout le dépôt passe par les _svc_* de ce module : plus un seul
# `docker compose` du service ailleurs, comme il n'y avait plus qu'un seul
# `systemctl --user` avant la bascule. Une seule ligne à corriger le jour où
# l'orchestration change, et surtout un seul endroit qui sait attendre.
# (Ne pas confondre avec lib/bench/bench-agentic.sh, qui a SON propre compose
# jetable pour le client pi : il ne sert pas le modèle, il l'appelle.)
#
# Ce que cette couche apporte par rapport à l'unité systemd :
#   - l'attente de /health est DANS _svc_start et _svc_restart. Le dépôt
#     réimplémentait cette boucle à quatre endroits, avec des délais
#     différents (120 s dans lib/, 180 s dans tools/qualif-modele.sh), et
#     deux mesures ont été perdues le 17/09/2026 sur la course « le service ne
#     répond pas encore » : une commande qui rend la main a maintenant un
#     service qui répond, ou elle a échoué en le disant.
#   - la sortie anticipée : un conteneur qui meurt au chargement est détecté
#     par docker inspect en quelques secondes, au lieu d'attendre le plafond.
#
# ⚠ JAMAIS `docker compose restart` : il relance le conteneur EXISTANT, donc
# l'ancienne image, l'ancienne ligne de commande et l'ancien --models-max.
# _svc_restart est un stop puis un start, et le start régénère le compose.
# =============================================================================

# _svc_compose [args...] - le seul point d'appel de docker compose du service.
# --project-directory $CONFIG_DIR : le compose vit à côté de models.ini, et
# c'est ce dossier qui doit servir de base, quel que soit le cwd de l'appelant
# (les mesures sont lancées depuis le dépôt, le service depuis n'importe où).
_svc_compose() {
  command -v docker >/dev/null 2>&1 || { warn "docker introuvable."; return 1; }
  [[ -f "$COMPOSE_FILE" ]] || { warn "$COMPOSE_FILE absent - ./setup-llm.sh --start le génère."; return 1; }
  docker compose --project-directory "$CONFIG_DIR" -f "$COMPOSE_FILE" "$@"
}

# _svc_installed - le service est-il montable ici ? Compose générable (docker,
# image locale, models.ini) : le compose lui-même n'a pas à exister, il se
# régénère. Remplace le `systemctl --user is-enabled` des mesures.
_svc_installed() {
  _compose_check >/dev/null 2>&1
}

# _svc_is_active - le conteneur tourne-t-il ? Interrogation directe de docker
# sur le nom du conteneur, sans passer par compose : c'est appelé souvent
# (fin de --setup, de --update, de --cleanup) et un `docker compose ps` coûte
# nettement plus cher qu'un inspect.
_svc_is_active() {
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "$SERVICE_NAME" 2>/dev/null || true)" == "true" ]]
}

# _svc_wait_ready [timeout=300] - attendre que le routeur réponde.
#
# Deux sorties : /health répond (0), ou le conteneur est mort / le plafond est
# atteint (1, avec le message qui renvoie aux journaux). Le plafond est large
# (300 s) parce qu'un parc préchargé de plusieurs dizaines de Go met des
# minutes à revenir ; l'attente ne coûte rien quand le service est déjà prêt.
_svc_wait_ready() {
  local timeout="${1:-300}" t=0 annonce=0 etat code
  command -v curl >/dev/null 2>&1 || { warn "curl introuvable - attente de /health sautée."; return 0; }
  while :; do
    if curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; then
      if [[ "$annonce" -eq 1 ]]; then
        info "  $SERVICE_NAME prêt après $t s."
      fi
      return 0
    fi
    # Sortie anticipée : un drafter incompatible, un GGUF absent ou une clé ini
    # inconnue tuent le conteneur en quelques secondes. Inutile d'attendre le
    # plafond pour dire ce que les journaux disent déjà.
    etat="$(docker inspect -f '{{.State.Status}}' "$SERVICE_NAME" 2>/dev/null || true)"
    if [[ "$etat" == "exited" || "$etat" == "dead" ]]; then
      code="$(docker inspect -f '{{.State.ExitCode}}' "$SERVICE_NAME" 2>/dev/null || true)"
      warn "$SERVICE_NAME est sorti (code ${code:-?}) après $t s, sans répondre sur $SPEC_TEST_URL."
      warn "  Journaux : ./setup-llm.sh --logs --tail 50"
      return 1
    fi
    if [[ "$annonce" -eq 0 ]]; then
      info "  attente de $SERVICE_NAME sur $SPEC_TEST_URL ($timeout s max)..."
      annonce=1
    fi
    # if/fi obligatoire : « [[ … ]] && return 1 » faux retournerait 1 à chaque
    # tour et set -e tuerait la boucle dès la 1re itération (piège AGENTS.md).
    if [[ "$t" -ge "$timeout" ]]; then
      warn "$SERVICE_NAME ne répond toujours pas après $timeout s."
      warn "  Journaux : ./setup-llm.sh --logs --tail 50"
      return 1
    fi
    sleep 2
    t=$(( t + 2 ))
  done
}

# _svc_start - compose régénéré PUIS démarrage PUIS attente.
#
# --force-recreate : le conteneur est recréé même si compose juge que rien n'a
# changé. C'est voulu - ce qui a changé est souvent hors du compose (models.ini
# régénéré, poids retéléchargés), et un conteneur réutilisé servirait l'ancien
# état. --remove-orphans ramasse les conteneurs d'un service renommé.
_svc_start() {
  regen_compose || return 1
  _svc_compose up -d --force-recreate --remove-orphans || return 1
  _svc_wait_ready
}

# _svc_stop [timeout=180] - arrêt propre (SIGINT, cf. stop_signal du compose).
# Le conteneur est arrêté, pas supprimé : `docker compose ps -a` garde la trace
# du dernier code de sortie, et _svc_start le recrée de toute façon.
_svc_stop() {
  local timeout="${1:-180}"
  _svc_is_active || return 0
  _svc_compose stop -t "$timeout" || return 1
  return 0
}

# _svc_restart - stop puis start. JAMAIS `docker compose restart`, qui
# garderait l'ancienne image, l'ancienne commande et l'ancien --models-max.
_svc_restart() {
  _svc_stop || warn "Arrêt de $SERVICE_NAME en échec - démarrage tenté quand même."
  _svc_start
}

# _svc_logs [args...] - --no-color : les journaux sont lus dans un fichier ou
# dans un tube aussi souvent qu'à l'écran.
_svc_logs() {
  _svc_compose logs --no-color "$@"
}

# =============================================================================
# Commandes publiques
# =============================================================================

# cmd_start - démarre la stack (commande par défaut, comme avant la bascule).
# L'ancien --start exécutait llama-server au premier plan, pour l'unité
# systemd ; il n'y a plus d'unité, et le moteur de l'hôte n'est plus celui qui
# sert. Son garde-fou moteur/ini (_fork_keys_guard) n'a donc plus d'objet ici :
# le moteur du conteneur est celui de l'image, un seul et connu. lib/fork.sh
# reste en place (filet de retour arrière tant que la migration n'est pas
# terminée) et ses commandes --setup-fork / --update-fork sont inchangées.
cmd_start() {
  [[ -f "$CONFIG_DIR/models.ini" ]] || error "Config introuvable - lance d'abord --setup"
  _compose_check || error "Le service ne peut pas démarrer ici (voir ci-dessus)."

  load_preload_conf
  local models_max=$(( ${#PRELOADED[@]} + 1 ))
  (( models_max < 2 )) && models_max=2
  info "Démarrage de $SERVICE_NAME (conteneur, router mode) sur $BIND_ADDR:$SERVER_PORT..."
  info "  Préchargés : $(_preload_summary) - models-max=$models_max"

  _svc_start || error "Démarrage de $SERVICE_NAME en échec - ./setup-llm.sh --logs --tail 50"
  info "✅ $SERVICE_NAME répond sur $SPEC_TEST_URL (WebUI comprise)."
}

cmd_stop() {
  if ! _svc_is_active; then
    info "$SERVICE_NAME n'est pas en marche, rien à arrêter."
    return 0
  fi
  info "Arrêt de $SERVICE_NAME (jusqu'à 180 s : déchargement des modèles préchargés)..."
  _svc_stop || error "Arrêt de $SERVICE_NAME en échec - ./setup-llm.sh --logs --tail 50"
  info "✅ $SERVICE_NAME arrêté."
}

cmd_restart() {
  info "Redémarrage de $SERVICE_NAME (compose régénéré, conteneur recréé)..."
  _svc_restart || error "Redémarrage de $SERVICE_NAME en échec - ./setup-llm.sh --logs --tail 50"
  info "✅ $SERVICE_NAME redémarré et prêt sur $SPEC_TEST_URL."
}

# cmd_status - état du conteneur (compose) plus la seule chose qui compte
# vraiment pour les mesures : le routeur répond-il ?
cmd_status() {
  if [[ -f "$COMPOSE_FILE" ]]; then
    _svc_compose ps -a || true
  else
    warn "$COMPOSE_FILE absent (service jamais démarré depuis la bascule)."
  fi
  echo ""
  if _svc_is_active; then
    if command -v curl >/dev/null 2>&1 && curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; then
      info "✅ $SERVICE_NAME en marche et /health répond sur $SPEC_TEST_URL."
    else
      warn "$SERVICE_NAME en marche mais /health ne répond pas encore (préchargement ?)."
      warn "  Suivre : ./setup-llm.sh --logs -f"
    fi
  else
    warn "$SERVICE_NAME n'est pas en marche - ./setup-llm.sh --start"
  fi
  return 0
}

# cmd_logs [-f] [--tail N] - journaux du conteneur.
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
  _svc_logs ${args[@]+"${args[@]}"}
}
