# lib/models.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → fork → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# BACKENDS
#
# Vulkan0 reste le défaut global ([*] device = Vulkan0). Backends ggml en
# paquets séparés (split Arch mi-août 2026) : ggml-vulkan pour Vulkan0,
# ggml-hip + runtime ROCm pour ROCm0 — le runtime seul ne suffit plus.
# Depuis le passage au fork strix-llama.cpp (13/09/2026, cf. lib/fork.sh), le
# binaire servi n'embarque que Vulkan : ROCm0 n'est atteignable qu'en repassant
# au paquet Arch (llama-cpp b10809). Les paquets ggml ci-dessus ne valent que
# pour ce secours.
#
# Sélection par GGUF : via bench-devices.conf, écrit par --bench-devices
# (édition manuelle OK), clé = dossier du GGUF. Chaque modèle dont le GGUF a
# une entrée reçoit `device = <retenu>` dans le ini. Pas d'entrée : héritage
# du [*].
#
# ⚠ Garde-fou pour un retour au paquet Arch (le fork est Vulkan seul) : les
#   modèles MTP/spéculatifs héritent du device benché sur leur GGUF, mais
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
#   - device : hérité du [*] (Vulkan0) sauf surcharge locale (ROCm0, seulement
#     en secours sur le paquet Arch : aucune ligne device dans ce fichier au
#     13/09/2026)
#   - cache-reuse = 0 : explicite sur toutes les sections à état récurrent (GDN)
#     ou à attention hybride/MLA ; seuls qwen3.5-9b (hérite du 4096 global, de
#     toute façon ignoré) et gpt-oss (MoE mais sans état récurrent, attention +
#     SWA : le cache-reuse sert) ne l'ont pas. Le cache-reuse
#     est de toute
#     façon ignoré sur les architectures à état récurrent (GDN), llama-server
#     log "cache reuse is not supported by this context". La vraie restauration
#     de préfixe passe par cache-ram + ctx-checkpoints — et elle ne se fait
#     qu'AU DERNIER CHECKPOINT, pas au token près : mesuré --bench-cache les 21
#     et 28/08/2026 (b10433) puis refait sur le fork le 13/09/2026 (cf.
#     docs/HISTORIQUE.md, « Cache de prompt ») sur toutes les archs à état
#     récurrent (9b, 35B-A3B, coder-next, lfm2.5 conv, et le qwopus3.6-27b
#     coder depuis retiré) : tour suivant 62 à 66 % (paquet) et 62 à 65 %
#     (fork) servi du cache, requête identique 63 à 66 % (paquet) et 64 à 67 %
#     (fork), tokenizers différents compris ;
#     témoin DeepSeek (attention pure) : 99 % et 100 %. C'est le coût de ces
#     architectures en boucle agentic, à mettre en face de leur débit. Et pour
#     TOUS, DeepSeek compris : une édition en amont du prompt (2/3 de préfixe
#     commun) = 0 % réutilisé (4 % sur gpt-oss, le seul au-dessus de zéro),
#     le cache ne sert que les continuations — ne
#     jamais réécrire l'historique (compaction, tronquage) si on tient au cache.
#   - cache-type-v = q8_0 en surcharge locale pour les modèles à usage
#     agentic/tool calling (le KV V q4_0 dégrade le tool calling, cf. doc
#     llama.cpp function-calling)
#   - swa-full + ctx-checkpoints : posé sur qwen3.5-9b, ornith-1.5-35b-a3b et
#     qwen3.8-27b-dflash-nothink. Jusqu'au 15/09/2026 ce bloc affirmait que
#     swa-full « n'est effectif que sur le 9b » ; le journal du 13/09/2026 dit
#     le contraire : llama-server écrit « swa_full is not supported by this
#     model, it will be disabled » AUSSI sur le 9b (puis « cache_reuse is not
#     supported by this context »), comme sur les 35B A3B (pas de SWA) et sur
#     l'arch du 3.8-27B. Donc swa-full n'est effectif sur AUCUNE des trois
#     sections : seul ctx-checkpoints y travaille. Les lignes sont gardées
#     telles quelles (coût nul, le serveur les désactive lui-même) et
#     redeviendront utiles si une arch à vraie SWA entre au parc.
#   - parallel : ce n'est PAS une contrainte de spec-type. Jusqu'au 15/09/2026
#     le dépôt affirmait « parallel = 1 OBLIGATOIRE sur tous les modèles MTP »
#     en citant "-np > 1 and --mmproj are not yet supported with MTP" ; cette
#     phrase est une doc unsloth de juin/juillet 2026, elle n'existe NULLE PART
#     dans le fork strix-llama.cpp servi (lecture du code et de l'historique au
#     commit 0007bc6, vérifié le 15/09/2026). Ce que fait réellement le fork :
#     le serveur crée UN seul objet spéculatif dimensionné à n_parallel
#     séquences (tools/server/server-context.cpp:1459) et drafte tous les slots
#     en un appel ; draft-dflash et draft-dspark sont explicitement
#     multi-séquences (common/speculative.cpp:1276-1331, commit dfb1328eb du
#     28/08/2026 « keep DFlash draft blocks the same width across sequences ») ;
#     draft-mtp est vectorisé par séquence (speculative.cpp:1482-1700) sans
#     assert sur n_seq, mais aucun commit ni test ne l'éprouve : « non éprouvé »,
#     pas « interdit » ; ngram-map-k a une table par séquence.
#     Les vraies contraintes, qui se jugent MODÈLE PAR MODÈLE :
#       (1) ctx-size est un pool partagé : chaque slot reçoit ctx-size /
#           parallel, donc à contexte agentic large le deuxième slot coûte du
#           contexte utile ou de la RAM de KV ;
#       (2) le batch de vérification vaut jusqu'à parallel x (n-max + 1) et
#           franchit vite le seuil de 8 colonnes de ggml-vulkan
#           (mul_mat_vec_max_cols = 8, courbe mesurée dans le bloc
#           qwen3.8-27b) : au-delà, chaque forward change de régime ;
#       (3) rendement mesuré : unsloth donne sur DSpark un gain de spéculation
#           qui tombe de 1,84x à 1,10x à 4 voies.
#     Donc : parallel se règle MODÈLE PAR MODÈLE, comme un CHOIX justifié par
#     le contexte par slot, la mémoire ou le rendement, pas comme interdit
#     technique. Campagne multi-slot du 15/09/2026 terminée (fork
#     strix-0007bc6, Vulkan0, --bench-parallel, solo contre agrégé) :
#       deepseek-v4-flash   np 2 = x1,22 agrégé  -> PASSÉ À 2 (batch 2x4 = 8,
#                           pile le seuil ; np 4 = x0,80, batch 16)
#       ornith-1.5-35b-a3b  np 4 sans spéculation x1,93, 138 t/s agrégés, le
#                           meilleur du parc en concurrence -> INCHANGÉ ; la
#                           variante MTP mono-utilisateur est une SECTION à
#                           part (ornith-1.5-35b-a3b-mtp, parallel 1, +24 % en
#                           solo, x0,83 à np 2 et x1,12 à np 4)
#       qwen3-coder-next    solo 73,0 t/s, np 2 = x0,86, np 4 = x0,92 : aucun
#                           np ne bat le solo (batch 16 et 32) -> RESTE À 1
#     Règle générale qui s'en dégage : un modèle spéculatif ne gagne au
#     multi-slot que si parallel x (n-max + 1) reste <= 8 colonnes.
#     Seul interdit qui demeure : le mmproj reste incompatible avec un drafter
#     (vision => pas de spéculation). Les anciens parallel 2/3 sur modèles MTP
#     (constatés avant le 15/08/2026, plus aucune section ne les porte) n'ont
#     pas été re-mesurés depuis : leur mauvais comportement d'alors n'est pas
#     une preuve, il attend la campagne.
# =============================================================================

declare -A MODEL_INI GROUPE_AVANT
PRESET_ORDER=()
DL_SPECS=()
_GROUPE_EN_ATTENTE=""

# Inventaire des fichiers attendus — source unique pour la création des dossiers
# et pour --cleanup, alimenté par les appels download_hf / download_hf_shards /
# derive_gguf ci-dessous. Tout
# fichier qui cesse d'être déclaré devient un orphelin supprimable.
# (retiré le 13/09/2026 car plus utilisé : qwopus3.6-27b-coder-mtp (ses mesures
#  restent dans logs/)
#  → ./setup-llm.sh --cleanup les purge)
# (qwen3.5-2b : revenu le 12/09/2026 comme estimateur de speculative prefill du
#  27B thinking (jamais servi, sans section ini), retiré à nouveau le
#  13/09/2026 (spec-prefill abandonné) — à purger par --cleanup)
# (retraits antérieurs : docs/HISTORIQUE.md)
KNOWN_FILES=()

# download_hf <dossier> <repo> VAR=<fichier> [VAR=<fichier>...]
#   Pour chaque VAR=<fichier> : définit la variable VAR (chemin absolu sous
#   $MODELS_BASE/<dossier>, utilisée par les corps `llama_model` — l'appel doit donc
#   PRÉCÉDER le premier corps qui la référence), ajoute le chemin à KNOWN_FILES
#   et enregistre un téléchargement (une ligne _dl par fichier).
#   Plusieurs VAR= sur un appel = plusieurs fichiers du même repo/dossier
#   (ex : modèle de base + drafter spéculatif externe). <fichier> peut être en
#   sous-dossier du repo (ex : MTP/x.gguf), il est recréé tel quel sous <dossier>.
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

# derive_gguf <dossier> VAR=<fichier produit> <chemin source> <script du dépôt>
#   Comme download_hf, mais pour un fichier qu'AUCUN repo ne porte : il est
#   calculé en local à partir d'un fichier déjà déclaré (donc déjà téléchargé —
#   l'appel doit SUIVRE celui de la source). Définit VAR, ajoute le chemin à
#   KNOWN_FILES et enregistre une étape de post-traitement, jouée par cmd_setup
#   après les téléchargements, dans l'ordre de déclaration (_derive, lib/common.sh).
derive_gguf() {
  local dossier="$1" spec="$2" source="$3" script="$4" var fichier chemin
  var="${spec%%=*}"; fichier="${spec#*=}"
  chemin="$MODELS_BASE/$dossier/$fichier"
  printf -v "$var" '%s' "$chemin"
  KNOWN_FILES+=("$chemin")
  DL_SPECS+=("derive"$'\t'"$chemin"$'\t'"$source"$'\t'"$script")
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
# Pas de variante MTP : jusqu'au 15/09/2026 la raison écrite ici était « MTP
#   imposerait parallel=1 » ; c'est faux (cf. en-tête, vérifié dans le fork le
#   15/09/2026). La raison qui tient : les 4 slots de tâches auxiliaires
#   concurrentes font tout l'intérêt du 9b, et un drafter partagerait avec eux
#   le batch de vérification (parallel x (n-max + 1) colonnes) pour un gain qui
#   s'effondre à 4 voies ; non mesuré ici — la campagne multi-slot du
#   15/09/2026 (cf. en-tête) n'a porté que sur les trois modèles spéculatifs,
#   à reprendre si le sujet revient.
# Mesuré 21/08/2026 (Vulkan0, b10433) : prefill 837 t/s, décode 25,7 t/s ;
#   --bench-parallel : 4 requêtes = 78,6 t/s agrégés (x3,06), 20 t/s par
#   requête — le parallel 4 est justifié ; --bench-load : 1,9 s de chargement
#   (8,2 Go), TTFT à chaud 65 ms ; --bench-cache : 62 % au tour suivant, 63 % à
#   l'identique (cf. en-tête). Justesse OK (recopie) ; un calcul mental simple, lui, est raté
#   (93 → 33) : tâches auxiliaires, pas de raisonnement.
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   971 t/s, décode 25,7 t/s : prefill +16 %, décode identique au dixième.
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

# Ornith-1.5-35B-A3B nothink — DEFAULT AGENTIC, chargé à la demande
#   (le bandeau disait « always-on » jusqu'au 15/09/2026 : sur bigchuck
#   preload.conf ne contient que lfm2.5-2.6b, ce modèle monte à la demande en
#   8,3 s ; preload.conf est un choix utilisateur local, non versionné)
#   Remplace le 28/08/2026 les trois variantes Qwen3.6-35B-A3B (nothink,
#   thinking, mtp-nothink) par une seule section, parallel 4.
# Fiche (model card HF ornith-ai, 24/08/2026, pas de guide unsloth) : post-train
#   d'Ornith AI sur Qwen3.6-35B-A3B, arch llama.cpp qwen35moe (même famille
#   que le 35B-A3B remplacé : GDN + MoE, 3B actifs, support mainline acquis
#   en b10566). Un mmproj BF16 (0,9 Go) existe : texte seul, non téléchargé.
# ⚠ TÊTE MTP PRÉSENTE, contrairement à ce que ce bloc affirmait jusqu'au
#   15/09/2026 (« pas de tête MTP : pas de repo -MTP, pas de nextn, donc pas de
#   spéculation ici, et parallel 4 serait de toute façon incompatible » : les
#   deux moitiés sont fausses). Vérifié le 15/09/2026 avec gguf-py sur
#   bigchuck : l'en-tête du GGUF servi Ornith-1.5-35B-Q4_K_M.gguf porte
#   qwen35moe.nextn_predict_layers = 1 et les tenseurs
#   blk.40.nextn.{eh_proj,enorm,hnorm,shared_head_norm} : la tête est dans le
#   fichier principal, sans repo -MTP séparé. Le fork strix-llama.cpp a le
#   graphe MTP qwen35moe et l'autodétecte. Et parallel n'est pas une contrainte
#   de spec-type (cf. en-tête).
#   Test ISOLÉ du 15/09/2026 (fork strix-0007bc6, Vulkan0, 2 passes,
#   1200 tokens ; t/s spec-test / spec-refactor) :
#     sans spéculation              71,5 / n/a
#     draft-mtp n-max 2             93,1 / 99,8
#     draft-mtp n-max 4             92,4 / 100,9   (acceptance 0,68 / 0,81)
#     draft-mtp n-max 6             75,2 /  88,3
#     ngram-map-k 7 min-hits 2
#       + draft-mtp 4               90,3 / 113,2   (acceptance 0,65 / 0,83)
#   Sorties cohérentes avec la référence, aucune dérive du rollback GDN
#   observée sur ces passes. Lecture : n-max 4 est l'optimum, 6 retombe sous la
#   référence en spec-test (le batch dépasse les 8 colonnes de ggml-vulkan) ;
#   l'ajout du n-gram ne paie que sur du refactor.
#   ⚠ Le réglage SERVI de CETTE section n'est PAS changé : elle reste sans
#   spec-type et à parallel 4. La campagne multi-slot du 15/09/2026 a tranché :
#   en concurrence réelle (le régime de ce modèle, 2 à 3 slots simultanés dans
#   le journal du service les 13 et 14/09) le parallel 4 sans spéculation donne
#   138 t/s agrégés à 4 requêtes contre 102 avec MTP au même np 4 ; la
#   spéculation ne gagne qu'en mono-utilisateur (88,7 contre 71,6 t/s en solo,
#   +24 %). D'où DEUX sections sur le même GGUF : celle-ci pour l'agentic
#   concurrent, ornith-1.5-35b-a3b-mtp (déclarée juste en dessous) pour
#   l'usage mono-utilisateur.
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
#   Confirmé le 15/09/2026 sur le fork (138 t/s agrégés à 4 requêtes), et
#   c'est le meilleur réglage servi du parc en concurrence réelle : aucune
#   variante spéculative n'en approche à np 4 (cf. ci-dessus).
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
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   1129 t/s, décode 73,3 t/s : prefill +16 %, décode +4 % (sans spéculation
#   des deux côtés).
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

groupe "; --- Variante MTP du même GGUF Ornith (mono-utilisateur, un seul slot) ---"

# Ornith-1.5-35B-A3B nothink, VARIANTE MTP — même GGUF que la section
#   ci-dessus (Ornith-1.5-35B-Q4_K_M.gguf, tête MTP embarquée blk.40.nextn,
#   cf. le commentaire de la section de base), servi à un seul slot avec
#   spéculation. Créée le 15/09/2026 à l'issue de la campagne multi-slot.
#   Nommée `-mtp` par la convention de _preload_sanity (lib/preload.sh) : les
#   deux sections partagent la ligne `model =`, le garde-fou avertit si elles
#   sont préchargées ensemble (~22 Go chargés deux fois). Précédent du parc :
#   qwen3.8-27b / qwen3.8-27b-dflash-nothink sur un GGUF unique.
#   bench-devices.conf est indexé par dossier de GGUF : cette section hérite
#   du Vulkan0 mesuré pour ornith-1.5-35b-a3b, rien à y ajouter.
#   Bascule manuelle : /model ornith-1.5-35b-a3b-mtp
# POURQUOI DEUX SECTIONS, et laquelle sert quoi (mesures du 15/09/2026, fork
#   strix-0007bc6, Vulkan0) :
#     - concurrence réelle => la section de base, parallel 4 SANS spéculation :
#       138 t/s agrégés à 4 requêtes, contre 102 avec MTP au même np 4. C'est
#       le meilleur réglage servi du parc en concurrence, et le journal du
#       service montre 2 à 3 slots simultanés sur ce modèle les 13 et
#       14/09/2026 (subagents omp/opencode) : elle reste le défaut agentic ;
#     - mono-utilisateur => cette section, parallel 1 AVEC spéculation :
#       88,7 t/s en solo contre 71,6 sans, soit +24 %.
#   Multi-slot MTP mesuré et écarté : np 2 agrégé 75,7 t/s (x0,83), np 4
#   agrégé 102,1 (x1,12) — pas de refus du moteur, pas de plantage, sorties
#   saines, mais le batch de vérification parallel x (n-max + 1) passe à 10 et
#   20 colonnes, au-delà du seuil de 8 de ggml-vulkan (cf. en-tête). D'où
#   parallel 1 ici et le maintien de parallel 4 sans spéculation là-bas.
# spec-type ngram-map-k,draft-mtp, n-max 4, size-m 7, min-hits 2 : réglage du
#   test isolé du 15/09/2026 détaillé dans la section de base (n-max 4 optimum,
#   6 retombe sous la référence, l'ajout du n-gram ne paie que sur du
#   refactor : 90,3 t/s en spec-test et 113,2 en spec-refactor, acceptance
#   0,65 / 0,83). Le n-gram est gardé parce que l'usage visé est l'édition de
#   code, où le oldString se ré-émet mot pour mot depuis le prompt.
#   n-max 4 : batch de vérification 5, sous les 8 colonnes de ggml-vulkan.
# cache-reuse 0 : ignoré sur GDN comme sur la section de base ; la valeur est
#   posée explicitement, contrainte des sections spéculatives.
# Toutes les autres clés sont celles de la section de base (sampling, ctx,
#   cache-type-v q8_0, jinja, swa-full, ctx-checkpoints) : à ne changer qu'en
#   même temps que là-bas.
# --bench du 15/09/2026 tel que servi (fork strix-0007bc6, Vulkan0, 3 passes,
#   première mesure journalisée de cette section) : prefill 1073 t/s, décode
#   76,2 t/s, acceptance 0,55, contre 1129 / 73,3 pour la section de base le
#   13/09 sur le même fork (parallel 4, sans spéculation) : décode +4 %,
#   prefill -5 %. L'écart avec les +24 % du test isolé est normal, bench-task
#   génère sans répétition et les hits n-gram y sont rares (acceptance 0,55
#   contre 0,83 sur spec-refactor).
llama_model ornith-1.5-35b-a3b-mtp "
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
parallel             = 1
cache-reuse          = 0
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 4
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
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
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   3048 t/s, décode 70,8 t/s : prefill +34 % contre le 21/08, mais bench.log
#   du 02/09 (b10621) donnait déjà 2743 : l'essentiel vient du build.
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
# Drafter DFlash (servi depuis le 15/09/2026) : conversion GGUF communautaire
# (repo transmutator) du drafter z-lab/Qwen3-Coder-Next-DFlash, publié en
# safetensors pour vLLM/SGLang seulement. general.architecture = dflash,
# dorsale Qwen3 de 8 blocs, block_size 16, target_layers [4,12,24,36,44],
# 0,51 Go en Q8_0, sha256 vérifié 2d9505f7... Même dossier que le modèle, autre
# repo : le GGUF devient nécessaire au démarrage du modèle, ne pas le retirer
# de ~/models/qwen3-coder-next/.
download_hf qwen3-coder-next "transmutator/Qwen3-Coder-Next-DFlash-GGUF" \
  QWEN3_CODER_NEXT_DFLASH_PATH="Qwen3-Coder-Next-DFlash-q8_0.gguf"

# Qwen3-Coder-Next — MoE 80B hybrid-attention, agentic coding
# cache-type-v q8_0 : précision V critique pour les diffs de code
# cache-reuse 0 : ignoré sur l'état récurrent GDN (cf. en-tête) ; la
#   restauration de préfixe passe par cache-ram + ctx-checkpoints, au dernier
#   checkpoint seulement (65 % au tour suivant sur le fork, 64 au paquet).
# Candidat ROCm sur le papier (gros prefill agentic) : invalidé par la mesure
#   ci-dessous.
# Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10433) : prefill 470 t/s,
#   décode 46,7 t/s. ⚠ ROCm0 INUTILISABLE sur cette arch avec ce build : répond
#   « LAMPAMPAMPAMP… » à la recopie de contrôle (exclu par --bench-sanity avant
#   toute mesure). Deuxième arch MoE à opérateurs fusionnés cassée sur ROCm0
#   après DeepSeek V4 ; les denses et le 35B-A3B passent.
# Spéculation n-gram, ngram-map-k size_m 47 : SERVI DU 21/08 AU 15/09/2026,
#   RETIRÉ depuis au profit du seul drafter DFlash (cf. bas de bloc).
#   Historique conservé parce qu'il explique l'arch. Pas de tête MTP dans le
#   GGUF (ni nextn, ni repo -MTP) : le draft vient d'un drafter EXTERNE, cf.
#   « Drafter DFlash z-lab » en bas de bloc. Courbe t_forward(batch) Vulkan0
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
#   répétitions du modèle lui-même). Gardé jusqu'au 15/09/2026 parce qu'en
#   agentic l'édition domine, puis retiré : le drafter DFlash fait mieux sur
#   les deux prompts et sans ce compromis (bas de bloc). Sur bigchuck
#   spec-ngram.conf n'a jamais porté de ligne pour ce modèle (le 47 venait de
#   ce fichier) : rien à y nettoyer.
# --bench 21/08 (bench-task, sans spéculation) : 457 pp / 46,2 tg. --bench-cache :
#   64 % / 66 % (état récurrent). --bench-load : 72 s (47 Go relus depuis le
#   disque), TTFT à chaud 406 ms — à la demande, ce modèle coûte plus d'une
#   minute à charger quand DeepSeek est passé avant lui.
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   763 t/s, décode 48,7 t/s, acceptance 0,27 : prefill +63 %, décode +11 %
#   contre le paquet (468 / 43,7, b10433) à acceptance inchangée : le gain
#   vient du moteur, pas de la spéculation.
# Drafter DFlash z-lab : RETENU LE 15/09/2026, il remplace ngram-map-k 47.
#   Le « pas de tête MTP » ci-dessus ne ferme pas la spéculation par drafter :
#   un drafter DFlash z-lab pour cette arch existe en GGUF communautaire
#   ($QWEN3_CODER_NEXT_DFLASH_PATH, déclaré plus haut : repo transmutator,
#   Q8_0, 0,51 Go, arch dflash, block_size 16, target_layers
#   [4,12,24,36,44], dorsale Qwen3 de 8 blocs, 91 tenseurs).
#   Mesures ISOLÉES du 15/09/2026 (fork strix-0007bc6, Vulkan0, 2 passes ;
#   t/s spec-test / spec-refactor) :
#     ngram-map-k 47 (le réglage servi)  45,2 /  48,7
#     draft-dflash n-max 15               43,5 /  65,9
#     draft-dflash n-max 7                70,5 / 100,0   (acceptance 0,70 / 0,92)
#     ngram-map-k 47 + draft-dflash 7     67,9 / 104,6   (acceptance 0,65 / 0,82)
#   Lecture : draft-dflash n-max 7 lave le défaut connu de l'ancien réglage (le
#   -5,5 % en génération sans répétition) tout en doublant le refactor ; n-max
#   15 retombe, batch de vérification au-delà des 8 colonnes de ggml-vulkan.
#   Les n-grams N'APPORTENT RIEN DE NET par-dessus le drafter et coûtent de
#   l'acceptance (0,92 -> 0,82 en refactor, 0,70 -> 0,65 en générique) : le
#   15/09/2026 spec-type passe à draft-dflash SEUL, n-max 7, et
#   spec-ngram-map-k-size-m / -min-hits sont retirés du corps ini.
#   spec-draft-n-max 7 : valeur de la carte z-lab, et batch de vérification de
#   8 = 4+4 sous le découpage mat-vec du fork (cf. bloc qwen3.8-27b), donc pas
#   le pire cas 4+2+1 ; n-max 15 (batch 16) est au-delà des 8 colonnes de
#   ggml-vulkan et retombe, la mesure ci-dessus le confirme.
# parallel 1 maintenu, sur mesure multi-slot du 15/09/2026 (fork strix-0007bc6,
#   Vulkan0, --bench-parallel, spec-test, 600 tokens, 2 salves) : solo 73,0 t/s
#   à np 1, 74,9 à np 2, 74,5 à np 4 — aucun np ne bat le solo. Agrégé :
#   np 2 = 64,7 t/s (x0,86), np 4 = 68,5 (x0,92, dispersé de 63 à 74). La
#   raison est le batch de vérification, parallel x (n-max + 1) : 16 colonnes à
#   np 2 et 32 à np 4, tous deux au-delà du seuil de 8 de ggml-vulkan
#   (mul_mat_vec_max_cols), donc chaque forward change de régime. Ce modèle
#   reste à un slot : c'est un choix mesuré, pas une contrainte du moteur
#   (cf. en-tête du fichier).
# --bench du 15/09/2026 tel que servi (fork strix-0007bc6, Vulkan0, 3 passes) :
#   prefill 727 t/s, décode 52,2 t/s, acceptance 0,515, contre 763 / 48,7 /
#   0,27 en ngram-map-k 47 le 13/09 sur le même fork : décode +7,2 %,
#   acceptance presque doublée, prefill -4,6 % (le drafter décode aussi le
#   prompt, comme sur DeepSeek). Le compromis de l'ancien réglage (-5,5 % en
#   génération sans répétition) disparaît : le gain est net des deux côtés.
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
spec-type        = draft-dflash
spec-draft-model = $QWEN3_CODER_NEXT_DFLASH_PATH
spec-draft-n-max = 7
parallel         = 1"

# =============================================================================
# Famille Qwen3.8-27B : le GGUF cible (UD-Q4_K_XL, tête MTP embarquée, non
# servie depuis le 13/09/2026) et son drafter DFlash 2, dans le même dossier,
# pour la seule section qwen3.8-27b-dflash-nothink. Remplace qwen3.6-27b,
# qwen3.6-27b-nothink et qwen3.6-27b-mtp-nothink.
# Historique (13/09/2026) : tant qu'une section thinking existait, pas de
# nothink non-MTP, à parallel 1 il aurait fait doublon strict avec la section
# spéculative ; la thinking, non-MTP jusqu'au 12/09 puis draft-dflash, est
# retirée (docs/HISTORIQUE.md, « Qwen3.8-27B thinking : section retirée le
# 13/09/2026 »). Jusqu'au 12/09 le thinking restait non-MTP volontairement :
# chemin checkpoints/prompt-cache fiable, le rollback GDN sur rejet de draft
# étant encore jugé fragile en agentic (cf. 35B-A3B).
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
# ctx-checkpoints : arch hybride GDN/SWA identique 3.5/3.6 ; swa-full posé pour
#   la même raison mais inopérant ici, cf. la note swa-full à la fin du
#   commentaire de la section qwen3.8-27b-dflash-nothink.
# Vision : mmproj non téléchargé (--include du seul GGUF texte) → pas de
#   --mmproj, texte seul. Ajouter mmproj-F16.gguf + "mmproj =" si besoin un jour
#   (attention : mmproj incompatible MTP, cf. contrainte np/mmproj plus haut).
# Tête MTP embarquée VALIDÉE : llama-server charge draft-mtp sur ce GGUF et
#   --spec-test mesure une acceptance de 0,82 à 0,94 (15/08 et 21/08/2026) —
#   pas de repo -MTP séparé à réintroduire (mesures des 15/08 et 21/08/2026,
#   tête non servie depuis le 13/09/2026 ; elle reste utilisable en secours,
#   cf. « Historique MTP » de la section).
# =============================================================================

groupe "; --- Famille 27B (Qwen3.8 : GGUF cible + drafter DFlash 2) ---"

# Qwen3.8-27B — dense 27B hybrid-thinking (arch qwen35 : même base GDN + gated
# attention que 3.5/3.6, aucun bump llama.cpp requis), vision native, ctx natif
# 256K (1M via YaRN), Dynamic V3.0 (preview). Remplace TOUTE la famille 3.6-27B
# (base, MTP et le SFT coder Qwopus) : SWE-bench Pro 61.7 vs 53.5, QwenSWEBench
# 79.0 vs 49.3, Terminal Bench 2.1 73.0 vs 63.4, IFBench 79.5 vs 69.1.
# MTP : tête MTP embarquée dans le GGUF principal (unsloth : "MTP for fast
#   inference is available", pas de repo -MTP séparé dans la collection Qwen3.8 —
#   seul Qwen3.6 exigeait encore un GGUF MTP à part). Un seul fichier servait
#   donc les modèles non-MTP et MTP (fini le doublon Q6 + Q4 de la 3.6) ; la
#   tête n'est plus servie depuis le 13/09/2026, cf. l'en-tête.
# Quant UD-Q4_K_XL (~16 Go, quant par défaut du guide llama.cpp unsloth) :
#   ~26 % de poids en moins que le Q6 à relire par token → décode ×1,3-1,5
#   (Q6 : 8,5 t/s brut / 16 t/s MTP ; Q4 mesuré : 25,5 t/s MTP sur ROCm0 le
#   15/08, 31,4 t/s MTP sur Vulkan0 le 21/08 — cf. modèle dflash-nothink).
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
# Repo day-zero (mi-août 2026), template et quants mouvants à l'époque ; stable
#   depuis, aucun --update nécessaire au 13/09/2026.
download_hf qwen3.8-27b "unsloth/Qwen3.8-27B-GGUF" \
  QWEN38_27B_PATH="Qwen3.8-27B-UD-Q4_K_XL.gguf"
# Drafter DFlash 2 officiel (z-lab, diffusion par blocs, lit les couches 6, 20,
# 34, 48, 62 de la cible ; ~5,3 tokens acceptés par étape annoncés, cible en
# quant libre). Même dossier que le modèle, autre repo. Téléchargé le
# 13/09/2026 ; --spec-ab du même jour sur le fork (spec-refactor, 4 passes) :
# ngram-map-k 47 + draft-dflash n-max 7 = 64,5 t/s (+20 % contre MTP n-max 6,
# +12 % contre MTP n-max 4), draft-dflash seul 47,0 (acceptance 0,96).
# RETENU le 13/09/2026 : il remplace la tête MTP dans le modèle
# qwen3.8-27b-dflash-nothink ci-dessous (mesures des deux prompts dans son
# commentaire), d'où le renommage du modèle. Le GGUF devient nécessaire au
# démarrage de ce modèle : ne pas le retirer de ~/models/qwen3.8-27b/.
download_hf qwen3.8-27b "z-lab/Qwen3.8-27B-DFlash2-GGUF" \
  QWEN38_27B_DFLASH_PATH="Qwen3.8-27B-DFlash2-Q8_0.gguf"

# Qwen3.8-27B-DFlash nothink : spéculation n-gram + drafter DFlash 2, n-max 7.
#   Section thinking `qwen3.8-27b` RETIRÉE le 13/09/2026 : même GGUF,
#   reasoning_effort medium, reasoning-budget 4096, draft-dflash 7 seul :
#   349 / 21,7 t/s, acceptance 0,35 sur le fork strix-0007bc6 (contre
#   215 / 12,1 au paquet b10433), jamais préchargée et moitié moins vite que
#   cette section. Ses commentaires (reasoning-budget, spec-prefill essayé et
#   retiré, DFlash 2 sur du raisonnement) sont dans docs/HISTORIQUE.md,
#   section « Qwen3.8-27B thinking : section retirée le 13/09/2026 ». Pour la
#   ravoir : sampling thinking (temp 1.0 / top-p 0.95 / min-p 0, sans
#   presence-penalty), chat-template-kwargs reasoning_effort medium, spec-type
#   draft-dflash seul (le n-gram n'apporte rien sur du raisonnement),
#   parallel 1, et ne pas la précharger en même temps que celle-ci.
#   Renommé depuis qwen3.8-27b-mtp-nothink le 13/09/2026 : le suffixe -mtp
#   désignait la tête MTP embarquée, remplacée ici par le drafter externe
#   $QWEN38_27B_DFLASH_PATH (déclaré plus haut). Détail en bas de ce bloc.
#   Bascule manuelle : /model qwen3.8-27b-dflash-nothink
# Historique MTP, n-max 6 (mesuré --spec-tune Q4/Vulkan0 21/08/2026,
#   draft-mtp seul, spec-test.txt, 4 passes : k2=26,8 / k4=31,8 / k6=33,1 t/s,
#   acceptance 0,95 / 0,85 / 0,75 ; le modèle α prédit 33,8 à k8, <2 % → 6 est
#   l'optimum. 4 est à 4 % en dessous, hors tolérance). Sur ROCm0 le 15/08
#   c'était k2=22,2 / k4=25,5 / k6=26,0 → 4 : l'optimum dépend du device,
#   re-régler après chaque bascule. La tête MTP reste dans le GGUF et reste
#   utilisable (spec-type draft-mtp) si le drafter venait à manquer.
#   Historique de quant : Q6/n-max 2 = 16 t/s contre Q4/n-max 2 = 22 ;
#   + ngram-map-k size_m 47 = 47,4 sur refactor (mesuré avec n-max 4, avant ce
#   réglage).
# La tête MTP reste embarquée dans ce GGUF (cf. l'en-tête du bloc) : une
#   section thinking sur le même fichier, comme celle retirée le 13/09/2026,
#   ne doit PAS être préchargée en même temps (~16 Go chargés deux fois,
#   _preload_sanity le signale).
# (courbe k2/k4/k6 des deux devices : paragraphe « Historique MTP » ci-dessus
#   et docs/HISTORIQUE.md, Spéculation)
#   Re-régler avec --spec-ab (--spec-tune refuse ce modèle depuis le passage à
#   DFlash : il exige draft-mtp, cf. lib/spec.sh) après changement de
#   quant/build/device.
# cache-reuse 0 : ignoré sur l'arch hybride GDN (état récurrent), cf. l'en-tête
#   du fichier (était justifié par le MTP jusqu'au 13/09/2026).
# parallel 1 : un seul slot, régime agentic sérialisé. Jusqu'au 15/09/2026 ce
#   bloc ajoutait que « la contrainte MTP (-np > 1 and --mmproj are not yet
#   supported with MTP) redeviendrait bloquante si la tête MTP était reprise » :
#   cette contrainte n'existe pas dans le fork (vérifié le 15/09/2026 sur
#   strix-0007bc6, cf. en-tête), draft-dflash y est même explicitement
#   multi-séquences. Ce qui justifie réellement le 1 ici : l'usage (agentic
#   sérialisé, un agent à la fois), le contexte par slot (ctx-size est un pool
#   partagé), et le batch de vérification à parallel x (n-max + 1) qui
#   franchirait immédiatement les 8 colonnes de ggml-vulkan documentées plus
#   bas (déjà 8 à parallel 1 avec n-max 7 : np 2 en ferait 16). Valeur
#   inchangée après la campagne multi-slot du 15/09/2026, qui confirme la
#   règle (cf. en-tête) ; cette section n'y a pas été mesurée, son batch étant
#   déjà au seuil.
#
# spec-type ngram-map-k,draft-dflash (draft-mtp jusqu'au 13/09/2026) : la liste
#   est essayée dans l'ordre de
#   priorité de llama.cpp (les draftless d'abord) et la première implémentation
#   qui produit un draft non vide gagne le pas de décode ; un miss n-gram coûte
#   une sonde de hash et le drafter DFlash reprend la main. Gratuit en VRAM
#   (une table de 2^18 entrées, ~1 Mio par séquence) et sans perte ; le
#   drafter, lui, coûte 2,0 Go (cf. bas de bloc).
#   Intérêt en agentic : l'outil d'édition d'opencode fait ré-émettre le
#   oldString mot pour mot depuis le fichier lu, et ngram-map-k construit sa
#   map à partir du PROMPT entier, pas seulement du texte généré.
#   ngram-map-k plutôt que ngram-mod (le défaut de --spec-default d'upstream) :
#   le pool partagé de ngram-mod n'apporte rien tant que la section reste à
#   parallel 1 (argument conditionnel au réglage, pas une propriété du
#   modèle) : à re-évaluer, ngram-mod contre map-k, si cette section passait un
#   jour à plusieurs slots, où le pool partagé prend au contraire du sens — la
#   campagne du 15/09/2026 ne l'y a pas fait passer (batch déjà à 8). Et map-k
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
#   en série sur le seul slot (conséquence du réglage parallel 1 servi, pas
#   d'une contrainte du moteur ; cf. en-tête, vérifié le 15/09/2026 : plusieurs
#   slots sont possibles, le 1 est un choix maintenu par la campagne du
#   15/09/2026 ; le besoin de
#   cache-ram ci-dessous ne disparaîtrait pas pour autant, il se déplacerait
#   sur la RAM de KV). L'état de l'orchestrateur à 60k de
#   contexte pèse 9 Go (« prompt state size 9022 MiB exceeds cache size limit
#   4096 MiB, skipping ») : jamais sauvegardé, donc prefill complet de 58k
#   tokens (~325 s à 180 t/s) à chaque retour d'agent, au-delà du timeout
#   premier token d'omp (300 s) → 4 prefills annulés, 22 min perdues. 12 Go
#   gardent l'orchestrateur en RAM pendant qu'un agent occupe le slot.
# Pas de spec-draft-adaptive (option du fork strix-llama.cpp) : --spec-ab du
#   12/09/2026 (strix-0007bc6, spec-refactor.txt, 4 passes) : adaptatif 52,4 t/s
#   (acceptance 0,62) contre 53,7 (0,67) en draft fixe n-max 6. Aucun gain,
#   et l'adaptatif casse la calibration α de --spec-tune (k variable par
#   forward). Draft fixe conservé (mesuré contre la tête MTP, non re-mesuré
#   depuis le passage à DFlash 2).
# Historique (réglage MTP n-max 6, --bench du 13/09/2026, strix-0007bc6) :
#   prefill 360 t/s, décode 26,6, acceptance 0,59, prefill +38 % mais décode
#   -10 % contre le paquet (261 / 29,5 / 0,65, b10433), seul décode alors en
#   retrait du parc ; annulé par le passage à DFlash 2 (bas de bloc). Première
#   mesure du 12/09 à 321 / 25,8 / 0,59, contre-mesurée le 13/09. Sur
#   spec-refactor.txt (décode seul) : 53,7 t/s acceptance 0,67 contre
#   56,1 / 0,80 au paquet, soit -4 %.
# Historique du n-max MTP sur le fork (réglage servi le 13/09 jusqu'au passage
#   à DFlash le même jour) : 4 (était 6), parce que le -10 %
#   ci-dessus s'explique. Le fork découpe les mat-vec batchés en colonnes
#   (4/2/1), optimisation restreinte à q8_0 et q6_K par sa PR #27, et le
#   UD-Q4_K_XL porte 110 tenseurs q8_0 et 56 q6_K : elle s'applique donc ici.
#   Le batch de vérification vaut n-max + 1 : à n-max 6 il vaut 7, découpé en
#   4+2+1, le pire cas. llama-bench du 13/09/2026 (Vulkan0, strix-0007bc6, -b 8 -ub 8
#   -r 3) : pp7 68,9 t/s contre 74,4 avec GGML_VK_MMV_NO_SPLIT=1 et 74,5 au
#   paquet b10809, soit -7,4 % ; pp5 54,2 contre 56,9 (-4,7 %) ; pp4 47,8
#   contre 47,7 (aucune pénalité). --spec-ab du 13/09 (spec-refactor.txt,
#   4 passes) : n-max 4 = 57,8 t/s acceptance 0,712 contre 54,1 / 0,668 en
#   n-max 6 (run du 13/09, série n-max), soit +6,8 % ; en draft-mtp seul l'acceptance monte à 0,962 (la
#   tête MTP du fork est saine, le 0,67 est l'agrégat n-gram + MTP).
#
# DRAFTER DFLASH 2 (retenu le 13/09/2026, remplace la tête MTP) : le drafter
#   officiel z-lab $QWEN38_27B_DFLASH_PATH (2,0 Go, Q8_0, déclaré plus haut)
#   bat la tête MTP embarquée sur les deux prompts, sur le fork strix-0007bc6.
#   --spec-ab qwen3.8-27b-dflash-nothink 4 (lancé sous son ancien nom
#   -mtp-nothink), décode médian hors 1re passe :
#     spec-refactor.txt : ngram 47 + draft-mtp n-max 6 = 53,8 t/s (acc. 0,67,
#       run de la série DFlash) ;
#       ngram 47 + draft-mtp n-max 4 = 57,6 (0,71) ; ngram 47 + draft-dflash
#       n-max 7 = 64,5 (0,67) ; draft-dflash seul n-max 7 = 47,0 (0,96).
#     spec-test.txt (générique, pas de blocs à recopier) : ngram 47 + draft-mtp
#       n-max 4 = 30,5 (0,65) ; ngram 47 + draft-dflash n-max 7 = 35,9 (0,70) ;
#       draft-dflash seul n-max 7 = 37,0 (0,77) ; draft-mtp seul = 29,7 (0,74).
#   Soit +12 % contre le meilleur MTP en refactor et +18 % en générique, la
#   liste ngram + dflash gagnant partout sauf en générique pur, où le dflash
#   seul passe devant de 3 % (les hits n-gram y sont rares) : la liste est
#   gardée, le régime agentic est celui du refactor.
#   spec-draft-n-max 7 : valeur recommandée par la carte z-lab, et le fork note
#   que DFlash2 préfère 7. Elle contourne aussi le découpage mat-vec : le
#   drafter propose 7 tokens, le batch de vérification en vaut 8, découpé en
#   4+4 : pas de 2 ni de 1, donc pas le pire cas qui coûtait -7,4 % au batch 7.
#   Comme le size-m, cette valeur est surchargeable par spec-nmax.conf
#   (lib/ini.sh) ; --spec-tune ne peut plus l'écrire ici (il exige draft-mtp) :
#   la mesurer par --spec-ab, puis écrire la valeur à la main (spec-nmax.conf
#   ou ce bloc).
#   ngram-map-k size-m 47 et min-hits 2 inchangés (le drafter ne change rien
#   au régime n-gram, mesuré identique ci-dessus).
#   ⚠ Non mesuré sur le paquet Arch : b10809 expose bien draft-dflash (la
#   carte du modèle renvoie à la PR mainline #27342), mais ce réglage n'y a
#   jamais tourné, les chiffres ci-dessus sont ceux du fork seulement.
#   Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) :
#   prefill 359 t/s, décode 32,6 t/s, acceptance 0,595, contre 261 / 29,5 /
#   0,65 au paquet b10433 (+11 % de décode) et 360 / 26,6 / 0,59 en MTP
#   n-max 6 sur le même fork (+23 %). Le retrait de décode du fork est annulé,
#   le réglage passe au gain net des deux côtés.
# swa-full : inopérant sur cette architecture (le journal du serveur dit
#   « swa_full is not supported by this model »). La clé est gardée telle
#   quelle : elle ne coûte rien et redeviendra utile si l'arch est supportée.
llama_model qwen3.8-27b-dflash-nothink "
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
spec-type            = ngram-map-k,draft-dflash
spec-draft-model     = $QWEN38_27B_DFLASH_PATH
spec-draft-n-max     = 7
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
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   599 t/s, décode 52,9 t/s, acceptance 0,57 : prefill +80 %, décode neutre
#   (+2 %) contre le paquet (333 / 51,9, b10548).
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
# Repo squashé le 01/08/2026, quants alors mouvantes ; aucun ré-upload depuis,
#   dernier contrôle 13/09/2026, pas de --update.
# Décode ~12,5 t/s sur Strix Halo Vulkan avec ce quant : c'est la baseline
#   communautaire, bornée bande passante — mesuré ici 11,3 t/s sans spéculation
#   (21/08/2026, b10433), 12,3 avec n-gram : normal, pas un bug de config.
download_hf_shards deepseek-v4-flash "unsloth/DeepSeek-V4-Flash-0731-GGUF" \
  DSV4_FLASH_PATH="UD-IQ3_XXS/DeepSeek-V4-Flash-0731-UD-IQ3_XXS-00001-of-00004.gguf"
# Drafter DSpark officiel (extrait du checkpoint 0731 par unsloth, dossier
# dspark/ du même repo ; le Q8_0 est à la racine, le BF16 bit-exact de 11,3 Go
# dans dspark/, mesurés identiques par unsloth). general.architecture = dflash
# avec dorsale DSV4 (3 étages pleins, fenêtre 128, tête de Markov rang 256),
# block_size 5 : embeddings et tête de sortie empruntés à la cible, donc même
# device qu'elle, jamais de spec-draft-device. Vérifié le 15/09/2026 : le GGUF
# principal n'a AUCUN tenseur nextn (pas de tête MTP embarquée, le 0731 ne
# publie qu'un drafter DSpark), draft-mtp est donc impossible sur ce modèle.
download_hf deepseek-v4-flash "unsloth/DeepSeek-V4-Flash-0731-GGUF" \
  DSV4_FLASH_DSPARK_PATH="dspark-DeepSeek-V4-Flash-0731-Q8_0.gguf"

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
#   a été fermé sans merge). Le fork strix-llama.cpp comme le paquet Arch de
#   secours exposent draft-dspark et draft-mtp (déjà le cas en b10433).
#   Vérifié le 15/09/2026 : pas de tête MTP dans le GGUF (aucun tenseur nextn
#   dans les quatre shards, unsloth le confirme : « --mtp will not work with
#   these files »), le drafter est le sidecar DSpark déclaré plus haut
#   ($DSV4_FLASH_DSPARK_PATH, 10,9 Go), loader DSV4 de src/models/dflash.cpp
#   du fork (dsv4_hc_mult > 0, « DFlash with DSpark markov head »).
#   Test isolé du 15/09/2026 (fork strix-0007bc6, Vulkan0, ctx 32K, draft-dspark
#   seul n-max 3, 1200 tokens, hors service) : spec-test.txt 27,7 et 25,8 t/s
#   (acc. 0,59 / 0,52), spec-refactor.txt 28,0 et 32,9 t/s (acc. 0,63 / 0,81),
#   sortie saine (raisonnement puis code), mémoire 111 Go utilisés sur 124.
#   n-max : borné à block_size 5 par le checkpoint ; unsloth mesure l'optimum à
#   3 (défaut llama.cpp) sur B200, acceptance qui chute au-delà. Pas de
#   spec-draft-device (embeddings et tête de sortie empruntés à la cible), pas
#   de spec-draft-p-min (sans tête de confiance le fork refuse p-min > 0).
#   RETENU le 15/09/2026 : ngram-map-k 7 + draft-dspark n-max 3, sur --spec-ab
#   (fork strix-0007bc6, Vulkan0, spec-refactor.txt, 4 passes, médiane hors
#   1re passe) : ngram seul 31,2 t/s (acc. 0,91) ; draft-dspark seul n-max 3
#   35,6 (0,94) ; ngram + dspark n-max 3 = 38,7 (0,87, +24 %) ; n-max 2 = 35,0
#   (0,89) ; n-max 5 = 22,7 (0,48, -27 % : l'acceptance s'effondre au-delà de
#   3, comme mesuré par unsloth sur B200). Les deux drafts se complètent : les
#   n-grams recopient les blocs du prompt, DSpark porte le reste.
#   Coût : 10,9 Go de plus en mémoire (115 Go de poids, 111 Go utilisés à ctx
#   32K en isolé), à garder en tête avec le piège --models-max du routeur.
#   --bench du 15/09/2026 tel que servi (fork strix-0007bc6, 3 passes) :
#   prefill 199 t/s, décode 28,9 t/s, acceptance 0,68, contre 205 / 19,9 /
#   0,65 en n-gram seul le 13/09 : décode +45 %, prefill inchangé (-3 %, le
#   drafter décode aussi le prompt). La garde mémoire a dû décharger lfm2.5
#   (préchargé) pour faire la place : ~118 Go demandés pour 117,6 disponibles.
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
# reasoning-budget-* : options du fork strix-llama.cpp (cf. lib/fork.sh) —
#   budget de réflexion plus large que les 4096 de l'ancienne section thinking
#   qwen3.8-27b (retirée le 13/09/2026, cf. docs/HISTORIQUE.md), le modèle
#   pensant longuement avant de produire, avec deux paliers d'avertissement doux (60 % puis 85 %) et 192
#   tokens de grâce. À 12 t/s, c'est le garde-fou contre un raisonnement qui
#   s'emballe. Budget à affiner à l'usage.
#   ⚠ Ces quatre clés sont propres au fork (FORK_ONLY_KEYS, lib/fork.sh) : le
#   paquet Arch de secours connaît reasoning-budget mais pas
#   reasoning-budget-enable, -soft-ratio, -soft2-ratio ni -grace-tokens, et une
#   clé inconnue ferait échouer le routeur entier ; --start refuse donc de
#   démarrer sur le paquet tant qu'elles sont là, y revenir impose de les
#   retirer à la main puis --preload.
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes, n-gram
#   seul, avant DSpark) : prefill 205 t/s, décode 19,9 t/s, acceptance 0,65 :
#   prefill +86 % et décode +62 % contre le paquet (110 / 12,3, b10433), le
#   plus gros gain de décode du parc.
#   Le reasoning-budget ci-dessus n'a pas été atteint sur le test fait
#   (1678 tokens de pensée).
# parallel 2 (était 1) depuis le 15/09/2026, sur mesure multi-slot du même jour
#   (fork strix-0007bc6, Vulkan0, --bench-parallel) : en solo 25,2 / 26,6 /
#   25,9 t/s à np 1 / 2 / 4 ; en agrégé np 2 = 32,4 t/s (x1,22, 16,9 t/s par
#   requête, acceptance 0,63) et np 4 = 20,8 (x0,80, 5,4 t/s par requête).
#   C'est le SEUL cas du parc où le multi-slot paie, et la raison est
#   arithmétique : le batch de vérification vaut parallel x (n-max + 1) =
#   2 x (3 + 1) = 8 colonnes, pile le seuil de ggml-vulkan
#   (mul_mat_vec_max_cols = 8, cf. en-tête et bloc qwen3.8-27b) ; à np 4 il
#   vaut 16, au-delà du seuil, et le rendement s'effondre. Le petit n-max 3
#   imposé par le block_size DSpark est ce qui rend ce réglage possible.
#   ⚠ Conséquence sur le contexte : ctx-size est un POOL PARTAGÉ entre les
#   slots, donc les 131072 ci-dessous deviennent 65536 par slot. Ne pas monter
#   ctx-size pour compenser : 115 Go de poids (modèle + drafter) sur 128,
#   12 Go de marge, il n'y a pas la place. Mémoire inchangée par le passage à
#   2 slots : 112 Go résidents mesurés à np 1, 2 et 4.
#   --bench du 15/09/2026 tel que servi à parallel 2 (fork strix-0007bc6,
#   3 passes) : prefill 196 t/s, décode 28,8 t/s, acceptance 0,69, contre
#   199 / 28,9 / 0,68 à parallel 1 le matin même : le deuxième slot ne coûte
#   RIEN sur une requête isolée (écart -1,5 % et -0,4 %, dans le bruit).
#   --bench-parallel du 15/09/2026 (N=2 lu sur le serveur, 2 passes par
#   salve) : 1 requête 33,6 t/s ; 2 requêtes 39,0 t/s agrégés (x1,16),
#   19,9 t/s par requête. La commande affiche « Pas de gain d'agrégat » :
#   c'est son seuil heuristique, x1,16 est un gain réel et le seul du parc en
#   spéculation. La garde mémoire décharge les autres modèles pour charger
#   celui-ci (117,9 Go demandés), c'est normal.
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
spec-type        = ngram-map-k,draft-dspark
spec-draft-model = $DSV4_FLASH_DSPARK_PATH
spec-draft-n-max = 3
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
reasoning-budget-enable        = true
reasoning-budget               = 6144
reasoning-budget-soft-ratio    = 0.6
reasoning-budget-soft2-ratio   = 0.85
reasoning-budget-grace-tokens  = 192
jinja            = true
parallel         = 2"

groupe "; --- Laguna S 2.1 : arch 'laguna', servie par le fork strix-llama.cpp ; sur le paquet Arch de secours, b10087 minimum (vérifié jusqu'à b10548) ---"

# Laguna S 2.1 (poolside) — MoE 118B (8B actifs), agentic coding, shards UD-Q4_K_XL
# 73.4 Go / 3 shards.
# (ré-upload de fin juillet 2026 absorbé, cf. docs/HISTORIQUE.md)
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
#   tenseurs d'écart), fork poolside/llama.cpp branche laguna requis, hors
#   périmètre ici : ni le paquet Arch de secours ni le fork strix-llama.cpp ne
#   portent ce contrat. Flags à réutiliser le jour où le mainline
#   suit : --spec-type draft-dflash -md <drafter> --spec-draft-n-max 7 (bloc
#   entraîné 16).
#   Retours communauté sur le fork poolside : jusqu'à +30 tok/s.
#   12/09/2026 : le fork strix-llama.cpp revendique DFlash (draft-dflash dans
#   son --spec-type, loader src/models/dflash.cpp, DFlash2/DSpark compris),
#   d'où le draft-dflash remis ci-dessous le 12/09, puis retiré le jour même
#   (cf. VÉRIFIÉ ci-dessous) — MAIS LA LECTURE DU CODE DIT QUE ÇA
#   VA ENCORE ÉCHOUER, et de la même façon : le contrôle de comptage est
#   toujours là (« wrong number of tensors; expected %d, got %d »,
#   src/llama-model-loader.cpp) et le loader DFlash du fork ne crée AUCUN
#   blk.N.attn_gate — aucune trace d'attn_gate ni de laguna dans dflash.cpp.
#   Or le drafter en porte un par couche : ses tenseurs (lus dans l'en-tête du
#   GGUF) font 12 par couche sur 6 couches = 72, plus 4 hors blocs = 76, quand
#   le loader générique n'en crée que 11 x 6 + 3 = 69. C'est exactement l'écart
#   de 7 déjà mesuré.
#   VÉRIFIÉ le 12/09/2026 sur strix-0007bc6, et la lecture du code avait raison :
#   refus identique au paquet Arch (« common_speculative_init_result: failed to
#   load draft model »), le modèle ne charge plus du tout via le routeur. Retour
#   au NGRAM SEUL le jour même : draft-dflash, spec-draft-model et
#   spec-draft-n-max retirés du corps ci-dessous. Le drafter reste déclaré et
#   sur disque (2,2 Go) pour le jour où un moteur crée les attn_gate : il
#   faudra le fork poolside/llama.cpp branche `laguna`, ou un DFlash mainline
#   qui connaisse le contrat Laguna.
# Candidat ROCm sur le papier (gros prefill agentic) : invalidé par la mesure
#   ci-dessous.
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
#   récurrent). --bench-load : 90,5 s depuis le disque (13/09/2026, fork ; 67 s
#   au paquet le 21/08), TTFT à chaud 138 ms (173 ms au paquet).
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   346 t/s, décode 29,6 t/s, acceptance 0,80 : prefill +36 %, décode -2 %
#   contre le paquet (255 / 30,3 / 0,835, b10548), soit le bruit de mesure.
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

groupe "; --- Qwen3.8-Flash-Next : arch 'qwen4exp', servie par le fork strix-llama.cpp ; sur le paquet Arch de secours, b10661 minimum (PR #27742, mergée le 27/08/2026, présente dans b10809) ---"

# Qwen3.8-Flash-Next (Qwen) : MoE 125B (6B actifs, 512 experts, 10 routés + 1
# partagé) + 51B d'embeddings n-gram (bigrammes/trigrammes à la couche 2, table
# de hash lue une fois par forward), arch GDN (3 couches sur 4) + Qwen Sparse
# Attention (QSA, budget 2048, ratio 4) + hyper-connections, vision Qwen3-VL,
# ctx natif 256K (1M via YaRN). Shards UD-IQ4_XS (93,7 Go).
# SUPPORT llama.cpp : general.architecture = qwen4exp, PR #27742 (unsloth,
#   mergée le 27/08/2026 dans b10661 : convertisseur, graphe texte, QSA avec un
#   troisième cache dans llama_memory_hybrid_idx, vision, 3 correctifs de
#   llama-quant). Le paquet Arch llama-cpp suit les tags stables semver
#   ('#tag=v${pkgver}'), pas les pre-releases bXXXXX : un changement de pkgver
#   ne prouve rien (0.3.0 = b10621, sans qwen4exp). Le seul contrôle fiable :
#   strings /usr/lib/libllama.so* | grep -x qwen4exp
#   (attente close le 05/09/2026 : le paquet 0.4.0-1.1 = b10809 porte qwen4exp)
#   Suivi de l'attente et des jalons : cf. docs/HISTORIQUE.md, « Passage au
#   fork (12 et 13/09/2026) » (plan détaillé : PLAN-qwen3.8-flash-next.md,
#   supprimé au merge du 13/09/2026, récupérable dans l'historique git).
# Quant : grille HF complète depuis le 27/08 (uploads 15:01 à 15:16 UTC) :
#   UD-IQ1_S 72,5 / UD-Q2_K_XL 78,9 / UD-IQ3_XXS 82,0 / UD-Q3_K_XL 90,0 /
#   UD-IQ4_XS 93,7 / UD-Q4_K_XL 111,3 Go (3 shards jusqu'à l'IQ4_XS, 4 pour
#   le Q4_K_XL). Retenu UD-IQ4_XS (validé le 27/08) : experts en 4 bits, et
#   ~30 Go de marge sur 124 Go pour le KV à 128k, la table n-gram et le
#   système, plus que DeepSeek V4 (104 Go) qui tourne. Le Q4_K_XL (111 Go)
#   ne laisse rien. Repli si le chargement est trop juste : UD-IQ3_XXS
#   (82 Go), changer l'entrée, le glob suit.
#   ré-upload redouté : n'a pas eu lieu, vérifié le 04/09 (tailles des shards
#   consignées dans docs/HISTORIQUE.md). Pas de --update.
# Sampling officiel (guide unsloth + model card) : même table que Qwen3.8-27B
#   (cf. l'en-tête du bloc Qwen3.8-27B plus haut), thinking et instruct.
# Thinking ON par défaut (<think>), reasoning_effort xhigh (défaut) / medium /
#   low, "high" est replié sur xhigh par le template ; enable_thinking false =
#   nothink. preserve_thinking (garde les traces des tours précédents) : true
#   par défaut, côté client. Le modèle ci-dessous est en NOTHINK avec le
#   sampling instruct ; variante « low » si on veut un peu de raisonnement :
#     chat-template-kwargs = {"reasoning_effort":"low"}  + sampling thinking
#     (temp 1.0 / top-p 0.95, presence-penalty 0)
# cache-type-v q8_0 : agentic/coding, précision V critique (tool calls, diffs)
# cache-reuse 0 : état récurrent GDN (l'interdit à lui seul), et de nouveau
#   contrainte MTP depuis le retour de draft-mtp (jalon 2, cf.
#   docs/HISTORIQUE.md, « Passage au fork (12 et 13/09/2026) »)
# Pas de swa-full ni ctx-checkpoints : pas de SWA (QSA n'est pas une fenêtre
#   glissante) : à revoir si la PR expose des checkpoints pour l'état GDN.
# jinja : template unsloth (developer role, systèmes fusionnés, tool calling
#   au format <function=...><parameter=...>).
# Vision : mmproj-F16.gguf publié le 27/08 mais pas téléchargé, incompatible
#   MTP de toute façon : texte seul.
# MTP : la tête n'est PAS dans le GGUF principal (retirée par unsloth le
#   01/09), elle est publiée en sidecar dans MTP/ du repo HF. Deux familles de
#   fichiers : les « shared- » (2,60 Go) empruntent embeddings et projection de
#   sortie au modèle hôte, les AUTONOMES portent les leurs. Le fork
#   strix-llama.cpp ne sait PAS emprunter les tenseurs partagés du modèle
#   principal : c'est donc la version autonome Q8_0 (4,1 Go) qui est déclarée
#   ci-dessous, et elle seule.
#   Le paquet Arch, lui, ne sait charger ni l'une ni l'autre : ni graphe MTP
#   pour qwen4exp, ni emprunt de tenseurs entre modèles, ni --spec-type
#   draft-mtp pour cette arch — c'est la PR #28243, toujours non mergée au
#   13/09/2026. Le fork apporte le graphe MTP qwen4exp et le drafter externe :
#   le jalon 2 (cf. docs/HISTORIQUE.md, « Passage au fork (12 et 13/09/2026) »)
#   est donc débloqué par le fork, PAS par le mainline.
#   Sur cette arch (GDN + MoE 512 experts, la même famille que Qwen3-Coder-Next)
#   on attendait un gros surcoût fixe par pas spéculatif ; mesuré le 05/09/2026
#   (b10809, Vulkan0) : ce n'est PAS le cas ici, le petit draft gagne, cf. le
#   commentaire de la section -mtp-nothink.
# parallel 1 : la raison écrite ici jusqu'au 15/09/2026, « contrainte MTP
#   (np > 1 non supporté) », ne tient pas : cette phrase vient d'une doc
#   unsloth, pas du fork (vérifié le 15/09/2026 dans strix-0007bc6, cf.
#   en-tête). draft-mtp y est vectorisé par séquence et sans assert sur n_seq :
#   NON ÉPROUVÉ à np > 1, pas interdit. La raison qui tient, elle, est la
#   mémoire, et elle suffit : 93,7 Go de poids sur 124 Go, un deuxième slot de
#   KV à 128k mangerait la marge ; et ctx-size étant un pool partagé, passer à
#   2 slots couperait aussi en deux le contexte par requête. Valeur inchangée
#   après la campagne multi-slot du 15/09/2026 (cf. en-tête) : cette section
#   n'y a pas été mesurée, la mémoire tranchant avant le rendement.
# Device : Vulkan0 (--bench-devices 05/09/2026, b10809 : prefill 181 t/s,
#   décode 24 t/s brut). ROCm0 EXCLU par la question de contrôle : réponse
#   « LAMPAMPAMPAMP... » dégénérée, le même symptôme que DeepSeek V4 et
#   Qwen3-Coder-Next (MoE à opérateurs fusionnés). Re-tester à chaque bump
#   de ggml-hip, en lisant le texte généré.
download_hf_shards qwen3.8-flash-next "unsloth/Qwen3.8-Flash-Next-GGUF" \
  QWEN38_FLASH_NEXT_PATH="UD-IQ4_XS/Qwen3.8-Flash-Next-UD-IQ4_XS-00001-of-00003.gguf"
# Tête MTP en sidecar, même repo, sous-dossier MTP/ (recréé tel quel sous le
# dossier modèle par _dl). Téléchargée sur bigchuck le 12/09/2026. Version
# AUTONOME Q8_0 (4,1 Go, 34 tenseurs) : le fork ne sait pas emprunter les
# tenseurs partagés du modèle hôte, la « shared- » (2,60 Go, 32 tenseurs) ne lui
# sert donc à rien et n'est plus déclarée depuis le 12/09/2026 — l'exemplaire
# déjà téléchargé reste sur disque et --cleanup ne le purgera pas (il est dans
# MTP/, sous-dossier protégé en bloc comme un dossier de quant) ; le supprimer à
# la main ne coûte rien.
# Ce sidecar n'est PAS chargeable tel quel par le fork : il nomme le mixeur final
# des hyper-connexions blk.48.nextn.hc_head_* (convention de la PR mainline
# #28243) quand le graphe qwen4exp du fork lit output_hc_* (« check_tensor_dims:
# tensor 'output_hc_norm.weight' not found », et c'est le modèle entier qui ne
# charge plus). D'où la copie renommée ci-dessous ; le fichier d'origine reste la
# SOURCE, et redevient utilisable tel quel le jour où #28243 est mergée
# (toujours non mergée au 13/09/2026).
download_hf qwen3.8-flash-next "unsloth/Qwen3.8-Flash-Next-GGUF" \
  QWEN38_FLASH_NEXT_MTP_PATH="MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf"
# Copie renommée pour le fork, produite en local (aucun repo ne la porte) par
# tools/mtp-rename-hc-head.py : trois tenseurs renommés, données recopiées
# telles quelles, mêmes formes et mêmes types. Faite sur bigchuck le 12/09/2026,
# et refaite automatiquement par --setup si elle manque ou si la source a bougé.
derive_gguf qwen3.8-flash-next \
  QWEN38_FLASH_NEXT_MTP_STRIX_PATH="MTP/mtp-Qwen3.8-Flash-Next-strix-Q8_0.gguf" \
  "$QWEN38_FLASH_NEXT_MTP_PATH" tools/mtp-rename-hc-head.py

# Qwen3.8-Flash-Next nothink : spéculation mixte n-gram + MTP, sampling instruct.
# Renommée -nothink le 04/09, quand draft-mtp avait été retiré faute de moteur
#   capable de charger le sidecar ; revenue à -mtp-nothink le 12/09/2026 avec le
#   retour de draft-mtp sur le fork, comme l'était alors
#   qwen3.8-27b-mtp-nothink (renommée qwen3.8-27b-dflash-nothink le
#   13/09/2026, la tête MTP y étant remplacée par le drafter DFlash 2).
# Jalon 2 (MTP de Flash-Next, cf. docs/HISTORIQUE.md, « Passage au fork »)
#   DÉBLOQUÉ le
#   12/09/2026 par le renommage du sidecar (tools/mtp-rename-hc-head.py, cf. la
#   déclaration ci-dessus) : le fork apporte le graphe MTP qwen4exp et le
#   drafter externe, il ne manquait que la convention de nom.
#   Historique du même jour : le premier essai, avec les sidecars unsloth tels
#   quels, refusait de charger (« tensor 'output_hc_norm.weight' not found »,
#   Flash-Next ne démarrait plus du tout) et le bloc avait été remis en n-gram
#   seul le soir même, avant que la cause soit trouvée.
#   Chargement validé sur le fork (instance isolée, draft-mtp seul, n-max 4,
#   ngram-on-disk) : sortie cohérente, acceptance 0,64 (215/336), 40,3 t/s sur
#   300 tokens de code. Les tenseurs blk.48.indexer.* du sidecar sont ignorés
#   par le fork (« unused tensor », sans effet).
#   Référence à battre, n-gram seul sur le fork : prefill 414 t/s, décode
#   30,9 t/s (--bench du 12/09/2026, strix-0007bc6, Vulkan0, ngram-on-disk).
#   MESURÉ le 12/09/2026 via le routeur (strix-0007bc6, Vulkan0, mode mixte
#   ngram-map-k 7 + draft-mtp n-max 4, ngram-on-disk) :
#   --spec-test 4 passes (spec-test.txt) : 48,8 t/s, acceptance 0,86 agrégée ;
#   --bench 3 passes : prefill 383 t/s, décode 50,0 t/s, acceptance 0,87,
#   soit +62 % de décode et -7 % de prefill contre le n-gram seul. MTP GARDÉ.
#   Mémoire utilisée avec Flash-Next chargé : 79 Go.
#   --spec-tune 2,4,6,8 4 (draft-mtp seul, spec-test.txt) : n-max 2 = 43,0 t/s
#     (acceptance 0,95) / 4 = 50,7 (0,90) / 6 = 49,5 (0,84) / 8 = 32,7 (0,80).
#     Retenu 4 (spec-nmax.conf), la valeur de départ est confirmée. La chute à
#     8 est la marche de la courbe llama-bench entre les batchs 8 et 9 (x2,5,
#     cf. plus bas) : au-delà de 8 tokens de draft le pas spéculatif coûte plus
#     que ce que l'acceptance rapporte.
# Mesuré le 05/09/2026 (bigchuck, llama-cpp 0.4.0-1.1 = b10809, ggml 0.23.0,
#   UD-IQ4_XS, Vulkan0, médianes hors 1re passe) :
#   --bench 3 passes : prefill 197 t/s, décode 25,9 t/s (acceptance 0,75 sur
#     le prompt générique) ; le premier run du matin donnait 181 / 24,0.
#   --spec-ngram-tune 4 passes puis --spec-ab (spec-refactor.txt), identiques :
#     sans spéculation 25,1 t/s ; size_m 7 = 54,0 t/s (+115 %, acceptance
#     0,95) ; size_m 47 = 48,2 t/s (+92 %, acceptance 0,86, et la passe 2
#     (seed 44) sort une réponse illisible dans les deux runs). Retenu 7
#     (spec-ngram.conf). Courbe llama-bench : batch 1 = 41 ms, batch 8 = 94 ms
#     (x2,3), marche x2,5 entre 8 et 9, batch 48 = 515 ms (x12,6) : jugée
#     défavorable, la mesure dit le contraire, comme pour Laguna et gpt-oss.
#     Contrairement à Qwen3-Coder-Next (même famille GDN + MoE), le petit
#     draft n'est pas perdant : pas de surcoût fixe visible par pas spéculatif
#     sur ce build.
#   --bench-cache : tour suivant 62 %, édition en amont 0 %, requête identique
#     64 % (état récurrent GDN, restauration au dernier checkpoint).
#   --bench-load : 60,8 s depuis le disque (88 Go, sidecar MTP compris,
#     13/09/2026) ; 14,1 s avec le fichier encore en cache de pages (05/09),
#     TTFT à chaud 86 ms.
# ngram-on-disk : option du fork strix-llama.cpp (cf. lib/fork.sh). La table
#   n-gram per_layer_token_embd (28,8 Go, propre à qwen4exp) n'est ni mappée ni
#   chargée, chaque batch relit du GGUF les seules lignes qu'il rassemble.
#   Mesuré le 12/09/2026 sur le fork (A/B de l'option, run antérieur au --bench
#   de référence 414 / 30,9) : même prefill et même décode (391 / 27,3
#   t/s contre 380 / 27,3 sans), sortie identique, mémoire utilisée 72 Go au
#   lieu d'environ 100.
#   ⚠ Le paquet Arch (b10809) NE connaît PAS cette clé et refuse alors de
#   démarrer le routeur ENTIER (« option 'ngram-on-disk' not recognized in
#   preset », vérifié le 12/09/2026 — l'ini n'est pas tolérant aux clés
#   inconnues). Revenir au paquet Arch (--unset-fork) impose donc de retirer
#   cette ligne à la main puis de relancer --preload ; le dépôt ne filtre rien,
#   il refuse seulement de démarrer (FORK_ONLY_KEYS, lib/fork.sh).
llama_model qwen3.8-flash-next-mtp-nothink "
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
spec-type        = ngram-map-k,draft-mtp
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
spec-draft-model = $QWEN38_FLASH_NEXT_MTP_STRIX_PATH
spec-draft-n-max = 4
ngram-on-disk    = true
jinja            = true
parallel         = 1"

# Préchargement par défaut (sans preload.conf) : le léger agentic edge seul,
# le reste en LRU — les always-on se choisissent via --preload.
DEFAULT_PRELOAD=(lfm2.5-2.6b)
