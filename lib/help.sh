# lib/help.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

# =============================================================================
# help
# =============================================================================

cmd_help() {
  cat <<HELP
setup-llm.sh — llama-server en router mode natif (Strix Halo, Vulkan/ROCm)

Usage : ./setup-llm.sh [commande] [options]

Commandes :
  --setup                  Installe les dépendances (paru), propose le runtime ROCm
                           + ggml-hip, télécharge les GGUF manquants, sélection
                           interactive du préchargement, génère $CONFIG_DIR/models.ini
  --update [modèle]        Comme --setup mais laisse hf comparer les etags et ne
                           retélécharge que ce qui a bougé en amont
                           (modèle = dossier sous $MODELS_BASE, ex. qwen3.8-27b)
  --cleanup [--yes]        Supprime dossiers/GGUF orphelins (plus dans KNOWN_FILES).
                           Dry-run par défaut, --yes pour exécuter
  --preload                Re-sélectionne les modèles préchargés (always-on) et
                           régénère models.ini (--models-max = nb préchargés + 1)
  --bench [modèle|all] [n] Perfs du serveur tel qu'il tourne : n passes (défaut 3)
                           par modèle, long contexte réaliste (passe 1) +
                           décode et acceptance MTP médians, tableau récapitulatif.
                           Pas de restart, rien d'écrit. Sans argument : sélection
                           interactive
  --bench-devices [modèle] [devices] [n]
                           Comparaison automatique des devices pour un modèle :
                           pour chaque device (défaut Vulkan0,ROCm0), ini régénéré
                           + restart + bench (n passes, défaut 3), tableau comparatif.
                           Verdict = temps d'un tour d'usage simulé (2000 tokens de
                           prefill froid + 3000 générés, BENCH_PROFILE_PP/GEN pour
                           changer) ; vainqueur écrit dans bench-devices.conf,
                           ini régénéré, restart final. Restarts via systemctl --user
  --bench-parallel [modèle] [n] [passes]
                           Débit sous n requêtes simultanées (défaut : le parallel
                           du modèle) : agrégé et décode par requête, comparés à
                           1 requête. Montre ce que vaut parallel = N, et la file
                           d'attente au-delà. Journal logs/bench-parallel.log
  --bench-cache [modèle]   Efficacité du cache de prompt sur le pattern agentic :
                           contexte froid, tour suivant, édition au milieu,
                           requête identique — part servie du cache et prefill
                           à chaque fois. Journal logs/bench-cache.log
  --list-devices           Backends ggml installés + devices exposés par llama-bench,
                           croisés avec bench-devices.conf (alerte si device disparu)
  --spec-test [modèle] [n] [prompt]
                           Mesure le décode réel via l'API (spéculation incluse) :
                           n passes du même prompt code, prompt/gen t/s, acceptance
                           MTP + médianes (seed fixe/passe, 4 passes par défaut).
                           Journalise (quarantaine auto des runs incohérents),
                           et dès 2 n-max mesurés : prédit la courbe, choisit la
                           cible et l'écrit dans spec-nmax.conf (ini régénéré,
                           restart proposé).
  --spec-tune [modèle] [k1,k2,..] [n]
                           Boucle automatique : pour chaque n-max (défaut 2,4,6),
                           ini régénéré + restart + spec-test ; retient le meilleur
                           mesuré (à <2 %, le plus petit), l'écrit dans
                           spec-nmax.conf (surcharge du défaut script), restart final.
                           Restarts via systemctl --user
                           Sans modèle : choix interactif parmi les MTP présents.
                           4 passes par défaut. Sert à régler
                           spec-draft-n-max (éditer le script, --preload, re-tester)
  --spec-ngram-tune [modèle] [n] [prompt]
                           Règle spec-ngram-map-k-size-m (longueur de draft n-gram)
                           en deux temps : llama-bench trace t_forward(batch) sur le
                           device effectif du modèle et localise la marche de noyau
                           ggml (deux candidats — sous la marche, ou assez large pour
                           l'amortir), puis chaque candidat est mesuré pour de vrai
                           (ini régénéré + restart + spec-test) et le meilleur est
                           écrit dans spec-ngram.conf. À <2 %, le plus petit gagne.
                           Prompt par défaut : spec-refactor.txt (blocs à recopier
                           puis remplacer) — c'est là que les n-grams tapent.
  --start                  Lance llama-server sur :$SERVER_PORT (défaut sans argument)
  --install-service        Installe/active le service systemd USER $SERVICE_NAME
                           (systemctl --user) + linger (démarrage au boot)
  --uninstall-service      Arrête, désactive et supprime le service user
  --help, -h               Cette aide

Fichiers (à côté du script, locaux, non versionnés) :
  bench-devices.conf       clé (dossier GGUF) = device (Vulkan0/ROCm0), écrit par
                           --bench-devices, édition manuelle OK
  preload.conf             modèles préchargés, un par ligne
  logs/spec-tests.log      journal des --spec-test (TSV), base de l'analyse n-max
  logs/bench.log           journal des --bench (TSV, avec le build llama.cpp),
                           comparé automatiquement au run précédent
  logs/bench-parallel.log  journal des --bench-parallel
  logs/bench-cache.log     journal des --bench-cache
  logs/spec-batch.log/.tsv journal des balayages tools/bench-spec-batch.sh
  spec-nmax.conf           modèle = spec-draft-n-max retenu par --spec-tune
  spec-ngram.conf          modèle = spec-ngram-map-k-size-m retenu par --spec-ngram-tune
Fichiers ($CONFIG_DIR) :
  models.ini               généré — ne pas éditer à la main, relancer --preload/--setup

Workflow typique :
  ./setup-llm.sh --setup && ./setup-llm.sh --install-service
  systemctl --user start $SERVICE_NAME ; journalctl --user -u $SERVICE_NAME -f
  ./setup-llm.sh --bench all          # perfs de tous les modèles présents
  ./setup-llm.sh --update qwen3.8-27b # après un re-upload unsloth
  ./setup-llm.sh --spec-test          # décode réel d'un modèle MTP (choix interactif)
  ./setup-llm.sh --spec-tune          # règle spec-draft-n-max tout seul (2,4,6)
  ./setup-llm.sh --spec-ngram-tune    # règle la longueur de draft n-gram

Modèles (models.ini, ${#PRESET_ORDER[@]}) :
$(printf '  %s\n' "${PRESET_ORDER[@]}")
Clés modèles (--update / --bench) :
$(for f in "${KNOWN_FILES[@]}"; do _key "$f"; done | sort -u | sed 's/^/  /')
HELP
}
