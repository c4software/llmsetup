#!/usr/bin/env bash
# Récupère l'image de gufo et les poids que gufo exige. Depuis le 17/11/2026
# (gufo 0.35.0, #1203), les modèles que gufo propose passent par
# « gufo model install » (lancé dans l'image épinglée) : fichiers, révisions
# et SHA-256 viennent du models.lock.json de son extension, donc de la ligne
# de IMAGE, et non plus de ce script. Ils vont dans
# MODELS_BASE/gufo/models/<id>/ (GUFO_MODELS_DIR), en blobs nommés par leur
# SHA-256 et liés en dur dans le dossier du modèle. Ce que gufo ne propose
# pas (les voix, l'encodeur Heretic) reste en hf download dans MODELS_BASE/gufo.
# Appelé par ./setup-llm.sh --setup <quoi> (runtime gufo actif, ou
# LLM_RUNTIME=gufo), ou seul.
#
# Usage :
#   runtime/gufo/download.sh image       docker pull de l'image (8,3 Go)
#   runtime/gufo/download.sh 27b         qwen27-q4 : Qwen3.8-27B UD-Q4_K_XL unsloth,
#                                        drafter DFlash 2 Q4_K_M z-lab, mmproj BF16 (19,7 Go)
#   runtime/gufo/download.sh flashnext   flash-next-q4 : Flash-Next UD-Q4_K_XL unsloth,
#                                        4 shards, tête MTP shared Q8_0, mmproj BF16 (115 Go)
#   runtime/gufo/download.sh deepseek    deepseek4 : DeepSeek V4 Flash IQ2XXS antirez + DSpark (92,7 Go)
#   runtime/gufo/download.sh tts         Qwen3-TTS 12Hz 1.7B, trois variantes BF16 (≈ 13,5 Go ;
#                                        hf download, gufo ne les propose pas)
#   runtime/gufo/download.sh asr         qwen3-asr : Qwen3-ASR 1.7B BF16 (4,7 Go)
#   runtime/gufo/download.sh qwen-image  qwen-image-2.1 : Qwen-Image-2.1 BF16, pipeline complet
#                                        (33,1 Go ; licence Qwen Research, non commerciale)
#   runtime/gufo/download.sh qwen-image-heretic
#                                        encodeur « abliterated » (≈ 16,3 Go, après
#                                        qwen-image) : la variante 40 étapes servie
#   runtime/gufo/download.sh qwen-image-turbo
#                                        qwen-image-2.1-turbo : Qwen-Image-2.1-Turbo BF16,
#                                        8 étapes (32,5 Go, même licence), indépendant de qwen-image
#   runtime/gufo/download.sh qwen-image-turbo-heretic
#                                        le même encodeur « abliterated » monté sur
#                                        Turbo (rien de plus si qwen-image-heretic est
#                                        fait, après qwen-image-turbo) : la variante
#                                        Turbo servie
#   runtime/gufo/download.sh all         tout ce qui précède
#
# Un modèle déjà installé n'est pas repris : une nouvelle image qui épingle
# d'autres poids ne les fait pas bouger seule (« gufo model update », à la
# main, est une requalification). gufo ne réutilise pas un fichier présent
# sous un autre chemin : avant l'installation, gufo_model lie en dur dans
# blobs/ (même système de fichiers) les fichiers déjà là qu'on lui désigne,
# sous leur SHA-256, et gufo ne télécharge que ce qui manque (vérifié le
# 17/11/2026 : 0 octet pour Qwen3-ASR, même inode que le parc).
#
# La cible du 27B, la tête MTP et le mmproj de Flash-Next sont des fichiers
# que gufo PARTAGE avec le runtime llama-cpp-rocm-strix, dont le --setup les
# télécharge aussi (son lib/models.sh), sous MODELS_BASE/qwen3.8-27b et
# MODELS_BASE/qwen3.8-flash-next. Un runtime devant être autonome
# (runtime/CONTRAT.md), gufo les installe lui-même ; vers_parc les lie en
# dur à ces chemins s'ils manquent, et gufo_model reprend ceux qui y sont
# déjà : une machine déjà peuplée ne retélécharge rien, les deux runtimes
# lisent le même inode. Qwen3-TTS : gufo n'épingle que le code amont, les
# révisions HF ci-dessous sont celles du 25/09/2026.
set -euo pipefail
IMG="${GUFO_IMAGE:-$(<"$(dirname "$(realpath "$0")")/IMAGE")}"
PARC="${MODELS_BASE:-$HOME/models}"
DL="$PARC/gufo"

GM="$DL/models"

# gufo_model <id> [fichier ou dossier déjà présent]... - installe un modèle
# proposé par gufo dans GM. S'il ne l'est pas encore, les fichiers désignés
# (récursivement) sont d'abord liés en dur dans GM/blobs sous leur SHA-256 :
# gufo les reconnaît et ne télécharge que le reste. Un chemin absent est
# ignoré ; un lien impossible (autre système de fichiers) aussi, le fichier
# est alors téléchargé. HF_TOKEN est transmis s'il est posé.
gufo_model() {
  local id="$1" f s
  shift
  mkdir -p "$GM/blobs"
  if ! grep -qs "\"id\": *\"$id\"" "$GM/installed.json"; then
    while IFS= read -r -d '' f; do
      s="$(sha256sum "$f" | cut -d' ' -f1)"
      [[ -e "$GM/blobs/$s" ]] || ln "$f" "$GM/blobs/$s" 2>/dev/null || true
    done < <(for f in "$@"; do [[ -e "$f" ]] && find "$f" -type f -print0; done)
  fi
  docker run --rm --entrypoint gufo -e GUFO_MODELS_DIR="$GM" \
    ${HF_TOKEN:+-e HF_TOKEN} -v "$GM:$GM" "$IMG" model install "$id"
}

# vers_parc <id> <chemin dans le modèle> <dossier sous MODELS_BASE> - lie en
# dur un fichier installé par gufo au chemin où le runtime
# llama-cpp-rocm-strix l'attend (même chemin relatif), s'il n'y est pas.
vers_parc() {
  local dst="$PARC/$3/$2"
  [[ -e "$dst" ]] && return 0
  mkdir -p "$(dirname "$dst")"
  ln "$GM/$1/$2" "$dst"
}

# heretic <pipeline> <variante> <cible du pipeline> - monte l'encodeur de
# texte Qwen3-VL de Qwen-Image passé par l'abliteration de Heretic
# (catplusplus, Apache-2.0) sur un pipeline Qwen-Image téléchargé : mêmes 749
# tenseurs BF16, lm_head en moins (inutile à l'encodage). Seuls ses poids
# servent : sa config.json est au format transformers 5 (rope_parameters), que
# gufo refuse ; la config du pipeline décrit la même architecture. gufo exige
# un index des tenseurs, écrit ici depuis l'en-tête du safetensors. Le reste
# du pipeline (transformer, VAE, processeur) : liens vers le pipeline.
heretic() {
  local src="$1" dst="$2" f
  [[ -f "$src/model_index.json" ]] || { echo "$(basename "$src") absent : download.sh $3 d'abord" >&2; exit 1; }
  hf download catplusplus/Qwen21_Text_Encoder_Heretic \
    --revision 7b004403c04dee95a18b959694a3cfdac5b28107 \
    text_encoder/model.safetensors --local-dir "$DL/Qwen21_Text_Encoder_Heretic"
  rm -rf "$dst"; mkdir -p "$dst/text_encoder"
  for f in "$src"/*; do
    [[ "$(basename "$f")" == text_encoder ]] || ln -s "$f" "$dst/"
  done
  ln -s "$src/text_encoder/config.json" "$src/text_encoder/generation_config.json" "$dst/text_encoder/"
  ln -s "$DL/Qwen21_Text_Encoder_Heretic/text_encoder/model.safetensors" "$dst/text_encoder/"
  python3 - "$dst/text_encoder" <<'PY'
import json, struct, sys
d = sys.argv[1]
with open(f"{d}/model.safetensors", "rb") as f:
    h = json.loads(f.read(struct.unpack("<Q", f.read(8))[0]))
h.pop("__metadata__", None)
with open(f"{d}/model.safetensors.index.json", "w") as f:
    json.dump({"metadata": {}, "weight_map": {k: "model.safetensors" for k in sorted(h)}}, f, indent=1)
print(f"index : {len(h)} tenseurs")
PY
}

telecharge() {
  case "$1" in
    image) docker pull "$IMG" ;;
    27b)
      # qwen27-q4 (extension qwen) : cible Unsloth Dynamic 3.1 depuis le
      # 11/11/2026, révision ce331efc que gufo épingle (gufo-org/gufo#1167),
      # 17 659 407 264 octets, sha256 2a5f3565…, mêmes 866 tenseurs que la
      # Dynamic 3.0 du 19/08/2026 (4ca72078, 16,35 Gio) avec d'autres types
      # de quant ; la remplacer a été une requalification, faite sur
      # silentchuck le 12/11/2026. Drafter z-lab 2d9571f, tête du repo le
      # 24/10/2026, le Q4_K_M mesuré le 25/09/2026 (Q8_0 du parc jusqu'au
      # 24/10/2026) ; mmproj à ce331efc, identique à l'octet à celui de
      # 4ca72078. Repris : la cible du parc (partagée) et l'ancien dossier
      # MODELS_BASE/gufo/qwen3.8-27b (avant le 17/11/2026).
      gufo_model qwen27-q4 "$PARC/qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf" "$DL/qwen3.8-27b"
      vers_parc qwen27-q4 Qwen3.8-27B-UD-Q4_K_XL.gguf qwen3.8-27b ;;
    flashnext)
      # flash-next-q4 (extension qwen38_flash_next) : révision Unsloth
      # Dynamic 3.1 d96201194f10, épinglée par gufo depuis la 0.31.0
      # (gufo-org/gufo#1031) : mêmes types et formes de tenseurs que
      # 38bb39ee9782 (celle de nos mesures jusqu'à la 0.29.0), vitesse AR
      # inchangée selon gufo. 4 shards propres à gufo, tête MTP et mmproj
      # partagés avec l'autre runtime. Repris : MTP et mmproj du parc, et
      # l'ancien dossier MODELS_BASE/gufo/qwen3.8-flash-next (avant le
      # 17/11/2026).
      gufo_model flash-next-q4 "$PARC/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf" \
        "$PARC/qwen3.8-flash-next/mmproj-BF16.gguf" "$DL/qwen3.8-flash-next/UD-Q4_K_XL"
      vers_parc flash-next-q4 MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf qwen3.8-flash-next
      vers_parc flash-next-q4 mmproj-BF16.gguf qwen3.8-flash-next ;;
    deepseek)
      # deepseek4 (extension deepseek_v4_flash) : IQ2XXS antirez 1cd7b564,
      # DSpark e7f04037. Repris : les anciens fichiers à la racine de
      # MODELS_BASE/gufo (avant le 17/11/2026).
      gufo_model deepseek4 "$DL/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf" \
        "$DL/DeepSeek-V4-Flash-DSpark-support-0731.gguf" ;;
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
      # qwen3-asr (extension qwen3_asr), révision 7278e1e7. Repris : l'ancien
      # dossier (avant le 17/11/2026).
      gufo_model qwen3-asr "$DL/Qwen3-ASR-1.7B" ;;
    qwen-image)
      # qwen-image-2.1 (extension qwen_image_21), révision b3179ad3. Repris :
      # l'ancien dossier (avant le 17/11/2026).
      gufo_model qwen-image-2.1 "$DL/Qwen-Image-2.1" ;;
    qwen-image-heretic) heretic "$GM/qwen-image-2.1" "$DL/Qwen-Image-2.1-heretic" qwen-image ;;
    qwen-image-turbo-heretic)
      # L'encodeur de Turbo est celui de Qwen-Image-2.1 (configs identiques
      # hors version de transformers, fichier unique au lieu de 4 shards) :
      # l'encodeur Heretic, dérivé de l'officiel, s'y monte tel quel.
      # Identité des tenseurs vérifiée le 08/11/2026 sur silentchuck.
      heretic "$GM/qwen-image-2.1-turbo" "$DL/Qwen-Image-2.1-Turbo-heretic" qwen-image-turbo ;;
    qwen-image-turbo)
      # qwen-image-2.1-turbo (extension qwen_image_21), révision fc13ba19,
      # sans assets/ (images de la fiche). Repris : l'ancien dossier (avant
      # le 17/11/2026).
      gufo_model qwen-image-2.1-turbo "$DL/Qwen-Image-2.1-Turbo" ;;
    *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
  esac
}

mkdir -p "$DL"
if [[ "${1:-}" == all ]]; then
  for quoi in image 27b flashnext deepseek tts asr qwen-image qwen-image-heretic qwen-image-turbo qwen-image-turbo-heretic; do telecharge "$quoi"; done
else
  telecharge "${1:-}"
fi
