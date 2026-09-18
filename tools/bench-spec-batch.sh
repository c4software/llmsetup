#!/usr/bin/env bash
# =============================================================================
# bench-spec-batch.sh — coût d'un forward selon la taille du batch.
#
# Balayage brut sur un ou plusieurs GGUF, hors du service : utile pour explorer
# (comparer deux backends, deux quants, raffiner autour d'une marche). Toute
# l'analyse vit dans py/batch_curve.py — voir son commentaire de tête pour le
# fond (marches de noyau ggml, batch = size_m + 1, régimes sûr/large).
#
# Pour RÉGLER un modèle, préférer ./setup-llm.sh --spec-ngram-tune : il prend le
# device effectif du modèle, raffine autour de la marche tout seul, départage
# les candidats par une mesure de bout en bout et persiste le résultat.
#
# Usage :
#   tools/bench-spec-batch.sh                    # tous les GGUF présents
#   tools/bench-spec-batch.sh <gguf> [<gguf>...] # modèles précis
#
# Variables d'env :
#   DEV=ROCm0        device(s) ggml séparés par des virgules (défaut : ROCm0,
#                    le seul que l'image expose) ; "auto" = ggml choisit.
#                    Chaque modèle est mesuré sur chaque device.
#   IMAGE=           image docker à mesurer (défaut : celle du service)
#   OUT=<fichier>    journal lisible, en APPEND (défaut : logs/spec-batch.log,
#                    comme les autres journaux). La sortie reste affichée à
#                    l'écran en même temps.
#   TSV=<fichier>    mêmes mesures en TSV pour analyse (défaut : logs/spec-batch.tsv)
#   DEPTH=0          tokens de contexte déjà en KV avant la mesure.
#                    0 = rapide, isole le coût des poids (suffit à classer
#                    dense/MoE). 32768 = réaliste agentic mais TRÈS lent
#                    (un prefill par test) — à réserver aux finalistes.
#   BATCHES=1,8,16,32,48
#   REPS=5
#   FA=auto          -fa on|off|auto
# =============================================================================
set -euo pipefail

# Racine du dépôt = parent de tools/ ; les journaux vivent dans logs/ comme
# ceux de setup-llm.sh (locaux, .gitignore).
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# MODELS_BASE de l'appelant, relevé AVANT de sourcer lib/common.sh : celui-ci
# repositionne la variable sur ~/models sans condition, et la surcharge par
# l'environnement (documentée ci-dessus) serait perdue.
_MODELS_BASE_ENV="${MODELS_BASE:-}"
# Modules du dépôt : _svc_is_active (état du service, journalisé avec la mesure)
# et _dk_run (llama-bench tourne dans l'image depuis le 18/09/2026, retrait du
# fork). lib/common.sh attend SCRIPT_DIR = racine du dépôt.
SCRIPT_DIR="$ROOT_DIR"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/runtime.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/compose.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/svc.sh"
mkdir -p "$ROOT_DIR/logs"
OUT="${OUT:-$ROOT_DIR/logs/spec-batch.log}"
TSV="${TSV:-$ROOT_DIR/logs/spec-batch.tsv}"

MODELS_BASE="${_MODELS_BASE_ENV:-$MODELS_BASE}"
DEV="${DEV:-ROCm0}"
DEPTH="${DEPTH:-0}"
BATCHES="${BATCHES:-1,8,16,32,48}"
REPS="${REPS:-5}"
FA="${FA:-auto}"

command -v docker  >/dev/null || { echo "docker introuvable" >&2; exit 1; }
command -v python3 >/dev/null || { echo "python3 introuvable" >&2; exit 1; }

# IMAGE= surcharge l'image mesurée (essai d'un autre moteur), comme dans
# tools/spec-isolate.sh.
if [[ -n "${IMAGE:-}" ]]; then
  IMAGE_NAME="${IMAGE%%:*}"
  [[ "$IMAGE" == *:* ]] && IMAGE_TAG="${IMAGE##*:}"
fi
_image_ref >/dev/null 2>&1 \
  || { echo "Aucune image ${IMAGE_NAME:-llm-rocm-strix}:$(_image_tag) ici - ./setup-llm.sh --image-build" >&2; exit 1; }

# Modèles : argv, sinon tous les .gguf sous $MODELS_BASE (1er shard seulement)
declare -a GGUFS=()
if [[ $# -gt 0 ]]; then
  GGUFS=("$@")
else
  while IFS= read -r f; do
    # shards : ne garder que le 00001-of-*, llama-bench charge la suite tout seul
    [[ "$f" =~ -0*[2-9][0-9]*-of-[0-9]+\.gguf$ ]] && continue
    GGUFS+=("$f")
  done < <(find "$MODELS_BASE" -name '*.gguf' -type f 2>/dev/null | sort)
fi

[[ ${#GGUFS[@]} -gt 0 ]] || { echo "Aucun GGUF trouvé sous $MODELS_BASE" >&2; exit 1; }

# Devices demandés, croisés avec ceux réellement exposés par l'image : un
# device absent donnerait un llama-bench en échec sans dire pourquoi.
declare -a DEVS=()
if [[ "$DEV" == "auto" ]]; then
  DEVS=("auto")
else
  exposed="$(_dk_run llama-bench --list-devices 2>/dev/null || true)"
  IFS=',' read -r -a want <<< "$DEV"
  for d in "${want[@]}"; do
    if [[ -z "$exposed" ]] || grep -q "$d" <<<"$exposed"; then
      DEVS+=("$d")
    else
      echo "device '$d' non exposé (llama-bench --list-devices), ignoré." >&2
    fi
  done
  [[ ${#DEVS[@]} -gt 0 ]] || { echo "Aucun device demandé n'est exposé." >&2; exit 1; }
fi

# (GGML_CUDA_ENABLE_UNIFIED_MEMORY était exporté ici du temps du moteur de
#  l'hôte. INTERDIT sur ce runtime : sur le retained-PM4 de l'image elle fait
#  passer chaque allocation par hipMallocManaged et la sortie se corrompt,
#  cf. runtime/AMONT.md.)

# En-tête TSV. Si un fichier existe avec un autre jeu de colonnes (ancienne
# version du script), on ré-écrit une ligne d'en-tête avant les nouvelles
# lignes plutôt que d'écraser des mesures déjà collectées.
TSV_HDR=$'date\tmodele\tdevice\tdepth\tfa_reel\tbatch\tt_forward_ms\tsd_ms\tcout_rel\tgain_max'
if [[ ! -s "$TSV" ]]; then
  printf '%s\n' "$TSV_HDR" > "$TSV"
elif [[ "$(head -1 "$TSV")" != "$TSV_HDR" ]]; then
  printf '\n%s\n' "$TSV_HDR" >> "$TSV"
fi

# L'état du service est relevé ici mais journalisé DANS le bloc tee : une mesure
# dont on ignore si le service tournait n'est pas comparable à une autre.
SERVICE_STATE="arrêté"
_svc_is_active && SERVICE_STATE="EN MARCHE"

{
echo "# bench-spec-batch — $(date '+%F %T')"
echo "# host=$(hostname)  devices=${DEVS[*]}  depth=$DEPTH  batches=$BATCHES  reps=$REPS  fa=$FA"
echo "# moteur   : $(_llama_build)  (image ${IMAGE_NAME}:$(_image_tag))"
echo "# service llama-server : $SERVICE_STATE"
if [[ "$SERVICE_STATE" == "EN MARCHE" ]]; then
  echo "#   ⚠ contention GPU/mémoire — pour un run propre :"
  echo "#     ./setup-llm.sh --stop"
fi
echo
echo "# NB : les points à gros batch sont bornés compute et donc sensibles à"
echo "#      l'état thermique. Un balayage enchaîné juste après un autre mesure"
echo "#      une puce chaude : c'est le régime soutenu, pas le pic à froid."
echo

for gguf in "${GGUFS[@]}"; do
 [[ -f "$gguf" ]] || { echo "absent, ignoré : $gguf" >&2; continue; }
 for dev in "${DEVS[@]}"; do
  declare -a DEVARG=()
  [[ "$dev" != "auto" ]] && DEVARG=(-dev "$dev")
  echo "═══ $(basename "$gguf")  [$dev] ═══"
  if ! out="$(_dk_run llama-bench -m "$gguf" -p "$BATCHES" -n 0 -d "$DEPTH" \
                          -r "$REPS" -fa "$FA" "${DEVARG[@]}" -o jsonl 2>/dev/null)"; then
    echo "  échec llama-bench (RAM insuffisante ? arch non supportée par ce backend ?)"
    echo
    continue
  fi
  printf '%s\n' "$out" \
    | python3 "$ROOT_DIR/py/batch_curve.py" "$(basename "$gguf")" "$dev" "$DEPTH" "$TSV" \
    || echo "  (analyse en échec — mesures brutes conservées dans $OUT)"
  echo
 done
done
} 2>&1 | tee -a "$OUT"

echo "→ journal  : $OUT"
echo "→ mesures  : $TSV"
