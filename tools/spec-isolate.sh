#!/usr/bin/env bash
# =============================================================================
# spec-isolate.sh — test isolé d'un réglage spéculatif, hors service et hors
# models.ini, AVANT de le déclarer dans lib/models.sh.
#
# Pourquoi : déclarer un modèle coûte cher (bloc + commentaire métier, ini
# régénéré, restart du service, préchargement) et les questions de l'étape 2 de
# la skill ajout-modele — le drafter se charge-t-il ? quelle acceptance ? quel
# n-max ? — se répondent avec un llama-server jetable sur un port à part.
# Rien n'est écrit dans le ini ni dans les .conf : on monte le serveur avec les
# arguments bruts, on mesure, on tue, on reporte le verdict dans lib/models.sh.
#
# Quand l'utiliser :
#   - nouveau drafter (sidecar MTP, DFlash, DSpark, Eagle) jamais servi ici ;
#   - comparaison de plusieurs --spec-draft-n-max avant d'en déclarer un ;
#   - vérification qu'un GGUF/ moteur donné charge la tête de draft tout court.
# Une fois le réglage retenu : le déclarer dans lib/models.sh, puis le
# CONFIRMER sur le service par ./setup-llm.sh --spec-ab (ou --spec-test), qui
# mesure le modèle tel qu'il est réellement servi.
#
# Usage :
#   tools/spec-isolate.sh <tag> -- <args llama-server...>
#
# Les arguments après « -- » sont passés TELS QUELS à llama-server (-m, -md,
# --spec-type, --spec-draft-n-max, sampling, -c, -ctk/-ctv, -np…) : aucun
# chemin de modèle n'est en dur ici. Le script pose d'abord les flags globaux
# du parc (--device Vulkan0 -ngl 99 -fa on --jinja --host/--port), qui restent
# surchargeables puisque llama-server garde la DERNIÈRE occurrence d'un flag.
#
# Exemple réel — test DSpark sur DeepSeek-V4-Flash du 15/09/2026 :
#   tools/spec-isolate.sh dsv4-dspark3 -- \
#     -m ~/models/deepseek-v4-flash/UD-IQ3_XXS/DeepSeek-V4-Flash-0731-UD-IQ3_XXS-00001-of-00004.gguf \
#     -md ~/models/deepseek-v4-flash/dspark-DeepSeek-V4-Flash-0731-Q8_0.gguf \
#     --spec-type draft-dspark --spec-draft-n-max 3 -c 32768 \
#     --temp 1.0 --top-k 40 --top-p 0.95 --min-p 0 -ctk f16 -ctv f16 --fit off -ngld 99
#
# Variables d'env :
#   PORT=8099       port du serveur jetable (jamais 8009, celui du service)
#   NP=1            slots : -np $NP est TOUJOURS passé (un test isolé se fait à
#                   un slot, pas aux 4 par défaut de llama-server) ; si > 1, le
#                   bench fait en plus une salve de NP requêtes simultanées.
#                   Rappel : le batch de
#                   vérification vaut np x (n-max + 1), à garder <= 8 colonnes
#                   sur ggml-vulkan (cf. en-tête de lib/models.sh).
#   PASSES=2        passes séquentielles par prompt (la 1re est le cache froid)
#   PROMPTS=spec-test.txt,spec-refactor.txt   résolus dans prompts/
#   MAX_TOKENS=1200 max_tokens de chaque requête
#   OUT=logs/spec-isolate/<tag>/              log serveur, générations, TSV
#   LLAMA_BIN_DIR=  dossier de binaires mis en tête du PATH, devant ~/.local/bin :
#                   pour mesurer un build du fork non installé (patch en cours,
#                   build/ à part) sans toucher au moteur servi. Vide = moteur
#                   du service. La ligne « llama-cpp: » de l'en-tête dit lequel
#                   a répondu.
#
# Sorties : OUT/serveur.log (le llama-server jetable), OUT/mesures.tsv (une
# ligne par mesure) et OUT/gen-*.txt (texte généré, à relire quand un chiffre
# semble trop beau). Tout dans logs/, donc non versionné.
#
# Le service llama-server (conteneur) est ARRÊTÉ par le script (un seul GPU) et
# RELANCÉ par son trap, y compris sur Ctrl-C ou sur échec du serveur jetable :
# tout passe par les _svc_* (lib/svc.sh), jamais par docker compose en direct.
# Le serveur jetable, lui, reste un llama-server de L'HÔTE (liens du fork) :
# porter ce test dans l'image est une étape à part.
# =============================================================================
set -euo pipefail

[[ $# -ge 3 && "$2" == "--" ]] || {
  echo "usage : tools/spec-isolate.sh <tag> -- <args llama-server...>" >&2
  exit 2
}
TAG="$1"; shift 2
SRV_ARGS=("$@")

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${PORT:-8099}"
NP="${NP:-1}"
PASSES="${PASSES:-2}"
PROMPTS="${PROMPTS:-spec-test.txt,spec-refactor.txt}"
MAX_TOKENS="${MAX_TOKENS:-1200}"
OUT="${OUT:-$ROOT_DIR/logs/spec-isolate/$TAG}"
LOG="$OUT/serveur.log"

# $HOME/.local/bin en tête, comme le service et lib/common.sh : c'est là que
# vivent les liens du fork strix-llama.cpp. Sans ça on mesurerait le paquet
# Arch en croyant mesurer le moteur servi (défaut réel du 12/09/2026).
# LLAMA_BIN_DIR (optionnel) passe encore devant : un build à part du fork.
export PATH="${LLAMA_BIN_DIR:+$LLAMA_BIN_DIR:}$HOME/.local/bin:$PATH"
# ROCm/HIP sur iGPU : allocations en mémoire unifiée. Moteur de l'HÔTE
# UNIQUEMENT : cette variable ne doit JAMAIS être passée à _dk_run
# (lib/runtime.sh) ni au compose du service : sur le runtime retained-PM4 de
# l'image elle corrompt la sortie (cf. runtime/AMONT.md et lib/compose.sh).
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

# Modules du dépôt : seuls les _svc_* sont nécessaires (arrêt et relance du
# service le temps de la mesure), mais ils s'appuient sur common (helpers,
# SERVICE_NAME, CONFIG_DIR), runtime (image) et compose (chemin du compose).
# lib/common.sh attend SCRIPT_DIR = racine du dépôt, comme pour setup-llm.sh ;
# il repose $HOME/.local/bin en tête du PATH, ce que ce script fait déjà
# ci-dessus (LLAMA_BIN_DIR passe toujours devant).
SCRIPT_DIR="$ROOT_DIR"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/runtime.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/compose.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/svc.sh"

# Mode d'alimentation de l'APU appliqué par le contrôleur embarqué. La lecture
# est refaite ici plutôt qu'appelée par _ec_power_mode : ce script écrit ses
# propres en-têtes et veut la valeur brute, sans les messages du dépôt.
# Journalisé parce qu'un run en "balanced" perd 10 à 13 %
# de décode (mesuré le 16/09/2026) et ne se compare donc qu'à même mode. Jamais
# bloquant : "inconnu" et un avertissement si le sysfs ne répond pas.
EC_POWER_MODE_FILE="${EC_POWER_MODE_FILE:-/sys/class/ec_su_axb35/apu/power_mode}"
EC_MODE="$(tr -d '[:space:]' < "$EC_POWER_MODE_FILE" 2>/dev/null || true)"
[[ -n "$EC_MODE" ]] || {
  EC_MODE="inconnu"
  echo "mode d'alimentation EC illisible ($EC_POWER_MODE_FILE) : journalisé \"inconnu\"" >&2
}

command -v llama-server >/dev/null || { echo "llama-server introuvable" >&2; exit 1; }
command -v python3      >/dev/null || { echo "python3 introuvable" >&2; exit 1; }

# --- Garde-fou : une seule mesure à la fois sur la machine (un seul GPU) -----
# Une mesure du dépôt qui tourne en parallèle fausserait les deux : celle-ci
# par contention, l'autre en perdant son service sous les pieds.
# Motif ANCRÉ sur le début de la ligne de commande (interpréteur optionnel,
# puis le chemin du script) : un « pgrep -f "setup-llm.sh --bench …" » laissé
# dans un shell d'attente contient la chaîne et ferait un refus à tort
# (constaté sur bigchuck le 15/09/2026, deux boucles zsh oubliées). Le service
# lui-même (« bash …/setup-llm.sh --start ») ne matche pas non plus.
MESURE_RE='^([^ ]*sh )?[^ ]*setup-llm\.sh --(bench|spec)'
if pgrep -f "$MESURE_RE" >/dev/null 2>&1; then
  echo "REFUS : une mesure du dépôt tourne déjà (setup-llm.sh --bench* / --spec*)." >&2
  pgrep -af "$MESURE_RE" >&2 || true
  echo "Attendre sa fin (un seul GPU), puis relancer." >&2
  exit 1
fi
if command -v docker >/dev/null 2>&1 \
   && docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^bench-agentic-'; then
  echo "REFUS : un conteneur bench-agentic-* tourne (--bench-agentic en cours)." >&2
  docker ps --format '  {{.Names}}' | grep '^  bench-agentic-' >&2 || true
  echo "Attendre sa fin (un seul GPU), puis relancer." >&2
  exit 1
fi

mkdir -p "$OUT"
SRV_PID=""

# Le service est arrêté pour libérer le GPU, et remis en marche quoi qu'il
# arrive : sortie normale, erreur (set -e), Ctrl-C ou TERM.
_fin() {
  local rc=$?
  trap - EXIT INT TERM
  if [[ -n "$SRV_PID" ]] && kill -0 "$SRV_PID" 2>/dev/null; then
    kill "$SRV_PID" 2>/dev/null || true
    wait "$SRV_PID" 2>/dev/null || true
  fi
  echo ""
  echo "→ relance du service llama-server…"
  _svc_start || echo "  ÉCHEC du redémarrage : ./setup-llm.sh --start" >&2
  exit "$rc"
}
trap _fin EXIT INT TERM

echo "# spec-isolate — $(date '+%F %T')  tag=$TAG"
echo "# host=$(hostname)  port=$PORT  np=$NP  passes=$PASSES  max_tokens=$MAX_TOKENS"
echo "# llama-cpp: $(llama-server --version 2>&1 | head -1 || true)  ($(command -v llama-server))"
echo "# mode EC  : $EC_MODE (alimentation de l'APU ; ne comparer qu'à même mode)"
echo "# args     : ${SRV_ARGS[*]}"
echo ""
echo "→ arrêt du service llama-server (un seul GPU)…"
_svc_stop || true
sleep 3

# Flags globaux du parc D'ABORD, args de l'appelant ENSUITE : llama-server
# retient la dernière occurrence, donc tout est surchargeable depuis la ligne
# de commande sans toucher au script.
# (pas de « [[ … ]] && … » en fin de portée : sous set -e un test faux tuerait
#  le script — piège documenté dans AGENTS.md.)
declare -a NPARG=(-np "$NP")
llama-server --device Vulkan0 -ngl 99 -fa on --jinja \
             "${SRV_ARGS[@]}" "${NPARG[@]}" \
             --host 127.0.0.1 --port "$PORT" > "$LOG" 2>&1 &
SRV_PID=$!

# Attente du /health : 600 s (un gros MoE en IQ3 met plusieurs minutes à
# mapper ses shards). Sortie immédiate si le processus meurt : c'est le cas
# fréquent d'un drafter incompatible, et le message utile est dans le log.
echo "→ attente de /health (600 s max)…"
pret=0
for ((i = 1; i <= 200; i++)); do
  if curl -s "localhost:$PORT/health" 2>/dev/null | grep -q '"ok"'; then pret=1; break; fi
  if ! kill -0 "$SRV_PID" 2>/dev/null; then
    echo "SERVEUR MORT après ~$((i * 3)) s — fin du log ($LOG) :" >&2
    tail -40 "$LOG" >&2
    SRV_PID=""
    exit 1
  fi
  sleep 3
done
[[ "$pret" -eq 1 ]] || { echo "TIMEOUT (600 s) — fin du log ($LOG) :" >&2; tail -40 "$LOG" >&2; exit 1; }
echo "→ prêt après ~$((i * 3)) s"

echo ""
echo "--- mémoire (free -g) :"
free -g | sed -n 2p
echo ""
echo "--- log du serveur (spéculation, drafter, erreurs) :"
# Les lignes « slot launch/release/update/print » sont du trafic normal, elles
# noieraient le reste : filtrées.
grep -iE 'speculativ|draft|mtp|nextn|dflash|dspark|ngram|n_parallel|n_slots|error|failed|warn' "$LOG" \
  | grep -viE 'slot (launch|release|update|print)' | head -30 || true

echo ""
python3 "$ROOT_DIR/py/spec_isolate_bench.py" \
  --port "$PORT" --tag "$TAG" --out "$OUT" \
  --prompts "$PROMPTS" --passes "$PASSES" --max-tokens "$MAX_TOKENS" --np "$NP" \
  --ec-mode "$EC_MODE"

echo ""
echo "--- mémoire après mesures (free -g) :"
free -g | sed -n 2p
echo ""
echo "→ log serveur : $LOG"
echo "→ à faire : reporter ces chiffres (date, moteur, mode EC, device, quant) dans le"
echo "  commentaire du bloc lib/models.sh, déclarer le réglage, puis CONFIRMER"
echo "  sur le service par ./setup-llm.sh --spec-ab <modèle> <n> - <variante>"
echo "  (ou --spec-test), qui mesure le modèle tel qu'il est réellement servi."
