# lib/help.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → gufo → help

# =============================================================================
# help
# =============================================================================

cmd_help() {
  cat <<HELP
setup-llm.sh : llama-server en router mode natif (Strix Halo, image ROCm)

Usage : ./setup-llm.sh [commande] [options]

Commandes :
  --setup                  Installe les dépendances (curl, hf), vérifie docker
                           (démon actif ET activé au boot, utilisateur dans le
                           groupe docker) et l'image du moteur, télécharge les
                           GGUF manquants, sélection interactive du
                           préchargement, génère $CONFIG_DIR/models.ini
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
  --bench-parallel [modèle] [n] [passes]
                           Débit sous n requêtes simultanées (défaut : le parallel
                           du modèle) : agrégé et décode par requête, comparés à
                           1 requête. Montre ce que vaut parallel = N, et la file
                           d'attente au-delà. Journal logs/bench-parallel.log
  --bench-cache [modèle]   Efficacité du cache de prompt sur le pattern agentic :
                           contexte froid, tour suivant, édition au milieu,
                           requête identique — part servie du cache et prefill
                           à chaque fois. Journal logs/bench-cache.log
  --bench-agentic [modèle] [passes] [N]
                           Une vraie boucle de tool calls : pi (conteneur
                           jetable, bench-agentic/) joue un appel froid (prompt
                           système) puis N passes de 5 scénarios en direct sur
                           llama-server ; par scénario PASS/passes et médianes
                           (temps mur, prompt et part du cache, générés, prefill
                           et décode t/s réels). 3e argument N > 1 : chaque passe
                           joue la suite seule puis à N boucles pi SIMULTANÉES
                           (le cas orchestrateur + sous-agents), et donne le
                           facteur de débit de tâches (N x solo / parallèle) et
                           le décode agrégé ; dans le tableau de la salve, seuls
                           PASS et temps mur sont par scénario (colonnes
                           /metrics en n/c, recouvertes entre instances).
                           Journal logs/bench-agentic.log
  --bench-sanity [modèle|all]
                           Le modèle répond-il juste (question à réponse connue) ?
                           Complète le garde-fou anti-charabia de timings.py, qui
                           n'attrape que le charabia, pas un texte propre et faux.
                           Première étape, BLOQUANTE, de tools/qualif-modele.sh
  --bench-load [modèle|all]
                           Temps de chargement + 1er token après restart, puis TTFT
                           à chaud — ce que coûte un modèle à la demande (preload,
                           bascule LRU). Journal logs/bench-load.log
  --bench-prefill [modèle] [tailles] [passes]
                           Prefill à froid en profondeur, tel que servi : une
                           requête à contenu unique par taille (défaut
                           1000,4000,16000,32000,65000 tokens, 2 passes), cache
                           de prompt refusé, passes contaminées exclues. Là où
                           le --bench (1,4 k) ne départage ni deux moteurs ni
                           deux micro-lots. Journal logs/bench-prefill.log
  --image-build [--no-cache]
                           Image : construit le moteur CONTENEURISÉ (runtime/,
                           ROCm 10.0 gfx1151 + ROCr/HIP retained-PM4 +
                           halo-box/strix-llama.cpp en HIP seul) sur les
                           révisions épinglées dans les ARG de
                           runtime/Dockerfile.rocm-strix. Simple raccourci vers
                           « cd ~/models && docker compose build » : le compose
                           (runtime/docker-compose.yml) porte le contexte et le
                           Dockerfile, le .env de ~/models ses valeurs machine. L'image
                           qu'elle remplace perd son tag ; la retirer à la main
                           par « docker image prune » (SANS -a, qui toucherait
                           aux images des autres outils de la machine).
                           ⚠ C'est le MOTEUR DU SERVICE : une image neuve n'est
                           servie qu'au prochain --restart, et elle ouvre sa
                           propre série de mesures (étiquette
                           strix-<engine>+r<rocm>). Compter 40 à 60 minutes à
                           froid. Changer de révision : éditer l'ARG dans le
                           Dockerfile, commiter la raison, reconstruire
  --list-devices           Devices exposés par l'IMAGE du moteur
                           (llama-bench --list-devices dans le conteneur).
                           Alerte si ROCm0, le device de tout le ini, manque
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
                           Restarts par --restart
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
  --spec-ab <modèle> <n> <prompt|-> <variante>...
                           A/B de réglages spéculatifs sur mesure réelle : chaque
                           variante ("clé=val;clé=val" sur le corps ini, ou base)
                           est appliquée au ini, le service redémarré, --spec-test
                           mesuré ; bilan comparé, rien d'écrit. Ex. :
                           --spec-ab qwen3.8-27b-dflash-nothink 4 - base \
                             "spec-ngram-map-k-min-hits=1" "spec-type=ngram-map-k4v,draft-mtp"
  --start                  Démarre le service $SERVICE_NAME (défaut sans argument) :
                           .env du service régénéré dans $CONFIG_DIR, conteneur
                           recréé (docker compose up -d --force-recreate), puis
                           ATTENTE de /health - la commande ne rend la main que
                           quand le routeur répond sur :$SERVER_PORT
  --stop                   Arrête le conteneur (SIGINT, jusqu'à 180 s : le
                           déchargement des modèles préchargés prend du temps)
  --restart                --stop puis --start. Jamais « docker compose restart »,
                           qui garderait l'ancienne image, l'ancienne ligne de
                           commande et l'ancien --models-max
  --status                 État du conteneur (docker compose ps) et réponse de
                           /health
  --logs [-f] [--tail N]   Journaux du conteneur (docker compose logs)
  --gufo [modèle]          Met le moteur alternatif gufo à la place du service
                           sur :$SERVER_PORT (docs/GUFO.md), toujours derrière
                           llama-swap : le client choisit qwen3.8-27b,
                           qwen3.8-flash-next ou deepseek-v4-flash, bascule
                           automatique, un seul chargé à la fois. [modèle] =
                           préchargé : flashnext (défaut), 27b, deepseek.
                           Compose runtime-gufo/, .env généré dans GUFO_DATA
                           (défaut ~/llm/gufo-test), 2 sessions
                           (GUFO_SESSIONS). Le dernier lancé, gufo ou
                           service, repart seul au démarrage
  --gufo-off               Supprime gufo et relance le service ; --start et
                           --restart refusent tant que gufo tient le port
  --gufo-logs              Requêtes de gufo au fil de l'eau
  --gufo-download <quoi>   Image et GGUF de référence de gufo : image,
                           flashnext, deepseek ou all
  --migrate-off-systemd    TEMPORAIRE (migration) : arrête, désactive et supprime
                           l'ancienne unité systemd user $SERVICE_NAME, recharge
                           systemd et vérifie que le port $SERVER_PORT est
                           libre. Idempotente ; à lancer une fois avant
                           le premier --start, puis à oublier
  --help, -h               Cette aide

Fichiers (à côté du script, locaux, non versionnés) :
  preload.conf             modèles préchargés, un par ligne
  logs/spec-tests.log      journal des --spec-test (TSV), base de l'analyse n-max
  logs/bench.log           journal des --bench (TSV, avec le build llama.cpp),
                           comparé automatiquement au run précédent
  logs/bench-parallel.log  journal des --bench-parallel
  logs/bench-cache.log     journal des --bench-cache
  logs/bench-agentic.log   journal des --bench-agentic
  logs/bench-load.log      journal des --bench-load
  logs/bench-prefill.log   journal des --bench-prefill
  logs/spec-batch.log/.tsv journal des balayages tools/bench-spec-batch.sh
  spec-nmax.conf           modèle = spec-draft-n-max retenu par --spec-tune
  spec-ngram.conf          modèle = spec-ngram-map-k-size-m retenu par --spec-ngram-tune
Fichiers versionnés (runtime/, moteur conteneurisé) :
  runtime/Dockerfile.rocm-strix
                           copie vendorisée du Dockerfile amont (PR 133), qui
                           porte les DEUX RÉVISIONS ÉPINGLÉES du moteur et du
                           runtime ROCr (ARG ENGINE_REV, ARG ROCM_SYSTEMS_REV,
                           bloc « Révisions épinglées » en tête) ; son
                           historique git est le journal des révisions, et le
                           retour arrière passe par lui. Écarts avec l'amont et
                           resynchronisation : runtime/AMONT.md
Fichiers ($CONFIG_DIR, générés - ne pas éditer à la main) :
  models.ini               configuration des modèles, relancer --preload/--setup
  .env                     valeurs machine (gid, chemins, --models-max, tag de
                           l'image) de runtime/docker-compose.yml, qui décrit le
                           service ET la recette de son image (bloc build) ;
                           régénéré à chaque --start (lib/compose.sh) ; usage manuel :
                           cd $CONFIG_DIR && docker compose ps | logs -f
                           cd $CONFIG_DIR && docker compose build

Workflow typique :
  ./setup-llm.sh --setup && ./setup-llm.sh --image-build && ./setup-llm.sh --start
  ./setup-llm.sh --status ; ./setup-llm.sh --logs -f
  ./setup-llm.sh --bench all          # perfs de tous les modèles présents
  ./setup-llm.sh --update qwen3.8-27b # après un re-upload unsloth
  ./setup-llm.sh --image-build        # puis le moteur, après un bump de révision
                                      # dans runtime/Dockerfile.rocm-strix
                                      # (restart du service et --bench restent à la main)
  ./setup-llm.sh --spec-test          # décode réel d'un modèle MTP (choix interactif)
  ./setup-llm.sh --spec-tune          # règle spec-draft-n-max tout seul (2,4,6)
  ./setup-llm.sh --spec-ngram-tune    # règle la longueur de draft n-gram
  ./setup-llm.sh --spec-ab <m> 4 - base "clé=val"   # compare des réglages, sans rien écrire
  ./setup-llm.sh --bench-parallel <m> # ce que vaut parallel = N
  ./setup-llm.sh --bench-cache <m>    # part du prompt repayée à chaque tour (agentic)
  ./setup-llm.sh --bench-agentic <m> 3  # vraie boucle de tool calls (pi), PASS/FAIL et t/s réels
  ./setup-llm.sh --bench-agentic <m> 2 3  # les mêmes, à 3 boucles simultanées : débit de tâches
  ./setup-llm.sh --bench-load <m>     # coût d'une bascule LRU
  ./setup-llm.sh --bench-prefill <m>  # courbe de prefill à froid 1 k à 65 k (moteurs, micro-lots)
  ./setup-llm.sh --bench-prefill <m> 32000 3  # une seule taille, 3 passes
  ./setup-llm.sh --bench all          # après chaque bump de l'image : régressions

Modèles (models.ini, ${#PRESET_ORDER[@]}) :
$(printf '  %s\n' "${PRESET_ORDER[@]}")
Clés modèles (--update / --bench) :
$(for f in "${KNOWN_FILES[@]}"; do _key "$f"; done | sort -u | sed 's/^/  /')
HELP
}
