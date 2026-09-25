#!/usr/bin/env bash
# Récupère l'image de gufo et les poids que gufo exige, aux révisions épinglées
# par ses guides de modèles (docs/models/*/README.md du dépôt gufo), dans
# GUFO_DATA/models (défaut ~/llm/gufo-test/models).
# Appelé par ./setup-llm.sh --gufo-download, ou seul.
#
# Usage :
#   runtime-gufo/download.sh image       docker pull de l'image (8,3 Go)
#   runtime-gufo/download.sh flashnext   Flash-Next UD-Q4_K_XL unsloth, 4 shards (≈ 104 Go)
#   runtime-gufo/download.sh deepseek    DeepSeek V4 Flash IQ2XXS antirez + DSpark (≈ 93 Go)
#   runtime-gufo/download.sh tts         Qwen3-TTS 12Hz 1.7B, trois variantes BF16 (≈ 13,5 Go)
#   runtime-gufo/download.sh asr         Qwen3-ASR 1.7B BF16 (≈ 4,7 Go)
#   runtime-gufo/download.sh qwen-image  Qwen-Image-2.1 BF16, pipeline complet (≈ 33,1 Go ;
#                                        licence Qwen Research, non commerciale)
#   runtime-gufo/download.sh all         tout ce qui précède
#
# Le 27B (cible et drafter DFlash 2 Q8_0), la tête MTP et le mmproj de
# Flash-Next viennent du parc
# (./setup-llm.sh --setup) : rien à télécharger pour eux. hf ne re-télécharge
# pas un fichier déjà présent. Qwen3-TTS : gufo n'épingle que le code amont,
# les révisions HF ci-dessous sont celles du 25/09/2026.
set -euo pipefail
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
IMG="${GUFO_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime:latest}"
DL="$GUFO_DATA/models"

telecharge() {
  case "$1" in
    image) docker pull "$IMG" ;;
    flashnext)
      hf download unsloth/Qwen3.8-Flash-Next-GGUF \
        --revision 38bb39ee97821de2c9009abb7e93950eec396e66 \
        --include "UD-Q4_K_XL/*" --local-dir "$DL/qwen3.8-flash-next" ;;
    deepseek)
      hf download antirez/deepseek-v4-gguf \
        --revision 1cd7b564460821938add0475a60b942c409295e0 \
        DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf \
        --local-dir "$DL"
      hf download antirez/deepseek-v4-gguf \
        --revision e7f04037032990db0346398d249baf9fb9df1ccc \
        DeepSeek-V4-Flash-DSpark-support-0731.gguf --local-dir "$DL" ;;
    tts)
      hf download Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
        --revision 0c0e3051f131929182e2c023b9537f8b1c68adfe \
        --local-dir "$DL/Qwen3-TTS-12Hz-1.7B-CustomVoice"
      hf download Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
        --revision 5ecdb67327fd37bb2e042aab12ff7391903235d3 \
        --local-dir "$DL/Qwen3-TTS-12Hz-1.7B-VoiceDesign"
      hf download Qwen/Qwen3-TTS-12Hz-1.7B-Base \
        --revision fd4b254389122332181a7c3db7f27e918eec64e3 \
        --local-dir "$DL/Qwen3-TTS-12Hz-1.7B-Base" ;;
    asr)
      hf download Qwen/Qwen3-ASR-1.7B \
        --revision 7278e1e70fe206f11671096ffdd38061171dd6e5 \
        --local-dir "$DL/Qwen3-ASR-1.7B" ;;
    qwen-image)
      hf download Qwen/Qwen-Image-2.1 \
        --revision b3179ad355be050328e483a9dfdd9e60cd62adfa \
        --local-dir "$DL/Qwen-Image-2.1" ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
  esac
}

mkdir -p "$DL"
if [[ "${1:-}" == all ]]; then
  for quoi in image flashnext deepseek tts asr qwen-image; do telecharge "$quoi"; done
else
  telecharge "${1:-}"
fi
