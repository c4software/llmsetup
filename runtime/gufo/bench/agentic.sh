#!/usr/bin/env bash
# Boucle agentique réelle (scénarios pi de bench-agentic/, même image, même
# scenarios.sh) jouée contre gufo ou contre le service, sans rien écrire dans
# logs/bench-agentic.log. Sorties pi et journal gufo dans
# GUFO_DATA/resultats/agentic/.
#
# Usage :
#   runtime/gufo/bench/agentic.sh gufo  <cas>...   gufo sur :8009 ; le runtime qui
#                                                  servait est arrêté, et relancé
#                                                  à la sortie (trap)
#   runtime/gufo/bench/agentic.sh llama <cas>...   la section équivalente du runtime
#                                                  llama-cpp-rocm-strix, lancé s'il
#                                                  ne tourne pas
#   PASSES=N …                                     nombre de passes (défaut 3)
#   PI_SESSIONS=1 …                                garde les sessions pi (JSONL,
#                                                  appels d'outils compris) dans
#                                                  <label>.sessions/ à côté du .out
#   PI_CONSIGNE=texte …                            texte ajouté au prompt système
#                                                  de pi (scenarios.sh), par
#                                                  exemple "$(cat prompts/pi-consigne-edit.txt)" ;
#                                                  image pi à reconstruire si
#                                                  scenarios.sh a changé
#   PI_THINKING=low …                              pi lancé avec --thinking low
#                                                  (ou minimal, medium…) : le
#                                                  raisonnement vient du client,
#                                                  le yaml de gufo reste en
#                                                  --think off
#   PI_GARDE=secondes …                            garde-temps par scénario de
#                                                  scenarios.sh (défaut 300 :
#                                                  au-delà, FAIL et suite)
#   DEBUG=1 …                                      gufo en journal debug : -v ajouté
#                                                  à la macro gufo de
#                                                  gufo-llama-swap.yaml le temps du
#                                                  banc (copie restaurée par trap,
#                                                  refusé si le fichier a des
#                                                  modifications locales)
#
# Cas gufo : 27b, flashnext, deepseek (modèles de runtime/gufo/gufo-llama-swap.yaml,
# gufo lancé derrière llama-swap, le modèle du cas préchargé)
# Cas llama : 27b, flashnext, flashnext-large-ub, deepseek
#
# Réglage gufo de ce banc : celui du compose (cache disque et staging relevé,
# seconde série du 24/09/2026), 1 session (SESSIONS=N pour changer), port
# 8009 (celui du service, exclusifs), sans redémarrage automatique. Le
# runtime d'usage réel (gufo ou llama-server) est arrêté au départ et relancé
# à la fin s'il tournait.
# Sans cache disque, gufo ne reprend pas le préfixe commun des nouvelles
# conversations et perd son avance (docs/GUFO.md). Le /metrics de gufo n'a pas
# les compteurs de cache ni de secondes : pour gufo, les colonnes prompt, cache,
# prefill et décode de pi sont incomplètes, les vraies valeurs sont dans son
# journal (event=completed, une ligne par requête).
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
PASSES="${PASSES:-3}"
RES="$GUFO_DATA/resultats/agentic"
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
YAML="$DEPOT/runtime/gufo/gufo-llama-swap.yaml"
SAUVE=""

fin() {
  if [[ -n "$SAUVE" ]]; then cp -f "$SAUVE" "$YAML"; rm -f "$SAUVE"; fi
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

pi_run() {  # modèle url sortie ; garde-temps : une boucle infinie ne bloque pas le GPU
  local opts=() ses="${3%.out}.sessions"
  if [[ "${PI_SESSIONS:-0}" == 1 ]]; then
    rm -rf "$ses"; mkdir -p "$ses"
    opts=(-v "$ses:/sessions" -e PI_SESSIONS=/sessions)
  fi
  if [[ -n "${PI_CONSIGNE:-}" ]]; then opts+=(-e "PI_CONSIGNE=$PI_CONSIGNE"); fi
  if [[ -n "${PI_THINKING:-}" ]]; then opts+=(-e "PI_THINKING=$PI_THINKING"); fi
  if [[ -n "${PI_GARDE:-}" ]]; then opts+=(-e "PI_GARDE=$PI_GARDE"); fi
  # ${opts[@]+…} : un tableau vide sous set -u casse bash 4.3.
  MODEL="$1" PASSES="$PASSES" SERVER_URL="$2" \
    timeout 3600 docker compose -f "$DEPOT/bench-agentic/docker-compose.yml" run --rm -T \
    ${opts[@]+"${opts[@]}"} pi >"$3" 2>&1 || true
  grep -v $'^TSV\t' "$3" | grep -E 'PASS|FAIL|Résumé|mur' || true
}

run_gufo() {
  local cas="$1" label="gufo-$1" nom_modele
  modele_gufo "$cas" >/dev/null || return 1
  liberer
  if ! banc --start "$cas" >"$RES/$label.lancement.log" 2>&1; then
    echo "ÉCHEC du démarrage de $label :"; tail -25 "$RES/$label.lancement.log"
    return 1
  fi
  nom_modele="$(modele_gufo "$cas")"
  echo "=== $label : pi, $PASSES passes"
  pi_run "$nom_modele" "http://127.0.0.1:$PORT" "$RES/$label.out"
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
  echo "=== $label : pi, $PASSES passes"
  pi_run "$sec" "http://127.0.0.1:8009" "$RES/$label.out"
}

moteur="${1:-}"; shift || true
[[ "$moteur" == gufo || "$moteur" == llama ]] && (($# > 0)) \
  || { sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2; }
if [[ "${DEBUG:-0}" == 1 ]]; then
  if ! git -C "$DEPOT" diff --quiet -- runtime/gufo/gufo-llama-swap.yaml; then
    echo "ERREUR : $YAML a des modifications locales, DEBUG=1 refusé" >&2
    exit 2
  fi
  # -v existe dans toutes les versions de gufo : « Verbose logging » jusqu'en
  # 0.3.0, raccourci de --log-level debug depuis 0.4.0.
  SAUVE="$(mktemp "$GUFO_DATA/gufo-llama-swap.yaml.XXXXXX")"
  cp -f "$YAML" "$SAUVE"
  sed -i 's/^\(    gufo serve llm \)--host/\1-v --host/' "$YAML"
  grep -q 'gufo serve llm -v --host' "$YAML" || { echo "ERREUR : -v non posé dans $YAML" >&2; exit 2; }
fi
for cas in "$@"; do
  case "$moteur" in
    gufo) run_gufo "$cas" || true ;;
    llama) run_llama "$cas" ;;
  esac
done
