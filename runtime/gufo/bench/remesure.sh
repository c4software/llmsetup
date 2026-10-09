#!/usr/bin/env bash
# Remesure de gufo après une montée de version (étape 6 de la « Checklist de
# montée de version » de docs/GUFO.md) : banc HTTP, boucle agentique avec le
# cache disque d'usage, en option la même boucle SANS cache disque, puis le
# bilan des journaux (bench/journal.py) contre la remesure précédente, et
# le runtime d'usage réel relancé s'il tournait au départ.
#
# Usage (sur la machine du service, machine libre : le runtime d'usage réel,
# gufo ou llama-server, est coupé pendant les bancs) :
#   runtime/gufo/bench/remesure.sh [cas...]   défaut : 27b flashnext
#   SANS_CACHE=1 …                            ajoute la boucle sans --cache-disk
#   TAG=…                                     dossier des journaux (défaut :
#                                             <date>-<version de GUFO_IMAGE>)
#   DEBUG=0 / PI_SESSIONS=0 …                 sans gufo -v / sans transcript pi
#   nohup runtime/gufo/bench/remesure.sh > ~/llm/gufo-test/remesure.log 2>&1 &
#
# Boucles agentiques TOUJOURS en debug (gufo -v) et sessions pi gardées
# (<cas>.sessions/), par défaut depuis le 02/10/2026 : la boucle de #368 n'est
# apparue qu'une fois sur plusieurs séries, et la rejouer pour en avoir le
# transcript coûtait une seconde série (et ne la reproduit pas forcément).
#
# Cas : ceux de run.sh et agentic.sh (27b, flashnext, deepseek). DeepSeek
# n'est plus remesuré depuis le 28/09/2026 sauf demande.
#
# agentic.sh écrase GUFO_DATA/resultats/agentic/gufo-<cas>.* à chaque
# passage : ce script les copie avant (avant/) et après chaque série
# (avec-cache/, sans-cache/) dans resultats/agentic/<TAG>/. Le banc HTTP
# ajoute ses lignes à resultats/resultats.tsv (colonne date).
#
# SANS_CACHE=1 retire --cache-disk et --cache-disk-staging-bytes de la macro
# gufo de gufo-llama-swap.yaml le temps de la série (copie de sauvegarde,
# restaurée par trap) : sert à vérifier une affirmation amont sur la reprise
# des préfixes partagés sans disque (#259, #267). Refusé si le fichier a des
# modifications locales. Rien n'est commité. agentic.sh refusant DEBUG=1 sur
# un yaml modifié, le -v de cette série est posé ici, dans la même copie.
set -euo pipefail
DEPOT="$(realpath "$(dirname "$(realpath "$0")")/../../..")"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
YAML="$DEPOT/runtime/gufo/gufo-llama-swap.yaml"
BENCH="$DEPOT/runtime/gufo/bench"
A="$GUFO_DATA/resultats/agentic"
(($# > 0)) || set -- 27b flashnext
DEBUG="${DEBUG:-1}"
export PI_SESSIONS="${PI_SESSIONS:-1}"

image="${GUFO_IMAGE:-$(<"$DEPOT/runtime/gufo/IMAGE")}"
TAG="${TAG:-$(date +%F)-${image##*:}}"
S="$A/$TAG"

# Runtime d'usage réel en marche au départ ? (gufo ou llama-server, celui de
# runtime.conf.) Les bancs l'arrêtent ; il est relancé UNE fois, à la fin de
# ce script et non entre deux bancs (BANC_SANS_RELANCE). gufo reprend alors le
# modèle préchargé de son .env.
relance=0
if "$DEPOT/setup-llm.sh" --en-marche; then relance=1; fi
export BANC_SANS_RELANCE=1

if [[ "${SANS_CACHE:-0}" == 1 ]] && ! git -C "$DEPOT" diff --quiet -- runtime/gufo/gufo-llama-swap.yaml; then
  echo "ERREUR : $YAML a des modifications locales, SANS_CACHE=1 refusé" >&2
  exit 2
fi

copie() {  # copie <sous-dossier> <cas>... : journaux agentiques des cas
  local d="$S/$1" c
  shift
  mkdir -p "$d"
  for c in "$@"; do
    cp -a "$A/gufo-$c".* "$d/" 2>/dev/null || true
  done
}

bilan() {  # bilan <sous-dossier> : journal.py sur ses journaux gufo
  local c
  for c in "${CAS[@]}"; do
    [[ -f "$S/$1/gufo-$c.log" ]] && python3 "$BENCH/journal.py" "$S/$1/gufo-$c.log"
  done
  return 0
}

SAUVE=""
fin() {
  if [[ -n "$SAUVE" ]]; then cp -f "$SAUVE" "$YAML"; rm -f "$SAUVE"; fi
  return 0
}
trap fin EXIT

CAS=("$@")
echo "== $(date +%T) remesure $TAG (${image}), cas : ${CAS[*]}${SANS_CACHE:+, SANS_CACHE=$SANS_CACHE}"
if ((relance)); then echo "   runtime d'usage réel relancé à la fin"; fi
copie avant "${CAS[@]}"

echo "== $(date +%T) banc HTTP"
"$BENCH/run.sh" gufo "${CAS[@]}"

echo "== $(date +%T) boucle agentique, cache disque"
DEBUG="$DEBUG" "$BENCH/agentic.sh" gufo "${CAS[@]}"
copie avec-cache "${CAS[@]}"

if [[ "${SANS_CACHE:-0}" == 1 ]]; then
  echo "== $(date +%T) boucle agentique, SANS cache disque"
  SAUVE="$(mktemp "$GUFO_DATA/gufo-llama-swap.yaml.XXXXXX")"
  cp -f "$YAML" "$SAUVE"
  sed -i '/--cache-disk /d; /--cache-disk-staging-bytes /d' "$YAML"
  if [[ "$DEBUG" == 1 ]]; then
    sed -i 's/^\(    gufo serve llm \)--host/\1-v --host/' "$YAML"
    grep -q 'gufo serve llm -v --host' "$YAML" || { echo "ERREUR : -v non posé dans $YAML" >&2; exit 2; }
  fi
  DEBUG=0 "$BENCH/agentic.sh" gufo "${CAS[@]}"
  copie sans-cache "${CAS[@]}"
  fin; SAUVE=""
fi

echo "== $(date +%T) bilan des journaux (avant = remesure précédente)"
for sous in avant avec-cache sans-cache; do
  [[ -d "$S/$sous" ]] || continue
  echo "-- $sous"
  bilan "$sous"
done

if ((relance)); then
  echo "== $(date +%T) retour du runtime d'usage réel"
  "$DEPOT/setup-llm.sh" --start 2>&1 | tail -2
fi
echo "== $(date +%T) FIN, journaux dans $S"
