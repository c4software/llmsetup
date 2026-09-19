# lib/compose.sh - sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Le .env du service : les valeurs machine du compose
#
# Le service llama-server est un conteneur décrit par runtime/docker-compose.yml,
# fichier VERSIONNÉ du dépôt, écrit à la main, lu tel quel par docker compose.
# Il ne porte aucune valeur propre à une machine : tout ce qui varie d'un hôte à
# l'autre y est une variable ${VAR:?}, et ce module écrit ces variables dans
# $CONFIG_DIR/.env (~/models/.env), à côté de models.ini et du même statut :
# produit, jamais édité à la main, jamais versionné, refait à chaque démarrage.
#
# Ce que le .env porte, et pourquoi ça ne peut pas être dans le YAML :
#   - les gid numériques de render et video (getent, propres à l'hôte) ;
#   - le chemin absolu de ~/models, du dépôt (contexte de build) et du cache ;
#   - --models-max, dérivé de preload.conf : il change dès qu'on touche au
#     préchargement, d'où la réécriture à chaque --start ;
#   - COMPOSE_FILE, le chemin absolu de runtime/docker-compose.yml : c'est lui
#     qui rend l'usage manuel possible (cd ~/models && docker compose ps), le
#     compose ne vivant pas dans ~/models.
# Les constantes du dépôt (port, nom du conteneur, tag de l'image) y sont
# écrites aussi, pour n'avoir qu'une seule source : lib/common.sh et
# lib/runtime.sh, jamais un défaut recopié dans le YAML.
#
# docker compose lit le .env du DOSSIER DE PROJET (--project-directory, ou le
# cwd) : _svc_compose passe donc --project-directory $CONFIG_DIR, et l'usage à
# la main se fait depuis ~/models.
#
# ⚠ Le ini et le .env ne se régénèrent PAS ensemble : les tuners (--spec-ab,
# --spec-tune, --spec-ngram-tune, --bench-load) surchargent le ini le temps
# d'une mesure et n'ont aucune raison de toucher au .env. regen_models_ini
# n'appelle donc jamais regen_env ; c'est _svc_start qui régénère le .env, à
# chaque démarrage.
# =============================================================================

# Le compose, versionné dans le dépôt. (RUNTIME_DIR est défini plus loin, dans
# lib/runtime.sh : le chemin est écrit en entier ici.)
COMPOSE_FILE="$SCRIPT_DIR/runtime/docker-compose.yml"

# Le .env, généré à côté de models.ini (mêmes règles : local, non versionné).
ENV_FILE="$CONFIG_DIR/.env"

# Second volume, INSCRIPTIBLE et hors de ~/models (monté en lecture seule) :
# place réservée à un futur cache disque du moteur. Hors de ~/models exprès,
# pour que le parc de poids reste un dossier de poids et rien d'autre, et que
# --cleanup n'ait jamais à raisonner dessus.
COMPOSE_CACHE_DIR="$HOME/.local/state/llm-setup/cache"

# Adresse de publication du port. 0.0.0.0 par défaut : c'est exactement ce que
# faisait l'unité systemd, dont le ExecStart passait --host 0.0.0.0 (le serveur
# écoutait sur toutes les interfaces, pas seulement en local). La bascule vers
# le conteneur ne change pas l'exposition du service ; BIND_ADDR=127.0.0.1
# permet de la restreindre sans toucher au code.
BIND_ADDR="${BIND_ADDR:-0.0.0.0}"

# _compose_gid <groupe> - gid NUMÉRIQUE d'un groupe de l'hôte.
# Les groupes render et video sont ceux de L'HÔTE et n'existent pas dans
# l'image Fedora : passer leur NOM à docker échoue, seul le nombre marche
# (même raison que dans _dk_run, lib/runtime.sh). Sans eux, le conteneur n'a
# pas accès au GPU : c'est une erreur, pas un avertissement.
# Le message part sur stderr, la fonction étant appelée en substitution de
# commande (même convention que _ec_power_mode).
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

# _compose_check - prérequis du service, tous vérifiés AVANT d'écrire la
# moindre ligne. Renvoie 1 en expliquant (sur stderr), sans effet de bord.
_compose_check() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker introuvable - le service tourne en conteneur, il ne peut pas démarrer ici." >&2
    return 1
  fi
  [[ -f "$COMPOSE_FILE" ]] \
    || { warn "$COMPOSE_FILE absent : le dépôt est incomplet." >&2; return 1; }
  # Image absente = refus net. `docker compose up` construirait tout seul
  # (c'est son comportement quand l'image du service manque) : vingt minutes
  # de compilation silencieuse au milieu d'un --start, sans que personne l'ait
  # demandé. Mieux vaut renvoyer sur la commande de build.
  # COMPOSE_SKIP_IMAGE_CHECK=1 lève ce contrôle pour le SEUL appelant qui a une
  # raison d'écrire le .env sans image : cmd_image_build, dont le travail est
  # précisément de la construire.
  if [[ "${COMPOSE_SKIP_IMAGE_CHECK:-0}" != "1" ]] && ! _image_ref >/dev/null 2>&1; then
    warn "Aucune image du moteur sur cette machine (${IMAGE_NAME:-llm-rocm-strix}:$(_image_tag))." >&2
    warn "  La construire d'abord : ./setup-llm.sh --image-build" >&2
    warn "  (ou, à la main : cd $CONFIG_DIR && docker compose build)" >&2
    return 1
  fi
  [[ -f "$CONFIG_DIR/models.ini" ]] \
    || { warn "$CONFIG_DIR/models.ini absent - lancer d'abord ./setup-llm.sh --setup." >&2; return 1; }
  local g
  for g in render video; do
    _compose_gid "$g" >/dev/null || return 1
  done
  return 0
}

# generate_env - écrit le .env sur STDOUT et ne touche à rien d'autre : c'est
# ce qui le rend testable (tests/sh-unit.sh le fait rendre par le vrai
# `docker compose config`, sur un faux getent) et diffable à la main.
# Format : KEY=valeur, une par ligne, sans guillemets (compose lit les
# guillemets comme du contenu dans certaines versions ; aucune valeur ici ne
# contient d'espace ni de caractère spécial, les chemins du dépôt et de
# ~/models étant sans espace par construction du reste du script).
generate_env() {
  _compose_check || return 1

  local ref gid_render gid_video models_max
  ref="${IMAGE_NAME:-llm-rocm-strix}:$(_image_tag)"
  gid_render="$(_compose_gid render)"
  gid_video="$(_compose_gid video)"

  # --models-max dérivé de preload.conf, EXACTEMENT comme l'ancien cmd_start :
  # nb de modèles préchargés + 1 slot LRU pour le modèle appelé à la demande
  # (minimum 2).
  load_preload_conf
  models_max=$(( ${#PRELOADED[@]} + 1 ))
  (( models_max < 2 )) && models_max=2

  cat <<ENV
# GÉNÉRÉ par ./setup-llm.sh (lib/compose.sh) - NE PAS ÉDITER
# Valeurs machine de $COMPOSE_FILE ; réécrit à chaque --start.
# Usage manuel : cd $CONFIG_DIR && docker compose ps | logs -f | build
COMPOSE_FILE=$COMPOSE_FILE
SERVICE_NAME=$SERVICE_NAME
IMAGE_REF=$ref
RUNTIME_DIR=${RUNTIME_DIR:-$SCRIPT_DIR/runtime}
SERVER_PORT=$SERVER_PORT
BIND_ADDR=$BIND_ADDR
CONFIG_DIR=$CONFIG_DIR
MODELS_BASE=$MODELS_BASE
CACHE_DIR=$COMPOSE_CACHE_DIR
GID_RENDER=$gid_render
GID_VIDEO=$gid_video
MODELS_MAX=$models_max
ENV
}

# regen_env - écrit $ENV_FILE, par un fichier temporaire, et ne remplace que si
# le contenu diffère. Ne rien réécrire quand rien ne change garde une date de
# modification qui veut dire quelque chose (« la configuration du service a
# bougé au dernier démarrage »), et évite de toucher le fichier sous les yeux
# d'un `docker compose` lancé à la main.
# Renvoie 1 sans rien écrire si les prérequis manquent (image absente, groupe
# introuvable) : l'appelant décide si c'est fatal.
regen_env() {
  mkdir -p "$COMPOSE_CACHE_DIR" 2>/dev/null || true

  # Migration : l'ancien docker-compose.yml généré (jusqu'au 18/09/2026) dans
  # $CONFIG_DIR passerait avant COMPOSE_FILE du .env pour un `docker compose`
  # lancé à la main depuis ~/models. Retiré seulement si son en-tête prouve
  # qu'il a été généré : un fichier écrit par quelqu'un n'est pas touché.
  local vieux="$CONFIG_DIR/docker-compose.yml"
  if [[ -f "$vieux" ]] && head -n3 "$vieux" | grep -q 'GÉNÉRÉ par ./setup-llm.sh'; then
    rm -f "$vieux" && info "Ancien $vieux (généré) retiré : le compose vit dans $COMPOSE_FILE."
  fi

  local tmp
  tmp="$(mktemp)" || { warn "mktemp en échec - .env non régénéré."; return 1; }
  if ! generate_env > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$ENV_FILE" ]] && cmp -s "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"
    return 0
  fi
  if ! mv -f "$tmp" "$ENV_FILE"; then
    rm -f "$tmp"
    warn "Écriture de $ENV_FILE en échec."
    return 1
  fi
  chmod 0644 "$ENV_FILE" 2>/dev/null || true
  info ".env régénéré : $ENV_FILE"
  return 0
}
