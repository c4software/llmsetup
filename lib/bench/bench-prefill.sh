# lib/bench/bench-prefill.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → bench-prefill → spec → service → help
# Réutilise de bench.sh : _bench_select_one ; de common.sh : _llama_build, _ec_power_mode.

# =============================================================================
# bench-prefill — prefill à froid en profondeur, tel que servi, par l'API
#
# Usage : ./setup-llm.sh --bench-prefill [modèle] [tailles] [passes]
#         (tailles = tokens visés, séparés par des virgules,
#          défaut 1000,4000,16000,32000,65000 ; passes = 2 par défaut)
#
# Le --bench mesure un prefill de ~1 400 tokens : c'est le tour agentic
# typique, et c'est trop court pour départager deux moteurs ou deux micro-lots
# (base et large-ub de Flash-Next y font pareil, 627 à 669 t/s le 22/09/2026),
# et trop sensible à l'état du serveur (un --bench-cache juste avant, même
# prompt, a fait croire à 835 t/s le 18/09). tools/bench-depth.sh trace la
# courbe par llama-bench, service arrêté, sur le GGUF nu. Cette commande
# mesure la SECTION telle que le routeur la sert (drafter, mmproj, micro-lot,
# lazy-mode compris), à froid : chaque requête a un contenu unique et refuse
# le cache de prompt, et une requête dont le serveur a quand même servi une
# part du cache, ou qui ne génère rien, est exclue des médianes (garde-fou du
# 835). C'est la mesure où halogen-flash-server garde 12 à 24 % au-delà de
# 20 k tokens (22/09/2026, cf. docs/HISTORIQUE.md), invisible au --bench.
#
# Lecture : la courbe doit être plate ou montante avec la taille sur les archs
# à attention sparse (Flash-Next), descendante sur une attention dense. Ne se
# compare qu'à ubatch ET mode EC égaux (les deux sont en colonne du journal) :
# le micro-lot fait +12 % à lui seul sur Flash-Next, le mode EC 10 à 13 %.
# Journal : logs/bench-prefill.log (TSV, une ligne par requête, build).
# =============================================================================
BENCH_PREFILL_LOG="$LOG_DIR/bench-prefill.log"

cmd_bench_prefill() {
  local preset="${1:-}" tailles="${2:-1000,4000,16000,32000,65000}" passes="${3:-2}"
  [[ "$passes" =~ ^[1-9][0-9]*$ ]] || error "passes doit être un entier >= 1 (reçu : '$passes')"
  [[ "$tailles" =~ ^[0-9]+(,[0-9]+)*$ ]] || error "tailles : entiers séparés par des virgules (reçu : '$tailles')"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL - ./setup-llm.sh --start"
  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné — bench-prefill annulé."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"

  # Chargement à la demande AVANT la mesure : la première requête ne doit pas
  # porter le temps de chargement du modèle.
  info "bench-prefill '$preset' — chargement (requête d'amorce)..."
  curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' \
    -d "{\"model\":\"$preset\",\"messages\":[{\"role\":\"user\",\"content\":\"Réponds OK\"}],\"max_tokens\":4}" \
    -o /dev/null || true

  # ubatch et device RÉELS (status.args), jamais le ini : le routeur ne le
  # relit qu'au démarrage.
  local dev ub build ec
  dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
  ub="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --ubatch-size 2>/dev/null || true)"
  build="$(_llama_build)"; ec="$(_ec_power_mode)"
  info "Moteur : $build, device ${dev:-$DEFAULT_DEVICE}, ubatch ${ub:-défaut}, mode EC : $ec"

  # Tailles au-delà du contexte RÉEL de la section (status.args --ctx-size,
  # que le moteur peut avoir plafonné à n_ctx_train) : sautées, avec un mot.
  # Le tokenizer déborde d'environ 3 à 5 % sur la cible (3 caractères par
  # token visés), d'où la marge de 20 % avant de refuser une taille.
  local ctx t; local -a gardees=()
  ctx="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --ctx-size 2>/dev/null || true)"
  for t in ${tailles//,/ }; do
    if [[ -n "$ctx" ]] && (( t * 12 / 10 + 64 > ctx )); then
      warn "  taille $t sautée : contexte servi de $ctx tokens (status.args)."
    else
      gardees+=("$t")
    fi
  done
  [[ ${#gardees[@]} -gt 0 ]] || error "Aucune taille ne tient dans le contexte servi ($ctx tokens)."
  tailles="$(IFS=,; echo "${gardees[*]}")"
  info "Tailles $tailles tokens, $passes passe(s) chacune, contenu unique, cache de prompt refusé."

  local sortie; sortie="$(mktemp)"
  python3 "$SCRIPT_DIR/py/bench_prefill.py" mesure "$SPEC_TEST_URL" "$preset" "$passes" "$tailles" \
      "$SCRIPT_DIR/docs/HISTORIQUE.md" "$SCRIPT_DIR/lib/models.sh" "$SCRIPT_DIR/README.md" "$SCRIPT_DIR/ARCHITECTURE.md" \
    | tee "$sortie" | grep -v $'^TSV\t' | column -t -s$'\t' || true

  echo ""
  info "──── bilan ($passes passe(s), médianes sur les passes saines) ────"
  grep $'^TSV\t' "$sortie" | python3 "$SCRIPT_DIR/py/bench_prefill.py" bilan | grep -v '^MED=' || true
  echo "  (une passe est exclue si le serveur a servi une part du cache ou si la réponse est vide)"
  echo "  Ne comparer qu'à ubatch (${ub:-défaut}) et mode EC ($ec) égaux."

  # Journal, 13 colonnes : date modèle device build ubatch cible passe prompt_n
  # prompt_ms prefill_tps cache_n sain ec_mode
  grep $'^TSV\t' "$sortie" \
    | sed "s/^TSV\t/$(date '+%F %T')\t$preset\t${dev:-$DEFAULT_DEVICE}\t$build\t${ub:-défaut}\t/; s/\$/\t$ec/" \
    >> "$BENCH_PREFILL_LOG" 2>/dev/null || true
  rm -f "$sortie"
  return 0
}
