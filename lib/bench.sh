# lib/bench.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

# =============================================================================
# bench — mesure de perfs via le serveur, tel qu'il tourne
#
# Simple : pour chaque modèle choisi, N requêtes API (défaut 3) sur le routeur
# en l'état — pas de restart, pas de comparaison de devices, pas d'écriture de
# conf. La passe 1 porte un long contexte réaliste (cahier des charges,
# prompts/bench-context.txt) → prefill réel (la taille qui fait foi est le
# n= mesuré, affiché sur la passe 1) ; les
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
# Le choix du device par modèle reste celui de bench-devices.conf
# (--bench-devices pour le comparer automatiquement, édition manuelle sinon) ;
# le réglage MTP passe par --spec-test/--spec-tune.
# =============================================================================

BENCH_PASSES=3
# Le prompt = contexte réaliste (prompts/bench-context.txt, cahier des charges
# du système que la tâche demande d'implémenter) + tâche de génération
# (prompts/bench-task.txt), joints par build_body.py. La taille réelle du
# contexte est le n= mesuré en passe 1, pas une taille visée.
# ⚠ Modifier un de ces fichiers invalide les comparaisons avec les tableaux de
#   bench antérieurs (cf. ARCHITECTURE.md).

# Mesure d'un modèle sur le serveur en l'état. Affiche les passes, retourne
# via BENCH_ROW une ligne "modèle|prefill|décode|acceptance" pour le récap
# (vide si échec).
BENCH_ROW=""
_bench_one() {
  local preset="$1" passes="$2"
  BENCH_ROW=""

  local context_file="$SCRIPT_DIR/prompts/bench-context.txt"
  local task_file="$SCRIPT_DIR/prompts/bench-task.txt"
  [[ -f "$context_file" ]] || error "Prompt manquant : $context_file"
  [[ -f "$task_file" ]] || error "Prompt manquant : $task_file"

  info "=== $preset ($passes passes, long contexte en passe 1) ==="

  local body out pp="" pp_mark="" acc="-" i
  local -a gens=() accs=()
  for (( i=1; i<=passes; i++ )); do
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 1000 $((42 + i)) "$context_file" "$task_file")"
    out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
      || { warn "  passe $i : échec curl"; continue; }
    local line
    line="$(python3 "$SCRIPT_DIR/py/timings.py" --bench "$out" "$i")" \
      || { echo "$line" | grep -v '^PP=\|^G=\|^A=\|^PPCACHED=\|^DEGEN='; continue; }
    echo "$line" | grep -v '^PP=\|^G=\|^A=\|^PPCACHED=\|^DEGEN='
    # Sortie dégénérée (cf. timings.py) : la mesure entière est invalide, pas
    # seulement la passe — le backend ne calcule pas ce modèle correctement.
    if echo "$line" | grep -q '^DEGEN=1$'; then
      warn "  '$preset' : sortie dégénérée, le serveur ne génère pas de texte valide sur ce device — mesure invalide."
      BENCH_ROW=""
      return 1
    fi
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
  # Sans ce return, un dernier GGUF absent fait retourner 1 à la fonction et
  # set -e tue le script en silence chez l'appelant
  return 0
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
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"

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
  info "════════ Récapitulatif ($(date '+%F %T'), $passes passes, long contexte) ════════"
  {
    echo "modèle|prefill t/s|décode t/s|acceptance"
    printf '%s\n' "${rows[@]}"
  } | column -t -s'|'
  if printf '%s\n' "${rows[@]}" | grep -q '\*|'; then
    echo "* prefill contaminé par le cache — chiffre non comparable"
  fi
}

# =============================================================================
# bench-devices — comparaison automatique des devices pour un modèle
#
# Usage : ./setup-llm.sh --bench-devices [modèle] [devices] [passes]
#   modèle  : sélection interactive si absent
#   devices : liste séparée par des virgules, défaut "Vulkan0,ROCm0"
#   passes  : défaut 3 (comme --bench)
#
# Pour chaque device : models.ini régénéré avec le device forcé
# (BENCH_DEVICE_FORCE), restart du service systemd, attente /health, puis
# _bench_one (mêmes prompts et mêmes médianes que --bench). Le restart entre
# deux devices garantit un cache froid : le prefill de la passe 1 est propre
# et comparable.
#
# Verdict : temps total simulé d'un tour d'usage type,
#   t = PP_froid/prefill + GEN/décode   (profil ci-dessous, surchargable par
#   env : BENCH_PROFILE_PP, BENCH_PROFILE_GEN ; les tokens servis par le
#   prompt cache coûtent un temps négligeable et sont ignorés).
# Un scalaire unique tranche toujours, y compris quand un device gagne le
# prefill et l'autre le décode. Le vainqueur (temps minimal ; à moins de 2 %
# d'écart, le device par défaut $DEFAULT_DEVICE est préféré, ex aequo =
# moins de surprises) est écrit dans bench-devices.conf (clé = dossier GGUF),
# ini régénéré, restart final sur la config retenue.
# Restarts via systemctl --user. Les modèles préchargés se
# rechargent à chaque restart : prévoir la durée.
# =============================================================================

# Profil d'usage simulé : tour agentic type = 2000 tokens de prefill froid
# (nouveau contexte réellement calculé) + 3000 tokens générés. Le trafic
# resservi par le prompt cache est hors profil (coût quasi nul).
BENCH_PROFILE_PP="${BENCH_PROFILE_PP:-2000}"
BENCH_PROFILE_GEN="${BENCH_PROFILE_GEN:-3000}"

# Écrit "clé = device" dans bench-devices.conf en préservant les autres lignes
_bench_save_device() {
  local key="$1" dev="$2" tmp
  tmp="$(mktemp)"
  {
    echo "; bench-devices.conf : device retenu par dossier GGUF"
    echo "; écrit par ./setup-llm.sh --bench-devices, édition manuelle OK,"
    echo "; supprimer une ligne = retour au device par défaut ($DEFAULT_DEVICE)"
    if [[ -f "$BENCH_CONF" ]]; then
      grep -v '^[;#]' "$BENCH_CONF" | grep -v "^${key}[[:space:]]*=" | grep -v '^[[:space:]]*$' || true
    fi
    echo "${key} = ${dev}"
  } > "$tmp"
  mv "$tmp" "$BENCH_CONF"
}

# Sélection interactive d'un seul modèle à comparer (gum ou fallback numéroté).
# Résultat dans BENCH_DEV_CHOICE (vide = annulé).
BENCH_DEV_CHOICE=""
_bench_select_one() {
  _bench_presets
  BENCH_DEV_CHOICE=""
  [[ ${#BENCH_PRESETS[@]} -gt 0 ]] || error "Aucun GGUF présent sous $MODELS_BASE, lancer --setup."
  if [[ ! -t 0 ]]; then
    error "Entrée non interactive : préciser le modèle (./setup-llm.sh --bench-devices <modèle>)"
  fi
  if command -v gum >/dev/null 2>&1; then
    local line
    line="$(printf '%s\n' "${BENCH_PRESETS[@]}" \
      | gum choose --height 20 --header "Modèle à comparer (entrée = valider)")" || line=""
    [[ -n "$line" ]] && BENCH_DEV_CHOICE="$line"
  else
    info "gum absent (pacman -S gum), fallback numéroté."
    echo ""
    echo "Modèles disponibles :"
    local i=1 p
    for p in "${BENCH_PRESETS[@]}"; do
      printf "  %2d  %s\n" "$i" "$p"
      ((i++))
    done
    echo ""
    local n
    read -r -p "Numéro à comparer (vide = annuler) : " n
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#BENCH_PRESETS[@]} )); then
      BENCH_DEV_CHOICE="${BENCH_PRESETS[$((n-1))]}"
    fi
  fi
}

cmd_bench_devices() {
  local preset="${1:-}"
  local devlist="${2:-Vulkan0,ROCm0}"
  local passes="${3:-$BENCH_PASSES}"

  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné, comparaison annulée."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  local gguf
  gguf="$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
  [[ -f "$gguf" ]] || error "GGUF absent pour '$preset' ($gguf), lancer --setup."
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 2 ]] || error "Nombre de passes invalide : '$passes' (minimum 2)"
  command -v curl >/dev/null || error "curl introuvable"
  command -v python3 >/dev/null || error "python3 introuvable"
  systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null \
    || error "Service $SERVICE_NAME non installé : --bench-devices doit le redémarrer entre deux devices (--install-service)."

  # Devices demandés, croisés avec ceux réellement exposés par ggml
  local -a devs=()
  local d
  IFS=',' read -r -a devs <<< "$devlist"
  export PATH="$HOME/.local/bin:$PATH"
  if command -v llama-bench >/dev/null 2>&1; then
    local exposed
    exposed="$(llama-bench --list-devices 2>/dev/null || true)"
    local -a kept=()
    for d in "${devs[@]}"; do
      if grep -q "$d" <<<"$exposed"; then
        kept+=("$d")
      else
        warn "Device '$d' non exposé (llama-bench --list-devices), exclu. Backend manquant ? (--list-devices)"
      fi
    done
    devs=("${kept[@]}")
  else
    warn "llama-bench introuvable, devices non vérifiés avant chargement."
  fi
  [[ ${#devs[@]} -ge 2 ]] || error "Moins de 2 devices à comparer, rien à faire."

  info "Comparaison '$preset' : ${devs[*]} ($passes passes chacun)"
  warn "Chaque device = régénération du ini + restart de $SERVICE_NAME (les modèles préchargés se rechargent)."
  info "Le routeur ne lit le ini qu'au démarrage : chaque device impose un restart du service user."

  # Restore garanti (Ctrl-C en pleine comparaison : config non forcée remise)
  BENCH_DEV_DIRTY=0
  _bench_devices_restore() {
    if [[ "$BENCH_DEV_DIRTY" -eq 1 ]]; then
      warn "Comparaison interrompue : régénération du ini sans device forcé + restart."
      unset BENCH_DEVICE_FORCE BENCH_DEVICE_FORCE_PRESET
      regen_models_ini
      systemctl --user restart "$SERVICE_NAME" || true
      BENCH_DEV_DIRTY=0
    fi
  }
  trap _bench_devices_restore EXIT

  local -a rows=()
  local t
  for d in "${devs[@]}"; do
    echo ""
    info "════════ device = $d ════════"
    export BENCH_DEVICE_FORCE="$d" BENCH_DEVICE_FORCE_PRESET="$preset"
    BENCH_DEV_DIRTY=1
    regen_models_ini
    systemctl --user restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      # if/fi obligatoire : "[[ ... ]] && error" retourne 1 tant que le timeout
      # n'est pas atteint et set -e tuerait la boucle à la 1re itération
      if [[ $t -ge 120 ]]; then
        error "llama-server ne répond pas après 120 s : journalctl --user -u $SERVICE_NAME -e"
      fi
    done
    if _bench_one "$preset" "$passes"; then
      # BENCH_ROW = "modèle|prefill|décode|acceptance" : le modèle est le même
      # partout, la ligne du récap porte le device
      rows+=("$d|${BENCH_ROW#*|}")
    else
      warn "  $d : mesure incomplète, exclu de la comparaison."
    fi
  done
  unset BENCH_DEVICE_FORCE BENCH_DEVICE_FORCE_PRESET

  if [[ ${#rows[@]} -eq 0 ]]; then
    _bench_devices_restore
    trap - EXIT
    error "Aucun device mesuré, pas de comparaison possible."
  fi
  if [[ ${#rows[@]} -eq 1 && ${#devs[@]} -ge 2 ]]; then
    # Un seul device a produit une mesure valide (l'autre : échec ou sortie
    # dégénérée) : ce n'est pas une comparaison, mais c'est une décision — le
    # seul device qui fonctionne est retenu, et écrit pour que le ini ne
    # retombe pas sur un défaut qui ne marche pas.
    warn "Un seul device mesuré valide (${rows[0]%%|*}) : retenu d'office, les autres ont échoué ou dégénéré."
  fi

  # Temps simulé par device : t = PP_froid/prefill + GEN/décode (le "*" d'un
  # prefill contaminé est ignoré pour le calcul mais reste visible au tableau).
  # Sortie : une ligne "TIME device secondes" par device, puis "WINNER device"
  # (temps minimal ; à moins de 2 %, le device par défaut est préféré).
  local sim winner
  sim="$(printf '%s\n' "${rows[@]}" | awk -F'|' \
    -v profpp="$BENCH_PROFILE_PP" -v profgen="$BENCH_PROFILE_GEN" -v def="$DEFAULT_DEVICE" '
    { d=$1; pp=$2; gsub(/\*/,"",pp); t[d]=profpp/(pp+0)+profgen/($3+0); order[n++]=d }
    END {
      best=order[0]
      for (i=1; i<n; i++) if (t[order[i]] < t[best]) best=order[i]
      if (def in t && t[def] <= 1.02*t[best]) best=def
      for (i=0; i<n; i++) printf "TIME %s %.1f\n", order[i], t[order[i]]
      print "WINNER " best
    }')"
  winner="$(echo "$sim" | sed -n 's/^WINNER //p')"

  echo ""
  info "════════ Comparaison $preset ($(date '+%F %T'), $passes passes, long contexte) ════════"
  {
    echo "device|prefill t/s|décode t/s|acceptance|tour simulé (s)"
    local r d t
    for r in "${rows[@]}"; do
      d="${r%%|*}"
      t="$(echo "$sim" | sed -n "s/^TIME $d //p")"
      echo "$r|$t"
    done
  } | column -t -s'|'
  info "Tour simulé : $BENCH_PROFILE_PP tokens de prefill froid + $BENCH_PROFILE_GEN générés (BENCH_PROFILE_PP/BENCH_PROFILE_GEN pour changer le profil)."

  echo ""
  local mkey before
  load_bench_conf
  mkey="$(_preset_model_key "$preset")"
  before="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE (défaut)}"
  _bench_save_device "$mkey" "$winner"
  regen_models_ini
  info "Vainqueur : $winner (tour simulé le plus court), enregistré dans $BENCH_CONF ($mkey = $winner, avant : $before), models.ini régénéré."
  info "Restart final de $SERVICE_NAME sur la config retenue..."
  systemctl --user restart "$SERVICE_NAME" || warn "Restart en échec : systemctl --user restart $SERVICE_NAME"
  BENCH_DEV_DIRTY=0
  trap - EXIT
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
