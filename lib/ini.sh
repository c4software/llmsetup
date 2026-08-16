# lib/ini.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

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

# Clé modèle d'un modèle = dossier du GGUF référencé par sa ligne "model ="
_preset_model_key() {
  local body="${MODEL_INI[$1]}" path
  path="$(echo "$body" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
  [[ -n "$path" ]] && _key "$path"
}

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

generate_models_ini() {
  load_bench_conf
  load_preload_conf
  load_spec_conf

  cat <<HEADER
version = 1

; =============================================================================
; Flags globaux — appliqués à tous les modèles sauf surcharge locale
;
; device = Vulkan0 : backend par défaut. Les surcharges "device = ..." par
;   modèle ci-dessous proviennent de bench-devices.conf (écrit par
;   ./setup-llm.sh --bench-devices, édition manuelle OK) — chaque modèle
;   hérite du device retenu pour son GGUF. Vérifier au
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
    # Séparateurs de groupe déclarés par `groupe` dans models.sh
    if [[ -n "${GROUPE_AVANT[$name]:-}" ]]; then
      echo "${GROUPE_AVANT[$name]}"; echo ""
    fi

    echo "[$name]"
    # Surcharge device issue du bench (clé = dossier du GGUF du modèle)
    mkey="$(_preset_model_key "$name" || true)"
    mdev="${BENCH_DEVICE[$mkey]:-}"
    # BENCH_DEVICE_FORCE (env) prime sur tout, pour le modèle visé seulement :
    # utilisé par --bench-devices pour tester un device sans l'écrire
    if [[ -n "${BENCH_DEVICE_FORCE:-}" && "${BENCH_DEVICE_FORCE_PRESET:-}" == "$name" ]]; then
      mdev="$BENCH_DEVICE_FORCE"
    fi
    if [[ -n "$mdev" && "$mdev" != "$DEFAULT_DEVICE" ]]; then
      echo "device           = $mdev"
    fi
    # Corps du modèle + préchargement piloté par preload.conf
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

# Régénère le ini sur disque (routeur : relu au prochain démarrage seulement,
# un restart reste nécessaire pour appliquer)
regen_models_ini() {
  generate_models_ini > "$CONFIG_DIR/models.ini"
}
