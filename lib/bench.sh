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

  # Journal logs/bench.log (TSV, append) :
  #   date modèle gguf device build prefill décode acceptance passes prefill_cache
  # device = état RÉEL du serveur (status.args), comme pour le n-max des spec-test ;
  # prefill_cache = 1 si la passe 1 était contaminée (le "*" du récap).
  local gguf dev
  gguf="$(basename "$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)")"
  dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
  [[ -n "$dev" ]] || dev="$DEFAULT_DEVICE"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%F %T')" "$preset" "$gguf" "$dev" "$(_llama_build)" \
    "$pp" "$med" "$acc" "$passes" "${pp_mark:+1}" >> "$BENCH_LOG" 2>/dev/null || true
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
  # Comparaison au run précédent du même (modèle, GGUF, device), toutes
  # versions de llama.cpp confondues : c'est là que se voit une régression
  # après une mise à jour du paquet.
  echo ""
  info "──── vs run précédent (logs/bench.log) ────"
  local -a benched=()
  local r
  for r in "${rows[@]}"; do benched+=("${r%%|*}"); done
  python3 "$SCRIPT_DIR/py/bench_compare.py" "$BENCH_LOG" "${benched[@]}" || true
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

# =============================================================================
# bench-cache — efficacité du cache de prompt (cache-ram, ctx-checkpoints,
# cache-reuse, slot-prompt-similarity) sur le pattern d'un client agentic.
#
# Usage : ./setup-llm.sh --bench-cache [modèle]
#
# Quatre requêtes, dans l'ordre, sur le contexte du bench (bench-context.txt) :
#   1. froid      : contexte + tâche, max_tokens 48 — remplit le cache
#   2. suite      : même contexte, tâche allongée — le préfixe doit être servi
#                   du cache (c'est le tour suivant d'une conversation)
#   3. édition    : contexte modifié AU PREMIER TIERS, même tâche — le préfixe
#                   commun (~2/3) reste au-dessus du seuil slot-prompt-similarity
#                   (0.5 dans le [*]) ; seul ce préfixe est réutilisable par
#                   restauration d'état ; au-delà, seul cache-reuse (décalage
#                   de KV) peut récupérer la suite — impossible sur GDN/état
#                   récurrent. (Première version : édition au milieu → préfixe
#                   ~45 % < 0.5 → 0 % partout, DeepSeek compris : on mesurait
#                   le seuil, pas la réutilisation. Corrigé le 21/08/2026.)
#   4. identique  : requête 1 rejouée — cache complet attendu (moins 1 token)
# Pour chaque requête : part du prompt servie par le cache et temps de
# prefill. Journal : logs/bench-cache.log (TSV, avec build).
# =============================================================================
BENCH_CACHE_LOG="$LOG_DIR/bench-cache.log"

cmd_bench_cache() {
  local preset="${1:-}"
  command -v curl >/dev/null || error "curl introuvable"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"
  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné — bench-cache annulé."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  local ctx="$SCRIPT_DIR/prompts/bench-context.txt" task="$SCRIPT_DIR/prompts/bench-task.txt"
  [[ -f "$ctx" && -f "$task" ]] || error "Prompts manquants : $ctx / $task"

  # Variantes écrites dans un dossier temporaire. Le contexte de base reçoit
  # une ligne d'horodatage en tête, commune aux quatre requêtes : sans elle,
  # un --bench-cache lancé juste après un --bench (même bench-context.txt)
  # trouve sa requête « froide » déjà en cache (100 % mesuré sur gpt-oss le
  # 21/08/2026). Puis : tâche allongée, contexte modifié au premier tiers (une
  # ligne remplacée, le reste intact).
  local tmp; tmp="$(mktemp -d)"
  { echo "(run --bench-cache $(date '+%F %T.%N'))"; cat "$ctx"; } > "$tmp/ctx.txt"
  ctx="$tmp/ctx.txt"
  { cat "$task"; echo ""; echo "Ajoute ensuite un paragraphe sur les limites de cette conception."; } > "$tmp/task-suite.txt"
  python3 - "$ctx" "$tmp/ctx-edit.txt" <<'PY'
import sys
lignes = open(sys.argv[1], encoding="utf-8").read().split("\n")
m = len(lignes) // 3
lignes[m] = "(ligne modifiée par --bench-cache : édition au premier tiers du contexte)"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lignes))
PY

  info "bench-cache '$preset' — 4 requêtes sur bench-context.txt (froid, suite, édition au milieu, identique)"
  echo ""
  local -a etiq=("1. froid" "2. suite (tour suivant)" "3. édition au 1er tiers" "4. identique à la 1re")
  local -a fichiers=("$ctx $task" "$ctx $tmp/task-suite.txt" "$tmp/ctx-edit.txt $task" "$ctx $task")
  local -a parts=() pms=()
  local i body out line pn cn ms
  for i in 0 1 2 3; do
    # shellcheck disable=SC2086
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 48 42 ${fichiers[$i]})"
    out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
      || { warn "  ${etiq[$i]} : échec curl"; parts+=("-"); pms+=("-"); continue; }
    line="$(python3 "$SCRIPT_DIR/py/cache_stats.py" "$out" "${etiq[$i]}")" || true
    echo "$line" | grep -v '^PN=\|^CN=\|^PMS='
    pn="$(echo "$line" | sed -n 's/^PN=//p')"; cn="$(echo "$line" | sed -n 's/^CN=//p')"; ms="$(echo "$line" | sed -n 's/^PMS=//p')"
    if [[ "$pn" =~ ^[0-9]+$ && "$pn" -gt 0 ]]; then
      parts+=("$(awk -v c="$cn" -v p="$pn" 'BEGIN{printf "%.0f", 100*c/p}')"); pms+=("$ms")
    else
      parts+=("-"); pms+=("-")
    fi
  done
  rm -rf "$tmp"

  echo ""
  info "──── lecture ────"
  # 2 : préfixe réutilisé ? 3 : au-delà du préfixe (cache-reuse) ? 4 : tout ?
  # Mesuré le 21/08/2026 (b10433) : tous les modèles à état récurrent (GDN
  # Qwen3.5/3.6/Next, conv LFM2) plafonnent à 62-66 % au tour suivant ET à
  # l'identique, quel que soit le tokenizer ; DeepSeek (attention pure, MLA)
  # fait 99 % et 100 %. La restauration d'état des archs récurrentes ne se
  # fait qu'à un checkpoint, pas au token près : tout ce qui suit le dernier
  # checkpoint est repayé. C'est le coût de ces architectures en boucle
  # agentic, à mettre en face de leur débit.
  [[ "${parts[1]}" != "-" ]] && { if (( parts[1] >= 80 )); then info "  suite : ${parts[1]} % servi du cache — le tour suivant d'une conversation ne repaie pas le contexte."; else warn "  suite : ${parts[1]} % seulement — arch à état récurrent : restauration au dernier checkpoint, le reste est repayé (62-66 % mesuré sur GDN/conv, 99 % sur attention pure)."; fi; }
  # Édition : 0 % mesuré PARTOUT le 21/08/2026, DeepSeek (attention pure)
  # compris, avec 2/3 de préfixe commun : le cache de prompt du serveur ne sert
  # que les continuations (prompt en cache = préfixe exact du nouveau). Un
  # résultat non nul ici serait une nouveauté côté llama-server.
  [[ "${parts[2]}" != "-" ]] && { if (( parts[2] > 70 )); then info "  édition : ${parts[2]} % — au-delà du préfixe, cache-reuse récupère la suite après l'édition."; elif (( parts[2] > 0 )); then info "  édition : ${parts[2]} % — le préfixe avant l'édition est réutilisé, pas la suite."; else info "  édition : 0 % — toute modification en amont repaie tout le contexte (le cache ne sert que les continuations ; mesuré ainsi sur toutes les archs, attention pure comprise)."; fi; }
  [[ "${parts[3]}" != "-" ]] && { if (( parts[3] >= 95 )); then info "  identique : ${parts[3]} % — cache complet."; else warn "  identique : ${parts[3]} % — même une requête identique n'est pas entièrement servie : arch à état récurrent, le cache s'arrête au dernier checkpoint."; fi; }

  local dev
  dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
  # date modèle device build part_suite part_edit part_identique ms_froid ms_suite ms_edit ms_identique
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$preset" "${dev:-$DEFAULT_DEVICE}" \
    "$(_llama_build)" "${parts[1]}" "${parts[2]}" "${parts[3]}" "${pms[0]}" "${pms[1]}" "${pms[2]}" "${pms[3]}" \
    >> "$BENCH_CACHE_LOG" 2>/dev/null || true
}

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
    t0="$(date +%s.%N)"
    curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body" -o /dev/null || true
    t1="$(date +%s.%N)"
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
# c'est le prompt système de pi (~17 k tokens, payé une fois par
# conversation) ; mesuré le 28/08/2026 sur Ornith : 7,8 s et un décode
# apparent à 31 t/s sur le scénario suivant quand il est mélangé, 70 t/s
# une fois isolé. Puis N passes des cinq scénarios et les médianes par
# scénario : à temp > 0 le modèle corrige un bug en un tour ou en trois
# (49 s contre 6,7 s sur le même scénario, même jour), une passe seule ne
# dit rien, 3 est un bon défaut de qualification. Journal :
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
