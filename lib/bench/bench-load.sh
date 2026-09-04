# lib/bench/bench-load.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help
# Sorti de bench.sh (trop gros). Réutilise _bench_select_presets de bench.sh.

# =============================================================================
# bench-load — temps de chargement d'un modèle et premier token
#
# Usage : ./setup-llm.sh --bench-load [modèle|all]
#
# Pour chaque modèle : restart du service (tout est évincé), puis une requête
# d'un token chronométrée de bout en bout = chargement des poids + premier
# token ; puis la même requête à chaud = temps de premier token (TTFT) seul.
# Base objective pour preload.conf (ce que coûte un modèle à la demande) et
# pour --models-max (une bascule LRU = ce temps-là). « Froid » s'entend pour
# le processus : le fichier peut rester dans le cache de pages du noyau (124 Go
# de RAM), le disque n'est pas forcément relu — le chiffre reflète l'usage réel
# (bascule entre modèles), pas un démarrage machine.
# Journal : logs/bench-load.log (TSV, avec build).
# =============================================================================
BENCH_LOAD_LOG="$LOG_DIR/bench-load.log"

cmd_bench_load() {
  local target="${1:-}"
  systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null \
    || error "Service $SERVICE_NAME non installé — --bench-load redémarre le service entre deux modèles (--install-service)."
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
  warn "Chaque modèle = restart de $SERVICE_NAME (les modèles préchargés se rechargent ensuite)."
  local p body t0 t1 froid chaud gguf taille dev t
  local -a rows=()
  for p in "${cibles[@]}"; do
    echo ""
    info "── $p ──"
    systemctl --user restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 1; t=$((t+1))
      if [[ $t -ge 120 ]]; then error "llama-server ne répond pas après 120 s"; fi
    done
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$p" 1 7 "$SCRIPT_DIR/prompts/bench-sanity.txt")"
    local code
    t0="$(date +%s.%N)"
    code="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" \
      -o /dev/null -w '%{http_code}' || echo 000)"
    t1="$(date +%s.%N)"
    # Un modèle que le build ne sait pas charger (arch absente de libllama)
    # répond une erreur en une fraction de seconde : ne pas journaliser ce
    # temps comme un chargement. _bench_presets ne filtre que sur le GGUF.
    if [[ "$code" != 200 ]]; then
      warn "  '$p' : le routeur n'a pas chargé le modèle (HTTP $code), exclu du récap."
      continue
    fi
    froid="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
    t0="$(date +%s.%N)"
    curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" -o /dev/null || true
    t1="$(date +%s.%N)"
    chaud="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.0f", (b-a)*1000}')"
    gguf="$(echo "${MODEL_INI[$p]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
    # taille = le GGUF déclaré, ou ses shards (pas le dossier : il peut contenir
    # une autre quant, orpheline ou non)
    if [[ "$gguf" =~ ^(.*)-00001-of-([0-9]+)\.gguf$ ]]; then
      taille="$(du -shLc "${BASH_REMATCH[1]}"-*-of-"${BASH_REMATCH[2]}".gguf 2>/dev/null | tail -1 | cut -f1 || echo '?')"
    else
      taille="$(du -shL "$gguf" 2>/dev/null | cut -f1 || echo '?')"
    fi
    dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
      | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$p" --device 2>/dev/null || true)"
    info "  chargement + 1er token : $froid s ($taille, ${dev:-$DEFAULT_DEVICE}) ; à chaud : $chaud ms"
    rows+=("$p|$taille|${dev:-$DEFAULT_DEVICE}|$froid|$chaud")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$p" "$(basename "$gguf")" "${dev:-$DEFAULT_DEVICE}" \
      "$(_llama_build)" "$taille" "$froid" "$chaud" >> "$BENCH_LOAD_LOG" 2>/dev/null || true
  done
  echo ""
  info "════════ Chargement ($(date '+%F %T')) ════════"
  {
    echo "modèle|taille|device|chargement + 1er token (s)|TTFT à chaud (ms)"
    printf '%s\n' "${rows[@]}"
  } | column -t -s'|'
  info "Restart final de $SERVICE_NAME (retour aux modèles préchargés)..."
  systemctl --user restart "$SERVICE_NAME" || warn "Restart en échec : systemctl --user restart $SERVICE_NAME"
}
