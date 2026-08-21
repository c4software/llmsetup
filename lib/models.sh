# lib/models.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

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
#     de préfixe passe par cache-ram + ctx-checkpoints.
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
#  qwen3.5-9b-mtp, gemma-31b, gemma-12b → ./setup-llm.sh --cleanup les purge)
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
#   9b = tâches auxiliaires, 35b-a3b-nothink = default agentic (opencode & co)
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

download_hf qwen3.6-35b-a3b "unsloth/Qwen3.6-35B-A3B-GGUF" \
  QWEN36_35B_A3B_PATH="Qwen3.6-35B-A3B-UD-Q6_K_XL.gguf"

# Qwen3.6-35B-A3B nothink — DEFAULT AGENTIC, always-on
#   Sert opencode (usage principal) et les autres clients agentic.
# Repassé devant la variante MTP pour l'agentic : le rollback partiel de
#   l'état récurrent GDN sur rejet de draft est livré en mainline (PR #22673,
#   mai 2026 — #22400 fermé en sa faveur), mais il n'a pas été validé ici sur
#   Vulkan en boucle de tool calls → checkpoints/prompt-cache sans spéculation,
#   c'est ce qui compte en agentic. Réserve à lever par un test, plus un fait
#   upstream.
# parallel 2 : subagents opencode / requêtes concurrentes sans sérialisation
# cache-type-v q8_0 : le V q4_0 global dégrade le tool calling
# cache-reuse 0 : ignoré de toute façon sur GDN (état récurrent) — la
#   restauration de préfixe passe par cache-ram + ctx-checkpoints
# NB : la variante thinking (même GGUF, $QWEN36_35B_A3B_PATH) est déclarée
#   plus bas, dans le groupe « famille 35B A3B ».
llama_model qwen3.6-35b-a3b-nothink "
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

# =============================================================================
# Famille 35B A3B
# =============================================================================

groupe "; --- Famille 35B A3B ---"

# Qwen3.6-35B-A3B thinking — raisonnement activé
# Même GGUF que le nothink always-on : le download_hf est déclaré avec lui,
#   plus haut dans le groupe « préchargés » (l'ordre du ini prime sur la
#   contiguïté du bloc).
# cache-reuse 0 : ignoré sur GDN
llama_model qwen3.6-35b-a3b "
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

# Qwen3.6-35B-A3B-MTP — variante MTP, draft intégré (Q4_K_XL)
download_hf qwen3.6-35b-a3b-mtp "unsloth/Qwen3.6-35B-A3B-MTP-GGUF" \
  QWEN36_35B_A3B_MTP_PATH="Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf"

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
# spec-type ngram-map-k,draft-mtp : même montage que qwen3.8-27b-mtp-nothink
#   (voir ce bloc pour le fond). Le MoE a la même marche Vulkan 8→9 (x2,06,
#   batch 8 = 33 ms, batch 9 = 68 ms) mais sur une pente bien plus raide :
#   batch 8 coûte déjà 1,94x le batch 1 (trafic mémoire de l'union des experts
#   routés), donc seuil de non-perte 1,9 token sur 7 et gain plafonné x4.
#   --spec-ngram-tune du 21/08/2026 (Vulkan0, spec-refactor.txt, 4 passes) :
#   size_m 7 = 110,3 t/s (acceptance 0,93), 47 = 105,3 t/s (0,71) → 7, le
#   régime large ne s'amortit pas ici. spec-ngram.conf prime.
llama_model qwen3.6-35b-a3b-mtp-nothink "
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
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 4
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

download_hf qwen3-coder-next "unsloth/Qwen3-Coder-Next-GGUF" \
  QWEN3_CODER_NEXT_PATH="Qwen3-Coder-Next-UD-Q4_K_XL.gguf"

# Qwen3-Coder-Next — MoE 80B hybrid-attention, agentic coding
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : MoE hybrid-attention incompatible
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench-devices.
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
# ⚠ Repo day-zero (mi-août 2026) — template chat et quants encore mouvants,
#   prévoir un --update qwen3.8-27b d'ici quelques jours.
download_hf qwen3.8-27b "unsloth/Qwen3.8-27B-GGUF" \
  QWEN38_27B_PATH="Qwen3.8-27B-UD-Q4_K_XL.gguf"

# Qwen3.8-27B thinking — reasoning_effort medium (défaut modèle = xhigh), tool-calling jinja
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
#   (draft-mtp seul, spec-test.txt) : 31,4 t/s.
#   ⚠ Seuil du BACKEND, pas du modèle : la constante est figée à la
#   compilation, et la courbe ROCm0 n'a pas cette marche 8→9 (balayage du
#   21/08 à reps=2, bruité à ±10 ms — à re-mesurer avant d'en tirer un size_m).
# spec-ngram-map-k-min-hits 2 : n'accepter de drafter qu'à partir de deux
#   occurrences du n-gram, pour éviter les faux départs qui paient le batch
#   sans être acceptés.
llama_model qwen3.8-27b-mtp-nothink "
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
# spec-draft-n-max 4 : mesuré 15/08/2026 (valeur historique 2)
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : incompatible MTP
# spec-type ngram-map-k,draft-mtp : même montage que qwen3.8-27b-mtp-nothink
#   (voir ce bloc pour le fond). Même marche Vulkan 8→9 sur ce Q5_K_M (x2,42,
#   batch 8 = 106 ms, batch 9 = 257 ms). --spec-ngram-tune du 21/08/2026
#   (Vulkan0, spec-refactor.txt, 4 passes) : size_m 7 = 43,9 t/s (acceptance
#   0,95), 47 = 50,7 t/s (0,78) → 47, +16 %. spec-ngram.conf prime.
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

# GPT-OSS 120B — shards UD-Q4_K_XL
llama_model gpt-oss "
model            = $GPTOSS_PATH
ctx-size         = 131072
cache-ram        = 8192
temp             = 1.0
top-k            = 0
top-p            = 1.0
min-p            = 0.0
parallel         = 1"

# DeepSeek-V4-Flash-0731 — MoE 284B (13B actifs), 1M ctx natif, shards UD-IQ3_XXS
# UD-IQ3_XXS (104 Go, reco unsloth pour 128 Go de RAM) : le checkpoint est QAT
# FP4 natif sur les experts (96% des poids), donc le 3-bit est peu destructeur.
# Support llama.cpp mainline depuis fin juin 2026 (PR #24162).
# ⚠ Repo tout frais (squashé le 01/08) — les quants bougent encore, prévoir un
#   --update deepseek-v4-flash d'ici quelques jours.
# Décode ~12,5 t/s sur Strix Halo Vulkan avec ce quant : c'est la baseline
#   communautaire mesurée, bornée bande passante — normal, pas un bug de config.
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
# Spéculation n-gram : NON. Courbe t_forward(batch) Vulkan0 (bench-spec-batch,
#   reps=5, 21/08/2026) : batch 1 = 83 ms, 8 = 302 ms (x3,6), 16 = 551 ms,
#   32 = 718 ms, 48 = 1087 ms — seuil de non-perte de 45 % du draft dès
#   size_m 7, verdict « aucune taille viable ». MoE à 13B actifs : l'union
#   des experts routés croît avec le batch, le forward n'est jamais amorti.
#   Si spéculation un jour, ce sera DSpark (drafter dédié, cf. ci-dessus).
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
# Spéculation DFlash (drafter laguna-s-2.1-DFlash-BF16.gguf, 2,2 Go) :
#   draft-dflash est en mainline (PR #22105, mergée le 28/06/2026), le fork
#   poolside/llama.cpp branche `laguna` n'est plus nécessaire.
#   Reste à vérifier que ce drafter-là est bien reconnu par le mainline avant
#   d'ajouter --spec-type draft-dflash --spec-draft-n-max 15 (clampé à la
#   taille de bloc d'entraînement du drafter).
#   Retours communauté : jusqu'à +30 tok/s de décode selon les tâches.
# Candidat ROCm naturel (gros prefill agentic) — device auto via --bench-devices.
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
jinja            = true
parallel         = 1"

# Préchargement par défaut (sans preload.conf) : le léger agentic edge seul,
# le reste en LRU — les always-on se choisissent via --preload.
DEFAULT_PRELOAD=(lfm2.5-2.6b)
