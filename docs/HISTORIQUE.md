# Historique et campagnes de mesure détaillées

Archive des campagnes de mesure et des essais du dépôt, sortie du README le
13/09/2026 pour n'y garder que l'état courant. Le contenu est celui des
sections correspondantes du README, repris tel quel : chiffres, protocoles et
récits datés. L'état courant du parc (réglages retenus et perfs sur le fork)
reste dans `README.md`, section « Parc au 17/09/2026 ».

Trois séries de mesures cohabitent ici et ne se comparent jamais entre elles :
le paquet Arch (`bNNNNN`), le fork strix-llama.cpp (`strix-<commit>`) et, depuis
le 18/09/2026, l'image ROCm du service (`strix-<engine>+r<rocm>`).

## Flash-Next face à halogen-flash-server, micro-lot et n-gram (22/09/2026)

Journée de comparaison sur bigchuck, image `strix-8c1c282+r7dda3ac`, ROCm0,
Flash-Next servi par Signal-3.8-Flash-Next AP-Q4_K_XL, tête MTP shared,
reasoning off. En face, halogen-flash-server 0.11.4 (moteur spécialisé,
mono-modèle, checkpoint hgn w4b 5,53 bpw du Qwen de base, greedy par défaut,
`HALOGEN_ENABLE_THINKING=0`), lancé sur `:8029` d'après son `run-test.sh`,
jamais en même temps que le service. Poids différents des deux côtés : le mode
GGUF de halogen refuse les Q4_K, l'UD-IQ4_XS n'était plus sur le disque.

**Boucle agentic pi (`--bench-agentic`, 3 passes, même conteneur pi pointé sur
chaque serveur)**, 16/16 PASS des deux côtés : temps mur des cinq scénarios
35,5 s (llmsetup) contre 33,5 s (halogen) ; décode médian 48,5 contre 54,0 t/s
(+11 % halogen, en greedy contre sampling 0,7) ; prefill sans cache sur
l'appel froid 557 contre 613 t/s. Le `/metrics` de halogen n'a pas de compteur
de tokens en cache et ignore `?model=` : ses colonnes prompt, cache et prefill
du bench sont fausses par construction, seuls PASS, temps mur, généré et décode
se comparent.

**Boucle agentic omp (oh-my-pi 18.2.6 local, profil isolé, thinking off,
TODO list Laravel du TP « base de données » sur un projet fraîchement créé, un
run par configuration, 7/7 critères fonctionnels partout)** :

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

**Prefill à froid en profondeur** (requêtes directes, contenu unique,
`cache_prompt` false, deux requêtes par taille, `timings` de llama-server) :

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
de l'ub 16384 ici, la quant n'est pas ce qui manque. Rien de retenu : ub 4096
garde son arbitrage du 18/09 (cache de prompt restauré à 79 % en boucle
agentic), ngram-mod garde ses +10 % de décode en génération longue. Halogen
conserve 5 à 8 % de prefill à froid une fois llmsetup en ub 16384, au prix
d'un moteur mono-modèle sans vision ni sampling par défaut.

**Courbes rejouées le soir en mode EC `performance` vérifié** (l'après-midi
n'y était pas forcément), mêmes requêtes directes, médiane de deux requêtes
par taille, halogen relancé avec les mêmes options puis retiré :

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
mur des boucles agentic inchangés (cf. ci-dessus).

**Prefill 32 k du parc (`--bench-prefill 4000,32000 2`, nouvelle commande du
soir, `performance`, ubatch par défaut sauf Flash-Next), médiane de deux
passes saines, à froid :

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

Toutes les courbes descendent avec la profondeur (attention dense, ou GDN
avec une part d'attention), sauf Flash-Next, plate ou montante (attention
sparse QSA) : c'est l'arch, pas le moteur. DeepSeek V4 non joué (32 k = 4 min
par passe). La première série avait exclu LFM2.5 et Muse à tort : modèles à
réflexion, leurs 8 tokens partent dans `reasoning_content` et le garde-fou ne
regardait que `content` ; corrigé, rejoués.

**Suites dans le parc (22/09/2026, décision utilisateur)** : la section
`ornith-1.5-35b-a3b-parallel` est retirée (usage mono-utilisateur, plus aucun
multi-slot dans le parc ; son grand commentaire reste dans `lib/models.sh`
au-dessus de `ornith-1.5-35b-a3b-mtp`, seule section Ornith 35B désormais, et
son corps est consigné dans la note de retrait), et la variante
`qwen3.8-flash-next-mtp-nothink-large-ub` est créée : même section que la base
avec `ubatch-size` 16384, réservée aux gros prefills à froid, la base gardant
4096 pour les boucles d'outils. Qualifiée le soir même par
`tools/qualif-modele.sh` : justesse OK ; `--bench` 540 / 45,6 / 0,455 (prompt
court, un seul micro-lot) ; `--bench-cache` 0 % partout (même limite que la
base, prompt de 1,4 k) ; `--bench-agentic` 3 passes 15/15, décode 47 à 50 t/s,
temps mur et part de cache identiques à la base (les scénarios restent sous
7 k tokens, le grand micro-lot ne coûte qu'au-delà de ~16 k par tour).

## Le conteneur du service en uid:gid de l'utilisateur (22/09/2026)

Jusqu'ici `llama-server` tournait en root dans le conteneur (uid 0, avec les
groupes `video` et `render` en supplément), faute de directive `user:` dans
`runtime/docker-compose.yml`. Rien ne le demandait : les devices passent par
`group_add` (`/dev/kfd` et `renderD128` en rw pour `render`, `card0` pour
`video`), `~/models` est monté en lecture seule et le seul point inscriptible
(`CACHE_DIR`) appartient déjà à l'utilisateur. Le compose pose maintenant
`user: ${SVC_UID:?}:${SVC_GID:?}`, résolus par `regen_env` (`id -u`, `id -g`).
A/B dos à dos sur bigchuck, `--bench qwen3.8-flash-next-mtp-nothink 3` : root
664 t/s / 46,2 t/s / 0,455, uid 1000 669 / 46,1 / 0,455 ; justesse OK en 1000,
aucun fichier créé hors 1000. L'avertissement `failed to set process
priority 2 : Permission denied` (le `prio = 2` de l'en-tête du ini) est
présent dans les deux cas : hausser la priorité demande `CAP_SYS_NICE`, que
`cap_drop ALL` retire, root ou pas ; sans effet mesuré. A/B du soir même avec
`cap_add: SYS_NICE` (édition locale, non commitée) : en uid 1000 la capacité
ne devient pas effective (`CapEff` = 0, un non-root ne reçoit pas les
capacités ajoutées, `no-new-privileges` ferme l'autre voie), nice du
processus à 0, avertissement présent, `--bench` 663 / 46,1 contre 664 / 45,8
sans, `--bench-agentic` 15/15 et temps mur identiques des deux côtés. La clé
`prio` est donc RETIRÉE de l'en-tête `[*]` de `lib/ini.sh` (ini généré : une
ligne de moins, un commentaire de plus). Les 835 t/s de prefill
du 18/09 sur cette section ne se retrouvent ni en root ni en 1000 le 22/09 :
huit `--bench` propres (après restart, base comme variante large-ub, puis un
dernier après redémarrage complet de la machine, `performance` vérifié)
donnent 627 à 669 t/s, décode 45,3 à 47,0 partout. ÉLUCIDÉ par le journal :
le 18/09 une série de `--bench-cache` sur cette section a tourné de 06:42 à
07:06, et le `--bench` à 835 est parti 78 s après le dernier ; `--bench-cache`
lit `bench-context.txt`, le prompt même du `--bench`, donc ce prefill a été
servi en partie par le cache du serveur sans que le marqueur « * » se
déclenche (seuil de 10 % de `cache_n` en passe 1). Le run précédent du même
matin, à 01:41, donnait 604. Valeur retenue pour la table du parc : 627 à
669 t/s sur ce prompt court, la courbe longue (965 à 980 t/s à froid de 5 à
42 k tokens) restant la mesure de référence du prefill.

## `--models-max` sans plancher (21/09/2026)

Flash-Next injoignable sur bigchuck : plus de cinquante `cudaMalloc failed:
out of memory` à l'allocation de son buffer de poids (68,5 Go) pendant
qu'Ornith 35B MTP, contexte 1 M, tenait 74 Go (48,7 Go de GTT plus 25 Go
anonymes). Le routeur avait évincé lfm2.5, l'inactif le plus ancien, puis,
revenu à un seul résident sous `--models-max 2`, ne déchargeait plus rien :
même mécanique que les deux OOM du 13/09, mais l'allocation ROCm échoue
proprement au lieu de réveiller l'OOM killer, donc le service reste debout et
le modèle demandé échoue en boucle. Le plancher `models_max >= 2` hérité du
premier script rendait `preload.conf` vide inopérant. Retiré : préchargés + 1,
sans minimum ; `preload.conf` vide ⇒ `--models-max 1`, un seul résident, le
routeur décharge toujours avant de charger. Débloquage à chaud par
`POST /models/unload` du résident.

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
**un Dockerfile et un compose**.

Les deux révisions épinglées vivent désormais dans
`runtime/Dockerfile.rocm-strix`, en valeurs par défaut de `ARG ENGINE_REV` et
`ARG ROCM_SYSTEMS_REV`, avec en tête un bloc « Révisions épinglées » qui donne
la source de chacune, sa date d'épinglage et la marche à suivre pour la faire
bouger (`git ls-remote`, éditer l'`ARG`, commiter la raison,
`docker compose build`, `--restart`, nouvelle campagne). L'historique git de ce
fichier reste le journal des révisions, et le retour arrière consiste à y
remettre les anciennes valeurs ; la procédure décrite plus bas, par
`image.conf` et `--image-update`, ne vaut donc plus que pour les commits
antérieurs à ce jour.

Le `docker-compose.yml` généré porte un bloc `build` (contexte `runtime/` du
dépôt, `dockerfile: Dockerfile.rocm-strix`), et `--image-build` n'est plus
qu'un raccourci vers `docker compose build`. `docker compose up -d` ne
construit pas quand l'image existe, et `lib/compose.sh` refuse de toute façon
de générer le compose sans image, en renvoyant sur la commande de build : un
`--start` ne peut pas partir en compilation de quarante minutes par surprise.
L'étiquette des mesures (`_llama_build`) se lit maintenant par un `grep` sur
les deux `ARG` du Dockerfile, sans lancer de conteneur.

Ce qui est perdu, assumé : l'ancienne `:latest` n'est plus supprimée toute
seule après un build (elle perd son tag, `docker image prune` sans `-a` la
retire, à la main), et rien ne revérifie après coup que `/opt/strix/versions.txt`
correspond aux révisions demandées : ce que l'image contient se lit dedans,
quand on veut le savoir. Motif : pour deux fichiers, l'outillage coûtait plus
cher à lire et à maintenir que ce qu'il protégeait. Aucune image amont n'est
publiée pour ce Dockerfile (cf. l'entrée précédente), le build local reste donc
le seul chemin.

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
tableaux `--bench` ci-dessus. Ils seront rejoués par le dépôt après la bascule.
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
`ornith-1.5-35b-a3b-parallel` a été qualifiée le 18/09/2026, et
`lfm2.5-8b-a1b-nothink` retirée le même jour (cf. « lfm2.5-8b-a1b-nothink
retiré (18/09/2026) »).

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

## Résultats mesurés (bigchuck), campagnes du paquet Arch et du fork

Machine : AMD Ryzen AI MAX+ 395 (Radeon 8060S, 124 Go de mémoire unifiée),
CachyOS. Moteur courant : fork **strix-0007bc6** depuis le 12/09/2026 (voir
le README, « Moteur : fork strix-llama.cpp »), campagne `--bench` du parc entier les 12 et 13/09/2026, 3 passes,
Vulkan0. Les chiffres du paquet Arch (**b10433 / ggml 0.20.0** et
**b10548 / ggml 0.20.2** pour gpt-oss et Laguna, **b10566** pour ornith,
**b10809 / ggml 0.23.0** pour Flash-Next) restent entre parenthèses : ce sont
deux séries distinctes, qui ne se comparent pas à la décimale ; la colonne
build des journaux `logs/` fait foi. Les réglages de spéculation, les courbes
de batch, le cache de prompt et les temps de chargement des sections suivantes
datent des campagnes du paquet (21 au 28/08/2026) et n'ont pas été re-mesurés
sur le fork, sauf mention. Médianes hors première passe, 4 passes sauf
mention. Les lignes `spec-test.txt` (écriture d'un module
de zéro, meilleur cas MTP) et `spec-refactor.txt` (recopie de blocs exacts,
le cas n-gram) ne se comparent pas entre elles.

## Récapitulatif par modèle, campagne des 12, 13 et 15/09/2026 (fork strix-0007bc6)

| Modèle | GGUF | Device | Réglage retenu | Prefill t/s | Gen t/s | État |
|---|---|---|---|---|---|---|
| lfm2.5-2.6b | Q8_0 (2,7 Go) + drafter DSpark officiel Q8_0 (0,36 Go) | Vulkan0 (mesuré) | **draft-dspark 3**, parallel 1 (retenu le 15/09/2026) | **2875** (2279 au paquet b10433 le 21/08, réglage sans drafter à 4 slots ; 3048 sur le fork le 13/09 et 3602 le 15/09 avec ce même réglage) | **108,8** (acc. 0,50 ; 67,7 au paquet et 70,8 sur le fork le 13/09 sans drafter, 68,2 re-mesuré le 15/09, soit +59 % ; 122,3 en test isolé, x1,76) | fork strix-0007bc6, 15/09/2026 ; chargement 0,4 s, TTFT 27 ms (drafter compris) ; le prefill perd 20 % contre la variante, le drafter décodant aussi le prompt ; le réglage sans drafter à 4 slots (205 t/s agrégés à 4 requêtes, x3,06 ; chargement 0,5 s, TTFT 27 ms ; cache 62 / 63 %) a été gardé en variante `-parallel` la journée du 15/09/2026 puis retiré, cf. « Variantes -parallel retirées » |
| qwen3.5-9b | UD-Q6_K_XL (8,4 Go, GGUF MTP unsloth, dossier `qwen3.5-9b-mtp/`) | Vulkan0 (hérité : bench-devices.conf est indexé par dossier de GGUF) | **ngram-map-k 7 + draft-mtp 4**, min-hits 2, parallel 1 (retenu le 15/09/2026, tête MTP embarquée blk.32.nextn) | **745** (837 au paquet b10433 le 21/08, réglage sans spéculation à 4 slots sur le GGUF sans MTP ; 971 sur le fork le 13/09 et 791 le 15/09 avec ce même réglage) | **33,0** (acc. 0,58 ; 25,7 au paquet comme sur le fork le 13/09 sans spéculation, 25,5 re-mesuré le 15/09, soit +29 % ; 52,1 en test isolé, x2,1) | fork strix-0007bc6, 15/09/2026 ; cache 62 % au tour suivant, 0 % après édition, 64 % à l'identique, inchangé par le MTP ; multi-slot MTP inutilisable (np 4 n-max 1 = 18,2 t/s agrégés contre 80,8) ; le réglage sans spéculation à 4 slots (78,6 t/s agrégés à 4 requêtes, x3,06 ; chargement 1,9 s, TTFT 65 ms) a été gardé en variante `-parallel` la journée du 15/09/2026 puis retiré, cf. « Variantes -parallel retirées » ; **section retirée le soir du 15/09/2026**, remplacée par `ornith-1.5-9b-mtp-nothink` (cf. « qwen3.5-9b remplacé par Ornith-1.5-9B »), ses chiffres restent ici tels que mesurés |
| ornith-1.5-9b-mtp-nothink | Q8_0 (9,79 Go, GGUF fusionné tiers protoLabsAI, tête MTP nextn distillée) | Vulkan0 (hérité : le fork ne construit que Vulkan, `--bench-devices` non lancé) | **ngram-map-k 7 + draft-mtp 3**, min-hits 2, parallel 1 (retenu le 15/09/2026, tête MTP embarquée blk.32.nextn) | **827,9** (jamais mesuré au paquet ; 745 pour la section qwen3.5-9b remplacée, le même jour sur le même fork) | **39,5** (acc. 0,56 ; 33,0 pour la section remplacée, soit +20 % ; 52,9 au `--spec-ab` sur spec-refactor, acc. 0,85) | fork strix-0007bc6, 15/09/2026 ; remplace `qwen3.5-9b` (Terminal-Bench 2.1 47,0 contre 18,9, SWE-bench Verified 70,6 contre 53,2) ; n-max 3 et non 4 : seul le batch de 4 colonnes échappe au découpage mat-vec du fork (issue #50), 2 et 4 retombent à ~30 t/s en test isolé ; nothink obligatoire (thinking ON : 1200 tokens de raisonnement sans `</think>`, acceptance 0,42) |
| ornith-1.5-35b-a3b-parallel | Q4_K_M (22 Go) | Vulkan0 (mesuré : ROCm0 931 / 57,6) | parallel 4, sans spéculation | **1129** (974 au paquet b10566) | **73,3** (70,7 au paquet ; 136,8 agrégés à 4, x1,93) | fork strix-0007bc6, 13/09/2026 ; cache 62 % ; remplace les trois Qwen3.6-35B-A3B le 28/08/2026 ; **section renommée `-parallel` le 15/09/2026** (le suffixe dit l'usage, comme `-mtp`) : partout plus bas, les entrées datées et les mesures gardent le nom d'alors `ornith-1.5-35b-a3b`, qui reste aussi celui du dossier de GGUF |
| ornith-1.5-35b-a3b-mtp | idem (même GGUF) | Vulkan0 (hérité : bench-devices.conf est indexé par dossier de GGUF) | **ngram-map-k 7 + draft-mtp 4**, parallel 1 (tête MTP embarquée blk.40.nextn, découverte le 15/09/2026) | **1073** (jamais mesuré au paquet) | **76,2** (acc. 0,55 ; 73,3 pour la section de base sans spéculation) ; **113,2** (refactor, acc. 0,83) et **90,3** (générique, acc. 0,65) en test isolé | fork strix-0007bc6, 15/09/2026 ; section créée pour l'usage mono-utilisateur (+24 % en solo, 88,7 contre 71,6 t/s) ; la section de base reste le défaut agentic, elle bat la variante MTP en concurrence réelle (138 t/s agrégés à 4 requêtes contre 102) |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0 (mesuré) | **draft-dflash 7** (DFlash 2 z-lab, retenu le 13/09/2026 sur le fork ; spec-prefill essayé et retiré, cache de prompt à 0 %) | **349** (215 au paquet b10433 ; 289 → 183 à 32k en llama-bench) | **21,7** (acc. 0,35 ; 12,1 sans spéculation au paquet, +79 %) | fork strix-0007bc6, 13/09/2026 ; reasoning-budget 4096 (fork) ; spec-prefill lossy et incompatible avec le cache de prompt, perdant en agentic |
| qwen3.8-27b-dflash-nothink | idem | Vulkan0 (mesuré) | ngram-map-k 47 + **draft-dflash 7** (drafter DFlash 2 z-lab, 2,0 Go ; remplace la tête MTP le 13/09/2026 : le batch de vérification 8 se découpe en 4+4 et échappe au pire cas du découpage mat-vec) | **302** (359 en cache-type-v q8_0 le 13/09 ; 261 au paquet b10433) | **32,2** (acc. 0,625, cache-type-v f16 ; 30,3 acc. 0,595 en q8_0 le même soir, soit +6 % ; 32,6 acc. 0,595 en q8_0 le 13/09, autre série ; 29,5 acc. 0,65 au paquet, +9,2 % ; 26,6 acc. 0,59 en MTP n-max 6 sur le fork) ; **64,5** (refactor, acc. 0,67) et **35,9** (générique, acc. 0,70) en `--spec-ab` du 13/09 | fork strix-0007bc6, **17/09/2026** pour les chiffres de référence (cache-type-v f16, cf. « Campagne du 17/09/2026 ») ; DFlash 2 bat la tête MTP sur les deux prompts (+12 % en refactor, +18 % en générique) et annule le retrait de décode du fork ; réglage non mesuré sur le paquet Arch ; chargement 4,4 s |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go) + drafter DSpark unsloth Q8_0 (10,9 Go) | Vulkan0 (mesuré) | ngram-map-k 7 + **draft-dspark 3**, **parallel 1** (parallel 2 retenu le matin du 15/09/2026 puis annulé le soir même, cf. « Multi-slot et drafters » ; pas de tête MTP dans le GGUF, le 0731 ne publie qu'un drafter DSpark) | **196** (199 à parallel 1 le matin du 15/09 ; 205 en n-gram seul le 13/09 ; 110 au paquet b10433) | **28,8** (acc. 0,69, mesure du run à parallel 2 gardée comme référence chiffrée ; 28,9 acc. 0,68 à parallel 1, le réglage servi depuis le soir du 15/09, l'écart est dans le bruit ; 19,9 acc. 0,65 en n-gram seul sur le fork ; 12,3 au paquet) ; **39,0** agrégés à 2 requêtes (x1,16, 19,9 par requête, `--bench-parallel`) ; **38,7** (refactor, acc. 0,87) en `--spec-ab` contre 31,2 en n-gram seul, 35,6 en DSpark seul, 35,0 à n-max 2, 22,7 à n-max 5 | fork strix-0007bc6, 15/09/2026, plus gros gain de décode du parc (+135 % contre le paquet, +45 % contre le n-gram seul) ; ROCm0 inutilisable (b10433) ; cache 99 % (attention pure) ; reasoning-budget 6144 (fork) ; 115 Go de poids, la garde mémoire décharge lfm2.5 pour le charger |
| qwen3-coder-next | UD-Q4_K_XL (47 Go) + drafter DFlash z-lab Q8_0 (0,51 Go, conversion transmutator) | Vulkan0 (mesuré, ROCm0 exclu) | **draft-dflash 7** seul (retenu le 15/09/2026 ; remplace ngram-map-k 47, dont le compromis +47 % refactor / -5 % générique disparaît) | **727** (763 en ngram-map-k 47 le 13/09 ; 468 au paquet b10433) | **52,2** (bench, acc. 0,515 ; 48,7 acc. 0,27 en n-gram seul sur le fork ; 43,7 au paquet) ; **100,0** (refactor, acc. 0,92) et **70,5** (générique, acc. 0,70) en test isolé | fork strix-0007bc6, 15/09/2026 ; les n-grams par-dessus le drafter font retomber l'acceptance (0,92 → 0,82 en refactor) sans rien apporter : retirés ; ROCm0 répond « LAMPAMPAMP… » ; cache 64 % ; chargement 72 s depuis le disque |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE) | Vulkan0 (mesuré : ROCm0 219 / 31,5, juste lent) | ngram-map-k 7 | **599** (333 au paquet b10548) | **52,9** (bench, acc. 0,57 ; 51,9 au paquet) ; 59,8 (refactor, paquet) | fork strix-0007bc6, 13/09/2026 ; cache 99 % (attention, pas d'état récurrent) ; chargement 91 s depuis le disque ; drafter DFlash z-lab converti le 15/09/2026 mais refusé par le fork (biais d'attention, issue #61), le n-gram reste seul |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 (mesuré : ROCm0 320 / 23,6) | **ngram-map-k 7** seul (draft-dflash refusé par le mainline `wrong number of tensors; expected 76, got 69` **et** par le fork le 12/09/2026 : `failed to load draft model`) | **346** (255 au paquet b10548) | **29,6** (bench, acc. 0,80 ; 30,3 acc. 0,835 au paquet) ; 53,0 (refactor, +85 %, paquet) | fork strix-0007bc6, 13/09/2026 ; cache 99 % ; chargement 90,5 s depuis le disque (67 s au paquet) |
| qwen3.8-flash-next-mtp-nothink | UD-IQ4_XS (94 Go, MoE, GDN) | Vulkan0 (mesuré, ROCm0 exclu) | **ngram-map-k 7** + **draft-mtp 4** (confirmé, k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7) sur le fork (sidecar autonome Q8_0 renommé par `tools/mtp-rename-hc-head.py` ; le mainline ne sait toujours pas le charger, PR #28243) | **383** (414 en n-gram seul sur le fork ; 197 au paquet b10809) | **50,0** (bench mixte, acc. 0,87 ; 30,9 en n-gram seul sur le fork, 25,9 au paquet) ; **54,0** (refactor, +115 %) | fork strix-0007bc6, 12/09/2026 (le MTP n'existe pas sur le paquet) ; ROCm0 répond « LAMPAMPAMP… » ; cache 62 % ; chargement 60,8 s depuis le disque (14,1 s fichier chaud) |

Prefill et Gen : valeur du fork strix-0007bc6 en gras, valeur du paquet Arch
entre parenthèses. Médianes hors première passe ; « cache » = part du prompt
servie du cache pour tour suivant / édition au milieu / requête identique.
Détail et écarts en pourcentage ci-dessous.

Historique du parc : qwen3.8-27b-mtp-nothink renommé qwen3.8-27b-dflash-nothink
le 13/09/2026 : tête MTP remplacée par le drafter DFlash 2. Le même jour,
qwopus3.6-27b-coder-mtp-nothink a été retiré, plus utilisé ; ses mesures
restent dans `logs/`. Le soir même, la section thinking qwen3.8-27b a été
retirée à son tour (doublon sur le GGUF de qwen3.8-27b-dflash-nothink, moitié
moins vite : 21,7 contre 32,6 t/s), cf. « Qwen3.8-27B thinking : section
retirée le 13/09/2026 » ; les tables ci-dessous gardent sa ligne. Avant lui, les trois Qwen3.6-35B-A3B ont été remplacés
par ornith-1.5-35b-a3b le 28/08/2026. Le 15/09/2026, à l'issue de la campagne
multi-slot, ornith-1.5-35b-a3b-mtp est ajouté : même GGUF que la section de
base, tête MTP embarquée servie à un seul slot pour l'usage mono-utilisateur
(la base garde parallel 4 sans spéculation, meilleure en concurrence réelle).
C'est le deuxième cas du parc de deux sections sur un GGUF unique, après la
famille 27B ; `_preload_sanity` avertit si elles sont préchargées ensemble.
Toujours le 15/09/2026, la section `laguna-s-2.1` est retirée, jugée non utile
dans l'usage réel (cf. « Laguna-S-2.1 retiré (15/09/2026) ») ; les tables
ci-dessous gardent sa ligne et ses mesures, son dossier de GGUF devient
orphelin ; le 16/09/2026, même sort pour `gpt-oss` (cf. « gpt-oss retiré
(16/09/2026) »), les tables gardent aussi sa ligne. Dans la foulée, la section de base d'Ornith est renommée
`ornith-1.5-35b-a3b-parallel` : le nom dit ce qu'elle sert, comme `-mtp` et `-dflash-nothink` ailleurs, puisque
c'est la variante parallel 4 sans spéculation réservée à la concurrence. Seul
le nom de SECTION change : le dossier de GGUF reste `ornith-1.5-35b-a3b/` (donc
la ligne de `bench-devices.conf`, indexée par dossier, est intacte) et les
entrées datées ci-dessous gardent le nom d'alors. Une conséquence locale, sans
gravité : `logs/bench.log` et le comparateur `py/bench_compare.py` sont clés par
NOM DE SECTION (puis GGUF et device), donc le prochain `--bench` annoncera
« première mesure journalisée » au lieu de comparer aux runs des 28/08 et
13/09 ; les chiffres d'avant restent dans le journal sous l'ancien nom, et
renommer la colonne 2 de `logs/bench.log` à la main les rebranche (journal
local, non versionné : rien n'est fait ici).

Retraits de l'inventaire de fichiers (`KNOWN_FILES`, déplacés de
`lib/models.sh` le 13/09/2026) : retirés le 15/08/2026, remplacés par
qwen3.8-27b : qwen3.6-27b et qwen3.6-27b-mtp ; retirés le 15/08/2026 car
jamais utilisés : qwen3.5-2b, qwen3.5-9b-mtp, gemma-31b, gemma-12b ; retirés
le 28/08/2026, remplacés par ornith-1.5-35b-a3b : qwen3.6-35b-a3b et
qwen3.6-35b-a3b-mtp ; retiré le 15/09/2026 avec la variante
qwen3.5-9b-parallel (cf. « Variantes -parallel retirées ») : le GGUF SANS tête
MTP du 9b, `~/models/qwen3.5-9b/Qwen3.5-9B-UD-Q6_K_XL.gguf` (8,2 Go), homonyme
mais distinct de celui du dossier `qwen3.5-9b-mtp/` ; puis, le soir du
15/09/2026, avec la section `qwen3.5-9b` elle-même, remplacée par
`ornith-1.5-9b-mtp-nothink` (cf. « qwen3.5-9b remplacé par Ornith-1.5-9B ») :
ce second GGUF, `~/models/qwen3.5-9b-mtp/Qwen3.5-9B-UD-Q6_K_XL.gguf` (8,4 Go).
`./setup-llm.sh --cleanup` les purge.

Laguna S 2.1 (déplacé de `lib/models.sh` le 13/09/2026) : quants ré-uploadées
fin juillet 2026 par unsloth (« Fix rope/context metadata to 256K YaRN
(poolside config) » + fixes poolside), d'où un `./setup-llm.sh --update
laguna-s-2.1` nécessaire si le modèle avait été téléchargé avant.

Qwen3.8-Flash-Next (déplacé de `lib/models.sh` le 13/09/2026) : quants
converties AVANT le merge de la PR (15:16 contre 19:32 UTC), donc ré-upload
redouté ; il n'a pas eu lieu, vérifié le 04/09/2026, tailles des 3 shards
inchangées : 10 946 624 / 49 835 229 856 / 43 836 407 744 octets. Les commits
HF du 01/09 n'ont ajouté que le dossier `MTP/`.

## Paquet Arch contre fork : mesures

Comparaison des deux séries, faite le 13/09/2026 et complétée le 15/09/2026
(DSpark et parallel 2 de DeepSeek, drafter DFlash de Coder-Next, variante MTP
d'Ornith) ; les figures tirées de cette table (`docs/graphs/*.svg`) sont
restées dans le README.

Protocole `--bench` du dépôt (prefill de la passe 1 à froid, décode médian des
passes suivantes, acceptance médiane), sauf mention. Colonne « paquet » :
dernière valeur de la série `bNNNNN` dans `logs/bench.log` pour ce modèle.
Colonne « fork » : campagne `--bench` 3 passes, Vulkan0, `strix-0007bc6`, les
12 et 13/09/2026, parc entier, plus les trois sections re-réglées le
15/09/2026. Une colonne paquet vide = section jamais servie sous le paquet
(`docs/perfs.tsv` la laisse vide et les figures y écrivent « n/c »).

| Modèle | Paquet (prefill / gen) | Fork strix-0007bc6 (prefill / gen) | Écart prefill | Écart gen | Note |
|---|---|---|---|---|---|
| lfm2.5-2.6b | 2279 / 67,7 (b10433, 21/08, réglage sans drafter à 4 slots) | 2875 / 108,8 / acc. 0,50 (15/09, draft-dspark 3, parallel 1) | +26,2 % | +60,7 % | réglages différents des deux côtés : le paquet tournait sans drafter à 4 slots, le fork sert le DSpark à un slot depuis le 15/09/2026. Sur le même fork, ce réglage sans drafter donnait 3048 / 70,8 le 13/09 et 3602 / 68,2 re-mesuré le 15/09 sous la variante `-parallel` (retirée le soir même) ; contre elle : décode +59 %, prefill -20 %, le drafter DSpark décodant aussi le prompt. Le comparateur de `--bench` annonce « prefill 3651 -> 2875 RÉGRESSION » : il compare par nom de section sans savoir que le réglage a changé, et la variante retrouve 3602 le même jour. Test isolé du 15/09 (2 passes, spec-test / spec-refactor) : sans spéculation 69,6 t/s ; draft-dspark n-max 3 = **122,3** (acc. 0,39 à 0,83), n-max 5 = 110,2, n-max 9 = 124,6 (acc. 0,19 à 0,69) ; n-max 3 retenu pour son acceptance et son batch de vérification de 4 colonnes. `--bench-load` du 15/09, drafter compris : 0,4 s, TTFT 27 ms |
| qwen3.5-9b | 837 / 25,7 (b10433, 21/08, GGUF sans MTP, sans spéculation, 4 slots) | 745 / 33,0 / acc. 0,58 (15/09, ngram-map-k 7 + draft-mtp 4, parallel 1) | -11,0 % | +28,4 % | GGUF ET réglage différents des deux côtés : le paquet tournait sur le GGUF sans tête MTP, sans spéculation, à 4 slots. Sur le même fork, ce réglage donnait 971 / 25,7 le 13/09 et 791 / 25,5 re-mesuré le 15/09 sous la variante `-parallel` (retirée le soir même) ; contre elle : décode +29 %, prefill -5,8 %. Le comparateur annonce « prefill 993 -> 745 RÉGRESSION » alors que le GGUF ET le réglage ont changé, et la variante ne rend elle-même que 791 le 15/09 contre 993 le 13/09 : l'essentiel est de la dispersion entre journées. Test isolé du 15/09 (2 passes) : sans spéculation 25,3 t/s ; MTP seul n-max 2 = 34,2, n-max 4 = 45,7, n-max 6 = 40,8 ; ngram-map-k 7 min-hits 2 + draft-mtp 4 = **52,1** (42,4 générique, 61,8 refactor), soit x2,1 en test isolé contre x1,29 au `--bench`, dont le prompt est générique. `--bench-cache` du 15/09 : 62 / 0 / 64 %, soit exactement les valeurs du 21/08 sans spéculation |
| ornith-1.5-9b-mtp-nothink | jamais mesuré au paquet | 827,9 / 39,5 / acc. 0,56 (15/09, ngram-map-k 7 + draft-mtp 3, parallel 1) | n/c | n/c | section créée le 15/09/2026 en remplacement de `qwen3.5-9b` (Ornith-1.5-9B Q8_0, tête MTP tierce protoLabsAI). Contre la section remplacée, mesurée le même jour sur le même fork (745 / 33,0 / acc. 0,58) : prefill +11 %, décode +20 %. Test isolé du 15/09 (2 passes, spec-test / spec-refactor) : sans spéculation 23,6 / 23,3 ; draft-mtp 2 = 28,4 / 30,2 ; **draft-mtp 3 = 45,3 / 51,3** ; draft-mtp 4 = 29,9 / 33,3 ; ngram 7 min-hits 2 + draft-mtp 3 = 44,7 / 52,9. Courbe non monotone, seul le batch de 4 colonnes est rapide : découpage mat-vec du fork (issue #50). `--spec-ab` du même jour sur le service : le n-gram vaut +4,5 % sur spec-refactor (52,89 contre 50,62 en MTP seul), il est gardé |
| ornith-1.5-35b-a3b-parallel | 974 / 70,7 (b10566, 28/08) | 1129 / 73,3 (13/09) | +15,9 % | +3,7 % | sans spéculation des deux côtés ; mesures faites sous l'ancien nom `ornith-1.5-35b-a3b` |
| ornith-1.5-35b-a3b-mtp | jamais mesuré (section créée le 15/09/2026) | 1073 / 76,2 / acc. 0,55 (15/09, ngram 7 + draft-mtp 4) | n/c | n/c | variante mono-utilisateur du même GGUF : +24 % en solo contre la section de base (88,7 contre 71,6 t/s), mais perdante en concurrence (np 2 agrégé 75,7 soit x0,83, np 4 agrégé 102,1 soit x1,12, contre 138 t/s à np 4 sans spéculation) — d'où deux sections plutôt qu'un réglage unique |
| qwen3.8-27b (thinking) | 215 / 12,1 (b10433, 21/08) | 349 / 21,7 / acc. 0,35 (13/09, draft-dflash 7, reasoning_effort medium) | +62,3 % | +79,3 % | réglage différent des deux côtés : le paquet tournait sans spéculation, le fork avec le drafter DFlash 2. Le comparateur du dépôt affiche « prefill 759 → 349 régression » : les 759 t/s du 12/09 à 23:15 portaient `spec-prefill-p` 0,30, option retirée depuis (cache de prompt à 0 %) ; 349 est la première mesure du réglage réellement servi, ce n'est pas une régression. Référence sans spéculation sur le paquet : bench.log 02/09 (b10621) 239 / 12,13 ; `--spec-test` du 13/09 : 24,5 t/s contre 12,3 sans |
| qwen3.8-27b-dflash-nothink | 261 / 29,5 / acc. 0,65 (b10433, 21/08) | 359 / 32,6 / acc. 0,595 (13/09, réglage retenu : ngram 47 + draft-dflash 7) | +37,5 % | +10,5 % | le décode du fork passe au gain net avec le drafter DFlash 2. Sur l'ancien réglage MTP n-max 6, le même fork donnait 360 / 26,6 / 0,59, soit -9,8 % de décode : DFlash 2 gagne +22,6 % sur cette base. Ce seul écart de décode négatif du parc **s'expliquait** par le découpage des mat-vec batchés du fork (colonnes 4/2/1, restreint à q8_0 et q6_K par sa PR #27 ; le UD-Q4_K_XL porte 110 tenseurs q8_0 et 56 q6_K), à son pire cas au batch de vérification 7 = n-max 6 + 1, découpé en 4+2+1. llama-bench du 13/09 (Vulkan0, `-b 8 -ub 8 -r 3`) : pp7 68,9 t/s contre 74,4 avec `GGML_VK_MMV_NO_SPLIT=1` et 74,5 au paquet b10809 (-7,4 %), pp5 54,2 contre 56,9 (-4,7 %), pp4 47,8 contre 47,7 (aucune pénalité). Le réglage du fork n'est plus celui du paquet : **ngram 47 + draft-dflash n-max 7** (drafter DFlash 2 z-lab), qui bat la tête MTP sur les deux prompts en `--spec-ab` du 13/09 (4 passes, décode médian hors 1re passe). Sur spec-refactor.txt : 64,5 t/s acc. 0,67 contre 57,6 / 0,71 en MTP n-max 4 et 53,8 / 0,67 en n-max 6 ; spec-test.txt : 35,9 / 0,70 contre 30,5 / 0,65 en MTP n-max 4 (draft-dflash seul : 47,0 / 0,96 en refactor, 37,0 / 0,77 en générique). Le batch de vérification vaut alors 8, découpé en 4+4 : le pire cas du découpage est contourné, ce que le `--bench` du 13/09 confirme (32,6 t/s) |
| qwen3.8-flash-next-mtp-nothink | 197 / 25,9 / acc. 0,75 (b10809, 05/09) | 414 / 30,9 / acc. 0,80 en n-gram seul avec `ngram-on-disk` (12/09) | +110,2 % | +19,3 % | à réglage égal (n-gram seul) ; sur spec-refactor.txt le paquet fait 54,0 en n-gram seul |
| qwen3.8-flash-next-mtp-nothink (n-gram + draft-mtp 4) | impossible sur le paquet | 383 / 50,0 / acc. 0,87 (12/09) | +94,4 % contre le paquet en n-gram seul | +93,1 % contre le paquet en n-gram seul | le MTP n'existe pas sur le paquet (sidecar refusé) ; `--spec-tune` draft-mtp seul k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7 ; `--spec-test` mixte 48,8 acc. 0,86 |
| qwen3-coder-next | 468 / 43,7 (b10433, 21/08) | 727 / 52,2 / acc. 0,515 (15/09, draft-dflash 7 seul) | +55,3 % | +19,5 % | réglage différent des deux côtés : le paquet tournait en ngram-map-k 47, le fork sert depuis le 15/09/2026 le drafter DFlash z-lab (GGUF communautaire transmutator, Q8_0 de 0,51 Go, arch dflash, block_size 16, target_layers [4,12,24,36,44]). Sur le même fork, en n-gram seul, le 13/09 donnait 763 / 48,7 / 0,27 : le drafter ajoute +7,2 % de décode et double l'acceptance pour -4,6 % de prefill (il décode aussi le prompt). Test isolé du 15/09 (2 passes, spec-test / spec-refactor) : ngram 47 = 45,2 / 48,7 ; draft-dflash 15 = 43,5 / 65,9 ; **draft-dflash 7 = 70,5 / 100,0** (acc. 0,70 / 0,92) ; ngram 47 + draft-dflash 7 = 67,9 / 104,6 (acc. 0,65 / 0,82) — les n-grams coûtent de l'acceptance sans gain net, retirés. n-max 7 = batch de vérification 8, la dernière taille du chemin vectoriel de ggml-vulkan ; n-max 15 (batch 16) retombe. `--bench-parallel` du 15/09 : solo 73,0 t/s, np 2 agrégé 64,7 (x0,86), np 4 agrégé 68,5 (x0,92) — aucun np ne bat le solo, parallel 1 maintenu |
| gpt-oss | 333 / 51,9 (b10548, 21/08) | 599 / 52,9 / acc. 0,57 (13/09) | +79,9 % | +1,9 % | décode neutre ; le fork journalise une acceptance n-gram là où le paquet n'en donnait pas |
| laguna-s-2.1 | 255 / 30,3 / acc. 0,835 (b10548, 21/08) | 346 / 29,6 / acc. 0,80 (13/09) | +35,7 % | -2,3 % | dans le bruit de mesure ; DFlash refusé par le fork comme par le paquet (12/09) |
| deepseek-v4-flash | 110 / 12,3 (b10433, 21/08) | 196 / 28,8 / acc. 0,69 (15/09, ngram 7 + draft-dspark 3 ; mesure faite à parallel 2, réglage servi depuis le soir du 15/09 : parallel 1, 199 / 28,9 / 0,68) | +78,4 % | +134,1 % | plus gros gain de décode du parc ; en n-gram seul le fork faisait 205 / 19,9 / 0,65 le 13/09 (+61,8 %), le drafter DSpark d'unsloth (sidecar de 10,9 Go, pas de tête MTP dans le GGUF) ajoute +45 % de décode pour -3 % de prefill (le drafter décode aussi le prompt). `--spec-ab` du 15/09 sur spec-refactor.txt (4 passes) : n-gram seul 31,2 t/s acc. 0,91, DSpark seul n-max 3 35,6 / 0,94, n-gram + DSpark n-max 3 **38,7** / 0,87, n-max 2 35,0 / 0,89, n-max 5 22,7 / 0,48 (l'acceptance s'effondre au-delà de 3, comme mesuré par unsloth sur B200) ; reasoning-budget 6144 posé le 13/09 (seuil non atteint sur le test fait). **parallel 2 le 15/09/2026, annulé le soir même** (cf. « Multi-slot et drafters ») : `--bench-parallel` du même jour donne 1 requête 33,6 t/s et 2 requêtes 39,0 t/s agrégés (x1,16, 19,9 par requête) ; la campagne multi-slot mesurait solo 25,2 / 26,6 / 25,9 t/s à np 1 / 2 / 4 et agrégé 32,4 (x1,22, acc. 0,63) à np 2 contre 20,8 (x0,80) à np 4. Seul cas du parc où le multi-slot paie, parce que le batch de vérification vaut 2 x (3 + 1) = 8 colonnes, pile le seuil `mul_mat_vec_max_cols` de ggml-vulkan (16 à np 4). Conséquences : ctx-size 131072 est un pool partagé, soit 65536 par slot, et la mémoire ne bouge pas (112 Go résidents à np 1, 2 et 4) ; sur une requête isolée le deuxième slot ne coûte rien (196 / 28,8 contre 199 / 28,9) |

Deux valeurs de la colonne paquet diffèrent au chiffre près de la table du parc
d'origine, qui arrondissait un autre run du même jour : qwen3-coder-next 468 au
lieu de 457, laguna-s-2.1 255 au lieu de 247. C'est `logs/bench.log` qui fait foi.

Bilan. Le fork gagne le prefill sur tout le parc, de +16 % (qwen3.5-9b,
ornith) à +110 % (Qwen3.8-Flash-Next), sans exception. Il gagne nettement le
décode partout où la spéculation change de régime : DeepSeek V4 +135 % (+62 % en n-gram seul, le reste par le drafter DSpark),
qwen3-coder-next +12 %, Qwen3.8-Flash-Next dont le MTP n'existe pas sur le
paquet +93 %, qwen3.8-27b-dflash-nothink avec le drafter DFlash 2 +11 % contre
le paquet et +23 % contre la tête MTP sur le fork, et qwen3.8-27b thinking
+79 % avec le même drafter contre un paquet sans spéculation. Ailleurs il est
neutre, le décode des petits modèles, de gpt-oss et de Laguna bougeant de moins
de 5 % dans un sens ou dans l'autre, soit la dispersion normale des passes :
depuis le passage du 27B nothink au drafter DFlash 2, plus aucun écart négatif
ne subsiste, et le fork apporte en plus le sidecar MTP de Flash-Next et les
clés que le paquet ne sait pas charger.

Trois mesures du fork n'entrent pas dans le tableau. Le draft adaptatif
(`spec-draft-adaptive`) rend 2 % de moins que le draft fixe sur les deux 27B MTP
d'alors, qwen3.8-27b-mtp-nothink et le qwopus depuis retiré
(`--spec-ab` du 12/09), il n'est pas retenu. Le speculative prefill sur
qwen3.8-27b passe la boucle agentic (`--bench-agentic` 11/11 PASS, prefill
345 t/s) mais met `--bench-cache` à 0 % même sur requête identique : retiré.
Côté mémoire, `ngram-on-disk` charge Qwen3.8-Flash-Next en 72 Go en instance
seule (79 Go via le routeur, avec lfm2.5 et le sidecar MTP) au lieu d'environ
100, à prefill et décode inchangés.

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

Les deux séries ne se comparent pas à la décimale : builds et jours différents,
et les passes MTP sont dispersées. Détail des runs dans `logs/bench.log` et
`logs/spec-tests.log` sur bigchuck.

## Multi-slot et drafters (15/09/2026)

Campagne `--bench-parallel` puis `--bench-agentic` du 15/09/2026 (fork
strix-0007bc6, Vulkan0), qui remplace la croyance « MTP impose parallel 1 » :
elle était fausse, mais le résultat mesuré lui donne souvent raison.

Ce qui en ressort, dans l'ordre :

1. **Un slot vide ne coûte rien en solo.** Sur une requête isolée, monter
   `parallel` de 1 à 2 ou 4 ne change ni le débit ni la mémoire résidente
   (deepseek-v4-flash : 199 / 28,9 à np 1 contre 196 / 28,8 à np 2, 112 Go
   résidents dans les deux cas). Le coût du multi-slot est ailleurs : le
   `ctx-size` est un pool partagé, donc chaque slot en retranche sa part.
2. **L'agrégé se prédit par `parallel x (n-max + 1)` contre le seuil des
   8 colonnes** de `mul_mat_vec_max_cols` de ggml-vulkan. Sous ou pile sur le
   seuil, le multi-slot peut payer : DeepSeek à np 2 vaut 2 x (3 + 1) = 8 et
   rend x1,22 agrégé ; au-dessus il s'effondre, np 4 valant 16 et rendant
   x0,80. Même loi sur qwen3-coder-next (n-max 7, donc 16 à np 2 et 32 à np 4 :
   x0,86 et x0,92, aucun np ne bat le solo) et sur ornith-1.5-35b-a3b-mtp
   (x0,83 à np 2, x1,12 à np 4, contre x1,93 sans spéculation).
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
retiré le soir même (paragraphe suivant) ;
qwen3-coder-next et deepseek-v4-flash restent à parallel 1. Règle générale qui
s'en dégage, écrite en tête de `lib/models.sh` : un modèle spéculatif ne gagne
au multi-slot que si `parallel x (n-max + 1)` reste inférieur ou égal à
8 colonnes, et le MTP n'y gagne de toute façon pas. Seul interdit technique
qui demeure : le mmproj reste incompatible avec un drafter.

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
confondre avec ces deux variantes retirées), seul multi-slot du parc conservé : 2 à 3 slots occupés
au journal du service, x1,93 en salves de 4 requêtes et x2,33 à 3 boucles
agentic, pour aucune perte en solo. Sa variante `-mtp` (parallel 4 côté base,
parallel 1 côté MTP) reste elle aussi en place.

Ce que portaient ces deux variantes, gardé ici puisque les sections n'existent
plus :

- **lfm2.5-2.6b-parallel** : 4 slots, pas de drafter, même GGUF cible que la
  section principale (le DSpark n'étant simplement pas chargé), `ctx-size`
  131072 en pool partagé, donc 32768 par slot. Mesuré le 21/08/2026 (Vulkan0,
  b10433) : prefill 2279 t/s, décode 67,7 t/s ; `--bench-parallel` 4 requêtes
  = 205 t/s agrégés (x3,06) ; `--bench-load` 0,5 s (2,7 Go), TTFT 27 ms ;
  `--bench-cache` 62 % / 63 %, comme les GDN (autre tokenizer, même plafond :
  c'est l'état récurrent, conv ici). Le 13/09/2026 sur le fork
  (strix-0007bc6, `--bench` 3 passes) : 3048 / 70,8, soit +34 % de prefill
  contre le 21/08, mais `bench.log` du 02/09 (b10621) donnait déjà 2743 :
  l'essentiel vient du build. Re-mesuré le 15/09/2026 sous le nom `-parallel`
  (même fork) : 3602 / 68,2, l'ancien réglage retrouvé à 1,3 % près, ce qui a
  servi de témoin au prefill perdu par la section principale spéculée.
- **qwen3.5-9b-parallel** : 4 slots, pas de drafter, GGUF du repo unsloth SANS
  tête MTP (dossier `qwen3.5-9b/`, devenu orphelin par ce retrait, cf.
  « Retraits de l'inventaire de fichiers »), `ctx-size` 32768 en pool partagé,
  donc 8192 par slot ; toutes les autres clés étaient celles de la section
  principale (sampling, `n-predict`, `swa-full`, `ctx-checkpoints`). Mesuré le
  21/08/2026 (Vulkan0, b10433) : prefill 837 t/s, décode 25,7 t/s ;
  `--bench-parallel` 4 requêtes = 78,6 t/s agrégés (x3,06), 20 t/s par
  requête ; `--bench-load` 1,9 s (8,2 Go), TTFT à chaud 65 ms ;
  `--bench-cache` 62 % au tour suivant, 63 % à l'identique. Justesse OK
  (recopie) ; un calcul mental simple, lui, est raté (93 → 33) : tâches
  auxiliaires, pas de raisonnement. Le 13/09/2026 sur le fork : 971 / 25,7,
  prefill +16 %, décode identique au dixième. Re-mesuré le 15/09/2026 sous le
  nom `-parallel` : 791 / 25,5, décode identique au 13/09 mais prefill 20 %
  plus bas (993 dans `bench.log` ce jour-là) sans changement de réglage ni de
  GGUF : dispersion de plateforme, à garder en tête avant de lire un écart de
  prefill entre deux journées comme un effet de réglage.

La justification écrite alors pour les garder tenait en deux points, tous deux
caducs : « les 4 slots de tâches auxiliaires CONCURRENTES font tout l'intérêt
du 9b » (elles n'ont jamais eu lieu) et « le chemin MTP multi-slot du fork est
inutilisable » (18,2 t/s agrégés à np 4 contre 80,8 sans spéculation, cf.
point 3 ci-dessus). Ce second point reste vrai, mais il justifie le
parallel 1 de la section à drafter, pas l'existence d'une seconde section. De
même côté LFM2.5 : DSpark à np 2 respecte le seuil des 8 colonnes (2 x (3 + 1))
et ne rend pourtant que ~x1,1 agrégé pour un débit par requête divisé par deux
(mesure `tools/spec-isolate.sh NP=2` du 15/09/2026, 400 tokens, 2 salves :
solo 105 à 124 t/s, deux requêtes simultanées 120 à 136 t/s agrégés).

Conséquences pratiques du retrait : `docs/perfs.tsv` garde les colonnes paquet
de ces deux modèles sur les lignes `lfm2.5-2.6b` et `qwen3.5-9b` (2279 / 67,7
et 837 / 25,7) avec la mention « paquet sans drafter » dans la colonne réglage,
comme le fait la ligne deepseek, pour que les graphes gardent la comparaison
paquet contre fork sur ces deux modèles ; `preload.conf` et les autres `.conf`
locaux de bigchuck, indexés par nom de section, peuvent contenir des lignes
`*-parallel` devenues sans effet (à nettoyer à la main si elles gênent) ; et le
GGUF sans MTP du 9b devient orphelin, purgeable par `./setup-llm.sh --cleanup`.

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
| | | | ngram-map-k 7 + draft-dflash 7 | échec | | fork strix-0007bc6 (12/09/2026) : il revendique DFlash, mais son loader ne crée toujours aucun `attn_gate` — `common_speculative_init_result: failed to load draft model`, retour au n-gram seul |
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

Balayages `tools/bench-spec-batch.sh` du 21/08/2026 au 05/09/2026, paquet Arch.

Sur Vulkan0 (`tools/bench-spec-batch.sh`, reps=5) :

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

`tools/bench-depth.sh` du 16/08/2026, paquet Arch b10433.

`tools/bench-depth.sh`, 27B Q4, KV q8_0, sans spéculation, reps=2 :

| Device | depth 0 | depth 16k | depth 32k | Tour simulé 0 → 32k |
|---|---|---|---|---|
| Vulkan0 | 289 pp / 12,25 tg | 222 / 11,83 | 183 / 11,50 | 252 s → 272 s (x1,08) |
| ROCm0 | 352 pp / 11,97 tg | 263 / 10,73 | 214 / 9,54 | 256 s → 324 s (x1,26) |

ROCm0 prefill plus vite à vide mais décode moins bien, et se dégrade deux
fois plus vite en profondeur : Vulkan0 gagne à toutes les profondeurs sur ce
GGUF, et l'écart se creuse en contexte long (le régime agentic).

## Concurrence, cache de prompt, chargement

`--bench-parallel` des 21 et 28/08/2026, paquet Arch (b10433 et b10566).

`--bench-parallel`, spec-test.txt, 400 tokens, 2 salves :

| Modèle | parallel | 1 requête | 4 requêtes | Lecture |
|---|---|---|---|---|
| qwen3.5-9b | 4 | 25,7 t/s | 78,6 t/s agrégés (x3,06), 20,1 t/s par requête | le `parallel 4` des tâches auxiliaires est justifié |
| lfm2.5-2.6b | 4 | 67,4 t/s | 205 t/s agrégés (x3,06), 52 t/s par requête | idem |
| ornith-1.5-35b-a3b | 4 | 70,7 t/s | 136,8 t/s agrégés à 4 (x1,93), 35 t/s par requête | le MoE s'amortit moins bien qu'un dense : chaque requête route ses propres experts (le Qwen3.6 qu'il remplace faisait x1,43 à 2) |

## Boucle agentic réelle (--bench-agentic)

pi 0.84.3 en conteneur, appel froid puis 3 passes de 5 scénarios de tool calls en direct sur `:8009`, médianes, bigchuck, b10566, 28/08/2026 :

| Modèle | Verdict | Scénario | Mur | Prompt (part du cache) | Généré | Prefill | Décode |
|---|---|---|---|---|---|---|---|
| ornith-1.5-35b-a3b | 16/16 | froid (prompt système de pi) | 1,5 s | 1 523 tok (66 %) | 2 | 820 t/s | n/s |
| | 3/3 | write+bash+read | 2,8 s | 4 833 tok (98 %) | 133 | 228 t/s | 72,3 t/s |
| | 3/3 | edit | 4,1 s | 6 605 tok (91 %) | 181 | 518 t/s | 71,0 t/s |
| | 3/3 | création module + tests | 11,0 s | 5 876 tok (89 %) | 666 | 525 t/s | 70,9 t/s |
| | 3/3 | bug sans toucher au test | 7,2 s | 9 447 tok (91 %) | 361 | 508 t/s | 71,0 t/s |

Lecture : le décode en boucle d'outils (71 t/s) rejoint le `--bench` (70,7) ; le cache sert 89 à 98 % tant que la conversation ne fait que s'allonger, et le préfixe de pi survit d'un conteneur à l'autre (cache-ram). La variance est celle du modèle : le scénario 5 a pris 18 s (1 069 tokens, trois tours) sur une passe et 7 s sur les deux autres ; le tout premier run du jour l'avait fait en 49 s et 65 k tokens de prompt cumulés (28 % repayés, décode apparent 8 t/s : le coût GDN quand les tours s'enchaînent).

## Réglages n-gram alternatifs

`--spec-ab` du 21/08/2026, paquet Arch b10433.

`--spec-ab`, 27B, n-max 6, spec-refactor.txt, 4 passes :

| Variante | Gen t/s | Acceptance | Lecture |
|---|---|---|---|
| base (ngram-map-k 47, min-hits 2, draft-mtp 6) | **56,1** | 0,80 | +18 % sur le même réglage n-gram avec n-max 4 (47,4) : le n-max 6 profite aussi au mode mixte |
| min-hits 1 | 55,8 | 0,80 | équivalent, 2 gardé |
| ngram-map-k4v 47, min-hits 2 | 44,9 | 0,91 | -20 % : drafte moins souvent malgré une meilleure acceptance |

## Cache de prompt (--bench-cache)

Série du fork strix-0007bc6, 13/09/2026, valeurs du paquet Arch (b10433,
21 au 28/08/2026) entre parenthèses.

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
contre 3 814 (x2,6 seulement) — le coût du tour suivant sur état récurrent se
lit directement là.

Deux enseignements. DeepSeek et gpt-oss tranchent le premier : les
architectures à état récurrent (GDN, conv) ne restaurent leur état qu'à un
checkpoint, pas au token près, et repaient ~37 % du prompt même sur une
requête identique ; sans état récurrent (attention pure, SWA comprise) tout
est servi. Le second vaut
pour tous : une édition en amont du prompt, même avec 2/3 de préfixe commun
(au-dessus du seuil `slot-prompt-similarity 0.5`), donne **0 %** partout,
attention pure comprise, sauf `muse-glimmer-30b-dflash`, ajouté le 16/09/2026,
seule ligne du parc à rendre 34 % sur l'édition. Le cache de prompt du serveur ne sert que les
**continuations** (le prompt en cache doit être un préfixe exact du nouveau) ;
toute modification en amont repaie tout le contexte. En boucle agentic, cela
signifie : ne jamais réécrire l'historique (compaction, tronquage de
résultats d'outils) si on tient au cache.

## Chargement (--bench-load)

Série du fork strix-0007bc6, 13/09/2026, valeurs du paquet Arch (b10433 à
b10566, 21 au 28/08/2026) entre parenthèses.

`--bench-load`, restart puis première requête. Le chiffre dépend d'abord de
l'état du cache de pages du noyau : fichier chaud (benché à l'instant) ou
relu depuis le disque. Série **fork strix-0007bc6, 13/09/2026**, parc complet
à la suite d'une campagne `--bench-cache` ; entre parenthèses la valeur de la
campagne du paquet Arch (b10433 à b10566, 21 au 28/08/2026) quand elle
existe. Les deux sections ajoutées le 16/09/2026 ont été mesurées ce
jour-là, même fork, et sont insérées à leur place. L'état du cache de pages est déduit de la variation de `buff/cache`
pendant le chargement.

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

## Enseignements

Tirés des campagnes du paquet Arch (août 2026), toujours valables sur le fork.
Premier d'entre eux, la raison d'être du `--bench all` après chaque changement
de moteur : b10433 a cassé DeepSeek sur ROCm0 en silence, rien ne l'aurait vu
sans mesure.

Sur Qwen3-Coder-Next (GDN + MoE), chaque pas spéculatif porte un surcoût
fixe de plusieurs centaines de millisecondes (état récurrent à sauvegarder et
restaurer) : un petit draft divise le débit par deux malgré 98 % d'acceptance,
seul un grand draft l'amortit, et le gain en refactor (+47 %) se paie en
génération générique (-5 %). Le « régime sûr » n'existe pas sur cette arch.

La marche Vulkan 8→9 (`mul_mat_vec_max_cols = 8`) vaut pour
les denses comme pour les MoE ; le régime large (47) gagne sur les denses,
le régime sûr (7) sur les MoE ; l'optimum du n-max MTP dépend du device
(4 sur ROCm0, 6 sur Vulkan0 pour le même GGUF) ; ROCm0 est inutilisable sur
DeepSeek V4 avec ce build (sortie dégénérée silencieuse, détectée depuis par
le garde-fou de `timings.py`).

## Passage au fork (12 et 13/09/2026) : apports, essais retirés, dépannage

Récit du passage du paquet Arch au fork strix-llama.cpp, tel qu'il figurait
dans la section « Moteur » du README.

Ce que le fork apporte aujourd'hui côté réglages (détail et mesures dans les
commentaires de `lib/models.sh`) : `ngram-on-disk` laisse la table n-gram de
28,8 Go de Qwen3.8-Flash-Next sur disque (72 Go de mémoire utilisée au lieu
d'environ 100, à prefill et décode identiques, mesuré le 12/09/2026), les
`reasoning-budget-*` plafonnent la réflexion des modèles thinking, et
`spec-draft-adaptive` dimensionne le draft sur l'acceptance mesurée (--spec-ab du
12/09/2026 sur les 27B MTP : 2 % sous le draft fixe, non retenu). Il
apporte aussi le **speculative prefill** (`spec-prefill*`) : un petit modèle
estime l'importance des tokens du prompt et le gros n'en prefille qu'une
fraction (`spec-prefill-p`, 0,30 par défaut). Contrairement au MTP et aux
n-grams, c'est **lossy** — les tokens élagués sont perdus — et, mesuré le
12/09/2026 sur qwen3.8-27b, il neutralise le cache de prompt (0 % même sur une
requête identique) : retiré, perdant en boucle agentic. Le graphe MTP `qwen4exp` et
le drafter externe (`spec-draft-model`) viennent du fork également, ce qui
débloque le MTP de Qwen3.8-Flash-Next (jalon 2), à une condition : le sidecar
MTP d'unsloth doit d'abord être **renommé** par `tools/mtp-rename-hc-head.py`
(voir README, « Outils »). Le fork lit le mixeur des hyper-connexions sous
`output_hc_{norm,down,up}`, unsloth le range sous
`blk.<n>.nextn.hc_head_*` (convention de la PR mainline #28243) : sans
renommage, `check_tensor_dims: tensor 'output_hc_norm.weight' not found` et le
modèle ne charge pas du tout. Le renommage est automatique au `--setup`
(`derive_gguf` dans `lib/models.sh`). Le DFlash du fork ne débloque rien sur
Laguna S 2.1, refusé comme sur le paquet Arch (12/09/2026), mais il accepte le
drafter DFlash 2 officiel de Qwen3.8-27B (z-lab, 2,0 Go) : il y remplace la
tête MTP depuis le 13/09/2026 (`qwen3.8-27b-dflash-nothink`, +12 à +18 % de
décode selon le prompt).

Une contrepartie mesurée : le fork découpe les mat-vec batchés en colonnes
(4/2/1), ce qui coûte jusqu'à -7,4 % sur un batch de 7 (voir la ligne du
27B dans « Paquet Arch contre fork »). `GGML_VK_MMV_NO_SPLIT=1` annule la
pénalité, mais désactive le découpage pour **tout** le parc, Flash-Next
compris, qui lui en profite : non retenu. Le réglage par modèle (n-max qui
évite le pire cas, ou le drafter DFlash 2 à n-max 7) suffit. Signalé en amont
le 13/09/2026 : [issue #50](https://github.com/halo-box/strix-llama.cpp/issues/50)
(table llama-bench, contournement DFlash 2) ; si un correctif arrive, re-comparer
la tête MTP du 27B contre DFlash 2 après `--update-fork`.

Détail du changelog de `--update-fork`, au 12/09/2026 : le fork resynchronise
le llama.cpp officiel par blocs (0007bc6 → 6548035 = 210 commits, dont 209
d'amont), d'où le tri : les titres listés sont ceux des commits propres au fork
(merges de PR compris, 40 lignes au plus), le reste n'étant qu'un compte,
« Commits llama.cpp amont intégrés : 209 (amont : b10809 → b10950) ». Le tri
demande un remote `upstream` sur
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp), ajouté au clone à
la première mise à jour s'il manque ; sans lui (pas de réseau), la liste
complète est affichée avec un avertissement.

### Mise à jour du fork vers 654803517 (13/09/2026) : régression, retour à 0007bc6

Premier `--update-fork` réel : 0007bc6 vers 654803517, soit la PR de sync #47
du fork (206 commits llama.cpp amont, b10891 vers b10917) et aucun changement
propre au fork. `--bench all` sur ce commit (série strix-6548035, garde mémoire
exercée trois fois sans OOM) : neuf modèles au niveau de la série précédente,
mais les deux sections du 27B en DFlash 2 perdent 18 à 23 % de décode à
acceptance égale (nothink 26,7 t/s contre 32,6, thinking 16,8 contre 21,7).
`--spec-ab` sur le nouveau build : sans spéculation 11,9 t/s (inchangé), donc
le forward à batch 1 n'a pas bougé ; DFlash seul 29,4 contre 37,0 : c'est le
chemin de vérification batché qui ralentit. llama-bench, `-b 8 -ub 8 -r 3` :

| cols | fork 0007bc6 | fork 654803517 | 654803517 + NO_SPLIT | paquet b10809 |
|---|---|---|---|---|
| 4 | 47,8 | 48,2 | 48,1 | 47,4 |
| 5 | 54,2 | 51,2 | 53,6 | 56,7 |
| 7 | 68,9 | 58,0 | 61,5 | 74,3 |
| 8 | 79,3 | 51,7 | 53,5 | 80,5 |

Le batch 8 devient plus lent que le batch 7, indépendamment du découpage.
Suspects parmi les commits amont intégrés : « vulkan: small M matrix
optimizations for qwen » (#28457) et « vulkan: tune mat-vec rows for batched
inference on Strix Halo » (#27909). Retour à 0007bc6 le jour même (pp7 68,5,
pp8 77,9 retrouvés), fork épinglé par `fork.conf` tant que l'amont n'est pas
corrigé ; à re-tester à chaque `--update-fork` (le changelog s'affiche sans
rien faire tant que l'épinglage est en place). Signalé en amont le 13/09/2026 :
[issue #51](https://github.com/halo-box/strix-llama.cpp/issues/51) (table des
quatre bras, commits candidats, bisect proposé).

### Drafter DFlash de gpt-oss : converti, refusé par le fork (15/09/2026)

Le drafter officiel de gpt-oss-120b, `z-lab/gpt-oss-120b-DFlash` (safetensors,
1,57 Go), se convertit sans avertissement avec le `convert_hf_to_gguf.py` du
fork (classe `DFlashModel`, `conversion/qwen.py` l. 641), à condition de lui
passer les métadonnées HF de la cible avec `--target-model-dir` (tokenizer et
config d'`openai/gpt-oss-120b`, sans poids, 27 Mo) : GGUF Q8_0 de
847 145 664 octets, 123 tenseurs, `dflash.block_size 10`,
`dflash.target_layers [2, 10, 18, 26, 34]`, `fc.weight [14400, 2880]`, sans
`token_embd` ni `output` (empruntés à la cible). La commande exacte est dans le
bloc `gpt-oss` de `lib/models.sh`.

`llama-server` le refuse : `done_getting_tensors: wrong number of tensors;
expected 123, got 91`, puis `failed to load draft model`. 123 - 91 = 32 = les
8 couches x 4 biais d'attention du drafter (`attn_q.bias`, `attn_k.bias`,
`attn_v.bias`, `attn_output.bias`), que sa config annonce par
`attention_bias = true` et qui sont tous non nuls (absmax 4,16 sur
`attn_output`) : les jeter à la conversion donnerait un autre modèle. La
dorsale Qwen3 de `src/models/dflash.cpp` (l. ~211-232 au commit 0007bc6) ne
crée aucun tenseur de biais et le graphe n'en applique aucun (projections
`build_lora_mm` nues l. ~708-710, `build_attn(..., layer.wo, NULL, ...)`
l. ~727-728, même forme côté encodeur l. ~625-629). Le même loader accepte les
DFlash sans biais déjà servis ici, DFlash 2 du 27B, DFlash de Coder-Next,
DSpark de Liquid et de DeepSeek V4 Flash : c'est un manque, pas un refus.

Décision : ne pas patcher le moteur. Signalé en amont le 15/09/2026,
[issue #61](https://github.com/halo-box/strix-llama.cpp/issues/61)
(reproduction, les 32 tenseurs, correctif proposé en trois points, 15 à
20 lignes : création des quatre biais en `TENSOR_NOT_REQUIRED`, `ggml_add` des
biais Q/K/V avant les `reshape_3d`, `layer.bo` à la place du `NULL` dans les
deux `build_attn`). Si elle est corrigée : reconvertir et essayer `draft-dflash`
à `spec-draft-n-max 9` (= `block_size - 1`) contre le n-gram servi aujourd'hui,
re-mesuré le même jour par `tools/spec-isolate.sh` à 51,0 t/s (spec-test,
acceptance 0,49) et 51,3 t/s (spec-refactor, acceptance 0,71). Pour situer
l'enjeu, z-lab annonce en amont une acceptance de 3,7 à 5,4 tokens à block 10
et 1,3x à 1,9x de bout en bout sous SGLang et vLLM sur H200.

Suite : le modèle a quitté le parc le 16/09/2026 (cf. « gpt-oss retiré
(16/09/2026) »), la PR #62 reste ouverte pour les autres drafters à biais.

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

Le commentaire du bloc retiré, tel quel (connaissance à conserver :
reasoning-budget, speculative prefill essayé et retiré, DFlash 2 sur du
raisonnement), puis le corps de la section tel qu'il était émis dans
`models.ini`. Pour ravoir la section : remettre ce bloc dans `lib/models.sh`
avec `parallel 1` et sans la précharger en même temps que la nothink (même
GGUF, 16 Go chargés deux fois).

```
Qwen3.8-27B thinking — reasoning_effort medium (défaut modèle = xhigh), tool-calling jinja
Mesuré --bench 21/08/2026 (Vulkan0, b10433) : prefill 215 t/s, décode 12,1 t/s
  (cohérent avec les 12,3 t/s bruts de llama-bench, cf. profondeur ci-dessus).
reasoning-budget-* : options du fork strix-llama.cpp (cf. lib/fork.sh) —
  plafond de tokens de réflexion, avertissement doux à 70 % du budget, et
  128 tokens de grâce pour finir le paragraphe avant la coupure dure. Le
  modèle thinking est le seul à en avoir l'usage ici (12 t/s : un raisonnement
  qui part en boucle coûte des minutes). Budget à affiner à l'usage.
  ⚠ Le paquet Arch b10809 connaît reasoning-budget mais PAS -enable,
  -soft-ratio ni -grace-tokens : une clé inconnue fait échouer le démarrage du
  routeur entier (vérifié le 12/09/2026). Revenir au paquet impose de retirer
  ces lignes à la main puis --preload : le dépôt ne gère pas deux moteurs, il
  refuse seulement de démarrer (FORK_ONLY_KEYS, lib/fork.sh).
spec-prefill : option du fork strix-llama.cpp (port de la PR upstream #27692,
  docs/speculative-prefill.md). Un petit modèle estimateur prefille le prompt,
  décode quelques tokens de lookahead, et son attention sur le prompt sert à
  ne garder que la fraction p des chunks les mieux notés — le gros modèle ne
  prefille que ceux-là. LOSSY : les tokens élagués sont PERDUS, ce n'est pas
  une accélération sans perte comme le MTP ou les n-grams.
  Mesuré PAR LE FORK sur ce modèle exact (Qwen3.8-27B-UD-Q4_K_XL, Vulkan0,
  médiane de 3) : TTFT 12 992 → 5 199 ms à p 0,30 sur 3 131 tokens (x2,5), et
  décode inchangé (11,1 à 11,6 t/s sur toutes les cellules). Le gain monte
  avec la longueur du prompt (x2,35 à 1,5 k, x2,81 à 12 k).
  p 0,30 = défaut de l'option et valeur raisonnable selon la doc ; 0,15 tient
  encore un needle, en dessous de 0,10 c'est risqué quand les indices sont
  répartis dans le contexte.
  ⚠ Ne JAMAIS poser spec-prefill-ctx, -device ou -ngl seuls : chacun met
  enabled = true en effet de bord et le serveur sort sur « speculative prefill
  enabled but no draft model was provided ».
  MESURÉ ICI le 12-13/09/2026 (strix-0007bc6, Vulkan0, p 0,30) et NON RETENU :
  --bench : prefill 759 t/s (n=1365, contre 239 sans, l'estimateur garde
    401 tokens sur 1361), décode 12,2 t/s inchangé.
  --bench-agentic 2 passes : 11/11 PASS, prefill 345 t/s, décode 12,3.
  --bench-cache : 0 % de cache sur les quatre requêtes, MÊME la requête
    identique (1,7 s de prefill à chaque fois). Le prefill spéculatif
    court-circuite le cache de prompt : en boucle agentic à contexte
    croissant, tout est repayé à chaque tour (12 772 tokens re-prefillés
    au scénario edit). Perdant contre un cache à 62 % ; les trois clés sont
    retirées, à ré-essayer si le fork rend le cache compatible.
  L'estimateur (Qwen3.5-2B UD-Q4_K_XL, seul rôle de ce GGUF) n'est donc plus
    téléchargé depuis le 13/09/2026 : sa déclaration a été retirée, --cleanup
    purge ~/models/qwen3.5-2b. Le ré-essai imposerait de la remettre.
  ⚠ Clés inconnues du paquet Arch (vérifié le 12/09/2026 : aucune ligne
  spec-prefill dans /usr/bin/llama-server --help) : FORK_ONLY_KEYS, lib/fork.sh.
DRAFTER DFLASH 2 (z-lab, cf. la déclaration QWEN38_27B_DFLASH_PATH) sur la
  section thinking : --spec-ab du 13/09/2026 (strix-0007bc6, spec-test.txt,
  3 passes, reasoning_effort medium) : sans spéculation 12,3 t/s ;
  draft-dflash seul n-max 7 = 24,5 t/s (+99 %, acceptance 0,42) ;
  ngram-map-k 47 + draft-dflash = 24,3 (le n-gram n'apporte rien sur du
  raisonnement, il est laissé de côté ici). Distribution cible préservée
  par DFlash. Non mesuré sur le paquet Arch.
Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
  349 t/s, décode 21,7 t/s, acceptance 0,35, contre 215 / 12,1 sans
  spéculation au paquet b10433, soit +62 % de prefill et +79 % de décode.
  Le comparateur du dépôt affiche « prefill 759 -> 349 régression » : les
  759 t/s du 12/09 étaient mesurés avec spec-prefill-p 0,30, option retirée
  depuis (cache de prompt à 0 %) ; 349 est la première mesure du réglage
  réellement servi, ce n'est pas une régression.
```

```ini
[qwen3.8-27b]
model                = ~/models/qwen3.8-27b/Qwen3.8-27B-UD-Q4_K_XL.gguf
ctx-size             = 131072
cache-ram            = 4096
temp                 = 1.0
top-k                = 20
top-p                = 0.95
min-p                = 0.0
chat-template-kwargs = {"reasoning_effort":"medium"}
cache-type-v         = q8_0
reasoning-budget-enable       = true
reasoning-budget              = 4096
reasoning-budget-soft-ratio   = 0.7
reasoning-budget-grace-tokens = 128
spec-type            = draft-dflash
spec-draft-model     = ~/models/qwen3.8-27b/Qwen3.8-27B-DFlash2-Q8_0.gguf
spec-draft-n-max     = 7
jinja                = true
parallel             = 1
swa-full             = true
ctx-checkpoints      = 128
```

## qwen3.5-9b remplacé par Ornith-1.5-9B (15/09/2026)

Section `qwen3.5-9b` (Qwen3.5-9B UD-Q6_K_XL du repo MTP unsloth, dossier
`qwen3.5-9b-mtp/`, `ngram-map-k 7 + draft-mtp 4`, 745 t/s de prefill et 33,0 de
décode au `--bench` du 15/09/2026) retirée du parc le 15/09/2026 et remplacée,
au même créneau, par `ornith-1.5-9b-mtp-nothink` : Ornith-1.5-9B Q8_0 (9,79 Go)
avec tête MTP tierce (`protoLabsAI/Ornith-1.5-9B-MTP-GGUF`, GGUF fusionné trunk
officiel ornith-ai + tête nextn distillée par protoLabsAI, `blk.32.nextn.*`),
même architecture llama.cpp `qwen35` (GDN).

Raison : à VRAM comparable, les benchmarks de l'éditeur donnent Ornith-1.5-9B
très au-dessus de Qwen3.5-9B sur tout ce que ce créneau sert, Terminal-Bench 2.1
(harnais Claude Code) 47,0 contre 18,9, SWE-bench Verified 70,6 contre 53,2,
NL2Repo 32,4 contre 16,2, GPQA 86,4 contre 81,7. Le débit est du même ordre
(test isolé du 15/09/2026, mêmes prompts, quants différentes : 44,7 / 52,9 t/s
contre 42,4 / 61,8), le remplacement se joue donc sur la qualité. Il n'y a ni
régression ni défaut de mesure derrière ce retrait : les chiffres du 9b Qwen
restent bons, les tables de ce document gardent ses lignes, mesurées à l'époque,
comme `logs/`.

Le GGUF `~/models/qwen3.5-9b-mtp/Qwen3.5-9B-UD-Q6_K_XL.gguf` (8,4 Go) n'est plus
déclaré : il devient orphelin de `KNOWN_FILES`, rien n'a été supprimé sur la
machine, `./setup-llm.sh --cleanup` le purgera (le GGUF SANS tête MTP du même
modèle, `~/models/qwen3.5-9b/`, était déjà orphelin depuis le retrait de la
variante `-parallel` le matin même). Pour ravoir la section : remettre la
déclaration de téléchargement, le commentaire et le corps ci-dessous dans
`lib/models.sh`.

Le commentaire du bloc retiré, tel quel (connaissance à conserver : incident du
GGUF homonyme écrasé, effondrement du MTP multi-slot, part du cache inchangée
par la spéculation), puis le corps de la section tel qu'il était émis dans
`models.ini`.

```
GGUF MTP (repo unsloth séparé), seul GGUF du 9b déclaré depuis le 15/09/2026 :
le GGUF sans tête MTP (repo unsloth/Qwen3.5-9B-GGUF, dossier qwen3.5-9b/) n'est
plus déclaré depuis le retrait de la variante qwen3.5-9b-parallel, il est donc
orphelin (cf. le commentaire de KNOWN_FILES en tête de fichier).
Les deux portent le MÊME NOM DE FICHIER (Qwen3.5-9B-UD-Q6_K_XL.gguf,
8 987 439 456 octets contre 8 756 929 760), d'où un DOSSIER SÉPARÉ
qwen3.5-9b-mtp/ par la convention <clé> / <clé>-mtp du dépôt : les deux
fichiers ne peuvent pas cohabiter.
⚠ Incident du 15/09/2026 : un `hf download` de ce repo lancé dans
  ~/models/qwen3.5-9b/ a ÉCRASÉ le GGUF courant (même nom) ; il a été
  retéléchargé à l'identique. Ne jamais télécharger ce fichier ailleurs que
  dans son dossier.
Métadonnées (15/09/2026) : qwen35.nextn_predict_layers = 1, block_count 33
(32 + la couche MTP), tenseurs blk.32.nextn.* : tête MTP EMBARQUÉE, donc
spec-type = draft-mtp sans sidecar ni spec-draft-model.
bench-devices.conf est indexé par dossier de GGUF : qwen3.5-9b-mtp n'y a pas
de ligne, la section hérite donc du défaut [*] Vulkan0 : non mesuré par
--bench-devices, à faire si le sujet revient (le fork est Vulkan seul).
download_hf qwen3.5-9b-mtp "unsloth/Qwen3.5-9B-MTP-GGUF" \
  QWEN35_9B_MTP_PATH="Qwen3.5-9B-UD-Q6_K_XL.gguf"

Qwen3.5-9B : dense 9B — tâches auxiliaires courtes (résumés, titres, routage)
Depuis le 15/09/2026 cette section sert le GGUF MTP en mono-slot spéculé. Le
  réglage multi-slot qui était ici (GGUF sans MTP, parallel 4, sans
  spéculation) a d'abord été gardé en variante qwen3.5-9b-parallel le même
  jour, puis RETIRÉ le soir même : aucune concurrence n'a jamais été observée
  sur ce modèle au journal du service, et le drafter gagne en solo. Décision
  utilisateur : pas de parallel si perte de perf (mesures et détail de la
  variante dans docs/HISTORIQUE.md, « Variantes -parallel retirées »).
chat-template-kwargs : thinking COUPÉ. Note : depuis les mises à jour de
  template unsloth, les Qwen3.5 Small (0.8B/2B/4B/9B) sont nothink PAR DÉFAUT —
  le kwargs est devenu redondant mais reste en ceinture-bretelles (un futur
  re-download de template ne doit pas réactiver le thinking en douce).
n-predict 1024 : borne dure, aucune tâche auxiliaire n'a besoin de plus —
  plus jamais de génération qui court jusqu'au plafond de contexte
ctx-size 32768 inchangé, mais à parallel 1 le slot unique dispose de TOUT le
  ctx-size (le pool n'est plus divisé par 4) : 32768 redevient le contexte
  d'UNE requête, contre 8192 par slot du temps du réglage à 4 slots.
Spéculation MTP, test isolé du 15/09/2026 (fork strix-0007bc6, Vulkan0,
  hors service, np 1, 2 passes, 1200 tokens, spec-test.txt et
  spec-refactor.txt) : GGUF courant sans spéculation 25,3 t/s ; GGUF MTP
  n-max 2 = 34,2 (acceptance 0,92 à 0,99), n-max 4 = 45,7 (0,83 à 0,97),
  n-max 6 = 40,8 ; ngram-map-k 7 min-hits 2 + draft-mtp n-max 4 = 52,1
  (42,4 sur spec-test.txt, 61,8 sur spec-refactor.txt). RETENU : la liste
  n-gram + MTP à n-max 4, soit x2,1 sur le réglage sans spéculation.
  n-max 4 : batch de vérification 5, sous les 8 colonnes de ggml-vulkan
  (cf. en-tête) ; n-max 6 (batch 7) retombe, c'est le découpage 4+2+1 du fork.
  Le n-gram est gardé parce que le 9b sert aussi des reformulations et des
  résumés où le prompt se ré-émet mot pour mot.
parallel 1, et le multi-slot MTP est INUTILISABLE ici (même journée, même
  fork) : np 4 n-max 1 = 18,2 t/s agrégés contre 80,8 sans spéculation,
  np 2 n-max 1 = 24,0. L'effondrement tient même à n-max 1, donc à des
  batches de 4 et 8 colonnes qui restent sous le seuil de ggml-vulkan : ce
  n'est PAS le découpage mat-vec, c'est un cas nouveau du chemin MTP
  multi-séquences du fork (speculative.cpp, vectorisé par séquence mais
  éprouvé par aucun test amont, cf. en-tête) : à verser à l'issue #50.
  C'est la justification du parallel 1 ici : sur ce modèle le multi-slot ne
  se paie qu'en abandonnant le drafter, et le drafter vaut plus.
cache-reuse 0 : contrainte des sections spéculatives, posée explicitement.
Mesuré le 15/09/2026 TEL QUE SERVI (fork strix-0007bc6, Vulkan0, --bench 3
  passes, GGUF MTP) : prefill 745 t/s, décode 32,96 t/s, acceptance 0,58.
  Contre le réglage sans spéculation re-mesuré le même jour sous la variante
  -parallel depuis retirée (791 / 25,5) : décode +29 %, prefill -5,8 % (le drafter
  MTP décode aussi le prompt). Le x2,1 du test isolé devient x1,29 ici : le
  test isolé tournait sur spec-test.txt et spec-refactor.txt, où le prompt se
  ré-émet mot pour mot et où les n-grams paient ; le prompt de --bench est
  générique. Le comparateur de --bench annonce « RÉGRESSION » sur le prefill
  (993 le 13/09 -> 745) : il compare par nom de section, alors que le GGUF ET
  le réglage ont changé ; la variante ne rend elle-même que 791 le 15/09
  contre 993 le 13/09, donc l'essentiel de cet écart est de la dispersion
  entre journées, pas la spéculation.
--bench-cache du 15/09/2026 : 62 % au tour suivant, 0 % après édition en
  amont, 64 % sur requête identique : exactement les valeurs du 21/08 sans
  spéculation. Le GGUF MTP et cache-reuse 0 ne changent rien à la part du
  cache : elle est bornée par l'état récurrent (restauration au dernier
  checkpoint), pas par la spéculation.
Préchargement : preload.conf est indexé par NOM DE SECTION, donc la ligne
  `qwen3.5-9b` existante précharge désormais CETTE version (GGUF MTP). Tant
  que la variante -parallel a existé (journée du 15/09/2026), les deux
  ensemble déclenchaient l'avertissement « <clé> ET <clé>-mtp » de
  _preload_sanity (lib/preload.sh, dérivé du DOSSIER de GGUF : qwen3.5-9b et
  qwen3.5-9b-mtp) et c'était voulu, 2 x ~8,8 Go des mêmes poids. Avec une
  seule section le cas ne se présente plus.
llama_model qwen3.5-9b "
model                = $QWEN35_9B_MTP_PATH
ctx-size             = 32768
cache-ram            = 2048
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
chat-template-kwargs = {\"enable_thinking\":false}
n-predict            = 1024
parallel             = 1
cache-reuse          = 0
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 4
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
swa-full             = true
ctx-checkpoints      = 128"
```

```ini
[qwen3.5-9b]
model                = ~/models/qwen3.5-9b-mtp/Qwen3.5-9B-UD-Q6_K_XL.gguf
ctx-size             = 32768
cache-ram            = 2048
temp                 = 0.7
top-k                = 20
top-p                = 0.8
min-p                = 0.0
chat-template-kwargs = {"enable_thinking":false}
n-predict            = 1024
parallel             = 1
cache-reuse          = 0
spec-type            = ngram-map-k,draft-mtp
spec-draft-n-max     = 4
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
swa-full             = true
ctx-checkpoints      = 128
```

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
les purgera. Pour ravoir la section : remettre les deux déclarations de
téléchargement (`download_hf_shards` sur `unsloth/Laguna-S-2.1-GGUF` pour la
quant, `download_hf` sur `poolside/Laguna-S-2.1-GGUF` pour le drafter), le
commentaire et le corps ci-dessous dans `lib/models.sh`, avec sa bannière de
groupe : `; --- Laguna S 2.1 : arch 'laguna', servie par le fork
strix-llama.cpp ; sur le paquet Arch de secours, b10087 minimum (vérifié
jusqu'à b10548) ---`.

Le commentaire du bloc retiré, tel quel (connaissance à conserver : contrat
DFlash poolside refusé par les deux moteurs, rope/YaRN 256K, le plus gros gain
n-gram jamais mesuré ici), puis le corps de la section tel qu'il était émis dans
`models.ini`.

```
Laguna S 2.1 (poolside) — MoE 118B (8B actifs), agentic coding, shards UD-Q4_K_XL
73.4 Go / 3 shards.
(ré-upload de fin juillet 2026 absorbé, cf. docs/HISTORIQUE.md)
Alternative plus légère si la RAM est juste : UD-IQ4_XS (57.6 Go) — changer
  l'entrée en conséquence, le glob suit. (UD-Q4_K_S a été RETIRÉ du repo
  unsloth ; il ne reste en shards que UD-IQ4_XS, UD-Q3_K_XL, UD-Q4_K_XL et
  UD-Q5_K_XL.)
download_hf_shards laguna-s-2.1 "unsloth/Laguna-S-2.1-GGUF" \
  LAGUNA_S_PATH="UD-Q4_K_XL/Laguna-S-2.1-UD-Q4_K_XL-00001-of-00003.gguf"
Drafter DFlash officiel (poolside, 1B, 6 couches, block_size 16, embeddings
partagés avec la cible) : GGUF BF16 de 2,2 Go dans le repo poolside, pas
dans celui d'unsloth. Même dossier que le modèle, autre repo.
download_hf laguna-s-2.1 "poolside/Laguna-S-2.1-GGUF" \
  LAGUNA_DFLASH_PATH="laguna-s-2.1-DFlash-BF16.gguf"

Laguna S 2.1 — MoE 118B-A8B (poolside), agentic coding / long-horizon
48 couches en ratio 1:3 global/SWA (fenêtre 512) + softplus gating :
  pas de swa-full, l'ISWA laguna n'est pas l'implémentation Qwen.
ctx 262144 : les GGUF sont packagés pour 256K (metadata rope/YaRN fixée par
  unsloth fin juillet 2026 sur la config poolside). Le checkpoint est natif 1M
  mais il faut alors surcharger le rope au chargement :
    --ctx-size 1048576 --rope-scaling yarn --rope-scale 128 --yarn-orig-ctx 8192
  (dégradation qualité annoncée par poolside → on reste à 256K).
cache-reuse 0 : MoE + attention mixte, non testé avec le cache-reuse global.
cache-type-v q8_0 : précision V critique pour les diffs de code.
thinking activé par défaut (recommandé en agentic coding, avec preserved
  thinking côté client) — pour un modèle nothink, ajouter :
    chat-template-kwargs = {"enable_thinking":false}
Spéculation DFlash (drafter $LAGUNA_DFLASH_PATH, déclaré ci-dessus) :
  draft-dflash est en mainline (PR #22105, mergée le 28/06/2026), MAIS LE
  MAINLINE REFUSE CE DRAFTER. Mesuré 21/08/2026 (llama-cpp b10548, --spec-ab
  spec-type=draft-dflash;spec-draft-model=…;spec-draft-n-max=15 et 7) :
  « llama_model_load: error loading model: done_getting_tensors: wrong
  number of tensors; expected 76, got 69 », le serveur sort, le modèle ne
  charge pas. La model card poolside avait raison : le mainline « ships the
  generic DFlash framework » mais pas le contrat spécifique Laguna (7
  tenseurs d'écart), fork poolside/llama.cpp branche laguna requis, hors
  périmètre ici : ni le paquet Arch de secours ni le fork strix-llama.cpp ne
  portent ce contrat. Flags à réutiliser le jour où le mainline
  suit : --spec-type draft-dflash -md <drafter> --spec-draft-n-max 7 (bloc
  entraîné 16).
  Retours communauté sur le fork poolside : jusqu'à +30 tok/s.
  12/09/2026 : le fork strix-llama.cpp revendique DFlash (draft-dflash dans
  son --spec-type, loader src/models/dflash.cpp, DFlash2/DSpark compris),
  d'où le draft-dflash remis ci-dessous le 12/09, puis retiré le jour même
  (cf. VÉRIFIÉ ci-dessous) — MAIS LA LECTURE DU CODE DIT QUE ÇA
  VA ENCORE ÉCHOUER, et de la même façon : le contrôle de comptage est
  toujours là (« wrong number of tensors; expected %d, got %d »,
  src/llama-model-loader.cpp) et le loader DFlash du fork ne crée AUCUN
  blk.N.attn_gate — aucune trace d'attn_gate ni de laguna dans dflash.cpp.
  Or le drafter en porte un par couche : ses tenseurs (lus dans l'en-tête du
  GGUF) font 12 par couche sur 6 couches = 72, plus 4 hors blocs = 76, quand
  le loader générique n'en crée que 11 x 6 + 3 = 69. C'est exactement l'écart
  de 7 déjà mesuré.
  VÉRIFIÉ le 12/09/2026 sur strix-0007bc6, et la lecture du code avait raison :
  refus identique au paquet Arch (« common_speculative_init_result: failed to
  load draft model »), le modèle ne charge plus du tout via le routeur. Retour
  au NGRAM SEUL le jour même : draft-dflash, spec-draft-model et
  spec-draft-n-max retirés du corps ci-dessous. Le drafter reste déclaré et
  sur disque (2,2 Go) pour le jour où un moteur crée les attn_gate : il
  faudra le fork poolside/llama.cpp branche `laguna`, ou un DFlash mainline
  qui connaisse le contrat Laguna.
Candidat ROCm sur le papier (gros prefill agentic) : invalidé par la mesure
  ci-dessous.
Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10548, sans
  spéculation, 3 passes) : 247 pp / 28,6 tg contre ROCm0 320 / 23,6 (tour
  simulé 113 s contre 134), les deux justes — le schéma des denses.
Courbe t_forward(batch) Vulkan0 (21/08, reps=5) : batch 1 = 33 ms, 8 = 95
  (x2,9), 16 = 282, 32 = 384, 48 = 540 ms (x16,5). Référence sans
  spéculation sur spec-refactor : 28,7 t/s.
Spéculation n-gram : ngram-map-k size_m 7, RETENU par --spec-ngram-tune
  21/08/2026 (b10548, Vulkan0, spec-refactor.txt, 4 passes) : sans
  spéculation 28,7 t/s ; size_m 7 = 53,0 t/s (+85 %, le plus gros gain
  n-gram mesuré ici) ; size_m 47 = 39,9 t/s (+39 %). Courbe raide (x2,9 au
  batch 8, x16,5 au batch 48) et pourtant le petit draft double presque le
  débit : MoE à 8B actifs, le forward de batch 8 coûte peu en absolu (95 ms)
  et le décode de base est lent (33 ms/token), les hits rapportent gros. Pas
  d'état récurrent (SWA + global), donc pas de surcoût fixe par pas.
--bench (bench-task, peu de répétitions) avec n-gram 7 : 30,3 t/s contre 28,6
  sans (+6 %) — pas de revers hors refactor, contrairement à Qwen3-Coder-Next.
  --bench-cache : 99 % au tour suivant, 100 % à l'identique (pas d'état
  récurrent). --bench-load : 90,5 s depuis le disque (13/09/2026, fork ; 67 s
  au paquet le 21/08), TTFT à chaud 138 ms (173 ms au paquet).
Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
  346 t/s, décode 29,6 t/s, acceptance 0,80 : prefill +36 %, décode -2 %
  contre le paquet (255 / 30,3 / 0,835, b10548), soit le bruit de mesure.
```

```ini
[laguna-s-2.1]
model            = ~/models/laguna-s-2.1/UD-Q4_K_XL/Laguna-S-2.1-UD-Q4_K_XL-00001-of-00003.gguf
ctx-size         = 262144
cache-ram        = 8192
temp             = 0.7
top-p            = 0.95
top-k            = 0
min-p            = 0.0
cache-type-v     = q8_0
cache-reuse      = 0
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
jinja            = true
parallel         = 1
```

## gpt-oss retiré (16/09/2026)

Section `gpt-oss` (openai gpt-oss-120b, MoE 128 experts, shards UD-Q4_K_XL de
59 Go) retirée du parc le 16/09/2026. Raison, décidée par l'utilisateur : le
modèle ne sert pas dans l'usage réel. Ni régression ni mesure douteuse derrière
ce retrait, ses chiffres du 13/09/2026 restaient bons (599 t/s de prefill, 52,9
de décode, acceptance 0,57, cache 99 %) ; c'est, après Laguna la veille, le
second géant qu'on ne charge jamais, pour 59 Go de disque et 91 s de
chargement. Les tables de ce document gardent ses lignes, comme `logs/`.

Le GGUF (2 shards) de `~/models/gpt-oss/UD-Q4_K_XL/` n'est plus déclaré : il
devient orphelin de `KNOWN_FILES`, rien n'a été supprimé sur la machine,
`./setup-llm.sh --cleanup` le purgera. Restent aussi dans `~/models/gpt-oss/`
les sous-dossiers `dflash-src/` (source HF du drafter, 1,5 Go) et
`target-meta/` (27 Mo), jamais déclarés, que `--cleanup` ne touche pas (il ne
balaie que les `*.gguf` et les dossiers vides) : à retirer à la main. Le GGUF
du drafter converti avait déjà été purgé par le `--cleanup` du 15/09 au soir.
Le venv `~/llm/venv-convert` et le build `~/llm/strix-llama.cpp/build-bias/`
sont hors de `~/models` et gardés pour la PR #62. Pour ravoir la section :
remettre la déclaration de téléchargement, le commentaire et le corps ci-dessous
dans `lib/models.sh`, sous la bannière `; --- Géants ---` (toujours là pour
DeepSeek), avant DeepSeek. Depuis ce retrait, plus aucune section n'hérite du
`cache-reuse = 4096` global : gpt-oss était la seule sans état récurrent où il
servait.

Le commentaire du bloc retiré, tel quel (connaissance à conserver : choix du
device contre ROCm0, la courbe de batch la plus raide du parc et pourtant
+16 % au n-gram, conversion du drafter DFlash z-lab et refus par le fork,
comportement de `--cleanup` sur un modèle en shards), puis le corps de la
section tel qu'il était émis dans `models.ini`.

```
GPT-OSS 120B — shards UD-Q4_K_XL
download_hf_shards gpt-oss "unsloth/gpt-oss-120b-GGUF" \
  GPTOSS_PATH="UD-Q4_K_XL/gpt-oss-120b-UD-Q4_K_XL-00001-of-00002.gguf"

GPT-OSS 120B — shards UD-Q4_K_XL (59 Go), MoE 128 experts, attention
  classique + couches à fenêtre glissante (SWA), pas d'état récurrent.
Device : Vulkan0, mesuré --bench-devices 21/08/2026 (b10433, 3 passes) :
  413 pp / 49,9 tg contre ROCm0 219 / 31,5 (tour simulé 65 s contre 105) —
  les deux passent le contrôle de justesse, ROCm0 est juste lent ici. La
  courbe ROCm0 « bien meilleure » du 20/08 (reps=2) ne voulait rien dire.
  --bench (bench-task) : 333 pp / 51,9 tg. --bench-load : 91 s (59 Go depuis
  le disque), TTFT à chaud 86 ms. --bench-cache : tour suivant 99 %, requête
  identique 100 % — comme DeepSeek : sans état récurrent, le cache de prompt
  sert tout (la SWA n'y change rien). Un premier run donnait 63 % : requête
  « froide » déjà en cache après le --bench, outil corrigé depuis.
Courbe t_forward(batch) Vulkan0 (21/08, reps=5) : batch 1 = 17 ms, 8 = 57
  (x3,4), 16 = 130, 32 = 168, 48 = 246 ms (x14,7) — la plus raide de toutes.
Spéculation n-gram : ngram-map-k size_m 7, RETENU par --spec-ngram-tune
  21/08/2026 (Vulkan0, spec-refactor.txt, 4 passes) : sans spéculation
  51,7 t/s ; size_m 7 = 59,8 t/s (+16 %) ; size_m 47 = 52,7 t/s (+2 %). La
  courbe la plus raide de toutes (x3,4 au batch 8) n'a pas empêché le petit
  draft de gagner : pas d'état récurrent, donc pas de surcoût fixe par pas
  (contraste avec Qwen3-Coder-Next), et les misses sont gratuits. Le grand
  draft, lui, paie son batch x14,7 à chaque hit partiel.
Mesuré le 13/09/2026 sur le fork (strix-0007bc6, --bench 3 passes) : prefill
  599 t/s, décode 52,9 t/s, acceptance 0,57 : prefill +80 %, décode neutre
  (+2 %) contre le paquet (333 / 51,9, b10548).
Drafter DFlash z-lab : converti, refusé par le fork (15/09/2026).
  z-lab/gpt-oss-120b-DFlash (safetensors, 1,57 Go) est le drafter officiel de
  gpt-oss-120b : architectures ["DFlashDraftModel"], model_type qwen3,
  8 couches, hidden 2880, 64 têtes Q / 8 KV, head_dim 64, block_size 10,
  target_layer_ids [1, 9, 17, 25, 33], DFlash 1 (ni conv ni selector) et
  surtout attention_bias = true. Il se convertit sans avertissement avec le
  convert_hf_to_gguf.py DU FORK (classe DFlashModel, conversion/qwen.py
  l. 641), à condition de lui passer les métadonnées HF de la cible
  (openai/gpt-oss-120b, tokenizer et config sans poids, 27 Mo) :
    cd ~/llm/strix-llama.cpp && ~/llm/venv-convert/bin/python \
      convert_hf_to_gguf.py ~/models/gpt-oss/dflash-src \
      --target-model-dir ~/models/gpt-oss/target-meta \
      --outfile ~/models/gpt-oss/gpt-oss-120b-dflash-Q8_0.gguf --outtype q8_0
  (venv ~/llm/venv-convert : torch 2.14.0+cpu, transformers 5.17.0.)
  GGUF obtenu : 847 145 664 octets, 123 tenseurs, dflash.block_size 10,
  dflash.target_layers [2, 10, 18, 26, 34], fc.weight [14400, 2880], sans
  token_embd ni output (empruntés à la cible, donc même device qu'elle).
  Chargement REFUSÉ par llama-server (fork strix-0007bc6, build 10893) :
  "done_getting_tensors: wrong number of tensors; expected 123, got 91" puis
  "failed to load draft model". 123 - 91 = 32 = 8 couches x 4 biais
  d'attention (blk.N.attn_q.bias [4096], attn_k.bias [512], attn_v.bias
  [512], attn_output.bias [2880]), tous non nuls (absmax 4,16 sur
  attn_output, 1,46 sur k, 1,22 sur q) : les jeter à la conversion
  dénaturerait le drafter, ce n'est pas un contournement.
  Cause : src/models/dflash.cpp, dorsale Qwen3 (l. ~211-232 au commit
  0007bc6) ne crée AUCUN tenseur de biais, et le graphe n'en applique aucun
  (projections build_lora_mm nues l. ~708-710, build_attn(..., layer.wo,
  NULL, ...) l. ~727-728, même forme côté encodeur l. ~625-629). Le même
  loader accepte les DFlash sans biais déjà servis ici (DFlash 2 du
  qwen3.8-27b, DFlash de Qwen3-Coder-Next, DSpark de Liquid et de DeepSeek
  V4 Flash) : c'est un manque, pas un refus délibéré.
  Décision : ne pas patcher le moteur. Signalé en amont le 15/09/2026,
  [issue #61](https://github.com/halo-box/strix-llama.cpp/issues/61)
  (reproduction, 32 tenseurs, trois points de correctif estimés à 15-20
  lignes). Si elle est corrigée : re-télécharger le drafter, reconvertir,
  essayer spec-type draft-dflash à spec-draft-n-max 9 (= block_size - 1) et
  le comparer au n-gram servi aujourd'hui. Référence à battre, re-mesurée le
  même jour par tools/spec-isolate.sh : 51,0 t/s (spec-test, acceptance
  0,49) et 51,3 t/s (spec-refactor, acceptance 0,71). Chiffres amont z-lab
  pour situer l'enjeu : acceptance 3,7 à 5,4 tokens à block 10, 1,3x à 1,9x
  sous SGLang/vLLM sur H200.
  Fichiers laissés sur bigchuck, aucun déclaré par un download_hf :
    ~/models/gpt-oss/gpt-oss-120b-dflash-Q8_0.gguf (847 Mo)
    ~/models/gpt-oss/dflash-src/    (source HF du drafter, 1,5 Go)
    ~/models/gpt-oss/target-meta/   (métadonnées HF de la cible, 27 Mo)
    ~/llm/venv-convert/             (venv de conversion, 1,2 Go)
  Ce que --cleanup en fera (lecture de cmd_cleanup, lib/setup.sh) : le GGUF
  SERA PURGÉ. Il est à mindepth 2 sous ~/models, sa clé (gpt-oss) est encore
  connue, mais gpt-oss est déclaré en shards : cmd_cleanup ne protège alors
  que le DOSSIER DE QUANT (~/models/gpt-oss/UD-Q4_K_XL), pas la racine du
  dossier de modèle, donc tout .gguf non déclaré posé à côté tombe. Les deux
  sous-dossiers, eux, SURVIVENT : le balayage des dossiers est en
  maxdepth 1 (il ne voit que ~/models/gpt-oss) et celui des fichiers ne
  regarde que les *.gguf ; le find -type d -empty final ne prend que les
  dossiers vides. ~/llm/venv-convert est hors de ~/models : jamais touché.
  Donc : reconvertir après un --cleanup coûte la seule conversion, pas les
  téléchargements.
```

```ini
[gpt-oss]
model            = ~/models/gpt-oss/UD-Q4_K_XL/gpt-oss-120b-UD-Q4_K_XL-00001-of-00002.gguf
ctx-size         = 131072
cache-ram        = 8192
temp             = 1.0
top-k            = 0
top-p            = 1.0
min-p            = 0.0
spec-type        = ngram-map-k
spec-ngram-map-k-size-m   = 7
spec-ngram-map-k-min-hits = 2
parallel         = 1
```

## Muse-Glimmer-30B et LFM2.5-8B-A1B ajoutés (16/09/2026)

Deux sections ajoutées le 16/09/2026, toutes deux servies avec un drafter
externe à un seul slot : `lfm2.5-8b-a1b-nothink` (LFM2.5-8B-A1B de Liquid AI,
grand frère du 2.6B, drafter DSpark officiel) et `muse-glimmer-30b-dflash`
(Muse-Glimmer-30B de Meta, drafter DFlash 2 z-lab, concurrent direct de
`qwen3.8-27b-dflash-nothink`). Même moteur pour tout ce qui suit : fork
strix-0007bc6, bigchuck (Ryzen AI Max+ 395, 124 Go), Vulkan0, 16/09/2026.
Aucune des deux n'a jamais été mesurée sur le paquet Arch : la colonne « paquet »
du README et de `docs/perfs.tsv` reste vide pour elles.

Deux points de méthode communs. `--bench-devices` n'a pas pu tourner : le fork
ne construit que Vulkan et la commande refuse de trancher avec un seul device.
Les deux sections héritent donc du défaut `[*] Vulkan0`, sans ligne dans
`bench-devices.conf` : ce n'est pas un choix mesuré, seulement le seul device
disponible. `--spec-ngram-tune` a été écarté de la même façon sur les deux :
sur un modèle sans tête MTP il prend « sans spéculation » pour référence, ce qui
n'a pas de sens quand le draft vient d'un drafter externe déjà servi ; la taille
n-gram a été réglée par `--spec-ab` sur le modèle tel qu'il est servi.

### lfm2.5-8b-a1b-nothink : LFM2.5-8B-A1B-Q8_0.gguf (9,0 Go) + drafter DSpark officiel Q8_0 (0,36 Go), bigchuck, fork strix-0007bc6, Vulkan0, 16/09/2026

MoE `lfm2moe` 8,3B total / 1,5B actifs, ctx 131072, KV f16. Le modèle est
« reasoning-tuned » et son template n'a aucun interrupteur de thinking : en
1200 tokens il n'avait pas fini de raisonner, contenu vide sur les deux prompts.
Le suffixe `-nothink` vient de `reasoning-budget-enable` + `reasoning-budget 0`
(clés du fork), qui ferment la balise d'office.

| Configuration | Device | Prompt t/s | Gen t/s | Acceptance | Source |
|---|---|---|---|---|---|
| sans spéculation | Vulkan0 | n/c | 102,2 | — | test isolé, 2 passes, 1200 tokens (spec-test.txt) |
| sans spéculation | Vulkan0 | n/c | 102,9 | — | test isolé, 2 passes, 1200 tokens (spec-refactor.txt) |
| draft-dspark, n-max 3 | Vulkan0 | n/c | 118,0 | 0,66 | test isolé, 2 passes (spec-test.txt) |
| draft-dspark, n-max 3 | Vulkan0 | n/c | 133,4 | 0,82 | test isolé, 2 passes (spec-refactor.txt) |
| draft-dspark, n-max 5 | Vulkan0 | n/c | 114,0 | 0,60 | test isolé, 2 passes (spec-test.txt) |
| draft-dspark, n-max 5 | Vulkan0 | n/c | 128,4 | 0,72 | test isolé, 2 passes (spec-refactor.txt) |
| draft-dspark, n-max 9 | Vulkan0 | n/c | 82,0 | 0,36 | test isolé, 2 passes (spec-test.txt) |
| draft-dspark, n-max 9 | Vulkan0 | n/c | 117,3 | 0,56 | test isolé, 2 passes (spec-refactor.txt) |
| sans spéculation, thinking ON | Vulkan0 | n/c | 107,3 | — | test isolé, 2 passes, contenu vide en 1200 tokens (spec-test.txt) |
| draft-dspark 3, thinking ON | Vulkan0 | n/c | 100,9 | 0,53 | test isolé, 2 passes, contenu vide en 1200 tokens (spec-test.txt) |
| draft-dspark 3, thinking ON | Vulkan0 | n/c | 109,6 | 0,62 | test isolé, 2 passes, contenu vide en 1200 tokens (spec-refactor.txt) |
| sans spéculation | Vulkan0 | n/c | 106,0 | — | --spec-ab, 4 passes (spec-refactor.txt) |
| draft-dspark seul, n-max 3 | Vulkan0 | n/c | 126,6 | 0,78 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 7 + draft-dspark 3 | Vulkan0 | n/c | 146,2 | 0,78 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 15 + draft-dspark 3 | Vulkan0 | n/c | 144,2 | 0,70 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 47 + draft-dspark 3 | Vulkan0 | n/c | 169,6 | 0,61 | --spec-ab, 4 passes (spec-refactor.txt) |
| draft-dspark seul, n-max 3 | Vulkan0 | n/c | 120,3 | 0,71 | --spec-ab, 4 passes (spec-test.txt) |
| ngram 7 + draft-dspark 3 | Vulkan0 | n/c | 118,3 | 0,68 | --spec-ab, 4 passes (spec-test.txt) |
| ngram 47 + draft-dspark 3 | Vulkan0 | 3079 | 108,1 | 0,55 | --bench, 3 passes (bench-task) |

Retenu : `ngram-map-k` size-m 47 min-hits 2 + `draft-dspark` n-max 3 sur
Vulkan0, `reasoning-budget-enable` + `reasoning-budget 0`, parallel 1
(`spec-draft-n-max`, `spec-ngram-map-k-size-m` et le reste dans `lib/models.sh` ;
rien dans `spec-nmax.conf` ni `spec-ngram.conf`, aucun tune n'a tourné, et rien
dans `bench-devices.conf`). Jamais mesuré au paquet Arch.

Lectures. Le DSpark rend x1,16 en générique et x1,30 en refactor, bien moins que
sur le 2.6B (x1,76) : 1,5B actifs sur 9 Go de poids, le décode est déjà borné
par la lecture des experts routés et le batch de vérification en lit davantage.
Le n-gram, absent du 2.6B, est ajouté ici parce que le 8B vise aussi l'édition
de code : à 47 colonnes il rend +34 % contre le drafter seul et +60 % contre
rien sur le refactor, pour un coût nul en générique (les hits y sont rares, un
miss ne coûte qu'une sonde de hash). Même régime large que le 27B dense, malgré
la pente MoE : 1,5B actifs font un forward court même à 48 colonnes. Enfin, le
drafter devine bien mieux la réponse que la pensée (acceptance 0,53 / 0,62 avec
le raisonnement contre 0,66 / 0,82 sans), ce qui conforte le budget 0.

Cache de prompt (`--bench-cache`, 16/09/2026) : requête froide 440 ms, tour
suivant 63 % servi du cache (220 ms), édition au premier tiers 0 %, requête
identique 64 % (176 ms). Le modèle se range avec les architectures à état
récurrent (la conv double-gate), comme le 2.6B : restauration au dernier
checkpoint, pas au token près.

Chargement (`--bench-load`, 16/09/2026) : 1,7 s de chargement + premier token
pour 8,4 Go lus, TTFT à chaud 31 ms.

### muse-glimmer-30b-dflash : Muse-Glimmer-30B-UD-Q4_K_XL.gguf (15,9 Go) + drafter DFlash 2 z-lab Q8_0 (3,0 Go), bigchuck, fork strix-0007bc6, Vulkan0, 16/09/2026

Dense 30B `muse-glimmer`, SWA de 2048 sur 3 couches sur 4, ctx 131072,
cache-type-v q8_0, `swa-full` + `ctx-checkpoints 128`. Pas de suffixe `-nothink` :
le canal de réflexion de ce modèle ne se ferme pas, seul son niveau se règle
(`chat-template-kwargs` `reasoning_strength` low), plafonné par
`reasoning-budget-enable` + `reasoning-budget 4096`. Le test isolé a tourné à
-c 32768.

| Configuration | Device | Prompt t/s | Gen t/s | Acceptance | Source |
|---|---|---|---|---|---|
| sans spéculation | Vulkan0 | 275 (froid) | 14,0 | — | test isolé, 2 passes, 1200 tokens (spec-test.txt) |
| sans spéculation | Vulkan0 | n/c | 13,9 | — | test isolé, 2 passes, 1200 tokens (spec-refactor.txt) |
| draft-dflash, n-max 7 | Vulkan0 | n/c | 43,0 | 0,74 | test isolé, 2 passes, 6,0 tokens acceptés par étape (spec-test.txt) |
| draft-dflash, n-max 7 | Vulkan0 | n/c | 41,4 | 0,72 | test isolé, 2 passes, 6,2 tokens acceptés par étape (spec-refactor.txt) |
| draft-dflash, n-max 15 | Vulkan0 | n/c | 20,9 | 0,55 | test isolé, 2 passes (spec-test.txt) |
| draft-dflash, n-max 15 | Vulkan0 | n/c | 17,5 | 0,46 | test isolé, 2 passes (spec-refactor.txt) |
| draft-dflash, n-max 3 | Vulkan0 | n/c | 37,8 | 0,85 | test isolé, 2 passes (spec-test.txt) |
| draft-dflash, n-max 3 | Vulkan0 | n/c | 34,6 | 0,80 | test isolé, 2 passes (spec-refactor.txt) |
| draft-dflash seul, n-max 7 | Vulkan0 | n/c | 37,2 | 0,63 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 7 + draft-dflash 7 | Vulkan0 | n/c | 41,8 | 0,62 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 15 + draft-dflash 7 | Vulkan0 | n/c | 29,2 | 0,52 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 47 + draft-dflash 7 | Vulkan0 | n/c | 37,1 | 0,53 | --spec-ab, 4 passes (spec-refactor.txt) |
| draft-dflash seul, n-max 7 | Vulkan0 | n/c | 42,0 | 0,73 | --spec-ab, 4 passes (spec-test.txt) |
| ngram 7 + draft-dflash 7 | Vulkan0 | n/c | 43,5 | 0,73 | --spec-ab, 4 passes (spec-test.txt) |
| ngram 7 + draft-dflash 7 | Vulkan0 | 266 | 38,0 | 0,635 | --bench, 3 passes (bench-task) |

Retenu : `ngram-map-k` size-m 7 min-hits 2 + `draft-dflash` n-max 7 sur Vulkan0,
`reasoning_strength` low + `reasoning-budget 4096`, parallel 1 (tout dans
`lib/models.sh` ; rien dans `spec-nmax.conf`, `spec-ngram.conf` ni
`bench-devices.conf`, aucun tune n'a tourné et `--spec-tune` refuse de toute
façon `draft-dflash`). Jamais mesuré au paquet Arch. Contre le concurrent direct
`qwen3.8-27b-dflash-nothink`, mesuré le même mois sur le même fork
(359 / 32,6 / 0,595) : +17 % de décode, -26 % de prefill. Ces deux écarts sont
repris le 17/09/2026 par un contrôle à froid des deux modèles le même soir, sur
le même moteur (Muse 301 / 38,5, le 27B 302 / 32,2 en cache-type-v f16) :
+20 % de décode et un prefill équivalent, cf. « Campagne du 17/09/2026 ».

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

### Boucle agentic réelle des deux modèles (--bench-agentic du 16/09/2026)

pi 0.84.3 en conteneur, appel froid puis 3 passes de 5 scénarios, bigchuck, fork strix-0007bc6, 16/09/2026 (autre série de moteur que la table du 28/08 ci-dessus, à ne pas comparer à la décimale) :

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

## Ornith 35B A3B : cache V f16 et retrait de swa-full (18/09/2026)

Les deux sections `ornith-1.5-35b-a3b-parallel` et `ornith-1.5-35b-a3b-mtp`
perdent des clés de corps, sur mesure et sur journal du moteur. Décision de
l'utilisateur, hors campagne.

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

Aucune mesure n'est refaite ici : les chiffres de référence des deux sections
restent ceux du 18/09/2026 (1376 / 71,7 pour la `-parallel`, 1312 / 76,9 pour
la `-mtp`), la `-parallel` étant désormais servie dans la configuration f16 qui
a donné 1379 / 72,4 à l'A/B.

## `--setup` allégé : plus de paquets llama.cpp ni ggml sur l'hôte (18/09/2026)

Suite du retrait du fork. `--setup` installait `llama-cpp`, `ggml-cpu` et
`ggml-vulkan` (obligatoires), et proposait en best-effort le runtime ROCm de
l'hôte plus `ggml-hip` (`ROCM_PKGS` : `rocm-hip-runtime`, `hipblas`, `rocblas`,
`hipblaslt`, `ggml-hip`), avec son contrôle `rocminfo | grep gfx1151`. Tout cela
ne servait qu'un moteur sur l'hôte, qui n'existe plus : le service et les outils
tournent dans l'image, qui embarque son propre ROCm.

Ce que `--setup` vérifie désormais :

- `curl` et `hf` (`python-huggingface-hub`, `python-hf-xet`), installés par
  `paru` s'ils manquent, pour les téléchargements ;
- docker : la commande, le démon qui répond, le démon **activé au boot**
  (`systemctl is-enabled docker` : c'est docker qui relance le conteneur après
  un redémarrage de la machine, il a remplacé le `loginctl enable-linger` de
  l'unité systemd) et l'appartenance au groupe `docker` ;
- l'image du moteur : présente, avec son étiquette ; absente, `--image-build`
  est indiqué.

Aucun de ces contrôles n'est bloquant : un `--setup` sert aussi à télécharger
des poids sur une machine qui ne servira rien.

**Le dépôt ne désinstalle rien** et n'a jamais rien désinstallé. Sur une machine
qui porte encore ces paquets, les retirer à la main si la place manque :

```
paru -Rns llama-cpp ggml-cpu ggml-vulkan ggml-hip \
          rocm-hip-runtime hipblas rocblas hipblaslt
```

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

`_dk_run` gagne pour cela deux variables : `DK_RUN_PUBLISH` (publication de
port, qui bascule le réseau par défaut sur `bridge`, toujours bornée à la
loopback) et `DK_RUN_NAME` (nom du conteneur, pour que le trap de
`spec-isolate.sh` fasse `docker rm -f` : tuer le `docker run` ne tue pas
forcément le conteneur, qui garderait le GPU et le port). `LLAMA_BIN_DIR`,
qui pointait un build à part du fork, est remplacé par `IMAGE=` dans les trois
outils : c'est ainsi qu'on mesure un moteur autre que celui du service.

`GGML_CUDA_ENABLE_UNIFIED_MEMORY` disparaît de tout le dépôt. Elle était
nécessaire au moteur Vulkan/HIP de l'hôte et est INTERDITE sur le runtime
retained-PM4 de l'image, où elle fait passer chaque allocation par
`hipMallocManaged` et corrompt la sortie (cf. `runtime/AMONT.md`). Le test de
`tests/sh-unit.sh` qui interdit sa présence dans le compose généré reste.

Les valeurs par défaut des deux outils de courbe suivent le moteur : `DEV`
passe de `Vulkan0` à `ROCm0`, et le cache KV de `bench-depth.sh` de `q8_0` à
`f16`, qui est ce que sert le routeur depuis le 18/09/2026.

**Retour arrière.** Il ne passe plus par un fork installé sur l'hôte mais par
`runtime/image.conf` : y remettre d'anciennes révisions (`git revert` sur ce
fichier, ou `--image-update <engine-rev> <rocm-rev>`) puis `--image-build`.
L'historique git de ce fichier est le journal des révisions. Le code de
`lib/fork.sh` reste récupérable dans l'historique git du dépôt, au commit qui
précède ce retrait.

**Ce qui reste vrai et n'a pas bougé.** Les commentaires datés de
`lib/models.sh` et de ce document qui citent le fork comme moteur d'une
campagne : ce sont des mesures réellement faites sous `strix-<commit>`, et
elles gardent leur étiquette. Les clés que seul ce moteur comprend
(`ngram-on-disk`, `lazy-mode`, `fit`, `load-mode`, `reasoning-budget-*`,
`spec-draft-adaptive`, `spec-prefill*`) restent posées dans le ini : la dorsale
`halo-box/strix-llama.cpp` est la même dans l'image. Ce qui disparaît, c'est la
garde qui les signalait quand un moteur d'amont était résolu sur l'hôte, sans
objet depuis qu'il n'y a plus de moteur sur l'hôte.

## lfm2.5-8b-a1b-nothink retiré (18/09/2026)

Section `lfm2.5-8b-a1b-nothink` (LFM2.5-8B-A1B de Liquid AI, Q8_0 de 9,0 Go et
drafter DSpark officiel de 0,36 Go) retirée du parc le 18/09/2026. Raison,
décidée par l'utilisateur : le modèle échoue à la boucle agentic réelle, sur
les DEUX moteurs, et `lfm2.5-2.6b` couvre déjà le créneau en passant 16/16.

Le verdict, daté :

- 16/09/2026, fork strix-0007bc6, Vulkan0 : 3/5 scénarios puis boucle sans fin
  sur la correction de bug (36 min, 18 700 requêtes de 20 à 50 tokens, contexte
  à 47k, conteneur tué à la main), cf. « Muse-Glimmer-30B et LFM2.5-8B-A1B
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
la machine, `./setup-llm.sh --cleanup` les purgera. Pour ravoir la section :
remettre les deux `download_hf`, le commentaire et le corps ci-dessous dans
`lib/models.sh`, sous la bannière du groupe, entre `lfm2.5-2.6b` et
`qwen3-coder-next`.

Le bloc retiré, tel quel (connaissance à conserver : quant officielle, drafter
DSpark sidecar, thinking coupé par `reasoning-budget-enable` + budget 0, réglage
n-gram 47 arbitré par `--spec-ab`, et les mesures des deux moteurs). Les tirets
longs de l'original sont rendus en tirets simples.

```
groupe "; --- LFM2.5 8B-A1B (Liquid AI - MoE 8,3B / 1,5B actifs, agentic edge) ---"

# LFM2.5-8B-A1B (Liquid AI, sorti le 24/08/2026) - MoE hybride conv récurrente
# + GQA (arch lfm2moe, 24 couches : 18 conv double-gate + 6 GQA), 8,3B total /
# 1,5B actifs, ctx natif 128K, vocab 128 000. Grand frère du 2.6B ci-dessus :
# Liquid annonce +11,5 points de MMLU-Pro et un net progrès en code, mais le
# 2.6B reste devant sur le tool use pur (BFCLv4, IFEval) - les deux sections
# cohabitent tant que la boucle agentic (étape 7) n'a pas tranché.
# Q8_0 officiel LiquidAI (9 010 195 680 octets) : petit modèle, même logique
# que le 2.6B, aucune raison de descendre ; pas de quant unsloth UD ni de
# guide unsloth pour cette variante au 16/09/2026 (le guide LFM2.5 ne couvre
# que les 1.2B). Support lfm2moe mainline depuis mai 2026, présent dans le
# fork strix-0007bc6 (vérifié le 16/09/2026, src/llama-arch.cpp:128).
download_hf lfm2.5-8b-a1b "LiquidAI/LFM2.5-8B-A1B-GGUF" \
  LFM25_8B_PATH="LFM2.5-8B-A1B-Q8_0.gguf"

# Drafter DSpark officiel Liquid AI (Q8_0, 356 491 104 octets ; F16 664 Mo
# annoncé +2 % d'acceptance, à essayer par --spec-ab si le Q8_0 déçoit),
# déclaré dans le MÊME dossier que la cible, comme pour le 2.6B. Sidecar pur
# (5 couches d'attention, tête de Markov rang 256, tête de confiance, block
# size 9) : embeddings et tête LM empruntés à la cible, donc même device
# qu'elle, jamais de spec-draft-device. Le support DSpark pour LFM2 est une
# PR distincte du DSpark générique (mainline #27383, commit 07822bdd, présent
# dans le fork strix-0007bc6, vérifié le 16/09/2026). Le GGUF devient
# nécessaire au démarrage de la section : ne pas le retirer du dossier.
# n-max : le README du repo dit 10, le fork clampe à block_size = 9.
download_hf lfm2.5-8b-a1b "LiquidAI/LFM2.5-8B-A1B-DSpark-GGUF" \
  LFM25_8B_DSPARK_PATH="LFM2.5-8B-A1B-DSpark-Q8_0.gguf"

# LFM2.5-8B-A1B nothink - ajouté le 16/09/2026, étapes 1 à 6 de la skill
#   ajout-modele faites le jour même (chiffres ci-dessous), étape 7
#   (--bench-agentic) en bas de bloc.
# Sampling : reco officielle de la model card 8B-A1B (temp 0.2, top-k 80,
#   repeat-penalty 1.05), différente de celle du 2.6B (0.1 / 50 / 1.1) : la
#   fiche du 8B ne donne ni top-p ni min-p, min-p 0 explicite.
# Thinking COUPÉ (suffixe -nothink) : modèle « reasoning-tuned », il ouvre
#   <think> de lui-même et le template n'a aucun interrupteur (ni
#   enable_thinking ni reasoning_effort ; seul preserve_thinking, qui ne
#   concerne que la relecture de l'historique). Test isolé du 16/09/2026 : en
#   1200 tokens il n'avait pas fini de raisonner, contenu VIDE sur les deux
#   prompts. `reasoning-budget 0` seul est inerte sur le fork : le mécanisme
#   n'y vit que derrière reasoning-budget-enable (common/sampling.cpp:313).
#   Avec reasoning-budget-enable + budget 0 la balise se ferme d'office et la
#   réponse part au premier token (contenu ligne 2 du gen). ⚠ Clé propre au
#   fork (FORK_ONLY_KEYS, cf. deepseek-v4-flash) : le parc était déjà
#   verrouillé sur le fork par deepseek-v4-flash et qwen3.8-flash-next.
#   Sur le paquet Arch de secours, l'équivalent serait reasoning-budget 0 seul
#   (mainline) : non mesuré.
# ctx 131072 : fenêtre native 128K, un seul slot en dispose en entier.
# cache KV f16 : hérité du global depuis le 18/09/2026 (cf. en-tête), les deux
#   lignes du corps qui le répétaient sont retirées. Raison inchangée : arch
#   hybride conv + GQA, KV minuscule, chemin quantifié non validé sur lfm2
#   (même prudence que le 2.6B).
# cache-reuse 0 : état récurrent (conv) et contrainte des sections spéculatives.
# Pas de swa-full ni ctx-checkpoints : pas une arch hybride SWA Qwen.
# Spéculation DSpark, test isolé du 16/09/2026 (fork strix-0007bc6, Vulkan0,
#   hors service, np 1, 2 passes, 1200 tokens, médiane hors 1re passe,
#   spec-test.txt / spec-refactor.txt, thinking coupé) :
#     sans spéculation      102,2 / 102,9 t/s
#     draft-dspark n-max 3  118,0 / 133,4  (acceptance 0,66 / 0,82)
#     draft-dspark n-max 5  114,0 / 128,4  (0,60 / 0,72)
#     draft-dspark n-max 9   82,0 / 117,3  (0,36 / 0,56)
#   RETENU n-max 3 : x1,16 en générique, x1,30 en refactor, batch de
#   vérification de 4 colonnes. Gain plus faible que sur le 2.6B (x1,76) :
#   1,5B actifs sur 9 Go de poids, le décode est déjà limité par la lecture
#   des experts routés, et le batch en lit davantage. Le même test AVEC
#   raisonnement (avant le budget 0) donnait 100,9 / 109,6 en n-max 3 contre
#   107,3 / 100,3 sans spéculation, acceptance 0,53 / 0,62 : le drafter
#   devine bien mieux la réponse que la pensée.
#   n-gram AJOUTÉ (contrairement au 2.6B) : le 8B vise aussi l'édition de code,
#   où le prompt se ré-émet. --spec-ngram-tune n'a pas été utilisé : sur un
#   modèle sans tête MTP il prend « sans spéculation » pour référence, ce qui
#   n'a pas de sens avec un drafter externe ; réglé par --spec-ab tel que
#   servi, le 16/09/2026 (strix-0007bc6, Vulkan0, 4 passes, décode médian) :
#     spec-refactor.txt : none 106,0 ; draft-dspark seul 126,6 (acc. 0,78) ;
#       ngram 7 + dspark 146,2 (0,78) ; ngram 15 = 144,2 (0,70) ;
#       ngram 47 = 169,6 (0,61)
#     spec-test.txt : draft-dspark seul 120,3 (0,71) ; ngram 7 = 118,3 (0,68)
#   RETENU size-m 47, min-hits 2 : +34 % contre le drafter seul et +60 % contre
#   rien sur le refactor, neutre en générique (les hits y sont rares, un miss
#   ne coûte qu'une sonde de hash). Même régime large que le 27B dense : la
#   pente MoE sous la marche n'a pas empêché le 47 de gagner ici, parce que
#   1,5B actifs font un forward court même à 48 colonnes.
# parallel 1 : np 2 x (3 + 1) = 8 colonnes, pile au seuil, mais le 2.6B y a
#   mesuré ~x1,1 agrégé pour une latence doublée : pas mesuré ici, 1 gardé.
# ⚠ SECTION NON MESURÉE SUR LE MOTEUR CONTENEURISÉ, À QUALIFIER. Avec
#   ornith-1.5-35b-a3b-parallel, c'est l'une des deux sections que la campagne
#   du 17 au 18/09/2026 n'a pas jouées : tous les réglages ci-dessous sont ceux
#   du fork Vulkan, gardés tels quels faute de mesure. Ne changent que les
#   réglages globaux : device ROCm0, fit off, load-mode none, cache K et V f16
#   (elle était déjà en f16, cf. ci-dessus : rien ne bouge en pratique).
#   À la bascule : tools/qualif-modele.sh, en commençant par --bench-sanity.
# Device : ROCm0 depuis le 18/09/2026 (device unique de l'image). Jusque-là
#   Vulkan0 hérité du défaut, --bench-devices n'ayant jamais tourné ici (le
#   fork n'exposait que Vulkan0) ; la sanité de la sortie avait été lue au test
#   isolé (sanité ok sur toutes les passes).
# Mesuré le 16/09/2026 TEL QUE SERVI (fork strix-0007bc6, Vulkan0, --bench 3
#   passes, bench-task) : prefill 3079 t/s, décode 108,1 t/s, acceptance 0,55.
#   Même débit que le 2.6B (2875 / 108,8) pour un modèle trois fois plus gros
#   et bien meilleur en code selon Liquid : c'est l'argument de cette section.
#   Jamais mesuré au paquet Arch.
# --bench-cache du 16/09/2026 : suite 63 % servi du cache (220 ms), identique
#   64 %, édition 0 % : arch à état récurrent (conv), restauration au dernier
#   checkpoint comme le 2.6B et les GDN.
# --bench-load du 16/09/2026 : 1,7 s chargement + 1er token (8,4 Go lus),
#   TTFT à chaud 31 ms.
# Mémoire : ~16 Go chargé (poids 9 + drafter 0,36 + KV du ctx 131072).
# --bench-agentic du 16/09/2026 (pi 0.84.3, strix-0007bc6) : ÉCHEC. Passe 1 :
#   simple 0/1 (23 tokens, réponse hors sujet), outils 1/1 (1,9 s, 89 t/s),
#   edit 1/1 (4,0 s, 103 t/s), création 0/1 (les fichiers sont écrits mais le
#   test n'est pas relancé jusqu'au vert), bug sans toucher au test : BOUCLE
#   sans fin (36 min, 18 700 requêtes de 20 à 50 tokens, contexte à 47k,
#   conteneur tué à la main ; le bench n'a pas de limite de tours). Verdict :
#   le modèle tient les tool calls simples mais pas une boucle de correction,
#   comme Liquid l'annonce (« moins adapté au code lourd »). Section GARDÉE
#   pour l'instant avec ce verdict : à retirer si elle ne sert pas dans l'usage
#   réel (même critère que laguna et gpt-oss), ou à re-mesurer avec le
#   raisonnement rétabli (reasoning-budget N > 0) si on veut lui donner sa
#   chance en agentic, au prix du débit.
# JUSTESSE MESURÉE LE 18/09/2026, PREMIÈRE FOIS SUR CE MOTEUR - réserve à
#   lever avant tout usage réel. --bench-sanity passe (la chaîne de contrôle est
#   bien recopiée) mais la réponse est bavarde et méta (« Je suis en train de
#   copier exactement le code fourni sans aj… ») : ce n'est pas du charabia,
#   c'est du commentaire de soi. Aux comptages de lignes, à max_tokens 2048 et
#   finish_reason « stop » (donc sans troncature) : 69 / 259 / 399 pour
#   70 / 260 / 800. Les deux premiers sont un décalage d'une unité (le modèle
#   rend le dernier NUMÉRO de ligne), le troisième est une erreur grossière.
#   Cause identifiée : reasoning-budget 0. Avec le budget porté à 2048 par
#   surcharge SPEC_AB_OVERRIDES, même moteur, même prompt : 69 / 259 / 800 -
#   l'erreur grossière à 20k DISPARAÎT, le décalage d'une unité reste (limite
#   du modèle, 1,5B actifs). Les deux autres modèles du parc qui comptent juste
#   (lfm2.5-2.6b, Muse-Glimmer) le font DANS leur raisonnement.
#   RIEN N'EST CHANGÉ ICI : porter le budget à 2048 contredirait le « nothink »
#   de la section, qui est un choix d'usage, et le débit n'a pas été remesuré
#   sous ce budget. Proposition à trancher avec le --bench-agentic, en même
#   temps que le retrait déjà en suspens (boucle agentic échouée le 16/09).
# VALIDÉ PAR LE DÉPÔT le 18/09/2026 pour les débits (même série) : prefill
#   4 076 t/s, décode 118,5 t/s, acceptance 0,535, cache long à 20k 97 %,
#   chargement 1,4 s (8,4 Go).
llama_model lfm2.5-8b-a1b-nothink "
model            = $LFM25_8B_PATH
ctx-size         = 131072
cache-ram        = 2048
temp             = 0.2
top-k            = 80
min-p            = 0.0
repeat-penalty   = 1.05
cache-reuse      = 0
spec-type        = ngram-map-k,draft-dspark
spec-draft-model = $LFM25_8B_DSPARK_PATH
spec-draft-n-max = 3
spec-ngram-map-k-size-m   = 47
spec-ngram-map-k-min-hits = 2
reasoning-budget-enable = true
reasoning-budget = 0
jinja            = true
parallel         = 1"
```

## Campagne du 17/09/2026 : cache V f16 sur le 27B, `reasoning = off`, essais retirés sur Flash-Next

Toutes les mesures de cette section : bigchuck (Ryzen AI Max+ 395, 124 Go),
fork strix-0007bc6 épinglé, Vulkan0, mode EC performance, `--bench` 3 passes, à
froid juste après un redémarrage de la machine, le 17/09/2026. Sauf la dernière
sous-section, qui porte sur un autre commit du fork et le dit.

### `qwen3.8-27b-dflash-nothink` : cache-type-v f16 au lieu de q8_0

| Configuration | Device | Prompt t/s | Gen t/s | Acceptance | Source |
|---|---|---|---|---|---|
| ngram 47 + draft-dflash 7, cache-type-v f16 | Vulkan0 | 302 | 32,2 | 0,625 | --bench, 3 passes (bench-task), à froid |
| ngram 47 + draft-dflash 7, cache-type-v q8_0 | Vulkan0 | 305 | 30,3 | 0,595 | --bench, 3 passes (bench-task), à froid, même soir |

Retenu : `cache-type-v f16` (`lib/models.sh`, rien dans les `.conf`). Le f16
rend +6 % de décode et monte l'acceptance de 0,595 à 0,625, le prefill est égal
(302 contre 305, dans le bruit). C'est la première comparaison propre des deux
caches V sur cette section : même moteur, même soir, même état de machine.
La convention du parc (V q8_0 pour l'agentic, précision des tool calls et des
diffs) cède ici devant la mesure ; la justesse des sorties n'a pas bougé au
contrôle de sanité.

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

Configuration inchangée, même soir, mêmes conditions que ci-dessus, pour situer
les mesures de la section précédente et non pour remplacer les références :

| Modèle | Prompt t/s | Gen t/s | Acceptance |
|---|---|---|---|
| qwen3.8-flash-next-mtp-nothink | 342 | 48,1 | 0,87 |
| muse-glimmer-30b-dflash | 301 | 38,5 | 0,63 |

### Essai retiré sur Flash-Next : `batch-size` / `ubatch-size` 16384 et `lazy-mode on-direct`

Essai mené sur le fork 0636c9aee (b11111), pas sur 0007bc6. Avec
`batch-size 16384`, `ubatch-size 16384` et `lazy-mode on-direct` :

- prefill `--bench` 389 à 397 t/s contre 343, décode 45,3 à 46,5 contre 49,5 ;
- `lazy-mode on-direct` neutre, double emploi avec `ngram-on-disk` ;
  (relecture du 21/09/2026 : depuis le merge b11111, `--ngram-on-disk` n'est
  qu'un alias de `--lazy-mode on`, pas de `on-direct`, reproduit par un membre
  du Discord halo-box ; les deux flags étaient passés ensemble, le mode réel
  dépendait donc de l'ordre d'analyse. Les mesures servies depuis le 18/09
  passent `lazy-mode on-direct` seul et ne sont pas concernées.)
- surtout, le prefill servi sur Vulkan0 s'effondre en profondeur : 135 t/s à
  12 000 tokens, puis le GPU décroche à 25 000 tokens
  (`vk::Queue::submit: ErrorDeviceLost`, reset de file amdgpu), après quoi
  toute la machine perd 12 à 20 % de prefill jusqu'au redémarrage ;
- ROCm0 tient 445 t/s à 25 000 tokens mais rend une génération dégénérée et un
  « Invalid input batch ».

Le gain de prefill au bench court est donc payé deux fois : en décode, et par un
prefill servi qui s'écroule là où ce modèle sert justement. Paramètres retirés,
retour au batch par défaut et à `cache-type-v q8_0` sur cette section.

Le fork 0636c9aee lui-même n'est pas retenu : le 27B y tombe à 255 / 25,5
(cache-type-v f16) contre 302 / 32,2 sur 0007bc6. Ré-épinglage sur 0007bc6 le
soir même, cf. « Mise à jour du fork vers 654803517 (13/09/2026) : régression,
retour à 0007bc6 », même schéma.

## Choix du device (--bench-devices) : méthode et exemples datés

Méthode complète et exemple du 16/08/2026 (paquet Arch b10433).

Chaque modèle peut tourner sur Vulkan0 (défaut) ou ROCm0, et le meilleur
choix varie selon le modèle : ROCm est souvent devant en prefill, Vulkan en
décode. `--bench-devices` tranche automatiquement, sans édition manuelle :

```bash
./setup-llm.sh --bench-devices                          # choix interactif du modèle
./setup-llm.sh --bench-devices qwen3.8-27b-dflash-nothink  # modèle donné
./setup-llm.sh --bench-devices <modèle> Vulkan0,ROCm0 5 # devices et passes explicites
```

Déroulé : pour chaque device (croisé avec ceux réellement exposés par
`llama-bench --list-devices`, un backend absent est exclu), le script
régénère le ini avec le device forcé, redémarre le service par
`systemctl --user restart` (les modèles préchargés se rechargent, prévoir
la durée) et lance la même mesure que `--bench`. Le restart entre deux
devices garantit un cache froid : les prefills se comparent à conditions
égales. Une interruption en cours de route restaure la config non forcée.

Le verdict est le temps d'un tour d'usage simulé :

```
t(device) = 2000 tokens de prefill froid / prefill t/s + 3000 générés / décode t/s
```

Un seul scalaire tranche toujours, y compris quand un device gagne le
prefill et l'autre le décode. Exemple réel (qwen3.8-27b-mtp-nothink, 16/08/2026, avant son renommage
en qwen3.8-27b-dflash-nothink) :
ROCm0 gagne le prefill (356 contre 307 t/s) mais perd le décode (21,8
contre 29,9 t/s) ; en temps de tour, Vulkan0 fait 106,7 s contre 143,3 s
et l'emporte nettement. Le profil se surcharge à l'appel pour un usage
différent, par exemple `BENCH_PROFILE_PP=8000 BENCH_PROFILE_GEN=500` pour
du gros contexte à réponse courte. À moins de 2 % d'écart, le device par
défaut est conservé (pas de bascule sur du bruit de mesure).

Le vainqueur est écrit dans `bench-devices.conf` (clé = dossier du GGUF,
donc partagée entre les variantes d'un même fichier), le ini est régénéré
et le service redémarre sur la config retenue. Le fichier reste éditable à
la main pour forcer un choix. Formule, garde-fous et limites : section
dédiée dans ARCHITECTURE.md.

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
le 35B-A3B MoE retient 7 (sa pente sous la marche
est trop raide pour amortir un draft large). Un run en `spec-type` mixte est
journalisé mais exclu de la calibration α (k variable par forward) ; pour la
même raison `--spec-tune` mesure en `draft-mtp` seul le temps du réglage.

Pour explorer sans régler (autre GGUF, comparer ROCm0 et Vulkan0, modèle
sans MTP) : `tools/bench-spec-batch.sh` (voir README, « Outils »).

