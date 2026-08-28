# lib/spec.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-agentic → spec → service → help

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

# spec-type peut porter une LISTE séparée par des virgules : llama.cpp essaie
# les implémentations dans son ordre de priorité (les draftless d'abord, les
# draft models ensuite — cf. docs/speculative.md), et la première qui produit
# un draft non vide gagne le pas de décode. Sortie : valeur normalisée sans
# espaces, vide si le modèle n'est pas spéculatif.
_preset_spec_types() {
  echo "${MODEL_INI[$1]}" | sed -n 's/^spec-type[[:space:]]*=[[:space:]]*//p' | head -1 | tr -d ' '
}

# Vrai si le spec-type du modèle $1 contient le type $2. Ne PAS ancrer le type
# juste après le "=" comme le faisait le grep d'origine : avec une liste
# "ngram-map-k,draft-mtp" il ne matche plus et le modèle disparaît en silence
# de --spec-test et de --spec-tune.
_preset_has_spec_type() {
  local v; v="$(_preset_spec_types "$1")"
  [[ ",$v," == *",$2,"* ]]
}

# Modèles à tête MTP (draft-mtp dans leur spec-type, seul ou en liste) dont le
# GGUF est présent, dans l'ordre de PRESET_ORDER → SPEC_PRESETS
SPEC_PRESETS=()
_spec_presets() {
  SPEC_PRESETS=()
  local p body gguf
  for p in "${PRESET_ORDER[@]}"; do
    body="${MODEL_INI[$p]}"
    _preset_has_spec_type "$p" draft-mtp || continue
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
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"

  load_spec_conf
  local nmax nmax_cfg nmax_srv
  nmax_cfg="$(_preset_nmax "$preset")"
  # Valeur RÉELLE côté serveur : /v1/models expose status.args de chaque modèle
  # (le routeur lit le ini au démarrage — le script peut dire 2 quand le serveur
  # tourne encore à 4). C'est elle qui est journalisée et affichée.
  # Un seul appel à /v1/models, relu deux fois : n-max ET spec-type réels.
  local models_json
  models_json="$(curl -s "$SPEC_TEST_URL/v1/models" || true)"
  nmax_srv="$(printf '%s' "$models_json" \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" 2>/dev/null || true)"
  nmax="${nmax_srv:-$nmax_cfg}"

  # spec-type réel, pour la même raison que le n-max : le ini a pu changer sans
  # restart. Une liste (virgules) = plusieurs implémentations en concurrence,
  # ce qui change la lecture de l'acceptance et exclut le run de la
  # calibration α (k variable par forward) — d'où sa journalisation.
  local stype_srv stype_cfg stype spec_flag
  stype_cfg="$(_preset_spec_types "$preset")"
  stype_srv="$(printf '%s' "$models_json" \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --spec-type 2>/dev/null || true)"
  stype="${stype_srv:-$stype_cfg}"
  # size_m n-gram réel (même logique) : affiché à la place de la valeur du
  # script, qui ne reflète ni spec-ngram.conf ni un forçage --spec-ngram-tune.
  local ngram_srv
  ngram_srv="$(printf '%s' "$models_json" \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --spec-ngram-map-k-size-m 2>/dev/null || true)"
  spec_flag="${nmax:+spec}"
  if [[ -n "$spec_flag" && "$stype" == *,* ]]; then
    spec_flag="specmix"
  fi
  if [[ -n "$nmax_srv" && -n "$nmax_cfg" && "$nmax_srv" != "$nmax_cfg" ]]; then
    warn "Désaccord n-max : serveur=$nmax_srv, script/conf=$nmax_cfg → le ini a changé sans restart."
    warn "  Ce run mesure et journalise n-max $nmax_srv (réel). Appliquer la config : systemctl --user restart $SERVICE_NAME"
  fi
  if [[ -n "${SPEC_TYPE_FORCE:-}" && "${SPEC_TYPE_FORCE_PRESET:-}" == "$preset" ]]; then
    # forçage voulu par un tuner, pas un ini oublié
    [[ -n "$stype_srv" ]] && echo "  (spec-type forcé à $stype_srv le temps du réglage ; script : $stype_cfg)"
  elif [[ -n "$stype_srv" && -n "$stype_cfg" && "$stype_srv" != "$stype_cfg" ]]; then
    warn "Désaccord spec-type : serveur=$stype_srv, script=$stype_cfg → le ini a changé sans restart."
    warn "  Ce run mesure et journalise spec-type $stype_srv (réel). Appliquer la config : systemctl --user restart $SERVICE_NAME"
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

  # Prompt de référence : prompts/spec-test.txt (texte brut multiligne,
  # échappement JSON par build_body.py). ⚠ Le modifier invalide les
  # comparaisons avec les runs antérieurs de spec-tests.log (cf. ARCHITECTURE.md).
  # Un autre prompt peut être passé en 3e argument (--spec-ngram-tune s'en sert
  # pour mesurer sur du refactor, seul cas où un n-gram a des hits) : il est
  # alors journalisé, car deux runs sur des prompts différents ne se comparent
  # pas et ne doivent pas alimenter la même calibration.
  local prompt_file="${3:-$SCRIPT_DIR/prompts/spec-test.txt}"
  [[ -f "$prompt_file" ]] || error "Prompt manquant : $prompt_file"

  echo "=== spec-test ==="
  echo "date       : $(date '+%F %T')"
  echo "host       : $(hostname) — $cpu — $kernel"
  echo "llama.cpp  : ${llver:-?}"
  echo "modèle     : $preset"
  echo "gguf       : $(basename "$gguf") ($gsize)"
  echo "device     : $mdev"
  echo "n-max      : ${nmax:-n/a}$( [[ -n "$nmax_srv" ]] && echo " (lu sur le serveur)" || echo " (script/conf)" )$( [[ -n "$nmax_srv" && -n "$nmax_cfg" && "$nmax_srv" != "$nmax_cfg" ]] && echo "  ⚠ script/conf=$nmax_cfg, restart requis" )"
  [[ "$stype" == *,* ]] && echo "spec-type  : $stype (liste — la 1re implémentation qui drafte gagne le pas ;"
  [[ "$stype" == *,* ]] && echo "             acceptance agrégée, run exclu de la calibration α)"
  echo "passes     : $passes (max_tokens=1500, temp=0.7, seed=42+n° de passe)"
  echo "prompt     : $(basename "$prompt_file")"
  echo "note       : prompt t/s significatif en passe 1 seulement (prompt cache ensuite, cf. n=/cache=)"
  echo "--- modèle ($preset) ---"
  if [[ -n "$nmax" ]]; then
    echo "${MODEL_INI[$preset]}" | sed '/^$/d' \
      | sed "s/^\(spec-draft-n-max[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1$nmax/;s/^\(spec-ngram-map-k-size-m[[:space:]]*=[[:space:]]*\)[0-9]*[[:space:]]*$/\1${ngram_srv:-&}/;s/^/  /"
    [[ -n "$ngram_srv" && -n "${SPEC_NGRAM_FORCE:-}" && "${SPEC_NGRAM_FORCE_PRESET:-}" == "$preset" ]] \
      && echo "  (spec-ngram-map-k-size-m = valeur SERVEUR, forcée par --spec-ngram-tune, non persistante)"
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
    line="$(python3 "$SCRIPT_DIR/py/timings.py" --spec "$out" "$i" "$spec_flag")" || true
    echo "$line" | grep -v '^GEN=\|^ACC=\|^DN=\|^DEGEN=' | sed 's/^/  /'
    # Sortie dégénérée (cf. timings.py) : passe ignorée, elle fausserait gen et acceptance
    if echo "$line" | grep -q '^DEGEN=1$'; then
      warn "Passe $i : sortie dégénérée, ignorée (backend ou modèle en défaut sur ce device)."
      continue
    fi
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

  # Médianes exposées aux appelants (--spec-tune, --spec-ngram-tune) sur le
  # modèle de BENCH_ROW dans lib/bench.sh : vides si la mesure a échoué.
  SPEC_TEST_MED_GEN=""
  SPEC_TEST_MED_ACC=""

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
  SPEC_TEST_MED_GEN="$med_gen"
  SPEC_TEST_MED_ACC="$med_acc"

  # --- Journal + analyse n-max ---------------------------------------------
  if [[ -n "$nmax" && -n "$med_gen" && "$sum_dn" -gt 0 ]]; then
    # date modèle gguf device nmax gen acc drafted accepted predicted spectype prompt build
    # (colonnes 11 et 12 ajoutées avec le support des listes et du prompt
    #  paramétrable, 13 = build llama.cpp ; les lignes plus anciennes n'en ont
    #  pas et sont lues comme "draft-mtp" seul sur spec-test.txt, build inconnu)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$(date '+%F %T')" "$preset" "$(basename "$gguf")" "$mdev" "$nmax" \
      "$med_gen" "$med_acc" "$sum_dn" "$sum_da" "$sum_pn" "${stype:-draft-mtp}" \
      "$(basename "$prompt_file")" "$(_llama_build)" >> "$SPEC_LOG"
    echo "--- analyse n-max ---"
    if [[ "$stype" == *,* || "$(basename "$prompt_file")" != "spec-test.txt" ]]; then
      # Le run courant est hors modèle α (k variable, ou acceptance d'un autre
      # prompt) : spec_analyze l'écarterait et commenterait le DERNIER run
      # valide comme s'il était courant. Le journal, lui, est bien écrit.
      echo "  sans objet pour ce run (spec-type mixte ou prompt hors référence) :"
      echo "  α ne se calibre que sur draft-mtp seul et spec-test.txt — comparer les t/s bruts."
      return 0
    fi
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
# Le service systemd user est requis (un llama-server manuel ne peut pas être
# relancé proprement) ; tout passe par systemctl --user.
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
  _preset_has_spec_type "$preset" draft-mtp \
    || error "'$preset' n'a pas de tête MTP (draft-mtp attendu dans spec-type, seul ou en liste)"
  systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null \
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
  info "Le routeur ne lit le ini qu'au démarrage : chaque n-max impose un"
  info "  'systemctl --user restart $SERVICE_NAME' (service user)."

  local gguf mkey mdev
  gguf="$(basename "$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)")"
  load_bench_conf
  mkey="$(_preset_model_key "$preset" || true)"
  mdev="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE}"

  # spec-type en liste (n-gram + MTP) : le n-max ne concerne que la tête MTP,
  # et le modèle α ne tient que si k est constant — on mesure donc en
  # draft-mtp seul (SPEC_TYPE_FORCE, lu par generate_models_ini), la
  # liste complète revient au restart final. La valeur retenue vaut pour le
  # chemin MTP quel que soit le reste de la liste.
  if [[ "$(_preset_spec_types "$preset")" == *,* ]]; then
    export SPEC_TYPE_FORCE="draft-mtp" SPEC_TYPE_FORCE_PRESET="$preset"
    info "spec-type en liste ($(_preset_spec_types "$preset")) : mesuré en draft-mtp seul"
    info "  le temps du réglage (n-max = paramètre MTP, calibration α à k constant)."
  fi

  # Restore garanti (Ctrl-C en plein tune : on remet la config non forcée)
  SPEC_TUNE_DIRTY=0
  _spec_tune_restore() {
    if [[ "$SPEC_TUNE_DIRTY" -eq 1 ]]; then
      warn "spec-tune interrompu — régénération du ini sans valeur forcée + restart."
      unset SPEC_NMAX_FORCE SPEC_NMAX_FORCE_PRESET SPEC_TYPE_FORCE SPEC_TYPE_FORCE_PRESET
      regen_models_ini
      systemctl --user restart "$SERVICE_NAME" || true
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
    systemctl --user restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    # attente du routeur (les poids se chargent à la 1re requête, passe froide ignorée)
    local t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      # if/fi obligatoire : "[[ ... ]] && error" retourne 1 tant que le timeout
      # n'est pas atteint et set -e tuerait la boucle à la 1re itération
      if [[ $t -ge 120 ]]; then
        error "llama-server ne répond pas après 120 s — journalctl --user -u $SERVICE_NAME -e"
      fi
    done
    cmd_spec_test "$preset" "$passes"
  done
  unset SPEC_NMAX_FORCE SPEC_NMAX_FORCE_PRESET SPEC_TYPE_FORCE SPEC_TYPE_FORCE_PRESET

  echo ""
  info "════════ Bilan ════════"
  local rec report
  report="$(_spec_analyze "$preset" "$gguf" "$mdev" "${ks[-1]}" rec)"
  echo "$report" | grep -v '^REC='
  rec="$(echo "$report" | sed -n 's/^REC=//p')"
  if [[ ! "$rec" =~ ^[0-9]+$ ]]; then
    warn "Pas de recommandation exploitable — config remise à l'état initial ($before)."
    regen_models_ini
    systemctl --user restart "$SERVICE_NAME" || true
    SPEC_TUNE_DIRTY=0
    return
  fi

  _spec_save_conf "$preset" "$rec"
  load_spec_conf
  regen_models_ini
  info "✅ $preset : spec-draft-n-max = $rec enregistré dans $SPEC_CONF (avant : $before)"
  info "Restart final de $SERVICE_NAME sur la valeur retenue..."
  systemctl --user restart "$SERVICE_NAME" || warn "Restart en échec — systemctl --user restart $SERVICE_NAME"
  SPEC_TUNE_DIRTY=0
  trap - EXIT
}

# =============================================================================
# spec-ngram-tune — règle spec-ngram-map-k-size-m d'un modèle, en deux moitiés
#
# Usage : ./setup-llm.sh --spec-ngram-tune [modèle] [passes] [prompt]
#
# 1. COURBE (llama-bench, service arrêté, ~2 min) : balayage grossier puis
#    raffinement automatique autour de la marche détectée, sur le device
#    EFFECTIF du modèle (bench-devices.conf) — la marche n'est pas au même
#    endroit d'un backend à l'autre. Sortie : deux candidats, le « sûr » (sous
#    la marche, ne peut pas perdre) et le « large » (amortit le coût fixe).
#    Détail du raisonnement dans py/batch_curve.py.
#
# 2. ARBITRAGE (service, ~10 min) : chaque candidat est écrit, le ini régénéré,
#    le service redémarré, et --spec-test mesuré. La courbe ne PEUT PAS trancher
#    seule — le choix dépend de la longueur des répétitions réellement
#    rencontrées, que seule une génération réelle donne.
#
#    ⚠ Le prompt par défaut (prompts/spec-test.txt) écrit un module de zéro :
#    aucune répétition à retrouver, donc aucun hit n-gram et deux candidats
#    indistinguables. Passer un prompt de refactor en 3e argument pour que
#    cette moitié mesure quelque chose.
#
# min-hits n'est pas réglé ici : le tuner par-dessus size_m multiplierait les
# restarts pour un effet de second ordre. La valeur vit dans lib/models.sh.
# =============================================================================

_spec_save_ngram_conf() {
  local key="$1" val="$2" tmp
  tmp="$(mktemp)"
  {
    echo "; spec-ngram.conf — spec-ngram-map-k-size-m retenu par modèle"
    echo "; généré par ./setup-llm.sh --spec-ngram-tune ; édition manuelle OK ;"
    echo "; supprimer une ligne = retour au défaut du script"
    if [[ -f "$SPEC_NGRAM_CONF" ]]; then
      grep -v '^;' "$SPEC_NGRAM_CONF" | grep -v "^${key}[[:space:]]*=" | grep -v '^[[:space:]]*$' || true
    fi
    echo "${key} = ${val}"
  } > "$tmp"
  mv "$tmp" "$SPEC_NGRAM_CONF"
}

# Modèles dont le spec-type contient une implémentation n-gram réglable par
# size_m et dont le GGUF est présent.
_spec_ngram_presets() {
  SPEC_PRESETS=()
  local p gguf
  for p in "${PRESET_ORDER[@]}"; do
    _preset_has_spec_type "$p" ngram-map-k || continue
    gguf="$(echo "${MODEL_INI[$p]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
    [[ -f "$gguf" ]] || continue
    SPEC_PRESETS+=("$p")
  done
}

# Un balayage llama-bench → jsonl brut sur stdout. $1 gguf, $2 device, $3 liste
# de batches, $4 répétitions.
_spec_ngram_sweep() {
  llama-bench -m "$1" -p "$3" -n 0 -d 0 -r "$4" -fa auto -dev "$2" -o jsonl 2>/dev/null
}

cmd_spec_ngram_tune() {
  local preset="${1:-}"
  local passes="${2:-4}"
  local prompt_file="${3:-}"

  if [[ -z "$preset" ]]; then
    _spec_ngram_presets
    [[ ${#SPEC_PRESETS[@]} -gt 0 ]] \
      || error "Aucun modèle avec ngram-map-k dans son spec-type et son GGUF présent."
    if [[ ! -t 0 ]]; then
      preset="${SPEC_PRESETS[0]}"
      info "Entrée non interactive — modèle : $preset"
    elif command -v gum >/dev/null 2>&1; then
      preset="$(printf '%s\n' "${SPEC_PRESETS[@]}" | gum choose --header "Modèle à régler :" || true)"
    else
      local i n
      for i in "${!SPEC_PRESETS[@]}"; do echo "  $((i+1))) ${SPEC_PRESETS[$i]}"; done
      read -r -p "Numéro (vide = annuler) : " n
      [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#SPEC_PRESETS[@]} )) \
        && preset="${SPEC_PRESETS[$((n-1))]}"
    fi
    [[ -n "$preset" ]] || { info "Rien sélectionné — spec-ngram-tune annulé."; return; }
  fi

  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  _preset_has_spec_type "$preset" ngram-map-k \
    || error "'$preset' n'a pas de spéculation n-gram (ngram-map-k attendu dans spec-type)."
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 2 ]] || error "Passes invalide : '$passes' (>= 2)"
  command -v llama-bench >/dev/null || error "llama-bench introuvable (paquet llama-cpp)"
  systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null \
    || error "Service $SERVICE_NAME non installé — l'arbitrage a besoin de le redémarrer (--install-service)."

  # Défaut spec-refactor.txt et non spec-test.txt : ce dernier écrit un module
  # de zéro, sans une répétition à retrouver, donc sans un seul hit n-gram — les
  # candidats y seraient indistinguables et l'arbitrage aveugle. spec-refactor
  # fournit un module dans le contexte et demande d'en recopier des blocs exacts
  # avant de les remplacer : c'est la forme du oldString/newString d'opencode,
  # et c'est là que les longueurs de match se jouent.
  if [[ -z "$prompt_file" ]]; then
    prompt_file="$SCRIPT_DIR/prompts/spec-refactor.txt"
  fi
  [[ -f "$prompt_file" ]] || error "Prompt introuvable : $prompt_file"
  info "Prompt d'arbitrage : $(basename "$prompt_file")"
  if [[ "$(basename "$prompt_file")" == "spec-test.txt" ]]; then
    warn "spec-test.txt génère du neuf, sans répétition : aucun hit n-gram,"
    warn "  donc des candidats indistinguables. Préférer spec-refactor.txt."
  fi

  local gguf mkey mdev
  gguf="$(echo "${MODEL_INI[$preset]}" | sed -n 's/^model[[:space:]]*=[[:space:]]*//p' | head -1)"
  [[ -f "$gguf" ]] || error "GGUF absent : $gguf — lancer --setup."
  load_bench_conf
  mkey="$(_preset_model_key "$preset" || true)"
  mdev="${BENCH_DEVICE[$mkey]:-$DEFAULT_DEVICE}"

  load_spec_ngram_conf
  local avant
  avant="$(_preset_ngram_m "$preset")"
  info "spec-ngram-tune '$preset' — device $mdev, valeur actuelle : ${avant:-défaut script}"

  # --- 1. Courbe -----------------------------------------------------------
  # Service arrêté : il occupe le GPU et la mémoire unifiée, et fausserait les
  # points hauts. Restauré quoi qu'il arrive (le trap couvre aussi le Ctrl-C).
  # Globale et non locale : le trap EXIT peut se déclencher après le retour de
  # la fonction, où une locale n'existerait plus (unbound sous set -u).
  SPEC_NGRAM_SERVICE_ACTIF=0
  if systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
    SPEC_NGRAM_SERVICE_ACTIF=1
  fi
  _spec_ngram_restore() {
    unset SPEC_NGRAM_FORCE SPEC_NGRAM_FORCE_PRESET SPEC_TYPE_FORCE SPEC_TYPE_FORCE_PRESET
    regen_models_ini
    if [[ "${SPEC_NGRAM_SERVICE_ACTIF:-0}" -eq 1 ]]; then
      systemctl --user start "$SERVICE_NAME" >/dev/null 2>&1 || true
    fi
    return 0
  }
  trap _spec_ngram_restore EXIT

  if [[ "$SPEC_NGRAM_SERVICE_ACTIF" -eq 1 ]]; then
    info "Arrêt de $SERVICE_NAME le temps du balayage (contention GPU)."
    systemctl --user stop "$SERVICE_NAME" || warn "Arrêt en échec — mesures potentiellement faussées."
  fi
  export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

  echo ""
  info "════════ 1/2 — courbe t_forward(batch) ════════"
  local jsonl rep lo hi
  jsonl="$(_spec_ngram_sweep "$gguf" "$mdev" "1,8,16,32,48" 5)"
  [[ -n "$jsonl" ]] || error "llama-bench n'a rien produit (RAM ? arch non supportée par $mdev ?)"
  rep="$(printf '%s\n' "$jsonl" | python3 "$SCRIPT_DIR/py/batch_curve.py" \
           "$(basename "$gguf")" "$mdev" 0 "" rec)"
  lo="$(echo "$rep" | sed -n 's/^STEP_LO=//p')"
  hi="$(echo "$rep" | sed -n 's/^STEP_HI=//p')"
  # Raffinement : la marche localisée au batch près change le candidat « sûr »
  # d'un cran, et c'est justement le cran qui compte. Le balayage grossier ne
  # PEUT PAS la voir seul : x2,12 entre 8 et 9 se dilue en x1,11 par unité
  # entre 8 et 16 (mesuré le 21/08/2026 — 47 retenu sans jamais être comparé
  # à 7). batch_curve.py signale donc les sauts bruts suspects entre deux
  # points non consécutifs, raffinés ici un par un ; une fois un intervalle
  # mesuré batch par batch il ne peut plus être suspect, la boucle termine.
  local tour=0
  while [[ "$lo" =~ ^[0-9]+$ && "$hi" =~ ^[0-9]+$ && $((hi - lo)) -gt 1 && $tour -lt 4 ]]; do
    tour=$((tour + 1))
    info "Saut entre les batches $lo et $hi — raffinement batch par batch ($tour)..."
    jsonl="$jsonl"$'\n'"$(_spec_ngram_sweep "$gguf" "$mdev" "${lo}-${hi}" 5)"
    rep="$(printf '%s\n' "$jsonl" | python3 "$SCRIPT_DIR/py/batch_curve.py" \
             "$(basename "$gguf")" "$mdev" 0 "" rec)"
    lo="$(echo "$rep" | sed -n 's/^STEP_LO=//p')"
    hi="$(echo "$rep" | sed -n 's/^STEP_HI=//p')"
  done
  echo "$rep" | grep -v '^SIZEM_\|^STEP_'

  local m_safe m_large
  m_safe="$(echo "$rep" | sed -n 's/^SIZEM_SAFE=//p')"
  m_large="$(echo "$rep" | sed -n 's/^SIZEM_LARGE=//p')"

  local -a cands=()
  if [[ "$m_safe" =~ ^[0-9]+$ ]] && (( m_safe >= 1 )); then
    cands+=("$m_safe")
  fi
  if [[ "$m_large" =~ ^[0-9]+$ ]] && (( m_large >= 1 )) && [[ "$m_large" != "$m_safe" ]]; then
    cands+=("$m_large")
  fi
  if [[ ${#cands[@]} -eq 0 ]]; then
    error "Aucun candidat exploitable (un seul point de courbe ?)."
  fi

  # --- 2. Arbitrage --------------------------------------------------------
  echo ""
  info "════════ 2/2 — arbitrage sur mesure réelle ════════"
  if [[ ${#cands[@]} -eq 1 ]]; then
    info "Un seul candidat (${cands[0]}) : pas de marche à départager. La mesure"
    info "  reste utile — elle valide la valeur de bout en bout avant de la figer."
  else
    info "Candidats : ${cands[*]} ($passes passes chacun, restart entre chaque)"
  fi
  # Modèle sans tête MTP : le n-gram est sa seule spéculation, et rien ne dit
  # encore s'il rapporte quoi que ce soit — une mesure de référence en
  # spec-type none s'impose (sur un modèle MTP, la référence est le MTP seul,
  # déjà connue par --spec-tune). Le bilan compare et refuse d'écrire un
  # size_m qui ne bat pas la référence.
  local ref_gen=""
  if ! _preset_has_spec_type "$preset" draft-mtp; then
    echo ""
    info "──── référence : sans spéculation (spec-type none) ────"
    export SPEC_TYPE_FORCE="none" SPEC_TYPE_FORCE_PRESET="$preset"
    regen_models_ini
    systemctl --user restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      if [[ $t -ge 120 ]]; then
        error "llama-server ne répond pas après 120 s — journalctl --user -u $SERVICE_NAME -e"
      fi
    done
    cmd_spec_test "$preset" "$passes" "$prompt_file"
    ref_gen="${SPEC_TEST_MED_GEN:-}"
    unset SPEC_TYPE_FORCE SPEC_TYPE_FORCE_PRESET
  fi

  local -a mesures=()
  local m t
  for m in "${cands[@]}"; do
    echo ""
    info "──── size_m = $m ────"
    export SPEC_NGRAM_FORCE="$m" SPEC_NGRAM_FORCE_PRESET="$preset"
    regen_models_ini
    systemctl --user restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      if [[ $t -ge 120 ]]; then
        error "llama-server ne répond pas après 120 s — journalctl --user -u $SERVICE_NAME -e"
      fi
    done
    cmd_spec_test "$preset" "$passes" "$prompt_file"
    mesures+=("${SPEC_TEST_MED_GEN:-0}")
  done
  unset SPEC_NGRAM_FORCE SPEC_NGRAM_FORCE_PRESET
  SPEC_NGRAM_SERVICE_ACTIF=1

  # --- Bilan ---------------------------------------------------------------
  echo ""
  info "════════ Bilan ════════"
  local i best_m="" best_g=""
  [[ -n "$ref_gen" ]] && echo "  sans spéculation : $ref_gen t/s"
  for i in "${!cands[@]}"; do
    echo "  size_m ${cands[$i]} : ${mesures[$i]} t/s"
    # comparaison numérique en awk (convention du dépôt)
    if [[ -z "$best_g" ]] || awk -v a="${mesures[$i]}" -v b="$best_g" 'BEGIN{exit !(a>b)}'; then
      best_g="${mesures[$i]}"; best_m="${cands[$i]}"
    fi
  done
  if [[ -z "$best_m" ]] || awk -v g="$best_g" 'BEGIN{exit !(g<=0)}'; then
    warn "Aucune mesure exploitable — config remise à l'état initial."
    _spec_ngram_restore; trap - EXIT; return
  fi
  if [[ -n "$ref_gen" ]] && awk -v g="$best_g" -v r="$ref_gen" 'BEGIN{exit !(g <= r)}'; then
    warn "Aucun size_m ne bat la référence sans spéculation ($ref_gen t/s) :"
    warn "  rien d'écrit — retirer ngram-map-k du spec-type de $preset dans lib/models.sh."
    _spec_ngram_restore; trap - EXIT; return
  fi
  # À moins de 2 % d'écart, préférer le plus PETIT size_m : son seuil de
  # non-perte est plus bas, donc il tient mieux sur des répétitions plus
  # courtes que celles du prompt de test (même règle que --spec-tune sur k).
  for i in "${!cands[@]}"; do
    if awk -v a="${mesures[$i]}" -v b="$best_g" 'BEGIN{exit !(a >= b*0.98)}' \
       && (( cands[i] < best_m )); then
      best_m="${cands[$i]}"; best_g="${mesures[$i]}"
    fi
  done

  _spec_save_ngram_conf "$preset" "$best_m"
  load_spec_ngram_conf
  regen_models_ini
  info "✅ $preset : spec-ngram-map-k-size-m = $best_m enregistré dans $SPEC_NGRAM_CONF (avant : ${avant:-défaut})"
  info "Restart final sur la valeur retenue..."
  systemctl --user restart "$SERVICE_NAME" || warn "Restart en échec — systemctl --user restart $SERVICE_NAME"
  trap - EXIT
}

# =============================================================================
# spec-ab — A/B de réglages spéculatifs sur mesure réelle, sans rien écrire
#
# Usage : ./setup-llm.sh --spec-ab <modèle> <passes> <prompt|-> <variante>...
#   variante = "clé=val;clé=val" appliquée au corps ini du modèle (clé présente
#   remplacée, absente ajoutée), ou "base" pour la configuration courante.
#   prompt : fichier de prompts/ ou "-" pour spec-refactor.txt.
#
# Exemples :
#   --spec-ab qwen3.8-27b-mtp-nothink 4 - base "spec-ngram-map-k-min-hits=1" "spec-ngram-map-k-min-hits=3"
#   --spec-ab qwen3.8-27b-mtp-nothink 4 - base "spec-type=ngram-map-k4v,draft-mtp;spec-ngram-map-k4v-size-m=47"
#   --spec-ab deepseek-v4-flash 4 - "spec-type=none" base "spec-ngram-map-k-size-m=15"
#
# Chaque variante : ini régénéré avec la surcharge, restart, --spec-test, puis
# bilan (gen t/s, acceptance) et retour à la configuration courante. Rien
# n'est écrit dans les .conf : c'est un instrument d'exploration, le choix
# final se reporte à la main dans lib/models.sh avec ses chiffres. C'est la
# forme outillée de la « voie manuelle » de la procédure d'ajout (SPEC_*_FORCE
# + --preload + restart à la main).
# =============================================================================
cmd_spec_ab() {
  local preset="${1:-}" passes="${2:-4}" prompt_file="${3:--}"
  shift 3 2>/dev/null || error "Usage : --spec-ab <modèle> <passes> <prompt|-> <variante>..."
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  [[ "$passes" =~ ^[0-9]+$ && "$passes" -ge 2 ]] || error "Passes invalide : '$passes' (>= 2)"
  [[ $# -ge 1 ]] || error "Au moins une variante (\"clé=val;clé=val\" ou base)."
  if [[ "$prompt_file" == "-" ]]; then
    prompt_file="$SCRIPT_DIR/prompts/spec-refactor.txt"
  elif [[ ! -f "$prompt_file" && -f "$SCRIPT_DIR/prompts/$prompt_file" ]]; then
    prompt_file="$SCRIPT_DIR/prompts/$prompt_file"
  fi
  [[ -f "$prompt_file" ]] || error "Prompt introuvable : $prompt_file"
  systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null \
    || error "Service $SERVICE_NAME non installé — --spec-ab redémarre le service entre deux variantes."

  local -a variantes=("$@")
  local v
  for v in "${variantes[@]}"; do
    [[ "$v" == "base" || "$v" == *=* ]] || error "Variante invalide : '$v' (attendu clé=val[;clé=val] ou base)"
  done
  info "spec-ab '$preset' — ${#variantes[@]} variante(s), $passes passes chacune, prompt $(basename "$prompt_file")"
  warn "Chaque variante = régénération du ini + restart de $SERVICE_NAME. Rien n'est écrit dans les .conf."

  SPEC_AB_DIRTY=0
  _spec_ab_restore() {
    if [[ "${SPEC_AB_DIRTY:-0}" -eq 1 ]]; then
      unset SPEC_AB_OVERRIDES SPEC_AB_PRESET
      regen_models_ini
      systemctl --user restart "$SERVICE_NAME" >/dev/null 2>&1 || true
      SPEC_AB_DIRTY=0
    fi
    return 0
  }
  trap _spec_ab_restore EXIT

  local -a gens=() accs=()
  local t
  for v in "${variantes[@]}"; do
    echo ""
    info "──── variante : $v ────"
    if [[ "$v" == "base" ]]; then
      unset SPEC_AB_OVERRIDES SPEC_AB_PRESET
    else
      export SPEC_AB_OVERRIDES="$v" SPEC_AB_PRESET="$preset"
    fi
    SPEC_AB_DIRTY=1
    regen_models_ini
    systemctl --user restart "$SERVICE_NAME" || error "Restart de $SERVICE_NAME en échec"
    t=0
    until curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; do
      sleep 2; t=$((t+2))
      if [[ $t -ge 120 ]]; then
        error "llama-server ne répond pas après 120 s — journalctl --user -u $SERVICE_NAME -e"
      fi
    done
    cmd_spec_test "$preset" "$passes" "$prompt_file"
    gens+=("${SPEC_TEST_MED_GEN:-0}"); accs+=("${SPEC_TEST_MED_ACC:--}")
  done
  unset SPEC_AB_OVERRIDES SPEC_AB_PRESET

  echo ""
  info "════════ Bilan spec-ab ($preset, $(basename "$prompt_file"), $passes passes) ════════"
  local i ref=""
  {
    echo "variante|gen t/s|vs 1re|acceptance"
    for i in "${!variantes[@]}"; do
      [[ -n "$ref" ]] || ref="${gens[$i]}"
      echo "${variantes[$i]}|${gens[$i]}|$(awk -v a="${gens[$i]}" -v r="$ref" 'BEGIN{ if (r>0) printf "%+.1f %%", (a-r)/r*100; else print "?" }')|${accs[$i]}"
    done
  } | column -t -s'|'
  info "Rien d'écrit : reporter le choix dans lib/models.sh avec ces chiffres."
  info "Retour à la configuration courante + restart..."
  _spec_ab_restore
  trap - EXIT
}
