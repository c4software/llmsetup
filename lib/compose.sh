# lib/compose.sh - sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Génération du docker-compose.yml du service
#
# Le service llama-server n'est plus une unité systemd qui lance un binaire de
# l'hôte : c'est un conteneur, décrit par un docker-compose.yml GÉNÉRÉ par ce
# module, à côté de models.ini dans $CONFIG_DIR (~/models). Les deux fichiers
# ont exactement le même statut : produits, jamais édités à la main, jamais
# versionnés, refaits à chaque démarrage. La source de vérité reste le dépôt
# (lib/models.sh, les .conf, runtime/image.conf).
#
# Pourquoi générer plutôt que versionner un compose :
#   - le fichier porte des valeurs qui ne sont connues QUE sur la machine : les
#     gid numériques de render et video (getent), le chemin absolu de ~/models,
#     le tag de l'image locale, et --models-max dérivé de preload.conf ;
#   - --models-max change dès qu'on touche au préchargement : un compose figé
#     serait faux dès le premier --preload.
#
# TOUT est résolu ici et écrit EN CLAIR : pas de ${VAR}, pas de fichier .env.
# Un compose qui dépend de l'environnement du shell qui lance `docker compose`
# est un compose qui ne dit pas ce qu'il fait - et il serait lu par des mains
# différentes (le dépôt, un `cd ~/models && docker compose ps` à la main).
#
# ⚠ Le ini et le compose ne se régénèrent PAS ensemble : les tuners
# (--spec-ab, --spec-tune, --spec-ngram-tune, --bench-load) surchargent le ini
# le temps d'une mesure et n'ont aucune raison de toucher au compose.
# regen_models_ini n'appelle donc jamais regen_compose ; c'est _svc_start qui
# régénère le compose, à chaque démarrage.
# =============================================================================

# Fichier généré, à côté de models.ini (mêmes règles : local, non versionné).
COMPOSE_FILE="$CONFIG_DIR/docker-compose.yml"

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
    warn "  n'aurait aucun accès au GPU. docker-compose.yml non généré." >&2
    return 1
  fi
  printf '%s\n' "$gid"
}

# _compose_check - prérequis de la génération, tous vérifiés AVANT d'écrire la
# moindre ligne. Renvoie 1 en expliquant (sur stderr), sans effet de bord.
_compose_check() {
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker introuvable - le service tourne en conteneur, il ne peut pas démarrer ici." >&2
    return 1
  fi
  if ! _image_ref >/dev/null 2>&1; then
    warn "Aucune image du moteur sur cette machine (${IMAGE_NAME:-llm-rocm-strix}:$(_image_tag))." >&2
    warn "  La construire d'abord : ./setup-llm.sh --image-build" >&2
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

# generate_compose - écrit le YAML sur STDOUT et ne touche à rien d'autre :
# c'est ce qui le rend testable (tests/sh-unit.sh le compare à ce qu'on attend,
# sur un faux docker et un faux getent) et diffable à la main.
generate_compose() {
  _compose_check || return 1

  local ref gid_render gid_video models_max
  ref="$(_image_ref)"
  gid_render="$(_compose_gid render)"
  gid_video="$(_compose_gid video)"

  # --models-max dérivé de preload.conf, EXACTEMENT comme l'ancien cmd_start :
  # nb de modèles préchargés + 1 slot LRU pour le modèle appelé à la demande
  # (minimum 2). C'est la seule valeur du compose qui bouge au rythme des
  # choix utilisateur, d'où la régénération à chaque démarrage.
  load_preload_conf
  models_max=$(( ${#PRELOADED[@]} + 1 ))
  (( models_max < 2 )) && models_max=2

  cat <<YAML
# =============================================================================
# GÉNÉRÉ par ./setup-llm.sh (lib/compose.sh) - NE PAS ÉDITER
#
# Toute modification à la main est perdue au prochain démarrage du service :
# ./setup-llm.sh --start régénère ce fichier avant chaque « docker compose up ».
#
# Sources de vérité :
#   lib/compose.sh          forme du service (montages, durcissement, santé)
#   runtime/image.conf      révisions du moteur, via l'image $ref
#   preload.conf            modèles préchargés, d'où --models-max $models_max
#   lib/models.sh + .conf   contenu de models.ini, passé en --models-preset
#
# Régénérer : ./setup-llm.sh --start (ou --restart)
# À la main  : cd $CONFIG_DIR && docker compose ps | logs -f
#
# Aucune date ici, volontairement : le contenu ne dépend QUE des sources
# ci-dessus, et regen_compose ne remplace le fichier que s'il change. Sa date
# de modification dit donc « la configuration du service a bougé », pas « le
# service a redémarré ».
# =============================================================================

# Nom de projet explicite : sans lui, compose nommerait le projet d'après le
# dossier qui porte le fichier (« models »), et les conteneurs et réseaux
# s'appelleraient models-*.
name: llm-setup

services:
  llama:
    # container_name figé : tous les messages du dépôt nomment « $SERVICE_NAME »,
    # et _svc_is_active / _svc_wait_ready interrogent ce nom par docker inspect.
    container_name: $SERVICE_NAME
    image: $ref
    # Image construite localement (--image-build), jamais poussée nulle part :
    # un pull ne peut que échouer ou, pire, ramener autre chose.
    pull_policy: never
    restart: unless-stopped
    entrypoint: ["/usr/local/bin/llama-server"]
    # Transposition FIDÈLE de la ligne de commande de l'ancien service.
    # --host 0.0.0.0 s'entend À L'INTÉRIEUR du conteneur (il faut écouter sur
    # toutes ses interfaces pour que la publication de port fonctionne) ;
    # l'exposition côté hôte est décidée par « ports » plus bas.
    # --models-autoload est le défaut côté llama-server, gardé explicite par
    # lisibilité, comme il l'était dans cmd_start.
    command:
      - "--host"
      - "0.0.0.0"
      - "--port"
      - "$SERVER_PORT"
      - "--models-preset"
      - "$CONFIG_DIR/models.ini"
      - "--models-max"
      - "$models_max"
      - "--models-autoload"
      - "--jinja"
    environment:
      # Sans effet côté Vulkan, nécessaire côté ROCm/HIP sur iGPU (allocations
      # en mémoire unifiée/GTT au lieu de la VRAM dédiée) - l'unité systemd le
      # posait déjà d'office, l'image est en HIP seul : il n'est plus optionnel.
      GGML_CUDA_ENABLE_UNIFIED_MEMORY: "1"
    # Les deux seuls accès matériels dont le backend HIP a besoin.
    devices:
      - "/dev/kfd:/dev/kfd"
      - "/dev/dri:/dev/dri"
    # gid NUMÉRIQUES de render et video, résolus sur l'hôte à la génération :
    # ces groupes n'existent pas dans l'image, leur nom n'y voudrait rien dire.
    group_add:
      - "$gid_render"
      - "$gid_video"
    # Durcissement validé en exécution réelle le 17/09/2026 (cf. _dk_run) :
    # seccomp=unconfined est EXIGÉ par ROCr (ioctl du KFD hors profil docker
    # par défaut) ; il est compensé par no-new-privileges et le retrait de
    # toutes les capabilities, qui ne coûtent rien au moteur.
    # Jamais privileged, jamais docker.sock, jamais network_mode: host.
    security_opt:
      - "seccomp=unconfined"
      - "no-new-privileges:true"
    cap_drop:
      - ALL
    # llama.cpp mmap les poids et épingle des buffers : les défauts docker
    # (64 Mio de /dev/shm, memlock bas) font échouer le chargement des gros GGUF.
    shm_size: 8g
    ulimits:
      memlock:
        soft: -1
        hard: -1
    # Pas de mem_limit : la garde mémoire du dépôt (_ensure_room_for) raisonne
    # sur le « available » de l'HÔTE et décharge des modèles par l'API du
    # routeur. Un plafond cgroup ferait tuer le routeur par l'OOM killer du
    # groupe avant que la garde n'ait la main - exactement ce qu'elle évite.
    ports:
      - "$BIND_ADDR:$SERVER_PORT:$SERVER_PORT"
    volumes:
      # MÊME chemin absolu des deux côtés : models.ini porte des chemins
      # absolus de l'hôte et ne doit surtout pas être réécrit pour le
      # conteneur. En lecture seule : le moteur n'a rien à écrire dans les poids.
      - "$MODELS_BASE:$MODELS_BASE:ro"
      # Seul point inscriptible, hors de ~/models : place d'un futur cache
      # disque du moteur. Créé par regen_compose s'il manque.
      - "$COMPOSE_CACHE_DIR:/var/cache/llama:rw"
    # 180 s : l'arrêt du routeur (déchargement des préchargés) dépassait le
    # délai par défaut de systemd, qui le tuait au SIGKILL. SIGINT est le
    # signal d'arrêt propre de llama-server.
    stop_grace_period: 180s
    stop_signal: SIGINT
    logging:
      driver: json-file
      options:
        max-size: "50m"
        max-file: "5"
    # Sonde sans curl : l'image est bâtie sur fedora-minimal, qui n'en a pas.
    # bash sait ouvrir une socket TCP (/dev/tcp) et lire la ligne de statut.
    # start_period 300 s : le préchargement d'un gros parc prend des minutes,
    # et un conteneur déclaré unhealthy pendant ce temps-là n'apprend rien.
    healthcheck:
      test:
        - "CMD"
        - "/bin/bash"
        - "-c"
        - "exec 3<>/dev/tcp/127.0.0.1/$SERVER_PORT && printf 'GET /health HTTP/1.0\r\n\r\n' >&3 && head -n1 <&3 | grep -q 200"
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 300s
YAML
}

# regen_compose - écrit $COMPOSE_FILE, par un fichier temporaire, et ne
# remplace que si le contenu diffère. Ne rien réécrire quand rien ne change
# garde une date de modification qui veut dire quelque chose (« le compose a
# bougé au dernier démarrage »), et évite de toucher le fichier sous les yeux
# d'un `docker compose` lancé à la main.
# Renvoie 1 sans rien écrire si les prérequis manquent (image absente, groupe
# introuvable) : l'appelant décide si c'est fatal.
regen_compose() {
  mkdir -p "$COMPOSE_CACHE_DIR" 2>/dev/null || true

  local tmp
  tmp="$(mktemp)" || { warn "mktemp en échec - docker-compose.yml non régénéré."; return 1; }
  if ! generate_compose > "$tmp"; then
    rm -f "$tmp"
    return 1
  fi

  if [[ -f "$COMPOSE_FILE" ]] && cmp -s "$tmp" "$COMPOSE_FILE"; then
    rm -f "$tmp"
    return 0
  fi
  if ! mv -f "$tmp" "$COMPOSE_FILE"; then
    rm -f "$tmp"
    warn "Écriture de $COMPOSE_FILE en échec."
    return 1
  fi
  chmod 0644 "$COMPOSE_FILE" 2>/dev/null || true
  info "docker-compose.yml régénéré : $COMPOSE_FILE"
  return 0
}
