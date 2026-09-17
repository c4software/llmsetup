# lib/runtime.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Moteur conteneurisé : image ROCm Strix Halo (runtime/)
#
# Deuxième moteur du dépôt, à côté du fork Vulkan de lib/fork.sh. Il vient de la
# PR 133 de kyuz0/amd-strix-halo-toolboxes : ROCm 10.0 gfx1151 + un ROCr/HIP
# retained-PM4 compilé depuis pwilkin/rocm-systems, et halo-box/strix-llama.cpp
# construit en HIP seul. Provenance et écarts : runtime/AMONT.md.
#
# ⚠ Depuis la bascule, cette image EST le moteur du service : le compose généré
# (lib/compose.sh) la nomme par _image_ref, et _svc_restart la reprend. Une
# image neuve n'est donc servie qu'au prochain redémarrage - --image-build,
# --image-update et --image-status ne redémarrent rien d'eux-mêmes. Le fork de
# lib/fork.sh reste le moteur des outils HORS service (llama-bench) et le filet
# de retour arrière de la migration.
#
# Modèle de gestion des images, décidé le 17/09/2026 :
#   - l'image ne contient QUE le moteur et son runtime — pas de modèle, pas de
#     configuration, pas de cache, pas d'état. Les poids arrivent par un montage
#     en lecture seule (compose généré, ou _dk_run), le ini vit dans ~/models.
#     Une image est donc jetable et interchangeable.
#   - UN SEUL tag : ${IMAGE_NAME}:latest. Pas de tag daté, pas de collection
#     d'anciennes images en filet de sécurité : reconstruire depuis
#     runtime/image.conf prend quelques minutes, et c'est l'HISTORIQUE GIT de
#     ce fichier qui sert de journal des révisions. Revenir en arrière = y
#     remettre les anciennes révisions (git revert, ou --image-update <engine>
#     <rocm>) puis --image-build. Il n'y a pas de --image-rollback par tag.
#   - la traçabilité tient à trois choses : les LABEL de l'image
#     (llm-setup.engine_rev / rocm_rev / build_date), /opt/strix/versions.txt
#     dedans, et logs/images.tsv sur la machine.
#
# ⚠ Comparabilité, comme pour le fork : une image = une série de mesures. Un
# chiffre ne se compare qu'à un autre pris sous les mêmes révisions ; d'où le
# refus de --image-update d'avancer sans accord explicite.
# =============================================================================

RUNTIME_DIR="$SCRIPT_DIR/runtime"
IMAGE_CONF="$RUNTIME_DIR/image.conf"
IMAGE_DOCKERFILE="$RUNTIME_DIR/Dockerfile.rocm-strix"
# Journal des images construites, même statut que les autres journaux de logs/ :
# local, non versionné, TSV en append. Seule trace qui survive à la suppression
# d'une image, et complément de l'historique de runtime/image.conf.
IMAGE_LOG="$LOG_DIR/images.tsv"

# Le tag unique, et le tag TEMPORAIRE sous lequel un build se fait. Construire
# directement sur :latest écraserait le tag de l'image qui marche avant même de
# savoir si la neuve est bonne : un build raté ou une vérification en échec
# doivent laisser :latest intact.
IMAGE_TAG="latest"
IMAGE_BUILD_TAG="build"

# Les quatre cibles attendues dans /usr/local/bin de l'image — mêmes que
# FORK_BINS, pour que les mesures se fassent de la même façon sur les deux
# moteurs. Le Dockerfile le garantit déjà côté build ; on le revérifie sur
# l'image finie, qui est ce qu'on va vraiment lancer.
IMAGE_BINS=(llama-server llama-bench llama-cli llama-quantize)

# Étiquette qui identifie NOS images. Elle sert aussi de filtre de ménage : rien
# n'est supprimé qui ne la porte pas (la machine héberge d'autres images —
# bench-agentic-pi, halogen-flash-server, les toolboxes construites à la main).
IMAGE_LABEL_ENGINE="llm-setup.engine_rev"
IMAGE_LABEL_ROCM="llm-setup.rocm_rev"
IMAGE_LABEL_DATE="llm-setup.build_date"

# Clés reconnues dans image.conf. Une clé inconnue est une faute de frappe qui
# passerait sinon inaperçue (build sur la branche au lieu de la révision) :
# refusée, pas ignorée.
IMAGE_CONF_KEYS=(
  ENGINE_REPO ENGINE_BRANCH ENGINE_REV
  ROCM_SYSTEMS_REPO ROCM_SYSTEMS_BRANCH ROCM_SYSTEMS_REV
  IMAGE_NAME
)

# _image_read_conf — remplit les variables de IMAGE_CONF_KEYS depuis image.conf.
# Contrairement aux .conf de la racine (choix de machine, tolérants), celui-ci
# est versionné et décrit ce qu'on construit : une clé inconnue, une clé requise
# absente ou un fichier manquant sont des erreurs.
_image_read_conf() {
  [[ -f "$IMAGE_CONF" ]] || error "$IMAGE_CONF absent — le dépôt est incomplet."

  local k
  for k in "${IMAGE_CONF_KEYS[@]}"; do
    printf -v "$k" '%s' ''
  done

  local ligne cle val connue
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    [[ "$ligne" =~ ^[[:space:]]*($|\;|\#) ]] && continue
    [[ "$ligne" == *=* ]] || continue
    cle="${ligne%%=*}"; cle="${cle// /}"
    val="${ligne#*=}"; val="${val#"${val%%[![:space:]]*}"}"; val="${val%"${val##*[![:space:]]}"}"
    connue=0
    for k in "${IMAGE_CONF_KEYS[@]}"; do
      [[ "$cle" == "$k" ]] && { printf -v "$k" '%s' "$val"; connue=1; break; }
    done
    [[ "$connue" -eq 1 ]] || error "$IMAGE_CONF : clé inconnue '$cle'."
  done < "$IMAGE_CONF"

  # Les *_REV ont le droit d'être vides (= HEAD de la branche), pas le reste.
  for k in ENGINE_REPO ENGINE_BRANCH ROCM_SYSTEMS_REPO ROCM_SYSTEMS_BRANCH IMAGE_NAME; do
    [[ -n "${!k}" ]] || error "$IMAGE_CONF : $k vide ou absent."
  done
}

# _image_tag — le tag de l'image courante. Constant depuis la décision du
# 17/09/2026 (tag unique) ; la fonction reste pour que le tag ne soit écrit
# qu'à un seul endroit, et que les appelants n'aient pas à le savoir.
_image_tag() { echo "$IMAGE_TAG"; }

# _image_ref — nom:tag de l'image courante, ou rien (code 1) s'il n'y en a pas.
# Avec un tag unique, « courante » ne demande plus de tri : c'est :latest, si
# elle est là.
_image_ref() {
  [[ -n "${IMAGE_NAME:-}" ]] || _image_read_conf
  local ref="${IMAGE_NAME}:$(_image_tag)"
  docker image inspect "$ref" >/dev/null 2>&1 || return 1
  printf '%s\n' "$ref"
}

# _image_ls_remote <dépôt> <branche> — sha complet du sommet de la branche.
# Sert à résoudre une révision non épinglée AVANT le build (les LABEL doivent
# dire ce qui a réellement été compilé) et à comparer dans cmd_image_update. Un
# dépôt injoignable est une erreur : construire « au hasard de ce que git clone
# ramènera » est précisément ce qu'on veut éviter.
_image_ls_remote() {
  local repo="$1" branche="$2" sha
  sha="$(git ls-remote "$repo" "refs/heads/$branche" 2>/dev/null | awk 'NR==1{print $1}')" || true
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || error "git ls-remote $repo $branche : révision illisible."
  printf '%s\n' "$sha"
}

# _image_size <ref> — taille de l'image en octets, vide si absente.
_image_size() {
  docker image inspect "$1" --format '{{.Size}}' 2>/dev/null || true
}

# _image_size_h <octets> — même arrondi que partout ailleurs : une décimale.
_image_size_h() {
  local o="${1:-}"
  [[ "$o" =~ ^[0-9]+$ ]] || { echo "n/c"; return 0; }
  awk -v o="$o" 'BEGIN{ printf "%.1f Go\n", o/1073741824 }'
}

# _image_versions <ref> — contenu de /opt/strix/versions.txt DANS l'image.
# --network none et --entrypoint cat : aucune chance d'exécuter le moteur, aucun
# accès réseau, rien de monté. C'est la source de vérité sur ce que l'image
# contient (les LABEL, eux, disent ce qu'on a DEMANDÉ).
_image_versions() {
  docker run --rm --network none --entrypoint cat "$1" /opt/strix/versions.txt 2>/dev/null || true
}

# _image_label <ref> <nom de label>
_image_label() {
  docker image inspect "$1" --format "{{index .Config.Labels \"$2\"}}" 2>/dev/null || true
}

# _image_rev_match <sha demandé> <champ de versions.txt> — versions.txt ne garde
# que des sha COURTS (rev-parse --short, longueur variable selon le dépôt) : la
# comparaison se fait donc par préfixe, dans ce sens-là seulement.
_image_rev_match() {
  local demande="$1" trouve="$2"
  [[ -n "$demande" && -n "$trouve" ]] || return 1
  [[ "${demande:0:${#trouve}}" == "$trouve" ]]
}

# _image_dangling — identifiants des images SANS TAG qui portent notre étiquette.
# Deux origines : l'image que le nouveau :latest vient de remplacer, et les
# couches finales de builds antérieurs. Le double filtre est la garantie de
# sûreté : jamais de docker system prune, jamais de docker image prune -a, rien
# qui ne vienne pas de notre Dockerfile.
_image_dangling() {
  docker image ls --filter "label=$IMAGE_LABEL_ENGINE" --filter "dangling=true" -q 2>/dev/null \
    | sort -u || true
}

# _image_purge_dangling — supprime ces images-là, une par une (un échec sur
# l'une, par exemple parce qu'un conteneur la retient, ne doit pas empêcher les
# autres ni faire échouer un build par ailleurs réussi).
_image_purge_dangling() {
  local -a ids=()
  mapfile -t ids < <(_image_dangling)
  [[ ${#ids[@]} -gt 0 ]] || return 0

  local id n=0
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    if docker image rm "$id" >/dev/null 2>&1; then
      n=$(( n + 1 ))
    else
      warn "Image sans tag $id non supprimée (encore utilisée ?) — sans conséquence."
    fi
  done
  [[ "$n" -gt 0 ]] && info "Ménage : $n image(s) sans tag de nos builds supprimée(s)."
  return 0
}

# _image_echec_build <ref temporaire> <message> — sortie d'échec d'un build :
# le tag temporaire est retiré (l'image devient sans tag, le prochain build
# réussi la ramassera) et :latest reste exactement ce qu'elle était. Appelée
# après la construction, quand une vérification refuse de promouvoir.
_image_echec_build() {
  docker image rm "$1" >/dev/null 2>&1 || true
  error "$2"
}

# _image_build_cache_h — taille du cache de build docker, telle que docker la
# déclare. Il n'est PAS purgé automatiquement : `docker builder prune` ne sait
# pas filtrer sur l'origine d'un cache, et la machine porte d'autres builds
# (bench-agentic-pi). --image-status l'affiche et donne la commande à lancer à
# la main, c'est tout.
_image_build_cache_h() {
  docker system df 2>/dev/null | awk '/^Build Cache/ { print $3; exit }' || true
}

# =============================================================================
# --image-build
# =============================================================================

# cmd_image_build [--no-cache] — construit l'image depuis runtime/ sous un tag
# TEMPORAIRE, vérifie qu'elle contient bien ce qui a été demandé, et seulement
# alors la promeut en :latest et fait le ménage. Ne touche à aucun service.
#
# Ordre voulu : build → vérification → promotion → ménage. Tant que la
# vérification n'est pas passée, l'ancienne :latest est intacte et reste le
# moteur utilisable ; c'est le seul filet de sécurité qui reste depuis qu'on ne
# garde plus les anciens tags.
cmd_image_build() {
  local arg="${1:-}"
  local -a cache_opt=()
  case "$arg" in
    "")          ;;
    --no-cache)  cache_opt=(--no-cache) ;;
    *)           error "--image-build : argument inconnu '$arg' (attendu : --no-cache)." ;;
  esac

  command -v docker >/dev/null 2>&1 || error "docker introuvable — l'image ne peut pas être construite ici."
  [[ -f "$IMAGE_DOCKERFILE" ]] || error "$IMAGE_DOCKERFILE absent — le dépôt est incomplet."

  _image_read_conf

  # Résolution AVANT le build : un LABEL ne peut pas lire versions.txt, produit
  # pendant le build. Une révision épinglée est prise telle quelle, une révision
  # vide est résolue au sommet de la branche.
  local engine_rev="$ENGINE_REV" rocm_rev="$ROCM_SYSTEMS_REV"
  if [[ -z "$engine_rev" ]]; then
    info "ENGINE_REV vide — résolution de $ENGINE_BRANCH..."
    engine_rev="$(_image_ls_remote "$ENGINE_REPO" "$ENGINE_BRANCH")"
  fi
  if [[ -z "$rocm_rev" ]]; then
    info "ROCM_SYSTEMS_REV vide — résolution de $ROCM_SYSTEMS_BRANCH..."
    rocm_rev="$(_image_ls_remote "$ROCM_SYSTEMS_REPO" "$ROCM_SYSTEMS_BRANCH")"
  fi

  local build_date ref_tmp ref
  build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  ref_tmp="${IMAGE_NAME}:${IMAGE_BUILD_TAG}"
  ref="${IMAGE_NAME}:$(_image_tag)"

  info "Image     : $ref (construite sous $ref_tmp)"
  info "Moteur    : $ENGINE_REPO@$engine_rev ($ENGINE_BRANCH)"
  info "Runtime   : $ROCM_SYSTEMS_REPO@$rocm_rev ($ROCM_SYSTEMS_BRANCH)"
  info "Construction (compter 40 à 60 minutes à froid : ROCr, HIP et le moteur sont compilés)."

  # --build-arg REPO/BRANCH : noms de l'amont, gardés tels quels pour que le
  # Dockerfile reste diffable contre lui (cf. runtime/AMONT.md).
  docker build "${cache_opt[@]+"${cache_opt[@]}"}" \
    -f "$IMAGE_DOCKERFILE" \
    --build-arg "REPO=$ENGINE_REPO" \
    --build-arg "BRANCH=$ENGINE_BRANCH" \
    --build-arg "ENGINE_REV=$engine_rev" \
    --build-arg "ROCM_SYSTEMS_REPO=$ROCM_SYSTEMS_REPO" \
    --build-arg "ROCM_SYSTEMS_BRANCH=$ROCM_SYSTEMS_BRANCH" \
    --build-arg "ROCM_SYSTEMS_REV=$rocm_rev" \
    --build-arg "BUILD_DATE=$build_date" \
    -t "$ref_tmp" \
    "$RUNTIME_DIR" \
    || error "docker build en échec — $ref inchangée."

  # Vérification d'après-coup. Le build a ses propres portes (patch retained-PM4
  # présent, test-backend-sched-ring, ldd), mais aucune ne dit QUELLE révision a
  # fini dedans : un cache de couche, une branche réécrite ou un --build-arg
  # perdu donneraient une image juste mais pas celle demandée, et toutes les
  # mesures suivantes seraient étiquetées à tort.
  #
  local versions v_engine v_rocm
  versions="$(_image_versions "$ref_tmp")"
  if [[ -z "$versions" ]]; then
    _image_echec_build "$ref_tmp" "$ref_tmp : /opt/strix/versions.txt illisible dans l'image ($ref inchangée)."
  fi
  v_engine="$(printf '%s\n' "$versions" | sed -n 's/^llama_cpp=\([0-9a-f]*\).*/\1/p' | head -1)"
  v_rocm="$(printf '%s\n' "$versions" | sed -n 's/^rocm_systems=\([0-9a-f]*\).*/\1/p' | head -1)"

  if ! _image_rev_match "$engine_rev" "$v_engine"; then
    warn "versions.txt de l'image construite :"
    printf '%s\n' "$versions" | sed 's/^/       /'
    _image_echec_build "$ref_tmp" "Moteur demandé $engine_rev, image construite sur '${v_engine:-?}' — $ref inchangée."
  fi
  if ! _image_rev_match "$rocm_rev" "$v_rocm"; then
    warn "versions.txt de l'image construite :"
    printf '%s\n' "$versions" | sed 's/^/       /'
    _image_echec_build "$ref_tmp" "rocm-systems demandé $rocm_rev, image construite sur '${v_rocm:-?}' — $ref inchangée."
  fi
  info "✅ versions.txt conforme (moteur $v_engine, rocm-systems $v_rocm)."

  # Les quatre cibles, sur l'image finie et pas seulement sur l'étage builder.
  if ! docker run --rm --network none --entrypoint /bin/sh "$ref_tmp" \
        -c 'for b in '"${IMAGE_BINS[*]}"'; do [ -x "/usr/local/bin/$b" ] || { echo "$b"; exit 1; }; done' >/dev/null 2>&1; then
    _image_echec_build "$ref_tmp" "Au moins un binaire manque dans /usr/local/bin (${IMAGE_BINS[*]}) — $ref inchangée."
  fi
  info "✅ ${IMAGE_BINS[*]} présents dans /usr/local/bin."

  # Promotion : à partir d'ici l'ancienne :latest perd son tag et devient une
  # image sans tag, que le ménage ci-dessous ramasse.
  docker tag "$ref_tmp" "$ref" || _image_echec_build "$ref_tmp" "docker tag $ref_tmp → $ref en échec."
  docker image rm "$ref_tmp" >/dev/null 2>&1 || true
  info "✅ $ref promue."

  local taille
  taille="$(_image_size "$ref")"
  info "Taille    : $(_image_size_h "$taille")"

  # Journal : date, tag, révisions, taille. L'image, elle, ne garde pas
  # d'historique — un seul tag.
  [[ -f "$IMAGE_LOG" ]] || printf 'date\ttag\tengine_rev\trocm_rev\ttaille_octets\n' > "$IMAGE_LOG"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date '+%Y-%m-%d %H:%M')" "$(_image_tag)" "$engine_rev" "$rocm_rev" "${taille:-n/c}" >> "$IMAGE_LOG"

  _image_purge_dangling

  local cache
  cache="$(_image_build_cache_h)"
  [[ -n "$cache" ]] && info "Cache de build docker : $cache (non purgé — cf. --image-status)."

  info "✅ $ref construite et vérifiée. Le service tourne encore sur l'image précédente :"
  info "   l'appliquer par ./setup-llm.sh --restart (nouvelle série de mesures)."
}

# =============================================================================
# --image-update
# =============================================================================

# _image_confirm <texte> — même convention que _fork_confirm (lib/fork.sh) :
# question seulement sur un terminal interactif, défaut NON, entrée non
# interactive = rien, et IMAGE_UPDATE_YES=1 vaut accord explicite.
_image_confirm() {
  local quoi="$1" reply=""
  if [[ "${IMAGE_UPDATE_YES:-0}" == "1" ]]; then
    info "IMAGE_UPDATE_YES=1 — mise à jour confirmée sans question."
    return 0
  fi
  if [[ ! -t 0 ]]; then
    warn "Entrée non interactive — aucune confirmation possible, rien n'est modifié."
    warn "  Forcer sans question : IMAGE_UPDATE_YES=1 ./setup-llm.sh --image-update"
    return 1
  fi
  read -r -p "$quoi [o/N] " reply
  [[ "$reply" =~ ^[oOyY]$ ]]
}

# _image_conf_write <engine_rev> <rocm_rev> — réécrit les deux lignes *_REV de
# image.conf, sur place, en laissant TOUT le reste intact : c'est un fichier
# versionné et commenté, il ne se régénère pas, il se modifie. Son diff git est
# le journal des révisions, et le seul chemin de retour arrière du moteur.
_image_conf_write() {
  local e="$1" r="$2" tmp
  tmp="$(mktemp)"
  sed -e "s|^ENGINE_REV=.*|ENGINE_REV=$e|" \
      -e "s|^ROCM_SYSTEMS_REV=.*|ROCM_SYSTEMS_REV=$r|" \
      "$IMAGE_CONF" > "$tmp" || { rm -f "$tmp"; error "Réécriture de $IMAGE_CONF en échec."; }
  cat "$tmp" > "$IMAGE_CONF"
  rm -f "$tmp"
}

# cmd_image_update [engine-rev] [rocm-rev] — suivi d'amont de l'image.
#
# Sans argument : compare les révisions d'image.conf aux sommets des deux
# branches et S'ARRÊTE. Une image est un moteur : la faire avancer ouvre une
# nouvelle série de mesures, ça ne se fait pas au détour d'une commande de
# statut. Avec confirmation (ou avec des révisions données à la main) :
# image.conf est réécrit, puis --image-build est enchaîné. Aucun service n'est
# basculé, ici non plus — une image neuve ne devient pas le moteur toute seule.
#
# C'est aussi la commande du RETOUR ARRIÈRE : --image-update <ancien-engine>
# <ancien-rocm> (ou un git revert sur image.conf, puis --image-build).
cmd_image_update() {
  local arg_engine="${1:-}" arg_rocm="${2:-}"

  _image_read_conf

  local engine_cible rocm_cible
  if [[ -n "$arg_engine" || -n "$arg_rocm" ]]; then
    # Arguments explicites : ils valent demande ET accord. Une révision omise
    # garde celle d'image.conf (on ne bouge que ce qui est nommé).
    engine_cible="${arg_engine:-$ENGINE_REV}"
    rocm_cible="${arg_rocm:-$ROCM_SYSTEMS_REV}"
    info "Révisions données à la main :"
    info "  moteur        : ${ENGINE_REV:-(branche)} → $engine_cible"
    info "  rocm-systems  : ${ROCM_SYSTEMS_REV:-(branche)} → $rocm_cible"
  else
    info "Interrogation des deux amonts..."
    engine_cible="$(_image_ls_remote "$ENGINE_REPO" "$ENGINE_BRANCH")"
    rocm_cible="$(_image_ls_remote "$ROCM_SYSTEMS_REPO" "$ROCM_SYSTEMS_BRANCH")"

    local ecart=0
    if [[ "$ENGINE_REV" == "$engine_cible" ]]; then
      info "  moteur        : à jour ($ENGINE_BRANCH, ${engine_cible:0:7})"
    else
      warn "  moteur        : ${ENGINE_REV:0:7} → ${engine_cible:0:7} ($ENGINE_BRANCH)"
      ecart=1
    fi
    if [[ "$ROCM_SYSTEMS_REV" == "$rocm_cible" ]]; then
      info "  rocm-systems  : à jour ($ROCM_SYSTEMS_BRANCH, ${rocm_cible:0:7})"
    else
      warn "  rocm-systems  : ${ROCM_SYSTEMS_REV:0:7} → ${rocm_cible:0:7} ($ROCM_SYSTEMS_BRANCH)"
      ecart=1
    fi

    if [[ "$ecart" -eq 0 ]]; then
      info "Rien de nouveau en amont — image.conf inchangé, aucun build."
      return 0
    fi

    warn "⚠ Une nouvelle image ouvre une SÉRIE DE MESURES à part : les chiffres"
    warn "  des révisions précédentes ne s'y comparent pas."
    if ! _image_confirm "Réécrire runtime/image.conf sur ces révisions et construire ?"; then
      info "Rien n'a été modifié (image.conf intact, aucun build)."
      info "  Reprendre plus tard : ./setup-llm.sh --image-update"
      return 0
    fi
  fi

  _image_conf_write "$engine_cible" "$rocm_cible"
  info "runtime/image.conf réécrit — à commiter avec la raison du bump."
  cmd_image_build
}

# =============================================================================
# --image-status
# =============================================================================

# cmd_image_status — ce qui est demandé (image.conf) et ce qui est là (l'image
# :latest et ses étiquettes), plus le verdict de conformité entre les deux.
# Ne construit rien et ne purge rien : le ménage est fait par --image-build, et
# le cache de build n'est que signalé.
cmd_image_status() {
  _image_read_conf

  echo "Révisions demandées (runtime/image.conf) :"
  echo "  moteur        : $ENGINE_REPO"
  echo "                  ${ENGINE_REV:-(sommet de $ENGINE_BRANCH, non épinglé)}"
  echo "  rocm-systems  : $ROCM_SYSTEMS_REPO"
  echo "                  ${ROCM_SYSTEMS_REV:-(sommet de $ROCM_SYSTEMS_BRANCH, non épinglé)}"
  echo

  if ! command -v docker >/dev/null 2>&1; then
    warn "docker introuvable — aucune image lisible sur cette machine."
    return 0
  fi

  local ref
  if ! ref="$(_image_ref)"; then
    warn "Aucune image ${IMAGE_NAME}:$(_image_tag) ici — ./setup-llm.sh --image-build."
    return 0
  fi

  local l_engine l_rocm l_date taille
  l_engine="$(_image_label "$ref" "$IMAGE_LABEL_ENGINE")"
  l_rocm="$(_image_label "$ref" "$IMAGE_LABEL_ROCM")"
  l_date="$(_image_label "$ref" "$IMAGE_LABEL_DATE")"
  taille="$(_image_size "$ref")"

  echo "Image en place :"
  echo "  $ref"
  echo "  moteur        : ${l_engine:-(sans étiquette)}"
  echo "  rocm-systems  : ${l_rocm:-(sans étiquette)}"
  echo "  construite le : ${l_date:-(sans étiquette)}"
  echo "  taille        : $(_image_size_h "$taille")"
  echo

  # Conformité. Une révision non épinglée ne se juge pas hors ligne : on ne
  # prétend pas trancher, on dit pourquoi.
  local verdict="conforme"
  if [[ -z "$ENGINE_REV" || -z "$ROCM_SYSTEMS_REV" ]]; then
    verdict="indécidable"
  else
    [[ "$l_engine" == "$ENGINE_REV" ]] || verdict="à reconstruire"
    [[ "$l_rocm"   == "$ROCM_SYSTEMS_REV" ]] || verdict="à reconstruire"
  fi
  case "$verdict" in
    conforme)      info "✅ L'image porte bien les révisions d'image.conf." ;;
    "à reconstruire")
      warn "⚠ L'image ne correspond plus à image.conf — ./setup-llm.sh --image-build."
      [[ "$l_engine" == "$ENGINE_REV" ]] || warn "  moteur       : image ${l_engine:0:7}, conf ${ENGINE_REV:0:7}"
      [[ "$l_rocm"   == "$ROCM_SYSTEMS_REV" ]] || warn "  rocm-systems : image ${l_rocm:0:7}, conf ${ROCM_SYSTEMS_REV:0:7}"
      ;;
    indécidable)
      warn "Révision non épinglée dans image.conf : conformité non vérifiable"
      warn "  sans interroger l'amont (./setup-llm.sh --image-update le fait)."
      ;;
  esac
  echo

  # Images sans tag laissées par nos builds : normalement aucune, --image-build
  # les ramasse. Leur présence signale un build interrompu ou une suppression
  # refusée, et elle se voit sur le disque.
  local -a orphelines=()
  mapfile -t orphelines < <(_image_dangling)
  if [[ ${#orphelines[@]} -gt 0 && -n "${orphelines[0]}" ]]; then
    local id total=0 t
    for id in "${orphelines[@]}"; do
      t="$(_image_size "$id")"
      [[ "$t" =~ ^[0-9]+$ ]] && total=$(( total + t ))
    done
    warn "${#orphelines[@]} image(s) sans tag de nos builds : $(_image_size_h "$total")"
    warn "  Elles partent au prochain --image-build réussi."
  fi

  local cache
  cache="$(_image_build_cache_h)"
  if [[ -n "$cache" ]]; then
    echo "Cache de build docker (tous builds de la machine) : $cache"
    echo "  Non purgé automatiquement : aucun filtre ne distingue notre build"
    echo "  des autres. À la main, si la place manque : docker builder prune"
  fi
  [[ -f "$IMAGE_LOG" ]] && echo "Journal des builds : $IMAGE_LOG"
  echo "Historique des révisions : git log -p -- runtime/image.conf"
  return 0
}

# =============================================================================
# Exécution dans l'image
# =============================================================================

# _dk_run <binaire> [args...] — lance un binaire de l'image courante.
#
# Protections validées en exécution réelle sur bigchuck le 17/09/2026 ; elles
# remplacent celles du lanceur amont (refresh-toolboxes.sh), qui donne le groupe
# sudo au conteneur. Point par point :
#   --device /dev/kfd --device /dev/dri : les deux seuls accès matériels dont le
#     backend HIP a besoin. Pas de --privileged, jamais, et pas de docker.sock.
#   --group-add <gid numériques> : les gid de render et video sont ceux de
#     L'HÔTE et n'ont aucune raison d'exister dans l'image Fedora (ils n'y
#     existent pas). Passer les noms échoue donc ; getent résout sur l'hôte.
#   seccomp=unconfined : exigé par ROCm (ioctl du KFD hors profil par défaut).
#     Compensé par no-new-privileges et cap-drop=ALL, qui ne coûtent rien ici.
#   --shm-size 8g, memlock illimité : llama.cpp mmap les poids et épingle des
#     buffers ; les défauts docker (64 Mio, memlock bas) font échouer le
#     chargement des gros GGUF.
#   ~/models monté au MÊME chemin absolu, en lecture seule : les chemins de
#     models.ini sont absolus et doivent rester valides des deux côtés, et rien
#     ici n'a de raison d'écrire dans les poids. C'est aussi ce qui permet à
#     l'image de ne contenir AUCUN modèle et de rester jetable.
#   --network none par défaut : une mesure n'a pas à sortir. DK_RUN_NET=host
#     pour les cas qui exposent un port (le service, lui, passe par le compose
#     et une publication de port, jamais par network_mode: host).
_dk_run() {
  local bin="${1:-}"
  [[ -n "$bin" ]] || error "_dk_run : binaire manquant."
  shift

  command -v docker >/dev/null 2>&1 || error "docker introuvable."
  local ref
  ref="$(_image_ref)" || error "Aucune image ${IMAGE_NAME}:$(_image_tag) ici — ./setup-llm.sh --image-build d'abord."

  local -a gids=()
  local g gid
  for g in render video; do
    gid="$(getent group "$g" 2>/dev/null | cut -d: -f3)"
    if [[ "$gid" =~ ^[0-9]+$ ]]; then
      gids+=(--group-add "$gid")
    else
      warn "Groupe $g introuvable sur l'hôte — accès GPU probablement refusé dans le conteneur."
    fi
  done

  docker run --rm \
    --device /dev/kfd --device /dev/dri \
    ${gids[@]+"${gids[@]}"} \
    --security-opt seccomp=unconfined \
    --security-opt no-new-privileges \
    --cap-drop=ALL \
    --shm-size 8g \
    --ulimit memlock=-1:-1 \
    -v "$MODELS_BASE:$MODELS_BASE:ro" \
    --network "${DK_RUN_NET:-none}" \
    --entrypoint "$bin" \
    "$ref" "$@"
}
