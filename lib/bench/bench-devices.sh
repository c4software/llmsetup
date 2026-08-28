# lib/bench/bench-devices.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help
#
# Sorti de bench.sh (trop gros) : --bench-devices, --bench-sanity (que devices
# applique avant chaque device) et --list-devices. Réutilise _bench_one et
# _bench_select_one de bench.sh.

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
# =============================================================================
# bench-sanity — le modèle répond-il JUSTE sur ce device ?
#
# Usage : ./setup-llm.sh --bench-sanity [modèle|all]
#
# Une tâche à réponse connue (prompts/bench-sanity.txt : recopier un code
# exact). Volontairement triviale : la première version demandait un petit
# calcul (93), que le 9b nothink a raté (33) sans que le device y soit pour
# rien — une question qui teste le modèle exclurait des devices sains. La
# recopie, tout modèle la réussit ; un backend qui dérive (noyau faux, tokens
# corrompus) la rate forcément. Le garde-fou « sortie dégénérée » de
# timings.py attrape le charabia ; celui-ci attrape un texte propre et faux.
# Appelé par --bench-devices avant chaque mesure : un device qui répond faux
# est exclu.
# =============================================================================
BENCH_SANITY_ATTENDU="LAMPADAIRE-2719"

_bench_sanity_one() {
  # $1 modèle → 0 si juste, 1 sinon (ligne lisible affichée)
  local preset="$1" body out
  # 400 tokens : un modèle qui pense d'abord doit pouvoir finir
  body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 400 7 "$SCRIPT_DIR/prompts/bench-sanity.txt")"
  out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
    || { warn "  justesse : échec curl"; return 1; }
  if python3 "$SCRIPT_DIR/py/check_answer.py" "$out" "$BENCH_SANITY_ATTENDU"; then
    return 0
  fi
  return 1
}

cmd_bench_sanity() {
  local target="${1:-}"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"
  local -a cibles=()
  if [[ "$target" == "all" ]]; then
    _bench_presets; cibles=("${BENCH_PRESETS[@]}")
  elif [[ -n "$target" ]]; then
    [[ -n "${MODEL_INI[$target]:-}" ]] || error "Modèle inconnu : '$target' (voir --help)"
    cibles=("$target")
  else
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné."; return; }
    cibles=("$BENCH_DEV_CHOICE")
  fi
  local p rc=0
  for p in "${cibles[@]}"; do
    info "── $p ──"
    _bench_sanity_one "$p" || rc=1
  done
  return $rc
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
    # Justesse d'abord : un device qui répond faux (texte propre mais dérive
    # numérique) ne doit pas entrer dans la comparaison, ses t/s sont sans objet.
    if ! _bench_sanity_one "$preset"; then
      warn "  $d : réponse fausse à la question de contrôle — device exclu."
      continue
    fi
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
