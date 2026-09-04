# lib/models.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

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
# DÉFINITION DES MODÈLES
#
# Un bloc par modèle : commentaires métier + appel `download_hf` (repo HF,
# fichiers, chemins) + appel(s) `llama_model` (corps ini). Tout le reste est dérivé :
# KNOWN_FILES, PRESET_ORDER (= ordre de déclaration = ordre d'émission du ini),
# les téléchargements de cmd_setup (DL_SPECS) et les en-têtes de groupe du ini
# (appels `groupe`).
#
# Conventions des corps ini :
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
#     de préfixe passe par cache-ram + ctx-checkpoints — et elle ne se fait
#     qu'AU DERNIER CHECKPOINT, pas au token près : mesuré --bench-cache le
#     21/08/2026 (b10433) sur TOUTES les archs à état récurrent (9b, 35B-A3B,
#     Qwopus, coder-next, lfm2.5 conv) : tour suivant 62 à 66 % servi du
#     cache, requête identique 63 à 66 %, tokenizers différents compris ;
#     témoin DeepSeek (attention pure) : 99 % et 100 %. C'est le coût de ces
#     architectures en boucle agentic, à mettre en face de leur débit. Et pour
#     TOUS, DeepSeek compris : une édition en amont du prompt (2/3 de préfixe
#     commun) = 0 % réutilisé, le cache ne sert que les continuations — ne
#     jamais réécrire l'historique (compaction, tronquage) si on tient au cache.
#   - cache-type-v = q8_0 en surcharge locale pour les modèles à usage
#     agentic/tool calling (le KV V q4_0 dégrade le tool calling, cf. doc
#     llama.cpp function-calling)
#   - swa-full + ctx-checkpoints : hybrides Qwen3.5/3.6/3.8 uniquement
#     (note : sans effet sur les 35B A3B, pas de SWA — llama-server le
#      désactive au chargement, seul ctx-checkpoints travaille)
#   - parallel = 1 OBLIGATOIRE sur tous les modèles MTP : "-np > 1 and --mmproj
#     are not yet supported with MTP" (doc unsloth, confirmée sur les README
#     Qwen MTP et Gemma QAT, juin/juillet 2026). Les anciens parallel 2/3 sur
#     les modèles MTP étaient au mieux ignorés, au pire cassaient la spéculation.
# =============================================================================

declare -A MODEL_INI GROUPE_AVANT
PRESET_ORDER=()
DL_SPECS=()
_GROUPE_EN_ATTENTE=""

# Inventaire des fichiers attendus — source unique pour la création des dossiers
# et pour --cleanup, alimenté par les appels download_hf ci-dessous. Tout
# fichier qui cesse d'être déclaré devient un orphelin supprimable.
# (retirés le 15/08/2026, remplacés par qwen3.8-27b : qwen3.6-27b et
#  qwen3.6-27b-mtp ; retirés le 15/08/2026 car jamais utilisés : qwen3.5-2b,
#  qwen3.5-9b-mtp, gemma-31b, gemma-12b ; retirés le 28/08/2026, remplacés par
#  ornith-1.5-35b-a3b : qwen3.6-35b-a3b et qwen3.6-35b-a3b-mtp
#  → ./setup-llm.sh --cleanup les purge)
KNOWN_FILES=()

# download_hf <dossier> <repo> VAR=<fichier> [VAR=<fichier>...]
#   Pour chaque VAR=<fichier> : définit la variable VAR (chemin absolu sous
#   $MODELS_BASE/<dossier>, utilisée par les corps `llama_model` — l'appel doit donc
#   PRÉCÉDER le premier corps qui la référence), ajoute le chemin à KNOWN_FILES
#   et enregistre un téléchargement (une ligne _dl par fichier).
#   Plusieurs VAR= sur un appel = plusieurs fichiers du même repo/dossier
#   (ex : modèle de base + drafter spéculatif externe).
download_hf() {
  local dossier="$1" repo="$2" spec var fichier chemin
  shift 2
  for spec in "$@"; do
    var="${spec%%=*}"; fichier="${spec#*=}"
    chemin="$MODELS_BASE/$dossier/$fichier"
    printf -v "$var" '%s' "$chemin"
    KNOWN_FILES+=("$chemin")
    DL_SPECS+=("plat"$'\t'"$chemin"$'\t'"$repo"$'\t'"$fichier")
  done
}

# download_hf_shards <dossier> <repo> VAR=<shard 00001, chemin relatif avec
#   son sous-dossier de quant>. Comme download_hf, mais le glob hf est
#   dérivé du shard : <sous-dossier de quant>/* (changer de quant = changer
#   uniquement l'entrée, le glob suit).
download_hf_shards() {
  local dossier="$1" repo="$2" spec="$3" var entry chemin
  var="${spec%%=*}"; entry="${spec#*=}"
  chemin="$MODELS_BASE/$dossier/$entry"
  printf -v "$var" '%s' "$chemin"
  KNOWN_FILES+=("$chemin")
  DL_SPECS+=("shard"$'\t'"$chemin"$'\t'"$repo"$'\t'"${entry%/*}/*")
}

# groupe <ligne> [<ligne>...]
#   En-tête de groupe du ini, émis (suivi d'une ligne vide) juste avant la
#   PROCHAINE section déclarée par `llama_model`. Plusieurs appels consécutifs =
#   plusieurs blocs séparés par une ligne vide (bannière + sous-groupe).
groupe() {
  local bloc="" l
  for l in "$@"; do bloc+="${bloc:+$'\n'}$l"; done
  _GROUPE_EN_ATTENTE+="${_GROUPE_EN_ATTENTE:+$'\n\n'}$bloc"
}

# llama_model <section> <corps ini>
#   Enregistre la section (MODEL_INI) et sa position d'émission (PRESET_ORDER =
#   ordre de déclaration), et lui rattache les en-têtes `groupe` en attente.
llama_model() {
  MODEL_INI[$1]="$2"
  PRESET_ORDER+=("$1")
  if [[ -n "$_GROUPE_EN_ATTENTE" ]]; then
    GROUPE_AVANT[$1]="$_GROUPE_EN_ATTENTE"
    _GROUPE_EN_ATTENTE=""
  fi
  return 0  # piège set -e : ne jamais finir sur un [[ ]] potentiellement faux
}

# =============================================================================
# Groupe de tête du ini — candidats naturels au préchargement (preload.conf) :
#   9b = tâches auxiliaires, ornith-1.5-35b-a3b = default agentic (opencode & co)
# =============================================================================

download_hf qwen3.5-9b "unsloth/Qwen3.5-9B-GGUF" \
  QWEN35_9B_PATH="Qwen3.5-9B-UD-Q6_K_XL.gguf"

# Qwen3.5-9B : dense 9B — tâches auxiliaires courtes (résumés, titres, routage)
# chat-template-kwargs : thinking COUPÉ. Note : depuis les mises à jour de
#   template unsloth, les Qwen3.5 Small (0.8B/2B/4B/9B) sont nothink PAR DÉFAUT —
#   le kwargs est devenu redondant mais reste en ceinture-bretelles (un futur
#   re-download de template ne doit pas réactiver le thinking en douce).
# n-predict 1024 : borne dure, aucune tâche auxiliaire n'a besoin de plus —
#   plus jamais de génération qui court jusqu'au plafond de contexte
# Pas de variante MTP : MTP imposerait parallel=1, incompatible avec les
#   4 slots de tâches auxiliaires concurrentes qui font tout l'intérêt du 9b.
# Mesuré 21/08/2026 (Vulkan0, b10433) : prefill 837 t/s, décode 25,7 t/s ;
#   --bench-parallel : 4 requêtes = 78,6 t/s agrégés (x3,06), 20 t/s par
#   requête — le parallel 4 est justifié ; --bench-load : 1,9 s de chargement
#   (8,2 Go), TTFT à chaud 65 ms ; --bench-cache : 62 % au tour suivant, 63 % à
#   l'identique (cf. en-tête). Justesse OK (recopie) ; un calcul mental simple, lui, est raté
#   (93 → 33) : tâches auxiliaires, pas de raisonnement.
llama_model qwen3.5-9b "
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

download_hf ornith-1.5-35b-a3b "ornith-ai/Ornith-1.5-35B-A3B-GGUF" \
  ORNITH15_35B_A3B_PATH="Ornith-1.5-35B-Q4_K_M.gguf"

# Ornith-1.5-35B-A3B nothink — DEFAULT AGENTIC, always-on
#   Remplace le 28/08/2026 les trois variantes Qwen3.6-35B-A3B (nothink,
#   thinking, mtp-nothink) par une seule section, parallel 4.
# Fiche (model card HF ornith-ai, 24/08/2026, pas de guide unsloth) : post-train
#   d'Ornith AI sur Qwen3.6-35B-A3B, arch llama.cpp qwen35moe (même famille
#   que le 35B-A3B remplacé : GDN + MoE, 3B actifs, support mainline acquis
#   en b10566). Pas de tête MTP (pas de repo -MTP, pas de nextn), donc pas de
#   spéculation ici — et parallel 4 serait de toute façon incompatible. Un
#   mmproj BF16 (0,9 Go) existe : texte seul, non téléchargé.
# Quant Q4_K_M (21,7 Go) : choix du 28/08/2026, c'est la quant de la commande
#   de référence de la fiche ; pas de quant unsloth UD sur ce repo
#   (grille : Q4_K_M 21,7 / Q5_K_M 25,3 / Q6_K 29,2 / Q8_0 37,8 Go).
# Sampling : reco officielle temp 0.6 / top-p 0.95 / top-k 20 (la fiche donne
#   temp 1.0 pour les benchs seulement). Thinking par défaut ; nothink via
#   chat-template-kwargs (le template gère enable_thinking:false en
#   émettant <think>\n\n</think>), reasoning off en plus pour ne rien
#   renvoyer dans reasoning_content.
# ctx 1048576 : llama-server partage ctx-size entre les slots, 4 x 262144 =
#   le contexte natif entier pour chaque requête (au-delà : YaRN facteur 4,
#   non activé).
# parallel 4 : subagents des clients agentic (omp, opencode) sans
#   sérialisation. --bench-parallel 28/08/2026 : 4 requêtes = 136,8 t/s
#   agrégés (x1,93), 35,0 t/s par requête (le Qwen3.6 faisait x1,43 à 2).
# Device : Vulkan0, --bench-devices 28/08/2026 (b10566, 3 passes) : 976 pp /
#   70,9 tg contre ROCm0 931 / 57,6, justesse OK sur les deux, tour simulé
#   44 s contre 54. --bench (bench-task) : 974 pp / 70,7 tg. --bench-cache :
#   62 % au tour suivant, 64 % à l'identique, 0 % après édition (GDN, cf.
#   en-tête). Sortie contrôlée à la main : réponse lisible, pas de warning.
#   --bench-agentic 28/08/2026 (pi 0.84.3, 3 passes) : 16/16, décode 71 t/s
#   en boucle d'outils, cache 89 à 98 % en continuation (72 % sur un run à
#   65 k tokens cumulés, trois tours de correction).
# cache-type-v q8_0 : le V q4_0 global dégrade le tool calling
# cache-reuse 0 : ignoré sur GDN (état récurrent) — la restauration de
#   préfixe passe par cache-ram + ctx-checkpoints, au dernier checkpoint
#   seulement (cf. en-tête, 62 % au tour suivant sur cette arch).
# jinja : template chat requis pour le tool calling XML (<function=...>).
llama_model ornith-1.5-35b-a3b "
model                = $ORNITH15_35B_A3B_PATH
ctx-size             = 1048576
cache-ram            = 12288
reasoning            = off
chat-template-kwargs = {\"enable_thinking\":false}
temp                 = 0.6
top-k                = 20
top-p                = 0.95
min-p                = 0.0
cache-type-v         = q8_0
jinja                = true
parallel             = 4
cache-reuse          = 0
swa-full             = true
ctx-checkpoints      = 128"

# =============================================================================
# Légers à la demande
# =============================================================================

groupe "; =============================================================================" \
       "; À la demande — évincés par le LRU de --models-max" \
       "; ============================================================================="
groupe "; --- LFM2.5 2.6B (Liquid AI — agentic edge, tool calling) ---"

# LFM2.5-2.6B (Liquid AI) — hybride conv récurrente + GQA (arch lfm2),
# agentic edge : tool calling / instruction following, ctx natif 128K.
# Q8_0 officiel LiquidAI (2,87 Go) — modèle minuscule, aucune raison de
# descendre en dessous ; pas de quant unsloth UD à ce jour (repo publié
# le 04/08/2026 avec la sortie du modèle).
download_hf lfm2.5-2.6b "LiquidAI/LFM2.5-2.6B-GGUF" \
  LFM25_26B_PATH="LFM2.5-2.6B-Q8_0.gguf"

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
# Mesuré 21/08/2026 (Vulkan0, b10433) : prefill 2279 t/s, décode 67,7 t/s ;
#   --bench-parallel : 4 requêtes = 205 t/s agrégés (x3,06) ; --bench-load :
#   0,5 s (2,7 Go), TTFT 27 ms ; --bench-cache : 62 % / 63 % comme les GDN
#   (autre tokenizer, même plafond : c'est l'état récurrent, conv ici).
llama_model lfm2.5-2.6b "
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

download_hf qwen3-coder-next "unsloth/Qwen3-Coder-Next-GGUF" \
  QWEN3_CODER_NEXT_PATH="Qwen3-Coder-Next-UD-Q4_K_XL.gguf"

# Qwen3-Coder-Next — MoE 80B hybrid-attention, agentic coding
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : MoE hybrid-attention incompatible
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench-devices.
# Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10433) : prefill 470 t/s,
#   décode 46,7 t/s. ⚠ ROCm0 INUTILISABLE sur cette arch avec ce build : répond
#   « LAMPAMPAMPAMP… » à la recopie de contrôle (exclu par --bench-sanity avant
#   toute mesure). Deuxième arch MoE à opérateurs fusionnés cassée sur ROCm0
#   après DeepSeek V4 ; les denses et le 35B-A3B passent.
# Spéculation n-gram : ngram-map-k size_m 47, RETENU sur mesure réelle, avec
#   un compromis à connaître. Pas de tête MTP. Courbe t_forward(batch) Vulkan0
#   (21/08, reps=5) : batch 1 = 21 ms, 8 = 46 (x2,16), 9 = marche, 16 = 106,
#   32 = 146, 48 = 199 ms. --spec-ngram-tune 21/08/2026 (spec-refactor.txt,
#   4 passes) : sans spéculation 46,8 t/s ; size_m 7 = 20,8 t/s (!) malgré une
#   acceptance de 0,98 ; size_m 47 = 68,7 t/s (+47 %). Lecture : sur cette arch
#   (GDN + MoE 512 experts) chaque PAS spéculatif porte un surcoût fixe énorme
#   (~330 ms à size 7, ~480 ms à 47, contre 46 et 199 ms de forward pur :
#   sauvegarde/restauration de l'état récurrent), que seuls les grands drafts
#   amortissent — un petit draft est une catastrophe, pas un réglage sûr.
#   Revers : en génération sans répétition (bench-task, spec-test.txt) les
#   hits partiels paient ce surcoût : -5,5 % (43,7 contre 46,2 ; 44,5 contre
#   47,1), acceptance 0,23 à 0,29, et min-hits 4 n'y change rien (--spec-ab :
#   44,8, même acceptance — ce ne sont pas des faux départs mais les
#   répétitions du modèle lui-même). Gardé parce qu'en agentic l'édition
#   domine ; retirer spec-type/size-m/min-hits ci-dessous (et la ligne de
#   spec-ngram.conf) si la génération générique prime.
# --bench 21/08 (bench-task, sans spéculation) : 457 pp / 46,2 tg. --bench-cache :
#   64 % / 66 % (état récurrent). --bench-load : 72 s (47 Go relus depuis le
#   disque), TTFT à chaud 406 ms — à la demande, ce modèle coûte plus d'une
#   minute à charger quand DeepSeek est passé avant lui.
llama_model qwen3-coder-next "
model            = $QWEN3_CODER_NEXT_PATH
ctx-size         = 131072
cache-ram        = 4096
temp             = 1.0
top-k            = 40
top-p            = 0.95
min-p            = 0.01
cache-type-v     = q8_0
cache-reuse      = 0
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 47
spec-ngram-map-k-min-hits = 2
parallel         = 1"

# =============================================================================
# Famille Qwen3.8-27B — un seul GGUF (UD-Q4_K_XL, tête MTP embarquée) partagé
# par les deux modèles ci-dessous. Remplace qwen3.6-27b, qwen3.6-27b-nothink
# et qwen3.6-27b-mtp-nothink. Pas de modèle nothink non-MTP : à parallel 1 il
# ferait doublon strict avec le mtp-nothink (même GGUF, mêmes réglages, juste
# sans la spéculation). Le thinking reste non-MTP volontairement : c'est le
# chemin checkpoints/prompt-cache fiable (rollback GDN sur rejet de draft
# encore fragile en agentic, cf. 35B-A3B) — spec-type à ajouter si envie.
# (Le Qwopus, SFT coder de la 3.6-27B, est gardé en modèle séparé plus bas —
# choix perso, pas un doublon strict.)
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
# Tête MTP embarquée VALIDÉE : llama-server charge draft-mtp sur ce GGUF et
#   --spec-test mesure une acceptance de 0,82 à 0,94 (15/08 et 21/08/2026) —
#   pas de repo -MTP séparé à réintroduire.
# =============================================================================

groupe "; --- Famille 27B (Qwen3.8 — un seul GGUF, tête MTP embarquée — + Qwopus 3.6 coder) ---"

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
#   (Q6 : 8,5 t/s brut / 16 t/s MTP ; Q4 mesuré : 25,5 t/s MTP sur ROCm0 le
#   15/08, 31,4 t/s MTP sur Vulkan0 le 21/08 — cf. modèle mtp-nothink).
#   Coût : ~1-2 pts de top-1 vs Q6 (analyse Dynamic V3 : l'IQ2_XXS de 9 Go
#   garde déjà 82,5 %, la courbe Q4→Q6 est écrasée en haut). Repasser en
#   UD-Q6_K_XL ici + --update qwen3.8-27b si le thinking long en pâtit.
# Profondeur de contexte (tools/bench-depth.sh 21/08/2026, KV q8_0, sans
#   spéculation, reps=2) : Vulkan0 prefill 289 → 222 → 183 t/s et décode
#   12,25 → 11,83 → 11,50 t/s à 0 / 16k / 32k ; ROCm0 352 → 263 → 214 et
#   11,97 → 10,73 → 9,54. ROCm0 prefill plus vite à vide mais décode moins bien
#   et se dégrade deux fois plus vite en profondeur : Vulkan0 gagne à toutes
#   les profondeurs (tour simulé 252 → 272 s contre 256 → 324 s), et l'écart
#   se creuse en contexte long, le régime agentic. Chargement : 4,4 s (17 Go,
#   cache de pages chaud), TTFT à chaud 165 ms.
# ⚠ Repo day-zero (mi-août 2026) — template chat et quants encore mouvants,
#   prévoir un --update qwen3.8-27b d'ici quelques jours.
download_hf qwen3.8-27b "unsloth/Qwen3.8-27B-GGUF" \
  QWEN38_27B_PATH="Qwen3.8-27B-UD-Q4_K_XL.gguf"

# Qwen3.8-27B thinking — reasoning_effort medium (défaut modèle = xhigh), tool-calling jinja
# Mesuré --bench 21/08/2026 (Vulkan0, b10433) : prefill 215 t/s, décode 12,1 t/s
#   (cohérent avec les 12,3 t/s bruts de llama-bench, cf. profondeur ci-dessus).
llama_model qwen3.8-27b "
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

# Qwen3.8-27B-MTP nothink — spéculation MTP, n-max 6 (mesuré --spec-tune
#   Q4/Vulkan0 21/08/2026, draft-mtp seul, spec-test.txt, 4 passes :
#   k2=26,8 / k4=31,8 / k6=33,1 t/s, acceptance 0,95 / 0,85 / 0,75 ; le modèle
#   α prédit 33,8 à k8, <2 % → 6 est l'optimum. 4 est à 4 % en dessous, hors
#   tolérance). Sur ROCm0 le 15/08 c'était k2=22,2 / k4=25,5 / k6=26,0 → 4 :
#   l'optimum dépend du device, re-régler après chaque bascule.
#   Bascule manuelle : /model qwen3.8-27b-mtp-nothink
# Même GGUF que le modèle thinking ci-dessus (tête MTP embarquée) — ne PAS
#   précharger les deux en même temps (~16 Go chargés deux fois).
# Historique : Q6/n-max 2 = 16 t/s ; Q4/n-max 2 = 22 ; Q4/n-max 4 = 25,5 (ROCm0) ;
#   Q4/n-max 4 = 31,8 et n-max 6 = 33,1 (Vulkan0) ; + ngram-map-k size_m 47 =
#   47,4 sur refactor (mesuré avec n-max 4, avant ce réglage).
#   Re-régler avec ./setup-llm.sh --spec-tune après changement de quant/build/device.
# cache-reuse 0 : incompatible MTP
# parallel 1 : contrainte MTP (np > 1 non supporté)
#
# spec-type ngram-map-k,draft-mtp — la liste est essayée dans l'ordre de
#   priorité de llama.cpp (les draftless d'abord) et la première implémentation
#   qui produit un draft non vide gagne le pas de décode ; un miss n-gram coûte
#   une sonde de hash et le MTP reprend la main. Gratuit en VRAM (une table de
#   2^18 entrées, ~1 Mio par séquence) et sans perte, comme le MTP.
#   Intérêt en agentic : l'outil d'édition d'opencode fait ré-émettre le
#   oldString mot pour mot depuis le fichier lu, et ngram-map-k construit sa
#   map à partir du PROMPT entier, pas seulement du texte généré.
#   ngram-map-k plutôt que ngram-mod (le défaut de --spec-default d'upstream) :
#   le pool partagé de ngram-mod n'apporte rien à parallel 1, et map-k
#   s'auto-limite par clé (n_draft_tokens = min(m, values[slot_max].n_accepted) dans
#   common/ngram-map.cpp), donc le plein tarif d'un draft raté n'est payé
#   qu'une fois par n-gram.
# spec-ngram-map-k-size-m 47 : retenu par ./setup-llm.sh --spec-ngram-tune
#   (Q4/Vulkan0, 21/08/2026, prompt spec-refactor.txt) — re-régler avec la même
#   commande après changement de device, de quant ou de build llama.cpp, le
#   résultat va dans spec-ngram.conf (qui surcharge la valeur ci-dessous).
#   Le batch de vérification vaut size_m + 1, et le coût d'un forward n'est pas
#   une pente lisse : ggml-vulkan.cpp déclare mul_mat_vec_max_cols = 8 — au-delà
#   de 8 colonnes il quitte le noyau vectoriel pour le matmul général et son
#   coût de mise en place. Courbe mesurée (llama-bench, reps=5) :
#     batch 8 = 100,9 ms, batch 9 = 215,0 ms (x2,13 d'un coup), plateau jusqu'à
#     16, batch 32 = 230,7 ms, batch 48 = 283,3 ms.
#   Deux régimes défendables, que seule une génération réelle départage :
#     - 7  (SÛR)   : dernière taille du chemin rapide, seuil de non-perte de
#                    1,2 token sur 7 — ne peut pas être perdant, gain plafonné x6,6
#     - 47 (LARGE) : amortit le coût fixe, gain jusqu'à x14, mais perdant sur
#                    les matchs de moins de 3,4 tokens
#   Mesuré sur spec-refactor (recopie de blocs exacts, la forme du
#   oldString/newString d'opencode, 4 passes) : 7 = 44,0 t/s (acceptance
#   0,94), 47 = 47,4 t/s (acceptance 0,73) — les répétitions réelles sont assez
#   longues pour que le régime large l'emporte de +8 %, au-delà des 2 % de
#   tolérance qui feraient préférer le plus petit. Référence sans n-gram
#   (draft-mtp seul, spec-test.txt) : 31,4 t/s. Avec n-max 6 (réglé ensuite) :
#   56,1 t/s sur le même prompt. --spec-ab du même jour : min-hits 1 équivalent
#   (55,8), ngram-map-k4v 47 nettement moins bon (44,9, -20 % : il drafte moins
#   souvent malgré une acceptance de 0,91) — map-k gardé. --bench (bench-task,
#   peu de répétitions) : 261 pp / 29,5 tg, acceptance 0,65 : l'écart avec les
#   56 t/s du refactor dit tout du rôle des hits n-gram.
#   ⚠ Seuil du BACKEND, pas du modèle : la constante est figée à la
#   compilation, et la courbe ROCm0 n'a pas cette marche 8→9 (balayage du
#   21/08 à reps=2, bruité à ±10 ms — à re-mesurer avant d'en tirer un size_m).
# spec-ngram-map-k-min-hits 2 : n'accepter de drafter qu'à partir de deux
#   occurrences du n-gram, pour éviter les faux départs qui paient le batch
#   sans être acceptés.
# cache-ram 12288 (était 4096) : session review omp du 25/08/2026, 4 agents
#   en série sur le seul slot (parallel 1). L'état de l'orchestrateur à 60k de
#   contexte pèse 9 Go (« prompt state size 9022 MiB exceeds cache size limit
#   4096 MiB, skipping ») : jamais sauvegardé, donc prefill complet de 58k
#   tokens (~325 s à 180 t/s) à chaque retour d'agent, au-delà du timeout
#   premier token d'omp (300 s) → 4 prefills annulés, 22 min perdues. 12 Go
#   gardent l'orchestrateur en RAM pendant qu'un agent occupe le slot.
llama_model qwen3.8-27b-mtp-nothink "
model                = $QWEN38_27B_PATH
ctx-size             = 131072
cache-ram            = 12288
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
presence-penalty     = 1.5
chat-template-kwargs = {\"enable_thinking\":false}
cache-type-v         = q8_0
cache-reuse          = 0
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 6
spec-ngram-map-k-size-m   = 47
spec-ngram-map-k-min-hits = 2
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# Qwopus3.6-27B-Coder-MTP — fine-tune coder SFT de la 3.6-27B, SWE-bench Verified 67.0%
# Conservé malgré l'arrivée de la 3.8-27B : seul survivant de la famille 3.6-27B,
#   gardé pour son style/coding, pas pour les benchs (la 3.8 native est devant).
# ⚠ Repo "super-squashé" fin juillet 2026 (historique nettoyé, etags changés) :
#   un --update qwopus3.6-27b-coder-mtp re-vérifiera proprement. Une variante
#   Jackrong/Qwopus3.6-27B-Coder-Compat-MTP-GGUF existe aussi si souci de compat.
download_hf qwopus3.6-27b-coder-mtp "Jackrong/Qwopus3.6-27B-Coder-MTP-GGUF" \
  QWOPUS_CODER_MTP_PATH="Qwopus3.6-27B-Coder-MTP-Q5_K_M.gguf"

# Qwopus3.6-27B-Coder-MTP nothink — fine-tune coder SFT, SWE-bench 67.0%
#   (score confirmé : run Q5_K_M, 335/500 Verified, thinking-off)
# Bascule manuelle : /model qwopus3.6-27b-coder-mtp-nothink
# spec-draft-n-max 4 : CONFIRMÉ sur Vulkan0 par --spec-tune 21/08/2026
#   (draft-mtp seul, spec-test.txt, 4 passes) : k2 = 24,6 / k4 = 30,2 /
#   k6 = 30,2 t/s (acceptance 0,93 / 0,82 / 0,72) — plateau dès 4, le plus
#   petit gagne (valeur historique 2, puis 4 le 15/08).
# Device : Vulkan0, mesuré --bench-devices 21/08/2026 : 243 pp / 26,5 tg
#   contre ROCm0 328 / 21,6 (tour simulé 122 s contre 145) — comme tous les
#   denses : ROCm prefill plus vite, décode moins bien.
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : incompatible MTP
# spec-type ngram-map-k,draft-mtp : même montage que qwen3.8-27b-mtp-nothink
#   (voir ce bloc pour le fond). Même marche Vulkan 8→9 sur ce Q5_K_M (x2,42,
#   batch 8 = 106 ms, batch 9 = 257 ms). --spec-ngram-tune du 21/08/2026
#   (Vulkan0, spec-refactor.txt, 4 passes) : size_m 7 = 43,9 t/s (acceptance
#   0,95), 47 = 50,7 t/s (0,78) → 47, +16 %. spec-ngram.conf prime. --bench
#   (bench-task) : 245 pp / 26,4 tg, acceptance 0,65. --bench-cache : 62 % /
#   63 %. --bench-load : 4,5 s (19 Go, cache de pages chaud), TTFT 147 ms.
llama_model qwopus3.6-27b-coder-mtp-nothink "
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
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 4
spec-ngram-map-k-size-m   = 47
spec-ngram-map-k-min-hits = 2
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# =============================================================================
# Géants
# =============================================================================

groupe "; --- Géants ---"

# GPT-OSS 120B — shards UD-Q4_K_XL
download_hf_shards gpt-oss "unsloth/gpt-oss-120b-GGUF" \
  GPTOSS_PATH="UD-Q4_K_XL/gpt-oss-120b-UD-Q4_K_XL-00001-of-00002.gguf"

# GPT-OSS 120B — shards UD-Q4_K_XL (59 Go), MoE 128 experts, attention
#   classique + couches à fenêtre glissante (SWA), pas d'état récurrent.
# Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10433, 3 passes) :
#   413 pp / 49,9 tg contre ROCm0 219 / 31,5 (tour simulé 65 s contre 105) —
#   les deux passent le contrôle de justesse, ROCm0 est juste lent ici. La
#   courbe ROCm0 « bien meilleure » du 20/08 (reps=2) ne voulait rien dire.
#   --bench (bench-task) : 333 pp / 51,9 tg. --bench-load : 91 s (59 Go depuis
#   le disque), TTFT à chaud 86 ms. --bench-cache : tour suivant 99 %, requête
#   identique 100 % — comme DeepSeek : sans état récurrent, le cache de prompt
#   sert tout (la SWA n'y change rien). Un premier run donnait 63 % : requête
#   « froide » déjà en cache après le --bench, outil corrigé depuis.
# Courbe t_forward(batch) Vulkan0 (21/08, reps=5) : batch 1 = 17 ms, 8 = 57
#   (x3,4), 16 = 130, 32 = 168, 48 = 246 ms (x14,7) — la plus raide de toutes.
# Spéculation n-gram : ngram-map-k size_m 7, RETENU par --spec-ngram-tune
#   21/08/2026 (Vulkan0, spec-refactor.txt, 4 passes) : sans spéculation
#   51,7 t/s ; size_m 7 = 59,8 t/s (+16 %) ; size_m 47 = 52,7 t/s (+2 %). La
#   courbe la plus raide de toutes (x3,4 au batch 8) n'a pas empêché le petit
#   draft de gagner : pas d'état récurrent, donc pas de surcoût fixe par pas
#   (contraste avec Qwen3-Coder-Next), et les misses sont gratuits. Le grand
#   draft, lui, paie son batch x14,7 à chaque hit partiel.
llama_model gpt-oss "
model            = $GPTOSS_PATH
ctx-size         = 131072
cache-ram        = 8192
temp             = 1.0
top-k            = 0
top-p            = 1.0
min-p            = 0.0
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
parallel         = 1"

# DeepSeek-V4-Flash-0731 — MoE 284B (13B actifs), 1M ctx natif, shards UD-IQ3_XXS
# UD-IQ3_XXS (104 Go, reco unsloth pour 128 Go de RAM) : le checkpoint est QAT
# FP4 natif sur les experts (96% des poids), donc le 3-bit est peu destructeur.
# Support llama.cpp mainline depuis fin juin 2026 (PR #24162).
# ⚠ Repo tout frais (squashé le 01/08) — les quants bougent encore, prévoir un
#   --update deepseek-v4-flash d'ici quelques jours.
# Décode ~12,5 t/s sur Strix Halo Vulkan avec ce quant : c'est la baseline
#   communautaire, bornée bande passante — mesuré ici 11,3 t/s sans spéculation
#   (21/08/2026, b10433), 12,3 avec n-gram : normal, pas un bug de config.
download_hf_shards deepseek-v4-flash "unsloth/DeepSeek-V4-Flash-0731-GGUF" \
  DSV4_FLASH_PATH="UD-IQ3_XXS/DeepSeek-V4-Flash-0731-UD-IQ3_XXS-00001-of-00004.gguf"

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
# Module DSpark (spéculation) : en mainline depuis le 02/08/2026 (PR #25784
#   « DeepseekV4 MTP + DSpark », sidecar drafter via #26458 ; le port #25683
#   a été fermé sans merge). b10433 expose draft-dspark et draft-mtp. Pas
#   activé : drafter GGUF à identifier et tête MTP du checkpoint à vérifier.
#   Gain modeste attendu sur APU.
# Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10433) — prefill 120 t/s,
#   décode 11,2 t/s. ⚠ ROCm0 INUTILISABLE sur cette arch avec ce build : le
#   serveur répond à ~500 t/s un charabia répétitif (« Nous dev dev dev… »),
#   réponse finale vide, sans erreur loggée — seulement des opérateurs fusionnés
#   DeepSeek V4 (Lightning Indexer, HC pre/comb/post) renvoyés sur CPU. C'est
#   ce cas qui a motivé le garde-fou « sortie dégénérée » de timings.py.
#   À re-tester après un bump de llama-cpp/ggml-hip.
# Spéculation n-gram : ngram-map-k size_m 7, RETENU sur mesure réelle
#   (21/08/2026, Vulkan0, spec-refactor.txt, 4 passes) : sans spéculation
#   11,29 t/s ; size_m 7 = 12,30 t/s (+9 %, acceptance 0,89 à 0,93 sur les
#   passes avec hits, -2 % au pire sur celles sans) ; size_m 31 = 11,78 t/s
#   (une passe sous la référence, acceptance 0,27 à 0,66). La courbe
#   t_forward(batch) (bench-spec-batch, reps=5 : batch 1 = 83 ms, 8 = 302 ms
#   soit x3,6, 16 = 551, 32 = 718, 48 = 1087 ms) concluait « aucune taille
#   viable » avec un seuil de non-perte de 45 % du draft dès size_m 7 — elle
#   ignore que les misses sont quasi gratuits et que seuls les hits, bien
#   acceptés, paient le batch. C'est ce cas qui a introduit le repli de
#   candidats de batch_curve.py et la référence « sans spéculation » du tune.
#   Gain modeste parce que le modèle pense longuement avant de recopier quoi
#   que ce soit ; en édition agentic pure il devrait être plus net. DSpark
#   (drafter dédié, cf. ci-dessus) reste l'autre piste.
# --bench-cache 21/08 : 99 % au tour suivant, 100 % à l'identique — attention
#   pure (MLA), pas d'état récurrent : le témoin qui montre que le plafond de
#   62-66 % des Qwen/LFM2 vient de la restauration par checkpoint.
llama_model deepseek-v4-flash "
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
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
jinja            = true
parallel         = 1"

groupe "; --- Laguna S 2.1 — nécessite llama.cpp >= b10087 (arch 'laguna', confirmé jusqu'à b10181) ---"

# Laguna S 2.1 (poolside) — MoE 118B (8B actifs), agentic coding, shards UD-Q4_K_XL
# 73.4 Go / 3 shards.
# ⚠ Quants ré-uploadés fin juillet 2026 par unsloth ("Fix rope/context metadata to
#   256K YaRN (poolside config)" + fixes poolside) → si téléchargé avant :
#   ./setup-llm.sh --update laguna-s-2.1
# Alternative plus légère si la RAM est juste : UD-IQ4_XS (57.6 Go) — changer
#   l'entrée en conséquence, le glob suit. (UD-Q4_K_S a été RETIRÉ du repo
#   unsloth ; il ne reste en shards que UD-IQ4_XS, UD-Q3_K_XL, UD-Q4_K_XL et
#   UD-Q5_K_XL.)
download_hf_shards laguna-s-2.1 "unsloth/Laguna-S-2.1-GGUF" \
  LAGUNA_S_PATH="UD-Q4_K_XL/Laguna-S-2.1-UD-Q4_K_XL-00001-of-00003.gguf"
# Drafter DFlash officiel (poolside, 1B, 6 couches, block_size 16, embeddings
# partagés avec la cible) : GGUF BF16 de 2,2 Go dans le repo poolside, pas
# dans celui d'unsloth. Même dossier que le modèle, autre repo.
download_hf laguna-s-2.1 "poolside/Laguna-S-2.1-GGUF" \
  LAGUNA_DFLASH_PATH="laguna-s-2.1-DFlash-BF16.gguf"

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
# Spéculation DFlash (drafter $LAGUNA_DFLASH_PATH, déclaré ci-dessus) :
#   draft-dflash est en mainline (PR #22105, mergée le 28/06/2026), MAIS LE
#   MAINLINE REFUSE CE DRAFTER. Mesuré 21/08/2026 (llama-cpp b10548, --spec-ab
#   spec-type=draft-dflash;spec-draft-model=…;spec-draft-n-max=15 et 7) :
#   « llama_model_load: error loading model: done_getting_tensors: wrong
#   number of tensors; expected 76, got 69 », le serveur sort, le modèle ne
#   charge pas. La model card poolside avait raison : le mainline « ships the
#   generic DFlash framework » mais pas le contrat spécifique Laguna (7
#   tenseurs d'écart), fork poolside/llama.cpp branche `laguna` requis — hors
#   périmètre ici (paquet Arch). Flags à réutiliser le jour où le mainline
#   suit : --spec-type draft-dflash -md <drafter> --spec-draft-n-max 7 (bloc
#   entraîné 16). Le drafter reste déclaré (2,2 Go) pour ce jour-là.
#   Retours communauté (sur le fork) : jusqu'à +30 tok/s.
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench-devices.
# Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10548, sans
#   spéculation, 3 passes) : 247 pp / 28,6 tg contre ROCm0 320 / 23,6 (tour
#   simulé 113 s contre 134), les deux justes — le schéma des denses.
# Courbe t_forward(batch) Vulkan0 (21/08, reps=5) : batch 1 = 33 ms, 8 = 95
#   (x2,9), 16 = 282, 32 = 384, 48 = 540 ms (x16,5). Référence sans
#   spéculation sur spec-refactor : 28,7 t/s.
# Spéculation n-gram : ngram-map-k size_m 7, RETENU par --spec-ngram-tune
#   21/08/2026 (b10548, Vulkan0, spec-refactor.txt, 4 passes) : sans
#   spéculation 28,7 t/s ; size_m 7 = 53,0 t/s (+85 %, le plus gros gain
#   n-gram mesuré ici) ; size_m 47 = 39,9 t/s (+39 %). Courbe raide (x2,9 au
#   batch 8, x16,5 au batch 48) et pourtant le petit draft double presque le
#   débit : MoE à 8B actifs, le forward de batch 8 coûte peu en absolu (95 ms)
#   et le décode de base est lent (33 ms/token), les hits rapportent gros. Pas
#   d'état récurrent (SWA + global), donc pas de surcoût fixe par pas.
# --bench (bench-task, peu de répétitions) avec n-gram 7 : 30,3 t/s contre 28,6
#   sans (+6 %) — pas de revers hors refactor, contrairement à Qwen3-Coder-Next.
#   --bench-cache : 99 % au tour suivant, 100 % à l'identique (pas d'état
#   récurrent). --bench-load : 67 s (69 Go depuis le disque), TTFT à chaud 173 ms.
llama_model laguna-s-2.1 "
model            = $LAGUNA_S_PATH
ctx-size         = 262144
cache-ram        = 8192
temp             = 0.7
top-p            = 0.95
top-k            = 0
min-p            = 0.0
cache-type-v     = q8_0
cache-reuse      = 0
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
jinja            = true
parallel         = 1"

groupe "; --- Qwen3.8-Flash-Next, nécessite l'arch 'qwen4exp' (llama.cpp PR #27742, mergée le 27/08/2026 dans b10661 ; absente du paquet Arch 0.3.0 = b10621, attend la prochaine coupe stable) ---"

# Qwen3.8-Flash-Next (Qwen) : MoE 125B (6B actifs, 512 experts, 10 routés + 1
# partagé) + 51B d'embeddings n-gram (bigrammes/trigrammes à la couche 2, table
# de hash lue une fois par forward), arch GDN (3 couches sur 4) + Qwen Sparse
# Attention (QSA, budget 2048, ratio 4) + hyper-connections, vision Qwen3-VL,
# ctx natif 256K (1M via YaRN). Shards UD-IQ4_XS (93,7 Go).
# SUPPORT llama.cpp : general.architecture = qwen4exp, PR #27742 (unsloth,
#   ouverte le 26/08, MERGÉE le 27/08 à 19:32 UTC, dans b10661 : convertisseur,
#   graphe texte, QSA avec un troisième cache dans llama_memory_hybrid_idx,
#   vision, 3 correctifs de llama-quant). Le paquet Arch llama-cpp est passé en
#   0.3.0-1 le 30/08 (b10621 sur bigchuck), TOUJOURS sans qwen4exp : v0.3.0 est
#   taguée le 25/08 et le commit de merge 6c84c7d5d8 est 39 commits devant elle.
#   Le PKGBUILD source '#tag=v${pkgver}', donc les tags stables semver et non
#   les pre-releases bXXXXX : l'attente porte sur la prochaine coupe stable
#   (aucune après v0.3.0 au 04/09, upstream à b10797), pas sur un rebuild.
#   Ne PAS surveiller le changement de pkgver, il a déjà déclenché à tort sur
#   0.3.0. Le seul contrôle fiable :
#   strings /usr/lib/libllama.so* | grep -x qwen4exp
# Quant : grille HF complète depuis le 27/08 (uploads 15:01 à 15:16 UTC) :
#   UD-IQ1_S 72,5 / UD-Q2_K_XL 78,9 / UD-IQ3_XXS 82,0 / UD-Q3_K_XL 90,0 /
#   UD-IQ4_XS 93,7 / UD-Q4_K_XL 111,3 Go (3 shards jusqu'à l'IQ4_XS, 4 pour
#   le Q4_K_XL). Retenu UD-IQ4_XS (validé le 27/08) : experts en 4 bits, et
#   ~30 Go de marge sur 124 Go pour le KV à 128k, la table n-gram et le
#   système, plus que DeepSeek V4 (104 Go) qui tourne. Le Q4_K_XL (111 Go)
#   ne laisse rien. Repli si le chargement est trop juste : UD-IQ3_XXS
#   (82 Go), changer l'entrée, le glob suit.
#   Quants converties AVANT le merge de la PR (15:16 contre 19:32 UTC), donc
#   ré-upload redouté : n'a PAS eu lieu, vérifié le 04/09 (tailles des 3 shards
#   inchangées, 10 946 624 / 49 835 229 856 / 43 836 407 744 octets). Les
#   commits HF du 01/09 n'ont ajouté que le dossier MTP/. Pas de --update.
# Sampling officiel (guide unsloth + model card) :
#   thinking : temp 1.0 / top-p 0.95 / top-k 20 / min-p 0.0 / presence 0.0
#   instruct : temp 0.7 / top-p 0.80 / top-k 20 / min-p 0.0 / presence 1.5
# Thinking ON par défaut (<think>), reasoning_effort xhigh (défaut) / medium /
#   low, "high" est replié sur xhigh par le template ; enable_thinking false =
#   nothink. preserve_thinking (garde les traces des tours précédents) : true
#   par défaut, côté client. Le modèle ci-dessous est en NOTHINK avec le
#   sampling instruct ; variante « low » si on veut un peu de raisonnement :
#     chat-template-kwargs = {"reasoning_effort":"low"}  + sampling thinking
#     (temp 1.0 / top-p 0.95, presence-penalty 0)
# cache-type-v q8_0 : agentic/coding, précision V critique (tool calls, diffs)
# cache-reuse 0 : état récurrent GDN (l'interdit à lui seul ; c'était aussi
#   une contrainte MTP, sans objet tant que draft-mtp est retiré)
# Pas de swa-full ni ctx-checkpoints : pas de SWA (QSA n'est pas une fenêtre
#   glissante) : à revoir si la PR expose des checkpoints pour l'état GDN.
# jinja : template unsloth (developer role, systèmes fusionnés, tool calling
#   au format <function=...><parameter=...>).
# Vision : mmproj-F16.gguf publié le 27/08 mais pas téléchargé, incompatible
#   MTP de toute façon : texte seul.
# MTP : tranché le 04/09, la tête n'est PAS dans le GGUF principal. Depuis le
#   01/09 unsloth la publie en sidecar dans MTP/ du repo HF (recommandé
#   mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf, 2,60 Go, annoncé 1,3x à 1,7x ;
#   les variantes « shared- » empruntent embeddings et projection de sortie au
#   modèle hôte, ~1,3 Go de moins que les autonomes). Leur README est explicite :
#   un build ggml-org standard ne peut rien en faire, mainline n'a ni graphe MTP
#   pour qwen4exp, ni emprunt de tenseurs entre modèles, ni --spec-type
#   draft-mtp pour cette arch. C'est la PR #28243, encore en DRAFT au 04/09.
#   Donc draft-mtp RETIRÉ du spec-type et section renommée -nothink (au lieu de
#   -mtp-nothink), conformément au repli prévu ici le 27/08. Deux jalons
#   distincts désormais : (1) tag stable avec qwen4exp = modèle qualifiable en
#   n-gram seul, étapes 3 à 7 de la skill déroulables ; (2) merge de #28243 =
#   remettre draft-mtp, re-nommer en -mtp-nothink, télécharger le sidecar et
#   refaire l'étape 4. Sur cette arch (GDN + MoE 512 experts, la même
#   famille que Qwen3-Coder-Next) attendre un gros surcoût fixe par pas
#   spéculatif (sauvegarde/restauration de l'état récurrent) : les petits
#   drafts n-gram peuvent être perdants, mesurer 7 ET 47 au --spec-ngram-tune.
# parallel 1 : c'était la contrainte MTP, tombée avec le retrait de draft-mtp.
#   Gardé à 1 quand même : 93,7 Go de poids sur 124 Go, un deuxième slot de KV
#   à 128k mangerait la marge. À rouvrir seulement si la mesure le réclame.
# Device : à mesurer (--bench-devices) ; les deux autres MoE à opérateurs
#   fusionnés du parc (DeepSeek V4, Qwen3-Coder-Next) sont INUTILISABLES sur
#   ROCm0 (charabia), s'attendre au même et lire le texte généré.
download_hf_shards qwen3.8-flash-next "unsloth/Qwen3.8-Flash-Next-GGUF" \
  QWEN38_FLASH_NEXT_PATH="UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf"

# Qwen3.8-Flash-Next nothink : spéculation n-gram seule, sampling instruct.
# Aucune mesure encore (arch non supportée par le build, cf. ci-dessus).
# Renommée -nothink le 04/09 : plus de draft-mtp, la tête est un sidecar que
#   mainline ne sait pas charger (PR #28243 en draft).
llama_model qwen3.8-flash-next-nothink "
model            = $QWEN38_FLASH_NEXT_PATH
ctx-size         = 131072
cache-ram        = 8192
temp             = 0.7
top-k            = 20
top-p            = 0.80
min-p            = 0.0
presence-penalty = 1.5
chat-template-kwargs = {\"enable_thinking\":false}
cache-type-v     = q8_0
cache-reuse      = 0
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
jinja            = true
parallel         = 1"

# Préchargement par défaut (sans preload.conf) : le léger agentic edge seul,
# le reste en LRU — les always-on se choisissent via --preload.
DEFAULT_PRELOAD=(lfm2.5-2.6b)
