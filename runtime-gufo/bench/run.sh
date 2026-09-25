#!/usr/bin/env bash
# Banc HTTP gufo contre le service llm-setup : mêmes requêtes aux deux moteurs
# (mesure.py : justesse, conditions du --bench, spec-refactor, prefill long avec
# aiguille, reprise de cache au tour 2). Résultats dans GUFO_DATA/resultats/.
#
# Usage :
#   runtime-gufo/bench/run.sh gufo  <cas>...   gufo sur :8009 ; le service est
#                                              arrêté et relancé à la sortie (trap)
#   runtime-gufo/bench/run.sh llama <cas>...   la section équivalente du service
#
# Cas gufo : 27b, flashnext, deepseek (modèles de runtime-gufo/gufo-llama-swap.yaml,
# gufo lancé derrière llama-swap, le modèle du cas préchargé)
# Cas llama : 27b, flashnext, flashnext-large-ub, deepseek
#
# Réglage gufo de ce banc : celui du compose (cache disque compris), 1 session
# (SESSIONS=N), port 8009 (celui du service, exclusifs), sans redémarrage
# automatique. Un gufo d'usage réel est retiré au départ ; le service est
# relancé à la fin. Chaque requête a un préfixe aléatoire, le cache disque ne sert donc pas ici ; les mesures du
# 24/09/2026 ont été faites sans lui (la seule différence, les écritures de
# points de reprise, n'entre pas dans le premier token).
set -euo pipefail
DEPOT="$(realpath "$(dirname "$(realpath "$0")")/../..")"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
PORT=8009
# gufo du banc : compose de runtime-gufo/, lancé par ./setup-llm.sh --gufo sur
# le même port que le service (ils sont exclusifs), sans redémarrage
# automatique, avec projet, conteneur et .env séparés de ceux de l'usage réel.
export GUFO_DATA GUFO_PORT=$PORT GUFO_RESTART=no GUFO_SESSIONS="${SESSIONS:-1}" \
  GUFO_PROJET=gufo-banc GUFO_CONTENEUR=gufo-banc GUFO_ENV_FILE="$GUFO_DATA/banc.env"
RES="$GUFO_DATA/resultats"
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

modele_gufo() {  # cas -> modèle de gufo-llama-swap.yaml
  case "$1" in
    27b) echo qwen3.8-27b ;;
    flashnext) echo qwen3.8-flash-next ;;
    deepseek) echo deepseek-v4-flash ;;
    *) echo "cas inconnu : $1" >&2; return 2 ;;
  esac
}

section() {  # cas -> section du models.ini
  case "$1" in
    27b*) echo qwen3.8-27b-dflash-nothink ;;
    flashnext-large-ub) echo qwen3.8-flash-next-mtp-nothink-large-ub ;;
    flashnext*) echo qwen3.8-flash-next-mtp-nothink ;;
    deepseek*) echo deepseek-v4-flash ;;
    *) echo "cas inconnu : $1" >&2; return 2 ;;
  esac
}

run_gufo() {
  local cas="$1" label="gufo-$1" t0 t1 nom_modele
  modele_gufo "$cas" >/dev/null || return 1
  if ! ((STOPPE)); then
    # Port à libérer : le service, et un éventuel gufo d'usage réel (projet
    # gufo, conteneur gufo-8009). Le banc rend la main au service à la fin.
    GUFO_PROJET=gufo GUFO_CONTENEUR=gufo-8009 GUFO_ENV_FILE="$GUFO_DATA/.env" \
      GUFO_SANS_SERVICE=1 "$DEPOT/setup-llm.sh" --gufo-off >/dev/null 2>&1 || true
    "$DEPOT/setup-llm.sh" --stop; STOPPE=1
  fi
  t0=$(date +%s.%N)
  if ! "$DEPOT/setup-llm.sh" --gufo "$cas" >"$RES/$label.lancement.log" 2>&1; then
    echo "ÉCHEC du démarrage de $label :"; tail -25 "$RES/$label.lancement.log"
    return 1
  fi
  t1=$(date +%s.%N)
  printf '%s\t%s\tchargement %.1f s\n' "$(date +%FT%T)" "$label" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" | tee -a "$RES/chargements.tsv"
  nom_modele="$(modele_gufo "$cas")"
  python3 "$DEPOT/runtime-gufo/bench/mesure.py" "http://localhost:$PORT" "$nom_modele" "$label" "$RES" "$DEPOT/prompts" || true
  printf '%s\t%s\tmémoire utilisée %s Mio\n' "$(date +%FT%T)" "$label" \
    "$(free -m | awk '/^Mem/{print $3}')" | tee -a "$RES/chargements.tsv"
  docker logs "$GUFO_CONTENEUR" >"$RES/$label.log" 2>&1
  GUFO_SANS_SERVICE=1 "$DEPOT/setup-llm.sh" --gufo-off >/dev/null
}

run_llama() {
  local cas="$1" label="llama-$1" sec
  sec="$(section "$cas")"
  if ((STOPPE)); then "$DEPOT/setup-llm.sh" --start; STOPPE=0; fi
  python3 "$DEPOT/runtime-gufo/bench/mesure.py" "http://localhost:8009" "$sec" "$label" "$RES" "$DEPOT/prompts" || true
  printf '%s\t%s\tmémoire utilisée %s Mio\n' "$(date +%FT%T)" "$label" \
    "$(free -m | awk '/^Mem/{print $3}')" | tee -a "$RES/chargements.tsv"
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
