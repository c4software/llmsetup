# lib/svc.sh - sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → runtime/*/runtime.sh → help

# =============================================================================
# Pilotage du service - couche unique au-dessus de docker compose, GÉNÉRIQUE
#
# Tout le dépôt passe par les _svc_* de ce module : plus un seul
# `docker compose` du service ailleurs, comme il n'y avait plus qu'un seul
# `systemctl --user` avant la bascule. Une seule ligne à corriger le jour où
# l'orchestration change, et surtout un seul endroit qui sait attendre.
# (Ne pas confondre avec le compose jetable de bench-agentic/, qui lance le
# client pi : il ne sert pas le modèle, il l'appelle.)
#
# Depuis le 09/10/2026 cette couche ne connaît plus aucun moteur : elle pilote
# le runtime VISÉ ($RT, posé par le point d'entrée : LLM_RUNTIME, sinon
# runtime.conf, sinon le défaut), dont elle ne sait que ce que
# runtime/CONTRAT.md lui garantit - un compose versionné à
# runtime/<nom>/docker-compose.yml, un .env qu'il sait écrire sur stdout, un
# nom de conteneur, /health sur SERVER_PORT. Avant : ce module pilotait le
# routeur llama-server, et lib/gufo.sh refaisait la même chose pour gufo, avec
# une garde d'exclusivité écrite à la main entre les deux (_gufo_refuse).
#
# Ce que cette couche apporte, pour tout runtime :
#   - l'attente de /health est DANS _svc_start et _svc_restart. Le dépôt
#     réimplémentait cette boucle à quatre endroits, avec des délais
#     différents (120 s dans lib/, 180 s dans tools/qualif-modele.sh), et
#     deux mesures ont été perdues le 17/09/2026 sur la course « le service ne
#     répond pas encore » : une commande qui rend la main a maintenant un
#     service qui répond, ou elle a échoué en le disant.
#   - la sortie anticipée : un conteneur qui meurt au chargement est détecté
#     par docker inspect en quelques secondes, au lieu d'attendre le plafond.
#   - l'exclusivité : un seul runtime tient le port (un GPU). Démarrer un
#     runtime ARRÊTE celui qui tournait, au lieu de refuser.
#
# ⚠ JAMAIS `docker compose restart` : il relance le conteneur EXISTANT, donc
# l'ancienne image, l'ancienne ligne de commande et l'ancien .env.
# _svc_restart est un stop puis un start, et le start régénère le .env.
# =============================================================================

# URL du service, la même pour tous les runtimes (contrat : /health y répond).
SVC_URL="http://localhost:$SERVER_PORT"

# _svc_compose_file [runtime=$RT] - le compose du runtime : sa place est fixée
# par le contrat, aucun runtime ne la déclare.
_svc_compose_file() {
  printf '%s\n' "$RUNTIMES_DIR/${1:-$RT}/docker-compose.yml"
}

# _svc_compose_de <runtime> [args...] - docker compose sur un runtime NOMMÉ.
# --project-directory = le dossier du .env (les valeurs machine du compose
# versionné) : docker compose ne lit que le .env de son dossier de projet, et
# ce dossier sert de base quel que soit le cwd de l'appelant (les mesures sont
# lancées depuis le dépôt, le service depuis n'importe où). --env-file en plus,
# parce qu'un runtime peut écrire son .env sous un autre nom (les bancs de gufo
# ont le leur, banc.env, à côté de celui de l'usage réel).
_svc_compose_de() {
  local n="$1"; shift
  local f env="${RT_ENV_FILE[$n]}"
  f="$(_svc_compose_file "$n")"
  command -v docker >/dev/null 2>&1 || { warn "docker introuvable."; return 1; }
  [[ -f "$f" ]] || { warn "$f absent : le dépôt est incomplet."; return 1; }
  [[ -f "$env" ]] || { warn "$env absent - ./setup-llm.sh --start le génère."; return 1; }
  docker compose --project-directory "$(dirname "$env")" --env-file "$env" -f "$f" "$@"
}

# _svc_compose [args...] - le seul point d'appel de docker compose du service,
# sur le runtime visé.
_svc_compose() {
  _svc_compose_de "$RT" "$@"
}

# _svc_installed - le service est-il montable ici ? Prérequis du runtime
# réunis : le .env lui-même n'a pas à exister, il se régénère. Remplace le
# `systemctl --user is-enabled` des mesures.
_svc_installed() {
  _rt check >/dev/null 2>&1
}

# _svc_actif_de <runtime> - le conteneur de ce runtime tourne-t-il ?
# Interrogation directe de docker sur le nom du conteneur, sans passer par
# compose : c'est appelé souvent (fin de --setup, de --update, de --cleanup) et
# un `docker compose ps` coûte nettement plus cher qu'un inspect.
_svc_actif_de() {
  command -v docker >/dev/null 2>&1 || return 1
  [[ "$(docker inspect -f '{{.State.Running}}' "${RT_CONTENEUR[$1]}" 2>/dev/null || true)" == "true" ]]
}

# _svc_is_active - le conteneur du runtime visé tourne-t-il ?
_svc_is_active() {
  _svc_actif_de "$RT"
}

# _svc_wait_ready [timeout] - attendre que le service réponde.
#
# Deux sorties : /health répond (0), ou le conteneur est mort / le plafond est
# atteint (1, avec le message qui renvoie aux journaux). Le plafond est celui
# que le runtime déclare (RT_DELAI_DEMARRAGE, 300 s à défaut), large parce
# qu'un parc préchargé de plusieurs dizaines de Go met des minutes à revenir ;
# l'attente ne coûte rien quand le service est déjà prêt.
_svc_wait_ready() {
  local timeout="${1:-${RT_DELAI_DEMARRAGE[$RT]:-300}}" t=0 annonce=0 etat code
  local nom="${RT_CONTENEUR[$RT]}"
  command -v curl >/dev/null 2>&1 || { warn "curl introuvable - attente de /health sautée."; return 0; }
  while :; do
    if curl -sf "$SVC_URL/health" >/dev/null 2>&1; then
      if [[ "$annonce" -eq 1 ]]; then
        info "  $nom prêt après $t s."
      fi
      return 0
    fi
    # Sortie anticipée : un drafter incompatible, un GGUF absent ou une clé de
    # configuration inconnue tuent le conteneur en quelques secondes. Inutile
    # d'attendre le plafond pour dire ce que les journaux disent déjà.
    etat="$(docker inspect -f '{{.State.Status}}' "$nom" 2>/dev/null || true)"
    if [[ "$etat" == "exited" || "$etat" == "dead" ]]; then
      code="$(docker inspect -f '{{.State.ExitCode}}' "$nom" 2>/dev/null || true)"
      warn "$nom est sorti (code ${code:-?}) après $t s, sans répondre sur $SVC_URL."
      warn "  Journaux : ./setup-llm.sh --logs --tail 50"
      return 1
    fi
    if [[ "$annonce" -eq 0 ]]; then
      info "  attente de $nom sur $SVC_URL ($timeout s max)..."
      annonce=1
    fi
    # if/fi obligatoire : « [[ … ]] && return 1 » faux retournerait 1 à chaque
    # tour et set -e tuerait la boucle dès la 1re itération (piège AGENTS.md).
    if [[ "$t" -ge "$timeout" ]]; then
      warn "$nom ne répond toujours pas après $timeout s."
      warn "  Journaux : ./setup-llm.sh --logs --tail 50"
      return 1
    fi
    sleep 2
    t=$(( t + 2 ))
  done
}

# _svc_regen_env [args de --start...] - écrit le .env du runtime visé, par un
# fichier temporaire, et ne remplace que si le contenu diffère. Ne rien
# réécrire quand rien ne change garde une date de modification qui veut dire
# quelque chose (« la configuration du service a bougé au dernier
# démarrage »), et évite de toucher le fichier sous les yeux d'un
# `docker compose` lancé à la main.
# Le contenu vient de la fonction de contrat `env`, qui écrit sur stdout et ne
# touche à rien : c'est ce qui la rend testable et diffable. Renvoie 1 sans
# rien écrire si elle échoue (prérequis manquants) : l'appelant décide si
# c'est fatal.
_svc_regen_env() {
  local env="${RT_ENV_FILE[$RT]}" tmp
  tmp="$(mktemp)" || { warn "mktemp en échec - .env non régénéré."; return 1; }
  if ! _rt env "$@" > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$env" ]] && cmp -s "$tmp" "$env"; then
    rm -f "$tmp"
    return 0
  fi
  if ! mkdir -p "$(dirname "$env")" || ! mv -f "$tmp" "$env"; then
    rm -f "$tmp"
    warn "Écriture de $env en échec."
    return 1
  fi
  chmod 0644 "$env" 2>/dev/null || true
  info ".env régénéré : $env"
  return 0
}

# _svc_stop_de <runtime> [timeout] - arrêt propre du conteneur d'un runtime
# NOMMÉ (signal d'arrêt de son compose). Le conteneur est arrêté, pas
# supprimé : `docker compose ps -a` garde la trace du dernier code de sortie,
# et _svc_start le recrée de toute façon. Un conteneur arrêté ne tient plus le
# port et ne repart pas au démarrage de la machine (restart: unless-stopped).
# Sans .env (machine jamais démarrée sur ce format, ou fichier retiré), compose
# ne peut pas lire son projet : le conteneur, lui, existe et porte son nom ;
# `docker stop` fait alors la même chose. C'est ce qui rend --restart possible
# au premier passage, au lieu de sauter l'arrêt propre.
_svc_stop_de() {
  local n="$1" timeout="${2:-${RT_DELAI_ARRET[$1]:-10}}"
  _svc_actif_de "$n" || return 0
  if [[ -f "${RT_ENV_FILE[$n]}" ]]; then
    _svc_compose_de "$n" stop -t "$timeout" || return 1
  else
    docker stop -t "$timeout" "${RT_CONTENEUR[$n]}" >/dev/null || return 1
  fi
  return 0
}

# _svc_stop [timeout] - arrêt propre du runtime visé.
_svc_stop() {
  _svc_stop_de "$RT" "$@"
}

# _svc_arreter_autres - un seul runtime sur le port : arrête le conteneur de
# tout AUTRE runtime qui tourne. Appelée par _svc_start, juste avant le up :
# l'exclusivité tient par construction, sans garde à écrire dans chaque
# runtime.
_svc_arreter_autres() {
  local n
  for n in ${RUNTIMES[@]+"${RUNTIMES[@]}"}; do
    [[ "$n" != "$RT" ]] || continue
    if _svc_actif_de "$n"; then
      info "  le runtime $n tient le port (conteneur ${RT_CONTENEUR[$n]}) : arrêt..."
      _svc_stop_de "$n" || { warn "Arrêt de ${RT_CONTENEUR[$n]} en échec."; return 1; }
    fi
  done
  return 0
}

# _svc_start [args de --start...] - préparation, .env régénéré, PUIS
# démarrage, PUIS attente.
#
# --force-recreate : le conteneur est recréé même si compose juge que rien n'a
# changé. C'est voulu - ce qui a changé est souvent hors du compose
# (configuration régénérée, poids retéléchargés), et un conteneur réutilisé
# servirait l'ancien état. --remove-orphans ramasse les conteneurs d'un service
# renommé.
# Les fonctions optionnelles du contrat encadrent le démarrage :
# avant_demarrage (dossiers de l'hôte, migrations) et pret (ce que /health ne
# dit pas : un modèle préchargé qui n'a pas fini de charger).
_svc_start() {
  if _rt_a "$RT" avant_demarrage; then
    _rt avant_demarrage "$@" || return 1
  fi
  _svc_regen_env "$@" || return 1
  _svc_arreter_autres || return 1
  _svc_compose up -d --force-recreate --remove-orphans || return 1
  _svc_wait_ready || return 1
  if _rt_a "$RT" pret; then
    _rt pret "$@" || return 1
  fi
  return 0
}

# _svc_restart [args de --start...] - stop puis start. JAMAIS
# `docker compose restart`, qui garderait l'ancienne image, l'ancienne
# commande et l'ancien .env.
_svc_restart() {
  _svc_stop || warn "Arrêt de ${RT_CONTENEUR[$RT]} en échec - démarrage tenté quand même."
  _svc_start "$@"
}

# _svc_logs [args...] - --no-color : les journaux sont lus dans un fichier ou
# dans un tube aussi souvent qu'à l'écran.
_svc_logs() {
  _svc_compose logs --no-color "$@"
}

# =============================================================================
# Commandes publiques
# =============================================================================

# cmd_start [args du runtime...] - démarre le runtime actif (commande par
# défaut). Les arguments sont ceux du runtime (gufo : le modèle préchargé).
cmd_start() {
  _rt check || error "Le runtime $RT ne peut pas démarrer ici (voir ci-dessus)."
  info "Démarrage de ${RT_CONTENEUR[$RT]} (runtime $RT) sur :$SERVER_PORT..."
  _svc_start "$@" || error "Démarrage de ${RT_CONTENEUR[$RT]} en échec - ./setup-llm.sh --logs --tail 50"
  info "✅ ${RT_CONTENEUR[$RT]} répond sur $SVC_URL."
}

cmd_stop() {
  local nom="${RT_CONTENEUR[$RT]}"
  if ! _svc_is_active; then
    info "$nom n'est pas en marche, rien à arrêter."
    return 0
  fi
  info "Arrêt de $nom (jusqu'à ${RT_DELAI_ARRET[$RT]:-10} s)..."
  _svc_stop || error "Arrêt de $nom en échec - ./setup-llm.sh --logs --tail 50"
  info "✅ $nom arrêté."
}

cmd_restart() {
  local nom="${RT_CONTENEUR[$RT]}"
  info "Redémarrage de $nom (.env régénéré, conteneur recréé)..."
  _svc_restart "$@" || error "Redémarrage de $nom en échec - ./setup-llm.sh --logs --tail 50"
  info "✅ $nom redémarré et prêt sur $SVC_URL."
}

# cmd_status - état du conteneur (compose) plus la seule chose qui compte
# vraiment pour les mesures : le service répond-il ? Puis ce que le runtime
# veut ajouter (fonction optionnelle etat).
cmd_status() {
  local nom="${RT_CONTENEUR[$RT]}" n
  info "Runtime actif : $RT (${RT_DESCRIPTION[$RT]:-})"
  if [[ -f "${RT_ENV_FILE[$RT]}" ]]; then
    _svc_compose ps -a || true
  else
    warn "${RT_ENV_FILE[$RT]} absent (runtime jamais démarré ici)."
  fi
  echo ""
  if _svc_is_active; then
    if command -v curl >/dev/null 2>&1 && curl -sf "$SVC_URL/health" >/dev/null 2>&1; then
      info "✅ $nom en marche et /health répond sur $SVC_URL."
      if _rt_a "$RT" etat; then
        _rt etat || true
      fi
    else
      warn "$nom en marche mais /health ne répond pas encore (chargement ?)."
      warn "  Suivre : ./setup-llm.sh --logs -f"
    fi
  else
    for n in ${RUNTIMES[@]+"${RUNTIMES[@]}"}; do
      if [[ "$n" != "$RT" ]] && _svc_actif_de "$n"; then
        warn "$nom n'est pas en marche : c'est le runtime $n qui tient :$SERVER_PORT (conteneur ${RT_CONTENEUR[$n]})."
        warn "  Le reprendre : ./setup-llm.sh --start ; y basculer : ./setup-llm.sh --runtime $n"
        return 0
      fi
    done
    warn "$nom n'est pas en marche - ./setup-llm.sh --start"
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

# cmd_en_marche - pour les scripts : code 0 si le conteneur du runtime actif
# tourne, 1 sinon, sans rien afficher. Sert aux bancs, qui coupent le service
# le temps d'une mesure et doivent savoir s'il y avait quelque chose à
# relancer.
cmd_en_marche() {
  _svc_is_active
}

# cmd_runtime [nom] - sans argument : les runtimes présents, l'actif et celui
# qui tourne. Avec un nom : BASCULE - le runtime devient l'actif (runtime.conf)
# et démarre, ce qui arrête celui qui tenait le port.
#
# Les prérequis du nouveau sont vérifiés AVANT de toucher à quoi que ce soit :
# un runtime pas encore installé ne coupe pas celui qui sert. Il s'installe
# d'abord sans bascule, par LLM_RUNTIME=<nom> ./setup-llm.sh --setup.
# Si le démarrage échoue après coup, l'ancien runtime est remis (conf et
# conteneur) : jamais un port vide.
cmd_runtime() {
  local nouveau="${1:-}" n marque etat ancien ancien_actif=0
  if [[ -z "$nouveau" ]]; then
    for n in ${RUNTIMES[@]+"${RUNTIMES[@]}"}; do
      marque=" "; etat="arrêté"
      [[ "$n" == "$RT" ]] && marque="*"
      _svc_actif_de "$n" && etat="en marche"
      printf '%s %-24s %-10s %s\n' "$marque" "$n" "$etat" "${RT_DESCRIPTION[$n]:-}"
    done
    echo ""
    info "* = runtime actif ($RUNTIME_CONF, défaut $RUNTIME_DEFAUT). Basculer : ./setup-llm.sh --runtime <nom>"
    return 0
  fi
  shift
  _rt_existe "$nouveau" || error "Runtime inconnu : '$nouveau' (présents : ${RUNTIMES[*]})"

  ancien="$RT"
  _svc_is_active && ancien_actif=1
  RT="$nouveau"
  if ! _rt check; then
    RT="$ancien"
    error "Le runtime $nouveau n'est pas prêt ici, rien n'a été touché. L'installer d'abord : LLM_RUNTIME=$nouveau ./setup-llm.sh --setup"
  fi

  printf '%s\n' "$nouveau" > "$RUNTIME_CONF"
  info "Runtime actif : $nouveau (était : $ancien)."
  if _svc_start "$@"; then
    info "✅ ${RT_CONTENEUR[$RT]} répond sur $SVC_URL."
    return 0
  fi

  warn "Démarrage de $nouveau en échec - retour à $ancien."
  _svc_stop >/dev/null 2>&1 || true
  RT="$ancien"
  printf '%s\n' "$ancien" > "$RUNTIME_CONF"
  if [[ "$ancien_actif" -eq 1 && "$ancien" != "$nouveau" ]]; then
    _svc_start || error "$nouveau n'a pas démarré, et $ancien n'a pas pu être relancé - ./setup-llm.sh --logs --tail 50"
    error "$nouveau n'a pas démarré, $ancien relancé."
  fi
  error "$nouveau n'a pas démarré (runtime actif remis à $ancien)."
}
