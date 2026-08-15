# lib/presets.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

# =============================================================================
# BACKENDS
#
# Vulkan0 reste le défaut global ([*] device = Vulkan0). Backends ggml en
# paquets séparés (split Arch mi-août 2026) : ggml-vulkan pour Vulkan0,
# ggml-hip + runtime ROCm pour ROCm0 — le runtime seul ne suffit plus.
#
# Sélection par modèle : via bench-devices.conf (édition manuelle, guidée
# par les mesures de --bench). Chaque modèle dont le GGUF a une entrée dans
# le conf reçoit `device = <retenu>` dans le ini. Pas d'entrée → héritage du [*].
#
# ⚠ Les modèles MTP/spéculatifs héritent du device benché sur leur GGUF, mais
#   le bench ne mesure PAS le chemin spéculatif : après une bascule ROCm d'un
#   modèle MTP, valider la spéculation dans les logs (acceptance, pas de
#   fallback silencieux) avant de garder.
# =============================================================================

DEFAULT_DEVICE="Vulkan0"

# =============================================================================
# PRESETS INI
#
# Chaque entrée du tableau associatif définit le corps d'un modèle [section].
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
#   - parallel = 1 OBLIGATOIRE sur tous les modèles MTP : "-np > 1 and --mmproj
#     are not yet supported with MTP" (doc unsloth, confirmée sur les README
#     Qwen MTP et Gemma QAT, juin/juillet 2026). Les anciens parallel 2/3 sur
#     les modèles MTP étaient au mieux ignorés, au pire cassaient la spéculation.
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
# NB : la variante MTP existe en modèle séparé (qwen3.5-9b-mtp) — MTP impose
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
# spec-draft-n-max 4 : mesuré 15/08/2026 (la reco unsloth était 6 depuis le
#   merge mainline du 16/05/2026 — la mesure prime, re-régler via --spec-tune)
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
spec-draft-n-max     = 4
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
# MTP draft=4 (mesuré 15/08/2026, valeur historique 2) : décodage spéculatif
#   sans perte, gain max sur tool calls / JSON,
#   mais rollback GDN fragile en agentic (cf. ci-dessus) → bascule manuelle
#   uniquement : /model qwen3.6-35b-a3b-mtp-nothink
# (ne PAS précharger ce modèle en même temps que le nothink dans --preload,
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
spec-draft-n-max     = 4
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
# par les deux modèles ci-dessous. Remplace qwen3.6-27b, qwen3.6-27b-nothink
# et qwen3.6-27b-mtp-nothink. Pas de modèle nothink non-MTP : à parallel 1 il
# ferait doublon strict avec le mtp-nothink (même GGUF, mêmes réglages, juste
# sans la spéculation). Le thinking reste non-MTP volontairement : c'est le
# chemin checkpoints/prompt-cache fiable (rollback GDN sur rejet de draft
# encore fragile en agentic, cf. 35B-A3B) — spec-type à ajouter si envie. (Le Qwopus, SFT coder de la 3.6-27B, est gardé
# en modèle séparé plus bas — choix perso, pas un doublon strict.)
#
# Sampling officiel Qwen3.8-27B (model card + doc unsloth) :
#   thinking : temp 1.0 / top-p 0.95 / top-k 20 / min-p 0.0 / presence 0.0
#   instruct : temp 0.7 / top-p 0.80 / top-k 20 / min-p 0.0 / presence 1.5
#   (le "temp 0.6" du 3.6 pour le coding précis n'est plus la reco 3.8)
# Thinking ON par défaut, désactivable par requête. reasoning_effort :
#   xhigh (défaut) / medium / low / none, via chat-template-kwargs. Le modèle
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
# ⚠ Hypothèse MTP embarqué à VALIDER au premier chargement du modèle MTP :
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
# Même GGUF que le modèle thinking ci-dessus (tête MTP embarquée) — ne PAS
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
# spec-draft-n-max 4 : mesuré 15/08/2026 (valeur historique 2)
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
spec-draft-n-max     = 4
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
#   faire un modèle non-MTP séparé sur le même GGUF.
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
#   thinking côté client) — pour un modèle nothink, ajouter :
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
# Ordre d'émission des modèles dans le ini
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
