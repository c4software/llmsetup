# lib/ini.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Génération du models.ini
#
# Le device n'est plus une variable : l'image du service (runtime/) est
# construite en HIP SEUL, elle n'expose que ROCm0. bench-devices.conf, sa
# commande --bench-devices et le mécanisme BENCH_DEVICE ont donc été retirés le
# 18/09/2026 : il n'y a plus rien à comparer. Les trois injections device,
# device-draft et mmproj-device restent (elles empêchent le serveur de répartir
# un modèle, son drafter ou son projecteur ailleurs que sur le device visé) et
# une quatrième les rejoint, spec-draft-ngl.
# =============================================================================

# Charge preload.conf → PRELOADED[modèle]=1. Sans fichier : DEFAULT_PRELOAD.
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
  # même garde set -e que load_spec_conf (dernière ligne = modèle retiré)
  return 0
}

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
  # return 0 explicite : si la dernière ligne du fichier ne passe pas le test
  # ci-dessus, la boucle (donc la fonction) retourne 1 et set -e tue le script
  # en plein generate_models_ini, après que la redirection a tronqué
  # models.ini. C'est ce cas précis (dernière ligne de spec-nmax.conf
  # référençant un modèle retiré du script) qui a produit un models.ini vide
  return 0
}

declare -A SPEC_NGRAM_M
load_spec_ngram_conf() {
  SPEC_NGRAM_M=()
  [[ -f "$SPEC_NGRAM_CONF" ]] || return 0
  local line k v
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*($|\;|\#) ]] && continue
    k="${line%%=*}"; k="${k// /}"
    v="${line#*=}";  v="${v// /}"
    [[ -n "${MODEL_INI[$k]:-}" && "$v" =~ ^[0-9]+$ ]] && SPEC_NGRAM_M[$k]="$v"
  done < "$SPEC_NGRAM_CONF"
  # même garde set -e que load_spec_conf (dernière ligne = modèle retiré)
  return 0
}

# size_m effectif d'un modèle : surcharge conf sinon valeur MODEL_INI (vide si
# le modèle n'a pas de spéculation n-gram). SPEC_NGRAM_FORCE (env) prime sur
# tout — utilisé par --spec-ngram-tune pour tester une valeur sans l'écrire.
_preset_ngram_m() {
  local p="$1" v
  v="$(echo "${MODEL_INI[$p]}" | sed -n 's/^spec-ngram-map-k-size-m[[:space:]]*=[[:space:]]*//p' | tr -d ' ')"
  [[ -n "$v" ]] || { echo ""; return; }
  if [[ -n "${SPEC_NGRAM_FORCE:-}" && "${SPEC_NGRAM_FORCE_PRESET:-}" == "$p" ]]; then
    echo "$SPEC_NGRAM_FORCE"; return
  fi
  echo "${SPEC_NGRAM_M[$p]:-$v}"
}

# _apply_overrides <corps ini> <"clé=val;clé=val"> → corps modifié sur stdout.
# Clé présente (même sans espaces autour du =) : ligne remplacée ; absente :
# ajoutée en fin. Les valeurs peuvent contenir virgules (listes spec-type) et
# "/" (chemins de drafter), pas de ";". Pur bash, pas de sed : aucun caractère
# de la valeur n'est interprété.
_apply_overrides() {
  local corps="$1" liste="$2" paire k v ligne trouve sortie
  local -a paires=()
  IFS=';' read -r -a paires <<< "$liste"
  for paire in "${paires[@]}"; do
    [[ "$paire" == *=* ]] || continue
    k="${paire%%=*}"; v="${paire#*=}"
    k="${k// /}"; v="${v# }"
    trouve=0; sortie=""
    while IFS= read -r ligne; do
      if [[ "$ligne" =~ ^${k}[[:space:]]*=[[:space:]]* ]]; then
        ligne="${BASH_REMATCH[0]}${v}"; trouve=1
      fi
      sortie+="${sortie:+$'\n'}$ligne"
    done <<< "$corps"
    corps="$sortie"
    [[ $trouve -eq 1 ]] || corps+=$'\n'"${k} = ${v}"
  done
  echo "$corps"
}

# n-max effectif d'un modèle : surcharge conf sinon valeur MODEL_INI (vide si
# modèle non spéculatif). SPEC_NMAX_FORCE (env) prime sur tout — utilisé par
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

# _ini_guard_batch <section> <corps ini> : refuse un batch-size ou un
# ubatch-size au-delà de $INI_BATCH_MAX pour une section qui n'est pas dans
# INI_BIG_BATCH_OK (lib/models.sh). Appelée sur le corps FINAL, donc après les
# surcharges de --spec-ab : une valeur passée par SPEC_AB_OVERRIDES est refusée
# comme une valeur écrite dans le script, c'est le même crash au bout.
_ini_guard_batch() {
  local name="$1" corps="$2" ligne cle val ok p
  ok=0
  for p in ${INI_BIG_BATCH_OK[@]+"${INI_BIG_BATCH_OK[@]}"}; do
    [[ "$p" == "$name" ]] && { ok=1; break; }
  done
  [[ "$ok" -eq 1 ]] && return 0
  while IFS= read -r ligne; do
    [[ "$ligne" == *=* ]] || continue
    cle="${ligne%%=*}"; cle="${cle// /}"
    [[ "$cle" == "batch-size" || "$cle" == "ubatch-size" ]] || continue
    val="${ligne#*=}"; val="${val// /}"
    [[ "$val" =~ ^[0-9]+$ ]] || continue
    if [[ "$val" -gt "$INI_BATCH_MAX" ]]; then
      error "[$name] $cle = $val : au-delà de $INI_BATCH_MAX, le moteur de l'image part en erreur de segmentation (code 139) dès un prompt de 8k tokens, et le batch coûte environ 33 Gio de tampons. Mesuré le 18/09/2026 sur tous les modèles du parc sauf ceux de INI_BIG_BATCH_OK (lib/models.sh) : ${INI_BIG_BATCH_OK[*]}."
    fi
  done <<< "$corps"
  return 0
}

# _ini_warn_conf_nmax <section> : avertit quand spec-nmax.conf impose au
# modèle une valeur DIFFÉRENTE de celle du dépôt. Sans cet avertissement, un
# changement de spec-type ou de n-max commité dans lib/models.sh est écrasé en
# silence par une valeur locale calibrée sur un autre moteur (cas de la
# section Flash-Next, passée de n-max 4 à 3 le 18/09/2026).
_ini_warn_conf_nmax() {
  local name="$1" local_v script_v
  local_v="${SPEC_NMAX[$name]:-}"
  [[ -n "$local_v" ]] || return 0
  script_v="$(echo "${MODEL_INI[$name]}" | sed -n 's/^spec-draft-n-max[[:space:]]*=[[:space:]]*//p' | tr -d ' ')"
  [[ -n "$script_v" && "$local_v" != "$script_v" ]] || return 0
  warn "[$name] spec-nmax.conf impose spec-draft-n-max = $local_v, le dépôt dit $script_v."
  warn "  Valeur locale calibrée sur un autre moteur ? La retirer de $SPEC_CONF pour reprendre le dépôt."
  return 0
}

generate_models_ini() {
  load_preload_conf
  load_spec_conf
  load_spec_ngram_conf

  cat <<HEADER
version = 1

; =============================================================================
; Flags globaux — appliqués à tous les modèles sauf surcharge locale
;
; device = ROCm0 : le seul device du moteur. Depuis la bascule en conteneur
;   (18/09/2026) le service tourne sur l'image de runtime/, construite en HIP
;   SEUL : aucun backend Vulkan dedans, donc plus de comparaison de devices ni
;   de bench-devices.conf. Vérifier au chargement dans les logs : device retenu
;   + flash-attn effectivement actif (certaines archs le coupent silencieusement
;   sous HIP, ce qui annule le gain de prefill).
; n-gpu-layers = 99 : inchangé. C'est « tout sur le GPU » pour tout le parc
;   (le plus profond fait 64 couches) ; le moteur accepterait aussi "all", la
;   valeur numérique est gardée pour ne pas rouvrir une comparaison sur un
;   simple renommage.
; fit = off, load-mode = none : réglages de la campagne du 17 au 18/09/2026.
;   Le moteur a -fit ON par défaut et ajusterait les arguments non posés ;
;   toute la campagne a tourné en "-fit off --load-mode none" et c'est ce qui
;   est servi. load-mode none plutôt que mmap : en mmap DeepSeek met plus de
;   13 minutes à charger (disqualifié). Sur DeepSeek, -fit on et -fit off
;   donnent le même résultat : le off est gardé parce que c'est lui qui a été
;   mesuré partout.
; cache-type-k / cache-type-v = f16 : toute la campagne du 17 au 18/09/2026 a
;   tourné en f16 sur les deux, sur les huit modèles mesurés. Aucune mesure de
;   ce moteur ne justifie une valeur quantifiée, et sur DeepSeek f16 et q8_0
;   sont équivalents (mémoire et débits) : le global passe donc en f16. Depuis
;   le 18/09/2026 et l'A/B d'ornith-1.5-35b-a3b-parallel (la dernière section
;   qui surchargeait, cf. lib/models.sh), AUCUNE section ne pose plus de valeur
;   de cache quantifiée.
;   C'était q8_0 / q4_0 jusqu'au 18/09/2026, du temps du moteur Vulkan.
; =============================================================================
[*]
device                 = $DEFAULT_DEVICE
n-gpu-layers           = 99
fit                    = off
load-mode              = none
cache-type-k           = f16
cache-type-v           = f16
flash-attn             = on
; prio : RETIRÉ le 22/09/2026. Le « prio = 2 » posé ici depuis le premier
;   script ne s'est jamais appliqué dans le conteneur : hausser la priorité
;   demande CAP_SYS_NICE, que cap_drop ALL retire (en root aussi), et depuis
;   le passage du conteneur en uid utilisateur un cap_add ne devient même
;   plus effectif (CapEff = 0, no-new-privileges). A/B du 22/09/2026 sur
;   bigchuck, avec et sans cap_add SYS_NICE : 663 / 46,1 contre 664 / 45,8 t/s
;   au --bench, boucles agentic identiques, avertissement « failed to set
;   process priority 2 : Permission denied » dans les deux cas. Cf.
;   docs/HISTORIQUE.md, « Le conteneur du service en uid:gid… ».
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
  for name in "${PRESET_ORDER[@]}"; do
    # Séparateurs de groupe déclarés par `groupe` dans models.sh
    if [[ -n "${GROUPE_AVANT[$name]:-}" ]]; then
      echo "${GROUPE_AVANT[$name]}"; echo ""
    fi

    echo "[$name]"
    # device toujours écrit, même s'il n'y a plus qu'un device : sans lui le
    # serveur répartit le modèle sur tous les devices exposés, et un drafter
    # qui partage token_embd avec la cible avorte. La ligne reste aussi le
    # point de lecture de status.args (/v1/models) pour les mesures.
    echo "device           = $DEFAULT_DEVICE"
    if grep -q "^spec-draft-model" <<< "${MODEL_INI[$name]}"; then
      echo "device-draft     = $DEFAULT_DEVICE"
      # spec-draft-ngl = all : même raisonnement que device-draft. Sans lui,
      # le nombre de couches du drafter est décidé par le moteur (et par le
      # -fit, qui peut en renvoyer au CPU), alors qu'un drafter tient toujours
      # sur le GPU, et il pèse de 0,36 à 10,9 Go dans ce parc. Le moteur de
      # l'image accepte "all" sur --spec-draft-ngl (alias --gpu-layers-draft).
      # Pas injecté si la section pose déjà la clé : on ne suppose rien sur la
      # tolérance du routeur à une clé répétée dans une même section.
      grep -q "^spec-draft-ngl[[:space:]]*=" <<< "${MODEL_INI[$name]}" \
        || echo "spec-draft-ngl   = all"
    fi
    # Même raison pour le projecteur vision : sans mmproj-device, l'encodeur
    # d'images atterrit où le serveur veut, pas sur le device du modèle
    # (17/09/2026, Qwen3.8-Flash-Next).
    if grep -q "^mmproj[[:space:]]*=" <<< "${MODEL_INI[$name]}"; then
      echo "mmproj-device    = $DEFAULT_DEVICE"
    fi
    _ini_warn_conf_nmax "$name"
    # Corps du modèle + préchargement piloté par preload.conf
    # (pas de stop-timeout : l'éviction est gérée par le LRU de --models-max)
    # spec-draft-n-max : surcharge spec-nmax.conf / --spec-tune si présente
    # spec-ngram-map-k-size-m : surcharge spec-ngram.conf / --spec-ngram-tune
    local eff_nmax eff_ngram
    eff_nmax="$(_preset_nmax "$name")"
    eff_ngram="$(_preset_ngram_m "$name")"
    local -a subs=()
    if [[ -n "$eff_nmax" ]]; then
      subs+=(-e "s/^\(spec-draft-n-max[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1$eff_nmax/")
    fi
    if [[ -n "$eff_ngram" ]]; then
      subs+=(-e "s/^\(spec-ngram-map-k-size-m[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1$eff_ngram/")
    fi
    # SPEC_TYPE_FORCE + SPEC_TYPE_FORCE_PRESET (env, posés par les tuners) :
    # spec-type remplacé le temps d'une mesure. --spec-tune force "draft-mtp"
    # (le n-max est un paramètre MTP pur et la calibration α exige un k
    # constant par forward, qu'une liste avec n-gram ne garantit pas) ;
    # --spec-ngram-tune force "none" pour la mesure de référence d'un modèle
    # sans MTP (sinon rien ne dit si le n-gram rapporte quoi que ce soit).
    if [[ -n "${SPEC_TYPE_FORCE:-}" && "${SPEC_TYPE_FORCE_PRESET:-}" == "$name" ]]; then
      subs+=(-e "s/^\(spec-type[[:space:]]*=[[:space:]]*\).*$/\1$SPEC_TYPE_FORCE/")
    fi
    # jamais "${subs[@]}" sur un tableau vide : unbound sous set -u en bash 4.3
    local corps
    if [[ ${#subs[@]} -gt 0 ]]; then
      corps="$(echo "${MODEL_INI[$name]}" | sed '/^$/d' | sed "${subs[@]}")"
    else
      corps="$(echo "${MODEL_INI[$name]}" | sed '/^$/d')"
    fi
    # SPEC_AB_OVERRIDES + SPEC_AB_PRESET (env, posés par --spec-ab) : surcharges
    # libres "clé=val;clé=val" sur le corps du modèle — une clé présente est
    # remplacée, une clé absente ajoutée. Sert à mesurer une variante sans
    # toucher au script ni aux conf (min-hits, size-n, autre spec-type…).
    if [[ -n "${SPEC_AB_OVERRIDES:-}" && "${SPEC_AB_PRESET:-}" == "$name" ]]; then
      corps="$(_apply_overrides "$corps" "$SPEC_AB_OVERRIDES")"
    fi
    _ini_guard_batch "$name" "$corps"
    echo "$corps"
    [[ -n "${PRELOADED[$name]:-}" ]] && echo "load-on-startup  = true"
    echo ""
  done
}

# Régénère le ini sur disque (routeur : relu au prochain démarrage seulement,
# un restart reste nécessaire pour appliquer)
regen_models_ini() {
  generate_models_ini > "$CONFIG_DIR/models.ini"
}
