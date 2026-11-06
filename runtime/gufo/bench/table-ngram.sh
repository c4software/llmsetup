#!/usr/bin/env bash
# Variantes de la table n-gram (engram) de Flash-Next UD-Q4_K_XL comparées par
# divergence.py : chaque table est posée à la place du shard 4/4, gufo la
# sert le temps d'une collecte (run.sh, MESURE=divergence), puis toutes sont
# comparées à la première. Rien de versionné ne change ; le shard d'origine
# est restauré par trap, puis le runtime d'usage réel relancé s'il tournait.
#
# Usage (sur la machine du service, machine libre) :
#   runtime/gufo/bench/table-ngram.sh <table>...
#   tables : iq4_nl (celle livrée dans le shard 4, sans téléchargement),
#            q8_0 (54,4 Go), bf16 (102,4 Go, sans perte) ; une table peut
#            être répétée, la première est la référence. Conseillé :
#            bf16 bf16 q8_0 iq4_nl (la seconde bf16 donne le plancher de bruit)
#   TAG=…  dossier des collectes (défaut <date-heure>-<version de GUFO_IMAGE>)
#
# Origine (06/11/2026) : la révision Unsloth Dynamic 3.1 (d96201194f10, celle
# de download.sh) range la table, 160 x 320 001 536 valeurs, dans son propre
# shard et publie dans engram/ des tables de rechange (README de ce dossier) ;
# gufo lit IQ4_NL, Q8_0 et BF16 (src/models/qwen38_flash_next/ngram.cpp, pas
# Q5_1), par lecture directe sur le disque, hors RAM. A/B du jour en Q8_0 :
# débits et 16/16 inchangés, d'où cette mesure de qualité.
#
# Tables dans MODELS_BASE/gufo/qwen3.8-flash-next/engram/, vérifiées par leur
# SHA-256 publié (révision d96201) puis numérotées 4 sur 4 par le set_split.py
# d'Unsloth (deux valeurs d'en-tête, split.no et split.count) ; un fichier
# <table>.ok marque une table vérifiée et numérotée. Collectes dans
# GUFO_DATA/resultats/divergence/<TAG>/, bilan ajouté à
# GUFO_DATA/resultats/divergence.tsv.
set -euo pipefail
DEPOT="$(realpath "$(dirname "$(realpath "$0")")/../../..")"
BENCH="$DEPOT/runtime/gufo/bench"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
M="${MODELS_BASE:-$HOME/models}/gufo/qwen3.8-flash-next"
S="$M/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00004-of-00004.gguf"
REV=d96201194f103c906994f283f504209dc8d2a10c
declare -A SHA=(
  [q8_0]=e3d76a2747c1fe53e3420d1bb7fd9593aafd03035fee4926317db80ad5c5296a
  [bf16]=fd191dd766b7b9616bc648dad1d9dec7bff7cf0a6d27cb2c9edcde9be2aef966
)
declare -A NOM=([q8_0]=Q8_0 [bf16]=BF16)

usage() { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
(($# > 0)) || usage
for t in "$@"; do
  [[ "$t" == iq4_nl || -n "${SHA[$t]:-}" ]] || { echo "table inconnue : $t" >&2; usage; }
done

image="${GUFO_IMAGE:-$(<"$DEPOT/runtime/gufo/IMAGE")}"
TAG="${TAG:-$(date +%F-%H%M)-${image##*:}}"
D="$GUFO_DATA/resultats/divergence/$TAG"
mkdir -p "$D"

fichier() { echo "$M/engram/Qwen3.8-Flash-Next-engram-${NOM[$1]}.gguf_file"; }

preparer() {  # preparer <table> : téléchargée, vérifiée, numérotée 4 sur 4
  local f; f="$(fichier "$1")"
  if [[ -f "$f.ok" ]]; then return 0; fi
  hf download unsloth/Qwen3.8-Flash-Next-GGUF --revision "$REV" \
    --include "engram/${f##*/}" --include "engram/set_split.py" --local-dir "$M"
  echo "${SHA[$1]}  $f" | sha256sum -c -
  python3 -I "$M/engram/set_split.py" "$f" 4 4
  touch "$f.ok"
}

restaure() {
  if [[ -L "$S" ]]; then rm -f "$S"; fi
  if [[ -f "$S.iq4nl" && ! -e "$S" ]]; then mv "$S.iq4nl" "$S"; fi
  return 0
}

poser() {  # poser <table> : la table servie par le shard 4
  restaure
  [[ "$1" == iq4_nl ]] && return 0
  mv "$S" "$S.iq4nl"
  ln -s "../engram/$(basename "$(fichier "$1")")" "$S"
}

# État de départ attendu : le shard d'origine, aucun lien laissé par une
# exécution interrompue sans trap (sinon restaure s'en charge plus bas).
[[ -f "$S" || -f "$S.iq4nl" ]] || { echo "ERREUR : shard 4 introuvable : $S" >&2; exit 1; }

relance=0
if "$DEPOT/setup-llm.sh" --en-marche; then relance=1; fi
export BANC_SANS_RELANCE=1
trap restaure EXIT

echo "== $(date +%T) tables : $* ($image), collectes dans $D"
for t in $(printf '%s\n' "$@" | sort -u); do
  [[ "$t" == iq4_nl ]] || preparer "$t"
done

n=0; collectes=()
attendus=$(grep -c '^====$' "$DEPOT/prompts/divergence.txt"); attendus=$((attendus + 1))
for t in "$@"; do
  n=$((n + 1))
  sortie="$D/$n-$t.jsonl"
  echo "== $(date +%T) collecte $n : table $t"
  poser "$t"
  ls -l "$S"
  MESURE=divergence DIVERGENCE_SORTIE="$sortie" SUFFIXE="-ngram-$t" \
    "$BENCH/run.sh" gufo flashnext
  if [[ ! -f "$sortie" ]] || (($(wc -l <"$sortie") != attendus)); then
    echo "ERREUR : collecte $n incomplète ($sortie), arrêt" >&2
    exit 1
  fi
  collectes+=("$sortie")
done
restaure
echo "== $(date +%T) shard 4 d'origine en place : $(ls -l "$S")"

echo "== $(date +%T) comparaison à la collecte 1"
python3 "$BENCH/divergence.py" compare "${collectes[@]}" \
  --tsv "$GUFO_DATA/resultats/divergence.tsv" --image "$image"

if ((relance)); then
  echo "== $(date +%T) retour du runtime d'usage réel"
  "$DEPOT/setup-llm.sh" --start 2>&1 | tail -2
fi
echo "== $(date +%T) FIN"
