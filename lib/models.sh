# lib/models.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# BACKEND : UN SEUL, ROCm0
#
# Depuis la bascule en conteneur (18/09/2026) le moteur du service est l'image
# de runtime/ : ROCm 10.0 gfx1151 + ROCr/HIP retained-PM4 + halo-box/
# strix-llama.cpp construit en HIP SEUL. Il n'y a AUCUN backend Vulkan dans
# l'image : ROCm0 est le seul device exposé, il n'y a plus rien à comparer.
# Conséquences, toutes actées le 18/09/2026 :
#   - DEFAULT_DEVICE = ROCm0, et plus aucune ligne `device =` par section ;
#   - --bench-devices, bench-devices.conf et le mécanisme BENCH_DEVICE sont
#     retirés (lib/ini.sh, lib/bench/) ; --bench-sanity reste, et devient la
#     première étape BLOQUANTE de tools/qualif-modele.sh : c'est elle qui
#     attrape un texte propre mais faux, quand timings.py attrape le charabia ;
#   - les exclusions « ROCm0 donne du charabia » des blocs ci-dessous datent du
#     ROCm SYSTÈME (paquet ggml-hip) et sont GUÉRIES par le runtime
#     retained-PM4 de l'image : elles restent en commentaire, datées, comme
#     historique. Le charabia « Nous dev dev dev » de DeepSeek V4 et le
#     « LAMPAMPAMP » de Qwen3-Coder-Next ont été re-testés le 18/09/2026 sur
#     l'image, comptages justes des deux côtés.
# Les paquets ggml de l'hôte (ggml-vulkan, ggml-hip) ne valent plus que pour
# les outils HORS service (llama-bench des courbes de batch, llama-server
# jetable de tools/spec-isolate.sh), qui tournent encore sur le fork Vulkan de
# lib/fork.sh.
#
# ⚠ GGML_CUDA_ENABLE_UNIFIED_MEMORY est INTERDIT sur ce runtime : il fait
#   passer chaque allocation par hipMallocManaged et la sortie se corrompt
#   (cf. runtime/AMONT.md et lib/compose.sh). Il reste exporté par lib/spec.sh
#   et les tools/ pour le moteur de l'HÔTE ; ne jamais le propager à _dk_run ni
#   au compose.
# =============================================================================

DEFAULT_DEVICE="ROCm0"

# =============================================================================
# GARDE-FOU batch-size / ubatch-size (18/09/2026)
#
# Sur le moteur de l'image, batch-size / ubatch-size 16384 provoque une ERREUR
# DE SEGMENTATION (code de sortie 139) dès un prompt de 8k tokens, sur TOUS les
# modèles essayés sauf Qwen3.8-Flash-Next, et coûte environ 33 Gio de tampons.
# generate_models_ini (lib/ini.sh) refuse donc d'émettre plus de INI_BATCH_MAX
# pour une section absente de INI_BIG_BATCH_OK, y compris quand la valeur vient
# d'une surcharge --spec-ab. Partout ailleurs : rien n'est posé, le moteur
# applique son défaut (2048).
# Ajouter une section ici demande une mesure : un prompt de 8k tokens au moins,
# et la sortie relue.
# =============================================================================
INI_BATCH_MAX=4096
INI_BIG_BATCH_OK=(qwen3.8-flash-next-mtp-nothink)

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
#   - device : jamais écrit ici. generate_models_ini injecte `device`,
#     `device-draft`, `mmproj-device` et `spec-draft-ngl = all` dans chaque
#     section concernée, tous sur le device unique ROCm0 (cf. en-tête)
#   - batch-size / ubatch-size : jamais posés, sauf la section Flash-Next
#     (INI_BIG_BATCH_OK, cf. en-tête). Ailleurs, le défaut du moteur (2048)
#   - cache-reuse = 0 : explicite sur toutes les sections à état récurrent (GDN)
#     ou à attention hybride/MLA ; plus aucune section n'hérite du 4096 global
#     depuis le retrait de gpt-oss le 16/09/2026 (MoE sans état récurrent,
#     attention + SWA : le cache-reuse y servait). Le
#     cache-reuse
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
#     commun) = 0 % réutilisé (4 % sur gpt-oss, le seul au-dessus de zéro,
#     retiré depuis),
#     le cache ne sert que les continuations — ne
#     jamais réécrire l'historique (compaction, tronquage) si on tient au cache.
#   - cache KV : f16 sur K et V pour tout le parc, posé une seule fois dans les
#     flags globaux ([*], lib/ini.sh) depuis le 18/09/2026. Avant cette date le
#     global était q8_0 / q4_0 et chaque section agentic surchargeait
#     cache-type-v = q8_0 (le V q4_0 dégradait le tool calling, cf. doc
#     llama.cpp function-calling). Ces surcharges ont disparu : la campagne du
#     17 au 18/09/2026 a tourné en f16 / f16 sur les huit modèles mesurés,
#     aucune mesure de ce moteur ne justifie une valeur quantifiée, et sur
#     DeepSeek f16 et q8_0 sont équivalents en mémoire comme en débit. Sur le
#     27B et Muse-Glimmer, mesuré plus tôt sur le fork Vulkan, le V f16 donnait
#     déjà une meilleure acceptance du drafter que le q8_0. SEULE EXCEPTION,
#     assumée : ornith-1.5-35b-a3b-parallel garde son q8_0, faute d'avoir été
#     mesurée sur ce moteur (cf. son bloc)
#   - swa-full + ctx-checkpoints : posé sur ornith-1.5-9b-mtp-nothink,
#     ornith-1.5-35b-a3b-parallel et
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
#       deepseek-v4-flash   np 2 = x1,22 agrégé (batch 2x4 = 8, pile le
#                           seuil ; np 4 = x0,80, batch 16) -> servi à 2 le
#                           15/09 puis REMIS À 1 le soir même : --bench-agentic
#                           2 boucles = x1,16 de tâches seulement, décode par
#                           boucle divisé par deux, ctx par slot divisé par
#                           deux, aucune concurrence réelle sur ce modèle
#       ornith-1.5-35b-a3b-parallel
#                           np 4 sans spéculation x1,93, 138 t/s agrégés, le
#                           meilleur du parc en concurrence -> RÉGLAGE INCHANGÉ,
#                           seul le NOM de la section a pris le suffixe
#                           -parallel le 15/09/2026 ; la variante MTP
#                           mono-utilisateur est une SECTION à part
#                           (ornith-1.5-35b-a3b-mtp, parallel 1, +24 % en
#                           solo, x0,83 à np 2 et x1,12 à np 4)
#       qwen3-coder-next    solo 73,0 t/s, np 2 = x0,86, np 4 = x0,92 : aucun
#                           np ne bat le solo (batch 16 et 32) -> RESTE À 1
#       qwen3.5-9b          le MTP multi-slot s'effondre (np 4 n-max 1 = 18,2
#                           t/s agrégés contre 80,8 sans spéculation) : garder
#                           les 4 slots imposait d'abandonner le drafter
#                           (section remplacée le soir même par
#                           ornith-1.5-9b-mtp-nothink, cf. docs/HISTORIQUE.md)
#       lfm2.5-2.6b         DSpark np 2 (batch 8, pile le seuil) = ~x1,1 pour un
#                           débit par requête divisé par deux
#     Ces deux derniers ont eu une variante `-parallel` (4 slots, sans drafter)
#     le 15/09/2026, RETIRÉE le soir même : aucune concurrence n'avait jamais
#     été observée sur eux au journal du service, et leur section à drafter
#     gagne en solo. Décision utilisateur : pas de parallel si perte de perf.
#     Le seul multi-slot du parc est donc ornith-1.5-35b-a3b-parallel, où la
#     concurrence
#     est réelle (2 à 3 slots au journal) et ne coûte rien.
#     Règle générale qui s'en dégage : un modèle spéculatif ne gagne au
#     multi-slot que si parallel x (n-max + 1) reste <= 8 colonnes.
#     ⚠ HISTORIQUE DEPUIS LE 18/09/2026 : ce seuil de 8 colonnes est celui de
#     ggml-vulkan (mul_mat_vec_max_cols, constante de compilation), et le
#     découpage mat-vec 4/2/1 est celui de la PR #27 du fork, Vulkan lui aussi.
#     Le moteur du service est maintenant l'image HIP, où NI l'un NI l'autre
#     n'a été re-mesuré. Les n-max et size-m du parc restent ceux qui ont été
#     choisis sous ces contraintes ; la campagne du 17 au 18/09/2026 les a
#     mesurés TELS QUELS sur le nouveau moteur (bons chiffres, cf. chaque
#     bloc), elle ne les a pas ré-arbitrés. Refaire les courbes t_forward(batch)
#     sur ROCm0 avant de conclure quoi que ce soit de neuf sur ces seuils.
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
# et pour --cleanup, alimenté par les appels download_hf / download_hf_shards
# ci-dessous. Tout
# fichier qui cesse d'être déclaré devient un orphelin supprimable.
# (retiré le 18/09/2026 avec le passage à la tête MTP « shared » de
#  Qwen3.8-Flash-Next : le sidecar AUTONOME
#  ~/models/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-Q8_0.gguf (4,1 Go) et
#  sa copie renommée mtp-Qwen3.8-Flash-Next-strix-Q8_0.gguf (4,1 Go), tous deux
#  nécessaires au seul commit 0007bc6 du fork. ORPHELINS, mais --cleanup NE LES
#  PURGERA PAS : MTP/ est un sous-dossier protégé en bloc, et la tête « shared »
#  y est déclarée. À retirer à la main si la place manque)
# (retiré le 13/09/2026 car plus utilisé : qwopus3.6-27b-coder-mtp (ses mesures
#  restent dans logs/)
#  → ./setup-llm.sh --cleanup les purge)
# (qwen3.5-2b : revenu le 12/09/2026 comme estimateur de speculative prefill du
#  27B thinking (jamais servi, sans section ini), retiré à nouveau le
#  13/09/2026 (spec-prefill abandonné) — à purger par --cleanup)
# (retiré le 15/09/2026 avec les variantes -parallel : le GGUF SANS tête MTP du
#  9b, ~/models/qwen3.5-9b/Qwen3.5-9B-UD-Q6_K_XL.gguf (8,2 Go), plus déclaré par
#  aucun download_hf depuis que qwen3.5-9b-parallel a disparu : la section
#  qwen3.5-9b sert le GGUF MTP du dossier qwen3.5-9b-mtp/, homonyme mais
#  distinct. Le fichier devient donc ORPHELIN
#  → ./setup-llm.sh --cleanup le purgera (non lancé). lfm2.5-2.6b-parallel, elle,
#  partageait le GGUF de la section principale : rien d'orphelin de ce côté)
# (retiré le 15/09/2026 avec la section qwen3.5-9b, remplacée par
#  ornith-1.5-9b-mtp-nothink : le GGUF MTP unsloth du 9b Qwen,
#  ~/models/qwen3.5-9b-mtp/Qwen3.5-9B-UD-Q6_K_XL.gguf (8,4 Go), plus déclaré par
#  aucun download_hf. Le dossier devient ORPHELIN
#  → ./setup-llm.sh --cleanup le purgera (non lancé). Commentaire métier,
#  mesures et corps ini : docs/HISTORIQUE.md, « qwen3.5-9b remplacé par
#  Ornith-1.5-9B (15/09/2026) »)
# (retiré le 15/09/2026 avec la section laguna-s-2.1, jugée non utile dans
#  l'usage réel : les 3 shards UD-Q4_K_XL (73,4 Go) et le drafter DFlash
#  poolside BF16 (2,2 Go) de ~/models/laguna-s-2.1/, plus déclarés par aucun
#  download_hf. Le dossier entier devient ORPHELIN
#  → ./setup-llm.sh --cleanup le purgera (non lancé). Commentaire métier et
#  mesures : docs/HISTORIQUE.md, « Laguna-S-2.1 retiré (15/09/2026) »)
# (retiré le 16/09/2026 avec la section gpt-oss, jugée non utile dans l'usage
#  réel : les 2 shards UD-Q4_K_XL (59 Go) de ~/models/gpt-oss/UD-Q4_K_XL/, plus
#  déclarés par aucun download_hf. Le dossier entier devient ORPHELIN, avec les
#  sous-dossiers dflash-src/ et target-meta/ du drafter DFlash, jamais déclarés
#  (le GGUF converti, lui, est déjà tombé au --cleanup du 15/09 au soir)
#  → ./setup-llm.sh --cleanup purgera les shards (non lancé) ; les sous-dossiers
#  non vides survivent au balayage, à retirer à la main.
#  ~/llm/venv-convert (hors ~/models) n'est pas concerné. Commentaire métier,
#  mesures et corps ini : docs/HISTORIQUE.md, « gpt-oss retiré (16/09/2026) »)
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

# (derive_gguf, qui déclarait un GGUF calculé en local par un script du dépôt,
#  a été retiré le 18/09/2026 avec son seul usage : la copie renommée du
#  sidecar MTP de Qwen3.8-Flash-Next, nécessaire au seul commit 0007bc6 du fork.
#  Le moteur de l'image lit la tête « shared » telle quelle. _derive
#  (lib/common.sh), le cas "derive" de cmd_setup et tools/mtp-rename-hc-head.py
#  sont partis avec ; tout est dans l'historique git si le besoin revient.)

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
#   ornith-1.5-9b-mtp-nothink = tâches auxiliaires et édition de code courte,
#   ornith-1.5-35b-a3b-parallel = default agentic
#   (opencode & co)
# =============================================================================

# GGUF fusionné (trunk officiel ornith-ai + tête MTP distillée par protoLabsAI),
# repo tiers protoLabsAI/Ornith-1.5-9B-MTP-GGUF, un seul fichier Q8_0 de 9,79 Go.
# Le repo OFFICIEL ornith-ai n'a PAS de tête MTP (les poids nextn ne sont pas
# publiés), il n'y a pas de repo unsloth pour Ornith 1.5 et pas de drafter
# DFlash / DSpark pour ce 9B : ce GGUF tiers est la seule façon de spéculer ici,
# d'où le repo hors unsloth/ornith-ai, seul cas du parc avec le DFlash 2 z-lab
# du 27B.
# Métadonnées (15/09/2026, 442 tenseurs) : arch llama.cpp qwen35 (GDN, même
# famille que le Qwen3.5-9B remplacé), tenseurs blk.32.nextn.* : tête MTP
# EMBARQUÉE dans le fichier principal, donc spec-type = draft-mtp sans sidecar
# ni spec-draft-model. Contexte natif 262144.
# Device : ROCm0, comme tout le parc depuis le 18/09/2026 (device unique de
# l'image, cf. en-tête). Jusque-là la section héritait du défaut Vulkan0 sans
# qu'aucun --bench-devices ait tourné sur elle, le fork ne construisant que
# Vulkan.
download_hf ornith-1.5-9b "protoLabsAI/Ornith-1.5-9B-MTP-GGUF" \
  ORNITH15_9B_MTP_PATH="Ornith-1.5-9B-MTP-Q8_0.gguf"

# Ornith-1.5-9B nothink + tête MTP tierce : petit modèle du parc, tâches
#   auxiliaires (résumés, titres, routage) ET édition de code courte.
# REMPLACE la section qwen3.5-9b le 15/09/2026 (même créneau, même arch qwen35,
#   même dossier de rôle). Pourquoi : à quantité de VRAM comparable (9,79 Go en
#   Q8_0 contre 8,4 Go en UD-Q6_K_XL) le modèle est meilleur sur tout ce qu'on
#   lui demande, chiffres de l'éditeur contre Qwen3.5-9B : Terminal-Bench 2.1
#   (harnais Claude Code) 47,0 contre 18,9, SWE-bench Verified 70,6 contre 53,2,
#   NL2Repo 32,4 contre 16,2, GPQA 86,4 contre 81,7. Le débit, lui, est du même
#   ordre (test isolé du même jour, mêmes prompts : 44,7 / 52,9 t/s contre
#   42,4 / 61,8 pour le 9b Qwen, quants différentes) : le remplacement se joue
#   sur la qualité, pas sur la vitesse. Commentaire métier,
#   mesures et corps ini de la section retirée : docs/HISTORIQUE.md,
#   « qwen3.5-9b remplacé par Ornith-1.5-9B (15/09/2026) ». Le GGUF du 9b Qwen
#   (~/models/qwen3.5-9b-mtp/, 8,4 Go) devient ORPHELIN, --cleanup le purgera.
# Fiche (model card HF ornith-ai + protoLabsAI, pas de guide unsloth) : post-train
#   d'ornith-ai (ex deepreinforce-ai) sur Qwen3.5-9B, publié le 18/08/2026,
#   licence MIT ; le GGUF MTP tiers date du 20/08/2026. Modèle multimodal : le
#   mmproj n'est pas téléchargé, texte seul, et de toute façon le mmproj est le
#   seul interdit dur avec un drafter (cf. en-tête).
# Quant Q8_0 : la seule publiée dans le repo MTP, et elle tient largement
#   (9,79 Go) ; aucune grille de quants à arbitrer ici.
# ctx-size 131072 : la valeur du reste du parc (27B, coder-next, DeepSeek), sous le natif 262144, à parallel 1 le slot unique en dispose en
#   entier. Le qwen3.5-9b remplacé était à 32768 avec n-predict 1024 parce qu'il
#   ne servait QUE des tâches auxiliaires courtes ; ce modèle-ci fait aussi de
#   l'édition de code (Terminal-Bench, SWE-bench), la borne dure de génération
#   est donc retirée et le contexte aligné sur le parc.
# jinja : convention du parc pour un modèle à tool calling (template chat
#   requis). Le cache-type-v q8_0 qui l'accompagnait jusqu'au 18/09/2026 est
#   retiré : le global est passé en f16 sur K et V (cf. en-tête), et c'est en
#   f16 que la campagne du 18/09 a mesuré cette section.
# ⚠ SAMPLING IMPOSÉ par la fiche éditeur, la famille BOUCLE sinon : temp 1.0,
#   top-k 20, top-p 0.95, min-p 0 et surtout presence-penalty 1.5 (le [*] global
#   est à 0.0, d'où la surcharge locale). Ce sont les valeurs utilisées par les
#   tests isolés ci-dessous : les changer invalide ces chiffres.
# ⚠ PIÈGE THINKING, nothink OBLIGATOIRE : thinking ON, les 1200 tokens du test
#   partent en raisonnement sans jamais atteindre </think> (aucune réponse
#   rendue) et l'acceptance tombe à 0,42 contre 0,69 en nothink (test isolé
#   ornith9b-mtp3-think du 15/09/2026). D'où reasoning = off, et le suffixe
#   -nothink du nom de section. (Réglage posé par chat-template-kwargs
#   {"enable_thinking":false} jusqu'au 17/09/2026 : clé obsolète, remplacée
#   par l'option native reasoning de llama-server, présente sur 0007bc6.)
# Test ISOLÉ du 15/09/2026 (tools/spec-isolate.sh, fork strix-0007bc6, Vulkan0,
#   hors service, Q8_0, ctx 32768, np 1, 2 passes, 1200 tokens ; t/s de décode
#   passe 2, spec-test.txt / spec-refactor.txt) :
#     sans spéculation              23,6 / 23,3
#     draft-mtp n-max 2             28,4 / 30,2   (acceptance 0,80 / 0,91)
#     draft-mtp n-max 3             45,3 / 51,3   (acceptance 0,69 / 0,85)
#     draft-mtp n-max 4             29,9 / 33,3   (acceptance 0,58 / 0,76)
#     ngram-map-k 7 min-hits 2
#       + draft-mtp 3               44,7 / 52,9   (acceptance 0,69 / 0,85)
#   Sanité « ok » sur chaque passe, sorties relues.
# n-max 3, et la courbe n'est PAS monotone : 2 et 4 retombent à ~30 t/s quand 3
#   donne 45 à 51, soit x1,9 à x2,2 sur la référence. Signature du découpage
#   mat-vec du fork (issue #50, cf. en-tête) : le batch de vérification vaut
#   n-max + 1, et seul 4 colonnes passe en un bloc ; 3 (n-max 2) et 5 (n-max 4)
#   se découpent en 2+1 et 4+1. Ce n'est donc pas le seuil des 8 colonnes de
#   ggml-vulkan qui commande ici mais le découpage, comme sur le 27B. Si les
#   issues #50 / #51 sont corrigées en amont, re-mesurer 2, 3 et 4.
# parallel 1 : np x (n-max + 1) = 4 colonnes à un slot, le seul batch rapide de
#   ce modèle ; à np 2 on demande 8 colonnes, donc deux découpages 4+4 par
#   forward, et le multi-slot MTP s'était déjà effondré sur le 9b Qwen à des
#   batches pourtant sous le seuil (cf. en-tête). Aucune concurrence n'a jamais
#   été observée sur ce créneau au journal du service. Non mesuré à NP>1,
#   conformément à la règle : sans mesure, parallel 1.
# cache-reuse 0 : contrainte des sections spéculatives, posée explicitement
#   (ignorée de toute façon sur GDN, cf. en-tête) ; swa-full + ctx-checkpoints
#   comme le 9b remplacé, même arch qwen35 : le serveur écrit « swa_full is not
#   supported by this model » et seul ctx-checkpoints travaille (en-tête).
# --fit : la fiche protoLabsAI conseille « --fit off -ngl 99 » parce que la tête
#   MTP fait monter l'estimation mémoire et que le fit peut renvoyer des couches
#   au CPU. RIEN À POSER ICI : --fit n'ajuste que les arguments NON POSÉS et le
#   parc fixe n-gpu-layers = 99 dans les flags globaux [*] (lib/ini.sh), comme
#   pour toutes les autres sections MTP, qui ne posent pas non plus de fit.
#   Vérifié au chargement (aucune couche CPU dans le journal du service).
# n-gram CONFIRMÉ SUR LE SERVICE, --spec-ab du 15/09/2026 (fork strix-0007bc6,
#   Vulkan0, 4 passes, spec-refactor.txt) : base (ngram-map-k 7 min-hits 2 +
#   draft-mtp 3) 52,89 t/s, acceptance 0,847 ; draft-mtp SEUL 50,62 t/s,
#   acceptance 0,840, soit -4,3 %. Le n-gram est donc gardé : il paie sur le
#   cas d'usage visé (édition de code, le oldString se ré-émet mot pour mot),
#   et il ne coûte rien ailleurs (test isolé : 44,7 contre 45,3 t/s sur le
#   prompt générique, dans le bruit).
# Mesuré le 15/09/2026 TEL QUE SERVI (fork strix-0007bc6, Vulkan0, --bench 3
#   passes, première mesure journalisée de cette section) : prefill 827,9 t/s,
#   décode 39,5 t/s, acceptance 0,56. Contre la section qwen3.5-9b remplacée,
#   mesurée le même jour sur le même fork (745 / 32,96 / 0,58) : prefill +11 %,
#   décode +20 %, pour un GGUF plus gros et une quant plus haute. L'écart avec
#   les 52,9 t/s du --spec-ab est normal : bench-task est un prompt générique où
#   les hits n-gram sont rares (acceptance 0,56 contre 0,85 sur spec-refactor).
# --bench-cache, --bench-load et --bench-agentic : non lancés sur cette section
#   au 15/09/2026 (le 9b remplacé donnait 62 / 0 / 64 % de cache sur la même
#   arch qwen35 et le même état récurrent GDN, rien n'indique un écart).
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac : image ROCm de runtime/, moteur 8c1c282, runtime
#   pwilkin/rocm-systems 7dda3ac ; ROCm0, fit off, load-mode none, cache K et V
#   f16, llama-server lancé HORS DÉPÔT par un script de test, prompt court
#   d'environ 1 400 tokens et 1 000 générés, médianes de 3 passes) :
#   prefill 1468 t/s, décode 49,8 t/s, réglage spéculatif inchangé.
#   Contre la même section sur le fork 0007bc6 Vulkan0 (828 / 39,5) : prefill
#   +77 %, décode +26 %. Prefill en profondeur (2k / 8k / 25k / 51k) : 1355 /
#   1460 / 1294 / 1080 t/s, justesse vérifiée par comptage de lignes.
#   ⚠ Ces chiffres ne viennent PAS de --bench : ne pas les mélanger aux lignes
#   de logs/bench.log, ils seront rejoués par le dépôt après la bascule.

llama_model ornith-1.5-9b-mtp-nothink "
model                = $ORNITH15_9B_MTP_PATH
ctx-size             = 131072
cache-ram            = 4096
temp                 = 1.0
top-k                = 20
top-p                = 0.95
min-p                = 0.0
presence-penalty     = 1.5
reasoning            = off
jinja                = true
parallel             = 1
cache-reuse          = 0
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 3
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
swa-full             = true
ctx-checkpoints      = 128"

download_hf ornith-1.5-35b-a3b "ornith-ai/Ornith-1.5-35B-A3B-GGUF" \
  ORNITH15_35B_A3B_PATH="Ornith-1.5-35B-Q4_K_M.gguf"

# Ornith-1.5-35B-A3B nothink, parallel 4 : DEFAULT AGENTIC, chargé à la demande
# NOM DE SECTION : `-parallel` depuis le 15/09/2026 (la section s'appelait
#   `ornith-1.5-35b-a3b` tout court jusque-là, cf. docs/HISTORIQUE.md et les
#   mesures antérieures). Le suffixe dit ce que la section SERT, comme `-mtp`
#   et `-dflash-nothink` ailleurs dans ce fichier : ici la variante parallel 4
#   SANS spéculation, réservée à la concurrence (x1,93 en salves, x2,33 à trois
#   boucles agentic simultanées, mesurés le 15/09/2026) ; la variante solo est
#   `ornith-1.5-35b-a3b-mtp`, déclarée juste en dessous. Aucun autre nom ne
#   bouge : le DOSSIER de GGUF reste ~/models/ornith-1.5-35b-a3b/ et la
#   variable reste $ORNITH15_35B_A3B_PATH.
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
#   concurrent (section ornith-1.5-35b-a3b-parallel), ornith-1.5-35b-a3b-mtp
#   (déclarée juste en dessous) pour
#   l'usage mono-utilisateur.
# Quant Q4_K_M (21,7 Go) : choix du 28/08/2026, c'est la quant de la commande
#   de référence de la fiche ; pas de quant unsloth UD sur ce repo
#   (grille : Q4_K_M 21,7 / Q5_K_M 25,3 / Q6_K 29,2 / Q8_0 37,8 Go).
# Sampling : reco officielle temp 0.6 / top-p 0.95 / top-k 20 (la fiche donne
#   temp 1.0 pour les benchs seulement). Thinking par défaut ; nothink par
#   reasoning = off depuis le 17/09/2026, option native de llama-server
#   (présente sur 0007bc6), qui ferme le canal et ne renvoie rien dans
#   reasoning_content. Elle remplace chat-template-kwargs
#   {"enable_thinking":false}, obsolète (le template émettait
#   <think>\n\n</think>).
# ctx 1048576 : llama-server partage ctx-size entre les slots, 4 x 262144 =
#   le contexte natif entier pour chaque requête (au-delà : YaRN facteur 4,
#   non activé).
# parallel 4 : subagents des clients agentic (omp, opencode) sans
#   sérialisation. --bench-parallel 28/08/2026 : 4 requêtes = 136,8 t/s
#   agrégés (x1,93), 35,0 t/s par requête (le Qwen3.6 faisait x1,43 à 2).
#   Confirmé le 15/09/2026 sur le fork (138 t/s agrégés à 4 requêtes), et
#   c'est le meilleur réglage servi du parc en concurrence réelle : aucune
#   variante spéculative n'en approche à np 4 (cf. ci-dessus).
# ⚠ SECTION NON MESURÉE SUR LE MOTEUR CONTENEURISÉ, À QUALIFIER. La campagne
#   du 17 au 18/09/2026 n'a pas joué le parallel 4 : tous ses réglages sont
#   ceux du fork Vulkan, gardés tels quels faute de mesure. Ce qui change quand
#   même, parce que c'est global : device ROCm0, fit off, load-mode none.
#   Le cache-type-v = q8_0 du corps est GARDÉ pour la même raison (le reste du
#   parc est passé au f16 global sur mesure, pas celui-ci) : c'est la seule
#   valeur de cache quantifiée qui subsiste dans ce fichier. À trancher à la
#   bascule, avec --bench-parallel.
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image, cf. en-tête).
#   HISTORIQUE, --bench-devices 28/08/2026 (b10566, ROCm SYSTÈME, 3 passes) :
#   Vulkan0 976 pp / 70,9 tg contre ROCm0 931 / 57,6, justesse OK sur les deux,
#   tour simulé 44 s contre 54 ; c'est ce qui avait retenu Vulkan0. Le ROCm de
#   l'image n'a rien à voir avec celui-là (runtime retained-PM4), la question
#   est rouverte et sans objet à la fois : il n'y a plus qu'un device.
#   --bench (bench-task) : 974 pp / 70,7 tg. --bench-cache :
#   62 % au tour suivant, 64 % à l'identique, 0 % après édition (GDN, cf.
#   en-tête). Sortie contrôlée à la main : réponse lisible, pas de warning.
#   --bench-agentic 28/08/2026 (pi 0.84.3, 3 passes) : 16/16, décode 71 t/s
#   en boucle d'outils, cache 89 à 98 % en continuation (72 % sur un run à
#   65 k tokens cumulés, trois tours de correction).
# cache-type-v q8_0 : posé du temps du global q8_0 / q4_0 (le V q4_0 dégradait
#   le tool calling). Gardé tel quel faute de mesure sur ce moteur, cf. l'avis
#   « section non mesurée » ci-dessus.
# cache-reuse 0 : ignoré sur GDN (état récurrent) — la restauration de
#   préfixe passe par cache-ram + ctx-checkpoints, au dernier checkpoint
#   seulement (cf. en-tête, 62 % au tour suivant sur cette arch).
# jinja : template chat requis pour le tool calling XML (<function=...>).
# Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
#   1129 t/s, décode 73,3 t/s : prefill +16 %, décode +4 % (sans spéculation
#   des deux côtés).
llama_model ornith-1.5-35b-a3b-parallel "
model                = $ORNITH15_35B_A3B_PATH
ctx-size             = 1048576
cache-ram            = 12288
reasoning            = off
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

groupe "; --- Variante MTP du même GGUF Ornith (mono-utilisateur, un seul slot) ; la section de concurrence est ornith-1.5-35b-a3b-parallel ci-dessus ---"

# Ornith-1.5-35B-A3B nothink, VARIANTE MTP — même GGUF que la section
#   ci-dessus (Ornith-1.5-35B-Q4_K_M.gguf, tête MTP embarquée blk.40.nextn,
#   cf. le commentaire de la section de base), servi à un seul slot avec
#   spéculation. Créée le 15/09/2026 à l'issue de la campagne multi-slot.
#   Nommée `-mtp` par la convention de _preload_sanity (lib/preload.sh) : les
#   deux sections partagent la ligne `model =`, le garde-fou avertit si elles
#   sont préchargées ensemble (~22 Go chargés deux fois). Précédent du parc :
#   qwen3.8-27b / qwen3.8-27b-dflash-nothink sur un GGUF unique.
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
#   jinja, swa-full, ctx-checkpoints) : à ne changer qu'en même temps que
#   là-bas. SAUF le cache KV : cette section-ci a été mesurée sur le moteur
#   conteneurisé en f16 sur K et V (cf. plus bas) et n'a plus de
#   cache-type-v = q8_0, quand la section de base le garde faute de mesure.
# --bench du 15/09/2026 tel que servi (fork strix-0007bc6, Vulkan0, 3 passes,
#   première mesure journalisée de cette section) : prefill 1073 t/s, décode
#   76,2 t/s, acceptance 0,55, contre 1129 / 73,3 pour la section de base le
#   13/09 sur le même fork (parallel 4, sans spéculation) : décode +4 %,
#   prefill -5 %. L'écart avec les +24 % du test isolé est normal, bench-task
#   génère sans répétition et les hits n-gram y sont rares (acceptance 0,55
#   contre 0,83 sur spec-refactor).
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac, ROCm0, fit off, load-mode none, cache K et V f16,
#   script de test HORS DÉPÔT, prompt court d'environ 1 400 tokens et 1 000
#   générés, médianes de 3 passes ; réglage spéculatif inchangé, swa-full,
#   ctx-checkpoints 128) : prefill 1673 t/s, décode 82,4 t/s. Contre la même
#   section sur le fork 0007bc6 Vulkan0 (1073 / 76,2) : prefill +56 %, décode
#   +8 %. Prefill en profondeur (2k / 8k / 25k / 51k) : 1703 / 1700 / 1429 /
#   1145 t/s, justesse vérifiée par comptage de lignes.
#   ⚠ Ces chiffres ne viennent PAS de --bench (script de test hors dépôt) : à
#   rejouer par le dépôt après la bascule, ne pas les mélanger à bench.log.
#   ⚠ CONTEXTE : la campagne a tourné à ctx-size 262144, pas aux 1048576 de
#   production ci-dessous. Le contexte N'EST PAS changé (on ne le touche pas
#   sans mesure), mais 1048576 en cache f16 n'a PAS été vérifié sur ce moteur :
#   à contrôler à la bascule (chargement, mémoire résidente, décode), le f16
#   pesant deux fois le q8_0 par token de KV.
llama_model ornith-1.5-35b-a3b-mtp "
model                = $ORNITH15_35B_A3B_PATH
ctx-size             = 1048576
cache-ram            = 12288
reasoning            = off
temp                 = 0.6
top-k                = 20
top-p                = 0.95
min-p                = 0.0
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

# Drafter DSpark officiel Liquid AI (Q8_0, 356 491 776 octets), déclaré dans le
# MÊME dossier que la cible : même façon de faire que le sidecar DSpark de
# deepseek-v4-flash ou le DFlash 2 de qwen3.8-27b. Le GGUF devient nécessaire
# au démarrage de la section principale : ne pas le retirer du dossier.
# Métadonnées lues le 15/09/2026 : general.architecture = dflash, dorsale Qwen3
# de 5 blocs, block_size 9, target_layers [3,10,18,22,28], tête de Markov rang
# 256 et tête de confiance (conf_proj) ; embeddings et tête LM empruntés à la
# cible, donc même device qu'elle, jamais de spec-draft-device.
# Le TODO « Qwen3-style backbones » du loader du fork porte sur la dorsale DU
# DRAFTER (Qwen3 ici), pas sur la cible : le couple charge sans contournement.
# n-max : le README du repo annonce 10, le fork clampe à block_size = 9.
download_hf lfm2.5-2.6b "LiquidAI/LFM2.5-2.6B-DSpark-GGUF" \
  LFM25_DSPARK_PATH="LFM2.5-2.6B-DSpark-Q8_0.gguf"

# LFM2.5-2.6B — agentic edge Liquid AI : tool calling, instruction following,
#   multi-step. Compétitif avec des modèles 4x plus gros sur le tool use
#   (BFCLv4, ToolSandbox) — coding : rester sur les gros, c'est sa faiblesse.
# Depuis le 15/09/2026 cette section sert la version SPÉCULÉE (drafter DSpark
#   officiel, parallel 1). Le réglage multi-slot qui était ici (4 slots, sans
#   drafter) a d'abord été gardé en variante lfm2.5-2.6b-parallel le même jour,
#   puis RETIRÉ le soir même : aucune concurrence n'a jamais été observée sur ce
#   modèle au journal du service, et le drafter gagne en solo. Décision
#   utilisateur : pas de parallel si perte de perf (mesures et détail de la
#   variante dans docs/HISTORIQUE.md, « Variantes -parallel retirées »).
# Sampling : reco llama.cpp officielle du model card GGUF (temp 0.1, top-k 50,
#   repeat-penalty 1.1). Le blog transformers donne temp 0.2 / rep 1.05 —
#   on suit la reco llama.cpp, plus déterministe, cohérente pour du tool calling.
# ctx 131072 : fenêtre native 128K (mid-training LFM2.5) ; à parallel 1 le slot
#   unique en dispose en entier (contre 32768 par slot du temps des 4 slots).
# cache KV f16 : hérité du global depuis le 18/09/2026 (cf. en-tête). Les deux
#   lignes cache-type-k/v = f16 du corps sont retirées, elles ne faisaient plus
#   que répéter le global. Raison inchangée : arch hybride conv récurrente +
#   GQA (lfm2), KV minuscule sur 2.6B, chemin quantifié jamais validé ici.
# cache-reuse 0 : état récurrent (conv) : même logique que GDN, non supporté ;
#   c'est aussi la contrainte des sections spéculatives.
# Pas de swa-full ni ctx-checkpoints : pas une arch hybride SWA Qwen.
# jinja : template chat requis pour le tool calling.
# Spéculation DSpark, test isolé du 15/09/2026 (fork strix-0007bc6, Vulkan0,
#   hors service, np 1, 2 passes, 1200 tokens, spec-test.txt et
#   spec-refactor.txt) : sans spéculation 69,6 t/s ; draft-dspark n-max 3 =
#   122,3 (acceptance 0,39 à 0,83 selon le prompt), n-max 5 = 110,2, n-max 9 =
#   124,6 (acceptance 0,19 à 0,69). RETENU n-max 3 : même débit que 9 au bruit
#   près, acceptance bien plus haute, et batch de vérification de 4 colonnes,
#   loin sous les 8 de ggml-vulkan (cf. en-tête). Soit x1,76 sur le réglage
#   sans spéculation. Pas de n-gram ici : mesure non faite, le modèle sert du
#   tool calling court plutôt que du refactor.
# Mémoire : ~9 Go résidents chargé (poids 2,7 + drafter 0,36 + KV du ctx
#   131072 d'un seul slot), à garder en tête avec le LRU de --models-max.
# parallel 1 : DSpark multi-slot n'a PAS été mesuré sur ce modèle. Ce qui est
#   mesuré ailleurs au 15/09/2026 : le MTP multi-slot du 9b s'effondre (18,2
#   t/s agrégés à np 4 contre 80,8 sans spéculation, cf. son bloc) et aucun
#   modèle spéculatif du parc ne gagne au multi-slot sauf deepseek-v4-flash à
#   np 2, où le batch de vérification tombe pile sur les 8 colonnes du seuil.
#   Ici np 2 donne 8 colonnes (2 x (3 + 1)), mesuré le 15/09/2026 au soir
#   par tools/spec-isolate.sh NP=2 (400 tokens, 2 salves) : solo 105 à 124
#   t/s, deux requêtes simultanées 120 à 136 t/s agrégés, soit ~x1,1 pour un
#   débit par requête divisé par deux (70 t/s). Comme DeepSeek à np 2 : le
#   seuil est respecté mais le gain ne vaut pas la latence, parallel 1 gardé.
# Préchargement : preload.conf est indexé par NOM DE SECTION, donc la ligne
#   `lfm2.5-2.6b` existante précharge désormais CETTE version (drafter DSpark
#   compris, ~9 Go au lieu de ~2,7).
# Mesuré le 15/09/2026 TEL QUE SERVI (fork strix-0007bc6, Vulkan0, --bench 3
#   passes) : prefill 2875 t/s, décode 108,8 t/s, acceptance 0,50. Contre le
#   réglage sans drafter re-mesuré le même jour sous la variante -parallel
#   depuis retirée (3602 / 68,2) : décode +59 %, prefill -20 %, le drafter DSpark décodant
#   aussi le prompt (même effet que sur deepseek-v4-flash et qwen3-coder-next).
#   Le comparateur de --bench annonce « RÉGRESSION » sur le prefill (3651 le
#   13/09 -> 2875) : il compare par nom de section et ignore que le réglage a
#   changé ; la variante retrouve 3602 le même jour, donc l'écart vient du
#   drafter, pas de la plateforme. Le x1,76 du test isolé devient x1,59 ici :
#   le prompt de --bench est générique, celui du test isolé plus favorable.
# --bench-load du 15/09/2026 (section préchargée, drafter compris) : 0,4 s de
#   chargement + 1er token, TTFT à chaud 27 ms : le drafter de 0,36 Go ne coûte
#   rien de visible (0,5 s / 27 ms au 21/08 sans lui).
# Mesuré 21/08/2026 (Vulkan0, b10433) et 13/09/2026 (fork) sans spéculation
#   (réglage à 4 slots, retiré le 15/09/2026) : prefill 2279 puis 3048 t/s,
#   décode 67,7 puis 70,8 t/s. Ces deux colonnes paquet restent dans
#   docs/perfs.tsv sur la ligne lfm2.5-2.6b, avec la mention « paquet sans
#   drafter », pour garder la comparaison paquet contre fork sur ce modèle ;
#   le reste est dans docs/HISTORIQUE.md.
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac, ROCm0, fit off, load-mode none, cache K et V f16,
#   script de test HORS DÉPÔT, prompt court d'environ 1 400 tokens et 1 000
#   générés, médianes de 3 passes ; Q8_0, draft-dspark n-max 3, reasoning auto) :
#   prefill 4187 t/s, décode 138,5 t/s. Contre la même section sur le fork
#   0007bc6 Vulkan0 (2875 / 108,8) : prefill +46 %, décode +27 %. Prefill en
#   profondeur (2k / 8k / 25k / 51k) : 4399 / 4181 / 3695 / 2954 t/s.
#   Justesse : texte cohérent, mais 3 comptages de lignes justes sur 4 (251 au
#   lieu de 260 sur un prompt). Probable limite du modèle plutôt que du moteur
#   (c'est le plus petit du parc et le seul à se tromper), comparaison en cours
#   au 18/09/2026 : à confirmer par --bench-sanity à la bascule.
#   ⚠ Ces chiffres ne viennent PAS de --bench : à rejouer par le dépôt.
llama_model lfm2.5-2.6b "
model            = $LFM25_26B_PATH
ctx-size         = 131072
cache-ram        = 2048
temp             = 0.1
top-k            = 50
min-p            = 0.0
repeat-penalty   = 1.1
cache-reuse      = 0
spec-type        = draft-dspark
spec-draft-model = $LFM25_DSPARK_PATH
spec-draft-n-max = 3
jinja            = true
parallel         = 1"

groupe "; --- LFM2.5 8B-A1B (Liquid AI — MoE 8,3B / 1,5B actifs, agentic edge) ---"

# LFM2.5-8B-A1B (Liquid AI, sorti le 24/08/2026) — MoE hybride conv récurrente
# + GQA (arch lfm2moe, 24 couches : 18 conv double-gate + 6 GQA), 8,3B total /
# 1,5B actifs, ctx natif 128K, vocab 128 000. Grand frère du 2.6B ci-dessus :
# Liquid annonce +11,5 points de MMLU-Pro et un net progrès en code, mais le
# 2.6B reste devant sur le tool use pur (BFCLv4, IFEval) — les deux sections
# cohabitent tant que la boucle agentic (étape 7) n'a pas tranché.
# Q8_0 officiel LiquidAI (9 010 195 680 octets) : petit modèle, même logique
# que le 2.6B, aucune raison de descendre ; pas de quant unsloth UD ni de
# guide unsloth pour cette variante au 16/09/2026 (le guide LFM2.5 ne couvre
# que les 1.2B). Support lfm2moe mainline depuis mai 2026, présent dans le
# fork strix-0007bc6 (vérifié le 16/09/2026, src/llama-arch.cpp:128).
download_hf lfm2.5-8b-a1b "LiquidAI/LFM2.5-8B-A1B-GGUF" \
  LFM25_8B_PATH="LFM2.5-8B-A1B-Q8_0.gguf"

# Drafter DSpark officiel Liquid AI (Q8_0, 356 491 104 octets ; F16 664 Mo
# annoncé +2 % d'acceptance, à essayer par --spec-ab si le Q8_0 déçoit),
# déclaré dans le MÊME dossier que la cible, comme pour le 2.6B. Sidecar pur
# (5 couches d'attention, tête de Markov rang 256, tête de confiance, block
# size 9) : embeddings et tête LM empruntés à la cible, donc même device
# qu'elle, jamais de spec-draft-device. Le support DSpark pour LFM2 est une
# PR distincte du DSpark générique (mainline #27383, commit 07822bdd, présent
# dans le fork strix-0007bc6, vérifié le 16/09/2026). Le GGUF devient
# nécessaire au démarrage de la section : ne pas le retirer du dossier.
# n-max : le README du repo dit 10, le fork clampe à block_size = 9.
download_hf lfm2.5-8b-a1b "LiquidAI/LFM2.5-8B-A1B-DSpark-GGUF" \
  LFM25_8B_DSPARK_PATH="LFM2.5-8B-A1B-DSpark-Q8_0.gguf"

# LFM2.5-8B-A1B nothink — ajouté le 16/09/2026, étapes 1 à 6 de la skill
#   ajout-modele faites le jour même (chiffres ci-dessous), étape 7
#   (--bench-agentic) en bas de bloc.
# Sampling : reco officielle de la model card 8B-A1B (temp 0.2, top-k 80,
#   repeat-penalty 1.05), différente de celle du 2.6B (0.1 / 50 / 1.1) : la
#   fiche du 8B ne donne ni top-p ni min-p, min-p 0 explicite.
# Thinking COUPÉ (suffixe -nothink) : modèle « reasoning-tuned », il ouvre
#   <think> de lui-même et le template n'a aucun interrupteur (ni
#   enable_thinking ni reasoning_effort ; seul preserve_thinking, qui ne
#   concerne que la relecture de l'historique). Test isolé du 16/09/2026 : en
#   1200 tokens il n'avait pas fini de raisonner, contenu VIDE sur les deux
#   prompts. `reasoning-budget 0` seul est inerte sur le fork : le mécanisme
#   n'y vit que derrière reasoning-budget-enable (common/sampling.cpp:313).
#   Avec reasoning-budget-enable + budget 0 la balise se ferme d'office et la
#   réponse part au premier token (contenu ligne 2 du gen). ⚠ Clé propre au
#   fork (FORK_ONLY_KEYS, cf. deepseek-v4-flash) : le parc était déjà
#   verrouillé sur le fork par deepseek-v4-flash et qwen3.8-flash-next.
#   Sur le paquet Arch de secours, l'équivalent serait reasoning-budget 0 seul
#   (mainline) : non mesuré.
# ctx 131072 : fenêtre native 128K, un seul slot en dispose en entier.
# cache KV f16 : hérité du global depuis le 18/09/2026 (cf. en-tête), les deux
#   lignes du corps qui le répétaient sont retirées. Raison inchangée : arch
#   hybride conv + GQA, KV minuscule, chemin quantifié non validé sur lfm2
#   (même prudence que le 2.6B).
# cache-reuse 0 : état récurrent (conv) et contrainte des sections spéculatives.
# Pas de swa-full ni ctx-checkpoints : pas une arch hybride SWA Qwen.
# Spéculation DSpark, test isolé du 16/09/2026 (fork strix-0007bc6, Vulkan0,
#   hors service, np 1, 2 passes, 1200 tokens, médiane hors 1re passe,
#   spec-test.txt / spec-refactor.txt, thinking coupé) :
#     sans spéculation      102,2 / 102,9 t/s
#     draft-dspark n-max 3  118,0 / 133,4  (acceptance 0,66 / 0,82)
#     draft-dspark n-max 5  114,0 / 128,4  (0,60 / 0,72)
#     draft-dspark n-max 9   82,0 / 117,3  (0,36 / 0,56)
#   RETENU n-max 3 : x1,16 en générique, x1,30 en refactor, batch de
#   vérification de 4 colonnes. Gain plus faible que sur le 2.6B (x1,76) :
#   1,5B actifs sur 9 Go de poids, le décode est déjà limité par la lecture
#   des experts routés, et le batch en lit davantage. Le même test AVEC
#   raisonnement (avant le budget 0) donnait 100,9 / 109,6 en n-max 3 contre
#   107,3 / 100,3 sans spéculation, acceptance 0,53 / 0,62 : le drafter
#   devine bien mieux la réponse que la pensée.
#   n-gram AJOUTÉ (contrairement au 2.6B) : le 8B vise aussi l'édition de code,
#   où le prompt se ré-émet. --spec-ngram-tune n'a pas été utilisé : sur un
#   modèle sans tête MTP il prend « sans spéculation » pour référence, ce qui
#   n'a pas de sens avec un drafter externe ; réglé par --spec-ab tel que
#   servi, le 16/09/2026 (strix-0007bc6, Vulkan0, 4 passes, décode médian) :
#     spec-refactor.txt : none 106,0 ; draft-dspark seul 126,6 (acc. 0,78) ;
#       ngram 7 + dspark 146,2 (0,78) ; ngram 15 = 144,2 (0,70) ;
#       ngram 47 = 169,6 (0,61)
#     spec-test.txt : draft-dspark seul 120,3 (0,71) ; ngram 7 = 118,3 (0,68)
#   RETENU size-m 47, min-hits 2 : +34 % contre le drafter seul et +60 % contre
#   rien sur le refactor, neutre en générique (les hits y sont rares, un miss
#   ne coûte qu'une sonde de hash). Même régime large que le 27B dense : la
#   pente MoE sous la marche n'a pas empêché le 47 de gagner ici, parce que
#   1,5B actifs font un forward court même à 48 colonnes.
# parallel 1 : np 2 x (3 + 1) = 8 colonnes, pile au seuil, mais le 2.6B y a
#   mesuré ~x1,1 agrégé pour une latence doublée : pas mesuré ici, 1 gardé.
# ⚠ SECTION NON MESURÉE SUR LE MOTEUR CONTENEURISÉ, À QUALIFIER. Avec
#   ornith-1.5-35b-a3b-parallel, c'est l'une des deux sections que la campagne
#   du 17 au 18/09/2026 n'a pas jouées : tous les réglages ci-dessous sont ceux
#   du fork Vulkan, gardés tels quels faute de mesure. Ne changent que les
#   réglages globaux : device ROCm0, fit off, load-mode none, cache K et V f16
#   (elle était déjà en f16, cf. ci-dessus : rien ne bouge en pratique).
#   À la bascule : tools/qualif-modele.sh, en commençant par --bench-sanity.
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image). Jusque-là
#   Vulkan0 hérité du défaut, --bench-devices n'ayant jamais tourné ici (le
#   fork n'exposait que Vulkan0) ; la sanité de la sortie avait été lue au test
#   isolé (sanité ok sur toutes les passes).
# Mesuré le 16/09/2026 TEL QUE SERVI (fork strix-0007bc6, Vulkan0, --bench 3
#   passes, bench-task) : prefill 3079 t/s, décode 108,1 t/s, acceptance 0,55.
#   Même débit que le 2.6B (2875 / 108,8) pour un modèle trois fois plus gros
#   et bien meilleur en code selon Liquid : c'est l'argument de cette section.
#   Jamais mesuré au paquet Arch.
# --bench-cache du 16/09/2026 : suite 63 % servi du cache (220 ms), identique
#   64 %, édition 0 % : arch à état récurrent (conv), restauration au dernier
#   checkpoint comme le 2.6B et les GDN.
# --bench-load du 16/09/2026 : 1,7 s chargement + 1er token (8,4 Go lus),
#   TTFT à chaud 31 ms.
# Mémoire : ~16 Go chargé (poids 9 + drafter 0,36 + KV du ctx 131072).
# --bench-agentic du 16/09/2026 (pi 0.84.3, strix-0007bc6) : ÉCHEC. Passe 1 :
#   simple 0/1 (23 tokens, réponse hors sujet), outils 1/1 (1,9 s, 89 t/s),
#   edit 1/1 (4,0 s, 103 t/s), création 0/1 (les fichiers sont écrits mais le
#   test n'est pas relancé jusqu'au vert), bug sans toucher au test : BOUCLE
#   sans fin (36 min, 18 700 requêtes de 20 à 50 tokens, contexte à 47k,
#   conteneur tué à la main ; le bench n'a pas de limite de tours). Verdict :
#   le modèle tient les tool calls simples mais pas une boucle de correction,
#   comme Liquid l'annonce (« moins adapté au code lourd »). Section GARDÉE
#   pour l'instant avec ce verdict : à retirer si elle ne sert pas dans l'usage
#   réel (même critère que laguna et gpt-oss), ou à re-mesurer avec le
#   raisonnement rétabli (reasoning-budget N > 0) si on veut lui donner sa
#   chance en agentic, au prix du débit.
llama_model lfm2.5-8b-a1b-nothink "
model            = $LFM25_8B_PATH
ctx-size         = 131072
cache-ram        = 2048
temp             = 0.2
top-k            = 80
min-p            = 0.0
repeat-penalty   = 1.05
cache-reuse      = 0
spec-type        = ngram-map-k,draft-dspark
spec-draft-model = $LFM25_8B_DSPARK_PATH
spec-draft-n-max = 3
spec-ngram-map-k-size-m   = 47
spec-ngram-map-k-min-hits = 2
reasoning-budget-enable = true
reasoning-budget = 0
jinja            = true
parallel         = 1"

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
# cache KV f16 : hérité du global depuis le 18/09/2026 (cf. en-tête). La ligne
#   cache-type-v = q8_0 du corps (précision V critique pour les diffs de code,
#   du temps du global q4_0) est retirée : c'est en f16 sur K et V que la
#   campagne du 18/09 a mesuré cette section, et le f16 est plus précis que le
#   q8_0, pas moins.
# cache-reuse 0 : ignoré sur l'état récurrent GDN (cf. en-tête) ; la
#   restauration de préfixe passe par cache-ram + ctx-checkpoints, au dernier
#   checkpoint seulement (65 % au tour suivant sur le fork, 64 au paquet).
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image, cf. en-tête).
#   HISTORIQUE, --bench-devices 21/08/2026 (b10433, ROCm SYSTÈME) : Vulkan0
#   prefill 470 t/s, décode 46,7 t/s, et ROCm0 INUTILISABLE sur cette arch avec
#   ce build, qui répondait « LAMPAMPAMPAMP… » à la recopie de contrôle (exclu
#   par --bench-sanity avant toute mesure) : deuxième arch MoE à opérateurs
#   fusionnés cassée sur le ROCm système après DeepSeek V4, quand les denses et
#   le 35B-A3B passaient.
#   ⚠ GUÉRI par le runtime retained-PM4 de l'image, constaté le 18/09/2026 :
#   quatre comptages de lignes justes, aucune trace de « LAMPAMPAMP ». Le
#   charabia venait du ROCm système (opérateurs fusionnés renvoyés sur CPU),
#   pas de l'architecture.
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
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac, ROCm0, fit off, load-mode none, cache K et V f16,
#   script de test HORS DÉPÔT, prompt court d'environ 1 400 tokens et 1 000
#   générés, médianes de 3 passes ; UD-Q4_K_XL, draft-dflash n-max 7) :
#   prefill 1352 t/s, décode 65,1 t/s. Contre la même section sur le fork
#   0007bc6 Vulkan0 (727 / 52,2) : prefill +86 %, décode +25 %, le meilleur
#   gain de prefill du parc avec le 9b. Prefill en profondeur (2k / 8k / 25k /
#   51k) : 1417 / 1455 / 1245 / 1006 t/s, quatre comptages de lignes justes.
#   ⚠ Ces chiffres ne viennent PAS de --bench : à rejouer par le dépôt.
llama_model qwen3-coder-next "
model            = $QWEN3_CODER_NEXT_PATH
ctx-size         = 131072
cache-ram        = 4096
temp             = 1.0
top-k            = 40
top-p            = 0.95
min-p            = 0.01
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
#   se creuse en contexte long, le régime agentic. ⚠ HISTORIQUE : ce ROCm0-là
#   est le ROCm SYSTÈME (paquet ggml-hip), pas le runtime retained-PM4 de
#   l'image ; sur ce dernier le prefill de la section tombe à 229 t/s et le
#   décode monte à 40,7 (cf. bas de bloc). Chargement : 4,4 s (17 Go, cache de
#   pages chaud), TTFT à chaud 165 ms.
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
#   Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes, alors
#   en cache-type-v q8_0) : prefill 359 t/s, décode 32,6 t/s, acceptance
#   0,595, contre 261 / 29,5 /
#   0,65 au paquet b10433 (+11 % de décode) et 360 / 26,6 / 0,59 en MTP
#   n-max 6 sur le même fork (+23 %). Le retrait de décode du fork est annulé,
#   le réglage passe au gain net des deux côtés.
# reasoning = off : nothink du suffixe de section, option native de
#   llama-server (présente sur 0007bc6), posée le 17/09/2026 à la place de
#   chat-template-kwargs {"enable_thinking":false}, obsolète. Sortie non
#   contrôlée individuellement ici : le contrôle a porté sur Flash-Next
#   (reasoning_content vide, réponse directe, vitesse inchangée).
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac, ROCm0, fit off, load-mode none, cache K et V f16,
#   script de test HORS DÉPÔT, prompt court d'environ 1 400 tokens et 1 000
#   générés, médianes de 3 passes ; UD-Q4_K_XL, ngram-map-k 47 + draft-dflash
#   n-max 7) : prefill 229 t/s, décode 40,7 t/s. Contre la même section sur le
#   fork 0007bc6 Vulkan0 (302 / 32,2) : décode +26 %, prefill -24 %.
#   ⚠ C'EST UN COMPROMIS, et il n'est PAS tranché ici : cette section est la
#   seule du parc à perdre du prefill à la bascule. Elle sert de l'agentic, où
#   le prefill compte (relecture de fichiers) autant que le décode ; le tour
#   simulé de l'ancien --bench-devices (2000/prefill + 3000/décode) donnerait
#   81,4 s sur l'image contre 99,8 s sur le fork, donc l'image gagne sur ce
#   profil, mais ce profil est une convention, pas une mesure de l'usage.
#   Décision utilisateur à prendre à la bascule, avec --bench-agentic.
#   Prefill en profondeur (2k / 8k / 25k / 51k) : 244 / 239 / 225 / 202 t/s,
#   justesse vérifiée par comptage de lignes. À noter : Muse-Glimmer, son
#   concurrent direct, ne perd pas de prefill (cf. son bloc).
#   ⚠ Ces chiffres ne viennent PAS de --bench : à rejouer par le dépôt.
# cache-type-v f16 (était q8_0, 17/09/2026) : les deux réglages mesurés le
#   même soir, à froid après redémarrage, même moteur (strix-0007bc6,
#   Vulkan0, mode EC performance, --bench 3 passes) : f16 302 / 32,2 / 0,625
#   contre q8_0 305 / 30,3 / 0,595, soit +6 % de décode, acceptance 0,595 vers
#   0,625, prefill égal. Le f16 est donc gardé malgré la convention V q8_0 du
#   parc pour l'agentic. Ces 302 / 32,2 / 0,625 REMPLACENT les 359 / 32,6 /
#   0,595 du 13/09 comme référence du README et de docs/perfs.tsv : autre
#   jour, autre série, la comparaison propre est celle de ce soir-là.
#   Depuis le 18/09/2026 la ligne n'est plus dans le corps : le f16 vient du
#   global (cf. en-tête), et c'est en f16 sur K ET V que la campagne du
#   moteur conteneurisé a mesuré la section.
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
reasoning            = off
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
# Muse-Glimmer-30B (Meta) : dense 30B agentic + drafter DFlash 2
# =============================================================================

groupe "; --- Muse-Glimmer-30B (Meta, dense 30B : GGUF cible + drafter DFlash 2 z-lab) ---"

# Muse-Glimmer-30B (Meta, août 2026, Apache 2.0) — dense causal 30B, 52 couches,
# hidden 6656, GQA 32 Q / 2 KV, motif d'attention [local, local, local, global]
# avec fenêtre glissante de 2048 sur les couches locales (RoPE θ 500000 sur les
# locales seulement), ctx natif 131072. Orienté agentic : SWE-bench Verified
# 76,0, SWE-Bench Pro 51,2, MCP Atlas 75,5. Encodeur de perception (mmproj)
# disponible mais NON déclaré : texte seul, incompatible avec un drafter.
# general.architecture = muse-glimmer, mainline b10353 (PR #26841, 10/08/2026),
# présent dans le fork strix-0007bc6 (vérifié le 16/09/2026,
# src/llama-arch.cpp:75, plus le correctif #26879 des tool calls après EOM).
# UD-Q4_K_XL unsloth (15 878 222 368 octets) : quant recommandée par le guide
# unsloth (docs.unsloth.ai/models/muse-glimmer). Fichier unique, pas de shard.
# Le repo officiel meta-models/Muse-Glimmer-30B-GGUF porte les mêmes quants
# sous d'autres noms (KQuant-*), plus un DFlash 1 (block 16) : non retenu, le
# DFlash 2 ci-dessous annonce la même longueur acceptée pour un drafter à
# sélecteur de chemin, format déjà servi sur le 27B.
download_hf muse-glimmer-30b "unsloth/Muse-Glimmer-30B-GGUF" \
  MUSE_30B_PATH="Muse-Glimmer-30B-UD-Q4_K_XL.gguf"

# Drafter DFlash 2 (z-lab, miroir d'incoai, Q8_0, 2 959 518 912 octets) :
# diffusion par blocs avec sélecteur de chemin, acceptance annoncée 5,4 à 5,6
# tokens par étape (GSM8K, cible Q4_K_M ; Q8_0 5,58, BF16 5,45). Même dossier
# que le modèle, autre repo. spec-type draft-dflash (pas de « dflash2 » : le
# moteur détecte le format au chargement, PR #27342 présente dans le fork,
# commit b10f9ca5). Le GGUF devient nécessaire au démarrage de la section : ne
# pas le retirer de ~/models/muse-glimmer-30b/.
download_hf muse-glimmer-30b "z-lab/Muse-Glimmer-30B-DFlash2-GGUF" \
  MUSE_30B_DFLASH_PATH="Muse-Glimmer-30B-DFlash2-Q8_0.gguf"

# Muse-Glimmer-30B DFlash — ajouté le 16/09/2026, étapes 1 à 6 de la skill
#   ajout-modele faites le jour même (chiffres ci-dessous), étape 7
#   (--bench-agentic) en bas de bloc.
#   Concurrent direct de qwen3.8-27b-dflash-nothink (même classe dense, même
#   spec-type) : c'est contre lui que se lit le résultat.
# Pas de suffixe -nothink : le canal de réflexion de ce modèle NE SE FERME PAS
#   (reasoning off, enable_thinking false, reasoning_effort none : sans effet,
#   documenté par la fiche Meta). Seul le niveau se règle, par le kwarg
#   reasoning_strength (low / medium / high / xhigh, défaut high) : low ici,
#   régime agentic où la latence prime, plafonné par reasoning-budget 4096
#   (clé mainline, pas une clé du fork ; les -soft-ratio & co du fork restent
#   possibles plus tard, cf. deepseek-v4-flash). À re-évaluer au bench-agentic
#   (étape 7) : si low fait échouer des scénarios, remonter à medium.
#   reasoning-budget-enable = true : sur le fork, reasoning-budget n'agit que
#   derrière cette clé (common/sampling.cpp:313, vérifié le 16/09/2026 sur le
#   LFM 8B) ; sans elle le 4096 est décoratif. Clé propre au fork (cf.
#   deepseek-v4-flash), parc déjà verrouillé sur le fork. Au test isolé en
#   strength low le raisonnement tient en 15 à 40 lignes, la réponse suit.
# Sampling : reco officielle Meta et unsloth (temp 1.0, top-p 0.95, top-k 64),
#   min-p 0 explicite.
# Tokens de fin : <|end_of_text|> et <|eot|> sont les eos du GGUF ; <|eom|>
#   n'est PAS une fin de tour (fin de message, tool calls parallèles) : ne
#   jamais l'ajouter en stop, le template jinja gère.
# ctx 131072 : natif, un seul slot en dispose en entier.
# cache-ram 12288 : même besoin que le 27B (orchestrateur de 60k gardé en RAM
#   pendant qu'un agent occupe le slot, cf. son bloc).
# cache KV f16 : hérité du global depuis le 18/09/2026 (cf. en-tête), la ligne
#   cache-type-v = f16 du corps est retirée. Attention pure sans état récurrent,
#   rien ne s'y oppose, et le f16 sur V donnait déjà une meilleure acceptance
#   que le q8_0 sur cette classe de modèles (mesuré sur le 27B le 17/09/2026).
# cache-reuse 0 : contrainte des sections spéculatives (ici la seule raison :
#   pas d'état récurrent, la valeur serait sinon utilisable).
# swa-full + ctx-checkpoints : arch à SWA réelle (fenêtre 2048 sur 3 couches
#   sur 4), c'est LE cas pour lequel la paire est prévue, et contrairement aux
#   sections Qwen le journal ne dit PAS « swa_full is not supported » (vérifié
#   le 16/09/2026) : elle est effective. --bench-cache du 16/09/2026 : suite
#   99 % servi du cache (321 ms), identique 100 % (82 ms), édition au 1er
#   tiers 34 % (le préfixe avant l'édition est réutilisé) : la restauration
#   au token près d'une attention pure, contre 62 à 66 % sur les archs à état
#   récurrent du parc. Le prefill froid de 1,4k tokens coûte 5,1 s.
# Spéculation DFlash 2, test isolé du 16/09/2026 (fork strix-0007bc6, Vulkan0,
#   hors service, np 1, 2 passes, 1200 tokens, -c 32768, médiane hors 1re
#   passe, spec-test.txt / spec-refactor.txt, strength low) :
#     sans spéculation        14,0 / 13,9 t/s   (prefill froid 275 t/s)
#     draft-dflash n-max 7    43,0 / 41,4  (acceptance 0,74 / 0,72, 6,0 à 6,2
#                                           tokens acceptés par étape)
#     draft-dflash n-max 15   20,9 / 17,5  (0,55 / 0,46)
#     draft-dflash n-max 3    37,8 / 34,6  (0,85 / 0,80)
#   RETENU n-max 7 : x3,1 sur le décode nu. La carte z-lab dit 15, mais un
#   batch de vérification de 16 colonnes quitte le noyau mat-vec de
#   ggml-vulkan (marche x2 entre 8 et 9, cf. bloc 27B) : mesuré, le 15 perd
#   moitié du gain. 7 donne un batch de 8 = 4+4, pas de découpage 4/2/1 du
#   fork. Le décode nu à 14 t/s est celui d'un dense de 16 Go sur la bande
#   passante de bigchuck (le 27B UD-Q4_K_XL de 17 Go est du même ordre) : ce
#   modèle ne vit que par son drafter. --spec-tune refuse draft-dflash : tout
#   re-réglage passe par --spec-ab.
#   n-gram : size-m réglé par --spec-ab tel que servi le 16/09/2026
#   (--spec-ngram-tune écarté : référence « sans spéculation » sur un modèle
#   sans tête MTP, sans sens avec un drafter externe ; strix-0007bc6, Vulkan0,
#   4 passes, décode médian) :
#     spec-refactor.txt : draft-dflash seul 37,2 (acc. 0,63) ; ngram 7 +
#       dflash 41,8 (0,62) ; ngram 15 = 29,2 (0,52) ; ngram 47 = 37,1 (0,53)
#     spec-test.txt : draft-dflash seul 42,0 (0,73) ; ngram 7 = 43,5 (0,73)
#   RETENU size-m 7, min-hits 2 : +12,5 % sur le refactor, +3,5 % en
#   générique. Contrairement au 27B (où 47 gagne), le régime large PERD ici :
#   le DFlash 2 accepte déjà 6 tokens par étape, et un draft n-gram de 47
#   colonnes accepté à moitié lui vole des pas plus rentables ; 15 est le pire
#   des deux mondes (batch 16 hors du noyau mat-vec, cf. n-max 15 ci-dessus).
# parallel 1 : batch déjà à 8 colonnes avec n-max 7 (np 2 en ferait 16), et
#   régime agentic sérialisé.
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image, cf. en-tête).
#   Jusque-là Vulkan0 hérité du défaut, --bench-devices jamais lancé ici (le
#   fork n'exposait qu'un device et la commande refusait).
# Mesuré le 16/09/2026 TEL QUE SERVI (fork strix-0007bc6, Vulkan0, --bench 3
#   passes, bench-task) : prefill 266 t/s, décode 38,0 t/s, acceptance 0,635.
#   Contre qwen3.8-27b-dflash-nothink sur le même fork (359 / 32,6 / 0,595) :
#   décode +17 %, prefill -26 %. Jamais mesuré au paquet Arch.
# --bench-load du 16/09/2026 : 3,5 s chargement + 1er token (15 Go lus), TTFT
#   à chaud 88 ms.
# Mémoire : 21 Go résidents au test isolé à -c 32768 (free après mesures) ;
#   compter ~24 Go à 131072 (poids 15,9 + drafter 3,0 + KV en q8_0 sur V, KV
#   réduit par le GQA 2 têtes et la SWA).
# --bench-agentic du 16/09/2026 (pi 0.84.3, strix-0007bc6, 3 passes) : 16/16,
#   froid compris. Médianes : froid 11,2 s (1,6k tokens, 259 t/s) ; simple
#   2,5 s ; outils 10,9 s (344 tokens, 38,1 t/s) ; edit 10,8 s (40,8 t/s) ;
#   création 25,9 s (986 tokens, 39,8 t/s) ; bug sans toucher au test 37,5 s
#   (1050 tokens, 33,8 t/s). Cache servi 97 à 99 % à chaque tour (attention
#   pure, cf. --bench-cache), décode en boucle 34 à 41 t/s = celui du --bench
#   (38,0). Le raisonnement en strength low reste court et ne fait échouer
#   aucun scénario : réglage confirmé.
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac, ROCm0, fit off, load-mode none, cache K et V f16,
#   script de test HORS DÉPÔT, prompt court d'environ 1 400 tokens et 1 000
#   générés, médianes de 3 passes ; UD-Q4_K_XL, ngram-map-k 7 + draft-dflash
#   n-max 7, reasoning_strength low, reasoning-budget-enable + budget 4096) :
#   prefill 318 t/s, décode 36,4 t/s, justesse confirmée par comptage de
#   lignes. Contre la même section sur le fork 0007bc6 Vulkan0 (266 / 38,0, et
#   277 à 301 / 38,5 à 40,5 aux contrôles à froid du 17/09) : prefill +7 à
#   +19 %, décode -4 à -10 %, donc à peu près l'inverse de son concurrent le
#   27B, qui gagne 26 % de décode et perd 24 % de prefill sur le même moteur.
#   Prefill en profondeur (2k / 8k / 25k / 51k) : 328 / 323 / 293 / 259 t/s.
#   Le raisonnement en strength low reste court, la réponse suit.
#   ⚠ Ces chiffres ne viennent PAS de --bench : à rejouer par le dépôt.
llama_model muse-glimmer-30b-dflash "
model                = $MUSE_30B_PATH
ctx-size             = 131072
cache-ram            = 12288
temp                 = 1.0
top-k                = 64
top-p                = 0.95
min-p                = 0.0
chat-template-kwargs = {\"reasoning_strength\":\"low\"}
reasoning-budget-enable = true
reasoning-budget     = 4096
cache-reuse          = 0
spec-type            = ngram-map-k,draft-dflash
spec-draft-model     = $MUSE_30B_DFLASH_PATH
spec-draft-n-max     = 7
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128"

# =============================================================================
# Géants
# =============================================================================

groupe "; --- Géants ---"

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
# cache KV f16 : hérité du global depuis le 18/09/2026 (cf. en-tête), les deux
#   lignes du corps qui le répétaient sont retirées. C'est la conf de référence
#   de cette section, et la campagne du 18/09 l'a confirmée directement : sur
#   ce modèle f16 et q8_0 sont ÉQUIVALENTS, en mémoire comme en débit. Raison
#   d'origine inchangée : KV MLA compact (~0,6 Go à 32K), et les configs
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
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image, cf. en-tête).
#   HISTORIQUE, --bench-devices 21/08/2026 (b10433, ROCm SYSTÈME) : Vulkan0
#   prefill 120 t/s, décode 11,2 t/s, et ROCm0 INUTILISABLE sur cette arch avec
#   ce build : le serveur répondait à ~500 t/s un charabia répétitif (« Nous dev
#   dev dev… »), réponse finale vide, sans erreur loggée, seulement des
#   opérateurs fusionnés DeepSeek V4 (Lightning Indexer, HC pre/comb/post)
#   renvoyés sur CPU. C'est ce cas qui a motivé le garde-fou « sortie
#   dégénérée » de timings.py, qui reste utile.
#   ⚠ GUÉRI par le runtime retained-PM4 de l'image, constaté le 18/09/2026 :
#   quatre comptages de lignes justes, acceptance 0,83, aucune trace de « Nous
#   dev dev dev ». Le charabia venait du ROCm système, pas de l'architecture.
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
# parallel 1 : essayé à 2 le 15/09/2026 et REMIS À 1 le soir même. La mesure
#   multi-slot le rendait tentant : (fork strix-0007bc6, Vulkan0, --bench-parallel) en solo 25,2 / 26,6 /
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
#   spéculation. MAIS --bench-agentic deepseek-v4-flash 2 2 du 15/09/2026
#   (mode parallèle du bench, 2 boucles pi simultanées contre la suite jouée
#   seule, 30 PASS sur 30) tranche contre : temps mur de la suite 116,7 s en
#   solo contre 202 s à 2 boucles, soit x1,16 de débit de tâches (x1,03 sur
#   une passe), décode vu par une boucle 14,5 t/s contre 28 à 30 en solo,
#   décode agrégé 21,4 t/s SOUS le solo (le batch ne compense pas son propre
#   surcoût), cache de préfixe intact (81 à 87 %). Un orchestrateur et un
#   sous-agent gagnent 16 % de tâches au prix d'une latence doublée chacun,
#   et le journal du service n'a jamais montré deux requêtes simultanées sur
#   ce modèle : le seul effet certain du parallel 2 était de diviser le
#   contexte par slot (65536 au lieu de 131072). Retour à 1, 131072 pour la
#   requête. La garde mémoire décharge les autres modèles pour charger
#   celui-ci (117,9 Go demandés), c'est normal.
# MOTEUR CONTENEURISÉ, campagne du 17 au 18/09/2026 (série
#   strix-8c1c282+r7dda3ac, ROCm0, fit off, load-mode none, cache K et V f16,
#   script de test HORS DÉPÔT, prompt court d'environ 1 400 tokens et 1 000
#   générés, médianes de 3 passes ; UD-IQ3_XXS, ngram-map-k 7 + draft-dspark
#   n-max 3, reasoning-budget 6144, contexte 131072, soit la conf de référence
#   ci-dessous, inchangée) : prefill 162 t/s, décode 29,3 t/s, acceptance 0,83.
#   Contre la même section sur le fork 0007bc6 Vulkan0 (196 / 28,8 / 0,69) :
#   décode +2 %, acceptance de 0,69 à 0,83, prefill -17 %. Prefill en
#   profondeur (2k / 8k / 25k / 51k) : 173 / 161 / 136 / 111 t/s, quatre
#   comptages de lignes justes.
#   ⚠ MÉMOIRE : chargé, ce modèle ne laisse plus que 9 Gio disponibles, QUEL
#   QUE SOIT le cache KV (f16 ou q8_0), le fit ou le contexte : ces trois
#   leviers ont été essayés le 18/09 et n'y changent rien. Il se sert donc
#   SEUL : la garde mémoire _ensure_room_for (lib/common.sh) décharge les
#   autres modèles avant de le charger, c'est le comportement attendu.
#   ⚠ Ces chiffres ne viennent PAS de --bench : à rejouer par le dépôt.
llama_model deepseek-v4-flash "
model            = $DSV4_FLASH_PATH
ctx-size         = 131072
cache-ram        = 8192
temp             = 1.0
top-k            = 40
top-p            = 0.95
min-p            = 0.0
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
parallel         = 1"

groupe "; --- Qwen3.8-Flash-Next : arch 'qwen4exp', servie par le fork strix-llama.cpp ; sur le paquet Arch de secours, b10661 minimum (PR #27742, mergée le 27/08/2026, présente dans b10809) ---"

# Qwen3.8-Flash-Next (Qwen) : MoE 125B (6B actifs, 512 experts, 10 routés + 1
# partagé) + 51B d'embeddings n-gram (bigrammes/trigrammes à la couche 2, table
# de hash lue une fois par forward), arch GDN (3 couches sur 4) + Qwen Sparse
# Attention (QSA, budget 2048, ratio 4) + hyper-connections, vision Qwen3-VL,
# ctx natif 256K (1M via YaRN). Quant AP-Q4_K_XL d'agentionai (94,2 Gio, fichier
# unique) depuis le 17/09/2026.
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
#   MIGRATION du 17/09/2026 vers AP-Q4_K_XL d'agentionai
#   (agentionai/Signal-3.8-Flash-Next-GGUF, fichier unique de 101 142 769 536
#   octets = 94,2 Gio, imatrix bartowski v5 sémantique, 1540 chunks) : mêmes
#   metadata que le GGUF unsloth (mêmes 64 clés hors imatrix et file_type,
#   mêmes 1224 tenseurs, même vocabulaire 248320 et même n_embd 2560, vérifié
#   au lecteur gguf le 17/09/2026), mais des experts en Q4_K au lieu d'IQ4_XS.
#   Raison : sur le runtime ROCm de la PR kyuz0/amd-strix-halo-toolboxes#133 la
#   quant Q4_K y est nettement plus rapide que l'UD-IQ4_XS à configuration
#   égale, 877 contre 526 t/s de prefill et 52,2 contre 45,3 t/s de décode
#   (chiffres de la PR, AUTRE moteur : ils ne se comparent pas aux mesures
#   ci-dessous, ils ont seulement motivé l'essai). Ce que vaut cette quant sur
#   le moteur du service (fork strix-0007bc6, Vulkan0) est mesuré plus bas.
#   Les shards UD-IQ4_XS restent sur disque pour les comparaisons ; n'étant
#   plus déclarés, le dossier UD-IQ4_XS/ est ORPHELIN (93,7 Go)
#   → un futur ./setup-llm.sh --cleanup le purgera (non lancé).
# Sampling officiel (guide unsloth + model card) : même table que Qwen3.8-27B
#   (cf. l'en-tête du bloc Qwen3.8-27B plus haut), thinking et instruct.
# Thinking ON par défaut (<think>), reasoning_effort xhigh (défaut) / medium /
#   low, "high" est replié sur xhigh par le template ; enable_thinking false =
#   nothink. preserve_thinking (garde les traces des tours précédents) : true
#   par défaut, côté client. Le modèle ci-dessous est en NOTHINK par
#   reasoning = off (option native de llama-server, posée le 17/09/2026 à la
#   place de chat-template-kwargs {"enable_thinking":false}, obsolète ;
#   contrôlé le soir même : reasoning_content vide, réponse directe, vitesse
#   inchangée, 342 / 48,1 / 0,87 contre 338 / 48,3 / 0,87 avant le changement,
#   même moteur), avec le
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
# Vision : ACTIVÉE depuis le 17/09/2026 (mmproj-BF16.gguf d'unsloth, 907 542 944
#   octets, arch clip, projecteur qwen3vl_merger, 27 blocs, images 768,
#   deepstack). Réglages repris de la configuration de référence de l'auteur des
#   fichiers : mmproj, mmproj-device = le device du modèle (injecté par
#   generate_models_ini, cf. lib/ini.sh, comme device-draft) et
#   image-min-tokens 1024, Qwen-VL ayant besoin d'au moins 1024 tokens d'image
#   pour le grounding (le fork le dit lui-même : tools/mtmd/clip.cpp avertit
#   « try adding --image-min-tokens 1024 »).
#   Les trois clés sont comprises AUSSI par le paquet Arch (vérifié le
#   17/09/2026 sur b10964, --help) : rien à ajouter à FORK_ONLY_KEYS.
#   Le dépôt affirmait jusqu'ici « mmproj incompatible avec un drafter » (cf.
#   en-tête) : cette phrase vient de la même doc unsloth que le « np > 1 non
#   supporté », et le fork servi ne porte aucune garde de ce genre (lecture de
#   tools/server/server-context.cpp au commit 0007bc6 le 17/09/2026 : mctx et
#   contexte spéculatif sont initialisés indépendamment). Vision ET spéculation
#   sont donc servies ensemble ici, et c'est la validation du jour qui tranche.
# MTP : la tête n'est PAS dans le GGUF principal (retirée par unsloth le
#   01/09), elle est publiée en sidecar dans MTP/ du repo HF. Deux familles de
#   fichiers : les « shared- » (2,60 Go) empruntent embeddings et projection de
#   sortie au modèle hôte, les AUTONOMES portent les leurs.
#   ⚠ RENVERSEMENT DU 18/09/2026 : c'est la tête « SHARED » Q8_0 qui est servie,
#   et elle seule. Le moteur de l'image (8c1c282) sait emprunter les tenseurs de
#   la cible ; la campagne l'a chargée telle quelle, sans renommage, avec une
#   acceptance de 0,87. Conséquences : la tête AUTONOME Q8_0 (4,1 Go) n'est plus
#   déclarée, la copie renommée « strix » n'existe plus du tout, et avec elle
#   partent derive_gguf, _derive et tools/mtp-rename-hc-head.py, plus aucune
#   section du parc ne dérivait de fichier (cf. le commentaire de KNOWN_FILES).
#   HISTORIQUE, vérifié le 17/09/2026 sur le commit épinglé 0007bc6 (fork
#   Vulkan) : la tête « shared » y était INUTILISABLE, et le renommage des
#   hc_head n'y changeait rien. Le chargeur qwen4exp de ce commit crée
#   token_embd.weight en tenseur REQUIS (flag 0, src/models/qwen4exp.cpp) avant
#   même le mixeur des hyper-connexions ; le fichier « shared » ne porte ni
#   token_embd ni output (32 tenseurs contre 34). Essai de chargement CPU seul
#   (llama-cli --device none), tel quel PUIS renommé : les deux échouaient sur
#   « check_tensor_dims: tensor 'token_embd.weight' not found », quand le
#   sidecar autonome renommé chargeait sans une erreur. Le renommage et le
#   sidecar autonome n'étaient donc nécessaires QUE pour 0007bc6.
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
#   mémoire, et elle suffit : 101 Go de poids sur 124 Go depuis l'AP-Q4_K_XL
#   (93,7 Go en UD-IQ4_XS), dont 28,8 Go de table n-gram restés sur disque
#   (lazy-mode on-direct, ngram-on-disk avant le 18/09/2026), plus le mmproj,
#   et les 33 Gio de tampons du batch 16384 ; un deuxième slot de
#   KV à 128k mangerait la marge ; et ctx-size étant un pool partagé, passer à
#   2 slots couperait aussi en deux le contexte par requête. Valeur inchangée
#   après la campagne multi-slot du 15/09/2026 (cf. en-tête) : cette section
#   n'y a pas été mesurée, la mémoire tranchant avant le rendement.
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image, cf. en-tête).
#   HISTORIQUE, --bench-devices 05/09/2026 (b10809, ROCm SYSTÈME) : Vulkan0
#   prefill 181 t/s, décode 24 t/s brut, et ROCm0 EXCLU par la question de
#   contrôle, réponse « LAMPAMPAMPAMP... » dégénérée, le même symptôme que
#   DeepSeek V4 et Qwen3-Coder-Next (MoE à opérateurs fusionnés).
#   ⚠ Sans objet sur le runtime retained-PM4 de l'image : la campagne du 17 au
#   18/09/2026 y mesure 877 / 52,2 avec une justesse vérifiée jusqu'à 51k
#   tokens (cf. bas de bloc), comme pour les deux autres MoE guéris.
# Fichier UNIQUE (pas de shards) : download_hf suffit, le sous-dossier de quant
# est recréé tel quel sous le dossier modèle. --cleanup protège en
# bloc le dossier de quant AP-Q4_K_XL/, comme il le faisait pour les shards.
# Téléchargé et vérifié (sha256) sur bigchuck le 17/09/2026.
download_hf qwen3.8-flash-next "agentionai/Signal-3.8-Flash-Next-GGUF" \
  QWEN38_FLASH_NEXT_PATH="AP-Q4_K_XL/Signal-3.8-Flash-Next-AP-Q4_K_XL.gguf"
# Projecteur vision, repo unsloth, à la racine du dossier modèle. Fichier plat :
# --cleanup protège le fichier lui-même, pas un dossier.
download_hf qwen3.8-flash-next "unsloth/Qwen3.8-Flash-Next-GGUF" \
  QWEN38_FLASH_NEXT_MMPROJ_PATH="mmproj-BF16.gguf"
# Tête MTP en sidecar, même repo, sous-dossier MTP/ (recréé tel quel sous le
# dossier modèle par _dl). Version « SHARED » Q8_0 (2 786 568 256 octets, 32
# tenseurs) depuis le 18/09/2026 : elle emprunte embeddings et projection de
# sortie au modèle hôte, et le moteur de l'image sait le faire (chargée telle
# quelle, sans renommage, acceptance 0,87). Déjà téléchargée sur bigchuck.
# Les deux fichiers qu'elle remplace ne sont plus déclarés et deviennent
# ORPHELINS dans ~/models/qwen3.8-flash-next/MTP/ : le sidecar AUTONOME
# mtp-Qwen3.8-Flash-Next-Q8_0.gguf (4,1 Go, 34 tenseurs) et sa copie renommée
# mtp-Qwen3.8-Flash-Next-strix-Q8_0.gguf (4,1 Go), tous deux nécessaires au
# seul commit 0007bc6. ⚠ --cleanup NE LES PURGERA PAS : MTP/ reste un
# sous-dossier protégé en bloc dès qu'un de ses fichiers est déclaré. Les
# supprimer à la main, ou les garder pour un retour au fork.
download_hf qwen3.8-flash-next "unsloth/Qwen3.8-Flash-Next-GGUF" \
  QWEN38_FLASH_NEXT_MTP_PATH="MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"

# Qwen3.8-Flash-Next nothink : spéculation mixte n-gram + MTP, sampling instruct,
# et vision depuis le 17/09/2026.
# MIGRATION du 17/09/2026 : la section sert désormais la quant AP-Q4_K_XL
#   d'agentionai (cf. la déclaration plus haut) au lieu des shards UD-IQ4_XS
#   d'unsloth, avec le mmproj BF16 et son image-min-tokens 1024. Le NOM de la
#   section ne change pas (décision utilisateur) : le drafter, lui, n'a pas
#   bougé, c'est toujours la tête MTP en sidecar. Toutes les mesures citées
#   ci-dessous sont ANTÉRIEURES à la migration et portent sur l'UD-IQ4_XS :
#   elles ne se comparent à la quant AP que sur le même moteur et le même
#   device, ligne à ligne.
#   MESURÉ le 17/09/2026, quant AP-Q4_K_XL (strix-0007bc6, Vulkan0, mode EC
#   performance, mmproj chargé, ngram-map-k 7 + draft-mtp 4, ngram-on-disk) :
#   --bench 3 passes = prefill 364 t/s, décode 52,4 t/s, acceptance 0,865,
#   contre 342 / 48,1 / 0,87 pour l'UD-IQ4_XS le même soir et sur le même
#   moteur, soit +6 % de prefill et +9 % de décode. Le gain est donc RÉEL mais
#   sans rapport avec le facteur annoncé par la PR #133, qui mesurait un autre
#   runtime. Mémoire utilisée, modèle chargé : 89 Go (79 Go en UD-IQ4_XS).
#   Chargement du serveur complet (poids + sidecar MTP + mmproj) : 18,5 s,
#   fichier encore chaud en cache de pages.
#   Vision et spéculation COHABITENT, contrairement à ce que le dépôt affirmait
#   (cf. le paragraphe Vision plus haut) : le journal montre « loaded
#   multimodal model » puis le sidecar MTP chargé, et l'acceptance reste à 0,87
#   pendant le bench. Contrôle vision du jour : un carré rouge de 64x64 en PNG
#   (data URI, /v1/chat/completions) est décrit « Le carré que vous avez fourni
#   est de couleur rouge. » Contrôle nothink : reasoning_content vide.
#   Reste à faire sur cette quant (ni la migration ni la campagne du 18/09 ne
#   les ont rejoués) : le --spec-tune, le --bench-cache, le --bench-load et le
#   --bench-agentic. Le --bench-devices n'existe plus (un seul device).
# Renommée -nothink le 04/09, quand draft-mtp avait été retiré faute de moteur
#   capable de charger le sidecar ; revenue à -mtp-nothink le 12/09/2026 avec le
#   retour de draft-mtp sur le fork, comme l'était alors
#   qwen3.8-27b-mtp-nothink (renommée qwen3.8-27b-dflash-nothink le
#   13/09/2026, la tête MTP y étant remplacée par le drafter DFlash 2).
# Jalon 2 (MTP de Flash-Next, cf. docs/HISTORIQUE.md, « Passage au fork »)
#   DÉBLOQUÉ le
#   12/09/2026 par le renommage du sidecar (outil tools/mtp-rename-hc-head.py,
#   retiré du dépôt le 18/09/2026, récupérable dans l'historique git) : le fork
#   apportait le graphe MTP qwen4exp et le drafter externe, il ne manquait que
#   la convention de nom. Le moteur de l'image lit la tête « shared » sans rien
#   renommer (cf. plus haut).
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
#   MESURÉ le 12/09/2026 via le routeur (strix-0007bc6, Vulkan0, UD-IQ4_XS,
#   mode mixte ngram-map-k 7 + draft-mtp n-max 4, ngram-on-disk) :
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
# lazy-mode on-direct (remplace ngram-on-disk le 18/09/2026) : même effet, la
#   table n-gram per_layer_token_embd (28,8 Go, propre à qwen4exp) n'est ni
#   mappée ni chargée, chaque batch relit du GGUF les seules lignes qu'il
#   rassemble. Sur le moteur de l'image, --ngram-on-disk n'est plus qu'un ALIAS
#   DÉPRÉCIÉ de --lazy-mode on ; la clé native est -lzm / --lazy-mode MODE (on,
#   on-direct, auto, off ; défaut auto), et c'est on-direct qui a été mesuré.
#   HISTORIQUE, A/B de ngram-on-disk sur le fork le 12/09/2026 (run antérieur
#   au --bench de référence 414 / 30,9) : même prefill et même décode (391 /
#   27,3 t/s contre 380 / 27,3 sans), sortie identique, mémoire utilisée 72 Go
#   au lieu d'environ 100.
#   ⚠ Le paquet Arch (b10809) ne connaît NI ngram-on-disk NI lazy-mode, et
#   refuse alors de démarrer le routeur ENTIER (« option 'ngram-on-disk' not
#   recognized in preset », vérifié le 12/09/2026 : l'ini n'est pas tolérant
#   aux clés inconnues). Revenir au paquet impose de retirer cette ligne à la
#   main puis de relancer --preload ; le dépôt ne filtre rien, il refuse
#   seulement de démarrer (FORK_ONLY_KEYS, lib/fork.sh).
# CONF DU MOTEUR CONTENEURISÉ, retenue le 18/09/2026 et servie telle quelle.
#   Ce qui change par rapport au fork, clé par clé :
#     ctx-size 262144 (était 131072) : le contexte natif entier, à un slot ;
#     batch-size et ubatch-size 16384 : SEULE section du parc autorisée à
#       dépasser 4096 (INI_BIG_BATCH_OK, cf. en-tête). Partout ailleurs cette
#       valeur part en erreur de segmentation (code 139) dès 8k tokens ; ici
#       elle tient, et c'est elle qui donne le prefill ci-dessous. Coût :
#       environ 33 Gio de tampons, à compter dans la marge mémoire ;
#     lazy-mode on-direct à la place de ngram-on-disk (cf. ci-dessus) ;
#     spec-type draft-mtp,ngram-mod (était ngram-map-k,draft-mtp) et
#       spec-draft-n-max 3 (était 4) : +10 % de décode contre l'ancien
#       spéculatif du dépôt sur ce moteur, 877 / 52,2 contre 881 / 47,4, à
#       prefill égal. Les clés spec-ngram-map-k-size-m et -min-hits disparaissent
#       avec ngram-map-k ; ngram-mod n'a pas de taille à régler ici.
#       ⚠ spec-nmax.conf (local, non versionné) porte encore « 4 » pour cette
#       section sur bigchuck : il écraserait le 3. generate_models_ini
#       avertit maintenant quand une valeur locale contredit le dépôt
#       (_ini_warn_conf_nmax, lib/ini.sh) : la retirer à la bascule. Idem pour
#       la ligne de spec-ngram.conf, devenue inerte (plus de ngram-map-k) ;
#     tête MTP « shared » d'unsloth en drafter, sans renommage, avec
#       spec-draft-ngl = all injecté par generate_models_ini ;
#     cache K et V f16 (le cache-type-v q8_0 est retiré, cf. en-tête) ;
#     mmproj et image-min-tokens 1024 CONSERVÉS, vision et spéculation
#       cohabitant toujours.
#   MESURÉ, campagne du 17 au 18/09/2026 (série strix-8c1c282+r7dda3ac, ROCm0,
#   fit off, load-mode none, script de test HORS DÉPÔT, prompt court d'environ
#   1 400 tokens et 1 000 générés, médianes de 3 passes) : prefill 877 t/s,
#   décode 52,2 t/s. Contre la même quant AP-Q4_K_XL sur le fork 0007bc6
#   Vulkan0 (364 / 52,4) : prefill x2,4, décode égal. Prefill en profondeur
#   (2k / 8k / 25k / 51k) : 938 / 1108 / 1111 / 1079 t/s, le seul modèle du
#   parc dont le prefill MONTE avec la profondeur, effet du batch 16384.
#   Justesse vérifiée par comptage de lignes jusqu'à 51k tokens. Mémoire :
#   28 Gio restants une fois chargé.
#   ⚠ Ces chiffres ne viennent PAS de --bench : à rejouer par le dépôt.
llama_model qwen3.8-flash-next-mtp-nothink "
model            = $QWEN38_FLASH_NEXT_PATH
ctx-size         = 262144
cache-ram        = 8192
batch-size       = 16384
ubatch-size      = 16384
temp             = 0.7
top-k            = 20
top-p            = 0.80
min-p            = 0.0
presence-penalty = 1.5
reasoning            = off
cache-reuse      = 0
mmproj           = $QWEN38_FLASH_NEXT_MMPROJ_PATH
image-min-tokens = 1024
spec-type        = draft-mtp,ngram-mod
spec-draft-model = $QWEN38_FLASH_NEXT_MTP_PATH
spec-draft-n-max = 3
lazy-mode        = on-direct
jinja            = true
parallel         = 1"

# Préchargement par défaut (sans preload.conf) : le léger agentic edge seul,
# le reste en LRU — les always-on se choisissent via --preload.
# Depuis le 15/09/2026 la section lfm2.5-2.6b porte le drafter DSpark : le
# préchargé par défaut pèse donc ~9 Go chargé (poids + drafter + KV) au lieu
# de ~2,7 Go de poids. Il n'y a plus de variante sans drafter : la section
# lfm2.5-2.6b-parallel a été retirée le 15/09/2026 (pas de parallel si perte de
# perf, cf. docs/HISTORIQUE.md).
DEFAULT_PRELOAD=(lfm2.5-2.6b)
