# lib/bench.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

# =============================================================================
# bench — mesure de perfs via le serveur, tel qu'il tourne
#
# Simple : pour chaque modèle choisi, N requêtes API (défaut 3) sur le routeur
# en l'état — pas de restart, pas de comparaison de devices, pas d'écriture de
# conf. La passe 1 porte un long préfixe de remplissage → prefill réel (la
# taille qui fait foi est le n= mesuré, affiché sur la passe 1) ; les
# passes suivantes (prompt cache) → décode réel, spéculation incluse pour les
# modèles MTP. Affiche par modèle : prefill t/s, décode t/s (médiane),
# acceptance MTP le cas échéant (médiane hors passe 1, comme le décode).
# Tableau récapitulatif en fin de run ; un prefill dont la passe 1 a été
# partiellement servie par le cache (cache_n > 0) est marqué "*" — signalé,
# jamais "corrigé" (pas de purge de slots ni de restart : mesure passive).
#
# Usage :
#   ./setup-llm.sh --bench                 # sélection interactive des modèles
#   ./setup-llm.sh --bench <modèle> [n]    # un modèle, n passes (défaut 3)
#   ./setup-llm.sh --bench all [n]         # tous les modèles dont le GGUF existe
#
# NB : chaque modèle non chargé est chargé par le routeur à la 1re requête
# (LRU --models-max) — sur --bench all, prévoir les temps de chargement.
# Le choix du device par modèle reste celui de bench-devices.conf (édition
# manuelle) ; le réglage MTP passe par --spec-test/--spec-tune.
# =============================================================================

BENCH_PASSES=3
# Préfixe de préremplissage : phrase ~20 tokens (prompts/bench-filler.txt)
# répétée, chaque répétition préfixée de son numéro « [i] » à la construction
# (build_body.py — casse la répétitivité exacte, préfixe reproductible entre
# runs). La taille réelle du préfixe est le n= mesuré en passe 1, pas une
# taille visée. La tâche vit dans prompts/bench-task.txt.
# ⚠ Modifier un de ces fichiers invalide les comparaisons avec les tableaux de
#   bench antérieurs (cf. ARCHITECTURE.md).
BENCH_FILLER_REPEAT=400

# Mesure d'un modèle sur le serveur en l'état. Affiche les passes, retourne
# via BENCH_ROW une ligne "modèle|prefill|décode|acceptance" pour le récap
# (vide si échec).
BENCH_ROW=""
_bench_one() {
  local preset="$1" passes="$2"
  BENCH_ROW=""

  local task_file="$SCRIPT_DIR/prompts/bench-task.txt"
  local filler_file="$SCRIPT_DIR/prompts/bench-filler.txt"
  [[ -f "$task_file" ]] || error "Prompt manquant : $task_file"
  [[ -f "$filler_file" ]] || error "Prompt manquant : $filler_file"

  info "=== $preset ($passes passes, long préfixe de remplissage en passe 1) ==="

  local body out pp="" pp_mark="" acc="-" i
  local -a gens=() accs=()
  for (( i=1; i<=passes; i++ )); do
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 1000 $((42 + i)) "$task_file" \
      --filler-file "$filler_file" --filler-repeat "$BENCH_FILLER_REPEAT")"
    out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
      || { warn "  passe $i : échec curl"; continue; }
    local line
    line="$(python3 "$SCRIPT_DIR/py/timings.py" --bench "$out" "$i")" \
      || { echo "$line" | grep -v '^PP=\|^G=\|^A=\|^PPCACHED='; continue; }
    echo "$line" | grep -v '^PP=\|^G=\|^A=\|^PPCACHED='
    if [[ "$i" -eq 1 ]]; then
      pp="$(echo "$line" | sed -n 's/^PP=//p')"
      # cache_n > 0 en passe 1 : prefill contaminé → "*" dans le récap
      echo "$line" | grep -q '^PPCACHED=1$' && pp_mark="*"
    else
      gens+=("$(echo "$line" | sed -n 's/^G=//p')")
      # acceptance : hors passe 1 (cache froid), comme le décode
      local a; a="$(echo "$line" | sed -n 's/^A=//p')"; [[ -n "$a" ]] && accs+=("$a")
    fi
  done

  if [[ -z "$pp" || ${#gens[@]} -eq 0 ]]; then
    warn "  '$preset' : mesure incomplète, exclu du récap."
    return 1
  fi
  local med
  med="$(printf '%s\n' "${gens[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
  # Médiane d'acceptance : même mécanisme awk que le décode
  [[ ${#accs[@]} -gt 0 ]] \
    && acc="$(printf '%s\n' "${accs[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
  info "  → prefill $pp$pp_mark t/s, décode $med t/s (médianes hors passe 1)$( [[ "$acc" != "-" ]] && echo ", acceptance $acc" )"
  BENCH_ROW="$preset|$pp$pp_mark|$med|$acc"
  return 0
}

# Modèles benchables = tous ceux dont le GGUF est sur disque, ordre PRESET_ORDER
BENCH_PRESETS=()
_bench_presets() {
  BENCH_PRESETS=()
  local p gguf
  for p in "${PRESET_ORDER[@]}"; do
    gguf="$(echo "${MODEL_INI[$p]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
    [[ -f "$gguf" ]] && BENCH_PRESETS+=("$p")
  done
}

# Sélection interactive des modèles à bencher (gum ou fallback numéroté).
BENCH_TARGETS=()
_bench_select_presets() {
  _bench_presets
  BENCH_TARGETS=()
  [[ ${#BENCH_PRESETS[@]} -gt 0 ]] || { warn "Aucun GGUF présent sous $MODELS_BASE — lancer --setup."; return; }

  local -a chosen=()
  if command -v gum >/dev/null 2>&1; then
    mapfile -t chosen < <(printf '%s\n' "${BENCH_PRESETS[@]}" \
      | gum choose --no-limit --height 20 \
          --header "Modèles à bencher (espace = cocher, entrée = valider)") || chosen=()
    local line
    for line in "${chosen[@]}"; do
      [[ -n "$line" ]] && BENCH_TARGETS+=("$line")
    done
  else
    info "gum absent (pacman -S gum pour les cases à cocher) — fallback numéroté."
    echo ""
    echo "Modèles à bencher :"
    local i=1 p
    for p in "${BENCH_PRESETS[@]}"; do
      printf "  %2d  %s\n" "$i" "$p"
      ((i++))
    done
    echo ""
    local input n
    read -r -p "Numéros à bencher (ex: 1 4), 'all' = tous, vide = annuler : " input
    if [[ "$input" == "all" ]]; then
      BENCH_TARGETS=("${BENCH_PRESETS[@]}")
    else
      for n in $input; do
        [[ "$n" =~ ^[0-9]+$ ]] || { warn "'$n' ignoré (pas un numéro)"; continue; }
        (( n >= 1 && n <= ${#BENCH_PRESETS[@]} )) || { warn "'$n' ignoré (hors liste)"; continue; }
        BENCH_TARGETS+=("${BENCH_PRESETS[$((n-1))]}")
      done
    fi
  fi
}

cmd_bench() {
  local target="${1:-}"
  local passes="${2:-$BENCH_PASSES}"
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 2 ]] || error "Nombre de passes invalide : '$passes' (minimum 2 : passe 1 = prefill, suivantes = décode)"

  command -v curl >/dev/null || error "curl introuvable"
  command -v python3 >/dev/null || error "python3 introuvable"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — sudo systemctl start $SERVICE_NAME"

  if [[ -z "$target" ]]; then
    if [[ -t 0 ]]; then
      _bench_select_presets
      [[ ${#BENCH_TARGETS[@]} -gt 0 ]] || { info "Rien sélectionné — bench annulé."; return; }
    else
      _bench_presets
      info "Modèles benchables : ${BENCH_PRESETS[*]:-aucun}"
      info "Lancer : ./setup-llm.sh --bench <modèle|all> [passes]"
      return
    fi
  elif [[ "$target" == "all" ]]; then
    _bench_presets
    [[ ${#BENCH_PRESETS[@]} -gt 0 ]] || error "Aucun GGUF présent — lancer --setup."
    BENCH_TARGETS=("${BENCH_PRESETS[@]}")
    warn "--bench all : chaque modèle non chargé sera chargé à sa 1re requête (LRU) — prévoir les temps de chargement."
  else
    [[ -n "${MODEL_INI[$target]:-}" ]] || error "Modèle inconnu : '$target' (voir --help)"
    BENCH_TARGETS=("$target")
  fi

  info "À bencher : ${BENCH_TARGETS[*]} — $passes passes chacun"
  echo ""

  local -a rows=()
  local p
  for p in "${BENCH_TARGETS[@]}"; do
    if _bench_one "$p" "$passes"; then
      rows+=("$BENCH_ROW")
    fi
    echo ""
  done

  [[ ${#rows[@]} -gt 0 ]] || { warn "Aucune mesure exploitable."; return; }
  info "════════ Récapitulatif ($(date '+%F %T'), $passes passes, long préfixe de remplissage) ════════"
  {
    echo "modèle|prefill t/s|décode t/s|acceptance"
    printf '%s\n' "${rows[@]}"
  } | column -t -s'|'
  if printf '%s\n' "${rows[@]}" | grep -q '\*|'; then
    echo "* prefill contaminé par le cache — chiffre non comparable"
  fi
}

# =============================================================================
# list-devices — devices exposés par ggml (Vulkan0, ROCm0…) + backends installés
#
# Diagnostic rapide après une mise à jour (split ggml, runtime ROCm) : si un
# device référencé dans bench-devices.conf n'apparaît plus ici, les modèles
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
    warn "  → ces modèles échoueront au chargement. Réinstaller le backend"
    warn "    (ex. paru -S ggml-hip) ou forcer Vulkan0 dans $BENCH_CONF puis --preload."
  fi
}
