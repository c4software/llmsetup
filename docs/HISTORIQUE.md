# Historique et campagnes de mesure détaillées

Archive des campagnes de mesure et des essais du dépôt, sortie du README le
13/09/2026 pour n'y garder que l'état courant : chiffres, protocoles et récits
datés, repris des sections correspondantes du README. L'état courant du parc
(réglages retenus et perfs) reste dans le README du runtime
(`runtime/llama-cpp-rocm-strix/README.md`, le `README.md` du dépôt jusqu'au
09/10/2026), section « Parc au
22/09/2026, moteur conteneurisé ROCm0 » (le texte d'origine disait « perfs sur
le fork » et citait « Parc au 17/09/2026 », titre que le README ne porte
plus).

Trois séries de mesures cohabitent ici et ne se comparent jamais entre elles :
le paquet Arch (`bNNNNN`), le fork strix-llama.cpp (`strix-<commit>`) et, depuis
le 18/09/2026, l'image ROCm du service (`strix-<engine>+r<rocm>`). La colonne
build des journaux `logs/` fait foi.

Machine des mesures : bigchuck, AMD Ryzen AI MAX+ 395 (Radeon 8060S,
124 Go de mémoire unifiée), CachyOS.

Ordre du document : les entrées datées, de la plus récente à la plus ancienne
(image ROCm du 17 au 22/09/2026, puis fork du 12 au 17/09/2026) ; les tables de
campagne du paquet Arch et du fork (« Résultats mesurés », « Récapitulatif par
modèle », « Paquet Arch contre fork : mesures ») ; les mesures par thème
(spéculation, courbes de batch, profondeur, concurrence, boucle agentic, cache
de prompt, chargement) ; enfin la méthode de `--spec-ngram-tune` et le renvoi
vers celle de `--bench-devices`, archivée.

Ce fichier est le journal du service llama.cpp seul. Deux contenus vivent
ailleurs :

- gufo, moteur évalué à partir du 24/09/2026 : journal dans
  [`docs/HISTORIQUE-GUFO.md`](HISTORIQUE-GUFO.md) (l'évaluation du 24/09 y
  est sous « Évaluation face au service (24/09/2026) »), état courant dans
  [`docs/GUFO.md`](GUFO.md). La section « gufo face au service (24/09/2026) »
  qui ouvrait ce document y est partie ;
- les blocs des cinq sections retirées du parc (commentaire métier et corps
  ini d'origine, à recopier dans `lib/models.sh` pour ravoir une section), et
  le détail des méthodes et procédures qui n'existent plus (`--bench-devices`,
  variantes `-parallel`, procédures du fork, essai batch 16384 du 17/09) :
  [`docs/SECTIONS-RETIREES.md`](SECTIONS-RETIREES.md). Chaque passage concerné
  garde ici la décision, le motif et les chiffres clés, et y renvoie.

## Découpage en runtimes (09/10/2026)

Décision de l'utilisateur du 09/10/2026 : le dépôt devient modulaire. Un
dossier `runtime/<nom>/` par moteur, autonome, un contrat écrit
(`runtime/CONTRAT.md`), un lancement toujours cloisonné par docker compose, un
runtime actif mémorisé (`runtime.conf`, bascule par `--runtime <nom>`). Le
service de ce journal est désormais le runtime **`llama-cpp-rocm-strix`**, le
défaut du dépôt ; gufo est le runtime `gufo` (`docs/HISTORIQUE-GUFO.md`).
Aucune mesure rejouée, aucun modèle ni réglage touché : `models.ini` généré
identique à l'octet avant et après (274 lignes, comparé sur le même `HOME`).

**Les entrées de ce journal citent les chemins de leur époque et ne sont pas
réécrites.** Correspondance :

| Avant | Depuis le 09/10/2026 |
|---|---|
| `runtime/` (Dockerfile, compose, patchs, `AMONT.md`) | `runtime/llama-cpp-rocm-strix/` |
| `lib/models.sh`, `ini.sh`, `compose.sh`, `preload.sh`, `setup.sh`, `spec.sh`, `service.sh`, `lib/bench/` | `runtime/llama-cpp-rocm-strix/lib/…` |
| `lib/runtime.sh` (image, `_dk_run`) | `runtime/llama-cpp-rocm-strix/lib/image.sh` |
| `lib/common.sh` (téléchargements, journaux, `_llama_build`, mode EC, garde mémoire) | `runtime/llama-cpp-rocm-strix/lib/common.sh` ; `info`/`warn`/`error`, `MODELS_BASE`, `SERVER_PORT`, `_compose_gid` restent dans `lib/common.sh` |
| `lib/help.sh` | `runtime/llama-cpp-rocm-strix/lib/aide.sh` (aide du runtime), `lib/help.sh` (commandes communes) |
| `py/`, `tests/py-golden.sh`, `tests/py-unit.py`, `tests/fixtures/` | `runtime/llama-cpp-rocm-strix/py/`, `…/tests/` |
| `tools/qualif-modele.sh`, `spec-isolate.sh`, `bench-depth.sh`, `bench-spec-batch.sh` | `runtime/llama-cpp-rocm-strix/tools/` |
| `README.md`, `ARCHITECTURE.md` (ce moteur) | `runtime/llama-cpp-rocm-strix/README.md`, `ARCHITECTURE.md` |
| `lib/svc.sh` (pilotage du routeur) | `lib/svc.sh`, générique : pilote le runtime actif |

Restent à la racine : `prompts/`, `bench-agentic/`, `docs/`, `logs/` et les
`.conf` (choix utilisateur, pas déplacés).

Ce qui change pour ce moteur au-delà des chemins :

- **Commandes** : aucune ne change de nom. `--start`, `--stop`, `--restart`,
  `--status`, `--logs` et `--setup` sont communes et visent le runtime actif ;
  toutes les autres (`--bench*`, `--spec-*`, `--preload`, `--update`,
  `--cleanup`, `--image-build`, `--list-devices`, `--migrate-off-systemd`)
  sont des sous-commandes de ce runtime, refusées quand un autre est l'actif
  (`LLM_RUNTIME=llama-cpp-rocm-strix ./setup-llm.sh …` les lance quand même).
  Sans `runtime.conf`, ce runtime est l'actif : une machine déjà installée se
  comporte comme avant.
- **`.env`** : deux valeurs changent, les chemins du dépôt (`COMPOSE_FILE`,
  `RUNTIME_DIR`). Il est donc réécrit au premier `--start`. Le reste est
  identique, et le compose n'a pas bougé.
- **Exclusivité** : `--start` ne refuse plus quand gufo tient le port, il
  l'arrête (pilotage générique). `--status` dit quel runtime tient le port.
- **`--start` affiche** le préchargement après la ligne de démarrage, sous une
  forme un peu différente ; les tuners, qui redémarrent le service, l'affichent
  aussi.
- **`--cleanup`** n'a plus le nom `gufo` écrit en dur : il épargne les dossiers
  du parc qu'un autre runtime déclare réservés (`RT_PARC_RESERVE`).
- **Outils** : `qualif-modele.sh` lance ses étapes avec
  `LLM_RUNTIME=llama-cpp-rocm-strix`, pour ne pas dépendre du runtime actif.
- **Tests** : ceux du pilotage (jamais `compose restart`, attente, `.env` non
  réécrit) et des règles communes du compose sont passés dans le test du
  contrat, `tests/sh-unit.sh` à la racine ; ce runtime garde les siens
  (`runtime/llama-cpp-rocm-strix/tests/`).

Non vérifié sur machine : écrit sans GPU ni docker. `./tests/sh-unit.sh`
(faux docker, 127 contrôles, deux rendus `docker compose config` sautés),
`py-golden.sh` et `py-unit.py` passent ; ni `--start`, ni `--image-build`, ni
un banc, ni un outil hors service n'ont tourné sur la nouvelle arborescence.

## Flash-Next face à halogen-flash-server, micro-lot et n-gram (22/09/2026)

Résultat : rien de retenu côté réglage. ub 4096 garde son arbitrage du 18/09
(cache de prompt restauré à 79 % en boucle agentic), ngram-mod garde ses +10 %
de décode en génération longue. Halogen ne garde qu'un avantage de prefill à
froid en profondeur, au prix d'un moteur mono-modèle sans vision ni sampling
par défaut. Deux suites dans le parc (dernier paragraphe).

Conditions : bigchuck, image `strix-8c1c282+r7dda3ac`, ROCm0, Flash-Next servi
par Signal-3.8-Flash-Next AP-Q4_K_XL, tête MTP shared, reasoning off. En face,
halogen-flash-server 0.11.4 (moteur spécialisé, mono-modèle, checkpoint hgn w4b
5,53 bpw du Qwen de base, greedy par défaut, `HALOGEN_ENABLE_THINKING=0`),
lancé sur `:8029` d'après son `run-test.sh`, jamais en même temps que le
service. Poids différents des deux côtés : le mode GGUF de halogen refuse les
Q4_K, l'UD-IQ4_XS n'était plus sur le disque.

**Boucle agentic pi** (`--bench-agentic`, 3 passes, même conteneur pi pointé sur
chaque serveur), 16/16 PASS des deux côtés :

| Mesure | llmsetup | halogen |
|---|---|---|
| temps mur des cinq scénarios | 35,5 s | 33,5 s |
| décode médian | 48,5 t/s (sampling 0,7) | 54,0 t/s (greedy), soit +11 % |
| prefill sans cache sur l'appel froid | 557 t/s | 613 t/s |

Le `/metrics` de halogen n'a pas de compteur de tokens en cache et ignore
`?model=` : ses colonnes prompt, cache et prefill du bench sont fausses par
construction, seuls PASS, temps mur, généré et décode se comparent.

**Boucle agentic omp** (oh-my-pi 18.2.6 local, profil isolé, thinking off,
TODO list Laravel du TP « base de données » sur un projet fraîchement créé, un
run par configuration, 7/7 critères fonctionnels partout) :

| configuration | mur | tours / outils | généré | décode | prompt frais | prefill frais |
|---|---|---|---|---|---|---|
| llmsetup ngram-mod, run 1 | 170 s | 22 / 34 | 5 108 | 45,3 t/s | 20,6 k | ~650 t/s (estimé) |
| llmsetup ngram-mod, run 2 | 169 s | 21 / 34 | 5 505 | 45,3 t/s | 20,9 k | 691 t/s |
| llmsetup ngram-map-k 7, min-hits 2 | 119 s | 14 / 26 | 3 949 | 45,8 t/s | 19,6 k | 743 t/s |
| halogen 0.11.4 | 184 s | 19 / 33 | 5 505 | 46,3 t/s | 47,6 k | 789 t/s |

Décode identique partout. Le temps mur court de la variante n-gram vient du
modèle qui a bouclé moins (une seule vérification navigateur), pas du drafter :
variance de sampling. Halogen a reprefillé 2,3 fois plus de tokens frais sur
la même conversation (reprise de cache aux frontières de 64 tokens, omp
réécrit le contexte à chaque tour), d'où ses 14 s de plus. Le seul écart réel
entre les moteurs : le prompt système omp de 17,9 k tokens à froid, 942 t/s
sur llmsetup (ub 4096) contre 1 165 t/s sur halogen.

**Prefill à froid en profondeur, après-midi** (requêtes directes, contenu
unique, `cache_prompt` false, deux requêtes par taille, `timings` de
llama-server ; mode EC `performance` pas forcément actif) :

| tokens | ub 4096 (retenu) | ub 16384 | b/ub 24576 (réglage d'ilintar) |
|---|---|---|---|
| 1,4 k | 701 / 815 | 665 / 880 | 619 / 809 |
| 5 à 7 k | 935 / 967 | 1 036 / 1 082 | 1 044 / 1 026 |
| 21 à 25 k | 966 / 981 | 1 096 / 1 112 | 1 123 / 1 104 |
| 40 à 49 k | 964 / 965 | 1 091 / 1 093 | 1 082 / 1 060 |
| 85 à 90 k | 924 / 925 | 1 035 / 1 034 | 785, puis instance sortie (statut 1) |

Le n-gram (ngram-mod contre ngram-map-k) ne change pas le prefill, à moins de
1 % près. Le micro-lot, si : +12 % dès 5 k tokens en ub 16384, pour 9 Go
disponibles pendant le run au lieu de 18. 24576 n'apporte rien de plus que
16384 et fait sortir le modèle à 90 k tokens (4 Go disponibles, cache de
prompt vidé entrée par entrée avant la chute). Le GGUF IQ4_NL d'ilintar
(`ilintar/qwen3.8-flash-next-gguf-strix-halo`, 93 Go, branche strix-halo)
annonce 1 152 t/s à vide et 1 060 à 40 k en `-b 24576 -ub 24576` : le niveau
de l'ub 16384 ici, la quant n'est pas ce qui manque. Lecture de l'après-midi :
halogen conserve 5 à 8 % de prefill à froid une fois llmsetup en ub 16384.

**Courbes rejouées le soir en mode EC `performance` vérifié** (l'après-midi
n'y était pas forcément), mêmes requêtes directes, médiane de deux requêtes
par taille, halogen relancé avec les mêmes options puis retiré. Ce sont les
dernières en date :

| tokens | llmsetup base (ub 4096) | llmsetup large-ub (ub 16384) | halogen 0.11.4 |
|---|---|---|---|
| 1,2 à 1,7 k | 628 / 790 | 629 / 894 | 607 / 693 |
| 4 à 6 k | 830 | 1 040 | 985 |
| 20 à 26 k | 920 | 1 100 | 1 230 |
| 32 à 39 k | 968 | 1 099 | 1 275 |
| 41 à 50 k | 961 | 1 099 | 1 325 |
| 84 à 90 k | 917 | 1 055 | 1 310 |

Sous 5 k tokens les trois sont au même niveau ; à partir de 20 k halogen
prend 12 % sur large-ub, 21 à 24 % de 40 à 90 k (35 % sur la base). C'est
l'écart réel des deux moteurs sur le prefill à froid, en `performance` ; les
+24 % de l'après-midi sur 18 k étaient une mesure hors mode. Décode et temps
mur des boucles agentic inchangés.

**Prefill 32 k du parc** (`--bench-prefill 4000,32000 2`, nouvelle commande du
soir, `performance`, ubatch par défaut sauf Flash-Next), médiane de deux
passes saines, à froid, en t/s :

| section | 4 k | 32 k |
|---|---|---|
| ornith-1.5-9b-mtp-nothink | 1 419 | 1 143 |
| ornith-1.5-35b-a3b-mtp | 1 261 | 965 |
| lfm2.5-2.6b | 4 191 | 3 120 |
| qwen3-coder-next | 918 | 740 |
| qwen3.8-27b-dflash-nothink | 249 | 224 |
| muse-glimmer-30b-dflash | 326 | 260 |
| qwen3.8-flash-next-mtp-nothink (ub 4096) | 938 | 975 |
| qwen3.8-flash-next-mtp-nothink-large-ub (ub 16384) | 1 040 | 1 099 |
| deepseek-v4-flash | 111 | 89 |

Toutes les courbes descendent avec la profondeur, de 8 % (27B) à 25 %
(Ornith 35B), sauf Flash-Next, plate ou montante. DeepSeek V4 Flash, joué en
dernier (6 min par passe à 32 k), descend aussi, de 20 %, alors que son
attention est sparse elle aussi (DSA, Lightning Indexer, présent dans le
graphe du moteur, cf. son bloc, et déjà 173 / 161 / 136 / 111 t/s de 2 k à
51 k le 18/09) : la courbe plate n'est donc pas « l'attention sparse » en
général mais le QSA de Flash-Next tel que ce moteur l'exécute (troisième
cache d'index, budget 2048). La première série avait exclu LFM2.5 et Muse à
tort : modèles à réflexion, leurs 8 tokens partent dans `reasoning_content` et
le garde-fou ne regardait que `content` ; corrigé, rejoués.

**Suites dans le parc (22/09/2026, décision utilisateur).**

- La section `ornith-1.5-35b-a3b-parallel` est retirée : usage
  mono-utilisateur, plus aucun multi-slot dans le parc. Son grand commentaire
  reste dans `lib/models.sh` au-dessus de `ornith-1.5-35b-a3b-mtp`, seule
  section Ornith 35B désormais, et son corps est consigné dans la note de
  retrait.
- La variante `qwen3.8-flash-next-mtp-nothink-large-ub` est créée : même
  section que la base avec `ubatch-size` 16384, réservée aux gros prefills à
  froid, la base gardant 4096 pour les boucles d'outils. Qualifiée le soir
  même par `tools/qualif-modele.sh` : justesse OK ; `--bench`
  540 / 45,6 / 0,455 (prompt court, un seul micro-lot) ; `--bench-cache` 0 % partout (même
  limite que la base, prompt de 1,4 k) ; `--bench-agentic` 3 passes 15/15,
  décode 47 à 50 t/s, temps mur et part de cache identiques à la base (les
  scénarios restent sous 7 k tokens, le grand micro-lot ne coûte qu'au-delà de
  ~16 k par tour).

## Le conteneur du service en uid:gid de l'utilisateur (22/09/2026)

Trois décisions : le conteneur ne tourne plus en root, la clé `prio` est
retirée du ini, et le prefill de référence de Flash-Next sur prompt court est
corrigé de 835 à 627 à 669 t/s.

**uid:gid.** Jusqu'ici `llama-server` tournait en root dans le conteneur
(uid 0, avec les groupes `video` et `render` en supplément), faute de directive
`user:` dans `runtime/docker-compose.yml`. Rien ne le demandait : les devices
passent par `group_add` (`/dev/kfd` et `renderD128` en rw pour `render`,
`card0` pour `video`), `~/models` est monté en lecture seule et le seul point
inscriptible (`CACHE_DIR`) appartient déjà à l'utilisateur. Le compose pose
maintenant `user: ${SVC_UID:?}:${SVC_GID:?}`, résolus par `regen_env` (`id -u`,
`id -g`). A/B dos à dos sur bigchuck,
`--bench qwen3.8-flash-next-mtp-nothink 3` : root 664 t/s / 46,2 t/s / 0,455, uid 1000 669 / 46,1 / 0,455 ; justesse OK
en 1000, aucun fichier créé hors 1000.

**`prio` retirée.** L'avertissement `failed to set process priority 2 :
Permission denied` (le `prio = 2` de l'en-tête du ini) est présent dans les
deux cas : hausser la priorité demande `CAP_SYS_NICE`, que `cap_drop ALL`
retire, root ou pas ; sans effet mesuré. A/B du soir même avec
`cap_add: SYS_NICE` (édition locale, non commitée) : en uid 1000 la capacité ne devient
pas effective (`CapEff` = 0, un non-root ne reçoit pas les capacités ajoutées,
`no-new-privileges` ferme l'autre voie), nice du processus à 0, avertissement
présent, `--bench` 663 / 46,1 contre 664 / 45,8 sans, `--bench-agentic` 15/15
et temps mur identiques des deux côtés. La clé `prio` est donc RETIRÉE de
l'en-tête `[*]` de `lib/ini.sh` (ini généré : une ligne de moins, un
commentaire de plus).

**Les 835 t/s du 18/09 élucidés.** Ce prefill ne se retrouve ni en root ni en
1000 le 22/09 : huit `--bench` propres (après restart, base comme variante
large-ub, puis un dernier après redémarrage complet de la machine,
`performance` vérifié) donnent 627 à 669 t/s, décode 45,3 à 47,0 partout.
ÉLUCIDÉ par le journal : le 18/09 une série de `--bench-cache` sur cette
section a tourné de 06:42 à 07:06, et le `--bench` à 835 est parti 78 s après
le dernier ; `--bench-cache` lit `bench-context.txt`, le prompt même du
`--bench`, donc ce prefill a été servi en partie par le cache du serveur sans
que le marqueur « * » se déclenche (seuil de 10 % de `cache_n` en passe 1). Le
run précédent du même matin, à 01:41, donnait 604. Valeur retenue pour la
table du parc : 627 à 669 t/s sur ce prompt court, la courbe longue (965 à
980 t/s à froid de 5 à 42 k tokens) restant la mesure de référence du prefill.

## `--models-max` sans plancher (21/09/2026)

Décision : le plancher `models_max >= 2` hérité du premier script est retiré.
`--models-max` vaut préchargés + 1, sans minimum ; `preload.conf` vide ⇒
`--models-max 1`, un seul résident, le routeur décharge toujours avant de
charger.

Incident à l'origine : Flash-Next injoignable sur bigchuck, plus de cinquante
`cudaMalloc failed: out of memory` à l'allocation de son buffer de poids
(68,5 Go) pendant qu'Ornith 35B MTP, contexte 1 M, tenait 74 Go (48,7 Go de
GTT plus 25 Go anonymes). Le routeur avait évincé lfm2.5, l'inactif le plus
ancien, puis, revenu à un seul résident sous `--models-max 2`, ne déchargeait
plus rien : même mécanique que les deux OOM du 13/09, mais l'allocation ROCm
échoue proprement au lieu de réveiller l'OOM killer, donc le service reste
debout et le modèle demandé échoue en boucle. Le plancher rendait
`preload.conf` vide inopérant. Débloquage à chaud par `POST /models/unload` du
résident.

## Compose versionné, `.env` généré (19/09/2026)

Le `docker-compose.yml` n'est plus généré par un heredoc de `lib/compose.sh` :
il vit dans `runtime/docker-compose.yml`, versionné, lisible et validable par
`docker compose config` sans passer par le script. Tout ce qui dépend de la
machine y est une variable obligatoire (`${VAR:?}`), et `lib/compose.sh`
n'écrit plus que `~/models/.env` : gid numériques de `render` et `video`,
chemins absolus (`~/models`, `runtime/`, cache), `--models-max` dérivé de
`preload.conf`, tag de l'image, port, et `COMPOSE_FILE`, qui permet toujours
`cd ~/models && docker compose ps` sans `-f`. `_svc_compose` passe
`--project-directory ~/models` pour que docker lise ce `.env`. Le refus de
générer sans image, la réécriture seulement si le contenu change et la
régénération à chaque `--start` sont inchangés, reportés sur le `.env`.
`tests/sh-unit.sh` valide désormais le rendu réel (`docker compose config`
sur le `.env` produit avec un faux `getent`) au lieu de grep sur un YAML
généré. Le motif « pas de `${VAR}`, pas de `.env` » du 18/09 est abandonné :
il enfermait le YAML dans un script pour un gain de lisibilité à la main que
`COMPOSE_FILE` dans le `.env` rend sans objet.

## Un Dockerfile et un compose (18/09/2026)

La couche d'abstraction montée la veille autour de l'image est retirée :
`runtime/image.conf`, les trois `LABEL llm-setup.*`, le build sous tag
temporaire avec promotion après vérification de `versions.txt`, la purge des
images sans tag par label, le journal `logs/images.tsv`, et les commandes
`--image-update` et `--image-status`. Il reste ce que la chose est vraiment :
**un Dockerfile et un compose**. Motif : pour deux fichiers, l'outillage
coûtait plus cher à lire et à maintenir que ce qu'il protégeait.

- **Révisions.** Les deux révisions épinglées vivent désormais dans
  `runtime/Dockerfile.rocm-strix`, en valeurs par défaut de `ARG ENGINE_REV` et
  `ARG ROCM_SYSTEMS_REV`, avec en tête un bloc « Révisions épinglées » qui
  donne la source de chacune, sa date d'épinglage et la marche à suivre pour
  la faire bouger (`git ls-remote`, éditer l'`ARG`, commiter la raison,
  `docker compose build`, `--restart`, nouvelle campagne). L'historique git de
  ce fichier reste le journal des révisions, et le retour arrière consiste à y
  remettre les anciennes valeurs. La procédure par `image.conf` et
  `--image-update`, écrite avec « Le fork Vulkan n'est plus un moteur du dépôt
  (18/09/2026) » et archivée depuis (`docs/SECTIONS-RETIREES.md`, « Procédures du
  fork »), ne vaut donc plus que pour les commits antérieurs au 18/09/2026.
- **Build.** Le `docker-compose.yml` généré (versionné depuis le 19/09, cf.
  « Compose versionné, `.env` généré (19/09/2026) ») porte un bloc `build` (contexte `runtime/` du dépôt,
  `dockerfile: Dockerfile.rocm-strix`), et `--image-build` n'est plus qu'un
  raccourci vers `docker compose build`. `docker compose up -d` ne construit
  pas quand l'image existe, et `lib/compose.sh` refuse de toute façon de
  générer le compose sans image, en renvoyant sur la commande de build : un
  `--start` ne peut pas partir en compilation de quarante minutes par
  surprise. L'étiquette des mesures (`_llama_build`) se lit maintenant par un
  `grep` sur les deux `ARG` du Dockerfile, sans lancer de conteneur.
- **Ce qui est perdu, assumé.** L'ancienne `:latest` n'est plus supprimée
  toute seule après un build (elle perd son tag, `docker image prune` sans
  `-a` la retire, à la main), et rien ne revérifie après coup que
  `/opt/strix/versions.txt` correspond aux révisions demandées : ce que
  l'image contient se lit dedans, quand on veut le savoir. Aucune image amont
  n'est publiée pour ce Dockerfile (cf. « Campagne du moteur conteneurisé »),
  le build local reste donc le seul chemin.

## Le fork Vulkan n'est plus un moteur du dépôt (18/09/2026)

`lib/fork.sh` et tout son mécanisme sont retirés : les commandes
`--setup-fork`, `--update-fork` et `--unset-fork`, l'épinglage `fork.conf`, le
garde-fou moteur/ini (`FORK_ONLY_KEYS` / `_fork_keys_guard`), la proposition
d'installation en fin de `--setup`, la résolution d'un binaire llama-* sur
l'hôte (`_llama_bin`, `_host_llama_build`, le `~/.local/bin` mis en tête du
PATH) et les tests unitaires correspondants.

Raison : depuis la bascule du service en conteneur (17 au 18/09/2026) le fork
ne servait plus aucun modèle. Il ne restait que le moteur des outils hors
service, ce qui faisait coexister DEUX moteurs, donc deux séries de mesures et
deux jeux de réglages, pour un rôle que l'image tient aussi bien. Les outils
passent donc dans l'image, par `_dk_run` :

| Outil | Avant | Après |
|---|---|---|
| `--spec-ngram-tune` (courbe `t_forward(batch)`) | `llama-bench` de l'hôte | `_dk_run llama-bench` |
| `tools/bench-spec-batch.sh` | `llama-bench` de l'hôte | `_dk_run llama-bench` |
| `tools/bench-depth.sh` | `llama-bench` de l'hôte | `_dk_run llama-bench` |
| `tools/spec-isolate.sh` | `llama-server` de l'hôte | `_dk_run llama-server`, port publié sur `127.0.0.1:8099`, conteneur nommé |
| `--list-devices` | moteur de l'hôte + paquets ggml, puis l'image | l'image seule |

- `_dk_run` gagne pour cela deux variables : `DK_RUN_PUBLISH` (publication de
  port, qui bascule le réseau par défaut sur `bridge`, toujours bornée à la
  loopback) et `DK_RUN_NAME` (nom du conteneur, pour que le trap de
  `spec-isolate.sh` fasse `docker rm -f` : tuer le `docker run` ne tue pas
  forcément le conteneur, qui garderait le GPU et le port). `LLAMA_BIN_DIR`,
  qui pointait un build à part du fork, est remplacé par `IMAGE=` dans les
  trois outils : c'est ainsi qu'on mesure un moteur autre que celui du service.
- `GGML_CUDA_ENABLE_UNIFIED_MEMORY` disparaît de tout le dépôt. Elle était
  nécessaire au moteur Vulkan/HIP de l'hôte et est INTERDITE sur le runtime
  retained-PM4 de l'image, où elle fait passer chaque allocation par
  `hipMallocManaged` et corrompt la sortie (cf. `runtime/AMONT.md`). Le test de
  `tests/sh-unit.sh` qui interdit sa présence dans le compose généré reste.
- Les valeurs par défaut des deux outils de courbe suivent le moteur : `DEV`
  passe de `Vulkan0` à `ROCm0`, et le cache KV de `bench-depth.sh` de `q8_0` à
  `f16`, qui est ce que sert le routeur depuis le 18/09/2026.
- **Retour arrière.** La procédure écrite avec ce retrait passait par
  `runtime/image.conf` et `--image-update`. Elle contredit « Un Dockerfile et
  un compose (18/09/2026) », qui est le dernier en date : `image.conf` et
  `--image-update` n'existent plus, les révisions sont les deux `ARG` du
  Dockerfile. Texte d'origine archivé (`docs/SECTIONS-RETIREES.md`, « Procédures du
  fork »). Le code de `lib/fork.sh` reste récupérable dans l'historique git du
  dépôt, au commit qui précède ce retrait.
- **Ce qui reste vrai et n'a pas bougé.** Les commentaires datés de
  `lib/models.sh` et de ce document qui citent le fork comme moteur d'une
  campagne : ce sont des mesures réellement faites sous `strix-<commit>`, et
  elles gardent leur étiquette. Les clés que seul ce moteur comprend
  (`ngram-on-disk`, `lazy-mode`, `fit`, `load-mode`, `reasoning-budget-*`,
  `spec-draft-adaptive`, `spec-prefill*`) restent posées dans le ini : la
  dorsale `halo-box/strix-llama.cpp` est la même dans l'image. Ce qui
  disparaît, c'est la garde qui les signalait quand un moteur d'amont était
  résolu sur l'hôte, sans objet depuis qu'il n'y a plus de moteur sur l'hôte.

## `--setup` allégé : plus de paquets llama.cpp ni ggml sur l'hôte (18/09/2026)

Suite du retrait du fork. `--setup` installait `llama-cpp`, `ggml-cpu` et
`ggml-vulkan` (obligatoires), et proposait en best-effort le runtime ROCm de
l'hôte plus `ggml-hip` (`ROCM_PKGS` : `rocm-hip-runtime`, `hipblas`, `rocblas`,
`hipblaslt`, `ggml-hip`), avec son contrôle `rocminfo | grep gfx1151`. Tout cela
ne servait qu'un moteur sur l'hôte, qui n'existe plus : le service et les outils
tournent dans l'image, qui embarque son propre ROCm.

Ce que `--setup` vérifie désormais, sans qu'aucun contrôle soit bloquant (un
`--setup` sert aussi à télécharger des poids sur une machine qui ne servira
rien) :

- `curl` et `hf` (`python-huggingface-hub`, `python-hf-xet`), installés par
  `paru` s'ils manquent, pour les téléchargements ;
- docker : la commande, le démon qui répond, le démon **activé au boot**
  (`systemctl is-enabled docker` : c'est docker qui relance le conteneur après
  un redémarrage de la machine, il a remplacé le `loginctl enable-linger` de
  l'unité systemd) et l'appartenance au groupe `docker` ;
- l'image du moteur : présente, avec son étiquette ; absente, `--image-build`
  est indiqué.

**Le dépôt ne désinstalle rien** et n'a jamais rien désinstallé. Sur une machine
qui porte encore ces paquets, les retirer à la main si la place manque :

```
paru -Rns llama-cpp ggml-cpu ggml-vulkan ggml-hip \
          rocm-hip-runtime hipblas rocblas hipblaslt
```

## Ornith 35B A3B : cache V f16 et retrait de swa-full (18/09/2026)

Les deux sections `ornith-1.5-35b-a3b-parallel` et `ornith-1.5-35b-a3b-mtp`
perdent des clés de corps, sur mesure et sur journal du moteur. Décision de
l'utilisateur, hors campagne. Aucune mesure n'est refaite au-delà de l'A/B :
les chiffres de référence des deux sections restent ceux du 18/09/2026
(1376 / 71,7 pour la `-parallel`, 1312 / 76,9 pour la `-mtp`), la `-parallel`
étant désormais servie dans la configuration f16 qui a donné 1379 / 72,4.

**`cache-type-v = q8_0` retiré de `ornith-1.5-35b-a3b-parallel`.** C'était la
dernière valeur de cache quantifiée du parc, gardée jusque-là faute d'avoir été
re-mesurée sur le moteur conteneurisé. L'A/B du 18/09/2026 (surcharge
`SPEC_AB_OVERRIDES`, même moteur strix-8c1c282+r7dda3ac, ROCm0) :

| cache V | `--bench` prefill / décode | `--bench-parallel` 4 requêtes, agrégé | mémoire libre |
|---|---|---|---|
| q8_0 (servi alors) | 1375,7 / 71,7 t/s | 144,1 t/s | 71 Gio |
| f16 | 1379,2 / 72,4 t/s | 145,9 t/s | 72 Gio |

Le f16 gagne environ 1 % de décode et 1 % d'agrégé, et ne coûte rien en
mémoire : `ctx-size` est de toute façon plafonné par le moteur à `n_ctx_train`
(262144), donc le f16 ne double pas le KV servi. La section suit désormais le
`cache-type-k` / `cache-type-v = f16` global. Plus aucune section du parc ne
pose de valeur de cache quantifiée.

**`swa-full = true` retiré des DEUX sections.** Clé inerte, constatée au journal
du moteur le 18/09/2026 sur l'une comme sur l'autre : « swa_full is not
supported by this model, it will be disabled ». Les 35B A3B n'ont pas de SWA.
Elle ne coûtait rien, mais elle n'expliquait aucun chiffre et le moteur la
refusait à chaque chargement : elle n'a rien à faire dans le ini. La clé reste
posée ailleurs (`ornith-1.5-9b-mtp-nothink`, `qwen3.8-27b-dflash-nothink`), où
elle est tout aussi inerte mais où rien n'a été re-décidé.

**`ctx-checkpoints = 128` est GARDÉ** des deux côtés : contrairement à
`swa-full`, c'est lui qui travaille sur cette architecture GDN, et il explique
les 62 % de contexte restauré au tour suivant mesurés par `--bench-cache`.

## lfm2.5-8b-a1b-nothink retiré (18/09/2026)

Section `lfm2.5-8b-a1b-nothink` (LFM2.5-8B-A1B de Liquid AI, Q8_0 de 9,0 Go et
drafter DSpark officiel de 0,36 Go) retirée du parc le 18/09/2026. Raison,
décidée par l'utilisateur : le modèle échoue à la boucle agentic réelle, sur
les DEUX moteurs, et `lfm2.5-2.6b` couvre déjà le créneau en passant 16/16.

Le verdict, daté :

- 16/09/2026, fork strix-0007bc6, Vulkan0 : 3/5 scénarios puis boucle sans fin
  sur la correction de bug (36 min, 18 700 requêtes de 20 à 50 tokens, contexte
  à 47k, conteneur tué à la main), table dans « Boucle agentic réelle
  (--bench-agentic) », contexte dans « Muse-Glimmer-30B et LFM2.5-8B-A1B
  ajoutés (16/09/2026) » ;
- 18/09/2026, moteur conteneurisé strix-8c1c282+r7dda3ac, ROCm0 : 0/16. La
  boucle part dès l'appel froid, aucun scénario n'aboutit, arrêt manuel après
  15 min 30. La section n'avait jamais été qualifiée sur ce moteur.

Ce n'était pas le seul signal : le contrôle de justesse du 18/09/2026 donnait
des comptages de lignes faux (69 / 259 / 399 pour 70 / 260 / 800), l'erreur
grossière à 20k tenant au `reasoning-budget 0` qui définit la section. Les
débits, eux, restaient bons (prefill 4 076 t/s, décode 118,5 t/s, acceptance
0,535, cache long 97 %, chargement 1,4 s) : ce retrait n'est pas une régression
de performance.

Les deux GGUF de `~/models/lfm2.5-8b-a1b/` (8,8 Gio au `du -sh`) ne sont plus
déclarés : ils deviennent orphelins de `KNOWN_FILES`, rien n'a été supprimé sur
la machine, `./setup-llm.sh --cleanup` les purgera.

Bloc complet (les deux `download_hf`, commentaire métier, corps) et marche à
suivre pour ravoir la section : `docs/SECTIONS-RETIREES.md`, « lfm2.5-8b-a1b-nothink ». Ce bloc porte
aussi le détail du réglage (quant officielle, drafter DSpark sidecar, thinking
coupé par `reasoning-budget-enable` + budget 0, n-gram 47 arbitré par
`--spec-ab`) et les mesures des deux moteurs.

## Campagne du moteur conteneurisé (17 au 18/09/2026)

Première campagne sur le moteur qui devient celui du service : l'image ROCm de
`runtime/` (ROCm 10.0 gfx1151 + ROCr/HIP retained-PM4 compilé depuis
pwilkin/rocm-systems + halo-box/strix-llama.cpp en HIP seul). Série
**`strix-8c1c282+r7dda3ac`** (moteur `8c1c282`, runtime `7dda3ac`), image
construite à la main depuis la PR kyuz0/amd-strix-halo-toolboxes#133.

La PR #133 a été mergée en amont le 18/09/2026 (merge `66da820` sur `main`).
Constat du jour : le Dockerfile amont est identique à notre copie vendorisée,
aux six écarts de `runtime/AMONT.md` près, et **aucune image n'est publiée**
pour lui (build manuel seulement, tag absent du registre). Le build local est
donc conservé, ce qui garde aussi l'épinglage des révisions. Rien ne change ni
dans `runtime/`, ni sur bigchuck.

**Méthode, et ses limites.** `llama-server` lancé **hors dépôt** par un script
de test, pas par `--bench` : ces chiffres ne sont donc PAS dans
`logs/bench.log`, ils n'entrent pas dans `docs/perfs.tsv` (dont le format n'a
que deux colonnes de série) et ils ne se comparent pas à la décimale aux
tableaux `--bench` de ce document. Ils seront rejoués par le dépôt après la bascule.
Conditions communes : device `ROCm0` (le seul de l'image), `-fit off`,
`--load-mode none`, `-ctk f16 -ctv f16`, prompt court d'environ 1 400 tokens et
1 000 générés, médianes de 3 passes. La justesse a été vérifiée à part, par
comptage de lignes sur des prompts de 40 à 51k tokens.

| Modèle (section) | Prefill t/s | Décode t/s | Fork strix-0007bc6, Vulkan0 | Prefill à 2k / 8k / 25k / 51k | Lecture |
|---|---|---|---|---|---|
| lfm2.5-2.6b | 4187 | 138,5 | 2875 / 108,8 | 4399 / 4181 / 3695 / 2954 | +46 % de prefill, +27 % de décode. Texte cohérent, mais 3 comptages justes sur 4 (251 au lieu de 260) : probable limite du modèle, comparaison en cours |
| ornith-1.5-9b-mtp-nothink | 1468 | 49,8 | 828 / 39,5 | 1355 / 1460 / 1294 / 1080 | +77 % de prefill, +26 % de décode |
| ornith-1.5-35b-a3b-mtp | 1673 | 82,4 | 1073 / 76,2 | 1703 / 1700 / 1429 / 1145 | +56 % de prefill, +8 % de décode. Testé à ctx 262144, pas aux 1048576 de production : à vérifier à la bascule, le f16 pesant deux fois le q8_0 par token de KV |
| qwen3.8-27b-dflash-nothink | 229 | 40,7 | 302 / 32,2 | 244 / 239 / 225 / 202 | **le seul compromis du parc** : décode +26 %, prefill -24 %. Le tour simulé 2000/3000 donne 81,4 s contre 99,8 s, donc l'image gagne sur ce profil, mais le profil est une convention : décision utilisateur, `--bench-agentic` à l'appui |
| muse-glimmer-30b-dflash | 318 | 36,4 | 266 / 38,0 (301 / 38,5 au contrôle à froid du 17/09) | 328 / 323 / 293 / 259 | +7 à +19 % de prefill, -4 à -10 % de décode : à peu près l'inverse de son concurrent le 27B |
| qwen3.8-flash-next-mtp-nothink | 877 | 52,2 | 364 / 52,4 | 938 / 1108 / 1111 / 1079 | prefill x2,4, décode égal. Seul modèle dont le prefill MONTE avec la profondeur (effet du batch 16384). 28 Gio restants une fois chargé |
| qwen3-coder-next | 1352 | 65,1 | 727 / 52,2 | 1417 / 1455 / 1245 / 1006 | +86 % de prefill, +25 % de décode, quatre comptages justes |
| deepseek-v4-flash | 162 | 29,3 (acceptance 0,83) | 196 / 28,8 (0,69) | 173 / 161 / 136 / 111 | décode +2 %, acceptance de 0,69 à 0,83, prefill -17 %, quatre comptages justes |

Non mesurés : `lfm2.5-8b-a1b-nothink` et `ornith-1.5-35b-a3b-parallel`. Leurs
réglages sont restés ceux du fork, et leurs blocs le disent. Depuis :
`ornith-1.5-35b-a3b-parallel` a été qualifiée le 18/09/2026 (puis retirée le
22/09/2026), et `lfm2.5-8b-a1b-nothink` retirée le 18/09/2026 (cf.
« lfm2.5-8b-a1b-nothink retiré (18/09/2026) »).

**Bogue du batch 16384.** `batch-size` / `ubatch-size` 16384 provoque une erreur
de segmentation (code de sortie 139) dès un prompt de 8k tokens sur TOUS les
modèles essayés SAUF Qwen3.8-Flash-Next, et coûte environ 33 Gio de tampons. Sur
Flash-Next il tient, et c'est lui qui donne les 877 t/s de prefill et la courbe
qui monte avec la profondeur. D'où le garde-fou de `generate_models_ini` : refus
d'émettre plus de `INI_BATCH_MAX` (4096) pour une section absente de
`INI_BIG_BATCH_OK`, surcharges `--spec-ab` comprises, avec la section, la valeur
et la raison dans le message.

**Leviers mémoire de DeepSeek : aucun.** Chargé, `deepseek-v4-flash` ne laisse
que 9 Gio disponibles, QUEL QUE SOIT le cache KV (f16 et q8_0 sont équivalents,
en mémoire comme en débit), le `fit` (on et off donnent le même résultat) ou le
contexte. Les trois leviers ont été essayés le 18/09. Conséquence pratique : ce
modèle se sert seul, et c'est la garde mémoire `_ensure_room_for` qui décharge
les autres avant de le charger.

**`mmap` disqualifié.** En `--load-mode mmap`, DeepSeek met plus de 13 minutes à
charger. Toute la campagne a tourné en `--load-mode none`, qui devient le réglage
global du parc.

**Les deux charabias ROCm sont guéris.** Le « Nous dev dev dev » de DeepSeek V4
et le « LAMPAMPAMP » de Qwen3-Coder-Next, tous deux constatés sur le ROCm
SYSTÈME (paquet `ggml-hip`, b10433) et qui avaient fait exclure ROCm0 de ces
deux architectures MoE à opérateurs fusionnés, n'apparaissent plus sur le
runtime retained-PM4 de l'image : quatre comptages de lignes justes sur chacun.
Le charabia venait du runtime, pas de l'architecture. Les exclusions restent en
commentaire daté dans `lib/models.sh`, et `--bench-sanity` reste (c'est elle qui
attrape un texte propre mais faux) : elle devient la première étape, bloquante,
de `tools/qualif-modele.sh`.

**Conséquences dans le dépôt** (commit du 18/09/2026) : `DEFAULT_DEVICE` passe à
`ROCm0` ; `fit = off`, `load-mode = none` et le cache K et V `f16` deviennent des
flags globaux ; `spec-draft-ngl = all` rejoint les injections automatiques ;
`--bench-devices`, `bench-devices.conf` et `lib/bench/bench-devices.sh` sont
retirés, faute de deuxième device ; `derive_gguf`, `_derive` et
`tools/mtp-rename-hc-head.py` partent avec la copie renommée du sidecar MTP de
Flash-Next, le moteur de l'image sachant lire la tête « shared » d'unsloth telle
quelle ; `fit`, `load-mode` et `lazy-mode` entrent dans `FORK_ONLY_KEYS`.

## Campagne du 17/09/2026 : cache V f16 sur le 27B, `reasoning = off`, essais retirés sur Flash-Next

Toutes les mesures de cette section : bigchuck, fork strix-0007bc6 épinglé,
Vulkan0, mode EC performance, `--bench` 3 passes (bench-task), à froid juste
après un redémarrage de la machine, le 17/09/2026. Sauf la dernière
sous-section, qui porte sur un autre commit du fork et le dit.

### `qwen3.8-27b-dflash-nothink` : cache-type-v f16 au lieu de q8_0

Retenu : `cache-type-v f16` (`lib/models.sh`, rien dans les `.conf`).

| Configuration (ngram 47 + draft-dflash 7) | Prompt t/s | Gen t/s | Acceptance |
|---|---|---|---|
| cache-type-v f16 | 302 | 32,2 | 0,625 |
| cache-type-v q8_0, même soir | 305 | 30,3 | 0,595 |

Le f16 rend +6 % de décode et monte l'acceptance de 0,595 à 0,625, le prefill
est égal (302 contre 305, dans le bruit). C'est la première comparaison propre
des deux caches V sur cette section : même moteur, même soir, même état de
machine. La convention du parc (V q8_0 pour l'agentic, précision des tool calls
et des diffs) cède ici devant la mesure ; la justesse des sorties n'a pas bougé
au contrôle de sanité.

Ces 302 / 32,2 / 0,625 remplacent les 359 / 32,6 / 0,595 du 13/09/2026 comme
chiffres de référence de la section dans le README et dans `docs/perfs.tsv` :
l'ancienne mesure appartient à une autre soirée et à une autre série, elle reste
citée ici et dans le commentaire daté de `lib/models.sh`. Contre le paquet Arch
b10433 (261 / 29,5 / 0,65), le décode est à +9,2 % ; contre `muse-glimmer-30b-dflash`
contrôlé le même soir (301 / 38,5), le 27B décode 20 % plus lentement pour un
prefill équivalent, là où la campagne du 16/09 lisait +17 % et -26 % sur les
chiffres d'alors.

### `reasoning = off` à la place de `chat-template-kwargs` `enable_thinking`

Cinq sections nothink passent à l'option native de llama-server :
`ornith-1.5-9b-mtp-nothink`, `ornith-1.5-35b-a3b-parallel`,
`ornith-1.5-35b-a3b-mtp`, `qwen3.8-27b-dflash-nothink` et
`qwen3.8-flash-next-mtp-nothink`. Motif : `chat-template-kwargs` est obsolète,
`--reasoning off` fait le travail côté serveur et est présent sur 0007bc6.

Contrôle sur `qwen3.8-flash-next-mtp-nothink` : `reasoning_content` vide,
réponse directe sans balise, et vitesse inchangée, 342 / 48,1 / 0,87 après le
changement contre 338 / 48,3 / 0,87 avant, même moteur. La sortie des quatre
autres sections n'a pas été contrôlée une à une : le changement est le même
partout, mais rien ne le dit modèle par modèle.

### Contrôle à froid des deux autres modèles touchés par la session

Configuration inchangée, même soir, mêmes conditions, pour situer les mesures
du 27B et non pour remplacer les références :

| Modèle | Prompt t/s | Gen t/s | Acceptance |
|---|---|---|---|
| qwen3.8-flash-next-mtp-nothink | 342 | 48,1 | 0,87 |
| muse-glimmer-30b-dflash | 301 | 38,5 | 0,63 |

### Essai retiré sur Flash-Next : `batch-size` / `ubatch-size` 16384 et `lazy-mode on-direct`

Paramètres retirés le 17/09/2026, retour au batch par défaut et à
`cache-type-v q8_0` sur cette section : le gain de prefill au bench court est
payé deux fois, en décode, et par un prefill servi qui s'écroule là où ce
modèle sert justement. Essai mené sur le fork 0636c9aee (b11111), pas sur
0007bc6 : prefill `--bench` 389 à 397 t/s contre 343, décode 45,3 à 46,5 contre
49,5 ; prefill servi sur Vulkan0 tombé à 135 t/s à 12 000 tokens, GPU décroché
à 25 000. Le fork 0636c9aee lui-même n'est pas retenu (le 27B y tombe à
255 / 25,5 contre 302 / 32,2 sur 0007bc6), ré-épinglage sur 0007bc6 le soir
même. Détail de l'essai : `docs/SECTIONS-RETIREES.md`, « Essai retiré sur Flash-Next
(17/09/2026) ».

Relecture du 21/09/2026 : depuis le merge b11111, `--ngram-on-disk` n'est
qu'un alias de `--lazy-mode on`, pas de `on-direct`. Les mesures servies depuis
le 18/09 passent `lazy-mode on-direct` seul et ne sont pas concernées.

Voir aussi, à ne pas confondre avec cet essai : « Bogue du batch 16384 » dans
« Campagne du moteur conteneurisé (17 au 18/09/2026) », mesuré sur l'image
ROCm, d'où vient le garde-fou `INI_BATCH_MAX` de `generate_models_ini`.

## Muse-Glimmer-30B et LFM2.5-8B-A1B ajoutés (16/09/2026)

Deux sections ajoutées le 16/09/2026, toutes deux servies avec un drafter
externe à un seul slot : `lfm2.5-8b-a1b-nothink` (LFM2.5-8B-A1B de Liquid AI,
grand frère du 2.6B, drafter DSpark officiel) et `muse-glimmer-30b-dflash`
(Muse-Glimmer-30B de Meta, drafter DFlash 2 z-lab, concurrent direct de
`qwen3.8-27b-dflash-nothink`). Même moteur pour tout ce qui suit : fork
strix-0007bc6, bigchuck, Vulkan0, 16/09/2026. Aucune des deux n'a jamais été
mesurée sur le paquet Arch : la colonne « paquet » du README et de
`docs/perfs.tsv` reste vide pour elles. La boucle agentic des deux modèles
(Muse 16/16, LFM2.5-8B-A1B en échec) est dans « Boucle agentic réelle
(--bench-agentic) ».

Deux points de méthode communs. `--bench-devices` n'a pas pu tourner : le fork
ne construit que Vulkan et la commande refuse de trancher avec un seul device.
Les deux sections héritent donc du défaut `[*] Vulkan0`, sans ligne dans
`bench-devices.conf` : ce n'est pas un choix mesuré, seulement le seul device
disponible. `--spec-ngram-tune` a été écarté de la même façon sur les deux :
sur un modèle sans tête MTP il prend « sans spéculation » pour référence, ce qui
n'a pas de sens quand le draft vient d'un drafter externe déjà servi ; la taille
n-gram a été réglée par `--spec-ab` sur le modèle tel qu'il est servi. Aucun
tune n'a tourné : rien dans `spec-nmax.conf`, `spec-ngram.conf` ni
`bench-devices.conf`, `spec-draft-n-max`, `spec-ngram-map-k-size-m` et le reste
sont dans `lib/models.sh`.

### lfm2.5-8b-a1b-nothink : LFM2.5-8B-A1B-Q8_0.gguf (9,0 Go) + drafter DSpark officiel Q8_0 (0,36 Go), bigchuck, fork strix-0007bc6, Vulkan0, 16/09/2026

Retenu : `ngram-map-k` size-m 47 min-hits 2 + `draft-dspark` n-max 3 sur
Vulkan0, `reasoning-budget-enable` + `reasoning-budget 0`, parallel 1. Jamais
mesuré au paquet Arch. Section retirée le 18/09/2026.

MoE `lfm2moe` 8,3B total / 1,5B actifs, ctx 131072, KV f16. Le modèle est
« reasoning-tuned » et son template n'a aucun interrupteur de thinking : en
1200 tokens il n'avait pas fini de raisonner, contenu vide sur les deux prompts.
Le suffixe `-nothink` vient de `reasoning-budget-enable` + `reasoning-budget 0`
(clés du fork), qui ferment la balise d'office.

Gen t/s (acceptance), Vulkan0 ; le prompt t/s n'est relevé (n/c ailleurs) que
sur le `--bench` :

| Configuration | spec-test.txt | spec-refactor.txt | Source |
|---|---|---|---|
| sans spéculation | 102,2 | 102,9 | test isolé, 2 passes, 1200 tokens |
| draft-dspark, n-max 3 | 118,0 (0,66) | 133,4 (0,82) | test isolé, 2 passes |
| draft-dspark, n-max 5 | 114,0 (0,60) | 128,4 (0,72) | test isolé, 2 passes |
| draft-dspark, n-max 9 | 82,0 (0,36) | 117,3 (0,56) | test isolé, 2 passes |
| sans spéculation, thinking ON | 107,3 | 100,3 (commentaire du bloc, absent de la table d'origine) | test isolé, 2 passes, contenu vide en 1200 tokens |
| draft-dspark 3, thinking ON | 100,9 (0,53) | 109,6 (0,62) | test isolé, 2 passes, contenu vide en 1200 tokens |
| sans spéculation | n/c | 106,0 | --spec-ab, 4 passes |
| draft-dspark seul, n-max 3 | 120,3 (0,71) | 126,6 (0,78) | --spec-ab, 4 passes |
| ngram 7 + draft-dspark 3 | 118,3 (0,68) | 146,2 (0,78) | --spec-ab, 4 passes |
| ngram 15 + draft-dspark 3 | n/c | 144,2 (0,70) | --spec-ab, 4 passes |
| ngram 47 + draft-dspark 3 | n/c | 169,6 (0,61) | --spec-ab, 4 passes |
| ngram 47 + draft-dspark 3, tel que servi | prompt 3079 t/s, gen 108,1 (0,55) sur bench-task | | --bench, 3 passes |

Lectures, cache de prompt (tour suivant 63 %, édition au premier tiers 0 %,
requête identique 64 % : architecture à état récurrent, la conv double-gate,
comme le 2.6B) et chargement : dans le bloc archivé
(`docs/SECTIONS-RETIREES.md`, « lfm2.5-8b-a1b-nothink »), qui porte les mêmes
chiffres avec leur explication. Seuls relevés absents du bloc : requête froide
440 ms, requête identique 176 ms (`--bench-cache` du 16/09/2026). Conclusion
des lectures : le drafter devine bien mieux la réponse que la pensée
(acceptance 0,53 / 0,62 avec le raisonnement contre 0,66 / 0,82 sans), ce qui
conforte le budget 0.

### muse-glimmer-30b-dflash : Muse-Glimmer-30B-UD-Q4_K_XL.gguf (15,9 Go) + drafter DFlash 2 z-lab Q8_0 (3,0 Go), bigchuck, fork strix-0007bc6, Vulkan0, 16/09/2026

Retenu : `ngram-map-k` size-m 7 min-hits 2 + `draft-dflash` n-max 7 sur Vulkan0,
`reasoning_strength` low + `reasoning-budget 4096`, parallel 1 (`--spec-tune`
refuse de toute façon `draft-dflash`). Jamais mesuré au paquet Arch.

Dense 30B `muse-glimmer`, SWA de 2048 sur 3 couches sur 4, ctx 131072,
cache-type-v q8_0, `swa-full` + `ctx-checkpoints 128`. Pas de suffixe `-nothink` :
le canal de réflexion de ce modèle ne se ferme pas, seul son niveau se règle
(`chat-template-kwargs` `reasoning_strength` low), plafonné par
`reasoning-budget-enable` + `reasoning-budget 4096`. Le test isolé a tourné à
-c 32768.

Gen t/s (acceptance), Vulkan0 ; prompt t/s n/c sauf mention :

| Configuration | spec-test.txt | spec-refactor.txt | Source |
|---|---|---|---|
| sans spéculation | 14,0 (prompt 275 t/s à froid) | 13,9 | test isolé, 2 passes, 1200 tokens |
| draft-dflash, n-max 7 | 43,0 (0,74 ; 6,0 tokens acceptés par étape) | 41,4 (0,72 ; 6,2 tokens acceptés par étape) | test isolé, 2 passes |
| draft-dflash, n-max 15 | 20,9 (0,55) | 17,5 (0,46) | test isolé, 2 passes |
| draft-dflash, n-max 3 | 37,8 (0,85) | 34,6 (0,80) | test isolé, 2 passes |
| draft-dflash seul, n-max 7 | 42,0 (0,73) | 37,2 (0,63) | --spec-ab, 4 passes |
| ngram 7 + draft-dflash 7 | 43,5 (0,73) | 41,8 (0,62) | --spec-ab, 4 passes |
| ngram 15 + draft-dflash 7 | n/c | 29,2 (0,52) | --spec-ab, 4 passes |
| ngram 47 + draft-dflash 7 | n/c | 37,1 (0,53) | --spec-ab, 4 passes |
| ngram 7 + draft-dflash 7, tel que servi | prompt 266 t/s, gen 38,0 (0,635) sur bench-task | | --bench, 3 passes |

Contre le concurrent direct `qwen3.8-27b-dflash-nothink`, mesuré le même mois
sur le même fork (359 / 32,6 / 0,595) : +17 % de décode, -26 % de prefill. Ces
deux écarts sont repris le 17/09/2026, dernier en date, par un contrôle à froid
des deux modèles le même soir, sur le même moteur (Muse 301 / 38,5, le 27B
302 / 32,2 en cache-type-v f16) : +20 % de décode et un prefill équivalent, cf.
« Campagne du 17/09/2026 ».

Lectures. Le décode nu à 14 t/s est celui d'un dense de 16 Go sur la bande
passante de bigchuck : ce modèle ne vit que par son drafter, qui rend x3,1. La
carte z-lab annonce 15, mais un batch de vérification de 16 colonnes quitte le
noyau mat-vec de ggml-vulkan (marche x2 entre 8 et 9, cf. l'issue #50) et le 15
mesuré perd la moitié du gain ; n-max 7 donne un batch de 8 = 4+4, hors du
découpage 4/2/1 du fork. Côté n-gram, le régime large PERD ici, contrairement au
27B où 47 gagne : le DFlash 2 accepte déjà 6 tokens par étape, et un draft
n-gram de 47 colonnes accepté à moitié lui vole des pas plus rentables ; 15 est
le pire des deux mondes (batch 16 hors du noyau mat-vec, exactement comme
n-max 15). Retenu 7 : +12,5 % sur le refactor, +3,5 % en générique.

Cache de prompt (`--bench-cache`, 16/09/2026) : requête froide 5 096 ms, tour
suivant 99 % (321 ms), édition au premier tiers 34 % (3 668 ms), requête
identique 100 % (82 ms). Attention pure, cache complet : le modèle se range avec
DeepSeek et les MoE à SWA, pas avec les architectures à état récurrent. Le 34 %
sur l'édition est une première dans ce document, où toutes les autres
architectures donnent 0 %.

Chargement (`--bench-load`, 16/09/2026) : 3,5 s de chargement + premier token
pour 15 Go, TTFT à chaud 88 ms.

## gpt-oss retiré (16/09/2026)

Section `gpt-oss` (openai gpt-oss-120b, MoE 128 experts, shards UD-Q4_K_XL de
59 Go) retirée du parc le 16/09/2026. Raison, décidée par l'utilisateur : le
modèle ne sert pas dans l'usage réel. Ni régression ni mesure douteuse derrière
ce retrait, ses chiffres du 13/09/2026 restaient bons (599 t/s de prefill, 52,9
de décode, acceptance 0,57, cache 99 %) ; c'est, après Laguna la veille, le
second géant qu'on ne charge jamais, pour 59 Go de disque et 91 s de
chargement. Les tables de ce document gardent ses lignes, comme `logs/`.

Fichiers. Le GGUF (2 shards) de `~/models/gpt-oss/UD-Q4_K_XL/` n'est plus
déclaré : il devient orphelin de `KNOWN_FILES`, rien n'a été supprimé sur la
machine, `./setup-llm.sh --cleanup` le purgera. Restent aussi dans
`~/models/gpt-oss/` les sous-dossiers `dflash-src/` (source HF du drafter,
1,5 Go) et `target-meta/` (27 Mo), jamais déclarés, que `--cleanup` ne touche
pas (il ne balaie que les `*.gguf` et les dossiers vides) : à retirer à la
main. Le GGUF du drafter converti avait déjà été purgé par le `--cleanup` du
15/09 au soir. Le venv `~/llm/venv-convert` et le build
`~/llm/strix-llama.cpp/build-bias/` sont hors de `~/models` et gardés pour la
PR #62.

Depuis ce retrait, plus aucune section n'hérite du `cache-reuse = 4096`
global : gpt-oss était la seule sans état récurrent où il servait.

### Drafter DFlash de gpt-oss : converti, refusé par le fork (15/09/2026)

Le drafter officiel `z-lab/gpt-oss-120b-DFlash` se convertit avec le
`convert_hf_to_gguf.py` du fork (option `--target-model-dir`, commande exacte
dans le bloc archivé) mais `llama-server` le refuse : `done_getting_tensors:
wrong number of tensors; expected 123, got 91`, puis `failed to load draft
model`. Les 32 tenseurs manquants sont les 8 couches x 4 biais d'attention du
drafter (`attn_q.bias`, `attn_k.bias`, `attn_v.bias`, `attn_output.bias`), que
sa config annonce par `attention_bias = true` : la dorsale Qwen3 de
`src/models/dflash.cpp` n'en crée aucun. C'est un manque, pas un refus. Tout
le détail (métadonnées, tailles, lignes de code, fichiers laissés sur
bigchuck) est dans le bloc archivé.

Décision : ne pas patcher le moteur. Signalé en amont le 15/09/2026,
[issue #61](https://github.com/halo-box/strix-llama.cpp/issues/61)
(reproduction, les 32 tenseurs, correctif proposé en trois points, 15 à
20 lignes : création des quatre biais en `TENSOR_NOT_REQUIRED`, `ggml_add` des
biais Q/K/V avant les `reshape_3d`, `layer.bo` à la place du `NULL` dans les
deux `build_attn`). Si elle est corrigée : reconvertir et essayer `draft-dflash`
à `spec-draft-n-max 9` (= `block_size - 1`) contre le n-gram, références à
battre dans le bloc archivé. Suite : le modèle a quitté le parc le 16/09/2026, la
PR #62 reste ouverte pour les autres drafters à biais.

### Bloc archivé

Bloc complet (déclaration de téléchargement, commentaire métier, corps ini) et
marche à suivre pour ravoir la section : `docs/SECTIONS-RETIREES.md`,
« gpt-oss ». Il porte le choix du device contre ROCm0, la courbe de batch la
plus raide du parc et pourtant +16 % au n-gram, la conversion du drafter DFlash
z-lab et son refus par le fork, et le comportement de `--cleanup` sur un modèle
en shards.

## Multi-slot et drafters (15/09/2026)

Règle générale qui s'en dégage, écrite en tête de `lib/models.sh` : un modèle
spéculatif ne gagne au multi-slot que si `parallel x (n-max + 1)` reste
inférieur ou égal à 8 colonnes, et le MTP n'y gagne de toute façon pas. Seul
interdit technique qui demeure : le mmproj reste incompatible avec un drafter.

Campagne `--bench-parallel` puis `--bench-agentic` du 15/09/2026 (fork
strix-0007bc6, Vulkan0), qui remplace la croyance « MTP impose parallel 1 » :
elle était fausse, mais le résultat mesuré lui donne souvent raison. Ce qui en
ressort, dans l'ordre :

1. **Un slot vide ne coûte rien en solo.** Sur une requête isolée, monter
   `parallel` de 1 à 2 ou 4 ne change ni le débit ni la mémoire résidente
   (deepseek-v4-flash : 199 / 28,9 à np 1 contre 196 / 28,8 à np 2, 112 Go
   résidents dans les deux cas). Le coût du multi-slot est ailleurs : le
   `ctx-size` est un pool partagé, donc chaque slot en retranche sa part.
2. **L'agrégé se prédit par `parallel x (n-max + 1)` contre le seuil des
   8 colonnes** de `mul_mat_vec_max_cols` de ggml-vulkan. Sous ou pile sur le
   seuil, le multi-slot peut payer, au-dessus il s'effondre :

   | Modèle | n-max | np 2 (colonnes, agrégé) | np 4 (colonnes, agrégé) |
   |---|---|---|---|
   | deepseek-v4-flash | 3 | 2 x (3 + 1) = 8, x1,22 | 16, x0,80 |
   | qwen3-coder-next | 7 | 16, x0,86 | 32, x0,92 (aucun np ne bat le solo) |
   | ornith-1.5-35b-a3b-mtp | 4 | x0,83 | x1,12, contre x1,93 sans spéculation |

3. **Le MTP multi-slot s'effondre même sous le seuil.** Sur qwen3.5-9b, à
   n-max 1, donc des batches de 4 et 8 colonnes qui restent dans le domaine
   vectoriel, np 4 rend 18,2 t/s agrégés et np 2 24,0, contre 80,8 sans
   spéculation. Ce n'est donc pas le découpage mat-vec de l'issue #50 : c'est
   le chemin MTP multi-séquences du fork (`common/speculative.cpp`, vectorisé
   par séquence mais éprouvé par aucun test amont). À verser à l'issue #50.
4. **La boucle agentic réelle tranche autrement que l'agrégé.**
   `--bench-agentic deepseek-v4-flash 2 2` ne rend que x1,16 de tâches pour un
   décode par boucle divisé par deux (14,5 t/s contre 28 à 30) et un contexte
   par slot divisé par deux : aucune concurrence réelle sur ce modèle, d'où le
   retour à parallel 1 le soir même. À l'inverse, ornith-1.5-35b-a3b à
   3 boucles rend x2,33 sur la passe propre, 40/40 PASS, cache 88 à 94 % :
   parallel 4 confirmé.

Décisions par modèle à l'issue de la campagne : ornith-1.5-35b-a3b reste à
parallel 4 sans spéculation (meilleur du parc en concurrence) et reçoit une
section `-mtp` séparée à parallel 1 pour le mono-utilisateur ; lfm2.5-2.6b et
qwen3.5-9b font l'inverse, la section principale passe au drafter à parallel 1
et l'ancien réglage multi-slot est d'abord gardé en variante `-parallel`, puis
retiré le soir même (« Variantes -parallel retirées ») ; qwen3-coder-next et
deepseek-v4-flash restent à parallel 1.

## Variantes -parallel retirées (15/09/2026)

Les sections `lfm2.5-2.6b-parallel` et `qwen3.5-9b-parallel`, créées le
15/09/2026 pour garder l'ancien réglage à 4 slots quand les sections
principales sont passées au drafter, ont été retirées le soir du même jour.
Raison, décidée par l'utilisateur : **pas de parallel si perte de perf**.
Aucune concurrence n'a jamais été observée sur ces deux modèles au journal du
service ; leurs sections à drafter (parallel 1) gagnent en solo (+59 % de
décode sur le LFM2.5, +29 % sur le 9b), et un multi-slot qui ne sert personne
ne fait que retrancher du contexte par slot. Le contraste est Ornith
(section renommée `ornith-1.5-35b-a3b-parallel` le soir même, à ne pas
confondre avec ces deux variantes retirées), seul multi-slot du parc conservé
alors : 2 à 3 slots occupés au journal du service, x1,93 en salves de
4 requêtes et x2,33 à 3 boucles agentic, pour aucune perte en solo. Sa variante
`-mtp` (parallel 4 côté base, parallel 1 côté MTP) reste elle aussi en place.

Ce que portaient ces deux variantes (GGUF, `ctx-size`, mesures du 21/08, du
13/09 et du 15/09/2026, justification écrite alors pour les garder et mesure
DSpark à np 2) est archivé : `docs/SECTIONS-RETIREES.md`, « Variantes -parallel
(15/09/2026) ». Chiffres de tête de l'ancien réglage à 4 slots, au paquet
b10433 le 21/08/2026 : lfm2.5-2.6b 2279 / 67,7 t/s et 205 t/s agrégés à
4 requêtes (x3,06) ; qwen3.5-9b 837 / 25,7 t/s et 78,6 t/s agrégés (x3,06).

Conséquences pratiques du retrait : `docs/perfs.tsv` garde les colonnes paquet
de ces deux modèles sur les lignes `lfm2.5-2.6b` et `qwen3.5-9b` (2279 / 67,7
et 837 / 25,7) avec la mention « paquet sans drafter » dans la colonne réglage,
comme le fait la ligne deepseek, pour que les graphes gardent la comparaison
paquet contre fork sur ces deux modèles ; `preload.conf` et les autres `.conf`
locaux de bigchuck, indexés par nom de section, peuvent contenir des lignes
`*-parallel` devenues sans effet (à nettoyer à la main si elles gênent) ; et le
GGUF sans MTP du 9b devient orphelin, purgeable par `./setup-llm.sh --cleanup`.

## qwen3.5-9b remplacé par Ornith-1.5-9B (15/09/2026)

Section `qwen3.5-9b` (Qwen3.5-9B UD-Q6_K_XL du repo MTP unsloth, dossier
`qwen3.5-9b-mtp/`, `ngram-map-k 7 + draft-mtp 4`, 745 t/s de prefill et 33,0 de
décode au `--bench` du 15/09/2026) retirée du parc le 15/09/2026 et remplacée,
au même créneau, par `ornith-1.5-9b-mtp-nothink` : Ornith-1.5-9B Q8_0 (9,79 Go)
avec tête MTP tierce (`protoLabsAI/Ornith-1.5-9B-MTP-GGUF`, GGUF fusionné trunk
officiel ornith-ai + tête nextn distillée par protoLabsAI, `blk.32.nextn.*`),
même architecture llama.cpp `qwen35` (GDN).

Raison : à VRAM comparable, les benchmarks de l'éditeur donnent Ornith-1.5-9B
très au-dessus de Qwen3.5-9B sur tout ce que ce créneau sert :

| Benchmark (éditeur) | Ornith-1.5-9B | Qwen3.5-9B |
|---|---|---|
| Terminal-Bench 2.1 (harnais Claude Code) | 47,0 | 18,9 |
| SWE-bench Verified | 70,6 | 53,2 |
| NL2Repo | 32,4 | 16,2 |
| GPQA | 86,4 | 81,7 |

Le débit est du même ordre (test isolé du 15/09/2026, mêmes prompts, quants
différentes : 44,7 / 52,9 t/s contre 42,4 / 61,8), le remplacement se joue donc
sur la qualité. Il n'y a ni régression ni défaut de mesure derrière ce retrait :
les chiffres du 9b Qwen restent bons, les tables de ce document gardent ses
lignes, mesurées à l'époque, comme `logs/`.

Le GGUF `~/models/qwen3.5-9b-mtp/Qwen3.5-9B-UD-Q6_K_XL.gguf` (8,4 Go) n'est plus
déclaré : il devient orphelin de `KNOWN_FILES`, rien n'a été supprimé sur la
machine, `./setup-llm.sh --cleanup` le purgera (le GGUF SANS tête MTP du même
modèle, `~/models/qwen3.5-9b/`, était déjà orphelin depuis le retrait de la
variante `-parallel` le matin même ; « Variantes -parallel retirées » date ce
retrait du soir du même jour : non tranché dans les sources).

Bloc complet (déclaration de téléchargement, commentaire métier, corps `llama_model` et
ini) et marche à suivre pour ravoir la section : `docs/SECTIONS-RETIREES.md`,
« qwen3.5-9b ». Il porte l'incident du GGUF homonyme écrasé, l'effondrement du
MTP multi-slot et la part du cache inchangée par la spéculation.

## Laguna-S-2.1 retiré (15/09/2026)

Section `laguna-s-2.1` (poolside, MoE 118B-A8B, shards UD-Q4_K_XL de 73,4 Go)
retirée du parc le 15/09/2026. Raison, décidée par l'utilisateur : le modèle ne
sert pas dans l'usage réel. Il n'y a ni régression ni défaut de mesure derrière
ce retrait, ses chiffres du 13/09/2026 restent bons (346 t/s de prefill, 29,6 de
décode, acceptance 0,80, cache 99 %) ; c'est un modèle de plus qu'on ne charge
jamais, pour 73 Go de disque et 90 s de chargement. Les tables de ce document
gardent ses lignes, mesurées à l'époque, comme `logs/`.

Le GGUF (3 shards) et le drafter DFlash poolside BF16 (2,2 Go) de
`~/models/laguna-s-2.1/` ne sont plus déclarés : ils deviennent orphelins de
`KNOWN_FILES`, rien n'a été supprimé sur la machine, `./setup-llm.sh --cleanup`
les purgera.

Ré-upload (note déplacée de `lib/models.sh` le 13/09/2026) : quants
ré-uploadées fin juillet 2026 par unsloth (« Fix rope/context metadata to 256K
YaRN (poolside config) » + fixes poolside), d'où un `./setup-llm.sh --update
laguna-s-2.1` nécessaire si le modèle avait été téléchargé avant.

Bloc complet (les deux déclarations de téléchargement, commentaire métier,
corps ini, bannière de groupe) et marche à suivre pour ravoir la section :
`docs/SECTIONS-RETIREES.md`, « laguna-s-2.1 ». Il porte le contrat DFlash
poolside refusé par les deux moteurs, le rope/YaRN 256K et le plus gros gain
n-gram jamais mesuré ici.

## Qwen3.8-27B thinking : section retirée le 13/09/2026

Le 27B avait deux sections sur le même GGUF : la thinking (`qwen3.8-27b`,
reasoning_effort medium, reasoning-budget 4096, draft-dflash 7 seul, 349 /
21,7 t/s, acceptance 0,35 sur le fork strix-0007bc6) et la nothink
(`qwen3.8-27b-dflash-nothink`, ngram-map-k 47 + draft-dflash 7, 359 / 32,6 t/s,
acceptance 0,595). La thinking, jamais préchargée et moitié moins vite au
décode, est retirée le 13/09/2026 ; seule `qwen3.8-27b-dflash-nothink` reste.
Les tables de ce document gardent la ligne « qwen3.8-27b (thinking) », mesurée
à l'époque (`logs/` aussi) ; si une section reprenait le nom `qwen3.8-27b`, le
comparateur de `--bench` la confronterait à cette ancienne série (215 / 12,1 au
paquet, 349 / 21,7 sur le fork), lire la date et le réglage avant d'y voir un
écart.

Bloc complet (commentaire métier et corps ini) et marche à suivre pour ravoir
la section : `docs/SECTIONS-RETIREES.md`, « qwen3.8-27b (thinking) ». Il porte
le détail du reasoning-budget, du speculative prefill essayé et retiré, et de
DFlash 2 sur du raisonnement.

## Passage au fork (12 et 13/09/2026) : apports, essais retirés, dépannage

Récit du passage du paquet Arch au fork strix-llama.cpp, tel qu'il figurait
dans la section « Moteur » du README. Détail et mesures dans les commentaires
de `lib/models.sh`.

Ce que le fork apporte côté réglages :

- **`ngram-on-disk`** laisse la table n-gram de 28,8 Go de Qwen3.8-Flash-Next
  sur disque : 72 Go de mémoire utilisée en instance seule (79 Go via le
  routeur, avec lfm2.5 et le sidecar MTP) au lieu d'environ 100, à prefill et
  décode identiques, mesuré le 12/09/2026.
- **`reasoning-budget-*`** plafonnent la réflexion des modèles thinking.
- **Le graphe MTP `qwen4exp` et le drafter externe** (`spec-draft-model`), ce
  qui débloque le MTP de Qwen3.8-Flash-Next (jalon 2), à une condition : le
  sidecar MTP d'unsloth devait d'abord être **renommé** (convention de la PR
  mainline #28243 contre celle du fork). L'outil `tools/mtp-rename-hc-head.py`
  et `derive_gguf` sont partis le 18/09/2026, l'image lisant la tête « shared »
  telle quelle ; le détail du renommage est archivé (`docs/SECTIONS-RETIREES.md`,
  « Procédures du fork »).
- **DFlash.** Il ne débloque rien sur Laguna S 2.1, refusé comme sur le paquet
  Arch (12/09/2026), mais il accepte le drafter DFlash 2 officiel de
  Qwen3.8-27B (z-lab, 2,0 Go) : il y remplace la tête MTP depuis le 13/09/2026
  (`qwen3.8-27b-dflash-nothink`, +12 à +18 % de décode selon le prompt).

Essais non retenus :

- **`spec-draft-adaptive`** dimensionne le draft sur l'acceptance mesurée :
  `--spec-ab` du 12/09/2026 sur les deux 27B MTP d'alors
  (qwen3.8-27b-mtp-nothink et le qwopus depuis retiré), 2 % sous le draft fixe.
- **Speculative prefill** (`spec-prefill*`) : un petit modèle estime
  l'importance des tokens du prompt et le gros n'en prefille qu'une fraction
  (`spec-prefill-p`, 0,30 par défaut). Contrairement au MTP et aux n-grams,
  c'est **lossy**, les tokens élagués sont perdus, et, mesuré le 12/09/2026
  sur qwen3.8-27b, il passe la boucle agentic (`--bench-agentic` 11/11 PASS,
  prefill 345 t/s) mais neutralise le cache de prompt (`--bench-cache` à 0 %
  même sur une requête identique) : retiré, perdant en boucle agentic. Détail
  dans le bloc archivé de cette section (`docs/SECTIONS-RETIREES.md`,
  « qwen3.8-27b (thinking) »).
- **`GGML_VK_MMV_NO_SPLIT=1`.** Contrepartie mesurée du fork : il découpe les
  mat-vec batchés en colonnes (4/2/1), ce qui coûte jusqu'à -7,4 % sur un
  batch de 7 (voir la note du 27B dans « Paquet Arch contre fork : mesures »).
  La variable annule la pénalité, mais désactive le découpage pour **tout** le
  parc, Flash-Next compris, qui lui en profite : non retenu. Le réglage par
  modèle (n-max qui évite le pire cas, ou le drafter DFlash 2 à n-max 7)
  suffit. Signalé en amont le 13/09/2026 :
  [issue #50](https://github.com/halo-box/strix-llama.cpp/issues/50) (table
  llama-bench, contournement DFlash 2) ; si un correctif arrive, re-comparer
  la tête MTP du 27B contre DFlash 2 après `--update-fork`.

Procédures du fork parties le 18/09/2026 avec `lib/fork.sh` (changelog de
`--update-fork`, épinglage par `fork.conf`, renommage du sidecar MTP) :
archivées dans `docs/SECTIONS-RETIREES.md`, « Procédures du fork ».

Qwen3.8-Flash-Next, attente d'un ré-upload (note déplacée de `lib/models.sh`
le 13/09/2026) : quants converties AVANT le merge de la PR (15:16 contre
19:32 UTC), donc ré-upload redouté ; il n'a pas eu lieu, vérifié le
04/09/2026, tailles des 3 shards inchangées : 10 946 624 / 49 835 229 856 /
43 836 407 744 octets. Les commits HF du 01/09 n'ont ajouté que le dossier
`MTP/`.

### Mise à jour du fork vers 654803517 (13/09/2026) : régression, retour à 0007bc6

Retour à 0007bc6 le jour même, fork épinglé tant que l'amont n'est pas corrigé
(procédure d'épinglage par `fork.conf` archivée, `docs/SECTIONS-RETIREES.md`).
Signalé en amont
le 13/09/2026 :
[issue #51](https://github.com/halo-box/strix-llama.cpp/issues/51) (table des
quatre bras, commits candidats, bisect proposé).

Premier `--update-fork` réel : 0007bc6 vers 654803517, soit la PR de sync #47
du fork (206 commits llama.cpp amont, b10891 vers b10917) et aucun changement
propre au fork. Ces comptes diffèrent de ceux du changelog du 12/09, archivé
(0007bc6 → 6548035 = 210 commits dont 209 d'amont, amont b10809 → b10950) :
celui du 13/09 est le dernier en date, mais rien dans les sources ne dit
lequel est juste.
`--bench all` sur ce commit (série strix-6548035, garde mémoire exercée trois
fois sans OOM) : neuf modèles au niveau de la série précédente, mais les deux
sections du 27B en DFlash 2 perdent 18 à 23 % de décode à acceptance égale
(nothink 26,7 t/s contre 32,6, thinking 16,8 contre 21,7). `--spec-ab` sur le
nouveau build : sans spéculation 11,9 t/s (inchangé), donc le forward à batch 1
n'a pas bougé ; DFlash seul 29,4 contre 37,0 : c'est le chemin de vérification
batché qui ralentit. llama-bench, `-b 8 -ub 8 -r 3`, en t/s :

| cols | fork 0007bc6 | fork 654803517 | 654803517 + NO_SPLIT | paquet b10809 |
|---|---|---|---|---|
| 4 | 47,8 | 48,2 | 48,1 | 47,4 |
| 5 | 54,2 | 51,2 | 53,6 | 56,7 |
| 7 | 68,9 | 58,0 | 61,5 | 74,3 |
| 8 | 79,3 | 51,7 | 53,5 | 80,5 |

Le batch 8 devient plus lent que le batch 7, indépendamment du découpage.
Suspects parmi les commits amont intégrés : « vulkan: small M matrix
optimizations for qwen » (#28457) et « vulkan: tune mat-vec rows for batched
inference on Strix Halo » (#27909). Après le retour à 0007bc6 : pp7 68,5,
pp8 77,9 retrouvés.

Cette table et le llama-bench du même 13/09 cité dans la note du 27B de
« Paquet Arch contre fork : mesures » ne donnent pas les mêmes valeurs pour le
paquet b10809 : au batch 7, 74,3 ici contre 74,5 là (et 56,7 et 47,4 ici aux
batchs 5 et 4, contre 56,9 et 47,7 là, dont le terme de comparaison n'est pas
précisé). Non tranché dans les sources. Pour le fork 0007bc6 au batch 7, 68,9
puis 68,5 : le 68,5 est la mesure d'après le retour, la dernière en date.

## Résultats mesurés (bigchuck), campagnes du paquet Arch et du fork

Conventions de lecture des tables qui suivent, jusqu'à « Enseignements ».

- Moteur courant de ces campagnes : fork **strix-0007bc6** depuis le
  12/09/2026 (la section « Moteur : fork strix-llama.cpp » du README, citée
  ici à l'origine, n'existe plus ; le README résume le fork sous « Avant : les
  deux moteurs précédents »), campagne
  `--bench` du parc entier les 12 et 13/09/2026, 3 passes, Vulkan0.
- Dans « Cache de prompt (--bench-cache) » et « Chargement (--bench-load) »,
  les chiffres du paquet Arch sont entre parenthèses ; dans « Récapitulatif
  par modèle », le paquet a sa colonne. Builds du paquet : **b10433 / ggml 0.20.0**,
  **b10548 / ggml 0.20.2** pour gpt-oss et Laguna, **b10566** pour ornith,
  **b10809 / ggml 0.23.0** pour Flash-Next. Ce sont deux séries distinctes, qui
  ne se comparent pas à la décimale : builds et jours différents, passes MTP
  dispersées. Détail des runs dans `logs/bench.log` et `logs/spec-tests.log`
  sur bigchuck.
- Les réglages de spéculation, les courbes de batch, le cache de prompt et les
  temps de chargement des sections par thème datent des campagnes du paquet
  (21 au 28/08/2026) et n'ont pas été re-mesurés sur le fork, sauf mention.
- Médianes hors première passe, 4 passes sauf mention.
- Les lignes `spec-test.txt` (écriture d'un module de zéro, meilleur cas MTP)
  et `spec-refactor.txt` (recopie de blocs exacts, le cas n-gram) ne se
  comparent pas entre elles.

### Historique du parc

| Date | Événement |
|---|---|
| 15/08/2026 | qwen3.6-27b et qwen3.6-27b-mtp retirés de l'inventaire, remplacés par qwen3.8-27b ; qwen3.5-2b, qwen3.5-9b-mtp, gemma-31b et gemma-12b retirés car jamais utilisés |
| 28/08/2026 | les trois Qwen3.6-35B-A3B remplacés par ornith-1.5-35b-a3b (inventaire : qwen3.6-35b-a3b et qwen3.6-35b-a3b-mtp retirés) |
| 13/09/2026 | qwen3.8-27b-mtp-nothink renommé qwen3.8-27b-dflash-nothink : tête MTP remplacée par le drafter DFlash 2. Le même jour, qwopus3.6-27b-coder-mtp-nothink retiré, plus utilisé ; ses mesures restent dans `logs/`. Le soir même, la section thinking qwen3.8-27b retirée à son tour (doublon sur le GGUF de qwen3.8-27b-dflash-nothink, moitié moins vite : 21,7 contre 32,6 t/s), cf. « Qwen3.8-27B thinking : section retirée le 13/09/2026 » |
| 15/09/2026 | à l'issue de la campagne multi-slot, ornith-1.5-35b-a3b-mtp ajouté : même GGUF que la section de base, tête MTP embarquée servie à un seul slot pour l'usage mono-utilisateur (la base garde parallel 4 sans spéculation, meilleure en concurrence réelle). Deuxième cas du parc de deux sections sur un GGUF unique, après la famille 27B ; `_preload_sanity` avertit si elles sont préchargées ensemble |
| 15/09/2026 | variantes `lfm2.5-2.6b-parallel` et `qwen3.5-9b-parallel` créées puis retirées (« Variantes -parallel retirées ») : le GGUF SANS tête MTP du 9b, `~/models/qwen3.5-9b/Qwen3.5-9B-UD-Q6_K_XL.gguf` (8,2 Go), homonyme mais distinct de celui du dossier `qwen3.5-9b-mtp/`, sort de l'inventaire |
| 15/09/2026, soir | `qwen3.5-9b` remplacée par `ornith-1.5-9b-mtp-nothink` (« qwen3.5-9b remplacé par Ornith-1.5-9B ») : le second GGUF, `~/models/qwen3.5-9b-mtp/Qwen3.5-9B-UD-Q6_K_XL.gguf` (8,4 Go), sort de l'inventaire |
| 15/09/2026 | `laguna-s-2.1` retirée, jugée non utile dans l'usage réel (« Laguna-S-2.1 retiré (15/09/2026) ») ; son dossier de GGUF devient orphelin |
| 15/09/2026, soir | section de base d'Ornith renommée `ornith-1.5-35b-a3b-parallel` (détail ci-dessous) |
| 16/09/2026 | `gpt-oss` retirée, même sort (« gpt-oss retiré (16/09/2026) ») ; `muse-glimmer-30b-dflash` et `lfm2.5-8b-a1b-nothink` ajoutées |
| 18/09/2026 | `lfm2.5-8b-a1b-nothink` retirée |
| 22/09/2026 | `ornith-1.5-35b-a3b-parallel` retirée, `qwen3.8-flash-next-mtp-nothink-large-ub` créée |

Les tables gardent les lignes et les mesures des sections retirées.
`./setup-llm.sh --cleanup` purge les GGUF sortis de l'inventaire
(`KNOWN_FILES` ; la liste de ces retraits a été déplacée de `lib/models.sh` le
13/09/2026).

Renommage d'Ornith en `-parallel` : le nom dit ce qu'elle sert, comme `-mtp` et
`-dflash-nothink` ailleurs, puisque c'est la variante parallel 4 sans
spéculation réservée à la concurrence. Seul le nom de SECTION change : le
dossier de GGUF reste `ornith-1.5-35b-a3b/` (donc la ligne de
`bench-devices.conf`, indexée par dossier, est intacte) et les entrées datées
et les mesures gardent le nom d'alors, `ornith-1.5-35b-a3b`. Une conséquence
locale, sans gravité : `logs/bench.log` et le comparateur
`py/bench_compare.py` sont clés par NOM DE SECTION (puis GGUF et device), donc
le prochain `--bench` annoncera « première mesure journalisée » au lieu de
comparer aux runs des 28/08 et 13/09 ; les chiffres d'avant restent dans le
journal sous l'ancien nom, et renommer la colonne 2 de `logs/bench.log` à la
main les rebranche (journal local, non versionné : rien n'est fait ici).

## Récapitulatif par modèle, campagne des 12, 13 et 15/09/2026 (fork strix-0007bc6)

Prefill et gen en t/s, protocole `--bench`. En gras, la valeur de référence du
fork. Les écarts sont ceux de la colonne fork contre la colonne paquet. Les
notes par modèle (autres mesures, lectures, pièges du comparateur) sont dans
« Paquet Arch contre fork : mesures ».

| Modèle | GGUF | Device | Réglage retenu | Fork : prefill / gen / acc. (date) | Paquet : prefill / gen / acc. (build, date) | Écart prefill | Écart gen |
|---|---|---|---|---|---|---|---|
| lfm2.5-2.6b | Q8_0 (2,7 Go) + drafter DSpark officiel Q8_0 (0,36 Go) | Vulkan0 (mesuré) | **draft-dspark 3**, parallel 1 (retenu le 15/09/2026) | **2875** / **108,8** / 0,50 (15/09) | 2279 / 67,7 (b10433, 21/08, réglage sans drafter à 4 slots) | +26,2 % | +60,7 % |
| qwen3.5-9b (retirée le soir du 15/09/2026) | UD-Q6_K_XL (8,4 Go, GGUF MTP unsloth, dossier `qwen3.5-9b-mtp/`) | Vulkan0 (hérité : bench-devices.conf est indexé par dossier de GGUF) | **ngram-map-k 7 + draft-mtp 4**, min-hits 2, parallel 1 (retenu le 15/09/2026, tête MTP embarquée blk.32.nextn) | **745** / **33,0** / 0,58 (15/09) | 837 / 25,7 (b10433, 21/08, GGUF sans MTP, sans spéculation, 4 slots) | -11,0 % | +28,4 % |
| ornith-1.5-9b-mtp-nothink | Q8_0 (9,79 Go, GGUF fusionné tiers protoLabsAI, tête MTP nextn distillée) | Vulkan0 (hérité : le fork ne construit que Vulkan, `--bench-devices` non lancé) | **ngram-map-k 7 + draft-mtp 3**, min-hits 2, parallel 1 (retenu le 15/09/2026, tête MTP embarquée blk.32.nextn) | **827,9** / **39,5** / 0,56 (15/09) | jamais mesuré au paquet | n/c | n/c |
| ornith-1.5-35b-a3b-parallel | Q4_K_M (22 Go) | Vulkan0 (mesuré : ROCm0 931 / 57,6) | parallel 4, sans spéculation | **1129** / **73,3** (13/09) | 974 / 70,7 (b10566, 28/08) | +15,9 % | +3,7 % |
| ornith-1.5-35b-a3b-mtp | idem (même GGUF) | Vulkan0 (hérité : bench-devices.conf est indexé par dossier de GGUF) | **ngram-map-k 7 + draft-mtp 4**, parallel 1 (tête MTP embarquée blk.40.nextn, découverte le 15/09/2026) | **1073** / **76,2** / 0,55 (15/09) | jamais mesuré (section créée le 15/09/2026) | n/c | n/c |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0 (mesuré) | **draft-dflash 7** (DFlash 2 z-lab, retenu le 13/09/2026 sur le fork, reasoning_effort medium) | **349** / **21,7** / 0,35 (13/09) | 215 / 12,1 (b10433, 21/08, sans spéculation) | +62,3 % | +79,3 % |
| qwen3.8-27b-dflash-nothink | idem | Vulkan0 (mesuré) | ngram-map-k 47 + **draft-dflash 7** (drafter DFlash 2 z-lab, 2,0 Go) | 359 / 32,6 / 0,595 (13/09, cache-type-v q8_0) ; référence depuis le 17/09 : **302** / **32,2** / 0,625 (cache-type-v f16) | 261 / 29,5 / 0,65 (b10433, 21/08) | +37,5 % (13/09) | +10,5 % (13/09) ; +9,2 % (17/09) |
| qwen3.8-flash-next-mtp-nothink, n-gram seul avec `ngram-on-disk` | UD-IQ4_XS (94 Go, MoE, GDN) | Vulkan0 (mesuré, ROCm0 exclu) | étape intermédiaire, à réglage égal avec le paquet | 414 / 30,9 / 0,80 (12/09) | 197 / 25,9 / 0,75 (b10809, 05/09) | +110,2 % | +19,3 % |
| qwen3.8-flash-next-mtp-nothink | idem | idem | **ngram-map-k 7** + **draft-mtp 4** | **383** / **50,0** / 0,87 (12/09, bench mixte) | impossible sur le paquet | +94,4 % contre le paquet en n-gram seul | +93,1 % contre le paquet en n-gram seul |
| qwen3-coder-next | UD-Q4_K_XL (47 Go) + drafter DFlash z-lab Q8_0 (0,51 Go, conversion transmutator) | Vulkan0 (mesuré, ROCm0 exclu) | **draft-dflash 7** seul (retenu le 15/09/2026) | **727** / **52,2** / 0,515 (15/09) | 468 / 43,7 (b10433, 21/08, ngram-map-k 47) | +55,3 % | +19,5 % |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE) | Vulkan0 (mesuré : ROCm0 219 / 31,5, juste lent) | ngram-map-k 7 | **599** / **52,9** / 0,57 (13/09) | 333 / 51,9 (b10548, 21/08) | +79,9 % | +1,9 % |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 (mesuré : ROCm0 320 / 23,6) | **ngram-map-k 7** seul | **346** / **29,6** / 0,80 (13/09) | 255 / 30,3 / 0,835 (b10548, 21/08) | +35,7 % | -2,3 % |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go) + drafter DSpark unsloth Q8_0 (10,9 Go) | Vulkan0 (mesuré) | ngram-map-k 7 + **draft-dspark 3**, **parallel 1** | **196** / **28,8** / 0,69 (15/09, mesure faite à parallel 2, gardée comme référence chiffrée ; 199 / 28,9 / 0,68 à parallel 1 le matin du 15/09, parallel 1 étant le réglage servi depuis le soir du 15/09, l'écart est dans le bruit) | 110 / 12,3 (b10433, 21/08) | +78,4 % | +134,1 % |

« cache » dans les notes = part du prompt servie du cache pour tour suivant /
édition au milieu / requête identique. Une colonne paquet vide ou « jamais
mesuré » = section jamais servie sous le paquet (`docs/perfs.tsv` la laisse
vide et les figures y écrivent « n/c »).

Deux valeurs de la colonne paquet diffèrent au chiffre près de la table du parc
d'origine, qui arrondissait un autre run du même jour : qwen3-coder-next 468 au
lieu de 457, laguna-s-2.1 255 au lieu de 247. C'est `logs/bench.log` qui fait foi.

## Paquet Arch contre fork : mesures

Comparaison des deux séries, faite le 13/09/2026 et complétée le 15/09/2026
(DSpark et parallel 2 de DeepSeek, drafter DFlash de Coder-Next, variante MTP
d'Ornith). La table elle-même, avec ses écarts, est celle de « Récapitulatif
par modèle, campagne des 12, 13 et 15/09/2026 (fork strix-0007bc6) » ; les
figures qui en sont tirées (`docs/graphs/*.svg`) sont restées dans le README.
Cette section en garde le bilan et les notes par modèle.

Protocole `--bench` du dépôt (prefill de la passe 1 à froid, décode médian des
passes suivantes, acceptance médiane), sauf mention. Dans la table du
récapitulatif, la colonne « Paquet » porte la dernière valeur de la série
`bNNNNN` dans `logs/bench.log` pour ce modèle, et la colonne « Fork » la
campagne `--bench` 3 passes, Vulkan0, `strix-0007bc6`, des 12 et 13/09/2026,
parc entier, plus les trois sections re-réglées le 15/09/2026.

### Bilan

Le fork gagne le prefill sur tout le parc, de +16 % (qwen3.5-9b, ornith) à
+110 % (Qwen3.8-Flash-Next), sans exception. Ce bilan date du 13/09
et a été retouché en partie le 15/09 ; depuis le re-réglage du 15/09, la ligne
qwen3.5-9b de la table affiche -11,0 % (GGUF et réglage différents, cf. sa
note) : la table est la dernière en date. Il gagne nettement le décode partout où la spéculation change de régime : DeepSeek V4 +135 %
(+62 % en n-gram seul, le reste par le drafter DSpark), qwen3-coder-next +12 %
(la table, dernière en date, affiche +19,5 % depuis le drafter DFlash du
15/09), Qwen3.8-Flash-Next dont le MTP n'existe pas sur le paquet +93 %,
qwen3.8-27b-dflash-nothink avec le drafter DFlash 2 +11 % contre le paquet et
+23 % contre la tête MTP sur le fork, et qwen3.8-27b thinking +79 % avec le
même drafter contre un paquet sans spéculation. Ailleurs il est neutre, le
décode des petits modèles, de gpt-oss et de Laguna bougeant de moins de 5 %
dans un sens ou dans l'autre, soit la dispersion normale des passes (pour les
petits modèles, la table, dernière en date, affiche +60,7 % sur lfm2.5-2.6b et
+28,4 % sur qwen3.5-9b depuis les re-réglages du 15/09) : depuis le
passage du 27B nothink au drafter DFlash 2, plus aucun écart négatif ne
subsiste, et le fork apporte en plus le sidecar MTP de Flash-Next et les clés
que le paquet ne sait pas charger.

Trois mesures du fork n'entrent pas dans le tableau, le draft adaptatif
(`spec-draft-adaptive`), le speculative prefill et le gain mémoire de
`ngram-on-disk` : elles sont dans « Passage au fork (12 et 13/09/2026) ».

**⚠ OOM du noyau pendant `--bench all`.** Le routeur a été tué deux fois par
l'OOM killer pendant la campagne du 13/09, à chaque fois au chargement d'un
géant alors qu'un autre était encore résident : Laguna (73 Go) chargé pendant
que gpt-oss (59 Go) tenait encore la mémoire, puis DeepSeek (104 Go) chargé
après avoir évincé lfm2.5 (le LRU) au lieu de Laguna. `--models-max 2`
(préchargé + 1) autorise cette somme, et la politique LRU ne connaît pas la
taille des modèles. Le service se relance seul (`Restart=on-failure`) et la
mesure en cours est perdue. Pour un `--bench all` ou toute suite de gros
modèles : décharger explicitement le précédent par le `POST /models/unload`
du routeur, ou ordonner la suite du plus petit au plus gros.

### Notes par modèle

Tout est sur le fork strix-0007bc6, Vulkan0, sauf mention.

**lfm2.5-2.6b** (fork 15/09/2026)

- Réglages différents des deux côtés : le paquet tournait sans drafter à
  4 slots, le fork sert le DSpark à un slot depuis le 15/09/2026. Sur le même
  fork, le réglage sans drafter donnait 3048 / 70,8 le 13/09 et 3602 / 68,2
  re-mesuré le 15/09 sous la variante `-parallel` (retirée le soir même) ;
  contre elle : décode +59 %, prefill -20 %, le drafter DSpark décodant aussi
  le prompt.
- Le comparateur de `--bench` annonce « prefill 3651 -> 2875 RÉGRESSION » : il
  compare par nom de section sans savoir que le réglage a changé, et la
  variante retrouve 3602 le même jour. Le 3651 cité par le comparateur n'est
  ni le 3048 du 13/09 ni le 3602 du 15/09 : non tranché dans les sources.
- Test isolé du 15/09 (2 passes, spec-test / spec-refactor) : sans spéculation
  69,6 t/s ; draft-dspark n-max 3 =
  **122,3** (acc. 0,39 à 0,83, soit x1,76), n-max 5 = 110,2, n-max 9 = 124,6
  (acc. 0,19 à 0,69) ; n-max 3 retenu pour son acceptance et son batch de
  vérification de 4 colonnes.
- `--bench-load` du 15/09, drafter compris : chargement 0,4 s, TTFT 27 ms.
- L'ancien réglage à 4 slots (205 t/s agrégés à 4 requêtes, x3,06 ; chargement
  0,5 s, TTFT 27 ms ; cache 62 / 63 %) : cf. « Variantes -parallel retirées ».

**qwen3.5-9b** (fork 15/09/2026 ; section retirée le soir même, remplacée par
`ornith-1.5-9b-mtp-nothink`, ses chiffres restent tels que mesurés)

- GGUF ET réglage différents des deux côtés : le paquet tournait sur le GGUF
  sans tête MTP, sans spéculation, à 4 slots. Sur le même fork, ce réglage
  donnait 971 / 25,7 le 13/09 (25,7 au paquet comme sur le fork) et 791 / 25,5
  re-mesuré le 15/09 sous la variante `-parallel` ; contre elle : décode
  +29 %, prefill -5,8 %.
- Le comparateur annonce « prefill 993 -> 745 RÉGRESSION » alors que le GGUF
  ET le réglage ont changé, et la variante ne rend elle-même que 791 le 15/09
  contre 993 le 13/09 : l'essentiel est de la dispersion entre journées. Le
  13/09 porte donc deux valeurs de prefill pour ce réglage, 971 (campagne
  `--bench`) et 993 (citée d'après `bench.log` et par le comparateur) : non
  tranché dans les sources.
- Test isolé du 15/09 (2 passes) : sans spéculation 25,3 t/s ; MTP seul n-max 2 = 34,2,
  n-max 4 = 45,7, n-max 6 = 40,8 ; ngram-map-k 7 min-hits 2 + draft-mtp 4 =
  **52,1** (42,4 générique, 61,8 refactor), soit x2,1 en test isolé contre
  x1,29 au `--bench`, dont le prompt est générique.
- `--bench-cache` du 15/09 : 62 % au tour suivant, 0 % après édition, 64 % à
  l'identique, soit exactement les valeurs du 21/08 sans spéculation, inchangé
  par le MTP.
- Multi-slot MTP inutilisable (np 4 n-max 1 = 18,2 t/s agrégés contre 80,8).
- L'ancien réglage à 4 slots (78,6 t/s agrégés à 4 requêtes, x3,06 ;
  chargement 1,9 s, TTFT 65 ms) : cf. « Variantes -parallel retirées ».

**ornith-1.5-9b-mtp-nothink** (fork 15/09/2026)

- Section créée le 15/09/2026 en remplacement de `qwen3.5-9b` (Ornith-1.5-9B
  Q8_0, tête MTP tierce protoLabsAI ; benchmarks de l'éditeur dans
  « qwen3.5-9b remplacé par Ornith-1.5-9B »). Contre la section remplacée,
  mesurée le même jour sur le même fork (745 / 33,0 / acc. 0,58) : prefill
  +11 %, décode +20 %.
- Test isolé du 15/09 (2 passes, spec-test / spec-refactor) : sans spéculation
  23,6 / 23,3 ; draft-mtp 2 =
  28,4 / 30,2 ; **draft-mtp 3 = 45,3 / 51,3** ; draft-mtp 4 = 29,9 / 33,3 ;
  ngram 7 min-hits 2 + draft-mtp 3 = 44,7 / 52,9. Courbe non monotone : n-max 3 et non
  4, seul le batch de 4 colonnes échappe au découpage mat-vec du fork
  (issue #50), 2 et 4 retombent à ~30 t/s.
- `--spec-ab` du même jour sur le service, spec-refactor : 52,9 (acc. 0,85) ;
  le n-gram vaut +4,5 % (52,89 contre 50,62 en MTP seul), il est gardé.
- nothink obligatoire (thinking ON : 1200 tokens de raisonnement sans
  `</think>`, acceptance 0,42).

**ornith-1.5-35b-a3b-parallel** (fork 13/09/2026)

- Sans spéculation des deux côtés ; mesures faites sous l'ancien nom
  `ornith-1.5-35b-a3b`. 136,8 t/s agrégés à 4 requêtes (x1,93) ; cache 62 %.
  Remplace les trois Qwen3.6-35B-A3B le 28/08/2026 ; section renommée
  `-parallel` le 15/09/2026 (le suffixe dit l'usage, comme `-mtp`).

**ornith-1.5-35b-a3b-mtp** (fork 15/09/2026)

- Variante mono-utilisateur du même GGUF : +24 % en solo contre la section de
  base (88,7 contre 71,6 t/s ; au `--bench`, 76,2 contre 73,3), mais perdante
  en concurrence (np 2 agrégé 75,7 soit x0,83, np 4 agrégé 102,1 soit x1,12,
  contre 138 t/s à np 4 sans spéculation), d'où deux sections plutôt qu'un
  réglage unique : la base reste le défaut agentic, elle bat la variante MTP
  en concurrence réelle (138 t/s agrégés à 4 requêtes contre 102).
- Test isolé : **113,2** (refactor, acc. 0,83) et **90,3** (générique,
  acc. 0,65).

**qwen3.8-27b (thinking)** (fork 13/09/2026)

- Réglage différent des deux côtés : le paquet tournait sans spéculation, le
  fork avec le drafter DFlash 2. `--spec-test` du 13/09 : 24,5 t/s contre 12,3
  sans. Référence sans spéculation sur le paquet : bench.log 02/09 (b10621)
  239 / 12,13 ; en llama-bench le prefill va de 289 à 183 à 32k (« Profondeur
  de contexte »).
- reasoning-budget 4096 (fork). spec-prefill essayé et retiré : lossy et
  incompatible avec le cache de prompt (0 %), perdant en agentic.
- Le comparateur du dépôt affiche « prefill 759 → 349 régression » : les
  759 t/s du 12/09 à 23:15 portaient `spec-prefill-p` 0,30, option retirée
  depuis ; 349 est la première mesure du réglage réellement servi, ce n'est
  pas une régression.

**qwen3.8-27b-dflash-nothink** (fork 13/09/2026, référence 17/09/2026)

- Série de chiffres, dans l'ordre (prefill / décode / acceptance) :

  | Série | Chiffres | Lecture |
  |---|---|---|
  | paquet b10433, 21/08 | 261 / 29,5 / 0,65 | référence paquet |
  | fork 13/09, ancien réglage MTP n-max 6 | 360 / 26,6 / 0,59 | -9,8 % de décode contre le paquet |
  | fork 13/09, ngram 47 + draft-dflash 7, cache-type-v q8_0, autre série que le 17/09 | 359 / 32,6 / 0,595 | +22,6 % sur la base MTP |
  | fork 17/09, q8_0 | 305 / 30,3 / 0,595 | même soir que la ligne suivante |
  | fork 17/09, f16, référence depuis | 302 / 32,2 / 0,625 | +6 % contre le q8_0 du même soir (« Campagne du 17/09/2026 ») |

  Chargement 4,4 s d'après le récapitulatif d'origine ; dans « Chargement
  (--bench-load) », 4,4 s est la valeur du paquet pour la section thinking et
  le fork donne 3,5 s pour cette section : non tranché dans les sources.
  Réglage DFlash non mesuré sur le paquet Arch.
- Le -9,8 %, seul écart de décode négatif du parc, **s'expliquait** par le
  découpage des mat-vec batchés du fork (colonnes 4/2/1, restreint à q8_0 et
  q6_K par sa PR #27 ; le UD-Q4_K_XL porte 110 tenseurs q8_0 et 56 q6_K), à
  son pire cas au batch de vérification 7 = n-max 6 + 1, découpé en 4+2+1.
  llama-bench du 13/09 (Vulkan0, `-b 8 -ub 8 -r 3`) : pp7 68,9 t/s contre 74,4
  avec `GGML_VK_MMV_NO_SPLIT=1` et 74,5 au paquet b10809 (-7,4 %), pp5 54,2
  contre 56,9 (-4,7 %), pp4 47,8 contre 47,7 (aucune pénalité). La table de
  « Mise à jour du fork vers 654803517 » donne d'autres valeurs pour le paquet
  (74,3 au batch 7) : voir la note qui la suit.
- Le réglage du fork n'est plus celui du paquet : **ngram 47 + draft-dflash
  n-max 7**, qui bat la tête MTP sur les deux prompts en `--spec-ab` du 13/09
  (4 passes, décode médian hors 1re passe ; +12 % en refactor, +18 % en
  générique, chiffres dans « Spéculation »). Le batch de vérification vaut
  alors 8, découpé en 4+4 : le pire cas du découpage est contourné, ce que le
  `--bench` du 13/09 confirme (32,6 t/s). DFlash 2 annule le retrait de décode
  du fork.

**qwen3.8-flash-next-mtp-nothink** (fork 12/09/2026)

- Le MTP n'existe pas sur le paquet (sidecar refusé ; le mainline ne sait
  toujours pas le charger, PR #28243). Sur le fork : sidecar autonome Q8_0
  renommé par `tools/mtp-rename-hc-head.py`.
- `--spec-tune` draft-mtp seul k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7 :
  n-max 4 confirmé ; `--spec-test` mixte 48,8 acc. 0,86.
- Sur spec-refactor.txt le paquet fait **54,0** en n-gram seul (+115 %).
- ROCm0 répond « LAMPAMPAMP… » ; cache 62 % ; chargement 60,8 s depuis le
  disque (14,1 s fichier chaud). Le récapitulatif d'origine attribue ce
  « LAMPAMPAMP » à Flash-Next et à Qwen3-Coder-Next ; « Campagne du moteur
  conteneurisé », dernière en date, ne le cite que pour Qwen3-Coder-Next, et
  la table « Spéculation » dit seulement « charabia » pour Flash-Next sur
  ROCm0. Non tranché dans les sources pour Flash-Next.

**qwen3-coder-next** (fork 15/09/2026)

- Réglage différent des deux côtés : le paquet tournait en ngram-map-k 47, le
  fork sert depuis le 15/09/2026 le drafter DFlash z-lab (GGUF communautaire
  transmutator, Q8_0 de 0,51 Go, arch dflash, block_size 16, target_layers
  [4,12,24,36,44]), qui remplace ngram-map-k 47, dont le compromis +47 %
  refactor / -5 % générique disparaît. Sur le même fork, en n-gram seul, le
  13/09 donnait 763 / 48,7 / 0,27 : le drafter ajoute +7,2 % de décode et
  double l'acceptance pour -4,6 % de prefill (il décode aussi le prompt).
- Test isolé du 15/09 (2 passes, spec-test / spec-refactor) : ngram 47 =
  45,2 / 48,7 ; draft-dflash 15 =
  43,5 / 65,9 ; **draft-dflash 7 = 70,5 / 100,0** (acc. 0,70 / 0,92) ; ngram 47 +
  draft-dflash 7 = 67,9 / 104,6 (acc. 0,65 / 0,82) : les n-grams par-dessus le
  drafter font retomber l'acceptance (0,92 → 0,82 en refactor) sans gain net,
  retirés. n-max 7 = batch de vérification 8, la dernière taille du chemin
  vectoriel de ggml-vulkan ; n-max 15 (batch 16) retombe.
- `--bench-parallel` du 15/09 : solo 73,0 t/s, np 2 agrégé 64,7 (x0,86), np 4
  agrégé 68,5 (x0,92) : aucun np ne bat le solo, parallel 1 maintenu.
- ROCm0 répond « LAMPAMPAMP… » ; cache 64 % ; chargement 72 s depuis le disque
  d'après le récapitulatif d'origine, alors que « Chargement (--bench-load) »
  donne 55,4 s au fork et 72 au paquet : non tranché dans les sources.

**gpt-oss** (fork 13/09/2026)

- Décode neutre ; le fork journalise une acceptance n-gram là où le paquet
  n'en donnait pas. 59,8 t/s en refactor au paquet.
- Cache 99 % (attention, pas d'état récurrent) ; chargement 91 s depuis le
  disque ; drafter DFlash z-lab converti le 15/09/2026 mais refusé par le fork
  (biais d'attention, issue #61), le n-gram reste seul.

**laguna-s-2.1** (fork 13/09/2026)

- Écart de décode dans le bruit de mesure. draft-dflash refusé par le mainline
  (`wrong number of tensors; expected 76, got 69`) **et** par le fork le
  12/09/2026 (`failed to load draft model`).
- 53,0 t/s en refactor au paquet (+85 %) ; cache 99 % ; chargement 90,5 s
  depuis le disque (67 s au paquet).

**deepseek-v4-flash** (fork 15/09/2026)

- Plus gros gain de décode du parc (+135 % contre le paquet, +45 % contre le
  n-gram seul). Pas de tête MTP dans le GGUF, le 0731 ne publie qu'un drafter
  DSpark (sidecar unsloth de 10,9 Go). En n-gram seul le fork faisait
  205 / 19,9 / 0,65 le 13/09 (+61,8 %) ; le drafter ajoute +45 % de décode
  pour -3 % de prefill (il décode aussi le prompt).
- `--spec-ab` du 15/09 sur spec-refactor.txt (4 passes) : n-gram seul 31,2 t/s
  acc. 0,91, DSpark seul n-max 3 35,6 / 0,94, n-gram + DSpark n-max 3
  **38,7** / 0,87, n-max 2 35,0 / 0,89, n-max 5 22,7 / 0,48 (l'acceptance
  s'effondre au-delà de 3, comme mesuré par unsloth sur B200).
- **parallel 2 retenu le matin du 15/09/2026, annulé le soir même** (cf.
  « Multi-slot et drafters ») : `--bench-parallel` du même jour donne
  1 requête 33,6 t/s et 2 requêtes 39,0 t/s agrégés (x1,16, 19,9 par
  requête) ; la campagne multi-slot mesurait solo 25,2 / 26,6 / 25,9 t/s à
  np 1 / 2 / 4 et agrégé 32,4 (x1,22, acc. 0,63) à np 2 contre 20,8 (x0,80) à
  np 4. Seul cas du parc où le multi-slot paie, parce que le batch de
  vérification vaut 2 x (3 + 1) = 8 colonnes, pile le seuil
  `mul_mat_vec_max_cols` de ggml-vulkan (16 à np 4). Conséquences : ctx-size
  131072 est un pool partagé, soit 65536 par slot, et la mémoire ne bouge pas
  (112 Go résidents à np 1, 2 et 4) ; sur une requête isolée le deuxième slot
  ne coûte rien (196 / 28,8 contre 199 / 28,9).
- reasoning-budget 6144 (fork) posé le 13/09 (seuil non atteint sur le test
  fait). ROCm0 inutilisable (b10433) ; cache 99 % (attention pure) ; 115 Go de
  poids, la garde mémoire décharge lfm2.5 pour le charger.

## Spéculation

Réglages spéculatifs mesurés modèle par modèle, du 15/08/2026 (paquet
b10433) au 13/09/2026 (fork strix-0007bc6) ; le build est en note de ligne.

| Modèle | GGUF | Device | Configuration | Gen t/s | Acceptance | Prompt |
|---|---|---|---|---|---|---|
| qwen3.8-27b-dflash-nothink | UD-Q4_K_XL (17 Go) | Vulkan0 | draft-mtp n-max 2 | 26,8 | 0,95 | spec-test |
| | | | draft-mtp n-max 4 | 31,8 | 0,85 | spec-test |
| | | | draft-mtp n-max 6 (retenu par --spec-tune au paquet) | 33,1 | 0,75 | spec-test |
| | | | ngram-map-k 7 + mtp 4 | 44,0 | 0,94 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 47,4 | 0,73 | spec-refactor |
| | | | ngram-map-k 47 + mtp 6 (retenu au paquet) | 56,1 | 0,80 | spec-refactor |
| | | ROCm0 (15/08) | draft-mtp n-max 2 / 4 / 6 | 22,2 / 25,5 / 26,0 | | spec-test |
| | | Vulkan0, fork (13/09) | ngram-map-k 47 + mtp 6 | 54,1 | 0,668 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 (retenu jusqu'au 13/09) | 57,8 | 0,712 | spec-refactor : +6,8 %, le batch de vérification à 5 échappe au découpage mat-vec 4+2+1 |
| | | Vulkan0, fork (13/09), drafter DFlash 2 | ngram-map-k 47 + mtp 6 / mtp 4 | 53,8 / 57,6 | 0,67 / 0,71 | spec-refactor, série `--spec-ab` du réglage DFlash (référence MTP) |
| | | | **ngram-map-k 47 + draft-dflash 7** (retenu) | **64,5** | 0,67 | spec-refactor : +12 % contre le meilleur MTP ; batch de vérification 8 découpé en 4+4, hors du pire cas du découpage mat-vec |
| | | | draft-dflash 7 seul | 47,0 | 0,96 | spec-refactor : acceptance quasi parfaite, mais sans les hits n-gram |
| | | | ngram-map-k 47 + mtp 4 / draft-mtp seul | 30,5 / 29,7 | 0,65 / 0,74 | spec-test : référence MTP en générique |
| | | | **ngram-map-k 47 + draft-dflash 7** (retenu) | **35,9** | 0,70 | spec-test : +18 % contre le MTP |
| | | | draft-dflash 7 seul | 37,0 | 0,77 | spec-test : 3 % devant la liste en générique pur (peu de hits n-gram), la liste est gardée pour le régime agentic |
| | | | **ngram-map-k 47 + draft-dflash 7** (retenu) | **32,6** | 0,595 | `--bench` du 13/09/2026 (bench-task, 3 passes, prefill 359 t/s) : réglage servi, +11 % contre le paquet (29,5 / 0,65) et +23 % contre le MTP n-max 6 du fork (26,6 / 0,59) |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0, fork (13/09) | **draft-dflash 7** (retenu, reasoning_effort medium) | **21,7** | 0,35 | `--bench` du 13/09/2026 (bench-task, 3 passes, prefill 349 t/s) : +79 % contre le paquet sans spéculation (12,1) ; `--spec-test` 24,5 contre 12,3 sans |
| qwen3.6-35b-a3b-mtp-nothink (retiré le 28/08/2026) | UD-Q4_K_XL (MoE) | Vulkan0 | ngram-map-k 7 + mtp 4 | 110,3 | 0,93 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 105,3 | 0,71 | spec-refactor |
| qwen3-coder-next | UD-Q4_K_XL (MoE, GDN) | Vulkan0 | sans spéculation | 46,8 | | spec-refactor |
| | | | ngram-map-k 7 | 20,8 | 0,98 | spec-refactor : surcoût fixe par pas spéculatif, un petit draft ne l'amortit pas |
| | | | **ngram-map-k 47** (retenu) | **68,7** | | spec-refactor |
| | | | ngram-map-k 47 | 44,5 (min-hits 4 : 44,8) | 0,23 | spec-test : -5 % sans répétitions |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE, SWA) | Vulkan0 | sans spéculation | 51,7 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **59,8** | | spec-refactor |
| | | | ngram-map-k 47 | 52,7 | | spec-refactor : le grand draft paie son batch x14,7 |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 | sans spéculation | 28,7 | | spec-refactor (b10548) |
| | | | **ngram-map-k 7** (retenu) | **53,0** | | spec-refactor : +85 %, le plus gros gain n-gram mesuré |
| | | | ngram-map-k 47 | 39,9 | | spec-refactor |
| | | | draft-dflash (n-max 15 ou 7) | échec | | mainline b10548 : refuse le drafter, 69 tenseurs créés au lieu des 76 du fichier |
| | | | ngram-map-k 7 + draft-dflash 7 | échec | | fork strix-0007bc6 (12/09/2026) : il revendique DFlash, mais son loader ne crée toujours aucun `attn_gate` : `common_speculative_init_result: failed to load draft model`, retour au n-gram seul |
| qwen3.8-flash-next-mtp-nothink | UD-IQ4_XS (94 Go, MoE, GDN) | Vulkan0 | sans spéculation | 25,1 | | spec-refactor (b10809, 05/09/2026) |
| | | | **ngram-map-k 7** (retenu) | **54,0** | 0,95 | spec-refactor : +115 %, le petit draft gagne malgré la famille GDN + MoE |
| | | | ngram-map-k 47 | 48,2 | 0,86 | spec-refactor : une passe sur quatre illisible (seed 44), reproductible |
| | | | **ngram-map-k 7 + draft-mtp 4** (retenu) | **50,0** | 0,87 | fork strix-0007bc6, sidecar autonome Q8_0 (4,1 Go) renommé par `tools/mtp-rename-hc-head.py` ; --bench du 12/09/2026 : prefill 383 t/s, contre 414 / 30,9 en n-gram seul sur le même fork (+62 % de décode, -7 % de prefill) ; --spec-test 4 passes : 48,8 t/s, acceptance 0,86 |
| | | | draft-mtp seul, n-max 2 / 4 / 6 / 8 | 43,0 / **50,7** / 49,5 / 32,7 | 0,95 / 0,90 / 0,84 / 0,80 | --spec-tune du 12/09/2026 (spec-test.txt, 4 passes) : n-max 4 retenu (spec-nmax.conf) ; la chute à 8 est la marche de la courbe entre les batchs 8 et 9 |
| | | ROCm0 | sans spéculation | **charabia**, exclu | | bench-devices, question de contrôle |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go, MoE) | Vulkan0 | sans spéculation | 11,3 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **12,3** | 0,9 sur les hits | spec-refactor |
| | | | ngram-map-k 31 | 11,8 | 0,27 à 0,66 | spec-refactor |
| | | ROCm0 | sans spéculation | ~550 (**charabia**, exclu) | | bench |

Prefill (passe 1, cache froid) : 27B ~220 t/s sur spec-test, ~275 t/s sur
spec-refactor ; 35B-A3B ~865 t/s ; DeepSeek 108 à 120 t/s (Vulkan0).

## Courbes de batch

Balayages `tools/bench-spec-batch.sh` du 21/08/2026 au 05/09/2026, paquet Arch,
sur Vulkan0, reps=5 :

| GGUF | batch 1 | batch 8 | batch 9 | batch 48 | Lecture |
|---|---|---|---|---|---|
| Qwen3.8-27B Q4 | 83 ms | 101 ms | 215 ms | 283 ms | marche x2,13 entre 8 et 9, plateau jusqu'à 16 |
| Qwopus3.6-27B Q5 (retiré le 13/09/2026) | 89 ms | 106 ms | 257 ms | 310 ms | marche x2,42 |
| Qwen3.6-35B-A3B Q4 (MoE) | 17 ms | 33 ms | 68 ms | 136 ms | marche x2,06, mais pente raide sous la marche (batch 8 = 1,9x) |
| DeepSeek-V4-Flash IQ3 (MoE) | 83 ms | 302 ms | | 1087 ms | pas de marche, x3,6 dès le batch 8 : la courbe disait « non », la mesure a dit +9 % |
| Qwen3-Coder-Next Q4 (MoE, GDN) | 21 ms | 46 ms | marche | 199 ms | x2,16 au batch 8 ; en réel, surcoût fixe par pas spéculatif, seul 47 gagne |
| gpt-oss-120b Q4 (MoE, SWA) | 17 ms | 57 ms | | 246 ms | x3,4 au batch 8, x14,7 au batch 48 ; en réel size_m 7 = +16 % |
| Laguna-S-2.1 Q4 (MoE) | 33 ms | 95 ms | | 540 ms | x2,9 au batch 8, x16,5 au batch 48 ; en réel size_m 7 = +85 % |
| Qwen3.8-Flash-Next IQ4 (MoE, GDN) | 41 ms | 94 ms | 238 ms | 515 ms | marche x2,5 entre 8 et 9, x12,6 au batch 48 ; en réel size_m 7 = +115 % (b10809) |

## Profondeur de contexte

`tools/bench-depth.sh` du 16/08/2026, paquet Arch b10433 : 27B Q4, KV q8_0,
sans spéculation, reps=2.

| Device | depth 0 | depth 16k | depth 32k | Tour simulé 0 → 32k |
|---|---|---|---|---|
| Vulkan0 | 289 pp / 12,25 tg | 222 / 11,83 | 183 / 11,50 | 252 s → 272 s (x1,08) |
| ROCm0 | 352 pp / 11,97 tg | 263 / 10,73 | 214 / 9,54 | 256 s → 324 s (x1,26) |

ROCm0 prefill plus vite à vide mais décode moins bien, et se dégrade deux
fois plus vite en profondeur : Vulkan0 gagne à toutes les profondeurs sur ce
GGUF, et l'écart se creuse en contexte long (le régime agentic).

## Concurrence, cache de prompt, chargement

Le cache de prompt et le chargement ont leurs sections (« Cache de prompt
(--bench-cache) », « Chargement (--bench-load) ») ; la concurrence sur le fork
est dans « Multi-slot et drafters (15/09/2026) ».

`--bench-parallel` des 21 et 28/08/2026, paquet Arch (b10433 et b10566),
spec-test.txt, 400 tokens, 2 salves :

| Modèle | parallel | 1 requête | 4 requêtes | Lecture |
|---|---|---|---|---|
| qwen3.5-9b | 4 | 25,7 t/s | 78,6 t/s agrégés (x3,06), 20,1 t/s par requête | le `parallel 4` des tâches auxiliaires est justifié |
| lfm2.5-2.6b | 4 | 67,4 t/s | 205 t/s agrégés (x3,06), 52 t/s par requête | idem |
| ornith-1.5-35b-a3b | 4 | 70,7 t/s | 136,8 t/s agrégés à 4 (x1,93), 35 t/s par requête | le MoE s'amortit moins bien qu'un dense : chaque requête route ses propres experts (le Qwen3.6 qu'il remplace faisait x1,43 à 2) |

## Boucle agentic réelle (--bench-agentic)

pi 0.84.3 en conteneur, appel froid puis 3 passes de 5 scénarios de tool calls
en direct sur `:8009`, médianes, bigchuck. Une table par série de moteur, à ne
pas comparer à la décimale entre elles. Autres boucles agentic, racontées avec
leur campagne : gufo (24/09/2026, dans `docs/HISTORIQUE-GUFO.md`), halogen et
omp (22/09/2026),
`lfm2.5-8b-a1b-nothink` sur l'image ROCm (18/09/2026, 0/16), salves à
plusieurs boucles (« Multi-slot et drafters »), speculative prefill sur
qwen3.8-27b (mesuré le 12/09/2026, 11/11).

### Paquet Arch b10566, 28/08/2026

| Modèle | Verdict | Scénario | Mur | Prompt (part du cache) | Généré | Prefill | Décode |
|---|---|---|---|---|---|---|---|
| ornith-1.5-35b-a3b | 16/16 | froid (prompt système de pi) | 1,5 s | 1 523 tok (66 %) | 2 | 820 t/s | n/s |
| | 3/3 | write+bash+read | 2,8 s | 4 833 tok (98 %) | 133 | 228 t/s | 72,3 t/s |
| | 3/3 | edit | 4,1 s | 6 605 tok (91 %) | 181 | 518 t/s | 71,0 t/s |
| | 3/3 | création module + tests | 11,0 s | 5 876 tok (89 %) | 666 | 525 t/s | 70,9 t/s |
| | 3/3 | bug sans toucher au test | 7,2 s | 9 447 tok (91 %) | 361 | 508 t/s | 71,0 t/s |

Lecture : le décode en boucle d'outils (71 t/s) rejoint le `--bench` (70,7) ; le cache sert 89 à 98 % tant que la conversation ne fait que s'allonger, et le préfixe de pi survit d'un conteneur à l'autre (cache-ram). La variance est celle du modèle : le scénario 5 a pris 18 s (1 069 tokens, trois tours) sur une passe et 7 s sur les deux autres ; le tout premier run du jour l'avait fait en 49 s et 65 k tokens de prompt cumulés (28 % repayés, décode apparent 8 t/s : le coût GDN quand les tours s'enchaînent).

### Fork strix-0007bc6, 16/09/2026 : Muse-Glimmer-30B et LFM2.5-8B-A1B

| Modèle | Verdict | Scénario | Mur | Prompt (part du cache) | Généré | Prefill | Décode |
|---|---|---|---|---|---|---|---|
| muse-glimmer-30b-dflash | 16/16 | froid (prompt système de pi) | 11,2 s | 1 599 tok (0 %) | n/s | 259 t/s | n/s |
| | 3/3 | réponse simple | 2,5 s | 1 599 tok (99 %) | 62 | 55 t/s | 33,0 t/s |
| | 3/3 | write+bash+read | 10,9 s | 7 332 tok (99 %) | 344 | 74 t/s | 38,1 t/s |
| | 3/3 | edit | 10,8 s | 7 274 tok (98 %) | 363 | 79 t/s | 40,8 t/s |
| | 3/3 | création module + tests | 25,9 s | 10 674 tok (98 %) | 986 | 101 t/s | 39,8 t/s |
| | 3/3 | bug sans toucher au test | 37,5 s | 12 498 tok (97 %) | 1 050 | 164 t/s | 33,8 t/s |
| lfm2.5-8b-a1b-nothink | ÉCHEC (passe 1 seule) | froid | 3,0 s | 1 328 tok (0 %) | 24 | 3012 t/s | 47,8 t/s |
| | 0/1 | réponse simple | 0,8 s | 1 328 tok (100 %) | 23 | 202 t/s | 46,3 t/s |
| | 1/1 | write+bash+read | 1,9 s | 4 253 tok (85 %) | 105 | 1722 t/s | 89,2 t/s |
| | 1/1 | edit | 4,0 s | 9 278 tok (90 %) | 300 | 1355 t/s | 103,3 t/s |
| | 0/1 | création module + tests | 5,2 s | 3 094 tok (44 %) | 423 | 3080 t/s | 98,6 t/s |
| | boucle sans fin | bug sans toucher au test | tué après 36 min | contexte à 47k | 18 700 requêtes de 20 à 50 tok | | |

Lecture : Muse-Glimmer tient la boucle complète, le cache sert 97 à 99 % à chaque tour (attention pure) et le décode en boucle (34 à 41 t/s) rejoint le `--bench` (38,0) ; le raisonnement en `reasoning_strength` low ne fait échouer aucun scénario. LFM2.5-8B-A1B (thinking coupé) réussit les tool calls simples mais rate la réponse simple et la création de module (fichiers écrits, test jamais relancé jusqu'au vert), et part en boucle de tool calls sur la correction de bug : `--bench-agentic` n'a pas de limite de tours, le conteneur a été tué à la main. C'est le résultat, pas un défaut du serveur (le 2.6B, lui, reste le modèle de tool calling). La section est gardée avec ce verdict, à retirer si elle ne sert pas dans l'usage réel. Suite : elle a été retirée le 18/09/2026 après un second échec, 0/16 sur le moteur conteneurisé (cf. « lfm2.5-8b-a1b-nothink retiré (18/09/2026) »).

## Réglages n-gram alternatifs

`--spec-ab` du 21/08/2026, paquet Arch b10433 : 27B, n-max 6,
spec-refactor.txt, 4 passes.

| Variante | Gen t/s | Acceptance | Lecture |
|---|---|---|---|
| base (ngram-map-k 47, min-hits 2, draft-mtp 6) | **56,1** | 0,80 | +18 % sur le même réglage n-gram avec n-max 4 (47,4) : le n-max 6 profite aussi au mode mixte |
| min-hits 1 | 55,8 | 0,80 | équivalent, 2 gardé |
| ngram-map-k4v 47, min-hits 2 | 44,9 | 0,91 | -20 % : drafte moins souvent malgré une meilleure acceptance |

## Cache de prompt (--bench-cache)

`--bench-cache`, bench-context.txt ~1370 tokens. Série **fork
strix-0007bc6, 13/09/2026**, parc complet du plus petit au plus gros, modèle
précédent déchargé avant chaque gros ; entre parenthèses la valeur de la
campagne du paquet Arch (b10433, 21 au 28/08/2026) quand elle existe. La
requête froide est à 0 % partout, par construction (horodatage en tête du
contexte). Les deux sections ajoutées le 16/09/2026,
`lfm2.5-8b-a1b-nothink` et `muse-glimmer-30b-dflash`, ont été mesurées ce
jour-là sur le même fork et sont insérées à leur place.

| Modèle | Architecture | Tour suivant | Édition au 1er tiers | Requête identique | Prefill froid → identique |
|---|---|---|---|---|---|
| lfm2.5-2.6b | conv récurrente (autre tokenizer) | 63 % (62) | 0 % (0) | 64 % (63) | 373 → 151 ms |
| lfm2.5-8b-a1b-nothink | conv récurrente, MoE | 63 % | 0 % | 64 % | 440 → 176 ms |
| qwen3.5-9b | hybride SWA/GDN | 62 % (62) | 0 % (0) | 64 % (63) | 1 419 → 549 ms |
| qwen3.8-27b | dense, GDN + gated attention | 62 % | 0 % | 64 % | 3 814 → 1 463 ms |
| qwen3.8-27b-dflash-nothink | idem (même GGUF) | 62 % | 0 % | 64 % | 3 838 → 1 472 ms |
| **muse-glimmer-30b-dflash** | **attention + SWA 2048, dense** | **99 %** | **34 %** | **100 %** | 5 096 → 82 ms |
| ornith-1.5-35b-a3b | GDN, MoE | 62 % (62) | 0 % (0) | 64 % (64) | 1 182 → 447 ms |
| qwen3-coder-next | GDN, MoE | 65 % (64) | 0 % (0) | 67 % (66) | 1 941 → 697 ms |
| qwen3.8-flash-next-mtp-nothink | GDN, MoE | 62 % (62) | 0 % (0) | 64 % (64) | 3 652 → 1 293 ms |
| **gpt-oss** | **attention + SWA, MoE** | **99 %** (99) | **4 %** (4) | **100 %** (100) | 2 131 → 65 ms |
| **laguna-s-2.1** | **attention SWA + globale, MoE** | **99 %** (99) | **0 %** (2) | **100 %** (100) | 4 756 → 138 ms |
| **deepseek-v4-flash** | **attention pure (MLA)** | **99 %** (99) | **0 %** (0) | **100 %** (100) | 7 262 → 109 ms |

Le passage au fork ne change rien au verdict : les écarts contre le paquet
tiennent dans un point de pourcentage (lfm2.5 et qwen3.5-9b gagnent 1 point à
l'identique, qwen3-coder-next 1 point partout), et la seule différence de
nature est laguna-s-2.1, qui passe de 2 % à 0 % sur l'édition. Les deux
variantes du 27B, jamais mesurées sur le paquet, se rangent avec les
architectures à état récurrent (62 / 0 / 64) : leur `swa-full` +
`swa-checkpoints` ne les en sort pas. Les prefill sont la nouveauté de cette
série : sur une requête identique, gpt-oss repaie 65 ms contre 2 131 à froid
(x33), deepseek 109 contre 7 262 (x67), alors que le 27B reste à 1 463 ms
contre 3 814 (x2,6 seulement) : le coût du tour suivant sur état récurrent se
lit directement là.

Deux enseignements. DeepSeek et gpt-oss tranchent le premier : les
architectures à état récurrent (GDN, conv) ne restaurent leur état qu'à un
checkpoint, pas au token près, et repaient ~37 % du prompt même sur une
requête identique ; sans état récurrent (attention pure, SWA comprise) tout
est servi. Le second vaut pour tous : une édition en amont du prompt, même
avec 2/3 de préfixe commun (au-dessus du seuil `slot-prompt-similarity 0.5`),
donne **0 %** partout, attention pure comprise, sauf `muse-glimmer-30b-dflash`,
ajouté le 16/09/2026, seule ligne du parc à rendre 34 % sur l'édition. Le cache de prompt du serveur
ne sert que les **continuations** (le prompt en cache doit être un préfixe
exact du nouveau) ; toute modification en amont repaie tout le contexte. En
boucle agentic, cela signifie : ne jamais réécrire l'historique (compaction,
tronquage de résultats d'outils) si on tient au cache.

## Chargement (--bench-load)

`--bench-load`, restart puis première requête. Le chiffre dépend d'abord de
l'état du cache de pages du noyau : fichier chaud (benché à l'instant) ou
relu depuis le disque. Série **fork strix-0007bc6, 13/09/2026**, parc complet
à la suite d'une campagne `--bench-cache` ; entre parenthèses la valeur de la
campagne du paquet Arch (b10433 à b10566, 21 au 28/08/2026) quand elle
existe. Les deux sections ajoutées le 16/09/2026 ont été mesurées ce
jour-là, même fork, et sont insérées à leur place. L'état du cache de pages
est déduit de la variation de `buff/cache` pendant le chargement.

| Modèle | Taille | Chargement + 1er token | TTFT à chaud | État du cache de pages |
|---|---|---|---|---|
| lfm2.5-2.6b | 2,7 Go | 0,9 s (0,5) | 26 ms (27) | chaud |
| lfm2.5-8b-a1b-nothink | 9,0 Go (+ drafter 0,36) | 1,7 s | 31 ms | non relevé (série du 16/09/2026) |
| qwen3.5-9b | 8,2 Go | 5,0 s (1,9) | 63 ms (65) | disque (+8 Go de cache de pages) |
| qwen3.8-27b | 17 Go | 3,6 s (4,4) | 129 ms (165) | chaud (~4,7 Go/s) |
| qwen3.8-27b-dflash-nothink | 17 Go (même GGUF) | 3,5 s | 131 ms | chaud |
| muse-glimmer-30b-dflash | 15,9 Go (+ drafter 3,0) | 3,5 s | 88 ms | non relevé (série du 16/09/2026) |
| ornith-1.5-35b-a3b | 21 Go | 8,3 s | 42 ms | disque (+20 Go de cache de pages) |
| qwen3-coder-next | 47 Go | 55,4 s (72) | 54 ms (406) | disque |
| gpt-oss | 59 Go | 91,3 s (91) | 85 ms (86) | disque |
| laguna-s-2.1 | 69 Go | 90,5 s (67) | 138 ms (173) | disque |
| qwen3.8-flash-next-mtp-nothink | 88 Go | 60,8 s (14,1 avec le fichier chaud) | 86 ms (86) | disque (sidecar MTP compris) |
| deepseek-v4-flash | 98 Go | 236,0 s | 133 ms | disque |

Une bascule LRU entre modèles moyens coûte quelques secondes si le fichier
est encore en cache de pages, une minute et plus s'il a été évincé (les
98 Go de DeepSeek évincent tout le reste). Les 88 Go de Flash-Next à 14,1 s
mesurés le 05/09 étaient un fichier entièrement en cache de pages : le même
chargement depuis le disque coûte 60,8 s, et DeepSeek, jamais mesuré sur le
paquet, tient les quatre minutes (~0,4 Go/s en IQ3_XXS sur quatre shards).
Le TTFT à chaud est stable d'une série à l'autre, sauf qwen3-coder-next qui
tombe de 406 à 54 ms.

Tailles : celles de cette table ne sont pas celles des autres tables du
document pour quatre modèles. Laguna 69 Go ici, 73 Go (73,4 Go de shards)
ailleurs ; Flash-Next 88 Go ici, 94 Go ailleurs ; DeepSeek 98 Go ici, 104 Go
de GGUF et « 115 Go de poids » ailleurs (le drafter DSpark pèse 10,9 Go) ;
Ornith 35B 21 Go ici, 22 Go ailleurs. Non tranché dans les sources : rien ne
dit quelle écriture est la bonne ni ce que chacune compte. Piste non vérifiée :
Gio contre Go (94 Go = 87,5 Gio, 73,4 Go = 68,4 Gio, 22 Go = 20,5 Gio ;
DeepSeek ne colle pas exactement).

## Enseignements

Tirés des campagnes du paquet Arch (août 2026), toujours valables sur le fork.

- La raison d'être du `--bench all` après chaque changement de moteur : b10433
  a cassé DeepSeek sur ROCm0 en silence, rien ne l'aurait vu sans mesure.
  ROCm0 est inutilisable sur DeepSeek V4 avec ce build (sortie dégénérée
  silencieuse, détectée depuis par le garde-fou de `timings.py`).
- Sur Qwen3-Coder-Next (GDN + MoE), chaque pas spéculatif porte un surcoût
  fixe de plusieurs centaines de millisecondes (état récurrent à sauvegarder et
  restaurer) : un petit draft divise le débit par deux malgré 98 %
  d'acceptance, seul un grand draft l'amortit, et le gain en refactor (+47 %)
  se paie en génération générique (-5 %). Le « régime sûr » n'existe pas sur
  cette arch.
- La marche Vulkan 8→9 (`mul_mat_vec_max_cols = 8`) vaut pour les denses comme
  pour les MoE ; le régime large (47) gagne sur les denses, le régime sûr (7)
  sur les MoE.
- L'optimum du n-max MTP dépend du device (4 sur ROCm0, 6 sur Vulkan0 pour le
  même GGUF).

## Choix du device (--bench-devices) : méthode et exemples datés

Commande retirée le 18/09/2026, avec `bench-devices.conf` : l'image n'expose
que `ROCm0` (« Campagne du moteur conteneurisé »). Tant qu'elle a existé, elle
tranchait entre Vulkan0 et ROCm0 par le temps d'un tour d'usage simulé
(2000 tokens de prefill froid, 3000 générés). Exemple du 16/08/2026 (paquet
Arch b10433, qwen3.8-27b-mtp-nothink) : ROCm0 gagnait le prefill (356 contre
307 t/s), Vulkan0 le décode (29,9 contre 21,8 t/s) et le tour (106,7 s contre
143,3 s). La méthode complète (commandes, déroulé, surcharge du profil, seuil
de 2 %, fichier de conf) est archivée : `docs/SECTIONS-RETIREES.md`, « Choix du device
(--bench-devices) ». Formule et limites du tour simulé, qui sert encore à la
main : ARCHITECTURE.md.

## Spéculation n-gram (--spec-ngram-tune) : méthode et mesures du 21/08/2026

Un `spec-type` peut être une liste (`ngram-map-k,draft-mtp`) : llama.cpp
essaie les implémentations dans son ordre de priorité (draftless d'abord) et
la première qui produit un draft gagne le pas de décode. `ngram-map-k`
construit sa table à partir du prompt entier : en édition agentic, où le
modèle recopie des blocs du fichier lu, un hit drafte jusqu'à `size_m`
tokens d'un coup, vérifiés dans un seul forward de batch `size_m + 1`.

Le bon `size_m` dépend donc de la forme de `t_forward(batch)` sur le device,
qui n'est pas une pente lisse : ggml change de noyau selon la taille du
batch (sur Vulkan, x2 entre batch 8 et 9, denses comme MoE). Les tailles
juste au-dessus d'une marche sont les pires. `--spec-ngram-tune` fait le
travail en deux temps :

1. courbe par `llama-bench`, service arrêté, balayage grossier puis
   raffinement automatique autour des sauts suspects ; sortie : un candidat
   « sûr » (sous la marche, ne peut pas perdre) et un « large » (amortit le
   coût fixe, gagne si les répétitions sont longues) ;
2. arbitrage réel : chaque candidat est écrit, le service redémarré, et
   `--spec-test` mesuré sur `prompts/spec-refactor.txt` (recopie de blocs
   exacts puis remplacement, la forme du oldString/newString d'opencode ;
   `spec-test.txt` écrit du neuf et ne produit aucun hit). Le gagnant va
   dans `spec-ngram.conf` ; à moins de 2 % d'écart, le plus petit.

Mesuré le 21/08/2026 sur Vulkan0 : les deux denses 27B d'alors, le Qwen3.8 Q4
et le Qwopus Q5 (retiré du parc depuis), retiennent 47 (+8 % et +16 % sur 7),
le 35B-A3B MoE retient 7 (sa pente sous la marche est trop raide pour amortir
un draft large). Un run en `spec-type` mixte est journalisé mais exclu de la
calibration α (k variable par forward) ; pour la même raison `--spec-tune`
mesure en `draft-mtp` seul le temps du réglage.

Pour explorer sans régler (autre GGUF, comparer ROCm0 et Vulkan0, modèle
sans MTP) : `tools/bench-spec-batch.sh` (voir README, « Outils »).
