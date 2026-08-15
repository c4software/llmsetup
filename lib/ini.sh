# lib/ini.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

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
