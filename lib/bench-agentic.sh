# lib/bench-agentic.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-agentic → spec → service → help
#
# Séparé de bench.sh (déjà gros) : ce bench ne mesure pas l'API en direct
# mais un client (pi) en conteneur, avec sa propre lecture des /metrics.
# Réutilise de bench.sh : _bench_select_one, _llama_build.

# =============================================================================
# bench-agentic — une vraie boucle de tool calls sur le modèle, mesurée.
#
# Usage : ./setup-llm.sh --bench-agentic [modèle] [passes]   (passes = 1 par défaut)
#
# Les autres benchs mesurent du débit sur une requête isolée ; celui-ci fait
# ce qu'un client agentic fait : pi (pi.dev) joue cinq scénarios (réponse
# simple, write+bash+read, edit, création de module + tests, correction
# d'un bug sans toucher au test) en direct sur llama-server, et chaque
# scénario donne un PASS/FAIL, son temps mur et le delta des compteurs
# /metrics?model= : tokens de prompt (dont part servie du cache : c'est là
# que le 62 % des archs récurrentes se paie), tokens générés, prefill et
# décode t/s réels sur ce trafic. pi tourne dans un conteneur jetable
# (bench-agentic/, réseau hôte) : rien sur l'hôte, ~/.pi jamais touché.
# Scénarios repris d'envTest (llm-proxy), sans le proxy. Un scénario peut
# échouer par la faute du modèle, pas du serveur : c'est le résultat, il se
# lit avec les t/s. Un appel « froid » est mesuré à part avant les passes :
# la première question de la conversation, qui paie le prompt système de
# pi (1,5 k tokens) si le serveur ne l'a pas déjà en cache-ram (mesuré
# 28/08/2026 sur Ornith : 66 % servis du cache d'un conteneur à l'autre,
# le serveur garde le préfixe ; le tout premier run avait payé 17,7 k
# tokens, artefact de première exécution de pi, non reproduit). Puis N
# passes des cinq scénarios et les médianes par scénario : à temp > 0 le
# modèle corrige un bug en un tour ou en trois (49 s contre 6,7 s sur le
# même scénario, même jour), une passe seule ne dit rien, 3 est un bon
# défaut de qualification. Journal :
# logs/bench-agentic.log (TSV, une ligne par scénario et par passe, build).
# =============================================================================
BENCH_AGENTIC_LOG="$LOG_DIR/bench-agentic.log"

cmd_bench_agentic() {
  local preset="${1:-}" passes="${2:-1}"
  command -v docker >/dev/null || error "docker introuvable (bench-agentic joue pi dans un conteneur)"
  [[ "$passes" =~ ^[1-9][0-9]*$ ]] || error "passes doit être un entier >= 1 (reçu : '$passes')"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"
  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné — bench-agentic annulé."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"

  # Le conteneur est en réseau hôte : localhost du conteneur = la machine.
  local url="${SPEC_TEST_URL/localhost/127.0.0.1}"
  info "bench-agentic '$preset' — appel froid puis $passes passe(s) de 5 scénarios pi (tool calls) en direct sur $url"
  local sortie; sortie="$(mktemp)"
  MODEL="$preset" PASSES="$passes" SERVER_URL="$url" \
    docker compose -f "$SCRIPT_DIR/bench-agentic/docker-compose.yml" run --rm --build pi 2>&1 \
    | tee "$sortie" | grep -v $'^TSV\t' || true

  # Bilan : froid à part, puis médianes par scénario sur les passes
  # (verdict = nombre de PASS / passes). Colonnes TSV du conteneur :
  # passe scénario verdict mur prompt cache gen prefill décode.
  echo ""
  info "──── bilan ($passes passe(s), médianes) ────"
  grep $'^TSV\t' "$sortie" | cut -f2- | awk -F'\t' '
    function med(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; j = i - 1; while (j > 0 && a[j] > t) { a[j+1] = a[j]; j-- } a[j+1] = t }
      return n % 2 ? a[(n+1)/2] : (a[n/2] + a[n/2+1]) / 2 }
    $1 == 0 { printf "  froid (prompt système)   : %s  %5.1f s, prompt %d tok (%d du cache), prefill %.0f t/s\n", $3, $4, $5+$6, $6, $8; next }
    { s = $2; if (!(s in n)) { ordre[++k] = s; n[s] = 0 } n[s]++
      if ($3 == "PASS") ok[s]++
      mur[s, n[s]] = $4; pt[s, n[s]] = $5 + $6; part[s, n[s]] = ($5 + $6) > 0 ? 100 * $6 / ($5 + $6) : 0
      gen[s, n[s]] = $7; pp[s, n[s]] = $8; tg[s, n[s]] = $9 }
    END { for (i = 1; i <= k; i++) { s = ordre[i]
        for (j = 1; j <= n[s]; j++) { A[j] = mur[s, j]; B[j] = pt[s, j]; C[j] = part[s, j]; D[j] = gen[s, j]; E[j] = pp[s, j]; F[j] = tg[s, j] }
        printf "  %-24s : %d/%d  %5.1f s, prompt %d tok (%.0f %% du cache), généré %d tok, prefill %.0f t/s, décode %.1f t/s\n",
          s, ok[s]+0, n[s], med(A, n[s]), med(B, n[s]), med(C, n[s]), med(D, n[s]), med(E, n[s]), med(F, n[s]) } }'

  local dev
  dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
  # date modèle device build passe scénario verdict mur_s prompt_tok cache_tok gen_tok prefill_tps decode_tps
  local build; build="$(_llama_build)"
  grep $'^TSV\t' "$sortie" | sed "s/^TSV\t/$(date '+%F %T')\t$preset\t${dev:-$DEFAULT_DEVICE}\t$build\t/" \
    >> "$BENCH_AGENTIC_LOG" 2>/dev/null || true
  rm -f "$sortie"
  return 0
}
