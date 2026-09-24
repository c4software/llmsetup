#!/usr/bin/env bash
# Bascule :8009 entre le service llm-setup et gufo, pour un essai en réel.
#
# Usage :
#   runtime-gufo/serve-8009.sh gufo 27b          arrête le service, lance gufo avec le 27B (défaut)
#   runtime-gufo/serve-8009.sh gufo flashnext    arrête le service, lance gufo avec Flash-Next
#   SESSIONS=1 runtime-gufo/serve-8009.sh gufo … même chose avec un autre nombre de sessions
#   runtime-gufo/serve-8009.sh service           supprime gufo, relance le service llm-setup
#   runtime-gufo/serve-8009.sh logs              suit les requêtes de gufo (une ligne par requête)
#
# Prérequis : le service installé (./setup-llm.sh --setup, qui télécharge les
# GGUF du parc) et, pour Flash-Next, les GGUF de référence de gufo
# (runtime-gufo/telecharger.sh flashnext).
#
# Modèles (nom exposé sur :8009, via le proxy : bigchuck/<nom>) :
#   27b        qwen3.8-27b
#              cible  UD-Q4_K_XL du parc (~/models/qwen3.8-27b/)
#              draft  DFlash 2 Q8_0 du parc, adaptatif, 7 max
#              chargement ~10 à 30 s ; ~45 Gio en 1 session
#   flashnext  qwen3.8-flash-next
#              cible  unsloth UD-Q4_K_XL, 4 shards (GUFO_DATA/models/ ; gufo
#                     refuse le fine-tune Signal AP-Q4_K_XL du parc)
#              draft  MTP shared Q8_0 du parc, adaptatif, 7 max
#              vision mmproj BF16 du parc
#              chargement ~20 s (80 s à froid) ; 93 Gio de GPU en 1 session, 100 en 2
#
# Paramètres par défaut, communs aux deux (détail et origine : commun.sh et
# docs/GUFO.md, « Paramètres de serve-8009.sh et leur origine ») :
#   --context 262144, --sessions 2 (SESSIONS=N pour changer), --max-tokens 32768
#   --temperature 0.7 --top-k 20 --top-p 0.8 --min-p 0.0 --presence-penalty 1.5
#   --think off (pas de raisonnement)
#   --cache-disk GUFO_DATA/cache, 16 Gio, staging 8 Gio
#
# Pourquoi ces valeurs :
#   - 2 sessions : la seconde (7 Gio sur Flash-Next) évite qu'une requête annexe
#     du client (titre, résumé) évince la conversation principale de la RAM.
#   - cache disque : seul chemin qui reprend un préfixe commun entre conversations
#     (même prompt système), staging relevé pour le 27B.
#   - changer la configuration vide le cache disque : la fixer une fois pour toutes.
#
# Redémarrage automatique : c'est le DERNIER lancé qui repart au boot. gufo a
# --restart unless-stopped ; le service llm-setup a restart: unless-stopped dans
# runtime/docker-compose.yml. `gufo` arrête le service (arrêt volontaire, il ne
# repart plus) ; `service` supprime le conteneur gufo et relance le service. Ne
# pas lancer ./setup-llm.sh --start pendant que gufo tient :8009.
#
# DeepSeek n'est pas proposé ici : gufo n'accepte que l'IQ2XXS d'antirez, dont
# la justesse n'est pas établie (il reste mesurable par runtime-gufo/bench/).
set -euo pipefail
source "$(dirname "$(realpath "$0")")/commun.sh"
NOM=gufo-8009

case "${1:-}" in
  gufo)
    gufo_modele "${2:-27b}"
    "$DEPOT/setup-llm.sh" --stop
    if ! gufo_lance "$NOM" 8009 unless-stopped "${MODELE[@]}" \
         --context 262144 --sessions "${SESSIONS:-2}" --max-tokens 32768 \
         "${CACHE_DISQUE[@]}"; then
      echo "gufo n'a pas démarré, relance du service" >&2
      "$DEPOT/setup-llm.sh" --start
      exit 1
    fi
    echo "gufo prêt sur :8009"; curl -s localhost:8009/v1/models; echo ;;
  service)
    docker rm -f "$NOM" >/dev/null 2>&1 || true
    "$DEPOT/setup-llm.sh" --start ;;
  logs)
    docker logs -f "$NOM" 2>&1 | grep --line-buffered "event=completed" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
