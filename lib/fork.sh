# lib/fork.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → fork → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# Moteur : fork strix-llama.cpp
#
# Depuis le 12/09/2026 le service ne tourne plus sur le paquet Arch llama-cpp
# mais sur https://github.com/halo-box/strix-llama.cpp, construit ici et exposé
# par quatre liens dans $HOME/.local/bin. L'unité systemd met ce dossier en
# tête du PATH (lib/service.sh), donc le service prend le fork sans autre
# changement ; common.sh fait la même chose pour les mesures.
#
# Le paquet Arch reste installé : retirer les liens (--unset-fork) suffit à
# revenir dessus. Les binaires portent un RUNPATH ABSOLU vers leur dossier
# build : déplacer $FORK_DIR impose un rebuild complet, jamais un simple mv.
#
# ⚠ Comparabilité : les mesures faites sous le fork forment une nouvelle série
# (étiquette "strix-<commit>" dans la colonne build des journaux, cf.
# _llama_build) et ne se comparent pas aux campagnes "bNNNNN" du paquet Arch.
# =============================================================================

FORK_REPO="https://github.com/halo-box/strix-llama.cpp"
FORK_DIR="$HOME/llm/strix-llama.cpp"
FORK_BIN_DIR="$HOME/.local/bin"
# Les quatre cibles construites et liées : le serveur du service, llama-bench
# (courbes de batch, --list-devices), llama-cli et llama-quantize.
FORK_BINS=(llama-server llama-bench llama-cli llama-quantize)

# Clés de models.ini que SEUL le fork comprend. llama-server refuse toute clé
# inconnue et l'échec n'est pas local au modèle fautif : c'est le ROUTEUR
# ENTIER qui ne démarre pas (« failed to initialize router models: option
# 'ngram-on-disk' not recognized in preset ... », vérifié le 12/09/2026 sur le
# paquet Arch b10809). Le dépôt ne gère pas deux moteurs : il ne filtre rien et
# ne réécrit rien, il se contente de REFUSER de lancer un moteur upstream sur
# un ini qui contient ces clés (_fork_keys_guard, appelé par cmd_start), avec
# un message qui dit quoi faire — au lieu de laisser llama-server échouer sur
# un message qui ne nomme qu'une clé.
# Ne pas y mettre les clés que le paquet Arch connaît aussi (reasoning-budget,
# spec-draft-n-min) : elles ne bloquent rien.
FORK_ONLY_KEYS=(
  ngram-on-disk
  reasoning-budget-enable
  reasoning-budget-soft-ratio
  reasoning-budget-soft2-ratio
  reasoning-budget-grace-tokens
  spec-draft-adaptive
  spec-prefill
  spec-prefill-draft-model
  spec-prefill-p
)

# _fork_keys_guard [fichier ini] — garde-fou de démarrage. Ne dit rien si le
# moteur résolu est le fork (étiquette non numérique) ou inconnu ; sort en
# erreur s'il est upstream (étiquette bNNNNN, forme du paquet) et que le ini
# porte une clé de FORK_ONLY_KEYS, en nommant le modèle et la clé.
_fork_keys_guard() {
  local ini="${1:-$CONFIG_DIR/models.ini}"
  [[ -f "$ini" ]] || return 0

  # Étiquette de moteur (_llama_build) : "bNNNNN" = build upstream, seul cas
  # où la garde s'applique. Le fork ne numérote pas ses builds et s'étiquette
  # "<dépôt>-<commit>" ; "?" = moteur non identifié, on ne bloque pas.
  # Limite assumée : la distinction repose sur le numéro de build annoncé par
  # --version (le fork dit "build 1", faute de tags upstream dans son clone).
  # Un fork qui récupérerait ces tags s'annoncerait "bNNNNN" et se ferait
  # refuser à tort ; --list-devices montre alors le binaire réellement résolu.
  local etiquette
  etiquette="$(_llama_build)"
  [[ "$etiquette" =~ ^b[0-9]+(-[0-9]+)?$ ]] || return 0

  local ligne section="" cle k
  local -a fautives=()
  while IFS= read -r ligne; do
    if [[ "$ligne" =~ ^\[(.*)\]$ ]]; then
      section="${BASH_REMATCH[1]}"
      continue
    fi
    [[ "$ligne" == *=* ]] || continue
    cle="${ligne%%=*}"; cle="${cle// /}"
    for k in "${FORK_ONLY_KEYS[@]}"; do
      if [[ "$cle" == "$k" ]]; then
        fautives+=("[$section] $cle")
      fi
    done
  done < "$ini"

  [[ ${#fautives[@]} -gt 0 ]] || return 0

  warn "Moteur résolu : $(_llama_bin llama-server) (build $etiquette = paquet upstream)."
  warn "$ini contient des clés propres au fork strix-llama.cpp :"
  local f
  for f in "${fautives[@]}"; do warn "  $f"; done
  warn "llama-server upstream refuse une clé inconnue et le ROUTEUR ENTIER"
  warn "  ne démarrerait pas (pas seulement ce modèle)."
  warn "Deux issues :"
  warn "  - repasser sur le fork : ./setup-llm.sh --setup-fork"
  warn "  - rester sur le paquet : retirer ces clés de lib/models.sh, puis"
  warn "    ./setup-llm.sh --preload (régénère le ini)"
  error "Démarrage refusé : moteur upstream et clés de fork dans le ini."
}

# Version résolue du moteur, telle que la voient le service et les mesures.
# Affichée par --setup-fork, --unset-fork et --list-devices.
_fork_status() {
  local bin ver
  bin="$(_llama_bin llama-server)"
  if [[ -z "$bin" ]]; then
    warn "llama-server introuvable (ni $FORK_BIN_DIR, ni le PATH)."
    return 0
  fi
  ver="$("$bin" --version 2>&1 | head -1)"
  info "Moteur résolu : $bin"
  [[ -L "$bin" ]] && info "  → $(realpath "$bin" 2>/dev/null)"
  info "  $ver"
  info "  Étiquette des journaux : $(_llama_build)"
  return 0
}

# =============================================================================
# Briques communes à --setup-fork et --update-fork : mise à jour du clone,
# construction des quatre cibles, pose des liens. Une seule implémentation de
# chaque étape, deux commandes qui les enchaînent différemment.
# =============================================================================

# Outils nécessaires à toute opération sur le fork.
_fork_tools() {
  command -v git >/dev/null   || error "git introuvable"
  command -v cmake >/dev/null || error "cmake introuvable (paru -S cmake)"
}

# Commit court du clone ("?" si illisible).
_fork_head() {
  git -C "$FORK_DIR" rev-parse --short HEAD 2>/dev/null || echo '?'
}

# Les quatre liens de $FORK_BIN_DIR pointent-ils bien dans le build du fork ?
# Sert à --update-fork : mettre à jour un dépôt dont le moteur en place ne vient
# pas (paquet Arch, ou autre build) n'a aucun effet visible et tromperait.
# Remplit FORK_LINKS_KO avec les binaires fautifs.
_fork_links_ok() {
  FORK_LINKS_KO=()
  local b cible
  for b in "${FORK_BINS[@]}"; do
    cible="$(realpath "$FORK_BIN_DIR/$b" 2>/dev/null || true)"
    if [[ -z "$cible" || "$cible" != "$FORK_DIR/build/"* ]]; then
      FORK_LINKS_KO+=("$b")
    fi
  done
  [[ ${#FORK_LINKS_KO[@]} -eq 0 ]]
}

# git pull --ff-only sur un clone existant. $1 = commande appelante, citée dans
# le message d'arbre sale.
# Arbre sale : `git pull` échouerait de toute façon (ou pire, réussirait en
# gardant des modifications locales dans le build), et le message de git est
# obscur. On le dit ici, on ne nettoie jamais à la place de l'humain.
_fork_pull() {
  local appelant="${1:---setup-fork}"
  if [[ -n "$(git -C "$FORK_DIR" status --porcelain 2>/dev/null)" ]]; then
    warn "Modifications locales dans $FORK_DIR :"
    git -C "$FORK_DIR" status --short | sed 's/^/  /'
    error "Arbre sale — committer, remiser ou annuler à la main avant $appelant."
  fi
  git -C "$FORK_DIR" pull --ff-only \
    || error "git pull --ff-only en échec — dépôt divergent ? Régler à la main dans $FORK_DIR"
}

# Configuration cmake + construction des quatre cibles.
# Vulkan uniquement : c'est le backend de tous les modèles retenus
# (bench-devices.conf) ; ROCm reste servi par le paquet Arch si besoin.
_fork_build() {
  info "Configuration cmake (Vulkan, Release, CURL)..."
  cmake -B "$FORK_DIR/build" -S "$FORK_DIR" \
    -DGGML_VULKAN=ON -DCMAKE_BUILD_TYPE=Release -DLLAMA_CURL=ON \
    || error "cmake -B en échec"

  # nproc vient de coreutils, mais un -j vide vaut « parallélisme illimité » :
  # repli explicite plutôt qu'une machine à genoux.
  local jobs
  jobs="$(nproc 2>/dev/null || echo 4)"
  [[ "$jobs" =~ ^[0-9]+$ && "$jobs" -gt 0 ]] || jobs=4

  info "Construction (${FORK_BINS[*]}, -j$jobs)... compter plusieurs minutes."
  # Construire D'ABORD, lier ENSUITE : un build interrompu ne doit jamais
  # laisser de lien neuf vers un binaire absent. Les liens déjà en place, eux,
  # pointent vers le build précédent que cmake vient peut-être d'écraser à
  # moitié — d'où le rappel de vérification.
  cmake --build "$FORK_DIR/build" --config Release -j"$jobs" \
    --target "${FORK_BINS[@]}" \
    || {
      warn "Les liens de $FORK_BIN_DIR pointent vers ce build à moitié refait :"
      warn "  vérifier par ./setup-llm.sh --list-devices avant tout restart,"
      warn "  et --unset-fork pour revenir au paquet en attendant."
      error "Construction en échec"
    }
}

# Pose (ou repose) les quatre liens du fork dans $FORK_BIN_DIR.
_fork_links() {
  info "Pose des liens dans $FORK_BIN_DIR..."
  mkdir -p "$FORK_BIN_DIR"
  local b
  for b in "${FORK_BINS[@]}"; do
    [[ -x "$FORK_DIR/build/bin/$b" ]] || error "Binaire manquant après build : $b"
    ln -sfn "$FORK_DIR/build/bin/$b" "$FORK_BIN_DIR/$b"
    info "  $b → $FORK_DIR/build/bin/$b"
  done
}

# =============================================================================
# --setup-fork : installe OU met à jour. Clone si absent, sinon git pull
# --ff-only (une divergence locale doit se voir, pas se faire écraser), puis
# rebuild et liens. Ne redémarre pas le service : le rappel suffit, un restart
# recharge tous les modèles préchargés.
#
# Le suivi d'amont au quotidien passe par --update-fork, qui exige un fork déjà
# en place et s'arrête si rien n'a bougé.
# =============================================================================

cmd_setup_fork() {
  _fork_tools

  local avant="" apres=""
  if [[ -d "$FORK_DIR/.git" ]]; then
    avant="$(_fork_head)"
    info "Mise à jour de $FORK_DIR (commit actuel $avant)..."
    _fork_pull --setup-fork
  else
    [[ -e "$FORK_DIR" ]] && error "$FORK_DIR existe mais n'est pas un dépôt git"
    info "Clone de $FORK_REPO dans $FORK_DIR..."
    mkdir -p "$(dirname "$FORK_DIR")"
    git clone "$FORK_REPO" "$FORK_DIR" || error "Clone en échec"
  fi
  apres="$(_fork_head)"
  if [[ -n "$avant" && "$avant" == "$apres" ]]; then
    info "Commit inchangé : $apres (rebuild quand même, cmake ne refait que le nécessaire)."
  else
    info "Commit : ${avant:-néant} → $apres"
  fi

  _fork_build
  _fork_links

  echo ""
  _fork_status
  echo ""
  warn "Le service ne redémarre pas tout seul : appliquer par"
  warn "  systemctl --user restart $SERVICE_NAME"
  warn "Mesures postérieures = nouvelle série, non comparable aux campagnes Arch."
  warn "Ne jamais déplacer $FORK_DIR (RUNPATH absolu) : relancer --setup-fork après."
}

# =============================================================================
# --update-fork : suivi d'amont, à lancer juste après un --update. Ne fait QUE
# la mise à jour du moteur déjà en place : pas de clone, pas de restart, pas de
# mesure. Refuse si le fork n'est pas installé ou n'est pas le moteur résolu
# (--setup-fork est là pour ça), s'arrête sans rebuild si rien n'a bougé en
# amont, et se termine sur le rappel de l'enchaînement (restart, puis --bench à
# la main quand l'humain le décide : chaque bump ouvre une nouvelle série de
# mesures étiquetée au commit).
# =============================================================================

cmd_update_fork() {
  # Les deux refus d'abord : ils ne dépendent que de l'état du disque, et une
  # machine sans cmake doit quand même se voir renvoyer vers --setup-fork.
  [[ -d "$FORK_DIR/.git" ]] \
    || error "$FORK_DIR n'est pas un clone du fork — lancer --setup-fork d'abord."

  if ! _fork_links_ok; then
    warn "Liens de $FORK_BIN_DIR ne pointant pas dans $FORK_DIR/build :"
    local b
    for b in "${FORK_LINKS_KO[@]}"; do
      warn "  $b → $(realpath "$FORK_BIN_DIR/$b" 2>/dev/null || echo 'absent')"
    done
    warn "Mettre à jour un dépôt dont le moteur en place ne vient pas ne changerait rien."
    error "Fork non installé comme moteur — lancer --setup-fork d'abord."
  fi

  _fork_tools

  local avant apres n
  avant="$(_fork_head)"
  info "Suivi d'amont sur $FORK_DIR (commit actuel $avant)..."
  _fork_pull --update-fork
  apres="$(_fork_head)"

  if [[ "$avant" == "$apres" ]]; then
    info "Rien de nouveau en amont : toujours $apres."
    info "Aucun rebuild, aucun lien touché, rien à remesurer."
    return 0
  fi

  n="$(git -C "$FORK_DIR" rev-list --count "$avant..$apres" 2>/dev/null || echo '?')"
  info "Commit : $avant → $apres ($n commit(s) d'amont)"

  _fork_build
  _fork_links

  echo ""
  _fork_status
  echo ""
  warn "Rien n'est lancé automatiquement. Enchaînement :"
  warn "  1. redémarrer le service : systemctl --user restart $SERVICE_NAME"
  warn "  2. nouvelle série de mesures : lancer ./setup-llm.sh --bench à la main"
  warn "     quand vous voulez — aucun bench n'est déclenché ici."
  warn "Le moteur a changé de commit : les mesures qui suivent portent l'étiquette"
  warn "  $(_llama_build) et forment une série à part des précédentes."
}

# =============================================================================
# --unset-fork : retire les quatre liens, le paquet Arch (toujours installé)
# reprend la main au prochain démarrage du service. Le dépôt et son build
# restent sur disque, --setup-fork les réactive sans rebuild.
# =============================================================================

cmd_unset_fork() {
  local b n=0
  for b in "${FORK_BINS[@]}"; do
    if [[ -L "$FORK_BIN_DIR/$b" ]]; then
      rm -f "$FORK_BIN_DIR/$b"
      info "Lien retiré : $FORK_BIN_DIR/$b"
      n=$((n + 1))
    fi
  done
  if [[ "$n" -eq 0 ]]; then
    info "Aucun lien de fork dans $FORK_BIN_DIR — déjà sur le paquet Arch."
  else
    warn "Retour au paquet Arch après : systemctl --user restart $SERVICE_NAME"
    warn "⚠ Les clés ini propres au fork (${FORK_ONLY_KEYS[*]})"
    warn "  font ÉCHOUER le démarrage du ROUTEUR ENTIER sur le paquet Arch :"
    warn "  llama-server refuse toute clé inconnue (« option ... not recognized »)."
    warn "  Le dépôt ne les retire pas tout seul — il ne fait que le signaler :"
    warn "  --start refuse de lancer un moteur upstream sur un tel ini."
    warn "  Pour rester sur le paquet : retirer ces clés de lib/models.sh, puis"
    warn "  ./setup-llm.sh --preload (régénère le ini) avant le restart."
  fi
  echo ""
  _fork_status
}
