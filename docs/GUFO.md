# gufo : état courant et suivi

Document de travail sur [gufo](https://github.com/gufo-org/gufo), moteur
d'inférence spécialisé Strix Halo, évalué le 24/09/2026 face au moteur du
service puis servi à sa place sur `:8009` (les deux ne tiennent pas ensemble
en mémoire). Pilotage et bancs sont versionnés
dans `runtime-gufo/`, sans intégration au routeur du service. Le détail daté
(évaluation, releases, tickets, mesures) est dans le journal
[`docs/HISTORIQUE-GUFO.md`](HISTORIQUE-GUFO.md) ; ce document n'en garde que
la synthèse et ce qui sert au travail courant.

État au 04/10/2026 :

- **Verdict** : bien configuré, gufo fait le même travail agentique que le
  service en 30 % de temps en moins sur le 27B et Flash-Next, sans le
  remplacer (section « Verdict »).
- **En service** : image épinglée `gufo-runtime:0.7.0` depuis le 04/10/2026,
  **remesure en attente** (0.1.1 le 28/09, 0.2.0 le 29/09, 0.4.0 montée puis
  annulée le 01/10, 0.5.0 le 03/10), derrière llama-swap, en `--think off`, 2 sessions, cache disque 16 Gio et
  staging 8 Gio ; réglages dans « Paramètres de gufo et leur origine ».
- **Tickets** : les ouverts sont dans le tableau « À surveiller ». Notre
  ticket #388 (boucle d'appels d'outils de Flash-Next) a été fermé le
  03/10/2026 ; sa synthèse est dans « Ticket #388 ».
- **À vérifier à la remesure de la 0.7.0** : #386, livré dans la 0.7.0
  (préfixe partagé repris sans `--cache-disk`), candidat au retrait de nos
  contournements du cache, à trancher sur la boucle `SANS_CACHE=1` ; le
  décode agentique de Flash-Next (44,7 à 46,4 contre 50,4 t/s en 0.2.0).

## Ce qu'est gufo

- Moteur HIP écrit à la main pour gfx1151, licence MIT. Testé au commit
  `9cad139` (image `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` du 24/09,
  ROCm 7.2.3 embarqué, `gufo diagnose` en PASS sur bigchuck), remesuré au
  commit `d9a84f1` le 26/09/2026, sur la v0.1.1 le 28/09/2026 (27B et
  Flash-Next), la v0.2.0 le 29/09/2026 (27B, Flash-Next et DeepSeek), puis la
  v0.4.0 et la v0.5.0 (« Suivi en amont »). Les deux premières mesures
  précèdent toute release : la v0.1.0 n'est publiée que le 28/09/2026.
- Pas un llama.cpp : noyaux spécialisés par modèle et par forme de matrice,
  en partie adaptés de llama.cpp / ggml (MIT, cf. leur
  `THIRD_PARTY_NOTICES.md`) et de ds4 (antirez) pour DeepSeek.
- Trois modèles de texte, tous dans le parc : Qwen3.8-27B,
  Qwen3.8-Flash-Next, DeepSeek V4 Flash (plus de l'audio, de l'image et de la
  vidéo).
- Un modèle par processus, pas de routeur, pas de n-gram, pas de budget de
  raisonnement ; API OpenAI compatible (`timings` au format llama.cpp dans le
  flux, `/metrics` sans compteur de cache ni de secondes).
- GGUF imposés. Refusés au chargement : notre Flash-Next Signal AP-Q4_K_XL
  (tenseur `output_hc_down.weight` en `IQ4_NL`) et notre DeepSeek UD-IQ3_XXS
  unsloth (format de stockage des experts). Seul le 27B (UD-Q4_K_XL + DFlash 2
  Q8_0) passe avec les fichiers du parc.

## Évaluation du 24/09/2026 : synthèse

Face à l'image `llm-rocm-strix`, série `strix-8c1c282+r7dda3ac`, sur les trois
modèles de texte de gufo. Protocole, tableaux complets, cache et sessions
réelles dans le journal (« Évaluation face au service »).

- **Banc HTTP**, 27B à fichiers identiques : prefill 547 contre 263 t/s
  (+108 %), décode en prose 48,9 contre 35,7 t/s (+37 %). Flash-Next et
  DeepSeek sur des quants différentes (gufo refuse les nôtres) : prefill
  +69 % et +212 %.
- **Boucle agentique pi**, 16/16 partout. Avec cache disque : 27B 40 contre
  57 s par passe, Flash-Next 31 contre 44 s, soit 30 % de temps en moins,
  90 % du prompt repris. Sans cache disque : 27B 56 contre 57 s, Flash-Next
  39 contre 44 s, gufo ne reprenant pas le préfixe commun d'une nouvelle
  conversation (14 débuts sur 16 recalculés).
- **Cache, ce qui conditionne le réglage** : le préfixe commun de deux
  conversations ne se reprend qu'avec `--cache-disk` ; le staging par défaut
  refuse les points de reprise trop gros (27B le 24/09, en silence à
  l'époque ; sessions réelles de Flash-Next le 26/09, journalisé depuis
  #279), d'où 8 Gio ; `--sessions 2` évite qu'une requête
  annexe évince la conversation (7 Gio de plus sur Flash-Next) ; changer la
  configuration du serveur vide le cache disque, la fixer une fois pour
  toutes.
- **Sessions réelles** (Claude Code via le proxy, omp, pi) : 86 à 93 % du
  prompt repris ; la reprise « un tour en retard » de Claude Code venait de
  llm-proxy, corrigé le 24/09/2026.
- **Récupérer ses optimisations dans le service** : légalement possible
  (MIT), techniquement coûteux, voie proposée et non lancée (profiler le 27B
  sur les deux moteurs, puis ticket chez halo-box/strix-llama.cpp) ; tableau
  dans le journal.

## Verdict

Bien configuré (`--cache-disk`, staging relevé), gufo fait le même travail
agentique en 30 % de temps en moins que le service sur le 27B (fichiers
identiques) comme sur Flash-Next (quant de base contre le fine-tune Signal),
et il gagne nettement sur les prompts neufs (prefill ×1,7 à ×3). C'est le
premier moteur qui bat le service sur son propre terrain.

Il ne le remplace pas pour autant, faute de :

- quants libres : le fine-tune Signal de Flash-Next et notre quant DeepSeek
  sont refusés, DeepSeek passe en IQ2XXS (comptage à 26k raté le 24/09,
  juste le 29/09 : justesse non établie sur une seule mesure) ;
- routeur : un modèle par processus, donc pas de bascule entre modèles, de
  WebUI ni de préchargement, et tout l'outillage du dépôt (`models.ini`,
  `--spec-tune`, `qualif-modele.sh`) serait à refaire ;
- n-gram : le service décode le code répété 58 % plus vite sur Flash-Next
  (banc HTTP) ; en agentique, gufo gagne quand même ;
- budget de raisonnement, et stabilité (quatre releases en quatre jours,
  v0.1.0 le 28/09 à v0.4.0 le 01/10/2026, deux contributeurs principaux ;
  la v0.4.0 régresse en boucle d'outils, #368, la v0.5.0 corrige le
  ralentissement mais pas la boucle de répétition de Flash-Next, qui
  n'est pas une régression : vue aussi en 0.2.0 le 03/10/2026, #388 ;
  nouveaux modèles et quants gelés en amont jusqu'à un produit stable, cf.
  #299).

Pistes, par ordre de faisabilité :

1. Gufo à la place du service pour un seul modèle, le 27B de préférence
   (mêmes fichiers, gain mesuré), lancé par `./setup-llm.sh --gufo 27b` ; les
   autres modèles du parc ne sont alors plus servis.
2. Gufo en second moteur à côté du service, sur un autre port. Points durs :
   la mémoire partagée (27B gufo environ 45 Gio) et deux points d'entrée.
3. Attendre un routeur ou un aiguillage multi-modèle en amont (rien de suivi à
   ce jour).

## Routeur : basculer entre le 27B et Flash-Next par le client

gufo ne sert qu'un modèle par processus et renvoie à llama-swap
(https://github.com/mostlygeek/llama-swap, MIT) pour exposer plusieurs
processus sous une même URL. `./setup-llm.sh --gufo` le fait toujours :
llama-swap (v257, épinglé par SHA-256, dans une image dérivée de celle de gufo,
sans socket docker) écoute sur `:8009` et lance `gufo serve llm` pour le modèle
demandé (lignes de commande dans `runtime-gufo/gufo-llama-swap.yaml`). Le
client choisit `qwen3.8-27b`, `qwen3.8-flash-next` ou `deepseek-v4-flash`
(IQ2XXS d'antirez, justesse à surveiller) par le champ `model`,
comme avec le routeur llama-server du service.

Mesures du 25/09/2026 (relais sans coût, bascules de 31,4 à 70,4 s, premier
token en 0,3 s sur un modèle déjà chargé) : tableau dans le journal
(« Routeur llama-swap, audio et image »).

Limites :

- un seul modèle à la fois (100 Gio + 45 Gio ne tiennent pas) : chaque
  bascule coûte 30 à 65 s, les fichiers ne restant pas tous en cache ;
- les rôles d'un client agentique (principal, tâches annexes) doivent viser le
  même modèle, sinon chaque requête annexe déclenche une bascule ;
- les autres modèles du parc restent sur le service : llama-swap ne peut pas
  piloter le routeur llama-server (autre image) sans la socket docker, que le
  dépôt s'interdit, et les deux ne tiennent pas ensemble en mémoire.

## Audio et image, derrière le même llama-swap

gufo sert aussi la synthèse vocale (Qwen3-TTS 12Hz 1.7B, trois variantes), la
transcription (Qwen3-ASR 1.7B) et la génération d'images (Qwen-Image-2.1, BF16,
licence non commerciale), sous les routes OpenAI audio et images. Mêmes
`gufo-llama-swap.yaml` et `./setup-llm.sh --gufo` : la voix et la
transcription sont chargées À CÔTÉ du modèle de texte (groupes persistants),
Qwen-Image partage le groupe exclusif des LLM.

Mesures du 25/09/2026 dans le journal : synthèse 2,5 fois le temps réel,
transcription en 3,2 s, image 1024² en 90,2 s, Flash-Next + voix +
transcription à 110 Gio.

Limites : 14 Gio de marge seulement avec Flash-Next, la voix et la
transcription chargés (DeepSeek laisse un peu plus, le 27B beaucoup plus) ;
une image coûte la bascule du LLM dans les deux sens ; le flux WebSocket de la
synthèse passe par `/upstream/<modèle>/`, pas par une route de llama-swap ;
voix et transcription déchargées après 60 s sans requête et limitées à une
file matérielle, sinon le GPU reste occupé à 100 % au repos (#272, section
« Suivi en amont »).

Depuis les clients, par le proxy (`http://llmproxy`, modèles préfixés
`bigchuck/`) : llm-proxy relaie la synthèse, la génération et l'édition
d'image, route les corps multipart (transcription, édition) d'après leur
champ `model` et sert `GET /v1/audio/voices` (commit bcaf63e du proxy).
Pour pi et omp, l'extension `tools/gufo-media.ts` ajoute deux outils :
`generer_image` (PNG dans le dossier de travail) et `parler` (lecture par
`pw-play`, voix intégrée ou décrite, cette dernière par VoiceDesign).
Vérifié le 25/09/2026 : `parler` sous pi en 10,6 s pour tout le tour,
`generer_image` 512² en 20 étapes sous omp en 90 s pour tout le tour (bascule
vers Qwen-Image, puis retour à Flash-Next pour la réponse).

Variante servie : `Qwen-Image-2.1-heretic` (encodeur de texte
« abliterated »), SEULE variante servie depuis le 25/09/2026, sans gain
constaté ni banc de régression ; essai détaillé dans le journal.

## Suivi en amont

Tickets et commentaires publiés sous le compte c4software. Suivi par
`tools/gufo-amont.sh` (lecture seule, `gh api`, choix du 28/09/2026) :
releases, images publiées, commits récents, état des tickets du tableau
ci-dessous (ses `| #NNN |` sont la liste suivie) et de ceux que nous avons
ouverts ; `ticket <n> [k]` lit un ticket ou une PR et ses commentaires.
Autorisé dans `.claude/settings.local.json`, pour que l'agent n'improvise
plus de commandes `gh`.

### À surveiller

Tickets ouverts seulement : un ticket fermé sort du tableau, ce qu'il a
changé reste dans le journal (#388, fermé le 03/10/2026, a sa synthèse plus
bas).

| Ticket | Sujet | État au 02/10/2026 (#259 : au 04/10/2026) |
|---|---|---|
| #259 | renommé : préfixes partagés réservés au cache disque, staging par défaut trop petit pour le 27B | ouvert (le nôtre) ; contournement en place : `--cache-disk` + staging 8 Gio ; point d'étape du mainteneur (fedeizzo) le 03/10/2026 sur `main` (1b4e6825) : reprise sans `--cache-disk` et apprentissage corrigés par #386, éviction en `--sessions 1` par #369, refus de staging journalisé ; reste le défaut de `--cache-disk-staging-bytes` (plafond fixe de 1 Gio à retirer), ticket fermable ensuite ; #386 est dans la 0.7.0, épinglée le 04/10/2026 : à vérifier à sa remesure, candidat au retrait de `--cache-disk` et du staging 8 Gio ; historique dans le journal |
| #239 | n-gram (prompt lookup) | ouvert ; résultat négatif en greedy, clôture proposée, puis jugé « worth experimenting » par le mainteneur (25/09), après les premiers bugs ; porte aussi le pool persistant de #263 depuis le 28/09 |
| #228 | ROCm 10 | verdict gufo : rester sur ROCm 7.2.3 (décode -5 % en ROCm 10) |
| #200 | runtime HRX + noyaux Loom | ouvert depuis août, +3,6 % de prefill 27B |
| #299 | PR : Qwen3.6-35B-A3B (`qwen35moe`, GDN + MoE 256 experts, MTP, DFlash 2), par slimsami, ouverte le 27/09 | **suivie à la demande de l'utilisateur** (28/09) : même architecture qu'Ornith-1.5-35B-A3B, notre modèle agentique par défaut (fine-tune de Qwen3.6-35B-A3B). Annoncé sur UD-Q6_K_XL : prefill 1 790 à 2 702 t/s contre 1 057 à 1 202 pour llama.cpp Vulkan, DFlash 2 à 83,3 t/s en glouton ; MTP pas encore branché dans `gufo serve`. À vérifier si elle est mergée : notre Ornith est en Q4_K_M (la PR ne cite que Q6_K et Q8_0 pour les experts), et gufo refuse les quants hors de ses formats ; le 30/09, **mise en attente par le mainteneur** : pas de nouveau modèle ni de nouvelle quant avant un produit stable avec les modèles actuels |

Constat du 29/09/2026 (v0.2.0), non revu depuis : rien n'est suivi en amont
sur d'autres quants (notre `IQ4_NL`), plusieurs modèles par serveur (« HTTP
model replacement not implemented »), un budget de raisonnement.

### Tickets : synthèse

Historique complet dans le journal.

- **#259 et #267, cache entre conversations** : #259 ouvert, #267 fermé le
  03/10/2026 par #386. Le 24/09/2026,
  ticket ouvert puis corrigé par nos soins (en grande partie une
  configuration) ; #279 (26/09) rend le staging automatique mais plafonné à
  1 Gio, insuffisant chez nous ; le 30/09 le mainteneur confirme les quatre
  points ; le 03/10/2026, trois sont corrigés : #369 (déjà dans la 0.5.0) et
  #386 (dans la 0.7.0).
- **#239, n-gram** : ouvert, deux commentaires de notre part le 24/09/2026,
  conception à pool persistant à suivre à part.
- **#272, GPU occupé à 100 % au repos** : le nôtre, du 25/09/2026, fermé par
  #317 en v0.2.0. Cause : plus de 8 files de calcul matérielles ouvertes,
  tous processus confondus. De notre contournement (`GPU_MAX_HW_QUEUES=1`,
  `ttl: 60`), seul `ttl: 60` reste sur la voix et la transcription.
- **#368, régression de la v0.4.0 sur les requêtes avec outils** : le nôtre,
  du 01/10/2026, fermé (ralentissement corrigé par #373 en 0.5.0).
- **#388** : section « Ticket #388 » plus bas.

### Versions : synthèse

Contenu, choix, mesures et lecture de chaque version dans le journal ; les
deux tableaux de remesure y sont aussi (« Mesures d'une version à l'autre »).

| Version | Date | Décision | À retenir |
|---|---|---|---|
| image `d9a84f1` | 26/09/2026 | déployée | prefill court de Flash-Next +5 % (#255), décode en prose du 27B -11 % avec l'acceptance, à confirmer ; staging automatique de #279 insuffisant, 8 Gio gardés |
| v0.1.1 (`b0f8673`) | 28/09/2026 | retenue, première image épinglée | gain dans le cache (un tiers de tokens recalculés en moins), pas dans le moteur ; cache disque toujours indispensable |
| v0.2.0 (`992113b`) | 29/09/2026 | retenue | échantillonnage officiel par défaut (#282), macro `qwen` réduite à `--think off` et macro `deepseek` retirée ; #272 corrigé (#317) ; DeepSeek remis en `--think off` après mesure |
| v0.3.0 (`fd1710b`) | 30/09/2026 | non montée | ni noyau, ni cache, ni serveur |
| v0.4.0 (`6aa87fc`) | 01/10/2026 | montée (`7c98484`) puis annulée (`b758eb7`) | 20 à 40 % de temps en plus sur les requêtes avec outils, boucle de 43 min sur Flash-Next (#368) |
| v0.5.0 (`23cacbb`) | 02/10/2026 | non retenue le 02/10, retenue le 03/10/2026 | ralentissement de #368 corrigé ; cache surtout en RAM (#348) ; boucle de Flash-Next toujours là, mais pas une régression (#388) |
| v0.6.0 (`cb46d63`) | 03/10/2026 | non montée, sautée | préfixes en cours partagés entre requêtes concurrentes (#382), sortie sur perte du contexte GPU (#390) |
| v0.7.0 (`aedc129`) | 04/10/2026 | montée le 04/10/2026, remesure en attente | préfixe partagé appris en RAM sans `--cache-disk` (#386, ferme #267) ; `--cache-ram-bytes` explicite au-delà du budget automatique (#384) ; métriques au format llama.cpp et `/slots` (#389, #403) ; aucun réglage changé |

## Ticket #388 : boucle d'appels d'outils de Flash-Next

Ticket ouvert par nous le 02/10/2026 à la demande du mainteneur (suite de
#368), **fermé le 03/10/2026 à 15:14 UTC par francescobozzo**
(collaborateur), état « completed » : « Ok, I'm closing the issue.
@c4software thanks a lot for your deep dive ». Les sept étapes de mesure, le
tableau des corrections et les échanges sont dans le journal (« Ticket
#388 »). Les mesures du raisonnement faible (étape 7) n'ont pas été publiées
dans le ticket avant sa fermeture.

Flash-Next en `--think off` (profil Qwen sans raisonnement de gufo,
presence 1,5), dans le scénario `creation` de la boucle pi, écrit parfois un
test dont la valeur attendue est fausse, le « corrige » vers une autre valeur
fausse, puis recopie sans fin le même appel d'outil.

### Conclusions au 03/10/2026

1. **Pas une régression** : boucle vue en 0.2.0, 0.4.0 et 0.5.0, même
   phénomène établi sur les sessions de la 0.2.0 et de la 0.5.0 (celle de la
   0.4.0 n'a pas de session), aucune différence 0.2.0 / 0.5.0 à pénalité
   égale (étapes 3 et 4). La boucle n'est plus un motif pour rester en 0.2.0.
2. **Ce qui décide, c'est le texte avant l'edit** : une correction précédée
   d'une phrase de raisonnement est juste, un edit sans texte est faux,
   quelle que soit la pénalité (étape 5).
3. **Presence 0,0 n'est pas un correctif établi** : 0 boucle sur 20 séries,
   sans coût mesurable, mais l'écart n'est pas significatif sur la 0.5.0
   seule, et la seconde valeur fausse arrive aussi à 0,0 au rejeu (étapes 2,
   4 et 5).
4. **Deux leviers côté client suppriment la fausse correction au rejeu** :
   une consigne dans le prompt système (environ +50 % de temps par passe,
   étape 6) et le raisonnement faible par requête (environ +60 %, étape 7),
   contre x2,3 pour `--think xhigh`.
5. **Décisions** : rien de changé au réglage d'usage ni posé dans la
   configuration de pi, d'omp ou du proxy ; le niveau de raisonnement se
   règle côté client, jamais au serveur (règle de l'utilisateur, étape 7).
6. **Non mesuré** : 10 séries 0.2.0 à presence 0,0 ; le même rejeu sur
   llama.cpp.

| Flash-Next, `--think off`, boucle pi | séries avec boucle |
|---|---|
| 0.2.0, presence 1,5 (avant le 03/10) | 0 sur 2 |
| 0.4.0, presence 1,5 | 1 sur 2 |
| 0.5.0, presence 1,5 | 2 sur 9 |
| 0.5.0, presence 0,0 | 0 sur 20 |
| 0.2.0, presence 1,5 (témoin du 03/10) | 1 sur 5 |

Chiffres qui portent ces conclusions :

- première correction fausse 6 fois sur 17 à presence 1,5, toutes versions,
  contre 0 sur 24 à 0,0 (p = 0,003), et toutes les boucles passent par là ;
- séries avec boucle, 0.5.0 seule : 2 sur 9 contre 0 sur 20 à 0,0, p = 0,09 ;
- rejeu de la première correction (0.2.0, 100 fois par bras) : 237 edits
  justes sur 237 avec une phrase avant l'edit, 63 faux sur 63 sans texte ;
- consigne côté pi et `reasoning_effort: low` (0.5.0) : 100 corrections
  justes sur 100 au rejeu, aucune boucle en 10 et 7 séries, somme des
  médianes par passe 45,2 s (consigne) et 49,1 s (low au serveur, 47,8 s par
  pi) contre 30,0 s.

## Reprendre les mesures

gufo se pilote depuis le point d'entrée du dépôt ; compose, téléchargement et
bancs sont versionnés dans [`runtime-gufo/`](../runtime-gufo/README.md). Les
données restent hors du dépôt et hors de `~/models`, dans `GUFO_DATA`
(défaut `~/llm/gufo-test` sur bigchuck, déjà peuplé) :

- `./setup-llm.sh --gufo [flashnext|27b|deepseek]` : gufo, toujours derrière
  llama-swap (section « Routeur » ci-dessus), à la place du service sur
  `:8009`, l'argument choisissant le modèle préchargé (compose
  `runtime-gufo/docker-compose.yml`, `.env` généré dans
  `GUFO_DATA`, 2 sessions par défaut, `GUFO_SESSIONS=N` pour changer, nom
  exposé `qwen3.8-27b` ou `qwen3.8-flash-next`, cache disque 16 Gio, staging
  8 Gio, utilisateur de l'hôte). `--gufo-off` pour revenir au service,
  `--gufo-logs` pour suivre les requêtes. Le dernier lancé repart seul au
  démarrage de bigchuck ; `--start` du service refuse tant que gufo tourne.
- `./setup-llm.sh --gufo-download image|flashnext|deepseek|all`
  (`runtime-gufo/download.sh`) : image et GGUF de référence aux révisions
  épinglées par gufo (Flash-Next UD-Q4_K_XL unsloth `38bb39e`, 104 Go ;
  DeepSeek IQ2XXS antirez `1cd7b56`, 87 Go, et DSpark `e7f0403`, 6 Go ;
  le drafter DFlash 2 Q4_K_M `2d9571f`, 1,1 Go, téléchargé pour la
  comparaison au Q8_0, mesuré identique et supprimé le 25/09/2026). Présents
  sur bigchuck (191 Go dans `GUFO_DATA/models`).
- `runtime-gufo/bench/run.sh gufo|llama <cas>...` : banc HTTP
  (`bench/mesure.py`). Cas gufo : `27b`, `flashnext`, `deepseek` ; cas service : `27b`, `flashnext`, `flashnext-large-ub`,
  `deepseek`.
- `runtime-gufo/bench/agentic.sh gufo|llama <cas>...` : boucle pi de
  `bench-agentic/`, `PASSES=3`, garde-temps d'une heure.
- Les deux bancs lancent gufo par `--gufo` sur le même port, en 1 session,
  sans redémarrage automatique, projet et `.env` séparés ; ils retirent un
  gufo d'usage réel au départ et relancent le service à la fin.
- `GUFO_DATA/resultats/` : `resultats.tsv` (banc HTTP), `chargements.tsv`,
  `reponses/` (textes générés), journaux gufo, `agentic/` (sorties pi et
  journaux gufo par requête). Les mesures du 24/09/2026 y sont, y compris
  celles faites avant le versionnement (étiquettes `gufo-flashnext-unsloth`,
  `gufo-deepseek-antirez`, `*-diskcache.*`). Le banc HTTP de cette journée
  tournait sans cache disque ; le compose l'active toujours, sans effet sur
  ce banc (préfixes aléatoires).
- `GUFO_DATA/essais/` : scripts d'essai non versionnés et leurs journaux
  (remesures, nuits de séries, essais de #388), regroupés le 03/10/2026 ;
  seule trace de la façon dont chaque essai a été lancé.

### Paramètres de gufo et leur origine

Gufo n'a pas de réglage de production « officiel ». Jusqu'au 25/09/2026, ses
défauts visaient un usage minimal (4 096 tokens de contexte, 128 générés) ;
depuis d5fd781 et #276, contexte et longueur de génération suivent llama.cpp
(contexte natif, génération jusqu'à EOS) ; depuis v0.2.0 (#282),
l'échantillonnage suit les profils officiels des modèles (glouton avant), ses
propres bancs restant en glouton. Les valeurs du tableau visent un usage
agentique comparable au service ; aucune n'est un réglage interne du moteur.
Dernière confrontation à la documentation amont : 04/10/2026, v0.7.0, sur le
diff de documentation seul (`--help` des deux images non comparé, à faire sur
bigchuck) : aucune option ajoutée, aucun défaut changé dans la documentation ;
`--cache-ram-bytes` explicite peut dépasser le budget automatique (non posée) ;
`--cache-disk` n'est plus le seul chemin de reprise d'un préfixe commun
(#386), gardé jusqu'à la remesure. Les
confrontations datées (26/09, v0.1.1, v0.2.0, v0.4.0, v0.5.0, v0.7.0) sont dans le
journal, à l'entrée de chaque version ; chaque montée de version y ajoute la
sienne et met cette ligne à jour.

| Paramètre | `runtime-gufo/gufo-llama-swap.yaml` | Défaut de gufo | Exemples gufo (guides des modèles) | Origine |
|---|---|---|---|---|
| `--context` | 262144 | contexte natif depuis d5fd781 (4096 avant) | 32768 | nous : contexte natif, celui du service ; redondant depuis d5fd781 (chargement : `context_tokens=262144`), gardé explicite parce que `capabilities.context` doit lui rester égal |
| `--sessions` | 2 | 1 | 2 | gufo (guides du 27B et de Flash-Next) et notre mesure (7 Gio, plus d'éviction par les requêtes annexes) |
| `--max-tokens` | non posé (-1, jusqu'à EOS) | -1 depuis #276 (128 avant) | non indiqué | gufo, comme le service (llama.cpp à -1, aucun `n-predict` dans le ini) ; 32768 explicite jusqu'au 26/09/2026, quand le défaut de 128 coupait un client sans `max_tokens` |
| échantillonnage | non posé (profil de gufo) ; temp 0,7, top-k 20, top-p 0,8, min-p 0, presence 1,5 explicites pour Qwen, temp 1,0, top-k 40, top-p 0,95 pour DeepSeek jusqu'au 29/09/2026 | profil officiel du modèle depuis v0.2.0 (#282) : Qwen sans raisonnement 0,7 / 0,8 / 20 / 1,5, avec 1,0 / 0,95 / 20 / 0 ; DeepSeek 1,0 / 0,95 / top-k 0 ; glouton avant | aucun | gufo, depuis v0.2.0 : Qwen officiel, profil instruct, celui des sections nothink du service et de nos anciennes valeurs ; surchargeable par requête |
| `--think` | off | raisonnement : Qwen effort xhigh, DeepSeek effort high depuis v0.2.0 (sans raisonnement avant) | non indiqué | nous : équivalent des sections nothink pour Qwen, mesuré le 02/10/2026 sur Flash-Next (0.2.0, boucle agentique pi, 3 passes) : `--think on --reasoning-effort xhigh` donne 16/16 aussi, mais 71,4 s par passe contre 30,9 s (x2,3, somme des médianes par scénario), 2,4 fois plus de tokens générés, décode 44,5 contre 50,4 t/s, acceptance MTP 76,2 contre 84,6 %, cache inchangé (93 %) ; à activer par requête côté client si besoin ; pour DeepSeek, raisonnement sans budget mesuré à +43 % de temps en agentique le 29/09/2026 (non posé entre la montée en 0.2.0 et cette mesure) |
| `--cache-disk` | activé, 16 Gio | désactivé (8 Gio si activé depuis #279) | non utilisé | nous : seul chemin de reprise d'un préfixe commun entre conversations jusqu'à la 0.5.0 (mesuré) ; depuis la 0.7.0 la RAM l'apprend aussi (#386, non remesuré chez nous), gardé le 04/10/2026 parce que le cache RAM est perdu à chaque redémarrage et à chaque bascule de modèle par llama-swap, retrait à trancher sur la boucle `SANS_CACHE=1` ; 16 Gio car partagé entre les modèles et un point de reprise Flash-Next de session réelle pèse 1,5 Go (8 Gio en garde environ 5), et `docs/SERVER.md` demande plus que les défauts pour le 27B à contexte long. Passé au défaut de 8 Gio le matin du 26/09/2026, remis à 16 Gio le jour même |
| `--cache-disk-staging-bytes` | 8 Gio | automatique depuis #279 : au plus 1 Gio et 1/8 de la RAM disponible (512 Mio fixes avant) | non utilisé | nous : au défaut, les points de reprise du 27B sont refusés dès ~8k tokens (4,5k avant #279), et le 26/09/2026 ceux de nos sessions Flash-Next (1,39 à 1,50 Go) l'ont été (`reason=staging_capacity`, journalisé depuis #279) ; non préalloué. Valeur que `docs/SERVER.md` recommande désormais pour Flash-Next à contexte plein |
| spéculatif (adaptatif, 7 tokens max), `--prefill-chunk` 512 | inchangés | défauts gufo | défauts gufo | gufo |
| `--max-pending-per-client` | inchangé (4) | 4 | non indiqué | gufo ; derrière llama-swap, toutes les requêtes viennent de 127.0.0.1, donc 4 en file au plus pour tous les clients réunis (aucun rejet vu à ce jour) |
| fichiers | Flash-Next UD-Q4_K_XL, MTP shared Q8_0, DFlash 2 Q8_0 | | UD-Q4_K_XL, MTP shared Q8_0, DFlash 2 Q4_K_M | gufo, sauf le drafter du 27B pris dans le parc (Q8_0, mesuré identique au Q4_K_M) |

Les chiffres agentiques avec cache disque ont été mesurés avec ces réglages ;
gufo « nu » (sans cache disque) était à égalité avec le service sur le 27B.

### Checklist de montée de version

À dérouler dans l'ordre à chaque nouvelle release de gufo. Règle : **les
étapes 1 à 3 ne font que lire ; rien n'est appliqué (épinglage, réglage,
contournement retiré, modèle remesuré ou non) sans question posée à
l'utilisateur et réponse reçue**, une question par décision, avec la mesure
ou la ligne de documentation qui la motive. La version mesurée en dernier
est celle de `GUFO_IMAGE` dans `lib/gufo.sh`.

Seconde règle (02/10/2026) : **toute validation se lance d'emblée en debug**
(gufo `-v` et sessions pi gardées), jamais une série normale suivie d'un
rejeu debug. Un incident rare (la boucle de #368, revue une fois sur
plusieurs séries) ne se reproduit pas forcément : son transcript doit venir de
la série qui l'a vu. `remesure.sh` le fait par défaut ; un appel direct à
`agentic.sh` pose `DEBUG=1 PI_SESSIONS=1`.

1. **Ce qui a changé** (lecture) :
   - `tools/gufo-amont.sh` : releases, images publiées, commits, tickets
     suivis (ceux du tableau « À surveiller », plus les nôtres) ;
   - `tools/gufo-amont.sh release <tag>` et le `CHANGELOG.md` amont ;
   - `tools/gufo-amont.sh ticket <n> 3` pour chaque ticket suivi qui a bougé,
     et chaque PR mergée qui touche le cache, le serveur, le 27B ou
     Flash-Next ;
   - repérer les tickets fermés, les questions qu'on nous pose (à noter
     pour l'étape 8) et les PR suivies (#299 : Ornith).
2. **Nouvelles recommandations de réglage** (lecture) :
   - `tools/gufo-amont.sh diff <version épinglée> <nouvelle>` : `docs/SERVER.md`,
     `docs/CLI.md`, guides et `QUALITY.md` / `EXPERIMENTS.md` des modèles ;
   - `gufo serve llm --help` des deux images, comparé (`docker run --rm
     --entrypoint gufo <image> serve llm --help`, sur bigchuck) : options
     ajoutées, retirées, défauts changés ;
   - confronter au tableau « Paramètres de gufo et leur origine » : chaque
     ligne tient-elle encore (défauts du cache disque et du staging,
     `--context`, `--sessions`, `--max-tokens`, échantillonnage, `--think`) ?
3. **Contournements encore utiles ?** (lecture) : staging 8 Gio (#259, #279),
   `ttl: 60` sur la voix et la transcription (#272, pour Qwen-Image au
   défaut du runtime depuis v0.2.0), `capabilities.context` de llama-swap,
   GGUF refusés (Flash-Next Signal en `IQ4_NL`, DeepSeek UD-IQ3_XXS, Ornith
   Q4_K_M si #299 est mergée).
4. **Questions à l'utilisateur**, avant tout changement : monter de version
   ou non ; quels modèles remesurer (DeepSeek n'est plus remesuré depuis le
   28/09/2026 sauf demande) ; chaque réglage ou contournement que les étapes
   2 et 3 proposent de changer ; la machine est-elle libre (les bancs
   coupent le service et gufo d'usage réel).
5. **Appliquer ce qui a été accepté** : `GUFO_IMAGE` de `lib/gufo.sh`,
   `runtime-gufo/download.sh` et `runtime-gufo/Dockerfile.routeur` (même
   version aux trois endroits), réglages dans
   `runtime-gufo/gufo-llama-swap.yaml` avec leur commentaire d'origine ;
   `./tests/sh-unit.sh`, `bash -n`, commit qui dit pourquoi, push ; sur
   bigchuck `git pull --ff-only` puis `./setup-llm.sh --gufo-download image`.
6. **Remesurer**, un GPU donc en séquence, sur les modèles retenus, en une
   commande : `nohup runtime-gufo/bench/remesure.sh 27b flashnext >
   ~/llm/gufo-test/remesure.log 2>&1 &` (`SANS_CACHE=1` pour ajouter la
   boucle sans cache disque ; boucles agentiques toujours en debug, gufo
   `-v` et sessions pi gardées, par défaut depuis le 02/10/2026 pour ne pas
   rejouer une série afin d'avoir le transcript d'un incident), qui enchaîne :
   - `runtime-gufo/bench/run.sh gufo 27b flashnext` : justesse d'abord
     (aiguilles, `sanity`), puis prefill court et à 52k, décode prose et
     code, cache au tour 2, mémoire, temps de chargement ;
   - `runtime-gufo/bench/agentic.sh gufo 27b flashnext` : 16/16, temps par
     passe, part du cache (disque / RAM / ratés) ;
   - la copie des journaux bruts de `resultats/agentic/`, que le banc
     écrase, dans `resultats/agentic/<date>-<version>/` (`avant/` = la
     remesure précédente), puis leur bilan par `runtime-gufo/bench/journal.py`
     et la relance de gufo d'usage réel.
7. **Lire les journaux**, pas seulement les débits : refus de staging
   (`reason=staging_capacity`), `cache_miss_reason`, points de reprise écrits,
   premier token des petites requêtes (un coût fixe par requête ne se voit
   pas à 52k), acceptance du spéculatif (une baisse de décode en prose peut
   venir d'elle et non du moteur).
8. **Documenter et répondre** : entrée de la release en tête de
   `docs/HISTORIQUE-GUFO.md` (contenu, choix, tableau contre la mesure
   précédente, confrontation des paramètres), ligne dans « Versions :
   synthèse » de « Suivi en amont », tableau « À surveiller » (tickets fermés
   retirés), tableau des paramètres (date de confrontation) ;
   réponses aux tickets où l'on nous a posé une question, **rédigées puis
   montrées à l'utilisateur avant publication**.
9. **Remettre l'usage réel** : `./setup-llm.sh --gufo flashnext` (ou le
   modèle d'avant), `/v1/models`, une requête avec `stop` par le proxy, voix
   et transcription si elles servent.

Pour rejouer contre une nouvelle version de gufo sans la checklist complète :
`runtime-gufo/download.sh image`, puis `runtime-gufo/bench/run.sh gufo 27b` et
`runtime-gufo/bench/agentic.sh gufo 27b`. Ce sont les deux mesures qui
comparent les moteurs à fichiers identiques ; les chiffres du service du
24/09/2026 (journal, « Évaluation face au service ») sont la référence.
