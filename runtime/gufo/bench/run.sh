#!/usr/bin/env bash
# Banc HTTP gufo contre le service llm-setup : mêmes requêtes aux deux moteurs
# (mesure.py : justesse, conditions du --bench, spec-refactor, prefill long avec
# aiguille, reprise de cache au tour 2). Résultats dans GUFO_DATA/resultats/.
#
# Usage :
#   runtime/gufo/bench/run.sh gufo  <cas>...   gufo sur :8009 ; le runtime qui
#                                              servait est arrêté, et relancé
#                                              à la sortie (trap)
#   runtime/gufo/bench/run.sh llama <cas>...   la section équivalente du runtime
#                                              llama-cpp-rocm-strix, lancé s'il
#                                              ne tourne pas
#
# Cas gufo : 27b, flashnext, deepseek (modèles de runtime/gufo/gufo-llama-swap.yaml,
# gufo lancé derrière llama-swap, le modèle du cas préchargé)
# Cas llama : 27b, flashnext, flashnext-large-ub, deepseek
#
# Réglage gufo de ce banc : celui du compose (cache disque compris), 1 session
# (SESSIONS=N), port 8009 (celui du service, exclusifs), sans redémarrage
# automatique. Le runtime d'usage réel (gufo ou llama-server) est arrêté au
# départ et relancé à la fin s'il tournait. Chaque requête a un préfixe aléatoire, le cache disque ne sert donc pas ici ; les mesures du
# 24/09/2026 ont été faites sans lui (la seule différence, les écritures de
# points de reprise, n'entre pas dans le premier token).
set -euo pipefail
DEPOT="$(realpath "$(dirname "$(realpath "$0")")/../../..")"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
PORT=8009
# gufo du banc : compose de runtime/gufo/, lancé par le point d'entrée
# (LLM_RUNTIME=gufo ./setup-llm.sh --start <cas>) sur le même port que l'usage
# réel (ils sont exclusifs), sans redémarrage automatique, avec projet,
# conteneur et .env séparés de ceux de l'usage réel.
export GUFO_DATA GUFO_PORT=$PORT GUFO_RESTART=no GUFO_SESSIONS="${SESSIONS:-1}" \
  GUFO_PROJET=gufo-banc GUFO_CONTENEUR=gufo-banc GUFO_ENV_FILE="$GUFO_DATA/banc.env"
RES="$GUFO_DATA/resultats"
mkdir -p "$RES"
STOPPE=0
RELANCE=0
LLAMA_LANCE=0

# Trois façons d'appeler le point d'entrée :
#   banc   le runtime gufo, avec les valeurs du banc exportées plus haut
#          (projet, conteneur et .env à part) ;
#   reel   le runtime ACTIF de la machine (runtime.conf), tel qu'il sert en
#          usage réel : sans LLM_RUNTIME et sans aucune valeur du banc, qui
#          sinon repartirait avec lui s'il s'agit de gufo ;
#   llama  le runtime llama-cpp-rocm-strix, pour les cas « llama ».
SANS_BANC=(env -u LLM_RUNTIME -u GUFO_PORT -u GUFO_RESTART -u GUFO_SESSIONS
           -u GUFO_PROJET -u GUFO_CONTENEUR -u GUFO_ENV_FILE)
banc()  { LLM_RUNTIME=gufo "$DEPOT/setup-llm.sh" "$@"; }
reel()  { "${SANS_BANC[@]}" "$DEPOT/setup-llm.sh" "$@"; }
llama() { "${SANS_BANC[@]}" LLM_RUNTIME=llama-cpp-rocm-strix "$DEPOT/setup-llm.sh" "$@"; }

# liberer - une fois par exécution : note si le runtime d'usage réel tournait
# (il sera relancé à la sortie), puis l'arrête. Le port et le GPU sont au banc.
liberer() {
  if ((STOPPE)); then return 0; fi
  if reel --en-marche; then RELANCE=1; fi
  reel --stop || true
  # Filet : un gufo d'usage réel lancé sans être le runtime actif
  # (LLM_RUNTIME=gufo ./setup-llm.sh --start) tiendrait le port du banc.
  "${SANS_BANC[@]}" LLM_RUNTIME=gufo "$DEPOT/setup-llm.sh" --stop >/dev/null 2>&1 || true
  STOPPE=1
}

fin() {
  banc --stop >/dev/null 2>&1 || true
  # Rendre la machine comme on l'a trouvée : le runtime d'usage réel relancé
  # s'il tournait au départ (gufo reprend le modèle préchargé de son .env),
  # sinon le llama-server lancé pour un cas « llama » arrêté.
  # BANC_SANS_RELANCE=1 (remesure.sh, qui enchaîne plusieurs bancs et relance
  # lui-même à la fin) : rien n'est relancé ici.
  if [[ "${BANC_SANS_RELANCE:-0}" != 1 ]]; then
    if ((RELANCE)); then
      reel --en-marche || reel --start || true
    elif ((LLAMA_LANCE)); then
      llama --stop >/dev/null 2>&1 || true
    fi
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
  liberer
  t0=$(date +%s.%N)
  if ! banc --start "$cas" >"$RES/$label.lancement.log" 2>&1; then
    echo "ÉCHEC du démarrage de $label :"; tail -25 "$RES/$label.lancement.log"
    return 1
  fi
  t1=$(date +%s.%N)
  printf '%s\t%s\tchargement %.1f s\n' "$(date +%FT%T)" "$label" \
    "$(awk -v a="$t0" -v b="$t1" 'BEGIN{print b-a}')" | tee -a "$RES/chargements.tsv"
  nom_modele="$(modele_gufo "$cas")"
  python3 "$DEPOT/runtime/gufo/bench/mesure.py" "http://localhost:$PORT" "$nom_modele" "$label" "$RES" "$DEPOT/prompts" || true
  printf '%s\t%s\tmémoire utilisée %s Mio\n' "$(date +%FT%T)" "$label" \
    "$(free -m | awk '/^Mem/{print $3}')" | tee -a "$RES/chargements.tsv"
  docker logs "$GUFO_CONTENEUR" >"$RES/$label.log" 2>&1
  banc --stop >/dev/null
}

run_llama() {
  local cas="$1" label="llama-$1" sec
  sec="$(section "$cas")"
  # Le llama-server doit tenir le port : le lancer s'il ne tourne pas (le
  # pilotage arrête alors gufo, banc ou usage réel, noté par liberer).
  if ! llama --en-marche; then
    liberer
    banc --stop >/dev/null 2>&1 || true
    llama --start
    LLAMA_LANCE=1
  fi
  python3 "$DEPOT/runtime/gufo/bench/mesure.py" "http://localhost:8009" "$sec" "$label" "$RES" "$DEPOT/prompts" || true
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
