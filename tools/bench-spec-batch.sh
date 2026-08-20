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
#   DEV=Vulkan0,ROCm0  device(s) ggml, liste comme --bench-devices (défaut :
#                    Vulkan0, le DEFAULT_DEVICE du models.ini) ; "auto" = ggml
#                    choisit. Chaque modèle est mesuré sur chaque device.
#   OUT=<fichier>    journal lisible, en APPEND (défaut : spec-batch.log à côté
#                    de setup-llm.sh, comme spec-tests.log). La sortie reste
#                    affichée à l'écran en même temps.
#   TSV=<fichier>    mêmes mesures en TSV pour analyse (défaut : spec-batch.tsv)
#   DEPTH=0          tokens de contexte déjà en KV avant la mesure.
#                    0 = rapide, isole le coût des poids (suffit à classer
#                    dense/MoE). 32768 = réaliste agentic mais TRÈS lent
#                    (un prefill par test) — à réserver aux finalistes.
#   BATCHES=1,8,16,32,48
#   REPS=5
#   FA=auto          -fa on|off|auto
# =============================================================================
set -euo pipefail

# Racine du dépôt = parent de tools/ ; les journaux vivent à côté de
# setup-llm.sh comme spec-tests.log / bench-devices.conf (locaux, .gitignore).
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT_DIR/spec-batch.log}"
TSV="${TSV:-$ROOT_DIR/spec-batch.tsv}"

MODELS_BASE="${MODELS_BASE:-$HOME/models}"
DEV="${DEV:-Vulkan0}"
DEPTH="${DEPTH:-0}"
BATCHES="${BATCHES:-1,8,16,32,48}"
REPS="${REPS:-5}"
FA="${FA:-auto}"

command -v llama-bench >/dev/null || { echo "llama-bench introuvable (paquet llama-cpp)" >&2; exit 1; }
command -v python3     >/dev/null || { echo "python3 introuvable" >&2; exit 1; }

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

# Devices demandés, croisés avec ceux réellement exposés par ggml (même
# garde-fou que --bench-devices : sans ggml-hip, ROCm0 n'existe pas).
declare -a DEVS=()
if [[ "$DEV" == "auto" ]]; then
  DEVS=("auto")
else
  exposed="$(llama-bench --list-devices 2>/dev/null || true)"
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

# ROCm/HIP sur iGPU : sans ça les allocations visent la VRAM dédiée (petite)
# au lieu de la mémoire unifiée/GTT — les gros modèles échouent, et surtout on
# ne mesurerait pas ce que fait réellement le service (cf. lib/service.sh).
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

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
systemctl --user is-active llama-server &>/dev/null && SERVICE_STATE="EN MARCHE"

{
echo "# bench-spec-batch — $(date '+%F %T')"
echo "# host=$(hostname)  devices=${DEVS[*]}  depth=$DEPTH  batches=$BATCHES  reps=$REPS  fa=$FA"
echo "# llama-cpp: $(llama-server --version 2>&1 | head -1 || true)"
echo "# service llama-server : $SERVICE_STATE"
if [[ "$SERVICE_STATE" == "EN MARCHE" ]]; then
  echo "#   ⚠ contention GPU/mémoire — pour un run propre :"
  echo "#     systemctl --user stop llama-server"
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
  if ! out="$(llama-bench -m "$gguf" -p "$BATCHES" -n 0 -d "$DEPTH" \
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
