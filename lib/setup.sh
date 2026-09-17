# lib/setup.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# setup
# =============================================================================

# Runtime ROCm + backend ggml-hip — installés en best-effort par --setup
# (jamais bloquant). ggml-hip est le backend HIP splitté d'extra/ggml : sans
# lui, ROCm0 n'est pas exposé même runtime installé.
# gfx1151 requis côté rocblas/hipblaslt : contrôler avec `rocminfo | grep gfx`.
ROCM_PKGS=(rocm-hip-runtime hipblas rocblas hipblaslt ggml-hip)

cmd_setup() {
  info "Vérification des dépendances..."
  # ggml-cpu + ggml-vulkan : backends splittés d'extra/ggml (optdeps, donc
  # à imposer — sans ggml-vulkan plus de Vulkan0, sans ggml-cpu plus d'ops CPU).
  # ⚠ Ces paquets ne concernent PLUS le service, qui tourne dans l'image ROCm
  # (runtime/) : ils servent les outils hors service (llama-bench des courbes
  # de batch, llama-server jetable de tools/spec-isolate.sh).
  PACMAN_PKGS=(curl llama-cpp ggml-cpu ggml-vulkan python-huggingface-hub python-hf-xet)
  MISSING=()
  for pkg in "${PACMAN_PKGS[@]}"; do
    paru -Qi "$pkg" &>/dev/null || MISSING+=("$pkg")
  done
  [[ ${#MISSING[@]} -gt 0 ]] && paru -S --noconfirm "${MISSING[@]}"
  command -v hf >/dev/null || error "hf introuvable"

  # --- Runtime ROCm + ggml-hip : best-effort, jamais bloquant ---------------
  # (backend HIP splitté : ggml-hip requis EN PLUS du runtime pour voir ROCm0)
  info "Vérification du runtime ROCm de l'hôte (optionnel, outils hors service)..."
  local rocm_missing=() rocm_to_install=()
  local pkg
  for pkg in "${ROCM_PKGS[@]}"; do
    if paru -Qi "$pkg" &>/dev/null; then
      continue
    elif paru -Si "$pkg" &>/dev/null; then
      rocm_to_install+=("$pkg")
    else
      rocm_missing+=("$pkg")
    fi
  done
  if [[ ${#rocm_to_install[@]} -gt 0 ]]; then
    warn "Paquets ROCm à installer (ROCm0 pour les outils HORS service) : ${rocm_to_install[*]}"
    local reply="n"
    if [[ -t 0 ]]; then
      read -r -p "Installer le runtime ROCm ? [o/N] " reply
    else
      warn "Entrée non interactive — installation ROCm sautée par défaut."
    fi
    if [[ "$reply" =~ ^[oOyY]$ ]]; then
      paru -S --noconfirm "${rocm_to_install[@]}" \
        || warn "Installation ROCm en échec — sans effet sur le service, qui tourne dans l'image."
    else
      info "Runtime ROCm de l'hôte non installé — sans effet sur le service."
      info "  (relancer --setup plus tard pour l'ajouter ; il ne sert qu'aux outils hors service)"
    fi
  fi
  if [[ ${#rocm_missing[@]} -gt 0 ]]; then
    warn "Paquets ROCm introuvables dans les dépôts : ${rocm_missing[*]}"
    warn "  → sans conséquence pour le service, qui embarque son propre ROCm"
    warn "    dans l'image ; seuls les outils hors service s'en passent."
  fi
  if command -v rocminfo >/dev/null 2>&1; then
    if rocminfo 2>/dev/null | grep -q gfx1151; then
      info "ROCm OK : gfx1151 (Strix Halo) détecté."
    else
      warn "rocminfo présent mais gfx1151 non détecté — rocblas/hipblaslt sans"
      warn "  support gfx1151 ? (alternative AUR : rocm-nightly-gfx1151-bin)"
    fi
  fi
  # -------------------------------------------------------------------------

  info "Création des dossiers..."
  local f
  for f in "${KNOWN_FILES[@]}"; do
    mkdir -p "$(dirname "$f")"
  done

  # Téléchargements pilotés par les déclarations de models.sh (DL_SPECS),
  # dans l'ordre de déclaration (= ordre du ini)
  # p1/p2 : sens dépendant du mode — repo + fichier (plat), repo + glob (shard).
  # (le mode "derive", fichier calculé en local après coup, a disparu le
  # 18/09/2026 avec son seul usage, cf. lib/models.sh)
  local spec mode cible p1 p2
  for spec in "${DL_SPECS[@]}"; do
    IFS=$'\t' read -r mode cible p1 p2 <<< "$spec"
    case "$mode" in
      plat)   _dl "$cible" "$p1" "$p2" ;;
      shard)  _dl_shard "$cible" "$p1" "$p2" ;;
    esac
  done

  # --- Moteur du service : docker + image ----------------------------------
  # Le service ne lance plus un binaire de l'hôte : il monte un conteneur
  # décrit par le compose généré. Sans docker ou sans image, --setup va
  # jusqu'au bout (les poids et le ini sont utiles quand même) mais le dit.
  _setup_check_docker

  info "Sélection des modèles préchargés au démarrage..."
  select_preload_models

  info "Génération de models.ini et du docker-compose.yml..."
  regen_models_ini
  # Le compose n'est pas indispensable au reste du setup : _svc_start le
  # régénère de toute façon. Le générer ici sert à échouer TÔT et clairement
  # (image absente, groupe render manquant) plutôt qu'au premier --start.
  regen_compose || warn "docker-compose.yml non généré (voir ci-dessus) - --start le retentera."

  info "✅ Config générée : $CONFIG_DIR/models.ini"
  info "Setup terminé → ./setup-llm.sh --start"
  info "Changer le préchargement → ./setup-llm.sh --preload"
  info "Mesurer les perfs → ./setup-llm.sh --bench [modèle|all]"
  info "Devices exposés par l'image → ./setup-llm.sh --list-devices"

  _setup_propose_fork

  _maybe_restart_service
}

# Moteur du SERVICE : docker et l'image du dépôt. Jamais bloquant - un --setup
# sert aussi à télécharger des poids sur une machine qui ne servira rien.
# Isolée de cmd_setup pour être testable seule, comme _setup_propose_fork.
_setup_check_docker() {
  info "Vérification du moteur du service (docker + image)..."
  if ! command -v docker >/dev/null 2>&1; then
    warn "docker introuvable : le service tourne en CONTENEUR, il ne démarrera pas ici."
    warn "  Installer docker, activer le démon au boot, puis ./setup-llm.sh --image-build."
    return 0
  fi
  if ! docker info >/dev/null 2>&1; then
    warn "Le démon docker ne répond pas (non démarré, ou utilisateur hors du groupe docker)."
    warn "  Sans lui, ni --image-build ni --start ne fonctionnent."
    return 0
  fi
  local ref
  if ref="$(_image_ref 2>/dev/null)"; then
    info "  Image du moteur : $ref (étiquette des mesures : $(_llama_build))"
  else
    warn "  Aucune image du moteur ici - ./setup-llm.sh --image-build (40 à 60 min à froid)."
  fi
  return 0
}

# Proposition du moteur HORS SERVICE, en fin de --setup (et donc de --update).
# Le fork n'est plus le moteur du service (c'est l'image), mais il reste celui
# des outils hors service (llama-bench de --spec-ngram-tune,
# tools/bench-depth.sh, tools/spec-isolate.sh) et le filet de retour arrière de
# la migration.
# Isolée de cmd_setup pour être testable seule (tests/sh-unit.sh) : cmd_setup
# fait paru, hf et réseau, cette fonction ne lit que l'état du disque.
#
# Le fork strix-llama.cpp n'est pas un agrément : le parc est réglé pour lui
# (FORK_ONLY_KEYS dans le ini, sidecar MTP de Flash-Next) et le retour arrière
# de la migration passe par lui. D'où la question, défaut OUI, contrairement à
# la proposition ROCm (défaut non, simple option de mesure).
#
# Le paquet Arch reste installé dans tous les cas : c'est le repli (--unset-fork)
# et le seul chemin vers ROCm0.
#
# Note d'ordre de source : lib/setup.sh est sourcé AVANT lib/fork.sh, mais
# l'appel n'a lieu qu'à l'exécution, quand cmd_setup_fork et _fork_links_ok
# existent. Aucune variable de fork.sh n'est lue avant cet appel.
_setup_propose_fork() {
  local etiquette reply
  etiquette="$(_host_llama_build)"

  # Fork en place = étiquette non numérique (cf. _host_llama_build) ET les quatre
  # liens de ~/.local/bin pointant dans son build (_fork_links_ok) : un moteur
  # étiqueté "?" ou "bNNNNN" est le paquet, des liens partiels ne sont pas un
  # fork installé.
  if [[ ! "$etiquette" =~ ^b[0-9]+(-[0-9]+)?$ && "$etiquette" != "?" ]] \
     && _fork_links_ok; then
    if _fork_pin_read; then
      info "Moteur : fork strix-llama.cpp $etiquette, épinglé sur $FORK_PIN${FORK_PIN_RAISON:+ ($FORK_PIN_RAISON)} ; --update-fork ne tire rien tant que l'épinglage tient"
    else
      info "Moteur : fork strix-llama.cpp $etiquette ; suivi d'amont par ./setup-llm.sh --update-fork"
    fi
    return 0
  fi

  echo ""
  warn "Moteur hors service : le fork strix-llama.cpp n'est pas en place (résolu : $etiquette)."
  warn "  Les réglages du parc en dépendent : clés ini que seul le fork comprend"
  warn "  (${#FORK_ONLY_KEYS[@]} au total, dont ${FORK_ONLY_KEYS[0]} et reasoning-budget-*) et sidecar MTP de"
  warn "  Flash-Next ; il reste aussi le moteur de llama-bench (--spec-ngram-tune,"
  warn "  tools/bench-depth.sh) et le retour arrière de la migration en conteneur."

  if [[ ! -t 0 ]]; then
    warn "Entrée non interactive — rien n'est installé. À lancer :"
    warn "  ./setup-llm.sh --setup-fork"
    return 0
  fi

  reply=""
  read -r -p "Installer le fork strix-llama.cpp comme moteur maintenant ? [O/n] " reply
  reply="${reply:-o}"
  if [[ "$reply" =~ ^[oOyY]$ ]]; then
    cmd_setup_fork
  else
    info "Fork non installé — le paquet Arch reste le moteur."
    info "  (l'installer plus tard : ./setup-llm.sh --setup-fork)"
  fi
}

# =============================================================================
# update — retélécharge uniquement les fichiers modifiés en amont
#
# `hf download --local-dir` conserve les métadonnées de chaque fichier dans
# <dossier>/.cache/huggingface/download/. Au second passage il compare l'etag
# distant et ne retransfère que ce qui a réellement bougé — le reste ne coûte
# qu'une requête HEAD. Le seul travail du script est donc de ne PAS court-
# circuiter sur "fichier déjà présent" (REFRESH=1).
#
# Note : la toute première mise à jour d'un fichier téléchargé avant que les
# métadonnées n'existent oblige hf à recalculer son sha256 en local — comptez
# une lecture disque complète du GGUF, sans réseau.
#
# Updates amont connus (juillet/août 2026) à rattraper si téléchargés avant :
#   --update qwen3.8-27b    (repo day-zero mi-août, template/quants mouvants)
#   (l'entrée laguna-s-2.1, fix rope/context 256K YaRN + fixes poolside, est
#    tombée avec le retrait du modèle le 15/09/2026 : docs/HISTORIQUE.md)
# =============================================================================

cmd_update() {
  ONLY="${1:-}"
  REFRESH=1

  if [[ -n "$ONLY" ]]; then
    [[ -d "$MODELS_BASE/$ONLY" ]] || error "Modèle inconnu : '$ONLY' (voir $MODELS_BASE/)"
    info "Vérification des mises à jour pour '$ONLY'..."
  else
    info "Vérification des mises à jour pour tous les modèles..."
  fi

  warn "Prévoir 2× la taille du plus gros fichier remplacé (écriture en .incomplete puis move)."
  warn "Un restart du service sera proposé en fin de run (poids mmap'és sur l'ancien inode sinon)."

  # Suivi du moteur : les modèles viennent d'être mis à jour, le fork qui les
  # sert ne l'est pas par cette commande. Le rappel (--update-fork si le fork
  # est en place, proposition d'installation sinon) est émis par
  # _setup_propose_fork, appelé en fin de cmd_setup — rien n'est lancé
  # automatiquement ici, ni mise à jour du moteur, ni restart, ni mesure.
  cmd_setup
}

# =============================================================================
# cleanup — supprime ce qui n'est plus référencé dans KNOWN_FILES
#
# Deux niveaux :
#   1. dossiers de premier niveau sous $MODELS_BASE dont plus aucun modèle ne
#      dépend (ex. qwen3.6-27b, qwen3.6-27b-mtp après leur remplacement par
#      qwen3.8-27b)
#   2. .gguf orphelins à l'intérieur d'un dossier encore référencé (ex. l'ancien
#      quant après un changement de UD-Q6_K_XL vers UD-Q4_K_XL)
#
# Les modèles en shards sont protégés au niveau du dossier de quant : KNOWN_FILES
# ne cite que le shard 00001, les suivants ne doivent évidemment pas sauter.
#
# ⚠ Les deux artefacts GÉNÉRÉS de $MODELS_BASE - `models.ini` (lib/ini.sh) et
# `docker-compose.yml` (lib/compose.sh) - sont hors d'atteinte PAR
# CONSTRUCTION, et les deux `find` ci-dessous ne doivent donc jamais être
# « corrigés » en ce sens : le premier ne liste que des DOSSIERS de premier
# niveau (`-maxdepth 1 -type d`), le second que des fichiers `*.gguf` à partir
# de la profondeur 2 (`-mindepth 2 -name '*.gguf'`). Ces deux fichiers sont des
# fichiers de premier niveau qui ne sont pas des .gguf : aucune des deux
# recherches ne peut les voir. Les élargir (retirer `-maxdepth`, viser `-type f`
# à la racine) supprimerait la configuration du service à chaque --cleanup,
# alors qu'elle se régénère certes, mais pas au milieu d'un run.
#
# Dry-run par défaut ; --yes pour exécuter réellement.
# =============================================================================

_in_list() {
  local needle="$1"; shift
  local item
  for item in "$@"; do
    [[ "$item" == "$needle" ]] && return 0
  done
  return 1
}

cmd_cleanup() {
  local assume_yes=0
  [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]] && assume_yes=1

  [[ -d "$MODELS_BASE" ]] || error "$MODELS_BASE introuvable"

  local f d parent
  local -a keep_keys=() keep_files=() keep_dirs=()

  for f in "${KNOWN_FILES[@]}"; do
    d="$(dirname "$f")"
    parent="$(dirname "$d")"
    keep_keys+=("$(_key "$f")")
    if [[ "$parent" == "$MODELS_BASE" ]]; then
      # fichier plat : on protège le fichier lui-même
      keep_files+=("$f")
    else
      # layout en shards : on protège tout le dossier de quant
      keep_dirs+=("$d")
    fi
  done

  local -a doomed=()

  # 1. dossiers de modèle entiers
  while IFS= read -r d; do
    _in_list "$(basename "$d")" "${keep_keys[@]}" || doomed+=("$d")
  done < <(find "$MODELS_BASE" -mindepth 1 -maxdepth 1 -type d ! -name '.cache' | sort)

  # 2. .gguf orphelins dans les dossiers conservés
  while IFS= read -r f; do
    _in_list "$(_key "$f")" "${keep_keys[@]}" || continue  # déjà couvert par 1.
    _in_list "$f" "${keep_files[@]}" && continue
    _in_list "$(dirname "$f")" "${keep_dirs[@]}" && continue
    doomed+=("$f")
  done < <(find "$MODELS_BASE" -mindepth 2 -type f -name '*.gguf' | sort)

  if [[ ${#doomed[@]} -eq 0 ]]; then
    info "Rien à nettoyer, $MODELS_BASE est aligné sur le script."
    return
  fi

  warn "À supprimer (${#doomed[@]} entrée(s)) :"
  for f in "${doomed[@]}"; do
    echo "  $(du -sh "$f" 2>/dev/null | cut -f1)  $f"
  done

  if [[ "$assume_yes" -eq 0 ]]; then
    info "Dry-run — relance avec './setup-llm.sh --cleanup --yes' pour supprimer."
    return
  fi

  for f in "${doomed[@]}"; do
    rm -rf -- "$f"
    info "Supprimé : $f"
  done

  # dossiers de quant vidés + métadonnées hf devenues orphelines
  find "$MODELS_BASE" -mindepth 2 -type d -empty -delete 2>/dev/null || true

  info "✅ Nettoyage terminé."

  _maybe_restart_service
}
