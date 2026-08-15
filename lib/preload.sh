# lib/preload.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

# =============================================================================
# Préchargement — lecture/écriture de preload.conf + sélection interactive
# =============================================================================


_save_preload_conf() {
  local tmp p
  tmp="$(mktemp)"
  {
    echo "; preload.conf — modèles préchargés (load-on-startup) au démarrage"
    echo "; généré par ./setup-llm.sh (--setup / --preload) — un modèle par ligne"
    echo "; édition manuelle OK ; --models-max = nb de lignes + 1 slot LRU"
    for p in "${PRESET_ORDER[@]}"; do
      [[ -n "${PRELOADED[$p]:-}" ]] && echo "$p"
    done
  } > "$tmp"
  mv "$tmp" "$PRELOAD_CONF"
}

# Sélection interactive des modèles préchargés. gum si dispo (cases à cocher,
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
          --header "Modèles préchargés au démarrage (espace = cocher, entrée = valider)" \
          --selected="$sel_csv") || {
        warn "Sélection annulée — préchargement inchangé : $(_preload_summary)"
        _save_preload_conf
        return
      }
  else
    # Fallback sans gum : liste numérotée, toggle par numéros
    info "gum absent (pacman -S gum pour les cases à cocher) — fallback numéroté."
    echo ""
    echo "Modèles préchargés au démarrage (always-on) :"
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
    && warn "Aucun modèle préchargé — premier appel de chaque modèle = temps de chargement complet."
  [[ $count -gt 3 ]] \
    && warn "$count modèles préchargés — vérifier que la somme des poids + KV tient dans les 128 Go."
  # Doublons connus : même GGUF chargé deux fois
  if [[ -n "${PRELOADED[qwen3.6-35b-a3b-nothink]:-}" && -n "${PRELOADED[qwen3.6-35b-a3b-mtp-nothink]:-}" ]]; then
    warn "35b-a3b nothink ET mtp-nothink préchargés : ~29 Go chargés deux fois pour le même modèle."
  fi
  local n38=0 p
  for p in qwen3.8-27b qwen3.8-27b-mtp-nothink; do
    [[ -n "${PRELOADED[$p]:-}" ]] && n38=$((n38 + 1))
  done
  if [[ $n38 -gt 1 ]]; then
    warn "$n38 modèles Qwen3.8-27B préchargés : même GGUF (~16 Go) chargé $n38 fois."
  fi
  # Toujours retourner 0 : sous set -e, un dernier test [[ ]] && ... faux
  # ferait sortir la fonction en 1 et tuerait le script avant la génération du ini.
  return 0
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
