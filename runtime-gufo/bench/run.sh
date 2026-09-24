#!/usr/bin/env bash
# Banc HTTP gufo contre le service llm-setup : mêmes requêtes aux deux moteurs
# (mesure.py : justesse, conditions du --bench, spec-refactor, prefill long avec
# aiguille, reprise de cache au tour 2). Résultats dans GUFO_DATA/resultats/.
#
# Usage :
#   runtime-gufo/bench/run.sh gufo  <cas>...   gufo sur :8090 ; le service est
#                                              arrêté et relancé à la sortie (trap)
#   runtime-gufo/bench/run.sh llama <cas>...   la section équivalente du service
#
# Cas gufo : 27b, 27b-q4km, flashnext, deepseek (fichiers : commun.sh)
# Cas llama : 27b, flashnext, flashnext-large-ub, deepseek
#
# Réglage gufo de ce banc : 1 session, pas de cache disque (chaque requête a
# un préfixe aléatoire, aucune reprise n'est possible), celui des mesures du
# 24/09/2026.
set -euo pipefail
source "$(dirname "$(realpath "$0")")/../commun.sh"
PORT=8090
NOM=gufo-banc
RES="$GUFO_DATA/resultats"
mkdir -p "$RES"
STOPPE=0

fin() {
  docker rm -f "$NOM" >/dev/null 2>&1 || true
  if ((STOPPE)); then "$DEPOT/setup-llm.sh" --start; fi
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

run_gufo() {
  local cas="$1" label="gufo-$1" t0 t1 nom_modele
  gufo_modele "$cas" || return 1
  if ! ((STOPPE)); then "$DEPOT/setup-llm.sh" --stop; STOPPE=1; fi
  t0=$(date +%s.%N)
  if ! gufo_lance "$NOM" "$PORT" no "${MODELE[@]}" --context 262144 --sessions 1 \
       >"$RES/$label.echec.log" 2>&1; then
    echo "ÉCHEC du démarrage de $label :"; tail -25 "$RES/$label.echec.log"
    return 1
  fi
  rm -f "$RES/$label.echec.log"
  t1=$(date +%s.%N)
  printf '%s\t%s\tchargement %.1f s\n' "$(date +%FT%T)" "$label" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" | tee -a "$RES/chargements.tsv"
  nom_modele="$(curl -s "localhost:$PORT/v1/models" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"][0]["id"])')"
  python3 "$GUFO_DIR/bench/mesure.py" "http://localhost:$PORT" "$nom_modele" "$label" "$RES" "$DEPOT/prompts" || true
  printf '%s\t%s\tmémoire utilisée %s Mio\n' "$(date +%FT%T)" "$label" \
    "$(free -m | awk '/^Mem/{print $3}')" | tee -a "$RES/chargements.tsv"
  docker logs "$NOM" >"$RES/$label.log" 2>&1
  docker rm -f "$NOM" >/dev/null
}

run_llama() {
  local cas="$1" label="llama-$1" sec
  sec="$(section "$cas")"
  if ((STOPPE)); then "$DEPOT/setup-llm.sh" --start; STOPPE=0; fi
  python3 "$GUFO_DIR/bench/mesure.py" "http://localhost:8009" "$sec" "$label" "$RES" "$DEPOT/prompts" || true
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
