# lib/models.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

# =============================================================================
# MODÈLES (repo + fichier)
# =============================================================================

MODEL_QWEN35_2B_REPO="unsloth/Qwen3.5-2B-GGUF"
MODEL_QWEN35_2B_FILE="Qwen3.5-2B-UD-Q4_K_XL.gguf"

# LFM2.5-2.6B (Liquid AI) — hybride conv récurrente + GQA (arch lfm2),
# agentic edge : tool calling / instruction following, ctx natif 128K.
# Q8_0 officiel LiquidAI (2,87 Go) — modèle minuscule, aucune raison de
# descendre en dessous ; pas de quant unsloth UD à ce jour (repo publié
# le 04/08/2026 avec la sortie du modèle).
MODEL_LFM25_26B_REPO="LiquidAI/LFM2.5-2.6B-GGUF"
MODEL_LFM25_26B_FILE="LFM2.5-2.6B-Q8_0.gguf"

MODEL_QWEN35_9B_REPO="unsloth/Qwen3.5-9B-GGUF"
MODEL_QWEN35_9B_FILE="Qwen3.5-9B-UD-Q6_K_XL.gguf"

# Qwen3.5-9B-MTP — variante MTP, draft intégré (MTP mergé mainline le 16/05/2026)
# Même nom de fichier que le non-MTP (convention unsloth), dossier distinct.
MODEL_QWEN35_9B_MTP_REPO="unsloth/Qwen3.5-9B-MTP-GGUF"
MODEL_QWEN35_9B_MTP_FILE="Qwen3.5-9B-UD-Q6_K_XL.gguf"

MODEL_QWEN36_35B_A3B_REPO="unsloth/Qwen3.6-35B-A3B-GGUF"
MODEL_QWEN36_35B_A3B_FILE="Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf"

MODEL_QWEN3_CODER_NEXT_REPO="unsloth/Qwen3-Coder-Next-GGUF"
MODEL_QWEN3_CODER_NEXT_FILE="Qwen3-Coder-Next-UD-Q4_K_XL.gguf"

# Qwen3.8-27B — dense 27B hybrid-thinking (arch qwen35 : même base GDN + gated
# attention que 3.5/3.6, aucun bump llama.cpp requis), vision native, ctx natif
# 256K (1M via YaRN), Dynamic V3.0 (preview). Remplace TOUTE la famille 3.6-27B
# (base + MTP + Qwopus coder SFT) : SWE-bench Pro 61.7 vs 53.5, QwenSWEBench
# 79.0 vs 49.3, Terminal Bench 2.1 73.0 vs 63.4, IFBench 79.5 vs 69.1.
# MTP : tête MTP embarquée dans le GGUF principal (unsloth : "MTP for fast
#   inference is available", pas de repo -MTP séparé dans la collection Qwen3.8 —
#   seul Qwen3.6 exigeait encore un GGUF MTP à part). Un seul fichier sert donc
#   les modèles non-MTP ET MTP, fini le doublon Q6 + Q4 de la 3.6.
# Quant UD-Q4_K_XL (~16 Go, quant par défaut du guide llama.cpp unsloth) :
#   ~26 % de poids en moins que le Q6 à relire par token → décode ×1,3-1,5
#   (mesuré Q6 : 8,5 t/s brut / 16 t/s MTP → attendu Q4 : ~12 / ~22-25).
#   Coût : ~1-2 pts de top-1 vs Q6 (analyse Dynamic V3 : l'IQ2_XXS de 9 Go
#   garde déjà 82,5 %, la courbe Q4→Q6 est écrasée en haut). Repasser en
#   UD-Q6_K_XL ici + --update qwen3.8-27b si le thinking long en pâtit.
# ⚠ Repo day-zero (mi-août 2026) — template chat et quants encore mouvants,
#   prévoir un --update qwen3.8-27b d'ici quelques jours.
MODEL_QWEN38_27B_REPO="unsloth/Qwen3.8-27B-GGUF"
MODEL_QWEN38_27B_FILE="Qwen3.8-27B-UD-Q4_K_XL.gguf"

# Qwopus3.6-27B-Coder-MTP — fine-tune coder SFT de la 3.6-27B, SWE-bench Verified 67.0%
# Conservé malgré l'arrivée de la 3.8-27B : seul survivant de la famille 3.6-27B,
#   gardé pour son style/coding, pas pour les benchs (la 3.8 native est devant).
# ⚠ Repo "super-squashé" fin juillet 2026 (historique nettoyé, etags changés) :
#   un --update qwopus3.6-27b-coder-mtp re-vérifiera proprement. Une variante
#   Jackrong/Qwopus3.6-27B-Coder-Compat-MTP-GGUF existe aussi si souci de compat.
MODEL_QWOPUS_CODER_MTP_REPO="Jackrong/Qwopus3.6-27B-Coder-MTP-GGUF"
MODEL_QWOPUS_CODER_MTP_FILE="Qwopus3.6-27B-Coder-MTP-Q5_K_M.gguf"

# Gemma 4 31B — MTP drafter embarqué dans le repo principal
# ⚠ Template chat officiel mis à jour par Google mi-juillet 2026 → si téléchargé
#   avant, relancer : ./setup-llm.sh --update gemma-31b
MODEL_GEMMA_31B_REPO="unsloth/gemma-4-31B-it-GGUF"
MODEL_GEMMA_31B_FILE="gemma-4-31B-it-Q4_K_M.gguf"
MODEL_GEMMA_31B_MTP_FILE="mtp-gemma-4-31B-it.gguf"

# Gemma 4 12B — modèle unifié texte+image+audio+vidéo, MTP drafter embarqué
# ⚠ Même remarque template : --update gemma-12b si téléchargé avant mi-juillet 2026
MODEL_GEMMA_12B_REPO="unsloth/gemma-4-12b-it-GGUF"
MODEL_GEMMA_12B_FILE="gemma-4-12b-it-UD-Q4_K_XL.gguf"
MODEL_GEMMA_12B_MTP_FILE="mtp-gemma-4-12b-it.gguf"

# GPT-OSS 120B — shards UD-Q4_K_XL
MODEL_GPTOSS_REPO="unsloth/gpt-oss-120b-GGUF"
MODEL_GPTOSS_FILE_GLOB="UD-Q4_K_XL/*"
MODEL_GPTOSS_FILE_ENTRY="UD-Q4_K_XL/gpt-oss-120b-UD-Q4_K_XL-00001-of-00002.gguf"

# Qwen3.6-35B-A3B-MTP — variante MTP, draft intégré (Q4_K_XL)
MODEL_QWEN36_35B_A3B_MTP_REPO="unsloth/Qwen3.6-35B-A3B-MTP-GGUF"
MODEL_QWEN36_35B_A3B_MTP_FILE="Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"

# DeepSeek-V4-Flash-0731 — MoE 284B (13B actifs), 1M ctx natif, shards UD-IQ3_XXS
# UD-IQ3_XXS (104 Go, reco unsloth pour 128 Go de RAM) : le checkpoint est QAT
# FP4 natif sur les experts (96% des poids), donc le 3-bit est peu destructeur.
# Support llama.cpp mainline depuis fin juin 2026 (PR #24162).
# ⚠ Repo tout frais (squashé le 01/08) — les quants bougent encore, prévoir un
#   --update deepseek-v4-flash d'ici quelques jours.
# Décode ~12,5 t/s sur Strix Halo Vulkan avec ce quant : c'est la baseline
#   communautaire mesurée, bornée bande passante — normal, pas un bug de config.
MODEL_DSV4_FLASH_REPO="unsloth/DeepSeek-V4-Flash-0731-GGUF"
MODEL_DSV4_FLASH_FILE_GLOB="UD-IQ3_XXS/*"
MODEL_DSV4_FLASH_FILE_ENTRY="UD-IQ3_XXS/DeepSeek-V4-Flash-0731-UD-IQ3_XXS-00001-of-00004.gguf"

# Laguna S 2.1 (poolside) — MoE 118B (8B actifs), agentic coding, shards UD-Q4_K_XL
# 73.4 Go / 3 shards.
# ⚠ Quants ré-uploadés fin juillet 2026 par unsloth ("Fix rope/context metadata to
#   256K YaRN (poolside config)" + fixes poolside) → si téléchargé avant :
#   ./setup-llm.sh --update laguna-s-2.1
# Alternative plus légère si la RAM est juste : UD-IQ4_XS (57.6 Go) — changer
#   GLOB + ENTRY en conséquence. (UD-Q4_K_S a été RETIRÉ du repo unsloth ; il ne
#   reste en shards que UD-IQ4_XS, UD-Q3_K_XL, UD-Q4_K_XL et UD-Q5_K_XL.)
MODEL_LAGUNA_S_REPO="unsloth/Laguna-S-2.1-GGUF"
MODEL_LAGUNA_S_FILE_GLOB="UD-Q4_K_XL/*"
MODEL_LAGUNA_S_FILE_ENTRY="UD-Q4_K_XL/Laguna-S-2.1-UD-Q4_K_XL-00001-of-00003.gguf"

QWEN35_2B_PATH="$MODELS_BASE/qwen3.5-2b/$MODEL_QWEN35_2B_FILE"
LFM25_26B_PATH="$MODELS_BASE/lfm2.5-2.6b/$MODEL_LFM25_26B_FILE"
QWEN35_9B_PATH="$MODELS_BASE/qwen3.5-9b/$MODEL_QWEN35_9B_FILE"
QWEN35_9B_MTP_PATH="$MODELS_BASE/qwen3.5-9b-mtp/$MODEL_QWEN35_9B_MTP_FILE"
QWEN36_35B_A3B_PATH="$MODELS_BASE/qwen3.6-35b-a3b/$MODEL_QWEN36_35B_A3B_FILE"
QWEN3_CODER_NEXT_PATH="$MODELS_BASE/qwen3-coder-next/$MODEL_QWEN3_CODER_NEXT_FILE"
QWEN38_27B_PATH="$MODELS_BASE/qwen3.8-27b/$MODEL_QWEN38_27B_FILE"
QWOPUS_CODER_MTP_PATH="$MODELS_BASE/qwopus3.6-27b-coder-mtp/$MODEL_QWOPUS_CODER_MTP_FILE"
GEMMA_31B_PATH="$MODELS_BASE/gemma-31b/$MODEL_GEMMA_31B_FILE"
GEMMA_31B_MTP_PATH="$MODELS_BASE/gemma-31b/$MODEL_GEMMA_31B_MTP_FILE"
GEMMA_12B_PATH="$MODELS_BASE/gemma-12b/$MODEL_GEMMA_12B_FILE"
GEMMA_12B_MTP_PATH="$MODELS_BASE/gemma-12b/$MODEL_GEMMA_12B_MTP_FILE"
GPTOSS_PATH="$MODELS_BASE/gpt-oss/$MODEL_GPTOSS_FILE_ENTRY"
QWEN36_35B_A3B_MTP_PATH="$MODELS_BASE/qwen3.6-35b-a3b-mtp/$MODEL_QWEN36_35B_A3B_MTP_FILE"
DSV4_FLASH_PATH="$MODELS_BASE/deepseek-v4-flash/$MODEL_DSV4_FLASH_FILE_ENTRY"
LAGUNA_S_PATH="$MODELS_BASE/laguna-s-2.1/$MODEL_LAGUNA_S_FILE_ENTRY"

# Inventaire des fichiers attendus — source unique pour la création des dossiers
# et pour --cleanup. Toute entrée retirée d'ici devient un orphelin supprimable.
# (retirés le 15/08/2026, remplacés par qwen3.8-27b : qwen3.6-27b et
#  qwen3.6-27b-mtp → ./setup-llm.sh --cleanup les purge)
KNOWN_FILES=(
  "$QWEN35_2B_PATH"
  "$LFM25_26B_PATH"
  "$QWEN35_9B_PATH"
  "$QWEN35_9B_MTP_PATH"
  "$QWEN36_35B_A3B_PATH"
  "$QWEN3_CODER_NEXT_PATH"
  "$QWEN38_27B_PATH"
  "$QWOPUS_CODER_MTP_PATH"
  "$GEMMA_31B_PATH"
  "$GEMMA_31B_MTP_PATH"
  "$GEMMA_12B_PATH"
  "$GEMMA_12B_MTP_PATH"
  "$GPTOSS_PATH"
  "$QWEN36_35B_A3B_MTP_PATH"
  "$DSV4_FLASH_PATH"
  "$LAGUNA_S_PATH"
)

# Runtime ROCm + backend ggml-hip — installés en best-effort par --setup
# (jamais bloquant). ggml-hip est le backend HIP splitté d'extra/ggml : sans
# lui, ROCm0 n'est pas exposé même runtime installé.
# gfx1151 requis côté rocblas/hipblaslt : contrôler avec `rocminfo | grep gfx`.
ROCM_PKGS=(rocm-hip-runtime hipblas rocblas hipblaslt ggml-hip)
