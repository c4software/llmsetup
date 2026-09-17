# lib/help.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → fork → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help

# =============================================================================
# help
# =============================================================================

cmd_help() {
  cat <<HELP
setup-llm.sh : llama-server en router mode natif (Strix Halo, image ROCm)

Usage : ./setup-llm.sh [commande] [options]

Commandes :
  --setup                  Installe les dépendances (paru), propose le runtime ROCm
                           + ggml-hip, télécharge les GGUF manquants, sélection
                           interactive du préchargement, génère $CONFIG_DIR/models.ini
                           et, si le fork strix-llama.cpp n'est pas le moteur résolu,
                           propose de l'installer (défaut oui : les réglages du parc
                           en dépendent ; en entrée non interactive, rien n'est fait
                           et --setup-fork est rappelé)
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
  --setup-fork [commit] [raison]
                           Moteur : installe OU met à jour le fork
                           https://github.com/halo-box/strix-llama.cpp dans
                           ~/llm/strix-llama.cpp (clone, sinon git pull --ff-only),
                           construit (cmake Vulkan/Release/CURL : llama-server,
                           llama-bench, llama-cli, llama-quantize) et pose les liens
                           dans ~/.local/bin, que le service met en tête du PATH.
                           Affiche l'ancien et le nouveau commit puis la version
                           résolue ; ne redémarre pas le service. ⚠ Les mesures
                           faites sous le fork forment une série à part
                           (étiquette strix-<commit>), non comparable aux campagnes
                           du paquet Arch.
                           Avec un argument (commit, tag ou branche) : ÉPINGLE le
                           moteur dessus (fetch, checkout détaché sur un commit ou
                           un tag, suivi de branche sur une branche) et l'écrit
                           dans fork.conf, avec une raison facultative en 2e
                           argument (ou \$FORK_PIN_REASON). Tant que l'épinglage
                           tient, --update-fork ne tire plus rien. Sans argument :
                           l'épinglage est retiré et la branche reprise
  --update-fork            Moteur : suivi d'amont du fork, à lancer juste après
                           un --update. Ne fait QUE la mise à jour du fork déjà
                           installé : git fetch, changelog des commits reçus
                           (ancien → nouveau, titres des commits PROPRES au
                           fork, le reste compté comme « amont llama.cpp
                           intégré » avec ses bornes bNNNNN) puis CONFIRMATION
                           avant le git pull --ff-only, le rebuild des quatre
                           cibles et la repose des liens ; sans « o », rien n'est
                           tiré. Entrée non interactive : rien n'est fait, sauf
                           FORK_UPDATE_YES=1 qui vaut confirmation. S'arrête sans
                           rebuild si rien n'a bougé, et refuse si le fork n'est
                           pas le moteur en place (--setup-fork d'abord). Ne redémarre pas le service et
                           ne lance aucune mesure : enchaînement recommandé
                           --update → --update-fork → ./setup-llm.sh --restart
                           → --bench à la main. ⚠ Chaque bump du
                           fork ouvre une nouvelle série de mesures, étiquetée au
                           commit (strix-<commit>). Si fork.conf porte un
                           épinglage : rien n'est tiré ni demandé, la commande
                           annonce le commit épinglé et sa raison, montre quand
                           même le changelog en attente et rappelle --setup-fork
                           sans argument pour reprendre le suivi
  --unset-fork             Retire les quatre liens de ~/.local/bin : retour au
                           paquet Arch pour les outils HORS service (llama-bench
                           de --spec-ngram-tune, tools/bench-depth.sh). Sans
                           effet sur le service, qui tourne sur l'image
  --image-build [--no-cache]
                           Image : construit le moteur CONTENEURISÉ (runtime/,
                           ROCm 10.0 gfx1151 + ROCr/HIP retained-PM4 +
                           halo-box/strix-llama.cpp en HIP seul) sur les
                           révisions de runtime/image.conf, sous un tag
                           temporaire ; vérifie que /opt/strix/versions.txt et
                           les quatre binaires correspondent à ce qui a été
                           demandé, puis seulement promeut en
                           llm-rocm-strix:latest et supprime les images sans tag
                           issues de nos builds (label llm-setup.engine_rev).
                           Un build raté laisse l'image en place intacte.
                           Journalise dans logs/images.tsv. ⚠ C'est le MOTEUR DU
                           SERVICE : une image neuve n'est servie qu'au prochain
                           --restart, et elle ouvre sa propre série de mesures
                           (étiquette strix-<engine>+r<rocm>). Compter 40 à 60
                           minutes à froid
  --image-update [engine-rev] [rocm-rev]
                           Image : suivi d'amont. Sans argument, compare les
                           révisions de runtime/image.conf aux sommets des deux
                           branches, affiche l'écart et S'ARRÊTE — rien n'est
                           modifié sans confirmation (entrée non interactive :
                           rien ; IMAGE_UPDATE_YES=1 vaut accord, comme
                           FORK_UPDATE_YES). Avec accord ou avec des révisions
                           données : réécrit image.conf puis enchaîne
                           --image-build. C'est aussi le RETOUR ARRIÈRE du
                           moteur conteneurisé (y remettre les anciennes
                           révisions ; il n'y a pas de rollback par tag)
  --image-status           Image : révisions demandées (runtime/image.conf),
                           image llm-rocm-strix:latest en place avec ses
                           étiquettes (moteur, rocm-systems, date), verdict de
                           conformité entre les deux, taille, images sans tag
                           restantes et place du cache de build. Ne construit ni
                           ne purge rien
  --list-devices           Moteur de l'HÔTE (paquet Arch ou fork) + backends ggml
                           installés, puis les devices exposés par l'IMAGE du
                           service (llama-bench --list-devices dans le conteneur).
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
                           docker-compose.yml régénéré dans $CONFIG_DIR, conteneur
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
  --migrate-off-systemd    TEMPORAIRE (migration) : arrête, désactive et supprime
                           l'ancienne unité systemd user $SERVICE_NAME, recharge
                           systemd, vérifie que le port $SERVER_PORT est libre et
                           signale les liens ~/.local/bin/llama-* restants (sans
                           les supprimer). Idempotente ; à lancer une fois avant
                           le premier --start, puis à oublier
  --help, -h               Cette aide

Fichiers (à côté du script, locaux, non versionnés) :
  preload.conf             modèles préchargés, un par ligne
  fork.conf                épinglage du moteur (pin = commit, raison = texte),
                           écrit par --setup-fork <commit>
  logs/spec-tests.log      journal des --spec-test (TSV), base de l'analyse n-max
  logs/bench.log           journal des --bench (TSV, avec le build llama.cpp),
                           comparé automatiquement au run précédent
  logs/bench-parallel.log  journal des --bench-parallel
  logs/bench-cache.log     journal des --bench-cache
  logs/bench-agentic.log   journal des --bench-agentic
  logs/bench-load.log      journal des --bench-load
  logs/spec-batch.log/.tsv journal des balayages tools/bench-spec-batch.sh
  logs/images.tsv          journal des --image-build (date, tag, révisions, taille)
  spec-nmax.conf           modèle = spec-draft-n-max retenu par --spec-tune
  spec-ngram.conf          modèle = spec-ngram-map-k-size-m retenu par --spec-ngram-tune
Fichiers versionnés (runtime/, moteur conteneurisé) :
  runtime/image.conf       dépôts, branches et RÉVISIONS épinglées de l'image,
                           plus son nom ; son historique git est le journal des
                           révisions (le retour arrière passe par lui)
  runtime/Dockerfile.rocm-strix
                           copie vendorisée du Dockerfile amont (PR 133) ;
                           écarts et resynchronisation dans runtime/AMONT.md
Fichiers ($CONFIG_DIR, générés - ne pas éditer à la main) :
  models.ini               configuration des modèles, relancer --preload/--setup
  docker-compose.yml       description du service, régénérée à chaque --start
                           (lib/compose.sh) ; usage manuel :
                           cd $CONFIG_DIR && docker compose ps | logs -f

Workflow typique :
  ./setup-llm.sh --setup && ./setup-llm.sh --image-build && ./setup-llm.sh --start
  ./setup-llm.sh --status ; ./setup-llm.sh --logs -f
  ./setup-llm.sh --bench all          # perfs de tous les modèles présents
  ./setup-llm.sh --update qwen3.8-27b # après un re-upload unsloth
  ./setup-llm.sh --update-fork        # puis le moteur : fork à jour, rebuild, liens
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
  ./setup-llm.sh --bench all          # après chaque mise à jour de llama-cpp : régressions

Modèles (models.ini, ${#PRESET_ORDER[@]}) :
$(printf '  %s\n' "${PRESET_ORDER[@]}")
Clés modèles (--update / --bench) :
$(for f in "${KNOWN_FILES[@]}"; do _key "$f"; done | sort -u | sed 's/^/  /')
HELP
}
