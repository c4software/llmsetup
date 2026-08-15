# lib/spec.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

# =============================================================================
# spec-test — mesure le décode réel d'un modèle via l'API (chemin spéculatif
# inclus, contrairement à --bench qui ne mesure que le forward standard)
#
# Usage : ./setup-llm.sh --spec-test [modèle] [passes]
#   modèle : sans argument, sélection interactive parmi les modèles MTP dont
#            le GGUF est présent (gum ou fallback numéroté ; non interactif =
#            premier de la liste) ; passes : défaut 4 (1 froide + 3 utiles)
#
# Envoie N fois le même prompt (module Python + tests pytest, ~1-1.5K tokens
# de sortie, code structuré = meilleur cas MTP), seed fixe par passe (42+i :
# reproductible d'un run à l'autre, sortie identique quel que soit le n-max
# puisque la spéculation est sans perte → comparaisons sans bruit de sampling,
# tout en couvrant plusieurs trajectoires), et affiche prompt/gen t/s
# depuis `timings` de llama-server, plus l'acceptance MTP (draft_n_accepted /
# draft_n, renvoyés dans le même `timings` — pas besoin de journalctl). La 1re
# passe est marquée (cache froid), comparer les médianes des suivantes.
# L'en-tête reprend tout le contexte (host, versions llama-cpp/ggml, GGUF,
# device, corps du modèle) pour que le bloc soit auto-suffisant à partager.
# Chaque run est journalisé dans spec-tests.log (les runs incohérents —
# tokens/forward > plafond, ini changé sans restart — sont mis en quarantaine
# automatiquement, lignes commentées) ; dès 2 runs valides à des n-max
# différents (même modèle/GGUF/device), l'analyse calibre
# t/s = (1+Σα^i)/(t_base + k·t_draft), recommande le n-max cible et
# l'écrit directement dans spec-nmax.conf (ini régénéré, restart proposé).
# --spec-test suffit donc à régler un modèle ; --spec-tune reste le mode
# batch (enchaîne plusieurs n-max avec restart entre chaque).
#
# Protocole pour régler spec-draft-n-max d'un modèle MTP :
#   1. --spec-test <modèle>                    (valeur courante)
#   2. éditer spec-draft-n-max dans MODEL_INI[<modèle>] du SCRIPT (pas le ini,
#      il est régénéré), ./setup-llm.sh --preload (+ restart), --spec-test
#   3. répéter, garder la meilleure valeur, --preload une dernière fois
# =============================================================================


_spec_save_conf() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  {
    echo "; spec-nmax.conf — spec-draft-n-max retenu par modèle MTP"
    echo "; généré par ./setup-llm.sh --spec-tune ; édition manuelle OK ;"
    echo "; supprimer une ligne = retour au défaut du script"
    if [[ -f "$SPEC_CONF" ]]; then
      grep -v '^;' "$SPEC_CONF" | grep -v "^${key}[[:space:]]*=" | grep -v '^[[:space:]]*$' || true
    fi
    echo "${key} = ${val}"
  } > "$tmp"
  mv "$tmp" "$SPEC_CONF"
}

# Modèles spéculatifs (spec-type = draft-mtp) dont le GGUF est présent, dans
# l'ordre de PRESET_ORDER → SPEC_PRESETS
SPEC_PRESETS=()
_spec_presets() {
  SPEC_PRESETS=()
  local p body gguf
  for p in "${PRESET_ORDER[@]}"; do
    body="${MODEL_INI[$p]}"
    echo "$body" | grep -q '^spec-type[[:space:]]*=[[:space:]]*draft-mtp' || continue
    gguf="$(echo "$body" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
    [[ -f "$gguf" ]] || continue
    SPEC_PRESETS+=("$p")
  done
}

# Sélection interactive du modèle MTP à tester (gum si dispo, sinon numéroté).
# Non interactif : premier de la liste. Résultat dans SPEC_CHOICE (vide = annulé).
SPEC_CHOICE=""
_spec_select_preset() {
  _spec_presets
  SPEC_CHOICE=""
  [[ ${#SPEC_PRESETS[@]} -gt 0 ]] || error "Aucun modèle MTP avec GGUF présent — lancer --setup."

  if [[ ! -t 0 ]]; then
    SPEC_CHOICE="${SPEC_PRESETS[0]}"
    info "Entrée non interactive — modèle MTP : $SPEC_CHOICE"
    return
  fi

  local -a labels=()
  local p nmax
  load_spec_conf
  for p in "${SPEC_PRESETS[@]}"; do
    nmax="$(_preset_nmax "$p")"
    labels+=("$p — n-max ${nmax:-?}")
  done

  if command -v gum >/dev/null 2>&1; then
    local line
    line="$(printf '%s\n' "${labels[@]}" \
      | gum choose --height 15 --header "Modèle MTP à tester (entrée = valider)")" || line=""
    [[ -n "$line" ]] && SPEC_CHOICE="${line%% — *}"
  else
    info "gum absent (pacman -S gum) — fallback numéroté."
    echo ""
    echo "Modèles MTP disponibles :"
    local i=1
    for p in "${labels[@]}"; do
      printf "  %2d  %s\n" "$i" "$p"
      ((i++))
    done
    echo ""
    local n
    read -r -p "Numéro à tester (vide = annuler) : " n
    if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#SPEC_PRESETS[@]} )); then
      SPEC_CHOICE="${SPEC_PRESETS[$((n-1))]}"
    fi
  fi
}

cmd_spec_test() {
  local preset="${1:-}"
  local passes="${2:-4}"
  if [[ -z "$preset" ]]; then
    _spec_select_preset
    [[ -n "$SPEC_CHOICE" ]] || { info "Rien sélectionné — spec-test annulé."; return; }
    preset="$SPEC_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 1 ]] || error "Nombre de passes invalide : '$passes'"
  command -v curl >/dev/null || error "curl introuvable"
  command -v python3 >/dev/null || error "python3 introuvable"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — sudo systemctl start $SERVICE_NAME"

  load_spec_conf
  local nmax nmax_cfg nmax_srv
  nmax_cfg="$(_preset_nmax "$preset")"
  # Valeur RÉELLE côté serveur : /v1/models expose status.args de chaque modèle
  # (le routeur lit le ini au démarrage — le script peut dire 2 quand le serveur
  # tourne encore à 4). C'est elle qui est journalisée et affichée.
  nmax_srv="$(curl -s "$SPEC_TEST_URL/v1/models" \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" 2>/dev/null || true)"
  nmax="${nmax_srv:-$nmax_cfg}"
  if [[ -n "$nmax_srv" && -n "$nmax_cfg" && "$nmax_srv" != "$nmax_cfg" ]]; then
    warn "Désaccord n-max : serveur=$nmax_srv, script/conf=$nmax_cfg → le ini a changé sans restart."
    warn "  Ce run mesure et journalise n-max $nmax_srv (réel). Appliquer la config : sudo systemctl restart $SERVICE_NAME"
  fi

  # --- En-tête : contexte complet du run, à coller tel quel dans un échange ---
  load_bench_conf
  local mkey mdev gguf gsize llver
  mkey="$(_preset_model_key "$preset" || true)"
  mdev="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE}"
  gguf="$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
  gsize="$(du -h "$gguf" 2>/dev/null | cut -f1 || echo '?')"
  llver="$(paru -Q llama-cpp ggml 2>/dev/null | tr '\n' ' ')"
  local kernel cpu
  kernel="$(uname -r)"
  cpu="$(sed -n 's/^model name[[:space:]]*: //p' /proc/cpuinfo | head -1)"

  echo "=== spec-test ==="
  echo "date       : $(date '+%F %T')"
  echo "host       : $(hostname) — $cpu — $kernel"
  echo "llama.cpp  : ${llver:-?}"
  echo "modèle     : $preset"
  echo "gguf       : $(basename "$gguf") ($gsize)"
  echo "device     : $mdev"
  echo "n-max      : ${nmax:-n/a}$( [[ -n "$nmax_srv" ]] && echo " (lu sur le serveur)" || echo " (script/conf)" )$( [[ -n "$nmax_srv" && -n "$nmax_cfg" && "$nmax_srv" != "$nmax_cfg" ]] && echo "  ⚠ script/conf=$nmax_cfg, restart requis" )"
  echo "passes     : $passes (max_tokens=1500, temp=0.7, seed=42+n° de passe, prompt fixe inventory/pytest)"
  echo "note       : prompt t/s significatif en passe 1 seulement (prompt cache ensuite, cf. n=/cache=)"
  echo "--- modèle ($preset) ---"
  if [[ -n "$nmax" ]]; then
    echo "${MODEL_INI[$preset]}" | sed '/^$/d' \
      | sed "s/^\(spec-draft-n-max[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1$nmax/;s/^/  /"
    [[ -n "$nmax_srv" && "$nmax_srv" != "$nmax_cfg" ]] \
      && echo "  (spec-draft-n-max ci-dessus = valeur SERVEUR ; le script/conf dit $nmax_cfg)"
    [[ -n "${SPEC_NMAX_FORCE:-}" && "${SPEC_NMAX_FORCE_PRESET:-}" == "$preset" ]] \
      && echo "  (spec-draft-n-max forcé par --spec-tune, non persistant)"
    [[ -n "${SPEC_NMAX[$preset]:-}" && -z "${SPEC_NMAX_FORCE:-}" ]] \
      && echo "  (spec-draft-n-max issu de spec-nmax.conf, défaut script = $(echo "${MODEL_INI[$preset]}" | sed -n 's/^spec-draft-n-max[[:space:]]*=[[:space:]]*//p' | tr -d ' '))"
  else
    echo "${MODEL_INI[$preset]}" | sed '/^$/d;s/^/  /'
  fi
  echo "--- résultats ---"

  # Prompt de référence : prompts/spec-test.txt (texte brut multiligne,
  # échappement JSON par build_body.py). ⚠ Le modifier invalide les
  # comparaisons avec les runs antérieurs de spec-tests.log (cf. ARCHITECTURE.md).
  local prompt_file="$SCRIPT_DIR/prompts/spec-test.txt"
  [[ -f "$prompt_file" ]] || error "Prompt manquant : $prompt_file"

  # seed fixe PAR PASSE (42+i) : chaque passe est reproductible d'un run à
  # l'autre (la spéculation étant sans perte, deux n-max produisent la même
  # sortie à seed égal → comparaison à trajectoire identique, sans bruit de
  # sampling), tout en gardant plusieurs trajectoires distinctes dans un run
  # (une seule seed sur-représenterait un cas particulier).
  local body i out

  local -a gens=() accs=()
  local sum_dn=0 sum_da=0 sum_pn=0
  for (( i=1; i<=passes; i++ )); do
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 1500 $((42 + i)) "$prompt_file")"
    out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
      || { warn "Passe $i : échec curl"; continue; }
    local line
    line="$(python3 "$SCRIPT_DIR/py/timings.py" --spec "$out" "$i" "${nmax:+spec}")" || true
    echo "$line" | grep -v '^GEN=\|^ACC=\|^DN=' | sed 's/^/  /'
    local g a dn da pn
    g="$(echo "$line" | sed -n 's/^GEN=//p')"
    a="$(echo "$line" | sed -n 's/^ACC=//p')"
    dn="$(echo "$line" | sed -n 's/^DN=\([0-9]*\) DA=\([0-9]*\) PN=\([0-9]*\)$/\1/p')"
    da="$(echo "$line" | sed -n 's/^DN=\([0-9]*\) DA=\([0-9]*\) PN=\([0-9]*\)$/\2/p')"
    pn="$(echo "$line" | sed -n 's/^DN=\([0-9]*\) DA=\([0-9]*\) PN=\([0-9]*\)$/\3/p')"
    if [[ "$i" -gt 1 ]]; then
      [[ -n "$g" ]] && gens+=("$g")
      [[ -n "$a" ]] && accs+=("$a")
      [[ -n "$dn" ]] && { sum_dn=$((sum_dn + dn)); sum_da=$((sum_da + da)); sum_pn=$((sum_pn + pn)); }
    fi
  done

  local med
  if [[ ${#gens[@]} -gt 0 ]]; then
    med="$(printf '%s\n' "${gens[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
    info "Médiane gen (hors 1re passe) : $med t/s"
  fi
  local med_gen="" med_acc=""
  [[ ${#gens[@]} -gt 0 ]] && med_gen="$(printf '%s\n' "${gens[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
  if [[ ${#accs[@]} -gt 0 ]]; then
    med_acc="$(printf '%s\n' "${accs[@]}" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}')"
    info "Médiane acceptance (hors 1re passe) : $med_acc"
  fi

  # --- Journal + analyse n-max ---------------------------------------------
  if [[ -n "$nmax" && -n "$med_gen" && "$sum_dn" -gt 0 ]]; then
    # date modèle gguf device nmax gen acc drafted accepted predicted
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date '+%F %T')" "$preset" "$(basename "$gguf")" "$mdev" "$nmax" \
      "$med_gen" "$med_acc" "$sum_dn" "$sum_da" "$sum_pn" >> "$SPEC_LOG"
    echo "--- analyse n-max ---"
    local report rec
    report="$(_spec_analyze "$preset" "$(basename "$gguf")" "$mdev" "$nmax" rec)"
    echo "$report" | grep -v '^REC='
    rec="$(echo "$report" | sed -n 's/^REC=//p')"
    # Persistance automatique : dès que >= 2 n-max mesurés donnent une reco,
    # elle est écrite dans spec-nmax.conf (surcharge du défaut script) et le
    # ini est régénéré — plus besoin de --spec-tune pour figer le résultat.
    # (sauf sous --spec-tune, qui pilote son propre bilan en fin de boucle)
    if [[ "$rec" =~ ^[0-9]+$ && -z "${SPEC_NMAX_FORCE:-}" ]]; then
      if [[ "$rec" == "$nmax_cfg" ]]; then
        info "spec-draft-n-max = $rec déjà en config — rien à changer."
      else
        _spec_save_conf "$preset" "$rec"
        load_spec_conf
        regen_models_ini
        info "✅ $preset : spec-draft-n-max = $rec enregistré dans $SPEC_CONF (config précédente : ${nmax_cfg:-défaut}) — models.ini régénéré."
        _maybe_restart_service
      fi
    fi
  fi
  echo "================="
}

# Analyse des runs journalisés pour (modèle, gguf, device) — la logique
# (modèle T(k)/t(k), calibration, quarantaine, recommandation) vit dans
# py/spec_analyze.py, voir son commentaire de tête. Ici : simple appel.
_spec_analyze() {
  python3 "$SCRIPT_DIR/py/spec_analyze.py" "$SPEC_LOG" "$1" "$2" "$3" "$4" "${5:-}"
}

# =============================================================================
# spec-tune — boucle automatique sur plusieurs n-max, mesure, choisit, persiste
#
# Usage : ./setup-llm.sh --spec-tune [modèle] [k1,k2,...] [passes]
#   modèle : sélection interactive si absent ; liste défaut "2,4,6" ; passes 4.
#
# Pour chaque k : models.ini régénéré avec le n-max forcé (SPEC_NMAX_FORCE),
# restart du service systemd, attente /health, --spec-test (journalisé). À la
# fin : analyse sur tous les runs, choix = meilleur MESURÉ (à <2 %, le plus
# petit k), écriture dans spec-nmax.conf, ini régénéré, restart final.
# Sudo demandé au premier restart (cache sudo ensuite). Le service systemd est
# requis (un llama-server manuel ne peut pas être relancé proprement).
# =============================================================================

cmd_spec_tune() {
  local preset="${1:-}"
  local klist="${2:-2,4,6}"
  local passes="${3:-4}"

  if [[ -z "$preset" ]]; then
    _spec_select_preset
    [[ -n "$SPEC_CHOICE" ]] || { info "Rien sélectionné — spec-tune annulé."; return; }
    preset="$SPEC_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset'"
  echo "${MODEL_INI[$preset]}" | grep -q '^spec-type[[:space:]]*=[[:space:]]*draft-mtp' \
    || error "'$preset' n'est pas un modèle spéculatif (spec-type = draft-mtp requis)"
  systemctl is-enabled "$SERVICE_NAME" &>/dev/null \
    || error "Service $SERVICE_NAME non installé — --spec-tune a besoin de le redémarrer entre deux n-max (--install-service)."

  local -a ks=()
  local k
  IFS=',' read -r -a ks <<< "$klist"
  for k in "${ks[@]}"; do
    [[ "$k" =~ ^[0-9]+$ && "$k" -ge 1 && "$k" -le 16 ]] || error "n-max invalide : '$k' (1..16)"
  done

  load_spec_conf
  local before
  before="$(_preset_nmax "$preset")"
  info "spec-tune '$preset' — n-max à tester : ${ks[*]} ($passes passes chacun), valeur actuelle : $before"
  warn "Chaque n-max = régénération du ini + restart de $SERVICE_NAME (les modèles préchargés se rechargent)."
  info "sudo requis : le routeur ne lit le ini qu'au démarrage, chaque n-max impose donc"
  info "  'systemctl restart $SERVICE_NAME' (service système). Rien d'autre ne passe par root."
  # Prendre le ticket sudo maintenant plutôt qu'au milieu de la boucle (mot de
  # passe demandé pendant qu'un run tourne = invite noyée dans la sortie).
  sudo -v || error "sudo refusé — spec-tune ne peut pas redémarrer $SERVICE_NAME."

  local gguf mkey mdev
  gguf="$(basename "$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)")"
  load_bench_conf
  mkey="$(_preset_model_key "$preset" || true)"
  mdev="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE}"

  # Restore garanti (Ctrl-C en plein tune : on remet la config non forcée)
  SPEC_TUNE_DIRTY=0
  _spec_tune_restore() {
    if [[ "$SPEC_TUNE_DIRTY" -eq 1 ]]; then
      warn "spec-tune interrompu — régénération du ini sans valeur forcée + restart."
      unset SPEC_NMAX_FORCE SPEC_NMAX_FORCE_PRESET
      regen_models_ini
      sudo systemctl restart "$SERVICE_NAME" || true
      SPEC_TUNE_DIRTY=0
    fi
  }
  trap _spec_tune_restore EXIT

  for k in "${ks[@]}"; do
    echo ""
    info "════════ n-max = $k ════════"
    export SPEC_NMAX_FORCE="$k" SPEC_NMAX_FORCE_PRESET="$preset"
    SPEC_TUNE_DIRTY=1
    regen_models_ini
    sudo systemctl restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    # attente du routeur (les poids se chargent à la 1re requête, passe froide ignorée)
    local t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      [[ $t -ge 120 ]] && error "llama-server ne répond pas après 120 s — journalctl -u $SERVICE_NAME -e"
    done
    cmd_spec_test "$preset" "$passes"
  done
  unset SPEC_NMAX_FORCE SPEC_NMAX_FORCE_PRESET

  echo ""
  info "════════ Bilan ════════"
  local rec report
  report="$(_spec_analyze "$preset" "$gguf" "$mdev" "${ks[-1]}" rec)"
  echo "$report" | grep -v '^REC='
  rec="$(echo "$report" | sed -n 's/^REC=//p')"
  if [[ ! "$rec" =~ ^[0-9]+$ ]]; then
    warn "Pas de recommandation exploitable — config remise à l'état initial ($before)."
    regen_models_ini
    sudo systemctl restart "$SERVICE_NAME" || true
    SPEC_TUNE_DIRTY=0
    return
  fi

  _spec_save_conf "$preset" "$rec"
  load_spec_conf
  regen_models_ini
  info "✅ $preset : spec-draft-n-max = $rec enregistré dans $SPEC_CONF (avant : $before)"
  info "Restart final de $SERVICE_NAME sur la valeur retenue..."
  sudo systemctl restart "$SERVICE_NAME" || warn "Restart en échec — sudo systemctl restart $SERVICE_NAME"
  SPEC_TUNE_DIRTY=0
  trap - EXIT
}
