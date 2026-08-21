#!/usr/bin/env bash
# =============================================================================
# bench-depth.sh — prefill et décode selon la profondeur de contexte.
#
# Le --bench du service mesure un prefill de ~1500 tokens et un décode à KV
# presque vide. L'usage agentic, lui, vit entre 30k et 100k tokens de contexte
# : l'attention y pèse sur chaque token, le décode chute, le prefill aussi, et
# le classement ROCm0 / Vulkan0 peut s'inverser. Cet outil trace les deux
# courbes par llama-bench -d, hors service, et recalcule à chaque profondeur
# le « tour simulé » de --bench-devices (BENCH_PROFILE_PP/GEN, défaut
# 2000/3000) pour comparer les devices dans le régime réel.
#
# Usage :
#   tools/bench-depth.sh <gguf> [<gguf>...]
#
# Variables d'env :
#   DEV=Vulkan0,ROCm0   devices (défaut Vulkan0 ; chaque GGUF sur chaque device)
#   DEPTHS=0,16384,32768  profondeurs de KV déjà remplies avant la mesure.
#                       65536 est réaliste pour de gros dossiers mais coûte un
#                       prefill de 64k tokens PAR répétition.
#   PP=2048  TG=128     tokens de prefill mesurés / générés à chaque profondeur
#   REPS=2              répétitions (3 pour un chiffre propre, 1 pour dégrossir)
#   CTK=q8_0 CTV=q8_0   types de KV : ceux du service pour les modèles agentic
#                       (le défaut llama-bench est f16/f16, plus rapide et plus
#                       gros, pas ce que sert le routeur)
#   FA=auto             -fa on|off|auto
#   PROFILE_PP=2000 PROFILE_GEN=3000   profil du tour simulé
#   OUT / TSV           journaux (défaut logs/bench-depth.log, logs/bench-depth.tsv)
#
# Arrêter le service avant (il occupe le GPU et la mémoire unifiée) :
#   systemctl --user stop llama-server ; ... ; systemctl --user start llama-server
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$ROOT_DIR/logs"
OUT="${OUT:-$ROOT_DIR/logs/bench-depth.log}"
TSV="${TSV:-$ROOT_DIR/logs/bench-depth.tsv}"

DEV="${DEV:-Vulkan0}"
DEPTHS="${DEPTHS:-0,16384,32768}"
PP="${PP:-2048}"
TG="${TG:-128}"
REPS="${REPS:-2}"
CTK="${CTK:-q8_0}"
CTV="${CTV:-q8_0}"
FA="${FA:-auto}"
PROFILE_PP="${PROFILE_PP:-2000}"
PROFILE_GEN="${PROFILE_GEN:-3000}"

command -v llama-bench >/dev/null || { echo "llama-bench introuvable (paquet llama-cpp)" >&2; exit 1; }
command -v python3     >/dev/null || { echo "python3 introuvable" >&2; exit 1; }
[[ $# -gt 0 ]] || { echo "Usage : tools/bench-depth.sh <gguf> [<gguf>...]" >&2; exit 1; }

# Devices demandés, croisés avec ceux exposés (même garde-fou que bench-spec-batch)
declare -a DEVS=()
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

export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

BUILD="$(llama-server --version 2>&1 | sed -n 's/.*build \([0-9][0-9]*\).*/b\1/p' | head -1)"
TSV_HDR=$'date\tmodele\tdevice\tdepth\tpp_ts\tpp_sd\ttg_ts\ttg_sd\ttour_s'
if [[ ! -s "$TSV" ]]; then
  printf '%s\n' "$TSV_HDR" > "$TSV"
elif [[ "$(head -1 "$TSV")" != "$TSV_HDR" ]]; then
  printf '\n%s\n' "$TSV_HDR" >> "$TSV"
fi

SERVICE_STATE="arrêté"
systemctl --user is-active llama-server &>/dev/null && SERVICE_STATE="EN MARCHE"

{
echo "# bench-depth — $(date '+%F %T')"
echo "# host=$(hostname)  build=${BUILD:-?}  devices=${DEVS[*]}  depths=$DEPTHS  pp=$PP  tg=$TG  reps=$REPS  kv=$CTK/$CTV  fa=$FA"
echo "# service llama-server : $SERVICE_STATE"
[[ "$SERVICE_STATE" == "EN MARCHE" ]] && echo "#   ⚠ contention GPU/mémoire — pour un run propre : systemctl --user stop llama-server"
echo
for gguf in "$@"; do
  [[ -f "$gguf" ]] || { echo "absent, ignoré : $gguf" >&2; continue; }
  declare -A TOURS=()
  for dev in "${DEVS[@]}"; do
    echo "═══ $(basename "$gguf")  [$dev] ═══"
    if ! out="$(llama-bench -m "$gguf" -p "$PP" -n "$TG" -d "$DEPTHS" -r "$REPS" \
                            -ctk "$CTK" -ctv "$CTV" -fa "$FA" -dev "$dev" -o jsonl 2>/dev/null)"; then
      echo "  échec llama-bench (RAM insuffisante à cette profondeur ? arch non supportée ?)"
      echo
      continue
    fi
    rep="$(printf '%s\n' "$out" | python3 "$ROOT_DIR/py/depth_curve.py" \
             "$(basename "$gguf")" "$dev" "$PROFILE_PP" "$PROFILE_GEN" "$TSV" rec)" \
      || { echo "  (analyse en échec)"; echo; continue; }
    echo "$rep" | grep -v '^TOUR_'
    while IFS='=' read -r k v; do TOURS["${k#TOUR_}|$dev"]="$v"; done < <(echo "$rep" | grep '^TOUR_')
    echo
  done
  # Verdict par profondeur quand plusieurs devices : le tour le plus court gagne
  if [[ ${#DEVS[@]} -ge 2 && ${#TOURS[@]} -gt 0 ]]; then
    echo "  Tour simulé par profondeur (s) — le plus court gagne :"
    IFS=',' read -r -a DLIST <<< "$DEPTHS"
    for d in "${DLIST[@]}"; do
      line="  %9d" ; printf "  %9d" "$d"
      best=""; bestv=""
      for dev in "${DEVS[@]}"; do
        v="${TOURS[$d|$dev]:-}"
        printf "  %s=%-7s" "$dev" "${v:-n/a}"
        if [[ -n "$v" ]] && { [[ -z "$bestv" ]] || awk -v a="$v" -v b="$bestv" 'BEGIN{exit !(a<b)}'; }; then
          best="$dev"; bestv="$v"
        fi
      done
      printf "  → %s\n" "${best:-?}"
    done
    echo
  fi
  unset TOURS
done
} 2>&1 | tee -a "$OUT"

echo "→ journal  : $OUT"
echo "→ mesures  : $TSV"
