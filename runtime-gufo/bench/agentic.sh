#!/usr/bin/env bash
# Boucle agentique réelle (scénarios pi de bench-agentic/, même image, même
# scenarios.sh) jouée contre gufo ou contre le service, sans rien écrire dans
# logs/bench-agentic.log. Sorties pi et journal gufo dans
# GUFO_DATA/resultats/agentic/.
#
# Usage :
#   runtime-gufo/bench/agentic.sh gufo  <cas>...   gufo sur :8009 ; le service est
#                                                  arrêté et relancé à la sortie (trap)
#   runtime-gufo/bench/agentic.sh llama <cas>...   la section équivalente du service
#   PASSES=N …                                     nombre de passes (défaut 3)
#
# Cas gufo : 27b, 27b-q4km, flashnext, deepseek (services de runtime-gufo/docker-compose.yml)
# Cas llama : 27b, flashnext, flashnext-large-ub, deepseek
#
# Réglage gufo de ce banc : celui du compose (cache disque et staging relevé,
# seconde série du 24/09/2026), 1 session (SESSIONS=N pour changer), port
# 8009 (celui du service, exclusifs), sans redémarrage automatique. Un gufo
# d'usage réel est retiré au départ ; le service est relancé à la fin.
# Sans cache disque, gufo ne reprend pas le préfixe commun des nouvelles
# conversations et perd son avance (docs/GUFO.md). Le /metrics de gufo n'a pas
# les compteurs de cache ni de secondes : pour gufo, les colonnes prompt, cache,
# prefill et décode de pi sont incomplètes, les vraies valeurs sont dans son
# journal (event=completed, une ligne par requête).
set -euo pipefail
DEPOT="$(realpath "$(dirname "$(realpath "$0")")/../..")"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
PORT=8009
# gufo du banc : compose de runtime-gufo/, lancé par ./setup-llm.sh --gufo sur
# le même port que le service (ils sont exclusifs), sans redémarrage
# automatique, avec projet, conteneur et .env séparés de ceux de l'usage réel.
export GUFO_DATA GUFO_PORT=$PORT GUFO_RESTART=no GUFO_SESSIONS="${SESSIONS:-1}" \
  GUFO_PROJET=gufo-banc GUFO_CONTENEUR=gufo-banc GUFO_ENV_FILE="$GUFO_DATA/banc.env"
PASSES="${PASSES:-3}"
RES="$GUFO_DATA/resultats/agentic"
mkdir -p "$RES"
STOPPE=0

fin() {
  GUFO_SANS_SERVICE=1 "$DEPOT/setup-llm.sh" --gufo-off >/dev/null 2>&1 || true
  if ((STOPPE)) && [[ "$(docker inspect -f '{{.State.Running}}' llama-server 2>/dev/null || true)" != true ]]; then
    "$DEPOT/setup-llm.sh" --start
  fi
  return 0
}
trap fin EXIT

section() {  # cas -> section du models.ini
  case "$1" in
    27b*) echo qwen3.8-27b-dflash-nothink ;;
    flashnext-large-ub) echo qwen3.8-flash-next-mtp-nothink-large-ub ;;
    flashnext*) echo qwen3.8-flash-next-mtp-nothink ;;
    deepseek*) echo deepseek-v4-flash ;;
    *) echo "cas inconnu : $1" >&2; return 2 ;;
  esac
}

pi_run() {  # modèle url sortie ; garde-temps : une boucle infinie ne bloque pas le GPU
  MODEL="$1" PASSES="$PASSES" SERVER_URL="$2" \
    timeout 3600 docker compose -f "$DEPOT/bench-agentic/docker-compose.yml" run --rm -T pi >"$3" 2>&1 || true
  grep -v $'^TSV\t' "$3" | grep -E 'PASS|FAIL|Résumé|mur' || true
}

run_gufo() {
  local cas="$1" label="gufo-$1" nom_modele
  if ! ((STOPPE)); then
    # Port à libérer : le service, et un éventuel gufo d'usage réel (projet
    # gufo, conteneur gufo-8009). Le banc rend la main au service à la fin.
    GUFO_PROJET=gufo GUFO_CONTENEUR=gufo-8009 GUFO_ENV_FILE="$GUFO_DATA/.env" \
      GUFO_SANS_SERVICE=1 "$DEPOT/setup-llm.sh" --gufo-off >/dev/null 2>&1 || true
    "$DEPOT/setup-llm.sh" --stop; STOPPE=1
  fi
  if ! "$DEPOT/setup-llm.sh" --gufo "$cas" >"$RES/$label.lancement.log" 2>&1; then
    echo "ÉCHEC du démarrage de $label :"; tail -25 "$RES/$label.lancement.log"
    return 1
  fi
  nom_modele="$(curl -s "localhost:$PORT/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
  echo "=== $label : pi, $PASSES passes"
  pi_run "$nom_modele" "http://127.0.0.1:$PORT" "$RES/$label.out"
  docker logs "$GUFO_CONTENEUR" >"$RES/$label.log" 2>&1
  GUFO_SANS_SERVICE=1 "$DEPOT/setup-llm.sh" --gufo-off >/dev/null
}

run_llama() {
  local cas="$1" label="llama-$1" sec
  sec="$(section "$cas")"
  if ((STOPPE)); then "$DEPOT/setup-llm.sh" --start; STOPPE=0; fi
  echo "=== $label : pi, $PASSES passes"
  pi_run "$sec" "http://127.0.0.1:8009" "$RES/$label.out"
}

moteur="${1:-}"; shift || true
[[ "$moteur" == gufo || "$moteur" == llama ]] && (($# > 0)) \
  || { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
for cas in "$@"; do
  case "$moteur" in
    gufo) run_gufo "$cas" || true ;;
    llama) run_llama "$cas" ;;
  esac
done
