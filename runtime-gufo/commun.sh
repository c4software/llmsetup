# runtime-gufo/commun.sh : sourcé par les scripts de runtime-gufo/ (ne pas exécuter)
#
# gufo (https://github.com/gufo-org/gufo) est un moteur HIP spécialisé Strix
# Halo, évalué le 24/09/2026 contre le service (docs/GUFO.md). Il ne sert que
# trois modèles de texte, un par processus, et n'accepte que ses propres GGUF
# de référence. Il ne remplace pas le service : ces scripts le mettent à sa
# place sur :8009 le temps d'un essai, ou le mesurent.
#
# Chemins, tous surchargeables par l'environnement :
#   MODELS_BASE  GGUF du parc (défaut ~/models, comme lib/common.sh)
#   GUFO_DATA    données de gufo HORS du dépôt et hors de ~/models (sinon
#                --cleanup les verrait orphelines) : models/ (GGUF de
#                référence, telecharger.sh), cache/ (cache disque), resultats/
#                (bancs). Défaut ~/llm/gufo-test, là où l'évaluation a été faite.
#   GUFO_IMAGE   image du moteur (défaut ghcr.io/gufo-org/toolboxes/gufo-runtime:latest)

GUFO_DIR="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
DEPOT="$(dirname "$GUFO_DIR")"
M="${MODELS_BASE:-$HOME/models}"
GUFO_DATA="${GUFO_DATA:-$HOME/llm/gufo-test}"
DL="$GUFO_DATA/models"
CACHE="$GUFO_DATA/cache"
IMG="${GUFO_IMAGE:-ghcr.io/gufo-org/toolboxes/gufo-runtime:latest}"

# Échantillonnage officiel Qwen, profil instruct (celui des sections nothink du
# service) ; DeepSeek : celui de la section deepseek-v4-flash. Défauts serveur,
# un client peut les surcharger requête par requête. Les défauts de gufo sont
# glouton, 128 tokens générés, 4 096 de contexte : pensés pour ses mesures, pas
# pour un usage agentique.
ECHANTILLONNAGE_QWEN=(--temperature 0.7 --top-k 20 --top-p 0.8 --min-p 0.0
  --presence-penalty 1.5 --think off)
ECHANTILLONNAGE_DS=(--temperature 1.0 --top-k 40 --top-p 0.95 --min-p 0.0)

# Cache disque : seul chemin qui reprend le préfixe commun de deux
# conversations (même prompt système). Staging relevé à 8 Gio : au défaut de
# 512 Mio, un point de reprise du 27B (≈ 165 Mo + 0,08 Mo par token) est
# abandonné en silence dès ~4,5k tokens. Changer la configuration du serveur
# (--sessions…) rend le cache existant inutilisable : la fixer une fois.
CACHE_DISQUE=(--cache-disk "$CACHE" --cache-disk-bytes 17179869184
  --cache-disk-staging-bytes 8589934592)

# gufo_modele <cas> : remplit le tableau MODELE (fichiers, spéculatif, nom
# exposé, échantillonnage). Les fichiers du parc sont ceux de lib/models.sh
# (téléchargés par --setup) ; les autres viennent de telecharger.sh.
gufo_modele() {
  case "$1" in
    27b) MODELE=(--served-model-name qwen3.8-27b
           --model "$M/qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf"
           --speculative dflash2 --dflash-model "$M/qwen3.8-27b/Qwen3.8-27B-DFlash2-Q8_0.gguf"
           "${ECHANTILLONNAGE_QWEN[@]}") ;;
    # Drafter recommandé par gufo : mesuré identique au Q8_0 du parc.
    27b-q4km) MODELE=(--served-model-name qwen3.8-27b
           --model "$M/qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf"
           --speculative dflash2 --dflash-model "$DL/Qwen3.8-27B-DFlash2-Q4_K_M.gguf"
           "${ECHANTILLONNAGE_QWEN[@]}") ;;
    # Quant de base unsloth : gufo refuse le fine-tune Signal AP-Q4_K_XL du
    # parc (tenseur output_hc_down.weight en IQ4_NL).
    flashnext) MODELE=(--served-model-name qwen3.8-flash-next
           --model "$DL/qwen3.8-flash-next/UD-Q4_K_XL/Qwen3.8-Flash-Next-UD-Q4_K_XL-00001-of-00004.gguf"
           --speculative mtp --mtp-model "$M/qwen3.8-flash-next/MTP/mtp-Qwen3.8-Flash-Next-shared-Q8_0.gguf"
           --mmproj "$M/qwen3.8-flash-next/mmproj-BF16.gguf"
           "${ECHANTILLONNAGE_QWEN[@]}") ;;
    # Seule quant DeepSeek acceptée (l'UD-IQ3_XXS du parc est refusé) ; un
    # comptage raté à 26k tokens, justesse non établie.
    deepseek) MODELE=(--served-model-name deepseek-v4-flash
           --model "$DL/DeepSeek-V4-Flash-IQ2XXS-w2Q2K-AProjQ8-SExpQ8-OutQ8-chat-v2-imatrix-0731.gguf"
           --speculative dspark --dspark-model "$DL/DeepSeek-V4-Flash-DSpark-support-0731.gguf"
           "${ECHANTILLONNAGE_DS[@]}") ;;
    *) echo "modèle inconnu : $1 (27b, 27b-q4km, flashnext, deepseek)" >&2; return 2 ;;
  esac
}

# gufo_lance <conteneur> <port hôte> <politique de redémarrage> [args gufo...]
# Lance l'image en arrière-plan (GPU, groupes numériques de /dev/kfd et du
# nœud de rendu, parc en lecture seule) puis attend /health. En cas d'échec,
# affiche la fin du journal, supprime le conteneur et renvoie 1.
gufo_lance() {
  local nom="$1" port="$2" politique="$3"; shift 3
  mkdir -p "$CACHE" "$DL"
  docker rm -f "$nom" >/dev/null 2>&1 || true
  docker run -d --name "$nom" --restart "$politique" \
    --device /dev/kfd --device /dev/dri \
    --group-add "$(stat -c %g /dev/kfd)" --group-add "$(stat -c %g /dev/dri/renderD128)" \
    --ulimit memlock=-1 -p "0.0.0.0:$port:8080" \
    -v "$M:$M:ro" -v "$DL:$DL:ro" -v "$CACHE:$CACHE" \
    "$IMG" gufo serve llm --host 0.0.0.0 --port 8080 "$@" >/dev/null
  until curl -sf "localhost:$port/health" >/dev/null 2>&1; do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$nom" 2>/dev/null)" != true ]]; then
      docker logs --tail 30 "$nom" 2>&1 || true
      docker rm -f "$nom" >/dev/null 2>&1 || true
      return 1
    fi
    sleep 0.5
  done
  return 0
}
