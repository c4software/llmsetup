# lib/common.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → runtime/*/runtime.sh → help

# =============================================================================
# Socle GÉNÉRIQUE : rien ici ne connaît un moteur.
#
# Depuis le 09/10/2026 le dépôt est découpé en RUNTIMES : un dossier
# runtime/<nom>/ par moteur, autonome (son compose, son image, ses poids, ses
# mesures), qui respecte runtime/CONTRAT.md. lib/ ne garde que ce qui est
# commun : ces helpers, le registre des runtimes, et le pilotage du conteneur
# (lib/svc.sh). Ce qui vivait ici et n'appartenait qu'au moteur llama.cpp
# (téléchargements hf, journaux de mesure, étiquette de moteur, mode EC, garde
# mémoire, chemins des .conf) est dans runtime/llama-cpp-rocm-strix/lib/common.sh.
# =============================================================================

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

# =============================================================================
# CHEMINS ET PORT, communs à tous les runtimes
# =============================================================================

# Parc des poids. Un runtime le monte dans son conteneur au MÊME chemin absolu
# et en lecture seule (runtime/CONTRAT.md) : les configurations portent des
# chemins de l'hôte et n'ont jamais à être réécrites pour le conteneur.
MODELS_BASE="$HOME/models"

# Port du service, le MÊME pour tous les runtimes : un seul tient le port à la
# fois (un GPU), et les clients ne changent pas d'adresse quand on bascule.
SERVER_PORT=8009

# _compose_gid <groupe> - gid NUMÉRIQUE d'un groupe de l'hôte.
# Les groupes render et video sont ceux de L'HÔTE et n'existent pas dans les
# images : passer leur NOM à docker échoue, seul le nombre marche. Sans eux, le
# conteneur n'a pas accès au GPU : c'est une erreur, pas un avertissement.
# Le message part sur stderr, la fonction étant appelée en substitution de
# commande (même convention que _ec_power_mode). Ici, et plus dans le .env
# d'un moteur, parce que tout runtime GPU en a besoin pour écrire le sien.
_compose_gid() {
  local g="$1" gid
  gid="$(getent group "$g" 2>/dev/null | cut -d: -f3)"
  if [[ ! "$gid" =~ ^[0-9]+$ ]]; then
    warn "Groupe '$g' introuvable sur l'hôte (getent group $g) : le conteneur" >&2
    warn "  n'aurait aucun accès au GPU. .env non généré." >&2
    return 1
  fi
  printf '%s\n' "$gid"
}

# =============================================================================
# REGISTRE DES RUNTIMES (runtime/CONTRAT.md)
#
# Un runtime est un dossier runtime/<nom>/ avec un runtime.sh, sourcé par le
# point d'entrée. En se chargeant, il se DÉCLARE dans les tableaux ci-dessous,
# sous son nom (= le nom de son dossier), et définit ses fonctions de contrat
# rt_<id>_<fonction>, <id> étant son nom où tout caractère hors [A-Za-z0-9]
# devient « _ » (llama-cpp-rocm-strix → rt_llama_cpp_rocm_strix_env).
#
# Tous les runtime.sh sont sourcés, pas seulement celui du runtime actif :
# arrêter le runtime qui tient le port demande son conteneur et son .env, et
# l'aide liste les commandes de chacun. D'où la règle du contrat : un
# runtime.sh ne fait RIEN en se chargeant (ni réseau, ni docker, ni écriture
# hors de son propre dossier de journaux).
# =============================================================================

RUNTIMES_DIR="$SCRIPT_DIR/runtime"
# Runtimes présents, dans l'ordre alphabétique des dossiers (rempli par le
# point d'entrée, au fil des source).
RUNTIMES=()
# Déclarations, une entrée par runtime.
declare -A RT_CONTENEUR=()        # nom du conteneur (container_name du compose)
declare -A RT_ENV_FILE=()         # .env généré ; son dossier est le projet compose
declare -A RT_DESCRIPTION=()      # une ligne, pour --runtime et l'aide
declare -A RT_COMMANDES=()        # sous-commandes propres, séparées par des espaces
declare -A RT_DELAI_DEMARRAGE=()  # plafond d'attente de /health, en s (défaut 300)
declare -A RT_DELAI_ARRET=()      # délai de grâce de l'arrêt, en s (défaut 10)
declare -A RT_PARC_RESERVE=()     # dossiers de premier niveau de MODELS_BASE qui
                                  # n'appartiennent qu'à lui, séparés par des
                                  # espaces : le ménage d'un autre runtime n'y
                                  # touche pas

# Runtime actif : CHOIX UTILISATEUR, local, non versionné, une ligne (le nom).
# Écrit par ./setup-llm.sh --runtime <nom>, jamais autrement.
RUNTIME_CONF="$SCRIPT_DIR/runtime.conf"
# Sans runtime.conf : le moteur historique du dépôt, pour qu'une machine déjà
# installée se comporte comme avant le découpage.
RUNTIME_DEFAUT="llama-cpp-rocm-strix"

# _rt_id <nom> - le nom d'un runtime tel qu'il entre dans un nom de fonction.
_rt_id() {
  printf '%s\n' "${1//[^A-Za-z0-9]/_}"
}

# _rt_existe <nom> - ce runtime est-il présent et déclaré ?
_rt_existe() {
  [[ -n "${1:-}" && -n "${RT_CONTENEUR[$1]:-}" ]]
}

# _rt_a <nom> <fonction> - ce runtime définit-il cette fonction du contrat ?
# Sert aux fonctions OPTIONNELLES (avant_demarrage, pret, etat).
_rt_a() {
  declare -F "rt_$(_rt_id "$1")_$2" >/dev/null
}

# _rt <fonction> [args...] - appelle la fonction de contrat du runtime visé
# ($RT). Le seul point d'appel : rien dans lib/ ne nomme un runtime.
_rt() {
  local f="$1"; shift
  "rt_$(_rt_id "$RT")_$f" "$@"
}

# _rt_actif - nom du runtime que les commandes visent : LLM_RUNTIME (pour UNE
# commande, sans rien mémoriser : installer un runtime avant d'y basculer,
# bancs), sinon runtime.conf, sinon le défaut.
_rt_actif() {
  local n="${LLM_RUNTIME:-}"
  if [[ -z "$n" && -f "$RUNTIME_CONF" ]]; then
    n="$(sed -n '/^[[:space:]]*[^#[:space:]]/{s/^[[:space:]]*//;s/[[:space:]]*$//;p;q}' "$RUNTIME_CONF")"
  fi
  printf '%s\n' "${n:-$RUNTIME_DEFAUT}"
}

# _rt_proprietaire <commande> - nom du runtime qui déclare cette
# sous-commande, ou échec. Sert à dire « commande du runtime X » quand elle
# est demandée sous un autre.
_rt_proprietaire() {
  local n
  for n in ${RUNTIMES[@]+"${RUNTIMES[@]}"}; do
    if [[ " ${RT_COMMANDES[$n]:-} " == *" $1 "* ]]; then
      printf '%s\n' "$n"
      return 0
    fi
  done
  return 1
}
