# lib/bench/bench-parallel.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help
# Sorti de bench.sh (trop gros). Réutilise _bench_select_one de bench.sh.

# =============================================================================
# bench-parallel — débit sous requêtes simultanées
#
# Usage : ./setup-llm.sh --bench-parallel [modèle] [n] [passes]
#   n = nombre de requêtes simultanées (défaut : le parallel du modèle, min 2),
#   passes = répétitions de la salve (défaut 2, médiane).
#
# Mesure N = 1 puis N = n sur le même prompt (spec-test.txt, seeds distincts,
# 400 tokens) : débit agrégé (tokens / temps mur) et décode médian par requête.
# Le `parallel` RÉEL du serveur est lu sur /v1/models : au-delà, les requêtes
# sont mises en file par le routeur et l'agrégat n'augmente plus, c'est
# visible dans le tableau. Ne mesure que le décode (le prompt est servi par
# le cache dès la 2e requête, slot-prompt-similarity).
# Journal : logs/bench-parallel.log (TSV, avec build).
# =============================================================================
BENCH_PARALLEL_LOG="$LOG_DIR/bench-parallel.log"

_bench_parallel_salve() {
  # $1 modèle, $2 nombre de requêtes, $3 n° de salve → AGG/MED via PAR_AGG PAR_MED
  local preset="$1" n="$2" salve="$3" i tmp body t0 t1 mur
  tmp="$(mktemp -d)"
  local -a pids=()
  t0="$(date +%s.%N)"
  for (( i=1; i<=n; i++ )); do
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 400 $((100 * salve + i)) "$SCRIPT_DIR/prompts/spec-test.txt")"
    curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' \
      -d "$body" -o "$tmp/$i.json" &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
  t1="$(date +%s.%N)"
  mur="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.2f", b-a}')"
  local line
  line="$(python3 "$SCRIPT_DIR/py/parallel_agg.py" "$mur" "$tmp"/*.json)" || true
  echo "$line" | grep -v '^AGG=\|^MED=\|^TOK=\|^ERR='
  PAR_AGG="$(echo "$line" | sed -n 's/^AGG=//p')"
  PAR_MED="$(echo "$line" | sed -n 's/^MED=//p')"
  PAR_ERR="$(echo "$line" | sed -n 's/^ERR=//p')"
  rm -rf "$tmp"
  return 0
}

cmd_bench_parallel() {
  local preset="${1:-}" n="${2:-}" passes="${3:-2}"
  command -v curl >/dev/null || error "curl introuvable"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"
  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné — bench-parallel annulé."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 1 ]] || error "Passes invalide : '$passes'"

  # parallel réel côté serveur (status.args), sinon celui du script
  local par_srv par_cfg
  par_srv="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --parallel 2>/dev/null || true)"
  par_cfg="$(echo "${MODEL_INI[$preset]}" | sed -n 's/^parallel[[:space:]]*=[[:space:]]*//p' | tr -d ' ')"
  local par="${par_srv:-${par_cfg:-1}}"
  if [[ -z "$n" ]]; then
    n="$par"; (( n >= 2 )) || n=2
  fi
  [[ "$n" =~ ^[0-9]+$ && "$n" -ge 2 ]] || error "n invalide : '$n' (>= 2)"

  info "bench-parallel '$preset' — parallel serveur = $par$( [[ -n "$par_srv" ]] || echo " (script)" ), salves de 1 puis $n requêtes, $passes passe(s) chacune"
  (( n > par )) && warn "n ($n) > parallel ($par) : les requêtes au-delà font la queue, l'agrégat ne montera pas."
  # chauffe : charge le modèle et amorce le cache de prompt
  local body
  body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 16 1 "$SCRIPT_DIR/prompts/spec-test.txt")"
  curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" -o /dev/null || true

  local -a aggs=() meds=()
  local k s med_agg med_med agg1="" med1=""
  for k in 1 "$n"; do
    echo ""
    info "──── $k requête(s) simultanée(s) ────"
    aggs=(); meds=()
    for (( s=1; s<=passes; s++ )); do
      _bench_parallel_salve "$preset" "$k" "$s"
      [[ "${PAR_ERR:-0}" -eq 0 && -n "$PAR_AGG" ]] && { aggs+=("$PAR_AGG"); meds+=("$PAR_MED"); }
    done
    [[ ${#aggs[@]} -gt 0 ]] || { warn "Aucune salve valide à $k requête(s)."; continue; }
    med_agg="$(printf '%s\n' "${aggs[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
    med_med="$(printf '%s\n' "${meds[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
    if [[ "$k" -eq 1 ]]; then
      agg1="$med_agg"; med1="$med_med"
      info "  → 1 requête : $med_agg t/s"
    else
      local ratio
      ratio="$(awk -v a="$med_agg" -v b="$agg1" 'BEGIN{ if (b>0) printf "%.2f", a/b; else print "?" }')"
      info "  → $k requêtes : agrégé $med_agg t/s (x$ratio vs 1 requête), décode par requête $med_med t/s (1 requête : $med1)"
      if awk -v r="$ratio" 'BEGIN{exit !(r < 1.2)}'; then
        warn "  Pas de gain d'agrégat : le serveur sérialise (parallel $par) ou le modèle est borné compute."
      fi
    fi
    local dev
    dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
      | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
    # date modèle device build parallel_srv n agrégé décode_par_requête passes
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$preset" "${dev:-$DEFAULT_DEVICE}" \
      "$(_llama_build)" "$par" "$k" "$med_agg" "$med_med" "$passes" >> "$BENCH_PARALLEL_LOG" 2>/dev/null || true
  done
}
