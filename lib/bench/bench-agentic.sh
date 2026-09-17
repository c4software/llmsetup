# lib/bench/bench-agentic.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help
#
# Séparé de bench.sh (déjà gros) : ce bench ne mesure pas l'API en direct
# mais un client (pi) en conteneur, avec sa propre lecture des /metrics.
# Réutilise de bench.sh : _bench_select_one, _llama_build.

# =============================================================================
# bench-agentic — une vraie boucle de tool calls sur le modèle, mesurée.
#
# Usage : ./setup-llm.sh --bench-agentic [modèle] [passes] [N]
#         (passes = 1 par défaut, N = 1 boucle par défaut)
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
#
# 3e argument, N > 1 — le cas réel : un orchestrateur et ses sous-agents
# tapent le même modèle EN MÊME TEMPS (2 à 3 slots simultanés observés sur
# Ornith). En série, un modèle à `parallel = 3` a l'air aussi bon qu'à
# `parallel = 1` : c'est faux dès qu'il sert trois boucles. À N > 1, chaque
# passe joue donc la suite DEUX fois : une fois seule (référence solo de la
# même exécution, même build, même cache) puis une fois à N conteneurs pi
# simultanés, chacun dans son /work jetable. On en tire le facteur de débit
# de tâches, (N × temps solo) / temps parallèle : x1 = le serveur sérialise
# (les boucles se mettent en file), xN = le batch absorbe les N boucles pour
# le prix d'une. Le décode et le prefill agrégés de la salve sont lus sur
# /metrics?model= côté hôte, avant et après (les deltas des N conteneurs se
# recouvrent dans le temps : leurs t/s ne s'additionnent pas, le compteur du
# serveur, lui, est juste). Même raison côté tableau de la salve : chaque
# conteneur lit le compteur GLOBAL du serveur, donc ses colonnes prompt,
# cache, généré, prefill et décode compteraient aussi le trafic des autres
# instances (creation : 76 k tokens de prompt à 3 boucles contre 21 k en
# solo, constaté le 15/09/2026 sur bigchuck) : elles sortent en « n/c »,
# seuls PASS et temps mur restent par scénario. N n'est pas plafonné,
# seulement comparé au `parallel` RÉEL lu sur /v1/models → status.args (jamais le ini, que le
# routeur ne relit qu'au démarrage) : au-delà, warn, et la file d'attente se
# voit dans le facteur. N = 1 (défaut) est le chemin historique, inchangé.
# =============================================================================
BENCH_AGENTIC_LOG="$LOG_DIR/bench-agentic.log"

# Conteneurs de la salve en cours, pour le trap Ctrl-C (docker compose run
# détaché de son shell survivrait au SIGINT : on les tue nommément).
_BENCH_AGENTIC_NOMS=()

_bench_agentic_nettoie() {
  local c
  for c in ${_BENCH_AGENTIC_NOMS[@]+"${_BENCH_AGENTIC_NOMS[@]}"}; do
    docker rm -f "$c" >/dev/null 2>&1 || true
  done
  _BENCH_AGENTIC_NOMS=()
  return 0
}

# Médianes par scénario, sur stdin : les lignes TSV du conteneur déjà
# débarrassées du marqueur (passe scénario verdict mur prompt cache gen
# prefill décode). Sert au bilan solo comme au bilan parallèle.
#
# 1er argument non vide = lignes d'une salve à N > 1 : les colonnes venant
# de /metrics (prompt, part du cache, généré, prefill, décode) sont lues par
# CHAQUE conteneur sur le compteur global du serveur, donc chacun compte
# aussi le trafic des N-1 autres (creation : 76 k tokens de prompt à 3
# boucles contre 21 k en solo, artefact de recouvrement). Elles sortent en
# « n/c » : seuls PASS et temps mur sont propres par scénario, les t/s de la
# salve se lisent sur la ligne de bilan agrégée (compteurs pris côté hôte
# avant et après la salve).
_bench_agentic_medianes() {
  awk -F'\t' -v recouvert="${1:-}" '
    function med(a, n,   i, j, t) { for (i = 2; i <= n; i++) { t = a[i]; j = i - 1; while (j > 0 && a[j] > t) { a[j+1] = a[j]; j-- } a[j+1] = t }
      return n % 2 ? a[(n+1)/2] : (a[n/2] + a[n/2+1]) / 2 }
    $1 == 0 { printf "  froid (prompt système)   : %s  %5.1f s, prompt %d tok (%d du cache), prefill %.0f t/s\n", $3, $4, $5+$6, $6, $8; next }
    { s = $2; if (!(s in n)) { ordre[++k] = s; n[s] = 0 } n[s]++
      if ($3 == "PASS") ok[s]++
      mur[s, n[s]] = $4; pt[s, n[s]] = $5 + $6; part[s, n[s]] = ($5 + $6) > 0 ? 100 * $6 / ($5 + $6) : 0
      gen[s, n[s]] = $7; pp[s, n[s]] = $8; tg[s, n[s]] = $9 }
    END { for (i = 1; i <= k; i++) { s = ordre[i]
        for (j = 1; j <= n[s]; j++) { A[j] = mur[s, j]; B[j] = pt[s, j]; C[j] = part[s, j]; D[j] = gen[s, j]; E[j] = pp[s, j]; F[j] = tg[s, j] }
        if (recouvert != "") {
          printf "  %-24s : %d/%d  %5.1f s, prompt n/c, cache n/c, généré n/c, prefill n/c, décode n/c\n",
            s, ok[s]+0, n[s], med(A, n[s]); continue }
        printf "  %-24s : %d/%d  %5.1f s, prompt %d tok (%.0f %% du cache), généré %d tok, prefill %.0f t/s, décode %.1f t/s\n",
          s, ok[s]+0, n[s], med(A, n[s]), med(B, n[s]), med(C, n[s]), med(D, n[s]), med(E, n[s]), med(F, n[s]) } }'
}

# Compteurs cumulés de llama-server pour un modèle : "pt pc gt ps gs"
# (mêmes compteurs que snap() dans bench-agentic/scenarios.sh, mais lus
# depuis l'hôte, autour de la salve entière).
_bench_agentic_metrics() {
  curl -s "$SPEC_TEST_URL/metrics?model=$1" 2>/dev/null | awk '
    /^llamacpp:prompt_tokens_total /{pt=$2} /^llamacpp:prompt_tokens_cached_total /{pc=$2}
    /^llamacpp:tokens_predicted_total /{gt=$2} /^llamacpp:prompt_seconds_total /{ps=$2}
    /^llamacpp:tokens_predicted_seconds_total /{gs=$2}
    END{printf "%s %s %s %s %s", pt+0, pc+0, gt+0, ps+0, gs+0}'
}

# Nom du conteneur d'une instance : explicite (PID du shell, passe, instance)
# pour que le trap Ctrl-C puisse le tuer. Enregistré par l'appelant AVANT le
# lancement : `_bench_agentic_run &` s'exécute dans un sous-shell, un
# `+=` fait là-dedans ne remonterait pas.
_bench_agentic_nom() { echo "bench-agentic-$$-p$1-i$2"; }

# Un conteneur pi jetable : _bench_agentic_run <modèle> <url> <sortie>
#   <nom> <passe> <froid 0|1> <passes internes> [instance]
# -T : la sortie part dans un fichier, pas de TTY en tâche de fond.
# INSTANCE (8e argument, mode parallèle seulement) sert à l'en-tête du
# conteneur : à N > 1 chacun joue PASSES=1 avec le numéro de la passe réelle,
# « passe 2/1 » n'avait pas de sens.
_bench_agentic_run() {
  local preset="$1" url="$2" sortie="$3" nom="$4" passe="$5" froid="$6" passes="$7" inst="${8:-}"
  MODEL="$preset" PASSES="$passes" PASSE_NUM="$passe" FROID="$froid" INSTANCE="$inst" SERVER_URL="$url" \
    docker compose -f "$SCRIPT_DIR/bench-agentic/docker-compose.yml" \
      run --rm -T --name "$nom" pi >"$sortie" 2>&1 || true
  return 0
}

# Médiane d'une liste de nombres passés en arguments (convention awk du dépôt).
_bench_agentic_med() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'
}

# Ajoute au journal les lignes TSV d'un fichier : préfixe date/modèle/device/
# build (comme avant) et colonne N en QUEUE de ligne — les lignes d'avant le
# 15/09/2026, à 13 colonnes, restent lisibles telles quelles.
# _bench_agentic_journal <fichier> <modèle> <device> <build> <N>
#
# N > 1 : les cinq colonnes /metrics du conteneur (prompt_tok, cache_tok,
# gen_tok, prefill_tps, decode_tps) comptent le trafic des N instances
# simultanées, pas celui du scénario : elles sont écrites « n/c » plutôt que
# fausses. Format inchangé à 14 colonnes, passe/scénario/verdict/mur_s
# restent justes ; les lignes de la référence solo passent ici avec N = 1 et
# gardent leurs chiffres.
_bench_agentic_journal() {
  if (( ${5:-1} > 1 )); then
    grep $'^TSV\t' "$1" \
      | awk -F'\t' -v OFS='\t' '{ for (i = 6; i <= 10; i++) $i = "n/c"; print }' \
      | sed "s/^TSV\t/$(date '+%F %T')\t$2\t$3\t$4\t/; s/\$/\t$5/" \
      >> "$BENCH_AGENTIC_LOG" 2>/dev/null || true
    return 0
  fi
  grep $'^TSV\t' "$1" \
    | sed "s/^TSV\t/$(date '+%F %T')\t$2\t$3\t$4\t/; s/\$/\t$5/" \
    >> "$BENCH_AGENTIC_LOG" 2>/dev/null || true
  return 0
}

cmd_bench_agentic() {
  local preset="${1:-}" passes="${2:-1}" n="${3:-1}"
  command -v docker >/dev/null || error "docker introuvable (bench-agentic joue pi dans un conteneur)"
  [[ "$passes" =~ ^[1-9][0-9]*$ ]] || error "passes doit être un entier >= 1 (reçu : '$passes')"
  [[ "$n" =~ ^[1-9][0-9]*$ ]] || error "N doit être un entier >= 1 (reçu : '$n')"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL - ./setup-llm.sh --start"
  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné — bench-agentic annulé."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"

  # Le conteneur est en réseau hôte : localhost du conteneur = la machine.
  local url="${SPEC_TEST_URL/localhost/127.0.0.1}"
  local dev
  dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
  local build; build="$(_llama_build)"

  if (( n > 1 )); then
    _bench_agentic_parallele "$preset" "$passes" "$n" "$url" "${dev:-$DEFAULT_DEVICE}" "$build"
    return 0
  fi

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
  grep $'^TSV\t' "$sortie" | cut -f2- | _bench_agentic_medianes

  # Format du journal, 14 colonnes :
  #   date modèle device build passe scénario verdict mur_s prompt_tok
  #   cache_tok gen_tok prefill_tps decode_tps N
  # Les cinq colonnes prompt_tok..decode_tps valent « n/c » sur les lignes
  # d'une salve à N > 1 (compteurs /metrics recouverts entre instances) ;
  # elles sont justes ici (N = 1) et sur les lignes solo du mode parallèle.
  _bench_agentic_journal "$sortie" "$preset" "${dev:-$DEFAULT_DEVICE}" "$build" 1
  rm -f "$sortie"
  return 0
}

# Mode parallèle (N > 1) : par passe, la suite jouée seule puis la même suite
# jouée par N conteneurs pi simultanés. Voir l'en-tête du fichier pour le
# pourquoi. _bench_agentic_parallele <modèle> <passes> <N> <url> <device> <build>
_bench_agentic_parallele() {
  local preset="$1" passes="$2" n="$3" url="$4" dev="$5" build="$6"

  # parallel RÉEL du serveur (status.args), sinon celui du script : au-delà,
  # les boucles supplémentaires font la queue, le facteur ne montera plus.
  local par_srv par_cfg par
  par_srv="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --parallel 2>/dev/null || true)"
  par_cfg="$(echo "${MODEL_INI[$preset]}" | sed -n 's/^parallel[[:space:]]*=[[:space:]]*//p' | tr -d ' ')"
  par="${par_srv:-${par_cfg:-1}}"

  info "bench-agentic '$preset' — parallel serveur = $par$( [[ -n "$par_srv" ]] || echo " (script)" ), appel froid puis $passes passe(s) : suite solo puis $n boucles pi simultanées sur $url"
  if (( n > par )); then
    warn "N ($n) > parallel ($par) : les boucles au-delà font la queue côté serveur, le facteur de débit de tâches ne montera pas."
  fi

  # Image construite une fois : N `run --build` simultanés se battraient
  # pour le même build.
  info "Construction de l'image pi (une fois pour les $n instances)…"
  docker compose -f "$SCRIPT_DIR/bench-agentic/docker-compose.yml" build pi >/dev/null \
    || error "docker compose build a échoué (bench-agentic/)"

  # Ctrl-C : tuer les conteneurs de la salve en cours avant de sortir.
  trap '_bench_agentic_nettoie; error "bench-agentic interrompu"' INT TERM

  local tmp; tmp="$(mktemp -d)"
  local tous_solo="$tmp/solo.tsv" tous_par="$tmp/par.tsv"
  : >"$tous_solo"; : >"$tous_par"

  # Appel froid, une fois, seul (PASSES=0 : le conteneur ne joue que le
  # scénario 0). Il amorce aussi le prompt système dans le cache du serveur,
  # comme en usage réel.
  _BENCH_AGENTIC_NOMS=("$(_bench_agentic_nom 0 0)")
  _bench_agentic_run "$preset" "$url" "$tmp/froid.out" "${_BENCH_AGENTIC_NOMS[0]}" 0 1 0
  grep -v $'^TSV\t' "$tmp/froid.out" || true
  grep $'^TSV\t' "$tmp/froid.out" | cut -f2- >>"$tous_solo" || true
  _bench_agentic_journal "$tmp/froid.out" "$preset" "$dev" "$build" 1

  local -a solos=() paras=() facteurs=() decs=()
  local p i f t0 t1 mur m0 m1 ok
  for (( p=1; p<=passes; p++ )); do
    echo ""
    info "──── passe $p/$passes : suite solo (référence) ────"
    _BENCH_AGENTIC_NOMS=("$(_bench_agentic_nom "$p" 0)")
    t0="$(date +%s.%N)"
    _bench_agentic_run "$preset" "$url" "$tmp/solo-$p.out" "${_BENCH_AGENTIC_NOMS[0]}" "$p" 0 1
    t1="$(date +%s.%N)"
    mur="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
    solos+=("$mur")
    grep -v $'^TSV\t' "$tmp/solo-$p.out" || true
    grep $'^TSV\t' "$tmp/solo-$p.out" | cut -f2- >>"$tous_solo" || true
    _bench_agentic_journal "$tmp/solo-$p.out" "$preset" "$dev" "$build" 1
    info "  suite solo : $mur s de temps mur"

    echo ""
    info "──── passe $p/$passes : $n boucles simultanées ────"
    _BENCH_AGENTIC_NOMS=()
    local -a pids=()
    m0="$(_bench_agentic_metrics "$preset")"
    t0="$(date +%s.%N)"
    for (( i=1; i<=n; i++ )); do
      _BENCH_AGENTIC_NOMS+=("$(_bench_agentic_nom "$p" "$i")")
      _bench_agentic_run "$preset" "$url" "$tmp/par-$p-$i.out" "${_BENCH_AGENTIC_NOMS[-1]}" "$p" 0 1 "$i" &
      pids+=($!)
    done
    wait "${pids[@]}" 2>/dev/null || true
    t1="$(date +%s.%N)"
    m1="$(_bench_agentic_metrics "$preset")"
    mur="$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.1f", b-a}')"
    paras+=("$mur")

    # PASS par instance : chaque conteneur a joué les mêmes 5 scénarios.
    for (( i=1; i<=n; i++ )); do
      f="$tmp/par-$p-$i.out"
      ok="$(awk -F'\t' '$1 == "TSV" && $4 == "PASS"' "$f" | wc -l)"
      info "  instance $i : $ok/5 PASS"
      grep $'^TSV\t' "$f" | cut -f2- >>"$tous_par" || true
      _bench_agentic_journal "$f" "$preset" "$dev" "$build" "$n"
    done

    # Agrégats de la salve, compteurs du serveur pris avant/après : les
    # deltas des N conteneurs se recouvrent, seule cette lecture est juste.
    # Décode agrégé = tokens générés / temps mur (le débit de la machine) ;
    # décode par boucle = le rapport tokens/secondes du serveur, ce que voit
    # une boucle. Prefill idem.
    local dec_agg dec_boucle pp_agg part_agg gen_agg
    read -r dec_agg dec_boucle pp_agg part_agg gen_agg <<<"$(echo "$m0 $m1 $mur" | awk '{
      pt=$6-$1; pc=$7-$2; gt=$8-$3; ps=$9-$4; gs=$10-$5; mur=$11
      part=(pt+pc)>0 ? 100*pc/(pt+pc) : 0
      printf "%.1f %.1f %.0f %.0f %.0f", (mur>0?gt/mur:0), (gs>0?gt/gs:0), (ps>0?pt/ps:0), part, gt }')"
    decs+=("$dec_agg")
    info "  $n boucles : $mur s de temps mur, décode agrégé $dec_agg t/s (par boucle $dec_boucle t/s), prefill $pp_agg t/s, $part_agg % du prompt servi du cache, $gen_agg tokens générés"
    facteurs+=("$(awk -v n="$n" -v s="${solos[-1]}" -v q="$mur" 'BEGIN{printf "%.2f", (q>0 ? n*s/q : 0)}')")
  done

  trap - INT TERM

  echo ""
  info "──── bilan solo, appel froid compris ($passes passe(s), médianes) ────"
  _bench_agentic_medianes <"$tous_solo"
  echo ""
  info "──── bilan à $n boucles simultanées ($passes passe(s) × $n instances, médianes) ────"
  _bench_agentic_medianes recouvert <"$tous_par"
  echo "  n/c : prompt, cache, généré, prefill et décode sont lus sur les compteurs"
  echo "        globaux du serveur par chacune des $n instances : chaque scénario y"
  echo "        compterait aussi le trafic des autres. PASS et temps mur sont propres"
  echo "        par scénario ; les t/s de la salve sont la ligne de bilan ci-dessous."

  local med_solo med_par med_fact med_dec
  med_solo="$(_bench_agentic_med "${solos[@]}")"
  med_par="$(_bench_agentic_med "${paras[@]}")"
  med_fact="$(_bench_agentic_med "${facteurs[@]}")"
  med_dec="$(_bench_agentic_med "${decs[@]}")"
  echo ""
  info "  → $n boucles : temps mur $med_par s contre $med_solo s en solo, soit x$med_fact de débit de tâches, décode agrégé $med_dec t/s"
  if awk -v r="$med_fact" 'BEGIN{exit !(r < 1.2)}'; then
    warn "  Pas de gain : le serveur sérialise les boucles (parallel $par) ou le modèle est borné compute."
  fi

  rm -rf "$tmp"
  return 0
}
