# lib/common.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → fork → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

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

# Propose un restart du service systemd si actif — appelé en fin de setup /
# update / cleanup / preload (config ou poids modifiés). Rappel : les poids
# déjà mmap'és restent sur l'ancien inode tant que le serveur n'a pas redémarré.
# Non-interactif : jamais de restart automatique, juste le rappel.
_maybe_restart_service() {
  systemctl --user is-active --quiet "$SERVICE_NAME" 2>/dev/null || return 0
  local reply="n"
  if [[ -t 0 ]]; then
    read -r -p "Le service $SERVICE_NAME tourne — redémarrer maintenant pour appliquer ? [O/n] " reply
    reply="${reply:-o}"
  else
    warn "Service $SERVICE_NAME actif — redémarrage non effectué (entrée non interactive)."
    warn "  Appliquer : systemctl --user restart $SERVICE_NAME"
    return 0
  fi
  if [[ "$reply" =~ ^[oOyY]$ ]]; then
    info "Redémarrage de $SERVICE_NAME..."
    systemctl --user restart "$SERVICE_NAME" \
      && info "✅ $SERVICE_NAME redémarré." \
      || warn "Redémarrage en échec — voir : journalctl --user -u $SERVICE_NAME -e"
  else
    info "Redémarrage sauté — appliquer plus tard : systemctl --user restart $SERVICE_NAME"
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

# _derive <cible absolue> <source absolue> <script du dépôt>
#   Fichier PRODUIT localement : aucun repo HF ne le porte, il est calculé à
#   partir d'un fichier déjà téléchargé (cas unique aujourd'hui : le sidecar MTP
#   de Qwen3.8-Flash-Next renommé pour le fork, cf. tools/mtp-rename-hc-head.py).
#   Mêmes règles que _dl pour --update (ONLY) et le skip, sauf que la fraîcheur
#   se juge sur la source : une source retéléchargée (etag changé) redonne une
#   cible plus vieille qu'elle, donc à refaire.
#   Rien n'est fatal ici : le setup des autres modèles doit aller au bout. Une
#   dérivation sautée se paie au chargement du modèle qui consomme le fichier,
#   avec le message de llama-server, pas par un setup interrompu.
_derive() {
  local cible="$1" source="$2" script="$3"
  _skip "$cible" && return 0
  if [[ -f "$cible" && ! "$source" -nt "$cible" ]]; then
    info "$(basename "$cible") déjà dérivé, skip."
    return 0
  fi
  if [[ ! -f "$source" ]]; then
    warn "$(basename "$cible") : source absente ($source), dérivation sautée."
    return 0
  fi
  # Le script importe le gguf-py DU FORK (il connaît l'arch qwen4exp) : sans le
  # dépôt du fork, rien à faire ici — et rien à faire tout court, puisque la
  # sortie ne sert qu'au fork.
  if [[ ! -d "$FORK_DIR/gguf-py" ]]; then
    warn "$(basename "$cible") : $FORK_DIR/gguf-py absent (fork non installé,"
    warn "  voir ./setup-llm.sh --setup-fork) — dérivation sautée."
    return 0
  fi
  info "Dérivation $(basename "$cible") par $script..."
  if ! PYTHONPATH="$FORK_DIR/gguf-py" python3 "$SCRIPT_DIR/$script" "$source" "$cible"; then
    rm -f "$cible"          # sortie partielle : pire qu'absente
    warn "Dérivation en échec ($script) — le modèle qui l'utilise ne chargera pas."
  fi
  return 0
}

# =============================================================================
# CHEMINS
# =============================================================================

# PATH du service : $HOME/.local/bin en tête, comme l'unité systemd. Les
# liens du fork strix-llama.cpp y vivent (./setup-llm.sh --setup-fork), donc
# toute commande du script (llama-server, llama-bench, llama-cli,
# llama-quantize) voit le MÊME moteur que le serveur mesuré. Sans fork, ces
# liens n'existent pas et /usr/bin (paquet Arch) reprend la main.
# Ajout conditionnel : le dossier est déjà en tête pour le service (unité
# systemd) et dans la plupart des sessions ; le rajouter empilerait un doublon
# à chaque source. Effet de bord assumé et voulu : ce dossier prime aussi pour
# les autres outils appelés ici (hf, python3…), c'est déjà le cas d'une session
# interactive normale, où pip/pipx installe justement `hf` là.
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac

MODELS_BASE="$HOME/models"
CONFIG_DIR="$MODELS_BASE"

# Port du routeur llama-server (service --start et mesures via l'API)
SERVER_PORT=8009

# Device retenu par GGUF — clé = dossier sous $MODELS_BASE.
# Format : "clé = device", commentaires ";". Édition manuelle (guidée par
# les mesures de --bench, qui n'écrit rien lui-même).
# Vit À CÔTÉ DU SCRIPT (local, non versionné — .gitignore), pas dans $MODELS_BASE.
BENCH_CONF="$SCRIPT_DIR/bench-devices.conf"

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

# Binaire llama.cpp effectivement utilisé, résolu COMME LE SERVICE : le
# service (lib/service.sh) met $HOME/.local/bin en tête du PATH, donc les
# liens du fork y priment sur le paquet Arch de /usr/bin. Une session ssh
# sans ce PATH lisait le binaire Arch et journalisait son build pour des
# mesures faites par le fork (arrivé le 12/09/2026, deux lignes de
# logs/bench.log) : on cherche donc d'abord dans ~/.local/bin, repli sur le
# PATH. $1 = nom du binaire (défaut llama-server).
_llama_bin() {
  local n="${1:-llama-server}"
  if [[ -x "$HOME/.local/bin/$n" ]]; then
    echo "$HOME/.local/bin/$n"
  else
    command -v "$n" 2>/dev/null
  fi
}

# Étiquette de moteur, journalisée par toutes les mesures. Deux formes, parce
# que deux moteurs coexistent (cf. README « Moteur : fork strix-llama.cpp ») :
#   - upstream (paquet Arch) : "b10809", le numéro de build de
#     `--version` ("version: 0.4.0-dev (build 10809, commit 5266f24da7)") ;
#   - fork : le fork ne numérote pas ses builds ("build 1"), l'étiquette est
#     donc "<dépôt>-<commit court>", ex. "strix-0007bc6". Règle du préfixe :
#     nom du dossier du dépôt (realpath du binaire remonté de build/bin),
#     amputé du suffixe "-llama.cpp" ; "fork" si le chemin ne dit rien.
# Repli final sur la version du paquet. Une étiquette n'est JAMAIS numérique
# pure côté consommateurs : elle est traitée en chaîne partout (colonne build
# des journaux TSV, comparaison « build X → Y » de py/bench_compare.py).
_llama_build() {
  local bin ver b commit repo
  bin="$(_llama_bin llama-server)"
  if [[ -n "$bin" ]]; then
    ver="$("$bin" --version 2>&1 | head -3)"
    b="$(sed -n 's/.*build \([0-9][0-9]*\).*/\1/p' <<< "$ver" | head -1)"
    commit="$(sed -n 's/.*commit \([0-9a-f][0-9a-f]*\).*/\1/p' <<< "$ver" | head -1)"
    if [[ -n "$b" && "$b" -gt 1 ]]; then
      echo "b$b"; return
    fi
    if [[ -n "$commit" ]]; then
      repo="$(realpath "$bin" 2>/dev/null)"
      if [[ "$repo" == */build/bin/* ]]; then
        repo="$(basename "${repo%/build/bin/*}")"
        repo="${repo%-llama.cpp}"
      else
        repo=""
      fi
      [[ -n "$repo" ]] || repo="fork"
      echo "${repo}-${commit:0:7}"; return
    fi
  fi
  b="$(paru -Q llama-cpp 2>/dev/null | awk '{print $2}')"
  echo "${b:-?}"
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

SERVICE_NAME="llama-server"
# Service systemd USER : piloté par systemctl --user, démarre au
# boot sans session via loginctl enable-linger (posé par --install-service)
SERVICE_FILE="$HOME/.config/systemd/user/${SERVICE_NAME}.service"
