# lib/common.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → gufo → help

# =============================================================================
# Helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# Propose un restart du service si actif - appelé en fin de setup /
# update / cleanup / preload (config ou poids modifiés). Rappel : les poids
# déjà mmap'és restent sur l'ancien inode tant que le serveur n'a pas redémarré.
# Non-interactif : jamais de restart automatique, juste le rappel.
_maybe_restart_service() {
  _svc_is_active || return 0
  local reply="n"
  if [[ -t 0 ]]; then
    read -r -p "Le service $SERVICE_NAME tourne — redémarrer maintenant pour appliquer ? [O/n] " reply
    reply="${reply:-o}"
  else
    warn "Service $SERVICE_NAME actif — redémarrage non effectué (entrée non interactive)."
    warn "  Appliquer : ./setup-llm.sh --restart"
    return 0
  fi
  if [[ "$reply" =~ ^[oOyY]$ ]]; then
    info "Redémarrage de $SERVICE_NAME..."
    if _svc_restart; then
      info "✅ $SERVICE_NAME redémarré."
    else
      warn "Redémarrage en échec - voir : ./setup-llm.sh --logs --tail 50"
    fi
  else
    info "Redémarrage sauté - appliquer plus tard : ./setup-llm.sh --restart"
  fi
}

# REFRESH=1 : on ne court-circuite plus sur "fichier déjà présent", on laisse
#   `hf download` comparer les etags et ne retélécharger que ce qui a bougé.
# ONLY : si non vide, ne traite que le modèle dont le dossier porte ce nom.
REFRESH=0
ONLY=""

# Clé d'un modèle = premier segment sous $MODELS_BASE
# (fonctionne pour les fichiers plats comme pour les dossiers de shards)
_key() {
  local p="${1#"$MODELS_BASE"/}"
  echo "${p%%/*}"
}

_skip() {
  [[ -n "$ONLY" && "$(_key "$1")" != "$ONLY" ]]
}

# _dl <cible absolue> <repo> <chemin dans le repo>
#   hf recrée sous --local-dir le chemin relatif au repo : local-dir est donc
#   la cible amputée de ce chemin (= le dossier modèle), pas dirname, sinon une
#   entrée en sous-dossier (ex : MTP/x.gguf) atterrit dans MTP/MTP/x.gguf.
_dl() {
  local target="$1" repo="$2" entry="$3"
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement $(basename "$target")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" "$entry" --local-dir "${target%/"$entry"}"
}

_dl_shard() {
  local target="$1" repo="$2" glob="$3"
  local shard_dir dest_dir
  shard_dir="$(dirname "$target")"
  dest_dir="$(dirname "$shard_dir")"
  _skip "$target" && return 0
  if [[ -f "$target" && "$REFRESH" -eq 0 ]]; then
    info "$(basename "$target") déjà présent, skip."
    return
  fi
  info "Téléchargement shards $(basename "$shard_dir")..."
  HF_XET_HIGH_PERFORMANCE=1 hf download "$repo" --include "$glob" --local-dir "$dest_dir"
}

# =============================================================================
# CHEMINS
# =============================================================================

# (le dépôt ne posait plus qu'un PATH ici : $HOME/.local/bin en tête, où
#  vivaient les liens du fork strix-llama.cpp. Retiré le 18/09/2026 avec le
#  fork : plus AUCUN binaire llama-* de l'hôte n'est appelé par ce dépôt, tout
#  passe par l'image (_dk_run, lib/runtime.sh) ou par le conteneur du service.)

MODELS_BASE="$HOME/models"
CONFIG_DIR="$MODELS_BASE"

# Port du routeur llama-server (service --start et mesures via l'API)
SERVER_PORT=8009

# Conteneur du moteur alternatif gufo quand il tient SERVER_PORT à la place du
# service (runtime-gufo/docker-compose.yml, lib/gufo.sh ; docs/GUFO.md).
# Surchargeable pour les bancs (gufo-banc).
GUFO_CONTENEUR="${GUFO_CONTENEUR:-gufo-8009}"

# (BENCH_CONF / bench-devices.conf, le device retenu par GGUF, a été retiré le
#  18/09/2026 : le moteur du service est une image construite en HIP seul, elle
#  n'expose qu'un device. Le fichier reste peut-être sur la machine, il n'est
#  plus lu par personne et peut être supprimé.)

# =============================================================================
# PRÉCHARGEMENT (always-on)
#
# La liste des modèles préchargés (load-on-startup) vit dans preload.conf
# (à côté du script, comme bench-devices.conf — local, non versionné),
# alimenté par la sélection interactive à cases à cocher du --setup (gum si
# présent, fallback bash sinon) ou par ./setup-llm.sh --preload. Un modèle
# sélectionné devient always-on (load-on-startup=true) ; les autres sont
# chargés à la demande et évincés par le LRU de --models-max (dérivé
# automatiquement : nb préchargés + 1 slot LRU).
# =============================================================================

PRELOAD_CONF="$SCRIPT_DIR/preload.conf"

SPEC_TEST_URL="http://localhost:$SERVER_PORT"

# Journaux de mesure : tous dans logs/ (local, non versionné), un fichier par
# outil, TSV en append, toujours avec la version de llama.cpp (cf. _llama_build)
# pour comparer d'un build à l'autre et voir les régressions.
LOG_DIR="$SCRIPT_DIR/logs"
mkdir -p "$LOG_DIR" 2>/dev/null || true
# Migration du 21/08/2026 : les journaux vivaient à la racine. Déplacés une
# fois, sans écraser ; à retirer quand les machines sont passées.
for _f in spec-tests.log spec-batch.log spec-batch.tsv; do
  if [[ -f "$SCRIPT_DIR/$_f" && ! -e "$LOG_DIR/$_f" ]]; then
    mv "$SCRIPT_DIR/$_f" "$LOG_DIR/$_f"
  fi
done
unset _f
# Journal des --spec-test — sert à l'analyse n-max : dès 2 runs à des n-max
# différents sur le même modèle/GGUF/device, le script calibre un modèle
# simple et prédit la courbe t/s(n-max).
SPEC_LOG="$LOG_DIR/spec-tests.log"
# Journal des --bench (une ligne par modèle et par run, cf. _bench_one) : base
# de la comparaison au run précédent (py/bench_compare.py).
BENCH_LOG="$LOG_DIR/bench.log"

# Étiquette de moteur, journalisée par toutes les mesures.
#
# Ce qui sert les modèles est l'image (runtime/, lib/runtime.sh), et ce qu'elle
# contient est décidé par les deux ARG *_REV de runtime/Dockerfile.rocm-strix.
# L'étiquette se lit donc DANS CE FICHIER, par un grep : depuis le 18/09/2026
# il n'y a plus d'étiquettes llm-setup.* sur l'image, et surtout il ne faut pas
# lancer un conteneur pour ça : la fonction est appelée à chaque journal de
# chaque mesure.
# Depuis le retrait du fork (18/09/2026) c'est la SEULE étiquette de moteur du
# dépôt, pour le service comme pour les outils, qui tournent dans la même image.
# Forme retenue : "strix-<engine7>+r<rocm7>" - les deux révisions comptent, un
# même moteur compilé sur un autre ROCr/HIP ne donne pas les mêmes chiffres, et
# c'est précisément le couple que le Dockerfile épingle.
# Une REV vidée (= sommet de branche au build, cas non épinglé) ne se lit pas
# ici : l'étiquette retombe alors sur "?", et les mesures disent ainsi
# elles-mêmes qu'elles ne sont comparables à rien.
# Mémoïsée dans le processus : une campagne --bench all appelle cette fonction
# une fois par modèle et par journal.
# Une étiquette n'est JAMAIS numérique pure côté consommateurs : elle est
# traitée en chaîne partout (colonne build des journaux TSV, comparaison
# « build X → Y » de py/bench_compare.py).
_LLAMA_BUILD_CACHE="${_LLAMA_BUILD_CACHE:-}"
_llama_build() {
  if [[ -n "$_LLAMA_BUILD_CACHE" ]]; then
    printf '%s\n' "$_LLAMA_BUILD_CACHE"
    return 0
  fi

  local etiquette="" df e="" r=""
  # lib/runtime.sh est sourcé après common.sh : IMAGE_DOCKERFILE peut ne pas
  # être défini à l'appel (aucun outil dans ce cas aujourd'hui), d'où le repli
  # sur le chemin en dur.
  df="${IMAGE_DOCKERFILE:-$SCRIPT_DIR/runtime/Dockerfile.rocm-strix}"
  if [[ -f "$df" ]]; then
    e="$(grep -m1 '^ARG ENGINE_REV=' "$df" 2>/dev/null | cut -d= -f2-)"
    r="$(grep -m1 '^ARG ROCM_SYSTEMS_REV=' "$df" 2>/dev/null | cut -d= -f2-)"
    [[ "$e" =~ ^[0-9a-f]+$ ]] || e=""
    [[ "$r" =~ ^[0-9a-f]+$ ]] || r=""
  fi
  if [[ -n "$e" ]]; then
    etiquette="strix-${e:0:7}"
    [[ -n "$r" ]] && etiquette="${etiquette}+r${r:0:7}"
  fi

  _LLAMA_BUILD_CACHE="${etiquette:-?}"
  printf '%s\n' "$_LLAMA_BUILD_CACHE"
  return 0
}

# Mode d'alimentation de l'APU appliqué par le contrôleur embarqué de la
# machine du service (bigchuck, Ryzen AI Max+ 395) : fichier sysfs
# /sys/class/ec_su_axb35/apu/power_mode, valeurs vues "balanced" et
# "performance". Ce n'est PAS le profil de powerprofilesctl, qui est décorrélé :
# l'espace utilisateur peut afficher "performance" pendant que l'EC tient l'APU
# en "balanced".
# Pourquoi le journaliser, comme l'étiquette de moteur (_llama_build) : mesuré
# le 16/09/2026, en "balanced" le décode perd 10 à 13 % sur tous les modèles
# sauf un dense (3 %), alors que le comparateur de --bench annonce une
# régression dès 5 %. Deux runs pris dans des modes différents s'accusent donc
# d'une régression qui n'existe pas : la colonne en fin de journal sert à ne
# comparer que des runs de même mode.
# Jamais bloquant : une mesure vaut d'être faite même si le mode est inconnu
# (autre machine, module EC absent, sysfs illisible). Le mode vaut alors
# "inconnu", un warn est émis une seule fois par processus (garde
# _EC_POWER_MODE_WARNED) et la fonction sort toujours en 0 ; le warn part sur
# stderr, la fonction étant appelée en substitution de commande.
# EC_POWER_MODE_FILE surcharge le chemin (tests, autre plateforme).
EC_POWER_MODE_FILE="${EC_POWER_MODE_FILE:-/sys/class/ec_su_axb35/apu/power_mode}"
_EC_POWER_MODE_WARNED=0
_ec_power_mode() {
  local m=""
  if [[ -r "$EC_POWER_MODE_FILE" ]]; then
    m="$(tr -d '[:space:]' < "$EC_POWER_MODE_FILE" 2>/dev/null || true)"
  fi
  if [[ -z "$m" ]]; then
    if [[ "${_EC_POWER_MODE_WARNED:-0}" -eq 0 ]]; then
      _EC_POWER_MODE_WARNED=1
      warn "Mode d'alimentation EC illisible ($EC_POWER_MODE_FILE) : journalisé \"inconnu\"." >&2
      warn "  Mesure faite quand même ; elle ne se compare qu'aux runs de même mode." >&2
    fi
    m="inconnu"
  fi
  printf '%s\n' "$m"
  return 0
}

# Surcharges spec-draft-n-max par modèle (à côté du script, comme
# bench-devices.conf) — écrit par --spec-tune, appliqué par generate_models_ini
# par-dessus la valeur de MODEL_INI (qui reste le défaut). Format "modèle = k".
SPEC_CONF="$SCRIPT_DIR/spec-nmax.conf"
# Surcharges spec-ngram-map-k-size-m par modèle (même statut que spec-nmax.conf :
# choix utilisateur, local, non versionné). Écrit par --spec-ngram-tune, appliqué
# par generate_models_ini par-dessus la valeur de MODEL_INI. Format "modèle = m".
# La longueur de draft n-gram dépend du couple (modèle, device) : le coût d'un
# forward de batch m+1 dépend du noyau ggml retenu, qui n'est pas le même d'un
# backend à l'autre — d'où une conf locale plutôt qu'une valeur dans le script.
SPEC_NGRAM_CONF="$SCRIPT_DIR/spec-ngram.conf"

# Nom du service, et NOM DU CONTENEUR (container_name de runtime/docker-compose.yml, via le .env) :
# les deux sont volontairement le même, pour que tous les messages du dépôt
# restent exacts et qu'un `docker logs llama-server` à la main marche.
SERVICE_NAME="llama-server"
# Ancienne unité systemd user. Elle n'est plus ni générée ni utilisée : ce
# chemin ne sert plus qu'à cmd_migrate_off_systemd (lib/service.sh), qui la
# débranche sur les machines qui l'avaient installée. À retirer avec elle.
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"

# =============================================================================
# GARDE MÉMOIRE — faire de la place avant de charger un modèle
#
# Le routeur charge à la demande et évince en LRU, sans connaître la taille
# des modèles : sur une suite de géants (--bench all), la somme du sortant et
# de l'entrant dépasse la RAM. Campagne du 13/09/2026 sur une machine de
# 124 Go : OOM killer sur le routeur deux fois (Laguna 73 Go chargé pendant
# que gpt-oss 59 Go tenait encore ; puis DeepSeek 104 Go après éviction de
# lfm2.5, le LRU, 3 Go, au lieu de Laguna). Le service se relance seul
# (Restart=on-failure) mais la mesure est perdue et le service coupé.
#
# La parade : avant la première requête à un modèle non chargé, estimer ce
# qu'il va prendre et décharger explicitement (POST /models/unload) les plus
# gros modèles chargés tant que la mémoire disponible ne suffit pas. Jamais de
# restart : le routeur reste debout, seuls des modèles en sortent.
# Estimation = somme des GGUF (shards compris) + drafter spec-draft-model,
# plus une marge pour le KV. La taille disque est une borne BASSE (le KV et
# les buffers de calcul s'ajoutent), volontairement : mieux vaut décharger un
# modèle de trop que se faire tuer. Elle n'a pas à être juste, elle a à être
# du bon ordre de grandeur.
# BENCH_NO_UNLOAD=1 désactive toute la garde (mesure passive stricte).
# BENCH_ROOM_MARGE_PCT : marge en % au-dessus de la taille disque (défaut 10).
# =============================================================================

BENCH_ROOM_MARGE_PCT="${BENCH_ROOM_MARGE_PCT:-10}"
# Attente max (s) que `free` reflète un déchargement : le routeur répond
# success avant que le noyau ait rendu les pages.
BENCH_ROOM_TIMEOUT="${BENCH_ROOM_TIMEOUT:-30}"

# Octets → Gio lisible (affichage des messages de la garde mémoire)
_gio() {
  awk -v b="${1:-0}" 'BEGIN{printf "%.1f Go", b/1073741824}'
}

# Fichiers de poids d'un modèle : sa ligne "model =" (un premier shard entraîne
# toute la série, que le routeur charge en entier) et son "spec-draft-model ="
# s'il en a un. Un fichier absent est ignoré (le modèle ne chargera pas non
# plus). Sortie : un chemin par ligne.
_model_files() {
  local body="${MODEL_INI[$1]:-}" p f
  [[ -n "$body" ]] || return 0
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    if [[ "$p" =~ ^(.*)-00001-of-([0-9]+)\.gguf$ ]]; then
      for f in "${BASH_REMATCH[1]}"-*-of-"${BASH_REMATCH[2]}".gguf; do
        [[ -f "$f" ]] && echo "$f"
      done
    else
      [[ -f "$p" ]] && echo "$p"
    fi
  done < <(echo "$body" | sed -n 's/^\(model\|spec-draft-model\)[[:space:]]*=[[:space:]]*//p')
  return 0
}

# Taille sur disque d'un modèle, en octets (0 si aucun fichier trouvé).
_model_size_bytes() {
  local total
  total="$(_model_files "$1" | tr '\n' '\0' \
    | xargs -0 -r stat -Lc '%s' 2>/dev/null \
    | awk '{s+=$1} END{printf "%.0f", s+0}')"
  echo "${total:-0}"
}

# Mémoire disponible en octets (colonne "available" de free, celle qui compte :
# elle inclut le cache de pages récupérable).
_mem_available_bytes() {
  free -b 2>/dev/null | awk '/^Mem:/{print $7; found=1} END{if(!found) print 0}'
}

# Modèles actuellement chargés côté routeur (status.value = loaded), un par
# ligne. Silencieux si le routeur ne répond pas : la garde s'efface alors.
_router_loaded_models() {
  curl -s --max-time 10 "$SPEC_TEST_URL/models" 2>/dev/null | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data", []):
    st = m.get("status") or {}
    if st.get("value") == "loaded":
        print(m.get("id", ""))
' 2>/dev/null || true
}

# Déchargement d'un modèle par l'API du routeur. 0 si la réponse dit success.
_router_unload() {
  local out
  out="$(curl -s --max-time 120 -X POST "$SPEC_TEST_URL/models/unload" \
    -H 'Content-Type: application/json' -d "{\"model\": \"$1\"}" 2>/dev/null || true)"
  [[ "$out" == *'"success"'*'true'* ]]
}

# _ensure_room_for <modèle> — à appeler AVANT la première requête d'une mesure.
# Ne rend jamais la main en erreur : une garde qui échoue laisse le routeur
# faire comme avant, elle ne doit pas interrompre une campagne.
_ensure_room_for() {
  local cible="$1"
  [[ "${BENCH_NO_UNLOAD:-0}" == "0" ]] || return 0
  command -v curl >/dev/null 2>&1 || return 0
  command -v free >/dev/null 2>&1 || return 0

  local besoin
  besoin="$(_model_size_bytes "$cible")"
  # Pas de poids sur disque : rien d'estimable, on laisse le routeur décider.
  [[ "$besoin" -gt 0 ]] || return 0
  besoin=$(( besoin + besoin * BENCH_ROOM_MARGE_PCT / 100 ))

  # (tableau éventuellement vide : jamais "${x[@]}" sans garde, unbound sous
  #  set -u en bash 4.3)
  local -a charges=()
  mapfile -t charges < <(_router_loaded_models)
  local m
  if [[ ${#charges[@]} -gt 0 ]]; then
    for m in "${charges[@]}"; do
      # Déjà chargé : le routeur ne rechargera rien, pas de place à faire.
      [[ "$m" == "$cible" ]] && return 0
    done
  fi

  local dispo
  dispo="$(_mem_available_bytes)"
  [[ "$dispo" -gt 0 ]] || return 0
  if [[ "$dispo" -ge "$besoin" ]]; then
    return 0
  fi

  load_preload_conf
  info "Garde mémoire : '$cible' demande ~$(_gio "$besoin") (poids + $BENCH_ROOM_MARGE_PCT % de marge KV), disponible $(_gio "$dispo") — déchargement des plus gros modèles chargés."

  local tours=0
  while [[ "$dispo" -lt "$besoin" ]]; do
    tours=$(( tours + 1 ))
    if [[ "$tours" -gt 12 ]]; then break; fi
    mapfile -t charges < <(_router_loaded_models)
    # Candidats triés du plus gros au plus petit : d'abord les modèles chargés
    # à la demande, les préchargés seulement en dernier recours (les décharger
    # coûte leur rechargement au prochain usage, et c'est un choix utilisateur).
    local -a libres=() gardes=()
    for m in ${charges[@]+"${charges[@]}"}; do
      [[ -n "$m" && "$m" != "$cible" ]] || continue
      if [[ -n "${PRELOADED[$m]:-}" ]]; then
        gardes+=("$(_model_size_bytes "$m")|$m")
      else
        libres+=("$(_model_size_bytes "$m")|$m")
      fi
    done
    local choisi="" taille="" precharge=0
    if [[ ${#libres[@]} -gt 0 ]]; then
      choisi="$(printf '%s\n' "${libres[@]}" | sort -t'|' -k1,1nr | head -1)"
    elif [[ ${#gardes[@]} -gt 0 ]]; then
      choisi="$(printf '%s\n' "${gardes[@]}" | sort -t'|' -k1,1nr | head -1)"
      precharge=1
    fi
    if [[ -z "$choisi" ]]; then
      warn "Garde mémoire : plus rien à décharger, il manque $(_gio $(( besoin - dispo ))) pour '$cible' — chargement tenté quand même (le routeur fera ce qu'il peut, risque d'OOM)."
      return 0
    fi
    taille="${choisi%%|*}"; m="${choisi#*|}"
    if [[ "$precharge" -eq 1 ]]; then
      warn "Garde mémoire : '$m' est PRÉCHARGÉ (preload.conf) mais c'est le seul déchargement possible — il sera rechargé au prochain restart du service."
    fi
    info "Garde mémoire : déchargement de '$m' ($(_gio "$taille")) pour libérer la place de '$cible'."
    if ! _router_unload "$m"; then
      warn "Garde mémoire : le routeur a refusé de décharger '$m' — on continue sans."
      return 0
    fi
    # Le routeur répond avant que le noyau ait rendu les pages : attendre que
    # `free` le reflète, sans bloquer une campagne si ça ne vient pas. On
    # n'attend pas la taille entière (une partie peut rester en cache de
    # pages) : la moitié suffit à dire que la libération a bien eu lieu.
    local t=0 attendu=$(( dispo + taille / 2 ))
    while [[ "$t" -lt "$BENCH_ROOM_TIMEOUT" ]]; do
      dispo="$(_mem_available_bytes)"
      if [[ "$dispo" -ge "$besoin" || "$dispo" -ge "$attendu" ]]; then break; fi
      sleep 1; t=$(( t + 1 ))
    done
    dispo="$(_mem_available_bytes)"
  done

  if [[ "$dispo" -lt "$besoin" ]]; then
    warn "Garde mémoire : après déchargement, disponible $(_gio "$dispo") < $(_gio "$besoin") estimés pour '$cible' — chargement tenté quand même (risque d'OOM sur le routeur)."
  else
    info "Garde mémoire : disponible $(_gio "$dispo") — place faite pour '$cible'."
  fi
  return 0
}
