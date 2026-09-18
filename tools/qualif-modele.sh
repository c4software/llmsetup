#!/usr/bin/env bash
# =============================================================================
# qualif-modele.sh : enchaînement automatique des étapes de qualification d'un
# modèle DÉJÀ déclaré dans lib/models.sh et servi par le routeur.
#
# Pourquoi : les étapes 3, 5, 6 et 7 de la skill ajout-modele sont une suite de
# commandes longues, toujours les mêmes, toujours dans le même ordre (justesse,
# n-gram, bench, cache, chargement, agentic), dont il faut ensuite recopier les
# chiffres à la main dans un tableau. Chacune dure de quelques minutes à une
# heure et la machine n'a qu'un GPU : les lancer une par une demande d'attendre
# devant, et les sorties se perdent dans le terminal. Ce script les enchaîne en
# une commande, journalise chaque étape dans son fichier et écrit un
# récapitulatif au format du tableau de l'étape 6, prêt à coller dans le
# commentaire du bloc lib/models.sh et dans docs/HISTORIQUE.md.
#
# Quand l'utiliser : le modèle est déclaré, le GGUF téléchargé, le service
# redémarré, un premier --spec-test montre une acceptance (fin de l'étape 2 de
# la skill). À lancer sur la machine du service (bigchuck).
#
# Ce que ce script NE fait PAS :
#   - le test isolé hors service (tools/spec-isolate.sh), qui se joue AVANT la
#     déclaration du modèle, sur un llama-server jetable ;
#   - --spec-tune (longueur de draft MTP, étape 4) : il reste manuel, il
#     n'existe que pour draft-mtp et il ÉCRIT dans spec-nmax.conf ;
#   - --spec-ngram-tune : sa référence « sans spéculation » n'a pas de sens
#     quand un drafter externe est servi, et il écrit dans spec-ngram.conf ;
#     l'étape n-gram passe donc par --spec-ab, qui ne compare que des variantes
#     réellement servies ;
#   - toute écriture dans les .conf ou dans lib/models.sh : --spec-ab ne
#     journalise rien, le choix retenu reste à reporter à la main avec ses
#     chiffres. Aucune commande de la suite n'écrit de .conf ; seuls les
#     journaux de logs/ des --bench* sont alimentés.
#
# Usage :
#   tools/qualif-modele.sh <section> [options]
#     --passes N         passes de --spec-ab ET de --bench
#                        (défaut : 4 pour --spec-ab, 3 pour --bench)
#     --size-m LISTE     candidats n-gram comparés par --spec-ab
#                        (défaut 7,15,47 ; « - » = pas d'étape n-gram)
#     --sans-agentic     ne pas lancer --bench-agentic (lancé par défaut, 3 passes)
#     --sans-cache       ne pas lancer --bench-cache
#     --sans-load        ne pas lancer --bench-load
#     --tag TAG          nom du dossier de sortie (défaut <section>-<date-heure>)
#     --help             cet écran
#
# Le spec-type réellement servi est lu dans status.args de /v1/models (jamais
# le ini, que le routeur ne relit qu'au démarrage) : c'est lui qui décide du
# drafter cité dans les variantes de --spec-ab et de la présence de l'étape
# n-gram.
#
# Sorties, toutes dans logs/qualif/<tag>/ (donc non versionné) :
#   01-sanity.log   02-ngram-refactor.log  03-ngram-generic.log  04-bench.log
#   05-cache.log    06-load.log            07-agentic.log
#   resume.md       en-tête (section, machine, moteur, mode EC, device, date), tableau
#                   « Configuration | Device | Prompt t/s | Gen t/s |
#                   Acceptance | Source », meilleur size-m, verdict agentic.
# resume.md est affiché à la fin.
#
# Plusieurs sous-commandes (--spec-ab, --bench-load)
# redémarrent le service et rendent la main SANS attendre son retour : chaque
# étape commence donc par attendre /health ET une liste /v1/models exploitable
# (_attendre_service), sinon la suivante sort aussitôt sur « ne répond pas ».
#
# Une étape en échec n'arrête pas les suivantes : elle est marquée ÉCHEC dans
# resume.md et le code de retour final est non nul. Deux exceptions qui
# arrêtent le script : les vérifications initiales (section servie, service
# actif, aucune autre mesure en cours) et l'étape 1 de justesse, dont l'échec
# rend toutes les mesures suivantes sans objet.
#
# Toutes les invocations de ./setup-llm.sh reçoivent leur entrée de /dev/null :
# entrée non interactive, donc pas de question ni de restart automatique.
# Un seul GPU : tout est séquentiel, rien n'est lancé en arrière-plan.
# =============================================================================
set -euo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

_usage() {
  cat <<'EOF'
usage : tools/qualif-modele.sh <section> [options]

Enchaîne les étapes 3, 5, 6 et 7 de la skill ajout-modele sur un modèle déjà
déclaré et servi, et écrit logs/qualif/<tag>/resume.md (tableau de perfs).

  --passes N         passes de --spec-ab et de --bench (défaut 4 / 3)
  --size-m LISTE     candidats n-gram comparés (défaut 7,15,47 ; « - » = pas
                     d'étape n-gram)
  --sans-agentic     ne pas lancer --bench-agentic (sinon 3 passes)
  --sans-cache       ne pas lancer --bench-cache
  --sans-load        ne pas lancer --bench-load
  --tag TAG          dossier de sortie (défaut <section>-<date-heure>)
  --help             cet écran

N'écrit ni les .conf ni lib/models.sh : les chiffres restent à reporter à la
main. Ne joue ni le test isolé (tools/spec-isolate.sh) ni --spec-tune.
S'arrête si la question de contrôle (--bench-sanity) échoue.
EOF
}

# --- Ligne de commande ------------------------------------------------------
SECTION=""
PASSES_SPEC=4
PASSES_BENCH=3
SIZE_M="7,15,47"
AVEC_AGENTIC=1
AVEC_CACHE=1
AVEC_LOAD=1
TAG=""

# Option à valeur appelée sans sa valeur : sans ce garde-fou, c'est le « shift 2 »
# qui échoue (moins d'arguments que demandé) et, sous set -e, le script sort en
# silence avec le code 1, sans dire ce qui manque.
_valeur() { [[ $# -ge 2 ]] || { echo "Valeur manquante pour l'option '$1'" >&2; exit 1; }; }

[[ $# -ge 1 ]] || { _usage >&2; exit 1; }
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help | -h)    _usage; exit 0 ;;
    --passes)       _valeur "$@"; PASSES_SPEC="$2"; PASSES_BENCH="$2"; shift 2 ;;
    --size-m)       _valeur "$@"; SIZE_M="$2"; shift 2 ;;
    --tag)          _valeur "$@"; TAG="$2"; shift 2 ;;
    --sans-agentic) AVEC_AGENTIC=0; shift ;;
    --sans-cache)   AVEC_CACHE=0; shift ;;
    --sans-load)    AVEC_LOAD=0; shift ;;
    -*)             echo "Option inconnue : '$1'" >&2; _usage >&2; exit 1 ;;
    *)
      [[ -z "$SECTION" ]] || { echo "Une seule section à la fois : '$SECTION' puis '$1'" >&2; exit 1; }
      SECTION="$1"; shift ;;
  esac
done
[[ -n "$SECTION" ]] || { _usage >&2; exit 1; }
[[ "$PASSES_SPEC"  =~ ^[0-9]+$ && "$PASSES_SPEC"  -ge 2 ]] || { echo "--passes invalide : '$PASSES_SPEC' (>= 2)" >&2; exit 1; }
[[ "$PASSES_BENCH" =~ ^[0-9]+$ && "$PASSES_BENCH" -ge 2 ]] || { echo "--passes invalide : '$PASSES_BENCH' (>= 2)" >&2; exit 1; }
[[ -n "$TAG" ]] || TAG="$SECTION-$(date '+%Y%m%d-%H%M')"

# lib/common.sh apporte SPEC_TEST_URL, SERVICE_NAME, _llama_build (étiquette de
# moteur, lue sur les LABEL de l'image qui sert) et les helpers info/warn/error.
# Il attend SCRIPT_DIR : c'est la racine du dépôt, comme pour setup-llm.sh.
# runtime.sh donne _image_ref/_image_label (étiquette de moteur), compose.sh les
# chemins du compose généré, svc.sh les _svc_* (état du service).
SCRIPT_DIR="$ROOT_DIR"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/common.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/runtime.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/compose.sh"
# shellcheck source=/dev/null
source "$ROOT_DIR/lib/svc.sh"

OUT="$LOG_DIR/qualif/$TAG"
RESUME="$OUT/resume.md"

# --- Vérifications initiales ------------------------------------------------
command -v curl    >/dev/null || error "curl introuvable"
command -v python3 >/dev/null || error "python3 introuvable"
[[ -x "$ROOT_DIR/setup-llm.sh" ]] || error "setup-llm.sh introuvable dans $ROOT_DIR"

# Garde-fou : une seule mesure à la fois sur la machine (un seul GPU). Même
# logique que tools/spec-isolate.sh, motif ANCRÉ sur le début de la ligne de
# commande pour ne pas refuser à cause d'un shell d'attente qui contient la
# chaîne (constaté sur bigchuck le 15/09/2026).
MESURE_RE='^([^ ]*sh )?[^ ]*setup-llm\.sh --(bench|spec)'
ISOLE_RE='^([^ ]*sh )?[^ ]*spec-isolate\.sh '
if pgrep -f "$MESURE_RE" >/dev/null 2>&1; then
  pgrep -af "$MESURE_RE" >&2 || true
  error "Une mesure du dépôt tourne déjà (setup-llm.sh --bench* / --spec*), attendre sa fin (un seul GPU)."
fi
if pgrep -f "$ISOLE_RE" >/dev/null 2>&1; then
  pgrep -af "$ISOLE_RE" >&2 || true
  error "tools/spec-isolate.sh tourne déjà, attendre sa fin (un seul GPU)."
fi
# Filtrage par docker lui-même plutôt que « docker ps | grep -q » : sous
# pipefail, grep -q sort dès la 1re correspondance et docker ps peut alors
# mourir sur EPIPE (code 141), ce qui rendait le garde-fou faussement négatif.
# Le filtre --filter name= est une ERE ancrée côté docker.
if command -v docker >/dev/null 2>&1; then
  CONTENEURS_AGENTIC="$(docker ps --filter 'name=^bench-agentic-' --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "$CONTENEURS_AGENTIC" ]]; then
    sed 's/^/  /' <<<"$CONTENEURS_AGENTIC" >&2
    error "Un conteneur bench-agentic-* tourne (--bench-agentic en cours), attendre sa fin (un seul GPU)."
  fi
fi

# Verrou : deux qualif-modele.sh en parallèle ne se voient pas par pgrep sur
# setup-llm.sh (leurs mesures ne tournent pas au même instant), alors que la
# machine n'a qu'un GPU. Le descripteur reste ouvert pour toute la vie du
# script : le verrou tombe tout seul à la sortie, y compris sur Ctrl-C ou kill.
QUALIF_LOCK="$LOG_DIR/qualif.lock"
if command -v flock >/dev/null 2>&1; then
  exec {QUALIF_LOCK_FD}>"$QUALIF_LOCK" || error "Verrou impossible à ouvrir : $QUALIF_LOCK"
  flock -n "$QUALIF_LOCK_FD" \
    || error "Un autre tools/qualif-modele.sh tourne déjà (verrou $QUALIF_LOCK), attendre sa fin (un seul GPU)."
else
  # Repli sans flock (util-linux absent) : pgrep sur le script, en excluant
  # notre propre PID et nos enfants éventuels.
  QUALIF_RE='^([^ ]*sh )?[^ ]*qualif-modele\.sh '
  QUALIF_AUTRES="$(pgrep -f "$QUALIF_RE" 2>/dev/null | grep -v "^$$\$" || true)"
  if [[ -n "$QUALIF_AUTRES" ]]; then
    pgrep -af "$QUALIF_RE" >&2 || true
    error "Un autre tools/qualif-modele.sh tourne déjà (PID $(tr '\n' ' ' <<<"$QUALIF_AUTRES")), attendre sa fin (un seul GPU)."
  fi
fi

_svc_is_active \
  || error "Service $SERVICE_NAME inactif : ./setup-llm.sh --start"
curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
  || error "llama-server ne répond pas sur $SPEC_TEST_URL"

MODELS_JSON="$(curl -s --max-time 30 "$SPEC_TEST_URL/v1/models" 2>/dev/null || true)"
[[ -n "$MODELS_JSON" ]] || error "$SPEC_TEST_URL/v1/models n'a rien renvoyé."
# La liste servie fait foi : le ini n'est relu qu'au démarrage du routeur, une
# section ajoutée depuis vit dans lib/models.sh mais pas dans le serveur.
SECTIONS_SERVIES="$(printf '%s' "$MODELS_JSON" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data", []):
    print(m.get("id", ""))
' 2>/dev/null || true)"
if ! grep -Fxq "$SECTION" <<<"$SECTIONS_SERVIES"; then
  echo "Sections servies :" >&2
  sed 's/^/  /' <<<"$SECTIONS_SERVIES" >&2
  error "Section '$SECTION' absente du ini servi : régénérer (--preload) puis ./setup-llm.sh --restart."
fi

# --- Ce qui est réellement servi (status.args, pas le ini) ------------------
_arg_servi() {
  printf '%s' "$MODELS_JSON" \
    | python3 "$ROOT_DIR/py/spec_server_nmax.py" "$SECTION" "$1" 2>/dev/null || true
}
SPEC_TYPE="$(_arg_servi --spec-type)"
NMAX="$(_arg_servi --spec-draft-n-max)"
DEV="$(_arg_servi --device)"
# Repli quand status.args ne porte pas --device (le modèle hérite du défaut du
# parc). « ROCm0 » DUPLIQUE ici la valeur de DEFAULT_DEVICE (lib/models.sh),
# qui n'est pas sourcé : ce script ne source que lib/common.sh, exprès, pour ne
# jamais confondre le ini du script avec ce que le serveur sert réellement
# (AGENTS.md, règle 5). Si le défaut du parc change, changer aussi cette ligne.
[[ -n "$DEV" ]] || DEV="${DEFAULT_DEVICE:-ROCm0}"

# Drafter et type de n-gram servis, lus jeton par jeton : « ngram-map-k » et
# « ngram-map-k4v » sont deux clés ini distinctes (spec-<jeton>-size-m), et un
# test par sous-chaîne les confondrait.
DRAFTER=""
NGRAM_TYPE=""
_split_spec_type() {
  local jeton
  local IFS=','
  for jeton in $SPEC_TYPE; do
    case "$jeton" in
      draft-mtp | draft-dflash | draft-dspark) DRAFTER="$jeton" ;;
      ngram-map-k | ngram-map-k4v)             NGRAM_TYPE="$jeton" ;;
    esac
  done
  return 0
}
_split_spec_type
SIZE_M_SERVI=""
if [[ -n "$NGRAM_TYPE" ]]; then
  SIZE_M_SERVI="$(_arg_servi "--spec-$NGRAM_TYPE-size-m")"
fi

mkdir -p "$OUT"
MOTEUR="$(_llama_build)"
# Mode d'alimentation de l'APU au moment de la campagne (cf. _ec_power_mode,
# lib/common.sh) : en "balanced" le décode perd 10 à 13 %, de quoi rendre deux
# qualifications incomparables. Jamais bloquant : "inconnu" si le sysfs se tait.
EC_MODE="$(_ec_power_mode)"
DEBUT_GLOBAL="$(date '+%F %T')"

info "qualif-modele '$SECTION' : sortie $OUT"
info "  moteur $MOTEUR, mode EC $EC_MODE, device servi $DEV, machine $(hostname)"
info "  spec-type servi : ${SPEC_TYPE:-aucun} (drafter ${DRAFTER:-aucun}, n-gram ${NGRAM_TYPE:-aucun}, size-m ${SIZE_M_SERVI:-n/c}, n-max ${NMAX:-n/c})"
warn "Un seul GPU : les étapes s'enchaînent en séquence. Certaines redémarrent $SERVICE_NAME."

# --- Machinerie des étapes --------------------------------------------------
# Statuts collectés pour resume.md : "libellé|statut|log|durée".
ETAPES=()
RC_GLOBAL=0

# Attente du service entre deux étapes.
#
# Constaté sur bigchuck avant la bascule en conteneur : --spec-ab se terminait
# par _spec_ab_restore (lib/spec.sh) qui régénérait le ini et relançait
# $SERVICE_NAME SANS attendre le retour de /health ; l'étape suivante démarrait
# donc sur un serveur encore éteint. C'est maintenant _svc_restart qui attend
# (lib/svc.sh), mais la garde reste ici : toutes les sous-commandes appelées
# commencent par un
# « curl -sf /health || error » à froid, sans réessai (lib/bench/bench.sh:190,
# lib/bench/bench-cache.sh:32, lib/bench/bench-agentic.sh:170,
# lib/spec.sh:145) : elles échouaient immédiatement. --bench-load passait par
# hasard, parce qu'il redémarre et attend lui-même (lib/bench/bench-load.sh:45).
#
# Depuis la bascule en conteneur, _svc_restart attend /health lui-même
# (_svc_wait_ready, lib/svc.sh) et les boucles recopiées dans lib/ ont disparu.
# Cette attente-ci reste néanmoins utile, avec une condition de plus : /health répond dès que le routeur écoute, AVANT
# d'avoir fini de précharger et de publier sa liste de modèles, et c'est cette
# liste que lisent toutes les mesures. On attend donc aussi un /v1/models
# exploitable. Plafond 180 s (contre 120 s dans lib/) : les préchargés d'un
# gros parc sont plus longs à revenir qu'un modèle seul.
#
# Jamais bloquant : au-delà du plafond on avertit et on lance quand même, pour
# que l'échec soit celui de l'étape (journalisé, marqué ÉCHEC dans resume.md)
# et non un arrêt muet de tout l'enchaînement.
_attendre_service() {
  local t=0 annonce=0 json
  while :; do
    if curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1; then
      # Pas de « curl | grep -q » : sous pipefail, grep -q sort au 1er match et
      # curl meurt sur EPIPE (141), ce qui ferait boucler indéfiniment.
      json="$(curl -sf --max-time 10 "$SPEC_TEST_URL/v1/models" 2>/dev/null || true)"
      if [[ "$json" == *'"data"'* ]]; then
        [[ "$annonce" -eq 0 ]] || info "  $SERVICE_NAME prêt après $t s."
        return 0
      fi
    fi
    if [[ "$annonce" -eq 0 ]]; then
      info "  attente de $SERVICE_NAME sur $SPEC_TEST_URL (180 s max)..."
      annonce=1
    fi
    if [[ "$t" -ge 180 ]]; then
      warn "  $SERVICE_NAME ne répond toujours pas après 180 s : l'étape est lancée quand même."
      warn "  Diagnostic : ./setup-llm.sh --logs --tail 50"
      return 0
    fi
    sleep 2
    t=$(( t + 2 ))
  done
}

_etape_sautee() {
  local libelle="$1" raison="$2"
  info "──── $libelle : SAUTÉE ($raison)"
  ETAPES+=("$libelle|SAUTÉE ($raison)|-|-")
  return 0
}

# _etape <fichier de log> <libellé> <commande...>
# Sortie dupliquée à l'écran et dans le log. L'entrée vient de /dev/null :
# les commandes du dépôt ne posent alors aucune question et ne redémarrent
# rien d'elles-mêmes (cf. AGENTS.md).
_etape() {
  local fichier="$1" libelle="$2"; shift 2
  local log="$OUT/$fichier" t0 t1 rc=0 duree
  # L'étape précédente a pu redémarrer le service sans l'attendre : le laisser
  # revenir AVANT de lancer, sinon la commande sort sur « ne répond pas ».
  # L'attente n'est pas comptée dans la durée de l'étape (t0 après).
  _attendre_service
  t0="$(date +%s)"
  echo ""
  info "──── $libelle : début $(date '+%T') ────"
  {
    echo "# $libelle"
    echo "# début   : $(date '+%F %T')"
    echo "# commande: $*"
    echo ""
  } > "$log"
  if "$@" < /dev/null 2>&1 | tee -a "$log"; then rc=0; else rc=$?; fi
  t1="$(date +%s)"
  duree="$(( t1 - t0 ))s"
  echo "" >> "$log"
  echo "# fin     : $(date '+%F %T') (code $rc, $duree)" >> "$log"
  if [[ "$rc" -eq 0 ]]; then
    info "──── $libelle : fin $(date '+%T') ($duree)"
    ETAPES+=("$libelle|OK|$fichier|$duree")
  else
    warn "──── $libelle : ÉCHEC (code $rc) à $(date '+%T') ($duree), voir $log"
    ETAPES+=("$libelle|ÉCHEC (code $rc)|$fichier|$duree")
    RC_GLOBAL=1
  fi
  return 0
}

_llm() { "$ROOT_DIR/setup-llm.sh" "$@"; }

# --- Étape 3 de la skill : justesse (--bench-sanity), BLOQUANTE -------------
# Le moteur du service n'expose qu'un device (image ROCm, cf. lib/models.sh) :
# --bench-devices a disparu le 18/09/2026, et l'étape 3 devient ce qui en
# faisait la valeur : la question de contrôle. Elle est jouée EN PREMIER et
# elle ARRÊTE la qualification si la réponse est fausse : mesurer les t/s d'un
# moteur qui produit du charabia n'a aucun sens, et c'est exactement ce qui est
# arrivé deux fois (DeepSeek V4 et Qwen3-Coder-Next couronnés sur un ROCm qui
# répondait « Nous dev dev dev » et « LAMPAMPAMP » à 500 t/s).
# C'est la seule étape bloquante de l'enchaînement ; toutes les autres se
# contentent d'être marquées ÉCHEC.
_etape 01-sanity.log "justesse (--bench-sanity)" _llm --bench-sanity "$SECTION"
if [[ "${ETAPES[-1]}" != *"|OK|"* ]]; then
  warn "Question de contrôle en échec sur '$SECTION' : la sortie du moteur est"
  warn "  fausse ou dégénérée. Toute mesure de débit serait sans objet."
  warn "  Relire $OUT/01-sanity.log et le texte généré avant d'aller plus loin :"
  warn "    ./setup-llm.sh --logs --tail 400 | grep -i 'warn\|error\|cpu'"
  error "Qualification arrêtée à l'étape 1 (justesse)."
fi

# --- Étape 5 de la skill : longueur de draft n-gram, par --spec-ab ---------
# --spec-ngram-tune est volontairement évité : il mesure une référence « sans
# spéculation » qui ne veut rien dire quand un drafter externe est servi, et il
# écrit dans spec-ngram.conf. --spec-ab ne compare que des configurations
# réellement servies et n'écrit rien.
SRC_REFACTOR="--spec-ab, $PASSES_SPEC passes (spec-refactor.txt)"
SRC_GENERIC="--spec-ab, $PASSES_SPEC passes (spec-test.txt)"
if [[ -z "$NGRAM_TYPE" ]]; then
  _etape_sautee "n-gram (--spec-ab, spec-refactor.txt)" "pas de ngram-map-k dans le spec-type servi"
  _etape_sautee "n-gram (--spec-ab, spec-test.txt)" "pas de ngram-map-k dans le spec-type servi"
elif [[ "$SIZE_M" == "-" ]]; then
  _etape_sautee "n-gram (--spec-ab, spec-refactor.txt)" "--size-m -"
  _etape_sautee "n-gram (--spec-ab, spec-test.txt)" "--size-m -"
else
  # Ordre voulu : le drafter seul (ou aucune spéculation s'il n'y en a pas),
  # puis la configuration courante, puis un size-m par candidat non servi.
  VARIANTES=()
  if [[ -n "$DRAFTER" ]]; then
    VARIANTES+=("spec-type=$DRAFTER")
  else
    VARIANTES+=("spec-type=none")
  fi
  VARIANTES+=("base")
  _k=""
  for _k in $(tr ',' ' ' <<<"$SIZE_M"); do
    [[ "$_k" =~ ^[0-9]+$ ]] || { warn "candidat size-m ignoré (pas un entier) : '$_k'"; continue; }
    # Le candidat déjà servi est couvert par la variante « base ». Si le size-m
    # servi est inconnu (flag absent de status.args : le moteur applique son
    # défaut), on ne dédoublonne rien et on mesure tous les candidats.
    if [[ -n "$SIZE_M_SERVI" && "$_k" == "$SIZE_M_SERVI" ]]; then continue; fi
    VARIANTES+=("spec-$NGRAM_TYPE-size-m=$_k")
  done
  _etape 02-ngram-refactor.log "n-gram (--spec-ab, spec-refactor.txt)" \
    _llm --spec-ab "$SECTION" "$PASSES_SPEC" - "${VARIANTES[@]}"

  # Second passage sur le prompt générique : spec-test.txt n'a pas de hits
  # n-gram, il dit donc ce que coûte (ou non) le bloc n-gram hors édition de
  # code. Deux variantes suffisent, les tailles ne s'y départagent pas.
  VARIANTES_GEN=()
  if [[ -n "$DRAFTER" ]]; then
    VARIANTES_GEN+=("spec-type=$DRAFTER")
  else
    VARIANTES_GEN+=("spec-type=none")
  fi
  VARIANTES_GEN+=("base")
  _etape 03-ngram-generic.log "n-gram (--spec-ab, spec-test.txt)" \
    _llm --spec-ab "$SECTION" "$PASSES_SPEC" spec-test.txt "${VARIANTES_GEN[@]}"
fi

# --- Étape 6 de la skill : bench final, cache, chargement ------------------
_etape 04-bench.log "bench final (--bench, $PASSES_BENCH passes)" \
  _llm --bench "$SECTION" "$PASSES_BENCH"

if [[ "$AVEC_CACHE" -eq 1 ]]; then
  _etape 05-cache.log "cache de prompt (--bench-cache)" _llm --bench-cache "$SECTION"
else
  _etape_sautee "cache de prompt (--bench-cache)" "--sans-cache"
fi

if [[ "$AVEC_LOAD" -eq 1 ]]; then
  _etape 06-load.log "chargement (--bench-load)" _llm --bench-load "$SECTION"
else
  _etape_sautee "chargement (--bench-load)" "--sans-load"
fi

# --- Étape 7 de la skill : boucle agentic réelle ---------------------------
if [[ "$AVEC_AGENTIC" -eq 0 ]]; then
  _etape_sautee "boucle agentic (--bench-agentic)" "--sans-agentic"
elif ! command -v docker >/dev/null 2>&1; then
  _etape_sautee "boucle agentic (--bench-agentic)" "docker absent"
else
  _etape 07-agentic.log "boucle agentic (--bench-agentic, 3 passes)" \
    _llm --bench-agentic "$SECTION" 3
fi

# =============================================================================
# resume.md : parsing des sorties
#
# Les commandes du dépôt émettent des codes couleur ANSI (info/warn de
# lib/common.sh) : tout parsing passe d'abord par _sans_ansi. Aucun parsing ne
# doit faire échouer le script : tout ce qui ne matche pas vaut « n/c ».
# =============================================================================
_sans_ansi() {
  [[ -f "$1" ]] || return 0
  sed 's/\x1b\[[0-9;]*m//g' "$1" 2>/dev/null || true
}

# Lignes du bilan de --spec-ab (lib/spec.sh, cmd_spec_ab) : un `column -t`
# dont l'en-tête est « variante  gen t/s  vs 1re  acceptance ». La variante ne
# contient jamais d'espace (clé=val;clé=val ou « base »), donc $1 = variante,
# $2 = gen, $NF = acceptance ; la colonne « vs 1re » du milieu compte un ou
# deux champs selon qu'elle vaut « +1.2 % » ou « ? », d'où le $NF.
# Le prefill n'est pas journalisé par --spec-ab : colonne « n/c », comme dans
# le tableau d'exemple de la skill.
_lignes_spec_ab() {
  local log="$1" src="$2"
  _sans_ansi "$log" | awk -v dev="$DEV" -v src="$src" '
    /Bilan spec-ab/ { dedans = 1; next }
    /Rien d/        { dedans = 0 }
    dedans && NF >= 3 && $1 != "variante" {
      printf "| %s | %s | n/c | %s | %s | %s |\n", $1, dev, $2, $NF, src
    }'
}

# Ligne de bilan de --bench (lib/bench/bench.sh, _bench_one) :
#   « → prefill 359 t/s, décode 32.6 t/s (médianes hors passe 1), acceptance 0.595 »
# Le prefill peut porter un « * » (passe 1 contaminée par le cache) : conservé
# tel quel, c'est l'avertissement du bench.
_ligne_bench() {
  local ligne pp gen acc
  ligne="$(_sans_ansi "$OUT/04-bench.log" | grep -- '→ prefill' | tail -1 || true)"
  [[ -n "$ligne" ]] || { echo "| ${SPEC_TYPE:-configuration servie} | $DEV | n/c | n/c | n/c | --bench, $PASSES_BENCH passes (bench-context + bench-task) |"; return 0; }
  pp="$(sed -n 's/.*prefill \([0-9.]*\*\?\) t\/s.*/\1/p' <<<"$ligne")"
  gen="$(sed -n 's/.*décode \([0-9.]*\) t\/s.*/\1/p' <<<"$ligne")"
  acc="$(sed -n 's/.*acceptance \([0-9.]*\).*/\1/p' <<<"$ligne")"
  echo "| ${SPEC_TYPE:-configuration servie} | $DEV | ${pp:-n/c} | ${gen:-n/c} | ${acc:-n/c} | --bench, $PASSES_BENCH passes (bench-context + bench-task) |"
}

# Lecture de --bench-cache (lib/bench/bench-cache.sh) : les trois lignes
# « suite : N % … », « édition : N % … », « identique : N % … » du bloc
# « ──── lecture ──── ». (Les lignes de py/cache_stats.py, « 2. suite (tour
# suivant)  prompt … », n'ont pas de « : » après l'étiquette : pas de collision.)
_part_cache() {
  local quoi="$1" v
  v="$(_sans_ansi "$OUT/05-cache.log" | sed -n "s/.*$quoi : \([0-9]*\) %.*/\1/p" | tail -1 || true)"
  echo "${v:-n/c}"
}

# Ligne de --bench-load (lib/bench/bench-load.sh) :
#   « chargement + 1er token : 42.1 s (17G, Vulkan0) ; à chaud : 380 ms »
_ligne_load() {
  local ligne froid chaud
  ligne="$(_sans_ansi "$OUT/06-load.log" | grep -- 'chargement + 1er token' | tail -1 || true)"
  [[ -n "$ligne" ]] || { echo "n/c"; return 0; }
  froid="$(sed -n 's/.*chargement + 1er token : \([0-9.]*\) s.*/\1/p' <<<"$ligne")"
  chaud="$(sed -n 's/.*à chaud : \([0-9]*\) ms.*/\1/p' <<<"$ligne")"
  echo "${froid:-n/c} s à froid (chargement + 1er token), ${chaud:-n/c} ms à chaud"
}

# Bilan de --bench-agentic (lib/bench/bench-agentic.sh, _bench_agentic_medianes) :
#   «   edit                     : 3/3   12.4 s, prompt … »
# L'appel froid de la même table porte « PASS » et non « n/n » : il ne matche
# pas, c'est voulu (ce n'est pas un scénario).
_verdict_agentic() {
  local v
  v="$(_sans_ansi "$OUT/07-agentic.log" \
    | sed -n 's/^[[:space:]]*\([^:]*[^ :]\)[[:space:]]*:[[:space:]]*\([0-9]\+\/[0-9]\+\).*/\1 \2/p' \
    | awk '!vu[$1]++ { printf "%s%s %s", (NR>1 ? ", " : ""), $1, $2 } END { print "" }' || true)"
  echo "${v:-n/c}"
}

# Meilleur size-m du bilan spec-refactor : la meilleure gen t/s parmi « base »
# (= la valeur servie) et les variantes « …-size-m=K ». Les variantes de
# drafter seul sont hors concours (elles ne portent pas de n-gram).
_meilleur_size_m() {
  local v
  v="$(_sans_ansi "$OUT/02-ngram-refactor.log" | awk -v servi="${SIZE_M_SERVI:-valeur par défaut du moteur}" '
    /Bilan spec-ab/ { dedans = 1; next }
    /Rien d/        { dedans = 0 }
    dedans && NF >= 3 && $1 != "variante" {
      m = ""
      if ($1 == "base") m = servi
      else if (match($1, /size-m=[0-9]+$/)) m = substr($1, RSTART + 7)
      if (m != "" && ($2 + 0) > meilleur) { meilleur = $2 + 0; retenu = m }
    }
    END { if (retenu != "") printf "%s (%s t/s sur spec-refactor.txt)\n", retenu, meilleur }' || true)"
  echo "${v:-n/c}"
}

# Verdict de la question de contrôle (lib/bench/bench.sh, _bench_sanity_one,
# qui délègue l'affichage à py/check_answer.py). L'étape étant bloquante, si on
# arrive ici elle est passée : la ligne sert à le tracer dans resume.md.
_verdict_sanity() {
  local v
  v="$(_sans_ansi "$OUT/01-sanity.log" | grep -i 'justesse\|attendu\|trouv' | tail -1 || true)"
  echo "${v:-n/c}"
}

{
  echo "### $SECTION : $(hostname), moteur $MOTEUR, mode EC $EC_MODE, device $DEV, $(date '+%d/%m/%Y')"
  echo ""
  echo "- section : \`$SECTION\`"
  echo "- machine : $(hostname)"
  echo "- moteur : $MOTEUR"
  echo "- mode EC : $EC_MODE (alimentation de l'APU ; ne comparer qu'à même mode)"
  echo "- device servi : $DEV"
  echo "- spec-type servi : ${SPEC_TYPE:-aucun} (n-max ${NMAX:-n/c}${NGRAM_TYPE:+, $NGRAM_TYPE size-m ${SIZE_M_SERVI:-n/c}})"
  echo "- lancé le : $DEBUT_GLOBAL, terminé le : $(date '+%F %T')"
  echo "- journaux : \`$OUT\`"
  echo ""
  echo "| Configuration | Device | Prompt t/s | Gen t/s | Acceptance | Source |"
  echo "|---|---|---|---|---|---|"
  _lignes_spec_ab "$OUT/02-ngram-refactor.log" "$SRC_REFACTOR"
  _lignes_spec_ab "$OUT/03-ngram-generic.log" "$SRC_GENERIC"
  _ligne_bench
  echo ""
  echo "- Meilleur size-m : $(_meilleur_size_m)"
  echo "- Justesse (--bench-sanity, bloquante) : $(_verdict_sanity)"
  echo "- Cache de prompt : suite $(_part_cache suite) %, édition $(_part_cache édition) %, identique $(_part_cache identique) %"
  echo "- Chargement : $(_ligne_load)"
  if [[ "$AVEC_AGENTIC" -eq 1 ]]; then
    echo "- Agentic : $(_verdict_agentic)"
  fi
  echo ""
  echo "| Étape | Statut | Log | Durée |"
  echo "|---|---|---|---|"
  for _e in ${ETAPES[@]+"${ETAPES[@]}"}; do
    IFS='|' read -r _l _s _f _d <<<"$_e"
    echo "| $_l | $_s | $_f | $_d |"
  done
  echo ""
  echo "Rien n'a été écrit dans lib/models.sh ni dans les .conf : reporter à"
  echo "la main le"
  echo "réglage retenu avec ces chiffres, dans le commentaire du bloc, le README"
  echo "et docs/HISTORIQUE.md. --spec-tune (n-max MTP) reste à jouer séparément."
} > "$RESUME"

echo ""
info "════════ resume.md ($RESUME) ════════"
cat "$RESUME"
echo ""
if [[ "$RC_GLOBAL" -ne 0 ]]; then
  warn "Au moins une étape a échoué, voir la table des étapes ci-dessus et les logs de $OUT."
fi
exit "$RC_GLOBAL"
