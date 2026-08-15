#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# setup-llm.sh — llama-server router mode natif
#
# Backends : Vulkan (défaut) + ROCm/HIP optionnel.
#   - Depuis le split Arch de mi-août 2026, extra/ggml n'embarque PLUS les
#     backends : ils sont en optdeps séparés (ggml-cpu, ggml-vulkan, ggml-hip,
#     ggml-cuda, ggml-blas, ggml-openvino) chargés dynamiquement s'ils sont
#     présents. Vulkan0 requiert ggml-vulkan, ROCm0 requiert ggml-hip + le
#     runtime ROCm — le runtime seul ne fait plus apparaître ROCm0.
#   - ./setup-llm.sh --bench <modèle|all> : llama-bench Vulkan0 vs ROCm0,
#     sauvegarde le vainqueur dans bench-devices.conf (à côté du models.ini),
#     et régénère le ini — chaque preset hérite automatiquement du meilleur
#     device mesuré pour son GGUF. Sans bench, tout reste sur Vulkan0.
# =============================================================================

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
#   les presets non-MTP ET MTP, fini le doublon Q6 + Q4 de la 3.6.
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

# =============================================================================
# CHEMINS
# =============================================================================

MODELS_BASE="$HOME/models"
CONFIG_DIR="$HOME/models"

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

# =============================================================================
# BACKENDS
#
# Vulkan0 reste le défaut global ([*] device = Vulkan0). Backends ggml en
# paquets séparés (split Arch mi-août 2026) : ggml-vulkan pour Vulkan0,
# ggml-hip + runtime ROCm pour ROCm0 — le runtime seul ne suffit plus.
#
# Sélection par preset : automatique via bench-devices.conf (généré par
# --bench). Chaque preset dont le GGUF a une entrée dans le conf reçoit
# `device = <vainqueur>` dans le ini généré. Pas d'entrée → héritage du [*].
#
# ⚠ Les presets MTP/spéculatifs héritent du device benché sur leur GGUF, mais
#   le bench ne mesure PAS le chemin spéculatif : après une bascule ROCm d'un
#   preset MTP, valider la spéculation dans les logs (acceptance, pas de
#   fallback silencieux) avant de garder.
# =============================================================================

DEFAULT_DEVICE="Vulkan0"
BENCH_DEVICES=(Vulkan0 ROCm0)

# Fichier des vainqueurs par modèle — clé = dossier sous $MODELS_BASE.
# Format : "clé = device", commentaires ";". Édition manuelle possible
# (conservée tant que la clé n'est pas re-benchée).
# Vit À CÔTÉ DU SCRIPT (versionnable avec lui), pas dans $MODELS_BASE.
SCRIPT_DIR="$(dirname "$(realpath "$0")")"
BENCH_CONF="$SCRIPT_DIR/bench-devices.conf"

# Migration depuis l'ancien emplacement ($CONFIG_DIR) — one-shot, idempotent
if [[ -f "$CONFIG_DIR/bench-devices.conf" && ! -f "$BENCH_CONF" ]]; then
  mv "$CONFIG_DIR/bench-devices.conf" "$BENCH_CONF"
  echo "[INFO] bench-devices.conf migré : $CONFIG_DIR → $SCRIPT_DIR"
fi

# =============================================================================
# PRÉCHARGEMENT (always-on)
#
# La liste des presets préchargés (load-on-startup) vit dans preload.conf
# (à côté du script, comme bench-devices.conf — versionnable avec lui),
# alimenté par la sélection interactive à cases à cocher du --setup (gum si
# présent, fallback bash sinon) ou par ./setup-llm.sh --preload. Un preset
# sélectionné devient always-on (load-on-startup=true) ; les autres sont
# chargés à la demande et évincés par le LRU de --models-max (dérivé
# automatiquement : nb préchargés + 1 slot LRU).
# =============================================================================

PRELOAD_CONF="$SCRIPT_DIR/preload.conf"
DEFAULT_PRELOAD=(qwen3.5-9b qwen3.6-35b-a3b-nothink)

# Migration depuis l'ancien emplacement ($CONFIG_DIR) — one-shot, idempotent
if [[ -f "$CONFIG_DIR/preload.conf" && ! -f "$PRELOAD_CONF" ]]; then
  mv "$CONFIG_DIR/preload.conf" "$PRELOAD_CONF"
  echo "[INFO] preload.conf migré : $CONFIG_DIR → $SCRIPT_DIR"
fi

# Runtime ROCm + backend ggml-hip — installés en best-effort par --setup
# (jamais bloquant). ggml-hip est le backend HIP splitté d'extra/ggml : sans
# lui, ROCm0 n'est pas exposé même runtime installé.
# gfx1151 requis côté rocblas/hipblaslt : contrôler avec `rocminfo | grep gfx`.
ROCM_PKGS=(rocm-hip-runtime hipblas rocblas hipblaslt ggml-hip)

# =============================================================================
# PRESETS INI
#
# Chaque entrée du tableau associatif définit le corps d'un preset [section].
# Conventions :
#   - Une clé ini par ligne, format "key = value"
#   - Les flags globaux ([*]) ne sont pas répétés ici
#   - Commentaire de section : ligne(s) commençant par ";"
#   - Préchargement (load-on-startup) : pas écrit ici — piloté par
#     preload.conf (sélection interactive au --setup ou via --preload).
#     Pas de stop-timeout : l'éviction des modèles à la demande est gérée
#     par le LRU de --models-max, un timer n'apporte rien.
#   - device : hérité du [*] (Vulkan0) sauf surcharge locale ROCm0
#   - cache-reuse = 0 : explicite sur les 35B A3B — le cache-reuse est de toute
#     façon ignoré sur les architectures à état récurrent (GDN), llama-server
#     log "cache reuse is not supported by this context". La vraie restauration
#     de préfixe passe par cache-ram + ctx-checkpoints.
#   - cache-type-v = q8_0 en surcharge locale pour les modèles à usage
#     agentic/tool calling (le KV V q4_0 dégrade le tool calling, cf. doc
#     llama.cpp function-calling)
#   - swa-full + ctx-checkpoints : hybrides Qwen3.5/3.6/3.8 uniquement
#     (note : sans effet sur les 35B A3B, pas de SWA — llama-server le
#      désactive au chargement, seul ctx-checkpoints travaille)
#   - spec-draft-model : drafter externe (Gemma MTP uniquement)
#   - parallel = 1 OBLIGATOIRE sur tous les presets MTP : "-np > 1 and --mmproj
#     are not yet supported with MTP" (doc unsloth, confirmée sur les README
#     Qwen MTP et Gemma QAT, juin/juillet 2026). Les anciens parallel 2/3 sur
#     les presets MTP étaient au mieux ignorés, au pire cassaient la spéculation.
# =============================================================================

declare -A MODEL_INI

# Qwen3.5-2B : dense 2B hybrid-thinking, ultra-léger
# swa-full : exploite le ctx complet (SWA hybride GatedDeltaNet)
MODEL_INI[qwen3.5-2b]="
model            = $QWEN35_2B_PATH
ctx-size         = 32768
cache-ram        = 2048
temp             = 0.7
top-k            = 20
top-p            = 0.8
min-p            = 0.0
parallel         = 4
swa-full         = true
ctx-checkpoints  = 128"

# LFM2.5-2.6B — agentic edge Liquid AI : tool calling, instruction following,
#   multi-step. Compétitif avec des modèles 4x plus gros sur le tool use
#   (BFCLv4, ToolSandbox) — coding : rester sur les gros, c'est sa faiblesse.
# Sampling : reco llama.cpp officielle du model card GGUF (temp 0.1, top-k 50,
#   repeat-penalty 1.1). Le blog transformers donne temp 0.2 / rep 1.05 —
#   on suit la reco llama.cpp, plus déterministe, cohérente pour du tool calling.
# ctx 131072 : fenêtre native 128K (mid-training LFM2.5).
# cache-type-k/v f16 : arch hybride conv récurrente + GQA (lfm2) — KV minuscule
#   sur 2.6B, le q8_0/q4_0 global n'apporte rien ; f16 explicite par prudence
#   (chemin quantifié non validé sur cette arch).
# cache-reuse 0 : état récurrent (conv) — même logique que GDN, non supporté.
# Pas de swa-full ni ctx-checkpoints : pas une arch hybride SWA Qwen.
# jinja : template chat requis pour le tool calling.
MODEL_INI[lfm2.5-2.6b]="
model            = $LFM25_26B_PATH
ctx-size         = 131072
cache-ram        = 2048
temp             = 0.1
top-k            = 50
min-p            = 0.0
repeat-penalty   = 1.1
cache-type-k     = f16
cache-type-v     = f16
cache-reuse      = 0
jinja            = true
parallel         = 4"

# Qwen3.5-9B : dense 9B — tâches auxiliaires courtes (résumés, titres, routage)
# chat-template-kwargs : thinking COUPÉ. Note : depuis les mises à jour de
#   template unsloth, les Qwen3.5 Small (0.8B/2B/4B/9B) sont nothink PAR DÉFAUT —
#   le kwargs est devenu redondant mais reste en ceinture-bretelles (un futur
#   re-download de template ne doit pas réactiver le thinking en douce).
# n-predict 1024 : borne dure, aucune tâche auxiliaire n'a besoin de plus —
#   plus jamais de génération qui court jusqu'au plafond de contexte
# NB : la variante MTP existe en preset séparé (qwen3.5-9b-mtp) — MTP impose
#   parallel=1, incompatible avec les 4 slots de tâches concurrentes : on
#   garde le non-MTP en always-on ici.
MODEL_INI[qwen3.5-9b]="
model                = $QWEN35_9B_PATH
ctx-size             = 32768
cache-ram            = 2048
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
chat-template-kwargs = {\"enable_thinking\":false}
n-predict            = 1024
parallel             = 4
swa-full             = true
ctx-checkpoints      = 128"

# Qwen3.5-9B-MTP nothink — variante spéculative du 9b, bascule manuelle
#   (/model qwen3.5-9b-mtp) pour la génération mono-flux : gain annoncé
#   ~1.5-2x en décode sans perte. NE remplace PAS le 9b always-on pour les
#   tâches auxiliaires (MTP = parallel 1, cf. ci-dessus). LRU, léger (~9 Go).
# spec-draft-n-max 6 : reco unsloth depuis le merge mainline (16/05/2026,
#   n-max relevé de 2 à 6 pour les Qwen3.5)
# cache-reuse 0 : incompatible MTP — nothink via chat-template-kwargs
MODEL_INI[qwen3.5-9b-mtp]="
model                = $QWEN35_9B_MTP_PATH
ctx-size             = 32768
cache-ram            = 2048
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
chat-template-kwargs = {\"enable_thinking\":false}
cache-reuse          = 0
spec-type            = draft-mtp
spec-draft-n-max     = 6
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# Qwen3.6-35B-A3B nothink — DEFAULT AGENTIC, always-on
#   Sert opencode (usage principal) et les autres clients agentic.
# Repassé devant la variante MTP pour l'agentic : le rollback de l'état
#   récurrent GDN lors des rejets de draft MTP est encore instable côté
#   llama.cpp (partial seq_rm, PR #22400/#22673) → checkpoints/prompt-cache
#   fiables ici, et c'est ce qui compte en boucle de tool calls.
# parallel 2 : subagents opencode / requêtes concurrentes sans sérialisation
# cache-type-v q8_0 : le V q4_0 global dégrade le tool calling
# cache-reuse 0 : ignoré de toute façon sur GDN (état récurrent) — la
#   restauration de préfixe passe par cache-ram + ctx-checkpoints
MODEL_INI[qwen3.6-35b-a3b-nothink]="
model            = $QWEN36_35B_A3B_PATH
ctx-size         = 524288
cache-ram        = 12288
reasoning        = off
temp             = 0.6
top-k            = 20
top-p            = 0.95
min-p            = 0.0
cache-type-v     = q8_0
parallel         = 2
cache-reuse      = 0
swa-full         = true
ctx-checkpoints  = 128"

# Qwen3.6-35B-A3B-MTP nothink — passé en LRU (ex-default)
# MTP draft=2 : décodage spéculatif sans perte, gain max sur tool calls / JSON,
#   mais rollback GDN fragile en agentic (cf. ci-dessus) → bascule manuelle
#   uniquement : /model qwen3.6-35b-a3b-mtp-nothink
# (ne PAS précharger ce preset en même temps que le nothink dans --preload,
#  ce serait ~29 Go chargés deux fois pour le même modèle)
# cache-type-v q8_0 : le V q4_0 global dégrade le tool calling
# cache-reuse 0 : ignoré sur GDN — nothink via chat-template-kwargs (pas --reasoning off)
# parallel 1 : contrainte MTP (np > 1 non supporté)
MODEL_INI[qwen3.6-35b-a3b-mtp-nothink]="
model                = $QWEN36_35B_A3B_MTP_PATH
ctx-size             = 131072
cache-ram            = 6144
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
presence-penalty     = 1.5
chat-template-kwargs = {\"enable_thinking\":false}
cache-type-v         = q8_0
cache-reuse          = 0
spec-type            = draft-mtp
spec-draft-n-max     = 2
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# Qwen3.6-35B-A3B thinking — raisonnement activé
# cache-reuse 0 : ignoré sur GDN
MODEL_INI[qwen3.6-35b-a3b]="
model            = $QWEN36_35B_A3B_PATH
ctx-size         = 393216
cache-ram        = 6144
temp             = 0.6
top-k            = 20
top-p            = 0.95
min-p            = 0.0
parallel         = 3
cache-reuse      = 0
swa-full         = true
ctx-checkpoints  = 128"

# Qwen3-Coder-Next — MoE 80B hybrid-attention, agentic coding
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : MoE hybrid-attention incompatible
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench.
MODEL_INI[qwen3-coder-next]="
model            = $QWEN3_CODER_NEXT_PATH
ctx-size         = 131072
cache-ram        = 4096
temp             = 1.0
top-k            = 40
top-p            = 0.95
min-p            = 0.01
cache-type-v     = q8_0
cache-reuse      = 0
parallel         = 1"

# =============================================================================
# Famille Qwen3.8-27B — un seul GGUF (UD-Q4_K_XL, tête MTP embarquée) partagé
# par les deux presets ci-dessous. Remplace qwen3.6-27b, qwen3.6-27b-nothink
# et qwen3.6-27b-mtp-nothink. Pas de preset nothink non-MTP : à parallel 1 il
# ferait doublon strict avec le mtp-nothink (même GGUF, mêmes réglages, juste
# sans la spéculation). Le thinking reste non-MTP volontairement : c'est le
# chemin checkpoints/prompt-cache fiable (rollback GDN sur rejet de draft
# encore fragile en agentic, cf. 35B-A3B) — spec-type à ajouter si envie. (Le Qwopus, SFT coder de la 3.6-27B, est gardé
# en preset séparé plus bas — choix perso, pas un doublon strict.)
#
# Sampling officiel Qwen3.8-27B (model card + doc unsloth) :
#   thinking : temp 1.0 / top-p 0.95 / top-k 20 / min-p 0.0 / presence 0.0
#   instruct : temp 0.7 / top-p 0.80 / top-k 20 / min-p 0.0 / presence 1.5
#   (le "temp 0.6" du 3.6 pour le coding précis n'est plus la reco 3.8)
# Thinking ON par défaut, désactivable par requête. reasoning_effort :
#   xhigh (défaut) / medium / low / none, via chat-template-kwargs. Le preset
#   thinking est calé sur medium (équilibre précision/vitesse — xhigh pense
#   trop pour un usage local) ; passer à "xhigh"/"low" dans le kwargs si besoin.
#   preserve_thinking (garde les traces des tours précédents) : côté client.
# Sortie longue en agentic : Qwen reco 256K reasoning + 128K réponse (dans 1M) —
#   inutile ici, ctx-size 131072 comme la 3.6 (natif 256K, YaRN 1M dispo).
# cache-type-v q8_0 : agentic/coding, précision V critique (tool calls, diffs)
# jinja : template unsloth (developer role, tool calling nested objects amélioré)
# swa-full + ctx-checkpoints : arch hybride GDN/SWA identique 3.5/3.6
# Vision : mmproj non téléchargé (--include du seul GGUF texte) → pas de
#   --mmproj, texte seul. Ajouter mmproj-F16.gguf + "mmproj =" si besoin un jour
#   (attention : mmproj incompatible MTP, cf. contrainte np/mmproj plus haut).
# ⚠ Hypothèse MTP embarqué à VALIDER au premier chargement du preset MTP :
#   llama-server doit logger le chargement de la tête MTP + acceptance ; s'il
#   refuse (spec-type sans tête), c'est qu'unsloth a finalement publié un repo
#   -MTP séparé → réintroduire une variable REPO/PATH dédiée.
# =============================================================================

# Qwen3.8-27B thinking — reasoning_effort medium (défaut modèle = xhigh), tool-calling jinja
MODEL_INI[qwen3.8-27b]="
model                = $QWEN38_27B_PATH
ctx-size             = 131072
cache-ram            = 4096
temp                 = 1.0
top-k                = 20
top-p                = 0.95
min-p                = 0.0
chat-template-kwargs = {\"reasoning_effort\":\"medium\"}
cache-type-v         = q8_0
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# Qwen3.8-27B-MTP nothink — spéculation MTP, n-max 4 (mesuré --spec-test
#   Q4/ROCm0 15/08/2026 : k2=22,2 / k4=25,5 / k6=26,0 t/s → 4 = plateau,
#   le plus petit à <2 % du max ; reco unsloth de départ était 2).
#   Bascule manuelle : /model qwen3.8-27b-mtp-nothink
# Même GGUF que le preset thinking ci-dessus (tête MTP embarquée) — ne PAS
#   précharger les deux en même temps (~16 Go chargés deux fois).
# Historique : Q6/n-max 2 = 16 t/s ; Q4/n-max 2 = 22 ; Q4/n-max 4 = 25,5.
#   Re-régler avec ./setup-llm.sh --spec-tune après changement de quant/build/device.
# cache-reuse 0 : incompatible MTP
# parallel 1 : contrainte MTP (np > 1 non supporté)
MODEL_INI[qwen3.8-27b-mtp-nothink]="
model                = $QWEN38_27B_PATH
ctx-size             = 131072
cache-ram            = 4096
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
presence-penalty     = 1.5
chat-template-kwargs = {\"enable_thinking\":false}
cache-type-v         = q8_0
cache-reuse          = 0
spec-type            = draft-mtp
spec-draft-n-max     = 4
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# Qwopus3.6-27B-Coder-MTP nothink — fine-tune coder SFT, SWE-bench 67.0%
#   (score confirmé : run Q5_K_M, 335/500 Verified, thinking-off)
# Bascule manuelle : /model qwopus3.6-27b-coder-mtp-nothink
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : incompatible MTP
MODEL_INI[qwopus3.6-27b-coder-mtp-nothink]="
model                = $QWOPUS_CODER_MTP_PATH
ctx-size             = 131072
cache-ram            = 4096
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
presence-penalty     = 1.5
chat-template-kwargs = {\"enable_thinking\":false}
cache-type-v         = q8_0
cache-reuse          = 0
spec-type            = draft-mtp
spec-draft-n-max     = 2
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# Gemma 4 31B — MTP drafter embarqué, texte seul (no-mmproj), spec-draft-n-max 4
#   (reco unsloth, acceptance ~0.78-0.79 mesurée)
# ⚠ MTP Gemma mergé dans llama.cpp le 2026-06-07 (PR #23398) — un build
#   antérieur ne charge pas l'arch gemma4-assistant.
# Pas de swa-full : architecture ISWA différente (issue #21468)
# chat-template-kwargs + jinja : désactive le thinking (--reasoning off non supporté)
# parallel 1 : contrainte MTP (np > 1 non supporté)
MODEL_INI[gemma4-31b-mtp]="
model                = $GEMMA_31B_PATH
spec-draft-model     = $GEMMA_31B_MTP_PATH
ctx-size             = 262144
cache-ram            = 4096
no-mmproj            = true
chat-template-kwargs = {\"enable_thinking\":false}
cache-reuse          = 0
spec-type            = draft-mtp
spec-draft-n-max     = 4
temp                 = 1.0
top-k                = 64
top-p                = 0.95
min-p                = 0.01
jinja                = true
parallel             = 1"

# Gemma 4 12B — MTP drafter embarqué, modèle unifié texte+image+audio+vidéo, texte seul
# spec-draft-n-max 4 : aligné sur la reco unsloth (était 2)
# Pas de swa-full : architecture ISWA différente (issue #21468)
# parallel 1 : contrainte MTP (np > 1 non supporté) — pour retrouver du parallel,
#   faire un preset non-MTP séparé sur le même GGUF.
MODEL_INI[gemma4-12b-mtp]="
model                = $GEMMA_12B_PATH
spec-draft-model     = $GEMMA_12B_MTP_PATH
ctx-size             = 262144
cache-ram            = 2048
no-mmproj            = true
chat-template-kwargs = {\"enable_thinking\":false}
cache-reuse          = 0
spec-type            = draft-mtp
spec-draft-n-max     = 4
temp                 = 1.0
top-k                = 64
top-p                = 0.95
min-p                = 0.01
jinja                = true
parallel             = 1"

# GPT-OSS 120B — shards UD-Q4_K_XL
MODEL_INI[gpt-oss]="
model            = $GPTOSS_PATH
ctx-size         = 131072
cache-ram        = 8192
temp             = 1.0
top-k            = 0
top-p            = 1.0
min-p            = 0.0
parallel         = 1"

# DeepSeek-V4-Flash-0731 — MoE 284B (13B actifs), agentic/coding, 1M ctx natif
# Sampling officiel DeepSeek pour le 0731 : temp 1.0, top-p 0.95 en agentic
#   (top-p 1.0 pour le reste), min-p 0.0. top-k non surchargé par unsloth
#   (défaut llama.cpp 40).
# Thinking : "Think High" actif par défaut via le template. Options :
#     chat-template-kwargs = {"reasoning_effort":"max"}   (ctx >= 384K requis)
#     chat-template-kwargs = {"reasoning_effort":"high"}
#     chat-template-kwargs = {"enable_thinking":false}    (ou reasoning = off)
#   On reste sur le défaut (high) — le 0731 pense déjà beaucoup plus que la
#   preview, max à réserver aux gros ctx.
# cache-type-k/v f16 : surcharge explicite — KV MLA compact (KV compressé,
#   ~0,6 Go à 32K), le q8_0/q4_0 global n'apporte rien et les configs
#   communautaires validées tournent en f16/f16.
# jinja : template unsloth amélioré (reasoning_effort + reasoning_content
#   conservé dans les tool calls) — indispensable en agentic.
# cache-reuse 0 : MoE incompatible — pas de swa-full (MLA/DSA, non SWA).
# Module DSpark (spéculation) : port llama.cpp soumis upstream (#25683),
#   pas encore mergé mainline — à activer ici le jour du merge
#   (spec-type = draft-dspark + drafter GGUF). Gain modeste attendu sur APU.
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench.
MODEL_INI[deepseek-v4-flash]="
model            = $DSV4_FLASH_PATH
ctx-size         = 131072
cache-ram        = 8192
temp             = 1.0
top-k            = 40
top-p            = 0.95
min-p            = 0.0
cache-type-k     = f16
cache-type-v     = f16
cache-reuse      = 0
jinja            = true
parallel         = 1"

# Laguna S 2.1 — MoE 118B-A8B (poolside), agentic coding / long-horizon
# 48 couches en ratio 1:3 global/SWA (fenêtre 512) + softplus gating :
#   pas de swa-full, l'ISWA laguna n'est pas l'implémentation Qwen.
# ctx 262144 : les GGUF sont packagés pour 256K (metadata rope/YaRN fixée par
#   unsloth fin juillet 2026 sur la config poolside). Le checkpoint est natif 1M
#   mais il faut alors surcharger le rope au chargement :
#     --ctx-size 1048576 --rope-scaling yarn --rope-scale 128 --yarn-orig-ctx 8192
#   (dégradation qualité annoncée par poolside → on reste à 256K).
# cache-reuse 0 : MoE + attention mixte, non testé avec le cache-reuse global.
# cache-type-v q8_0 : précision V critique pour les diffs de code.
# thinking activé par défaut (recommandé en agentic coding, avec preserved
#   thinking côté client) — pour un preset nothink, ajouter :
#     chat-template-kwargs = {"enable_thinking":false}
# Spéculation DFlash (drafter laguna-s-2.1-DFlash-BF16.gguf, 2,2 Go) : disponible
#   uniquement via le fork poolside/llama.cpp branche `laguna`
#   (--spec-type draft-dflash --spec-draft-n-max 15), pas dans le mainline —
#   retours communauté : jusqu'à +30 tok/s de décode selon les tâches.
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench.
MODEL_INI[laguna-s-2.1]="
model            = $LAGUNA_S_PATH
ctx-size         = 262144
cache-ram        = 8192
temp             = 0.7
top-p            = 0.95
top-k            = 0
min-p            = 0.0
cache-type-v     = q8_0
cache-reuse      = 0
jinja            = true
parallel         = 1"

# =============================================================================
# Ordre d'émission des presets dans le ini
# (declare -A ne préserve pas l'ordre d'insertion)
# =============================================================================

PRESET_ORDER=(
  # préchargés par défaut (cf. DEFAULT_PRELOAD / preload.conf) :
  #   9b = tâches auxiliaires, 35b-a3b-nothink = default agentic (opencode & co)
  qwen3.5-2b
  qwen3.5-9b
  qwen3.6-35b-a3b-nothink
  # légers à la demande
  qwen3.5-9b-mtp
  lfm2.5-2.6b
  # famille 35B A3B
  qwen3.6-35b-a3b
  qwen3.6-35b-a3b-mtp-nothink
  qwen3-coder-next
  # famille 27B (Qwen3.8)
  qwen3.8-27b
  qwen3.8-27b-mtp-nothink
  qwopus3.6-27b-coder-mtp-nothink
  # Gemma 4
  gemma4-31b-mtp
  gemma4-12b-mtp
  # géants
  gpt-oss
  deepseek-v4-flash
  laguna-s-2.1
)

# =============================================================================
# Génération du models.ini
# =============================================================================

# Charge bench-devices.conf → BENCH_DEVICE[clé modèle] = device vainqueur
declare -A BENCH_DEVICE
load_bench_conf() {
  BENCH_DEVICE=()
  [[ -f "$BENCH_CONF" ]] || return 0
  local line key dev
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*($|\;|\#) ]] && continue
    key="${line%%=*}"; key="${key// /}"
    dev="${line#*=}";  dev="${dev// /}"
    [[ -n "$key" && -n "$dev" ]] && BENCH_DEVICE[$key]="$dev"
  done < "$BENCH_CONF"
}

# Clé modèle d'un preset = dossier du GGUF référencé par sa ligne "model ="
_preset_model_key() {
  local body="${MODEL_INI[$1]}" path
  path="$(echo "$body" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
  [[ -n "$path" ]] && _key "$path"
}

# =============================================================================
# Préchargement — lecture/écriture de preload.conf + sélection interactive
# =============================================================================

# Charge preload.conf → PRELOADED[preset]=1. Sans fichier : DEFAULT_PRELOAD.
declare -A PRELOADED
load_preload_conf() {
  PRELOADED=()
  local p
  if [[ -f "$PRELOAD_CONF" ]]; then
    while IFS= read -r p; do
      [[ "$p" =~ ^[[:space:]]*($|\;|\#) ]] && continue
      p="${p// /}"
      [[ -n "${MODEL_INI[$p]:-}" ]] && PRELOADED[$p]=1
    done < "$PRELOAD_CONF"
  else
    for p in "${DEFAULT_PRELOAD[@]}"; do PRELOADED[$p]=1; done
  fi
}

_save_preload_conf() {
  local tmp p
  tmp="$(mktemp)"
  {
    echo "; preload.conf — presets préchargés (load-on-startup) au démarrage"
    echo "; généré par ./setup-llm.sh (--setup / --preload) — un preset par ligne"
    echo "; édition manuelle OK ; --models-max = nb de lignes + 1 slot LRU"
    for p in "${PRESET_ORDER[@]}"; do
      [[ -n "${PRELOADED[$p]:-}" ]] && echo "$p"
    done
  } > "$tmp"
  mv "$tmp" "$PRELOAD_CONF"
}

# Sélection interactive des presets préchargés. gum si dispo (cases à cocher,
# espace pour sélectionner) ; sinon fallback bash (numéros à toggler). Entrée
# non interactive : conserve la sélection courante sans rien demander.
select_preload_models() {
  load_preload_conf

  if [[ ! -t 0 ]]; then
    info "Entrée non interactive — préchargement conservé : $(_preload_summary)"
    _save_preload_conf
    return
  fi

  local -a chosen=()
  local p
  if command -v gum >/dev/null 2>&1; then
    # gum choose --no-limit : espace = cocher, entrée = valider
    local -a preselected=()
    for p in "${PRESET_ORDER[@]}"; do
      [[ -n "${PRELOADED[$p]:-}" ]] && preselected+=("$p")
    done
    local sel_csv
    sel_csv="$(IFS=,; echo "${preselected[*]}")"
    mapfile -t chosen < <(printf '%s\n' "${PRESET_ORDER[@]}" \
      | gum choose --no-limit --height 20 \
          --header "Presets préchargés au démarrage (espace = cocher, entrée = valider)" \
          --selected="$sel_csv") || {
        warn "Sélection annulée — préchargement inchangé : $(_preload_summary)"
        _save_preload_conf
        return
      }
  else
    # Fallback sans gum : liste numérotée, toggle par numéros
    info "gum absent (pacman -S gum pour les cases à cocher) — fallback numéroté."
    echo ""
    echo "Presets préchargés au démarrage (always-on) :"
    local i=1
    local -a idx=()
    for p in "${PRESET_ORDER[@]}"; do
      if [[ -n "${PRELOADED[$p]:-}" ]]; then
        printf "  %2d [x] %s\n" "$i" "$p"
      else
        printf "  %2d [ ] %s\n" "$i" "$p"
      fi
      idx+=("$p")
      ((i++))
    done
    echo ""
    local input n
    read -r -p "Numéros à inverser (ex: 2 5 12), vide = garder tel quel : " input
    for n in $input; do
      [[ "$n" =~ ^[0-9]+$ ]] || { warn "'$n' ignoré (pas un numéro)"; continue; }
      (( n >= 1 && n <= ${#idx[@]} )) || { warn "'$n' ignoré (hors liste)"; continue; }
      p="${idx[$((n-1))]}"
      if [[ -n "${PRELOADED[$p]:-}" ]]; then
        unset "PRELOADED[$p]"
      else
        PRELOADED[$p]=1
      fi
    done
    chosen=()
    for p in "${PRESET_ORDER[@]}"; do
      [[ -n "${PRELOADED[$p]:-}" ]] && chosen+=("$p")
    done
    PRELOADED=()
    for p in "${chosen[@]}"; do PRELOADED[$p]=1; done
    _preload_sanity
    _save_preload_conf
    info "Préchargement : $(_preload_summary)"
    return
  fi

  # Chemin gum : reconstruire PRELOADED depuis la sélection
  # (une sélection vide est légitime : zéro préchargé, tout en LRU)
  PRELOADED=()
  for p in "${chosen[@]}"; do
    [[ -n "$p" ]] || continue
    [[ -n "${MODEL_INI[$p]:-}" ]] && PRELOADED[$p]=1 || true
  done
  _preload_sanity
  _save_preload_conf
  info "Préchargement : $(_preload_summary)"
}

_preload_summary() {
  local p out=""
  for p in "${PRESET_ORDER[@]}"; do
    [[ -n "${PRELOADED[$p]:-}" ]] && out+="$p "
  done
  [[ -n "$out" ]] && echo "$out" || echo "(aucun — tout en LRU)"
}

_preload_sanity() {
  local count=${#PRELOADED[@]}
  [[ $count -eq 0 ]] \
    && warn "Aucun preset préchargé — premier appel de chaque modèle = temps de chargement complet."
  [[ $count -gt 3 ]] \
    && warn "$count presets préchargés — vérifier que la somme des poids + KV tient dans les 128 Go."
  # Doublons connus : même GGUF chargé deux fois
  if [[ -n "${PRELOADED[qwen3.6-35b-a3b-nothink]:-}" && -n "${PRELOADED[qwen3.6-35b-a3b-mtp-nothink]:-}" ]]; then
    warn "35b-a3b nothink ET mtp-nothink préchargés : ~29 Go chargés deux fois pour le même modèle."
  fi
  local n38=0 p
  for p in qwen3.8-27b qwen3.8-27b-mtp-nothink; do
    [[ -n "${PRELOADED[$p]:-}" ]] && n38=$((n38 + 1))
  done
  if [[ $n38 -gt 1 ]]; then
    warn "$n38 presets Qwen3.8-27B préchargés : même GGUF (~16 Go) chargé $n38 fois."
  fi
  # Toujours retourner 0 : sous set -e, un dernier test [[ ]] && ... faux
  # ferait sortir la fonction en 1 et tuerait le script avant la génération du ini.
  return 0
}

generate_models_ini() {
  load_bench_conf
  load_preload_conf
  load_spec_conf

  cat <<HEADER
version = 1

; =============================================================================
; Flags globaux — appliqués à tous les presets sauf surcharge locale
;
; device = Vulkan0 : backend par défaut. Les surcharges "device = ..." par
;   preset ci-dessous proviennent de bench-devices.conf (./setup-llm.sh --bench)
;   — chaque preset hérite du vainqueur mesuré sur son GGUF. Vérifier au
;   chargement dans les logs : device retenu + flash-attn effectivement actif
;   (certaines archs le coupent silencieusement sous HIP, ce qui annule le
;   gain de prefill).
; =============================================================================
[*]
device                 = $DEFAULT_DEVICE
n-gpu-layers           = 99
cache-type-k           = q8_0
cache-type-v           = q4_0
flash-attn             = on
prio                   = 2
metrics                = true
slot-prompt-similarity = 0.5
cache-reuse            = 4096
presence-penalty       = 0.0

; =============================================================================
; Préchargement (load-on-startup) piloté par preload.conf
; (./setup-llm.sh --preload pour changer la sélection sans re-setup)
; =============================================================================

HEADER

  local prev_group=""
  local mkey mdev
  for name in "${PRESET_ORDER[@]}"; do
    # Séparateurs de groupe à partir des commentaires dans PRESET_ORDER
    case "$name" in
      qwen3.5-9b-mtp)
        echo "; ============================================================================="; echo "; À la demande — évincés par le LRU de --models-max"; echo "; ============================================================================="; echo ""; echo "; --- Qwen3.5 9B MTP (bascule manuelle, parallel 1) ---"; echo "" ;;
      lfm2.5-2.6b)
        echo "; --- LFM2.5 2.6B (Liquid AI — agentic edge, tool calling) ---"; echo "" ;;
      qwen3.6-35b-a3b)
        echo "; --- Famille 35B A3B ---"; echo "" ;;
      qwen3.8-27b)
        echo "; --- Famille 27B (Qwen3.8 — un seul GGUF, tête MTP embarquée — + Qwopus 3.6 coder) ---"; echo "" ;;
      gemma4-31b-mtp)
        echo "; --- Famille Gemma 4 — pas de swa-full (ISWA, issue #21468) ; MTP requiert llama.cpp >= 2026-06-07 (PR #23398) ---"; echo "" ;;
      gpt-oss)
        echo "; --- Géants ---"; echo "" ;;
      laguna-s-2.1)
        echo "; --- Laguna S 2.1 — nécessite llama.cpp >= b10087 (arch 'laguna', confirmé jusqu'à b10181) ---"; echo "" ;;
    esac

    echo "[$name]"
    # Surcharge device issue du bench (clé = dossier du GGUF du preset)
    mkey="$(_preset_model_key "$name" || true)"
    mdev="${BENCH_DEVICE[$mkey]:-}"
    if [[ -n "$mdev" && "$mdev" != "$DEFAULT_DEVICE" ]]; then
      echo "device           = $mdev"
    fi
    # Corps du preset + préchargement piloté par preload.conf
    # (pas de stop-timeout : l'éviction est gérée par le LRU de --models-max)
    # spec-draft-n-max : surcharge spec-nmax.conf / --spec-tune si présente
    local eff_nmax
    eff_nmax="$(_preset_nmax "$name")"
    if [[ -n "$eff_nmax" ]]; then
      echo "${MODEL_INI[$name]}" | sed '/^$/d' \
        | sed "s/^\(spec-draft-n-max[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1$eff_nmax/"
    else
      echo "${MODEL_INI[$name]}" | sed '/^$/d'
    fi
    [[ -n "${PRELOADED[$name]:-}" ]] && echo "load-on-startup  = true"
    echo ""
  done
}

# =============================================================================
# Helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Propose un restart du service systemd si actif — appelé en fin de setup /
# update / cleanup / preload (config ou poids modifiés). Rappel : les poids
# déjà mmap'és restent sur l'ancien inode tant que le serveur n'a pas redémarré.
# Non-interactif : jamais de restart automatique, juste le rappel.
_maybe_restart_service() {
  systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || return 0
  local reply="n"
  if [[ -t 0 ]]; then
    read -r -p "Le service $SERVICE_NAME tourne — redémarrer maintenant pour appliquer ? [O/n] " reply
    reply="${reply:-o}"
  else
    warn "Service $SERVICE_NAME actif — redémarrage non effectué (entrée non interactive)."
    warn "  Appliquer : sudo systemctl restart $SERVICE_NAME"
    return 0
  fi
  if [[ "$reply" =~ ^[oOyY]$ ]]; then
    info "Redémarrage de $SERVICE_NAME..."
    sudo systemctl restart "$SERVICE_NAME" \
      && info "✅ $SERVICE_NAME redémarré." \
      || warn "Redémarrage en échec — voir : journalctl -u $SERVICE_NAME -e"
  else
    info "Redémarrage sauté — appliquer plus tard : sudo systemctl restart $SERVICE_NAME"
  fi
}

# REFRESH=1 : on ne court-circuite plus sur "fichier déjà présent", on laisse
#   `hf download` comparer les etags et ne retélécharger que ce qui a bougé.
# ONLY : si non vide, ne traite que le modèle dont le dossier porte ce nom.
REFRESH=0
ONLY=""

# Clé d'un modèle = premier segment sous $MODELS_BASE
# (fonctionne pour les fichiers plats comme pour les dossiers de shards)
_key() {
  local p="${1#"$MODELS_BASE"/}"
  echo "${p%%/*}"
}

_skip() {
  [[ -n "$ONLY" && "$(_key "$1")" != "$ONLY" ]]
}

# Résout la clé d'un modèle (nom de dossier) vers son chemin dans KNOWN_FILES
_path_for_key() {
  local key="$1" f
  for f in "${KNOWN_FILES[@]}"; do
    if [[ "$(_key "$f")" == "$key" ]]; then
      echo "$f"
      return 0
    fi
  done
  return 1
}

_dl() {
  local target="$1" repo="$2"
  shift 2
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement $(basename "$target")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" "$@" --local-dir "$(dirname "$target")"
}

_dl_shard() {
  local target="$1" repo="$2" glob="$3"
  local shard_dir dest_dir
  shard_dir="$(dirname "$target")"
  dest_dir="$(dirname "$shard_dir")"
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement shards $(basename "$shard_dir")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" --include "$glob" --local-dir "$dest_dir"
}

# =============================================================================
# setup
# =============================================================================

cmd_setup() {
  info "Vérification des dépendances..."
  # ggml-cpu + ggml-vulkan : backends splittés d'extra/ggml (optdeps, donc
  # à imposer — sans ggml-vulkan plus de Vulkan0, sans ggml-cpu plus d'ops CPU)
  PACMAN_PKGS=(curl llama-cpp ggml-cpu ggml-vulkan python-huggingface-hub python-hf-xet)
  MISSING=()
  for pkg in "${PACMAN_PKGS[@]}"; do
    paru -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
  done
  [[ ${#MISSING[@]} -gt 0 ]] && paru -S --noconfirm "${MISSING[@]}"
  command -v hf >/dev/null || error "hf introuvable"

  # --- Runtime ROCm + ggml-hip : best-effort, jamais bloquant ---------------
  # (backend HIP splitté : ggml-hip requis EN PLUS du runtime pour voir ROCm0)
  info "Vérification du runtime ROCm (optionnel)..."
  local rocm_missing=() rocm_to_install=()
  local pkg
  for pkg in "${ROCM_PKGS[@]}"; do
    if paru -Qi "$pkg" &>/dev/null; then
      continue
    elif paru -Si "$pkg" &>/dev/null; then
      rocm_to_install+=("$pkg")
    else
      rocm_missing+=("$pkg")
    fi
  done
  if [[ ${#rocm_to_install[@]} -gt 0 ]]; then
    warn "Paquets ROCm à installer (backend ROCm0 pour --bench) : ${rocm_to_install[*]}"
    local reply="n"
    if [[ -t 0 ]]; then
      read -r -p "Installer le runtime ROCm ? [o/N] " reply
    else
      warn "Entrée non interactive — installation ROCm sautée par défaut."
    fi
    if [[ "$reply" =~ ^[oOyY]$ ]]; then
      paru -S --noconfirm "${rocm_to_install[@]}" \
        || warn "Installation ROCm en échec — Vulkan0 reste pleinement fonctionnel."
    else
      info "Runtime ROCm non installé — le setup continue sur Vulkan0 seul."
      info "  (relancer --setup plus tard pour l'ajouter et débloquer ROCm0 dans --bench)"
    fi
  fi
  if [[ ${#rocm_missing[@]} -gt 0 ]]; then
    warn "Paquets ROCm introuvables dans les dépôts : ${rocm_missing[*]}"
    warn "  → le défaut Vulkan0 du models.ini reste pleinement fonctionnel sans ;"
    warn "    ROCm0 n'apparaîtra simplement pas dans --bench."
  fi
  if command -v rocminfo >/dev/null 2>&1; then
    if rocminfo 2>/dev/null | grep -q gfx1151; then
      info "ROCm OK : gfx1151 (Strix Halo) détecté."
    else
      warn "rocminfo présent mais gfx1151 non détecté — rocblas/hipblaslt sans"
      warn "  support gfx1151 ? (alternative AUR : rocm-nightly-gfx1151-bin)"
    fi
  fi
  # -------------------------------------------------------------------------

  info "Création des dossiers..."
  local f
  for f in "${KNOWN_FILES[@]}"; do
    mkdir -p "$(dirname "$f")"
  done

  _dl "$QWEN35_2B_PATH"          "$MODEL_QWEN35_2B_REPO"          "$MODEL_QWEN35_2B_FILE"
  _dl "$LFM25_26B_PATH"          "$MODEL_LFM25_26B_REPO"          "$MODEL_LFM25_26B_FILE"
  _dl "$QWEN35_9B_PATH"          "$MODEL_QWEN35_9B_REPO"          "$MODEL_QWEN35_9B_FILE"
  _dl "$QWEN35_9B_MTP_PATH"      "$MODEL_QWEN35_9B_MTP_REPO"      "$MODEL_QWEN35_9B_MTP_FILE"
  _dl "$QWEN36_35B_A3B_PATH"     "$MODEL_QWEN36_35B_A3B_REPO"     "$MODEL_QWEN36_35B_A3B_FILE"
  _dl "$QWEN3_CODER_NEXT_PATH"   "$MODEL_QWEN3_CODER_NEXT_REPO"   "$MODEL_QWEN3_CODER_NEXT_FILE"
  _dl "$QWEN38_27B_PATH"         "$MODEL_QWEN38_27B_REPO"         "$MODEL_QWEN38_27B_FILE"
  _dl "$QWOPUS_CODER_MTP_PATH"   "$MODEL_QWOPUS_CODER_MTP_REPO"  "$MODEL_QWOPUS_CODER_MTP_FILE"
  _dl "$GEMMA_31B_PATH"          "$MODEL_GEMMA_31B_REPO"          "$MODEL_GEMMA_31B_FILE"
  _dl "$GEMMA_31B_MTP_PATH"      "$MODEL_GEMMA_31B_REPO"          "$MODEL_GEMMA_31B_MTP_FILE"
  _dl "$GEMMA_12B_PATH"          "$MODEL_GEMMA_12B_REPO"          "$MODEL_GEMMA_12B_FILE"
  _dl "$GEMMA_12B_MTP_PATH"      "$MODEL_GEMMA_12B_REPO"          "$MODEL_GEMMA_12B_MTP_FILE"
  _dl_shard "$GPTOSS_PATH"       "$MODEL_GPTOSS_REPO"             "$MODEL_GPTOSS_FILE_GLOB"
  _dl "$QWEN36_35B_A3B_MTP_PATH" "$MODEL_QWEN36_35B_A3B_MTP_REPO" "$MODEL_QWEN36_35B_A3B_MTP_FILE"
  _dl_shard "$DSV4_FLASH_PATH"   "$MODEL_DSV4_FLASH_REPO"         "$MODEL_DSV4_FLASH_FILE_GLOB"
  _dl_shard "$LAGUNA_S_PATH"     "$MODEL_LAGUNA_S_REPO"           "$MODEL_LAGUNA_S_FILE_GLOB"

  info "Sélection des modèles préchargés au démarrage..."
  select_preload_models

  info "Génération de models.ini..."
  generate_models_ini > "$CONFIG_DIR/models.ini"

  info "✅ Config générée : $CONFIG_DIR/models.ini"
  info "Setup terminé → ./setup-llm.sh --start"
  info "Changer le préchargement → ./setup-llm.sh --preload"
  info "Comparer les backends → ./setup-llm.sh --bench [modèle]"
  info "Devices exposés → ./setup-llm.sh --list-devices"

  _maybe_restart_service
}

# =============================================================================
# update — retélécharge uniquement les fichiers modifiés en amont
#
# `hf download --local-dir` conserve les métadonnées de chaque fichier dans
# <dossier>/.cache/huggingface/download/. Au second passage il compare l'etag
# distant et ne retransfère que ce qui a réellement bougé — le reste ne coûte
# qu'une requête HEAD. Le seul travail du script est donc de ne PAS court-
# circuiter sur "fichier déjà présent" (REFRESH=1).
#
# Note : la toute première mise à jour d'un fichier téléchargé avant que les
# métadonnées n'existent oblige hf à recalculer son sha256 en local — comptez
# une lecture disque complète du GGUF, sans réseau.
#
# Updates amont connus (juillet/août 2026) à rattraper si téléchargés avant :
#   --update laguna-s-2.1   (fix rope/context 256K YaRN + fixes poolside)
#   --update gemma-31b      (template chat officiel Google)
#   --update gemma-12b      (template chat officiel Google)
#   --update qwen3.8-27b    (repo day-zero mi-août, template/quants mouvants)
#   --update qwopus3.6-27b-coder-mtp  (repo squashé, re-validation etags)
# =============================================================================

cmd_update() {
  ONLY="${1:-}"
  REFRESH=1

  if [[ -n "$ONLY" ]]; then
    [[ -d "$MODELS_BASE/$ONLY" ]] || error "Modèle inconnu : '$ONLY' (voir $MODELS_BASE/)"
    info "Vérification des mises à jour pour '$ONLY'..."
  else
    info "Vérification des mises à jour pour tous les modèles..."
  fi

  warn "Prévoir 2× la taille du plus gros fichier remplacé (écriture en .incomplete puis move)."
  warn "Un restart du service sera proposé en fin de run (poids mmap'és sur l'ancien inode sinon)."

  cmd_setup
}

# =============================================================================
# cleanup — supprime ce qui n'est plus référencé dans KNOWN_FILES
#
# Deux niveaux :
#   1. dossiers de premier niveau sous $MODELS_BASE dont plus aucun modèle ne
#      dépend (ex. qwen3.6-27b, qwen3.6-27b-mtp après leur remplacement par
#      qwen3.8-27b)
#   2. .gguf orphelins à l'intérieur d'un dossier encore référencé (ex. l'ancien
#      quant après un changement de UD-Q6_K_XL vers UD-Q4_K_XL)
#
# Les modèles en shards sont protégés au niveau du dossier de quant : KNOWN_FILES
# ne cite que le shard 00001, les suivants ne doivent évidemment pas sauter.
#
# Dry-run par défaut ; --yes pour exécuter réellement.
# =============================================================================

_in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

cmd_cleanup() {
  local assume_yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1

  [[ -d "$MODELS_BASE" ]] || error "$MODELS_BASE introuvable"

  local f d parent
  local -a keep_keys=() keep_files=() keep_dirs=()

  for f in "${KNOWN_FILES[@]}"; do
    d="$(dirname "$f")"
    parent="$(dirname "$d")"
    keep_keys+=("$(_key "$f")")
    if [[ "$parent" == "$MODELS_BASE" ]]; then
      # fichier plat : on protège le fichier lui-même
      keep_files+=("$f")
    else
      # layout en shards : on protège tout le dossier de quant
      keep_dirs+=("$d")
    fi
  done

  local -a doomed=()

  # 1. dossiers de modèle entiers
  while IFS= read -r d; do
    _in_list "$(basename "$d")" "${keep_keys[@]}" || doomed+=("$d")
  done < <(find "$MODELS_BASE" -mindepth 1 -maxdepth 1 -type d ! -name '.cache' | sort)

  # 2. .gguf orphelins dans les dossiers conservés
  while IFS= read -r f; do
    _in_list "$(_key "$f")" "${keep_keys[@]}" || continue  # déjà couvert par 1.
    _in_list "$f" "${keep_files[@]}" && continue
    _in_list "$(dirname "$f")" "${keep_dirs[@]}" && continue
    doomed+=("$f")
  done < <(find "$MODELS_BASE" -mindepth 2 -type f -name '*.gguf' | sort)

  if [[ ${#doomed[@]} -eq 0 ]]; then
    info "Rien à nettoyer, $MODELS_BASE est aligné sur le script."
    return
  fi

  warn "À supprimer (${#doomed[@]} entrée(s)) :"
  for f in "${doomed[@]}"; do
    echo "  $(du -sh "$f" 2>/dev/null | cut -f1)  $f"
  done

  if [[ "$assume_yes" -eq 0 ]]; then
    info "Dry-run — relance avec './setup-llm.sh --cleanup --yes' pour supprimer."
    return
  fi

  for f in "${doomed[@]}"; do
    rm -rf -- "$f"
    info "Supprimé : $f"
  done

  # dossiers de quant vidés + métadonnées hf devenues orphelines
  find "$MODELS_BASE" -mindepth 2 -type d -empty -delete 2>/dev/null || true

  info "✅ Nettoyage terminé."

  _maybe_restart_service
}

# =============================================================================
# bench — llama-bench Vulkan0 vs ROCm0, persistance du vainqueur
#
# Usage :
#   ./setup-llm.sh --bench            # interactif : cases à cocher (gum ou
#                                     #   fallback numéroté), device actuel
#                                     #   affiché par modèle ; non-interactif :
#                                     #   simple état des lieux
#   ./setup-llm.sh --bench <modèle>   # bench une clé (= dossier sous ~/models)
#   ./setup-llm.sh --bench all        # toutes les clés présentes sur disque
#
# Protocole : pp 4096 + pp 16384 (prefill) et tg 128 (décode), flash-attn on.
# Décision : score = geomean(pp16384, tg128) — un device qui échoue perd
# d'office. Le vainqueur est écrit dans bench-devices.conf (numéros bruts en
# commentaire), puis models.ini est régénéré : chaque preset pointant sur ce
# GGUF hérite du device. Redémarrer llama-server pour appliquer.
#
# Édition manuelle du conf possible (forcer un device) — conservée tant que la
# clé n'est pas re-benchée.
#
# Service llama-server : s'il tourne, le bench propose de l'arrêter (les
# always-on squattent sinon la RAM unifiée → résultats faussés puis persistés).
# Refus = bench annulé. Le redémarrage est garanti par trap EXIT (Ctrl-C
# compris) et intervient après la régénération du models.ini : le serveur
# repart directement sur les devices mesurés. Une instance llama-server hors
# systemd ne peut pas être relancée proprement → simple confirmation, à couper
# soi-même.
# =============================================================================

BENCH_PP="4096,16384"
BENCH_TG="128"

# Garde-fou de plausibilité : sur Strix Halo (256 Go/s), même le 2B plafonne
# ~125 t/s en décode — un tg au-dessus de ce seuil signifie un chemin backend
# cassé (génération garbage/effondrée chronométrée par llama-bench, vu sur
# qwen3-coder-next et deepseek-v4-flash sous ROCm : tg "2154" et "3694").
# Un device qui produit un tg > seuil est éliminé pour la clé, comme un échec.
# NB LFM2.5-2.6B : Liquid annonce ~113 t/s en décode *CPU* sur Ryzen AI Max+
#   395 — sur GPU l'arch conv hybride peut légitimement dépasser 200 t/s.
#   Si le bench l'élimine à tort en SUSPECT, vérifier une vraie génération
#   puis forcer le device à la main dans bench-devices.conf.
BENCH_TG_MAX_PLAUSIBLE=200

# Restart du service arrêté par cmd_bench — appelé via trap EXIT, donc garanti
# même sur Ctrl-C ou erreur en plein bench.
BENCH_STOPPED_SERVICE=0
_bench_restore_service() {
  if [[ "$BENCH_STOPPED_SERVICE" -eq 1 ]]; then
    info "Redémarrage de $SERVICE_NAME..."
    sudo systemctl start "$SERVICE_NAME" \
      || warn "Redémarrage en échec — relancer à la main : sudo systemctl start $SERVICE_NAME"
    BENCH_STOPPED_SERVICE=0
  fi
}

# Parse la sortie json de llama-bench → "pp4096=812.3 pp16384=624.1 tg128=13.2"
_bench_parse_json() {
  python3 - "$1" <<'PY'
import json, sys
try:
    data = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
out = []
for t in data:
    npr, ng = t.get("n_prompt", 0), t.get("n_gen", 0)
    ts = t.get("avg_ts", 0.0)
    if npr and not ng:
        out.append(f"pp{npr}={ts:.2f}")
    elif ng and not npr:
        out.append(f"tg{ng}={ts:.2f}")
print(" ".join(out))
PY
}

# Score d'un résultat "ppA=x ppB=y tgC=z" → geomean(dernier pp, premier tg)
_bench_score() {
  python3 - "$1" <<'PY'
import math, sys
pairs = dict(kv.split("=") for kv in sys.argv[1].split() if "=" in kv)
pps = [float(v) for k, v in pairs.items() if k.startswith("pp")]
tgs = [float(v) for k, v in pairs.items() if k.startswith("tg")]
if not pps or not tgs:
    sys.exit(1)
print(f"{math.sqrt(pps[-1] * tgs[0]):.2f}")
PY
}

# Réécrit bench-devices.conf : met à jour/ajoute la clé, préserve le reste.
#   $1 = clé, $2 = device vainqueur, $3 = ligne de détail (commentaire)
_bench_save() {
  local key="$1" dev="$2" detail="$3"
  local tmp
  tmp="$(mktemp)"
  {
    echo "; bench-devices.conf — généré par ./setup-llm.sh --bench"
    echo "; clé (dossier sous $MODELS_BASE) = device retenu pour le models.ini"
    echo "; score = geomean(pp16384, tg128) ; édition manuelle OK (écrasée au"
    echo "; prochain bench de la clé). Détails bruts en commentaires datés."
    if [[ -f "$BENCH_CONF" ]]; then
      # conserve les entrées et détails existants, sauf ceux de la clé re-benchée
      grep -v "^; bench-devices.conf" "$BENCH_CONF" \
        | grep -v "^; clé (dossier" \
        | grep -v "^; score = geomean" \
        | grep -v "^; prochain bench" \
        | grep -v "^${key}[[:space:]]*=" \
        | grep -v "^; ${key} :" || true
    fi
    echo "; ${key} : ${detail}"
    echo "${key} = ${dev}"
  } > "$tmp"
  mv "$tmp" "$BENCH_CONF"
}

# Bench une clé sur tous les devices dispo, décide, persiste. Retourne 1 si
# aucun device n'a produit de résultat.
_bench_one() {
  local target_key="$1"
  local model_path
  model_path="$(_path_for_key "$target_key")" || return 1
  [[ -f "$model_path" ]] || { warn "GGUF absent, skip : $model_path"; return 1; }

  info "Bench de '$target_key' — pp $BENCH_PP / tg $BENCH_TG, flash-attn on"
  info "  GGUF : $model_path"

  local dev rc json result score
  local best_dev="" best_score=0 detail=""

  for dev in "${AVAILABLE_DEVICES[@]}"; do
    echo ""
    info "=== $target_key / $dev ==="
    json="$(mktemp)"
    rc=0
    # GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 : sans effet Vulkan, requis HIP/iGPU
    GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 llama-bench \
      -m "$model_path" \
      -p "$BENCH_PP" \
      -n "$BENCH_TG" \
      -fa 1 \
      --device "$dev" \
      -o json > "$json" || rc=$?
    if [[ $rc -ne 0 ]]; then
      warn "Échec sur $dev (rc=$rc) — device éliminé pour cette clé."
      [[ "$dev" == ROCm* ]] && warn "  Pistes : rocblas/hipblaslt sans gfx1151, OOM GTT, runtime ROCm incomplet."
      detail+="$dev=ÉCHEC | "
      rm -f "$json"
      continue
    fi
    result="$(_bench_parse_json "$json" || true)"
    rm -f "$json"
    if [[ -z "$result" ]]; then
      warn "Sortie json illisible sur $dev — device éliminé pour cette clé."
      detail+="$dev=ÉCHEC | "
      continue
    fi
    # Plausibilité : tg aberrant = backend cassé, pas une perf
    local tgval
    tgval="$(echo "$result" | tr ' ' '\n' | sed -n 's/^tg[0-9]*=//p' | head -1)"
    if [[ -n "$tgval" ]] && python3 -c "import sys; sys.exit(0 if float('$tgval') > $BENCH_TG_MAX_PLAUSIBLE else 1)" 2>/dev/null; then
      warn "$dev : tg=$tgval t/s > $BENCH_TG_MAX_PLAUSIBLE (impossible sur ce matos) — chemin backend"
      warn "  probablement cassé pour cette arch, device éliminé. Vérifier qu'une vraie"
      warn "  génération sur $dev produit du texte cohérent avant de forcer à la main."
      detail+="$dev=SUSPECT($result) | "
      continue
    fi
    score="$(_bench_score "$result" || echo 0)"
    info "$dev : $result → score $score"
    detail+="$dev: $result score=$score | "
    if python3 -c "import sys; sys.exit(0 if float('$score') > float('$best_score') else 1)"; then
      best_score="$score"
      best_dev="$dev"
    fi
  done

  echo ""
  if [[ -z "$best_dev" ]]; then
    warn "Aucun résultat exploitable pour '$target_key' — conf inchangé."
    return 1
  fi

  detail+="$(date +%F)"
  _bench_save "$target_key" "$best_dev" "$detail"
  info "✅ '$target_key' → $best_dev (score $best_score), enregistré dans $BENCH_CONF"
}

# Sélection interactive des clés à bencher — gum (espace = cocher) si dispo,
# fallback numéroté sinon. Chaque entrée affiche le device actuellement retenu
# d'après bench-devices.conf. Résultat dans BENCH_TARGETS (vide = annulation).
# Seules les clés dont le GGUF est présent sur disque sont proposées.
BENCH_TARGETS=()
_bench_select_keys() {
  load_bench_conf
  BENCH_TARGETS=()

  local -a keys=() labels=()
  local f k label seen=" "
  for f in "${KNOWN_FILES[@]}"; do
    k="$(_key "$f")"
    [[ "$seen" == *" $k "* ]] && continue
    seen+="$k "
    [[ -f "$f" ]] || continue
    if [[ -n "${BENCH_DEVICE[$k]:-}" ]]; then
      label="$k — ${BENCH_DEVICE[$k]} (benché)"
    else
      label="$k — $DEFAULT_DEVICE (non benché, défaut)"
    fi
    keys+=("$k")
    labels+=("$label")
  done
  [[ ${#keys[@]} -gt 0 ]] || { warn "Aucun GGUF présent sous $MODELS_BASE — lancer --setup."; return; }

  local -a chosen=()
  if command -v gum >/dev/null 2>&1; then
    mapfile -t chosen < <(printf '%s\n' "${labels[@]}" \
      | gum choose --no-limit --height 20 \
          --header "Modèles à bencher (espace = cocher, entrée = valider)") || chosen=()
    # label → clé (premier champ avant " — "), lignes vides ignorées
    local line
    for line in "${chosen[@]}"; do
      [[ -n "$line" ]] || continue
      BENCH_TARGETS+=("${line%% — *}")
    done
  else
    info "gum absent (pacman -S gum pour les cases à cocher) — fallback numéroté."
    echo ""
    echo "Modèles à bencher :"
    local i=1
    for label in "${labels[@]}"; do
      printf "  %2d  %s\n" "$i" "$label"
      ((i++))
    done
    echo ""
    local input n
    read -r -p "Numéros à bencher (ex: 1 4), 'all' = tous, vide = annuler : " input
    if [[ "$input" == "all" ]]; then
      BENCH_TARGETS=("${keys[@]}")
    else
      for n in $input; do
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "'$n' ignoré (pas un numéro)"; continue; }
        (( n >= 1 && n <= ${#keys[@]} )) || { warn "'$n' ignoré (hors liste)"; continue; }
        BENCH_TARGETS+=("${keys[$((n-1))]}")
      done
    fi
  fi
}

cmd_bench() {
  local target="${1:-}"

  export PATH="$HOME/.local/bin:$PATH"

  # Résolution des cibles → BENCH_TARGETS
  local f k seen=" "
  if [[ -z "$target" ]]; then
    if [[ -t 0 ]]; then
      # Sans argument, interactif : sélection à cases à cocher
      _bench_select_keys
      [[ ${#BENCH_TARGETS[@]} -gt 0 ]] || { info "Rien sélectionné — bench annulé."; return; }
    else
      # Sans argument, non interactif : simple état des lieux
      load_bench_conf
      info "Clés benchables (dossiers sous $MODELS_BASE) :"
      for f in "${KNOWN_FILES[@]}"; do
        k="$(_key "$f")"
        [[ "$seen" == *" $k "* ]] && continue
        seen+="$k "
        if [[ -n "${BENCH_DEVICE[$k]:-}" ]]; then
          echo "  $k → ${BENCH_DEVICE[$k]}"
        elif [[ -f "$f" ]]; then
          echo "  $k → (non benché, héritera de $DEFAULT_DEVICE)"
        else
          echo "  $k → (GGUF absent)"
        fi
      done
      info "Lancer : ./setup-llm.sh --bench <clé>  ou  --bench all"
      return
    fi
  elif [[ "$target" == "all" ]]; then
    BENCH_TARGETS=()
    for f in "${KNOWN_FILES[@]}"; do
      k="$(_key "$f")"
      [[ "$seen" == *" $k "* ]] && continue
      seen+="$k "
      [[ -f "$f" ]] || { warn "Skip $k (GGUF absent)"; continue; }
      BENCH_TARGETS+=("$k")
    done
    [[ ${#BENCH_TARGETS[@]} -gt 0 ]] || error "Aucun GGUF présent — lancer --setup."
  else
    local model_path keys
    if ! model_path="$(_path_for_key "$target")"; then
      keys="$(for f in "${KNOWN_FILES[@]}"; do _key "$f"; done | sort -u | tr '\n' ' ')"
      error "Modèle inconnu : '$target' — clés valides : $keys"
    fi
    [[ -f "$model_path" ]] || error "GGUF absent : $model_path — lancer --setup d'abord"
    BENCH_TARGETS=("$target")
  fi

  info "À bencher : ${BENCH_TARGETS[*]}"

  command -v llama-bench >/dev/null || error "llama-bench introuvable (paquet llama-cpp)"
  command -v python3 >/dev/null || error "python3 introuvable"

  # --- llama-server ne doit pas tourner pendant le bench --------------------
  # (always-on chargés = RAM unifiée squattée = résultats faussés → persistés
  #  dans le conf : on refuse de bencher à côté d'un serveur actif)
  if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    local reply="o"
    if [[ -t 0 ]]; then
      warn "Le service $SERVICE_NAME tourne — il doit être arrêté pendant le bench."
      read -r -p "Arrêter $SERVICE_NAME maintenant (redémarré automatiquement à la fin) ? [O/n] " reply
      reply="${reply:-o}"
    else
      warn "Service $SERVICE_NAME actif, entrée non interactive → arrêt automatique."
    fi
    [[ "$reply" =~ ^[oOyY]$ ]] \
      || error "Bench annulé — arrêter le service puis relancer : sudo systemctl stop $SERVICE_NAME"
    info "Arrêt de $SERVICE_NAME..."
    sudo systemctl stop "$SERVICE_NAME" || error "Impossible d'arrêter $SERVICE_NAME"
    BENCH_STOPPED_SERVICE=1
    # Restart garanti même sur Ctrl-C / erreur — et comme le restart a lieu
    # APRÈS la régénération du models.ini, le serveur repart directement sur
    # les devices fraîchement mesurés.
    trap _bench_restore_service EXIT
  elif pgrep -x llama-server >/dev/null 2>&1; then
    # Instance hors service systemd : on ne sait pas la relancer proprement
    local reply="n"
    if [[ -t 0 ]]; then
      warn "Un llama-server tourne hors service systemd — résultats faussés garantis."
      read -r -p "Continuer quand même (déconseillé) ? [o/N] " reply
    fi
    [[ "$reply" =~ ^[oOyY]$ ]] \
      || error "Bench annulé — couper le llama-server manuel puis relancer."
  fi
  # --------------------------------------------------------------------------

  # Devices disponibles : Vulkan0 garanti, ROCm0 si le backend HIP se charge
  AVAILABLE_DEVICES=()
  local dev
  for dev in "${BENCH_DEVICES[@]}"; do
    if [[ "$dev" == "$DEFAULT_DEVICE" ]] \
       || llama-bench --list-devices 2>/dev/null | grep -q "$dev"; then
      AVAILABLE_DEVICES+=("$dev")
    else
      warn "$dev non exposé par llama-bench (ggml-hip/runtime absent ou gfx non supporté), ignoré."
    fi
  done
  [[ ${#AVAILABLE_DEVICES[@]} -lt 2 ]] \
    && warn "Un seul device dispo (${AVAILABLE_DEVICES[*]}) — le bench fixera quand même la baseline."

  for k in "${BENCH_TARGETS[@]}"; do
    _bench_one "$k" || true
    echo ""
  done

  # Régénération du ini avec les devices fraîchement mesurés
  info "Régénération de models.ini avec les devices du bench..."
  generate_models_ini > "$CONFIG_DIR/models.ini"
  if [[ "$BENCH_STOPPED_SERVICE" -eq 1 ]]; then
    info "✅ models.ini à jour — le service va redémarrer sur les devices mesurés."
  else
    info "✅ models.ini à jour — redémarrer llama-server pour appliquer."
  fi
  info "Rappel presets MTP : valider la spéculation dans les logs après une bascule ROCm."
}

# =============================================================================
# list-devices — devices exposés par ggml (Vulkan0, ROCm0…) + backends installés
#
# Diagnostic rapide après une mise à jour (split ggml, runtime ROCm) : si un
# device référencé dans bench-devices.conf n'apparaît plus ici, les presets
# qui en héritent échoueront au chargement.
# =============================================================================

cmd_list_devices() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v llama-bench >/dev/null || error "llama-bench introuvable (paquet llama-cpp)"

  info "Backends ggml installés :"
  local pkg
  for pkg in ggml-cpu ggml-vulkan ggml-hip ggml-cuda ggml-blas ggml-openvino; do
    if paru -Qi "$pkg" &>/dev/null; then
      echo "  ✔ $pkg"
    else
      echo "  · $pkg (absent)"
    fi
  done

  echo ""
  info "Devices exposés (llama-bench --list-devices) :"
  llama-bench --list-devices 2>&1 | sed 's/^/  /'

  # Croisement avec bench-devices.conf : devices retenus mais plus exposés
  load_bench_conf
  [[ ${#BENCH_DEVICE[@]} -gt 0 ]] || return 0
  local devs k d
  devs="$(llama-bench --list-devices 2>/dev/null)"
  local -a missing=()
  for k in "${!BENCH_DEVICE[@]}"; do
    d="${BENCH_DEVICE[$k]}"
    grep -q "$d" <<<"$devs" || missing+=("$k → $d")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo ""
    warn "Clés de bench-devices.conf pointant sur un device NON exposé :"
    printf '  %s\n' "${missing[@]}" | sort
    warn "  → ces presets échoueront au chargement. Réinstaller le backend"
    warn "    (ex. paru -S ggml-hip) ou forcer Vulkan0 dans $BENCH_CONF puis --preload."
  fi
}

# =============================================================================
# spec-test — mesure le décode réel d'un preset via l'API (chemin spéculatif
# inclus, contrairement à --bench qui ne mesure que le forward standard)
#
# Usage : ./setup-llm.sh --spec-test [preset] [passes]
#   preset : sans argument, sélection interactive parmi les presets MTP dont
#            le GGUF est présent (gum ou fallback numéroté ; non interactif =
#            premier de la liste) ; passes : défaut 4 (1 froide + 3 utiles)
#
# Envoie N fois le même prompt (module Python + tests pytest, ~1-1.5K tokens
# de sortie, code structuré = meilleur cas MTP), seed fixe par passe (42+i :
# reproductible d'un run à l'autre, sortie identique quel que soit le n-max
# puisque la spéculation est sans perte → comparaisons sans bruit de sampling,
# tout en couvrant plusieurs trajectoires), et affiche prompt/gen t/s
# depuis `timings` de llama-server, plus l'acceptance MTP (draft_n_accepted /
# draft_n, renvoyés dans le même `timings` — pas besoin de journalctl). La 1re
# passe est marquée (cache froid), comparer les médianes des suivantes.
# L'en-tête reprend tout le contexte (host, versions llama-cpp/ggml, GGUF,
# device, corps du preset) pour que le bloc soit auto-suffisant à partager.
# Chaque run est journalisé dans spec-tests.log ; dès 2 runs à des n-max
# différents (même preset/GGUF/device), l'analyse finale calibre
# t/s = (1+Σα^i)/(t_base + k·t_draft) et recommande le n-max cible.
#
# Protocole pour régler spec-draft-n-max d'un preset MTP :
#   1. --spec-test <preset>                    (valeur courante)
#   2. éditer spec-draft-n-max dans MODEL_INI[<preset>] du SCRIPT (pas le ini,
#      il est régénéré), ./setup-llm.sh --preload (+ restart), --spec-test
#   3. répéter, garder la meilleure valeur, --preload une dernière fois
# =============================================================================

SPEC_TEST_URL="http://localhost:8009"
# Journal des runs (à côté du script) — sert à l'analyse n-max : dès 2 runs à
# des n-max différents sur le même preset/GGUF/device, le script calibre un
# modèle simple et prédit la courbe t/s(n-max).
SPEC_LOG="$SCRIPT_DIR/spec-tests.log"
# Surcharges spec-draft-n-max par preset (à côté du script, comme
# bench-devices.conf) — écrit par --spec-tune, appliqué par generate_models_ini
# par-dessus la valeur de MODEL_INI (qui reste le défaut). Format "preset = k".
SPEC_CONF="$SCRIPT_DIR/spec-nmax.conf"

declare -A SPEC_NMAX
load_spec_conf() {
  SPEC_NMAX=()
  [[ -f "$SPEC_CONF" ]] || return 0
  local line k v
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*($|\;|\#) ]] && continue
    k="${line%%=*}"; k="${k// /}"
    v="${line#*=}";  v="${v// /}"
    [[ -n "${MODEL_INI[$k]:-}" && "$v" =~ ^[0-9]+$ ]] && SPEC_NMAX[$k]="$v"
  done < "$SPEC_CONF"
}

_spec_save_conf() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  {
    echo "; spec-nmax.conf — spec-draft-n-max retenu par preset MTP"
    echo "; généré par ./setup-llm.sh --spec-tune ; édition manuelle OK ;"
    echo "; supprimer une ligne = retour au défaut du script"
    if [[ -f "$SPEC_CONF" ]]; then
      grep -v '^;' "$SPEC_CONF" | grep -v "^${key}[[:space:]]*=" | grep -v '^[[:space:]]*$' || true
    fi
    echo "${key} = ${val}"
  } > "$tmp"
  mv "$tmp" "$SPEC_CONF"
}

# n-max effectif d'un preset : surcharge conf sinon valeur MODEL_INI (vide si
# preset non spéculatif). SPEC_NMAX_FORCE (env) prime sur tout — utilisé par
# --spec-tune pour tester une valeur sans l'écrire.
_preset_nmax() {
  local p="$1" v
  v="$(echo "${MODEL_INI[$p]}" | sed -n 's/^spec-draft-n-max[[:space:]]*=[[:space:]]*//p' | tr -d ' ')"
  [[ -n "$v" ]] || { echo ""; return; }
  if [[ -n "${SPEC_NMAX_FORCE:-}" && "${SPEC_NMAX_FORCE_PRESET:-}" == "$p" ]]; then
    echo "$SPEC_NMAX_FORCE"; return
  fi
  echo "${SPEC_NMAX[$p]:-$v}"
}

# Presets spéculatifs (spec-type = draft-mtp) dont le GGUF est présent, dans
# l'ordre de PRESET_ORDER → SPEC_PRESETS
SPEC_PRESETS=()
_spec_presets() {
  SPEC_PRESETS=()
  local p body gguf
  for p in "${PRESET_ORDER[@]}"; do
    body="${MODEL_INI[$p]}"
    echo "$body" | grep -q '^spec-type[[:space:]]*=[[:space:]]*draft-mtp' || continue
    gguf="$(echo "$body" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
    [[ -f "$gguf" ]] || continue
    SPEC_PRESETS+=("$p")
  done
}

# Sélection interactive du preset MTP à tester (gum si dispo, sinon numéroté).
# Non interactif : premier de la liste. Résultat dans SPEC_CHOICE (vide = annulé).
SPEC_CHOICE=""
_spec_select_preset() {
  _spec_presets
  SPEC_CHOICE=""
  [[ ${#SPEC_PRESETS[@]} -gt 0 ]] || error "Aucun preset MTP avec GGUF présent — lancer --setup."

  if [[ ! -t 0 ]]; then
    SPEC_CHOICE="${SPEC_PRESETS[0]}"
    info "Entrée non interactive — preset MTP : $SPEC_CHOICE"
    return
  fi

  local -a labels=()
  local p nmax
  load_spec_conf
  for p in "${SPEC_PRESETS[@]}"; do
    nmax="$(_preset_nmax "$p")"
    labels+=("$p — n-max ${nmax:-?}")
  done

  if command -v gum >/dev/null 2>&1; then
    local line
    line="$(printf '%s\n' "${labels[@]}" \
      | gum choose --height 15 --header "Preset MTP à tester (entrée = valider)")" || line=""
    [[ -n "$line" ]] && SPEC_CHOICE="${line%% — *}"
  else
    info "gum absent (pacman -S gum) — fallback numéroté."
    echo ""
    echo "Presets MTP disponibles :"
    local i=1
    for p in "${labels[@]}"; do
      printf "  %2d  %s\n" "$i" "$p"
      ((i++))
    done
    echo ""
    local n
    read -r -p "Numéro à tester (vide = annuler) : " n
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#SPEC_PRESETS[@]} )); then
      SPEC_CHOICE="${SPEC_PRESETS[$((n-1))]}"
    fi
  fi
}

cmd_spec_test() {
  local preset="${1:-}"
  local passes="${2:-4}"
  if [[ -z "$preset" ]]; then
    _spec_select_preset
    [[ -n "$SPEC_CHOICE" ]] || { info "Rien sélectionné — spec-test annulé."; return; }
    preset="$SPEC_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Preset inconnu : '$preset' (voir --help)"
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 1 ]] || error "Nombre de passes invalide : '$passes'"
  command -v curl >/dev/null || error "curl introuvable"
  command -v python3 >/dev/null || error "python3 introuvable"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — sudo systemctl start $SERVICE_NAME"

  load_spec_conf
  local nmax nmax_cfg nmax_srv
  nmax_cfg="$(_preset_nmax "$preset")"
  # Valeur RÉELLE côté serveur : /v1/models expose status.args de chaque preset
  # (le routeur lit le ini au démarrage — le script peut dire 2 quand le serveur
  # tourne encore à 4). C'est elle qui est journalisée et affichée.
  nmax_srv="$(curl -s "$SPEC_TEST_URL/v1/models" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data", []):
    if m.get("id") == sys.argv[1]:
        a = (m.get("status") or {}).get("args") or []
        for i, x in enumerate(a):
            if x == "--spec-draft-n-max" and i + 1 < len(a):
                print(a[i+1]); break
        break
' "$preset" 2>/dev/null || true)"
  nmax="${nmax_srv:-$nmax_cfg}"
  if [[ -n "$nmax_srv" && -n "$nmax_cfg" && "$nmax_srv" != "$nmax_cfg" ]]; then
    warn "Désaccord n-max : serveur=$nmax_srv, script/conf=$nmax_cfg → le ini a changé sans restart."
    warn "  Ce run mesure et journalise n-max $nmax_srv (réel). Appliquer la config : sudo systemctl restart $SERVICE_NAME"
  fi

  # --- En-tête : contexte complet du run, à coller tel quel dans un échange ---
  load_bench_conf
  local mkey mdev gguf gsize llver
  mkey="$(_preset_model_key "$preset" || true)"
  mdev="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE}"
  gguf="$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
  gsize="$(du -h "$gguf" 2>/dev/null | cut -f1 || echo '?')"
  llver="$(paru -Q llama-cpp ggml 2>/dev/null | tr '\n' ' ')"
  local kernel cpu
  kernel="$(uname -r)"
  cpu="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"

  echo "=== spec-test ==="
  echo "date       : $(date '+%F %T')"
  echo "host       : $(hostname) — $cpu — $kernel"
  echo "llama.cpp  : ${llver:-?}"
  echo "preset     : $preset"
  echo "gguf       : $(basename "$gguf") ($gsize)"
  echo "device     : $mdev"
  echo "n-max      : ${nmax:-n/a}$( [[ -n "$nmax_srv" ]] && echo " (lu sur le serveur)" || echo " (script/conf)" )$( [[ -n "$nmax_srv" && -n "$nmax_cfg" && "$nmax_srv" != "$nmax_cfg" ]] && echo "  ⚠ script/conf=$nmax_cfg, restart requis" )"
  echo "passes     : $passes (max_tokens=1500, temp=0.7, seed=42+n° de passe, prompt fixe inventory/pytest)"
  echo "note       : prompt t/s significatif en passe 1 seulement (prompt cache ensuite, cf. n=/cache=)"
  echo "--- preset ($preset) ---"
  if [[ -n "$nmax" ]]; then
    echo "${MODEL_INI[$preset]}" | sed '/^$/d' \
      | sed "s/^\(spec-draft-n-max[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1$nmax/;s/^/  /"
    [[ -n "$nmax_srv" && "$nmax_srv" != "$nmax_cfg" ]] \
      && echo "  (spec-draft-n-max ci-dessus = valeur SERVEUR ; le script/conf dit $nmax_cfg)"
    [[ -n "${SPEC_NMAX_FORCE:-}" && "${SPEC_NMAX_FORCE_PRESET:-}" == "$preset" ]] \
      && echo "  (spec-draft-n-max forcé par --spec-tune, non persistant)"
    [[ -n "${SPEC_NMAX[$preset]:-}" && -z "${SPEC_NMAX_FORCE:-}" ]] \
      && echo "  (spec-draft-n-max issu de spec-nmax.conf, défaut script = $(echo "${MODEL_INI[$preset]}" | sed -n 's/^spec-draft-n-max[[:space:]]*=[[:space:]]*//p' | tr -d ' '))"
  else
    echo "${MODEL_INI[$preset]}" | sed '/^$/d;s/^/  /'
  fi
  echo "--- résultats ---"

  local prompt
  prompt='Écris un module Python `inventory.py` complet, sans commentaire superflu, contenant :\n1. une dataclass `Item` (sku: str, name: str, qty: int, unit_price: float) avec validation dans __post_init__ (qty >= 0, unit_price > 0, sku non vide) ;\n2. une classe `Inventory` avec add(item), remove(sku, qty), get(sku), total_value(), low_stock(threshold=5) qui renvoie une liste triée par qty croissante, et to_json()/from_json(str) ;\n3. les exceptions `ItemNotFound` et `InsufficientStock` ;\n4. un bloc de tests pytest (`test_inventory.py`) couvrant chaque méthode, y compris les cas d'\''erreur, avec au moins 12 tests.\nRéponds uniquement avec les deux fichiers dans des blocs de code.'

  # seed fixe PAR PASSE (42+i) : chaque passe est reproductible d'un run à
  # l'autre (la spéculation étant sans perte, deux n-max produisent la même
  # sortie à seed égal → comparaison à trajectoire identique, sans bruit de
  # sampling), tout en gardant plusieurs trajectoires distinctes dans un run
  # (une seule seed sur-représenterait un cas particulier).
  local body i out

  local -a gens=() accs=()
  local sum_dn=0 sum_da=0 sum_pn=0
  for (( i=1; i<=passes; i++ )); do
    body="$(printf '{"model":"%s","max_tokens":1500,"temperature":0.7,"seed":%d,"messages":[{"role":"user","content":"%s"}]}' "$preset" $((42 + i)) "$prompt")"
    out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
      || { warn "Passe $i : échec curl"; continue; }
    local line
    line="$(python3 - "$out" "$i" "${nmax:+spec}" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    print(f"passe {sys.argv[2]} : réponse illisible"); sys.exit(1)
if "error" in d:
    print(f"passe {sys.argv[2]} : erreur serveur — {d['error']}"); sys.exit(1)
t = d.get("timings") or {}
pp, tg, n = t.get("prompt_per_second", 0), t.get("predicted_per_second", 0), t.get("predicted_n", 0)
pn = t.get("prompt_n", 0)
cached = t.get("cache_n", 0)
dn, da = t.get("draft_n"), t.get("draft_n_accepted")
if dn:
    acc = f"  acceptance={da/dn:.2f} ({da}/{dn})"
elif "spec" in sys.argv[3]:
    acc = "  acceptance=n/a (pas de draft_n dans timings : spéculation inactive ?)"
else:
    acc = ""
tag = "  (cache froid, à ignorer)" if sys.argv[2] == "1" else ""
# prompt_n petit = prompt cache actif → prompt t/s non significatif (résidu + overhead)
pptxt = f"prompt={pp:.0f} t/s (n={pn}, cache={cached})" if pn else f"prompt={pp:.0f} t/s"
print(f"passe {sys.argv[2]} : {pptxt}  gen={tg:.2f} t/s  n={n}{acc}{tag}")
print(f"GEN={tg:.2f}")
if dn: print(f"ACC={da/dn:.3f}"); print(f"DN={dn} DA={da} PN={n}")
PY
)" || true
    echo "$line" | grep -v '^GEN=\|^ACC=\|^DN=' | sed 's/^/  /'
    local g a dn da pn
    g="$(echo "$line" | sed -n 's/^GEN=//p')"
    a="$(echo "$line" | sed -n 's/^ACC=//p')"
    dn="$(echo "$line" | sed -n 's/^DN=\([0-9]*\) DA=\([0-9]*\) PN=\([0-9]*\)$/\1/p')"
    da="$(echo "$line" | sed -n 's/^DN=\([0-9]*\) DA=\([0-9]*\) PN=\([0-9]*\)$/\2/p')"
    pn="$(echo "$line" | sed -n 's/^DN=\([0-9]*\) DA=\([0-9]*\) PN=\([0-9]*\)$/\3/p')"
    if [[ "$i" -gt 1 ]]; then
      [[ -n "$g" ]] && gens+=("$g")
      [[ -n "$a" ]] && accs+=("$a")
      [[ -n "$dn" ]] && { sum_dn=$((sum_dn + dn)); sum_da=$((sum_da + da)); sum_pn=$((sum_pn + pn)); }
    fi
  done

  local med
  if [[ ${#gens[@]} -gt 0 ]]; then
    med="$(printf '%s\n' "${gens[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
    info "Médiane gen (hors 1re passe) : $med t/s"
  fi
  local med_gen="" med_acc=""
  [[ ${#gens[@]} -gt 0 ]] && med_gen="$(printf '%s\n' "${gens[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
  if [[ ${#accs[@]} -gt 0 ]]; then
    med_acc="$(printf '%s\n' "${accs[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
    info "Médiane acceptance (hors 1re passe) : $med_acc"
  fi

  # --- Journal + analyse n-max ---------------------------------------------
  if [[ -n "$nmax" && -n "$med_gen" && "$sum_dn" -gt 0 ]]; then
    # date preset gguf device nmax gen acc drafted accepted predicted
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date '+%F %T')" "$preset" "$(basename "$gguf")" "$mdev" "$nmax" \
      "$med_gen" "$med_acc" "$sum_dn" "$sum_da" "$sum_pn" >> "$SPEC_LOG"
    echo "--- analyse n-max ---"
    _spec_analyze "$preset" "$(basename "$gguf")" "$mdev" "$nmax"
  fi
  echo "================="
}

# Analyse des runs journalisés pour (preset, gguf, device).
# Modèle : par forward, k tokens draftés, acceptés en séquence avec proba α par
# position (α^i) → tokens/forward T(k) = 1 + Σ_{i=1..k} α^i ; temps/forward
# t(k) = t_base + k·t_draft. α est ajusté sur le run courant (accepted/drafted),
# t_base/t_draft par régression sur les runs à n-max distincts. Prédit t/s pour
# k = 1..10, recommande l'argmax (à égalité <2 %, le k le plus petit — l'accep-
# tance chute sur du texte moins prévisible que le prompt de test, un draft
# court est plus robuste).
_spec_analyze() {
  python3 - "$SPEC_LOG" "$1" "$2" "$3" "$4" "${5:-}" <<'PY'
import sys, math
log, preset, gguf, dev, cur_k = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
runs = []
try:
    for line in open(log, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 10 or f[1] != preset or f[2] != gguf or f[3] != dev: continue
        try:
            runs.append(dict(k=int(f[4]), gen=float(f[5]), dn=int(f[7]), da=int(f[8]), pn=int(f[9])))
        except ValueError:
            continue
except FileNotFoundError:
    pass
if not runs:
    print("  (aucun run journalisé)"); sys.exit(0)

# un point par n-max : le plus récent
by_k = {}
for r in runs: by_k[r["k"]] = r
cur = by_k.get(cur_k) or runs[-1]

# α : résout (Σ_{i=1..k} α^i)/k = accepted/drafted par bissection
def acc_ratio(a, k): return sum(a**i for i in range(1, k+1)) / k
target = cur["da"] / cur["dn"]
lo, hi = 0.0, 1.0
for _ in range(60):
    mid = (lo+hi)/2
    if acc_ratio(mid, cur["k"]) < target: lo = mid
    else: hi = mid
alpha = (lo+hi)/2
def T(k): return 1 + sum(alpha**i for i in range(1, k+1))
# tokens/forward mesurés = predicted / forwards, forwards = predicted - accepted
tpf_meas = cur["pn"] / max(1, cur["pn"] - cur["da"])
print(f"  run courant : n-max {cur['k']}  {cur['gen']:.2f} t/s  acceptance/token {target:.3f}"
      f"  → α≈{alpha:.3f}  tokens/forward {tpf_meas:.2f} (plafond {cur['k']+1})")
# Cohérence : plus de tokens/forward que k+1 = le serveur ne tournait PAS à ce
# n-max (ini modifié sans restart). Le run est faux, on ne calibre pas dessus.
bad = sorted(k for k, r in by_k.items() if r["pn"] / max(1, r["pn"] - r["da"]) > k + 1.05)
if bad:
    print(f"  ⚠ run(s) journalisé(s) sous n-max {bad} avec tokens/forward > plafond : n-max réel"
          f" différent (ini changé sans restart). Supprimer ces lignes de {log} avant de recalibrer.")
    sys.exit(0)

pts = sorted(by_k.values(), key=lambda r: r["k"])
if len(pts) < 2:
    nxt = cur["k"] + 2 if cur["k"] < 6 else max(1, cur["k"] - 2)
    print(f"  1 seul n-max journalisé — pas de calibration possible.")
    print(f"  → lancer un run à spec-draft-n-max = {nxt} pour calibrer et obtenir la courbe prédite.")
    sys.exit(0)

# régression t_fwd(k) = t_base + t_draft·k, avec t_fwd = tokens/forward / t/s
xs = [r["k"] for r in pts]
ys = [(r["pn"] / max(1, r["pn"] - r["da"])) / r["gen"] for r in pts]
n = len(xs); mx, my = sum(xs)/n, sum(ys)/n
sxx = sum((x-mx)**2 for x in xs)
t_draft = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sxx if sxx else 0.0
t_base = my - t_draft*mx
if t_base <= 0 or t_draft < 0:
    print(f"  calibration incohérente (t_base={t_base*1000:.0f} ms, t_draft={t_draft*1000:.1f} ms) — runs trop bruités ?"
          " Refaire un run propre (service fraîchement redémarré, machine au repos).")
    sys.exit(0)
print(f"  calibration sur n-max {xs} : t_base≈{t_base*1000:.0f} ms/forward (≈{1/t_base:.1f} t/s sans spéculation),"
      f" t_draft≈{t_draft*1000:.1f} ms/token drafté")

pred = {k: T(k)/(t_base + t_draft*k) for k in range(1, 11)}
best_k = max(pred, key=pred.get)
best = pred[best_k]
# à <2 % du max, préférer le plus petit k
rec = min(k for k, v in pred.items() if v >= best*0.98)
line = "  prédiction  : " + "  ".join(f"k{k}={v:.1f}" for k, v in pred.items())
print(line)
meas = "  mesuré      : " + "  ".join(f"k{r['k']}={r['gen']:.1f}" for r in pts)
print(meas)
# Recommandation MESURÉE (sert à --spec-tune) : parmi les k réellement testés,
# le plus petit à <2 % du meilleur mesuré — les mesures priment sur le modèle.
best_meas = max(r["gen"] for r in pts)
rec_meas = min(r["k"] for r in pts if r["gen"] >= best_meas*0.98)
print(f"  → mesuré : n-max {rec_meas} (meilleur {best_meas:.1f} t/s ; à <2 %, le plus petit k gagne)")
if len(sys.argv) > 6 and sys.argv[6] == "rec":
    print(f"REC={rec_meas}")
gain = (pred[rec] / cur["gen"] - 1) * 100
if rec == cur["k"]:
    print(f"  → modèle : n-max {cur['k']} est déjà l'optimum (max prédit {best:.1f} t/s à k{best_k}, écart <2 %).")
elif gain < 3:
    print(f"  → modèle : n-max {rec} suggéré mais gain <3 % vs {cur['k']} : plateau atteint.")
else:
    print(f"  → modèle : n-max {rec} suggéré (prédit {pred[rec]:.1f} t/s, +{gain:.0f} % vs {cur['k']}) — à confirmer par un run (--spec-tune l'inclura).")
PY
}

# =============================================================================
# spec-tune — boucle automatique sur plusieurs n-max, mesure, choisit, persiste
#
# Usage : ./setup-llm.sh --spec-tune [preset] [k1,k2,...] [passes]
#   preset : sélection interactive si absent ; liste défaut "2,4,6" ; passes 4.
#
# Pour chaque k : models.ini régénéré avec le n-max forcé (SPEC_NMAX_FORCE),
# restart du service systemd, attente /health, --spec-test (journalisé). À la
# fin : analyse sur tous les runs, choix = meilleur MESURÉ (à <2 %, le plus
# petit k), écriture dans spec-nmax.conf, ini régénéré, restart final.
# Sudo demandé au premier restart (cache sudo ensuite). Le service systemd est
# requis (un llama-server manuel ne peut pas être relancé proprement).
# =============================================================================

cmd_spec_tune() {
  local preset="${1:-}"
  local klist="${2:-2,4,6}"
  local passes="${3:-4}"

  if [[ -z "$preset" ]]; then
    _spec_select_preset
    [[ -n "$SPEC_CHOICE" ]] || { info "Rien sélectionné — spec-tune annulé."; return; }
    preset="$SPEC_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Preset inconnu : '$preset'"
  echo "${MODEL_INI[$preset]}" | grep -q '^spec-type[[:space:]]*=[[:space:]]*draft-mtp' \
    || error "'$preset' n'est pas un preset spéculatif (spec-type = draft-mtp requis)"
  systemctl is-enabled "$SERVICE_NAME" &>/dev/null \
    || error "Service $SERVICE_NAME non installé — --spec-tune a besoin de le redémarrer entre deux n-max (--install-service)."

  local -a ks=()
  local k
  IFS=',' read -r -a ks <<< "$klist"
  for k in "${ks[@]}"; do
    [[ "$k" =~ ^[0-9]+$ && "$k" -ge 1 && "$k" -le 16 ]] || error "n-max invalide : '$k' (1..16)"
  done

  load_spec_conf
  local before
  before="$(_preset_nmax "$preset")"
  info "spec-tune '$preset' — n-max à tester : ${ks[*]} ($passes passes chacun), valeur actuelle : $before"
  warn "Chaque n-max = régénération du ini + restart de $SERVICE_NAME (les modèles préchargés se rechargent)."

  local gguf mkey mdev
  gguf="$(basename "$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)")"
  load_bench_conf
  mkey="$(_preset_model_key "$preset" || true)"
  mdev="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE}"

  # Restore garanti (Ctrl-C en plein tune : on remet la config non forcée)
  SPEC_TUNE_DIRTY=0
  _spec_tune_restore() {
    if [[ "$SPEC_TUNE_DIRTY" -eq 1 ]]; then
      warn "spec-tune interrompu — régénération du ini sans valeur forcée + restart."
      unset SPEC_NMAX_FORCE SPEC_NMAX_FORCE_PRESET
      generate_models_ini > "$CONFIG_DIR/models.ini"
      sudo systemctl restart "$SERVICE_NAME" || true
      SPEC_TUNE_DIRTY=0
    fi
  }
  trap _spec_tune_restore EXIT

  for k in "${ks[@]}"; do
    echo ""
    info "════════ n-max = $k ════════"
    export SPEC_NMAX_FORCE="$k" SPEC_NMAX_FORCE_PRESET="$preset"
    SPEC_TUNE_DIRTY=1
    generate_models_ini > "$CONFIG_DIR/models.ini"
    sudo systemctl restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    # attente du routeur (les poids se chargent à la 1re requête, passe froide ignorée)
    local t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      [[ $t -ge 120 ]] && error "llama-server ne répond pas après 120 s — journalctl -u $SERVICE_NAME -e"
    done
    cmd_spec_test "$preset" "$passes"
  done
  unset SPEC_NMAX_FORCE SPEC_NMAX_FORCE_PRESET

  echo ""
  info "════════ Bilan ════════"
  local rec report
  report="$(_spec_analyze "$preset" "$gguf" "$mdev" "${ks[-1]}" rec)"
  echo "$report" | grep -v '^REC='
  rec="$(echo "$report" | sed -n 's/^REC=//p')"
  if [[ ! "$rec" =~ ^[0-9]+$ ]]; then
    warn "Pas de recommandation exploitable — config remise à l'état initial ($before)."
    generate_models_ini > "$CONFIG_DIR/models.ini"
    sudo systemctl restart "$SERVICE_NAME" || true
    SPEC_TUNE_DIRTY=0
    return
  fi

  _spec_save_conf "$preset" "$rec"
  load_spec_conf
  generate_models_ini > "$CONFIG_DIR/models.ini"
  info "✅ $preset : spec-draft-n-max = $rec enregistré dans $SPEC_CONF (avant : $before)"
  info "Restart final de $SERVICE_NAME sur la valeur retenue..."
  sudo systemctl restart "$SERVICE_NAME" || warn "Restart en échec — sudo systemctl restart $SERVICE_NAME"
  SPEC_TUNE_DIRTY=0
  trap - EXIT
}

# =============================================================================
# preload — re-sélectionner les modèles préchargés sans refaire le setup
# =============================================================================

cmd_preload() {
  select_preload_models
  info "Régénération de models.ini..."
  generate_models_ini > "$CONFIG_DIR/models.ini"
  info "✅ models.ini à jour."

  _maybe_restart_service
}

# =============================================================================
# start
# =============================================================================

cmd_start() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v llama-server >/dev/null || error "llama-server introuvable"
  [[ -f "$CONFIG_DIR/models.ini" ]] || error "Config introuvable — lance d'abord --setup"

  # --models-max dérivé de preload.conf : nb de presets préchargés + 1 slot
  #   LRU pour le modèle appelé à la demande (minimum 2).
  load_preload_conf
  local models_max=$(( ${#PRELOADED[@]} + 1 ))
  (( models_max < 2 )) && models_max=2

  info "Lancement de llama-server (router mode) sur :8009..."
  info "  Préchargés : $(_preload_summary) — models-max=$models_max"

  # --models-autoload : désormais activé par défaut côté llama-server, gardé
  #   explicite par lisibilité.
  # WebUI disponible sur http://0.0.0.0:8009
  llama-server \
    --host 0.0.0.0 \
    --port 8009 \
    --models-preset "$CONFIG_DIR/models.ini" \
    --models-max "$models_max" \
    --models-autoload \
    --jinja
}

# =============================================================================
# Service systemd système
# =============================================================================

SERVICE_NAME="llama-server"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"

cmd_install_service() {
  info "Génération du service systemd système..."

  local script_path
  script_path="$(realpath "$0")"

  # GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 : sans effet côté Vulkan, nécessaire côté
  # ROCm/HIP sur iGPU (alloc en mémoire unifiée/GTT au lieu de la VRAM dédiée) —
  # posé d'office pour que la bascule d'un preset en ROCm0 ne demande pas de
  # retoucher le service.
  sudo tee "$SERVICE_FILE" > /dev/null << SERVICE
[Unit]
Description=llama-server — LLM router mode natif
After=network.target

[Service]
Type=simple
User=$USER
Group=$(id -gn)
ExecStart=${script_path} --start
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment="PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=$HOME"
Environment="GGML_CUDA_ENABLE_UNIFIED_MEMORY=1"

[Install]
WantedBy=multi-user.target
SERVICE

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"

  info "✅ Service installé : $SERVICE_FILE"
  info "  Démarrage automatique au boot activé (multi-user.target)"
  info "Commandes utiles :"
  info "  sudo systemctl start   $SERVICE_NAME"
  info "  sudo systemctl stop    $SERVICE_NAME"
  info "  sudo systemctl restart $SERVICE_NAME"
  info "  sudo systemctl status  $SERVICE_NAME"
  info "  journalctl -u $SERVICE_NAME -f"
}

cmd_uninstall_service() {
  if ! systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
    warn "Service '$SERVICE_NAME' non installé, rien à faire."
    return
  fi

  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME"
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload

  info "✅ Service '$SERVICE_NAME' désinstallé."
}

# =============================================================================
# help
# =============================================================================

cmd_help() {
  cat <<HELP
setup-llm.sh — llama-server en router mode natif (Strix Halo, Vulkan/ROCm)

Usage : ./setup-llm.sh [commande] [options]

Commandes :
  --setup                  Installe les dépendances (paru), propose le runtime ROCm
                           + ggml-hip, télécharge les GGUF manquants, sélection
                           interactive du préchargement, génère $CONFIG_DIR/models.ini
  --update [modèle]        Comme --setup mais laisse hf comparer les etags et ne
                           retélécharge que ce qui a bougé en amont
                           (modèle = dossier sous $MODELS_BASE, ex. qwen3.8-27b)
  --cleanup [--yes]        Supprime dossiers/GGUF orphelins (plus dans KNOWN_FILES).
                           Dry-run par défaut, --yes pour exécuter
  --preload                Re-sélectionne les presets préchargés (always-on) et
                           régénère models.ini (--models-max = nb préchargés + 1)
  --bench [modèle|all]     llama-bench Vulkan0 vs ROCm0 (pp 4096/16384, tg 128),
                           vainqueur écrit dans bench-devices.conf, ini régénéré.
                           Sans argument : sélection interactive (ou état des lieux)
  --list-devices           Backends ggml installés + devices exposés par llama-bench,
                           croisés avec bench-devices.conf (alerte si device disparu)
  --spec-test [preset] [n] Mesure le décode réel via l'API (spéculation incluse) :
                           n passes du même prompt code, prompt/gen t/s, acceptance
                           MTP + médianes (seed fixe/passe, 4 passes par défaut).
                           Journalise dans spec-tests.log et, dès
                           2 runs à n-max différents, prédit la courbe t/s(n-max)
                           et recommande la valeur cible.
  --spec-tune [preset] [k1,k2,..] [n]
                           Boucle automatique : pour chaque n-max (défaut 2,4,6),
                           ini régénéré + restart + spec-test ; retient le meilleur
                           mesuré (à <2 %, le plus petit), l'écrit dans
                           spec-nmax.conf (surcharge du défaut script), restart final
                           Sans preset : choix interactif parmi les MTP présents.
                           3 passes par défaut. Sert à régler
                           spec-draft-n-max (éditer le script, --preload, re-tester)
  --start                  Lance llama-server sur :8009 (défaut sans argument)
  --install-service        Installe/active le service systemd $SERVICE_NAME
  --uninstall-service      Arrête, désactive et supprime le service
  --help, -h               Cette aide

Fichiers (à côté du script, versionnables) :
  bench-devices.conf       clé (dossier GGUF) = device retenu (Vulkan0/ROCm0)
  preload.conf             presets préchargés, un par ligne
  spec-tests.log           journal des --spec-test (TSV), base de l'analyse n-max
  spec-nmax.conf           preset = spec-draft-n-max retenu par --spec-tune
Fichiers ($CONFIG_DIR) :
  models.ini               généré — ne pas éditer à la main, relancer --preload/--bench

Workflow typique :
  ./setup-llm.sh --setup && ./setup-llm.sh --install-service
  sudo systemctl start $SERVICE_NAME ; journalctl -u $SERVICE_NAME -f
  ./setup-llm.sh --bench all          # une fois ROCm en place
  ./setup-llm.sh --update qwen3.8-27b # après un re-upload unsloth
  ./setup-llm.sh --spec-test          # décode réel d'un preset MTP (choix interactif)
  ./setup-llm.sh --spec-tune          # règle spec-draft-n-max tout seul (2,4,6)

Presets (models.ini, ${#PRESET_ORDER[@]}) :
$(printf '  %s\n' "${PRESET_ORDER[@]}")
Clés modèles (--update / --bench) :
$(for f in "${KNOWN_FILES[@]}"; do _key "$f"; done | sort -u | sed 's/^/  /')
HELP
}

# =============================================================================
# Entrypoint
# =============================================================================

case "${1:-}" in
  --setup)             cmd_setup ;;
  --update)            cmd_update "${2:-}" ;;
  --cleanup)           cmd_cleanup "${2:-}" ;;
  --bench)             cmd_bench "${2:-}" ;;
  --preload)           cmd_preload ;;
  --list-devices)      cmd_list_devices ;;
  --spec-test)         cmd_spec_test "${2:-}" "${3:-}" ;;
  --spec-tune)         cmd_spec_tune "${2:-}" "${3:-}" "${4:-}" ;;
  --start | "")        cmd_start ;;
  --install-service)   cmd_install_service ;;
  --uninstall-service) cmd_uninstall_service ;;
  --help | -h)         cmd_help ;;
  *) cmd_help >&2; error "Commande inconnue : '$1'" ;;
esac
