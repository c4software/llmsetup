# gufo : évaluation du 24/09/2026

Évaluation de [gufo](https://github.com/gufo-org/gufo), moteur d'inférence
spécialisé Strix Halo, face au moteur du service (image `llm-rocm-strix`,
série `strix-8c1c282+r7dda3ac`). Rien n'a été intégré au dépôt : ce document
garde les mesures, le verdict et ce qu'il faut surveiller pour y revenir.
Tout le banc et les fichiers sont conservés sur bigchuck (voir « Reprendre les
mesures »).

Le soir même, une seconde série a corrigé la première : sans `--cache-disk`,
gufo ne reprend pas le préfixe commun de deux conversations, et c'est ce qui
le faisait paraître à égalité en boucle agentique. Bien configuré, il y fait
le même travail en 30 % de temps en moins que le service. Les tableaux
agentiques ci-dessous donnent les deux séries.

## Ce qu'est gufo

- Moteur HIP écrit à la main pour gfx1151, sous licence MIT, testé au
  commit `9cad139` (image `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest`
  du 24/09, ROCm 7.2.3 embarqué, `gufo diagnose` en PASS sur bigchuck),
  remesuré au commit `d9a84f1` le 26/09/2026 et sur la release v0.1.1 le
  28/09/2026 (27B et Flash-Next, section « Suivi en amont »). Les deux
  premières mesures précèdent toute release : la v0.1.0 n'est publiée que le
  28/09/2026.
- Ce n'est pas un llama.cpp : noyaux spécialisés par modèle et par forme de
  matrice, dont une partie est adaptée de llama.cpp / ggml (MIT, cf. leur
  `THIRD_PARTY_NOTICES.md`), ainsi que de ds4 (antirez) pour DeepSeek.
- Trois modèles de texte seulement, tous dans le parc : Qwen3.8-27B,
  Qwen3.8-Flash-Next, DeepSeek V4 Flash (plus de l'audio, de l'image et de la
  vidéo hors sujet ici).
- Un modèle par processus, pas de routeur, pas de n-gram, pas de budget de
  raisonnement, API OpenAI compatible (`timings` au format llama.cpp dans le
  flux, `/metrics` sans compteur de cache ni de secondes).
- GGUF imposés. Refusés au chargement : notre Flash-Next Signal AP-Q4_K_XL
  (tenseur `output_hc_down.weight` en `IQ4_NL`) et notre DeepSeek UD-IQ3_XXS
  unsloth (format de stockage des experts). Seul le 27B (UD-Q4_K_XL + DFlash 2
  Q8_0) passe avec les fichiers du parc.

## Protocole

- Le service est arrêté pendant chaque passage gufo (`--stop`, relancé par
  trap `--start`), jamais deux moteurs en même temps sur le GPU.
- Gufo : `gufo serve llm --context 262144 --sessions 1`, spéculatif du
  modèle (`dflash2`, `mtp` avec tête shared Q8_0 et mmproj, `dspark`).
- Service : sections de production, réglages du `models.ini` inchangés.
- Banc HTTP (`mesure.py`) : mêmes requêtes aux deux moteurs, en streaming,
  débits à l'horloge du client recoupés avec les `timings` des moteurs.
  Justesse (prompt de `--bench-sanity`), conditions du `--bench` (contexte +
  tâche, 1 000 tokens, temp 0,7, seed 42+i, 3 passes), `spec-refactor`
  (1 500 tokens, 3 passes), prefill avec aiguille à 6,5k et 52k tokens (42k et
  5,3k sur DeepSeek, autre tokenizer), reprise de cache au tour 2 sur 32k.
  Préfixe aléatoire par requête : aucune reprise de cache entre passes.
- Boucle agentique (`agentic.sh`) : les scénarios de `bench-agentic/` (même
  image pi, même `scenarios.sh`), 3 passes + appel froid, pointés sur l'un ou
  l'autre moteur. Rien écrit dans `logs/bench-agentic.log`. Pour gufo,
  l'échantillonnage de la section est reporté en défauts serveur (Qwen : temp
  0,7, top-k 20, top-p 0,8, presence-penalty 1,5, `--think off` ; DeepSeek :
  temp 1,0, top-k 40, top-p 0,95), et le cache, le prefill et le décode sont
  relus dans son journal, requête par requête.
- Seconde série agentique (27B et Flash-Next) : gufo lancé par
  `serve-8009.sh` (remplacé depuis par `./setup-llm.sh --gufo`) sur le port
  du service, avec `--cache-disk` et
  `--cache-disk-staging-bytes 8589934592` (voir « Le cache »), même conteneur
  pi pointé sur `:8009`.

## Banc HTTP (médianes, gufo contre service)

| Modèle | prefill, prompt court (t/s) | prefill long (t/s) | décode, prose (t/s) | décode, code (t/s) | justesse | mémoire |
|---|---|---|---|---|---|---|---|
| **Qwen3.8-27B** (dense, mêmes fichiers UD-Q4_K_XL + DFlash 2 Q8_0) | 547 contre 263, soit **+108 %** | 502 contre 213 à 52k, soit **+136 %** | 48,9 contre 35,7, soit **+37 %** | 65,9 contre 52,4, soit **+26 %** | OK / OK | 44 contre 54 Gio |
| **Flash-Next** (MoE ; gufo UD-Q4_K_XL unsloth, service AP-Q4_K_XL Signal) | 1 391 contre 825, soit **+69 %** | 1 363 contre 964 à 52k, soit **+41 %** | non comparable (voir ci-dessous) | 61,6 contre 88,7, soit **-31 %** | OK / OK | 97 contre 106 Gio |
| **DeepSeek V4 Flash** (MoE ; gufo IQ2XXS antirez 87 Go, service UD-IQ3_XXS 104 Go) | 402 contre 129, soit **+212 %** | 457 contre 88 à 42k, soit **+419 %** | 34,1 contre 31,0, soit **+10 %** | 38,3 contre 33,5, soit **+14 %** | **KO** gufo (comptage à 26k : 1 au lieu de 8) / OK | 104 contre 119 Gio |

- Seul le 27B compare deux moteurs à fichiers identiques. Les lignes
  Flash-Next et DeepSeek mêlent moteur et quant.
- Drafter DFlash 2 Q4_K_M (celui que gufo recommande) contre Q8_0 : aucune
  différence sur gufo (541 / 48,7 contre 547 / 48,9).
- Flash-Next, base comme fine-tune et sur les deux moteurs, répond au prompt
  du `--bench` par des appels d'outils inventés et s'arrête avant 200 tokens :
  décode « prose » non mesurable pour ce modèle.
- Décode du code sur Flash-Next : gufo reste plat (61,7 / 61,8 / 59,0), le
  service monte avec les passes (59,5 / 88,7 / 107,9) grâce à `ngram-mod`,
  dont le pool semble persister d'une requête à l'autre (non vérifié dans le
  code).
- Reprise de cache au tour 2 d'une même conversation : 100 % partout, des
  deux côtés.
- Chargement gufo : 10 à 32 s (32 s à froid pour le 27B, 20 s pour
  Flash-Next et DeepSeek). Mémoire : relevé `free` global, approximatif.
- Le « KO » DeepSeek n'est arrivé qu'une fois, sur une seule mesure : quant
  IQ2XXS ou moteur, non tranché.

### Variante large-ub du service (Flash-Next, section `-large-ub`)

| Flash-Next, banc HTTP | gufo (UD-Q4_K_XL) | service ub 4096 | service ub 16384 |
|---|---|---|---|
| prefill, prompt court | **1 391** | 825 | 827 |
| prefill à 6,5k | **1 380** | 991 | 1 062 |
| prefill à 32,5k | **1 388** | 980 | 1 097 |
| prefill à 52k | **1 363** | 964 | 1 072 |
| décode code (3 passes) | 61,7 / 61,8 / 59,0 | 59,5 / 88,7 / 107,9 | 97,0 / 108,2 / 97,4 |
| mémoire utilisée | **97 Gio** | 106 Gio | 116 Gio |

Le grand micro-lot gagne 7 à 12 % de prefill dès 6,5k tokens et coûte 10 Gio.
Son décode à 97 t/s dès la première passe s'explique par l'instance qui venait
de servir la boucle agentique (pool `ngram-mod` déjà rempli), pas par le
micro-lot.

## Boucle agentique (pi, 3 passes, médianes)

16/16 partout, sur les deux moteurs, les trois modèles et les deux séries.

| Suite complète, par passe | gufo sans cache disque | gufo avec cache disque | service | gufo (cache disque) contre service |
|---|---|---|---|---|
| **Qwen3.8-27B** (mêmes fichiers) | 56 s | **40 s** | 57 s | **-30 %** de temps |
| **Flash-Next** (quants différentes) | 39 s | **31 s** | 44 s (46 s en large-ub) | **-30 %** de temps |
| **DeepSeek V4 Flash** (quants différentes) | 90 s | non rejoué | 116 s | -22 % sans cache disque |

| Détail par scénario | 27B gufo, cache disque | 27B service | Flash-Next gufo, cache disque | Flash-Next service |
|---|---|---|---|---|
| simple | **0,6 s** | 1,9 s | **0,5 s** | 2,4 s |
| outils (write + bash + read) | 4,7 s | **4,4 s** | **3,3 s** | 3,6 s |
| edit | **5,3 s** | 6,3 s | **4,3 s** | 5,1 s |
| création (module + tests) | **20,0 s** | 29,9 s | **14,3 s** | 23,4 s |
| bugfix | **9,3 s** | 15,0 s | **6,7 s** | 9,4 s |
| prompt repris du cache | 90 % | **92 %** | **91 %** | 83 % |
| temps en prefill / décode | **28 / 90 s** | 29 / 139 s | **16 / 71 s** | 33 / 96 s |
| prefill / décode réels (t/s) | **298 / 46,4** | 242 / 32,4 | 486 / **51,1** | **531** / 48,5 |

Première série, sans cache disque (pour mémoire) :

| Détail par scénario | 27B gufo | Flash-Next gufo | DeepSeek gufo | DeepSeek service |
|---|---|---|---|---|
| simple | 3,0 s | 1,5 s | **4,0 s** | 5,0 s |
| outils (write + bash + read) | 6,9 s | 4,3 s | **11,1 s** | 19,7 s |
| edit | 7,8 s | 5,3 s | **16,0 s** | 20,6 s |
| création (module + tests) | 25,6 s | 22,1 s | **27,4 s** | 43,2 s |
| bugfix | 12,3 s | 8,0 s | 25,9 s | **25,5 s** |
| tokens recalculés (tout le run) | 27,7k (30 %) | 27,3k (29 %) | 27,5k (30 %) | **11,3k (12 %)** |
| temps en prefill / décode | 63 / 101 s | 30 / 82 s | **92 / 179 s** | 102 / 255 s |
| prefill / décode réels (t/s) | 438 / 45,9 | 897 / 50,7 | **300 / 31,1** | 111 / 26,3 |

Lire les débits agentiques avec prudence : le prefill « réel » est une
moyenne dominée par de minuscules morceaux, puisque presque tout vient du
cache. Gufo sur Flash-Next (cache disque) : 37 requêtes de moins de 100
tokens recalculés à 131 t/s en moyenne (le coût fixe de la requête domine),
9 de 100 à 499 tokens à 470 t/s, 3 de 500 à 1 999 tokens à 1 172 t/s. Le
temps passé en prefill (16 s sur tout le run) dit plus que le débit moyen.
Le décode de Flash-Next (51 t/s) est son régime normal (parc : 46,7 au
`--bench`) ; le 27B dense s'en approche (46 t/s) grâce aux blocs de 7 tokens
de DFlash 2, bien acceptés sur du code. Identité des modèles vérifiée pour
chaque passage (fichier chargé par gufo, modèle demandé par pi), et appel
froid de 1 542 tokens côté service à 597 t/s sur Flash-Next contre 295 sur
le 27B, le rapport attendu.

L'appel froid n'est pas comparable : côté service, il comprend le chargement
du modèle à la demande (9,7 s, 21,6 s, 86 s), alors que gufo était déjà chargé.
Sur DeepSeek, le service a généré 20 % de tokens en plus (6,7k contre 5,6k) :
le raisonnement n'était sans doute pas réglé pareil (budget côté service,
défaut du template côté gufo).

### Le cache : la configuration compte

- Dans une même conversation, gufo reprend le prompt dès la configuration par
  défaut (94 % sur le 27B dans la première série).
- Le préfixe commun de deux conversations différentes (même prompt système,
  nouveau message) ne se reprend **qu'avec `--cache-disk`** : c'est le disque
  qui garde les points de reprise des préfixes partagés (au plus 4 par
  prompt, 128 tokens minimum). Sans lui, première série : 14 débuts de
  conversation sur 16 recalculés en entier (`prefix_changed`, 1 508 à 1 517
  tokens communs, 0 repris), même un prompt identique dès qu'une autre
  conversation s'est intercalée.
- Piège du 27B : un point de reprise pèse environ 165 Mo plus 0,1 Mo par token
  (575 Mo à 5k tokens), au-delà du `--cache-disk-staging-bytes` par défaut de
  512 Mio dès 4k tokens environ. Gufo renonce alors à l'écrire, sans le
  signaler dans son journal. Flash-Next (170 à 190 Mo) et DeepSeek (45 à
  57 Mo) restent loin de la limite aux tailles de prompt de pi.
- Période d'apprentissage : le point de reprise du préfixe apparaît à la 3e
  conversation qui le partage, et sert à partir de la 4e ou 5e. Mesuré sur un
  prompt système de 5k tokens : premier token en 8,5 à 9,1 s, puis 0,66 à
  0,74 s (5 045 tokens repris du disque).
- Avec cette configuration, seconde série : 12 requêtes servies par le disque,
  34 par la RAM, 3 ratés (l'apprentissage), soit 90 à 91 % du prompt repris,
  autant ou plus que le service.
- Pourquoi c'est décisif : en agentique, quand le cache marche, le prefill ne
  pèse qu'une petite part du temps (29 s sur 168 pour le service sur le 27B),
  et c'est le décode qui départage. Le prefill ×2 de gufo ne compte vraiment
  que sur les prompts neufs (document collé, première requête d'une session).

## Verdict

Bien configuré (`--cache-disk`, staging relevé), gufo fait le même travail
agentique en 30 % de temps en moins que le service sur le 27B (fichiers
identiques) comme sur Flash-Next (quant de base contre le fine-tune Signal),
et il gagne nettement sur les prompts neufs (prefill ×1,7 à ×3). C'est le
premier moteur qui bat le service sur son propre terrain.

Il ne le remplace pas pour autant, faute de :

- quants libres : le fine-tune Signal de Flash-Next et notre quant DeepSeek
  sont refusés, DeepSeek passe en IQ2XXS (un comptage raté, justesse non
  établie) ;
- routeur : un modèle par processus, donc pas de bascule entre modèles, de
  WebUI ni de préchargement, et tout l'outillage du dépôt (`models.ini`,
  `--spec-tune`, `qualif-modele.sh`) serait à refaire ;
- n-gram : le service décode le code répété 58 % plus vite sur Flash-Next
  (banc HTTP) ; en agentique, gufo gagne quand même ;
- budget de raisonnement, et stabilité (v0.1.0, commits quotidiens, deux
  contributeurs principaux).

Pistes, par ordre de faisabilité :

1. Gufo à la place du service pour un seul modèle, le 27B de préférence
   (mêmes fichiers, gain mesuré), lancé par `./setup-llm.sh --gufo 27b` ; les
   autres modèles du parc ne sont alors plus servis.
2. Gufo en second moteur à côté du service, sur un autre port. Points durs :
   la mémoire partagée (27B gufo environ 45 Gio) et deux points d'entrée.
3. Attendre un routeur ou un aiguillage multi-modèle en amont (rien de suivi à
   ce jour).

### Sessions réelles (Claude Code via le proxy, omp, pi, 24/09/2026 au soir)

Gufo Flash-Next sur `:8009` avec cache disque, cinq minutes d'usage réel,
42 tours principaux, contexte de 19,5k à 61,2k tokens :

- 92,7 % du prompt repris, premier token en 2,7 s en médiane (5,4 s pour
  90 % des tours), décode 53 t/s (acceptance MTP 85 %) sans baisse avec le
  contexte ;
- 150 s cumulées d'attente du premier token contre 122 s de génération :
  chaque tour repartait du point de reprise de l'avant-dernier tour (64k des
  125k tokens recalculés l'étaient déjà), et toutes les reprises venaient du
  disque (1,4 s minimum par tour). Ce n'est **pas** un défaut de gufo : la
  même session avec omp (OpenAI en direct, sans proxy) reprend le tour
  précédent entier depuis la RAM, 40 tokens seulement recalculés deux fois
  sur 34k, premier token en 1,0 s en médiane (0,5 à 3,9 s), 28 s d'attente
  cumulée pour 83 s de génération. Cause trouvée dans le proxy
  (llm-proxy) : un rappel `system` de Claude Code (`<total_tokens>…`) qui
  fermait la requête était reporté, au tour suivant, après le résultat
  d'outil d'après, donc le préfixe divergeait juste avant la dernière
  génération. Corrigé dans llm-proxy (commit du 24/09/2026, rappel gardé à sa
  place) : sur le même scénario Claude Code, tours de suivi repris en RAM,
  43 à 150 tokens recalculés au lieu de 1 800 à 1 960, premier token en 0,3 à
  0,5 s au lieu de 1,8 à 2,1 s. Le même proxy a retiré `stop` pour gufo
  (option `anthropic_drop_fields`) jusqu'à la correction de #260 : option
  supprimée le 26/09/2026 (commit 588776f du proxy) ;
- 6 requêtes sur 50 rejetées en `unsupported_field` : le proxy traduit les
  `stop_sequences` Anthropic en `stop`, que gufo refuse (reproduit, issue
  [#260](https://github.com/gufo-org/gufo/issues/260)).

Comparaison des trois clients sur le même gufo (Flash-Next, cache disque) :

| Session réelle | Claude Code via le proxy | Claude Code, proxy corrigé | omp (direct) | pi (direct) |
|---|---|---|---|
| Tours, contexte | 42, de 19,5k à 61,2k | 12, de 19,5k à 28,7k | 9, de 22,1k à 34,1k | 16, de 3,1k à 22,0k |
| Reprise | disque, avant-dernier tour | RAM, tour précédent | RAM, tour précédent | RAM, tour précédent |
| Prompt repris | 92,7 % | 90,5 % | 86,2 % | 91,0 % |
| Tokens recalculés deux fois | 64k sur 125k | 7 sur 28k | 40 sur 34k | 7 sur 19k |
| Premier tour (prompt système) | 16,7 s | 15,4 s | 16,8 s (22k tokens) | 2,4 s (3,1k tokens) |
| Premier token ensuite, médiane | 2,7 s | **0,5 s** | 1,0 s | 0,8 s (0,3 à 3,0) |
| Attente cumulée / génération | 150 / 122 s | 26 / 56 s | 28 / 83 s | 18 / 97 s |
| Décode, médiane | 53 t/s | 46 t/s | 40 t/s | 50 t/s |
| Requêtes rejetées | 6 sur 50 (`stop`) | 0 | 0 | 0 |

Avec `--sessions 1`, une requête annexe de Claude Code (titre, 770 tokens)
prend la place de la conversation en RAM, et le tour suivant repart du disque
(2,3 s au lieu d'environ 0,5 s). Avec `--sessions 2` (défaut de
`./setup-llm.sh --gufo`), la seconde session coûte 7 Gio sur
Flash-Next (100,4 Gio de GPU contre 93,4, 26,7 Gio de RAM encore libres) et
règle le problème : même scénario Claude Code, 11 tours de suivi sur 11 repris
depuis la RAM, aucun depuis le disque, y compris après une requête annexe de
29,8k tokens ; une petite requête annexe tourne en parallèle du tour principal
(`batch_width=2`) ; décode inchangé (46 t/s). Changer la configuration du
serveur vide le cache disque (le prompt système de Claude Code repart en
`no_checkpoint`) : la fixer une fois pour toutes.

Aucune session équivalente n'a été jouée sur le service : pas de comparaison
directe pour cet usage.

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

| Mesure du 25/09/2026, bigchuck | Résultat |
|---|---|
| Relais par llama-swap | sans coût : décode vu du client 47,4 t/s contre 47,6 mesurés par gufo |
| Bascule Flash-Next vers 27B (arrêt de l'un, chargement de l'autre) | 64,6 s avant le premier token |
| Bascule 27B vers Flash-Next | 31,4 s |
| Bascule Flash-Next vers DeepSeek (IQ2XXS) | 70,4 s, réponse juste ; sans raisonnement par défaut (le gabarit d'antirez répond directement, là où la section du service raisonne avec un budget de 6 144 tokens) |
| Modèle déjà chargé | premier token en 0,3 s |
| Requête avec `stop` | acceptée ; retiré par llama-swap jusqu'au 26/09/2026, transmis depuis (gufo#260 corrigé, arrêt vérifié en OpenAI et en Anthropic) |
| Mémoire | un seul modèle chargé à la fois (99 Gio avec Flash-Next) |

Limites :

- un seul des deux modèles à la fois (100 Gio + 45 Gio ne tiennent pas) :
  chaque bascule coûte 30 à 65 s, les fichiers ne restant pas tous en cache ;
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

| Mesure du 25/09/2026, bigchuck (Flash-Next préchargé) | Résultat |
|---|---|
| Synthèse (CustomVoice, voix intégrée « aiden ») | 6,5 s d'audio en 2,6 s, soit 2,5 fois le temps réel ; chargement quasi nul (2,9 s au premier appel) |
| Transcription du WAV produit | 3,2 s chargement compris ; texte fidèle, noms propres approximés (« Big Jack », « Guffaw », « Lama Swap ») |
| Flash-Next + voix + transcription chargés ensemble | 110 Gio utilisés, 14 Gio libres ; Flash-Next répond toujours en 0,4 s |
| Image 512², 20 étapes | 16,3 s, bascule depuis Flash-Next comprise |
| Image 1024², 40 étapes (défaut) | 90,2 s, image conforme à la demande |
| Retour à Flash-Next après une image | 38,0 s ; voix et transcription restées chargées |

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

Variante `Qwen-Image-2.1-heretic` (encodeur de texte « abliterated »
catplusplus/Qwen21_Text_Encoder_Heretic, seul candidat compatible sur HF : les
versions « uncensored » sont des GGUF ou des formats ComfyUI, que gufo ne lit
pas), essayée le 25/09/2026 : chargement et temps identiques à l'officiel
(9 s en 512², 20 étapes). Sur 4 prompts à graine fixe (un témoin neutre, et
volley de plage, bikini, gymnaste, les cas où la fiche annonce des vêtements
ajoutés ou des poses figées), les images sont quasi identiques (écart RMS de
2 % sur le témoin) et l'officiel ne montre aucun des défauts annoncés. Pas de
gain constaté ; images dans `~/llm/gufo-test/resultats/heretic/`.
Seuls 54 tenseurs sur 749 diffèrent (`o_proj` et `down_proj` des couches 9 à
35 du langage, signature d'une abliteration) ; vision, transformer et VAE
sont identiques bit à bit. Retenue malgré tout comme SEULE variante servie
(choix du 25/09/2026, sans banc de régression : texte dans l'image, prompts
complexes et édition non vérifiés) ; `bigchuck/Qwen-Image-2.1-heretic` par le
proxy, défaut de `tools/gufo-media.ts`.

## Récupérer ses optimisations dans le service

Légalement possible (MIT, mention de copyright), techniquement coûteux : les
noyaux sont spécialisés par modèle et par forme, hors du moule des opérations
ggml. Par ordre d'intérêt :

| Optimisation gufo | Cible côté llama.cpp | Gain attendu | Difficulté |
|---|---|---|---|
| GEMM du prefill directement sur poids quantifiés, réglées gfx1151 | `mmq` de ggml-hip | le prefill ×2 du 27B à fichier identique | élevée |
| Attention : tuiles de KV partagées entre têtes, lignes de vérification groupées | `fattn` HIP | vérification ×3 à 32k selon eux, décode en contexte profond | élevée |
| Longueur de brouillon adaptative, coût et acceptance pondérée | spéculatif de llama.cpp (C++ pur) | remplacerait le `n-max` fixe de `--spec-tune` | moyenne |
| Lecture parallèle des poids, huge pages | chargeur | chargement, environ 2 % de décode | faible |

Le mécanisme existe déjà (`runtime/patches/`, suivi dans
`runtime/AMONT.md`), mais maintenir des noyaux HIP maison va contre le KISS du
dépôt. Voie proposée, non lancée : profiler le 27B sur les deux moteurs (même
fichier, même prompt) pour localiser l'opération qui fait le ×2, puis ouvrir
un ticket chez halo-box/strix-llama.cpp avec la mesure et le lien vers le code
gufo. Personne n'y a encore mentionné gufo.

## Suivi en amont

Publié le 24/09/2026 sous le compte c4software :

- [#259](https://github.com/gufo-org/gufo/issues/259) : cache non réutilisé
  entre conversations au même préfixe. Corrigé par nos soins le même soir en
  deux commentaires : c'était en grande partie une configuration (`--cache-disk`
  absent, staging trop petit pour le 27B), chiffres agentiques à l'appui. Restent
  trois points pour gufo : limite de staging qui coupe en silence, préfixes
  partagés réservés au disque, période d'apprentissage. Réponse du mainteneur
  le 25/09/2026 : journal quand une sauvegarde dépasse le staging, défaut de
  512 Mio revu (idéalement déduit du modèle) et documentation de
  `--cache-disk` en une seule modification ; `--sessions 2` documenté pour les
  clients agentiques ; préfixes partagés en RAM et apprentissage déplacés
  dans [#267](https://github.com/gufo-org/gufo/issues/267) ; identité du cache
  disque (nombre de sessions ?) à examiner. Notre réponse : prêts à rejouer la
  même boucle agentique sur les deux correctifs.
- [#239](https://github.com/gufo-org/gufo/issues/239) : deux commentaires sur
  le n-gram. Le même jour, un contributeur y a publié un résultat négatif :
  recherche dans le prompt en complément de la MTP, greedy, +0,2 à 1,1 %
  seulement (la MTP accepte déjà 92 % en greedy). Notre réponse : mesure en
  temp 0,7 et gain lié à un pool persistant, donc conception différente, à
  suivre dans un ticket séparé.

Publié le 25/09/2026 :

- [#272](https://github.com/gufo-org/gufo/issues/272) : bigchuck ventilait en
  permanence au repos (GPU occupé à 100 %, ~30 W contre ~4 W, 50 °C), jamais
  vu avec le service. Ouvert d'abord contre la voix, renommé après enquête :
  le GPU reste occupé dès que plus de 8 files de calcul matérielles sont
  ouvertes, tous processus confondus. Le LLM en ouvre 5, la voix et la
  transcription 4 chacune (défaut HIP), donc LLM + un serveur audio = 9 ; le
  simple chargement suffit, sans requête. Démarche détaillée dans le
  commentaire du ticket : état du processus (threads endormis, pas
  d'éviction), lecture du code (aucune boucle, tout synchronisé), sondes
  ctypes isolées (HIP, rocBLAS, copie des poids : 0 %), réglages du runtime
  un par un (seul `GPU_MAX_HW_QUEUES` change le résultat, seuil sur le total
  des files). Mesures :

  | Chargés (Flash-Next résident, 5 files) | Files de calcul | GPU au repos |
  |---|---|---|
  | LLM seul | 5 | 0 % |
  | + voix, défaut | 9 | 100 % |
  | + voix, `GPU_MAX_HW_QUEUES=2` | 8 | 0 % |
  | + voix, `GPU_MAX_HW_QUEUES=1` | 7 | 0 % |
  | + transcription, défaut / `=1` | 9 / 7 | 100 % / 0 % |
  | + voix et transcription, `=1` toutes deux | 9 | 100 % |

  Vitesse inchangée avec `GPU_MAX_HW_QUEUES=1` (synthèse 2,23 à 2,28 s,
  transcription 0,45 s, avant comme après). Contournement en place depuis le
  commit e7cc120 (`runtime-gufo/gufo-llama-swap.yaml`) : `GPU_MAX_HW_QUEUES=1`
  et `ttl: 60` sur la voix et la transcription ; vérifié après redéploiement
  (LLM + voix au repos : 0 %, voix déchargée au bout de 60 s). À surveiller :
  une correction côté gufo (serveurs audio sur une seule file par défaut,
  limite documentée, 5 files du LLM à justifier) permettrait de retirer le
  `env` et le `ttl`. Le 27B et DeepSeek n'ont pas été comptés (le LLM
  pourrait ouvrir un autre nombre de files). Rejoué le même soir après mise à
  jour et redémarrage de bigchuck (noyau 7.2.5 vers 7.2.7-1-cachyos,
  `linux-firmware-amdgpu` 20260916) : toujours là (LLM + voix sans
  contournement, 5 + 4 files : 99 à 100 % ; avec, 5 + 2 : 0 à 1 %).

À surveiller :

| Ticket | Sujet | État au 28/09/2026 |
|---|---|---|
| #259 | renommé : préfixes partagés réservés au cache disque, staging par défaut trop petit pour le 27B | ouvert (le nôtre), résumé en tête et dernier commentaire sur `--sessions` ; contournement : `--cache-disk` + staging relevé ; la reprise « un tour en retard » vue avec Claude Code vient du proxy (omp reprend depuis la RAM), commentaire corrigé ; plan du mainteneur le 25/09 : points 1 à 3 (staging) et `--sessions 2` documentés, le reste dans #267 ; le 26/09, point 1 corrigé par la PR #279 (d9a84f1 : staging automatique au plus petit de 1 Gio, 1/8 de la RAM disponible et de la rétention disque, rétention par défaut 8 Gio, instantanés refusés journalisés), point 2 : 1 Gio, seuil fixe reconnu imparfait ; le 26/09, 11 points de reprise Flash-Next réels de 1,39 à 1,50 Go refusés au défaut : staging gardé à 8 Gio, remesure agentique inchangée ; commentaire du 26/09 avec les refus et la remesure, suggestion d'un staging automatique déduit du modèle chargé ; le 26/09 au soir, un utilisateur affirme que sur l'image `20260926T093925` la reprise d'un préfixe partagé marche **sans** `--cache-disk` (6,3 s ramenées à 0,1 s), mais en rejouant trois fois la même requête, pas une nouvelle conversation après une autre : vérifié chez nous le 28/09 (section « Release v0.1.1 ») |
| #267 | préfixes partagés gardés en RAM sans `--cache-disk`, apprentissage compris (ouvert par le mainteneur, nos chiffres en appui) | ouvert ; latence depuis la RAM à mesurer, rien de promis |
| #272 | GPU occupé à 100 % au repos (~30 W, ventilateurs) dès que plus de 8 files de calcul matérielles sont ouvertes, tous processus confondus : LLM (5) + voix ou transcription (4) | ouvert (le nôtre), **pris en charge** le 28/09 (fedeizzo, étiquette `triaged`) ; contournement en place (e7cc120) : `GPU_MAX_HW_QUEUES=1` (2 files) et `ttl: 60` sur la voix et la transcription, sans perte de vitesse mesurée ; toujours reproduit en noyau 7.2.7 et firmware 20260916. Leur piste : le chargement des poids ouvre 16 flux (`kReaders = 16`, `weight_upload.cpp`) et HIP garderait les files matérielles derrière eux pour toute la vie du processus ; `GPU_MAX_HW_QUEUES` fixé par gufo est leur dernier choix. Ils demandent : coût en débit (LLM avec 9 files contre 5), décompte des files par phase (avant, pendant, après le chargement) et effet de `--sessions N` ; à retirer si gufo limite ses files |
| #260 | `stop` refusé (les `stop_sequences` Anthropic traduites par un proxy) | **fermé** le 25/09 (le nôtre) : `stop` et `stop_sequences` pris en charge (9854ca5, 363d6a1) ; retrait de `stop` supprimé le 26/09 dans llama-swap (`stripParams`) et dans llm-proxy (588776f) |
| #268 | défauts serveur trop bas pour un usage agentique (`--max-tokens` 128, staging 512 Mio), ouvert par un utilisateur | **fermé** le 26/09 avec #279 : `--max-tokens` corrigé par #276 (défaut -1, jusqu'à EOS), contexte natif par défaut (d5fd781), staging automatique (1 Gio au plus, trop peu pour nous) |
| #263 | n-gram persistant autonome, à la llama.cpp `ngram-mod`, en option (le nôtre, issu de #239 ; mesure indépendante : ×1,6 à chaud) | ouvert |
| #248 | suite de conversation ratée quand la réflexion est active | **fermé** le 27/09 par la PR #281 (c362049, dans v0.1.1) : point de reprise posé avant l'ouverture de la réponse de l'assistant, plus un point sur le prompt entier pour les relances à l'identique ; la PR note que le raté se reproduisait **aussi en `--think off`** (notre réglage) quand le client retire ou interrompt une réponse ; reste #266 (budget de `max_tokens` consommé par le raisonnement) |
| #239 | n-gram (prompt lookup) | résultat négatif en greedy, clôture proposée |
| #255 | GEMM W8A8 du prefill Flash-Next, +5 % (pwilkin) | **mergé** le 25/09 (98641a6) |
| #228 | ROCm 10 | verdict gufo : rester sur ROCm 7.2.3 (décode -5 % en ROCm 10) |
| #200 | runtime HRX + noyaux Loom | ouvert depuis août, +3,6 % de prefill 27B |
| #257 | outils mal formés tolérés (clients agentiques) | **mergé** le 25/09 (bec9787) |
| #256 | format HGN de halogen (spécification en salle blanche) | **fermé** le 25/09 : refusé (pas de concurrence avec halogen) |
| #299 | PR : Qwen3.6-35B-A3B (`qwen35moe`, GDN + MoE 256 experts, MTP, DFlash 2), par slimsami, ouverte le 27/09 | **suivie à la demande de l'utilisateur** (28/09) : même architecture qu'Ornith-1.5-35B-A3B, notre modèle agentique par défaut (fine-tune de Qwen3.6-35B-A3B). Annoncé sur UD-Q6_K_XL : prefill 1 790 à 2 702 t/s contre 1 057 à 1 202 pour llama.cpp Vulkan, DFlash 2 à 83,3 t/s en glouton ; MTP pas encore branché dans `gufo serve`. À vérifier si elle est mergée : notre Ornith est en Q4_K_M (la PR ne cite que Q6_K et Q8_0 pour les experts), et gufo refuse les quants hors de ses formats |

Image `gufo-runtime:latest` republiée le 26/09/2026 (`20260926T093925`,
`sha256:09507c0…`, commit d9a84f1 ou plus récent) : contient #255, #257, #260
et #279, déployée sur bigchuck le même jour (`stop` vérifié en OpenAI et en
Anthropic, jusqu'au proxy). Le staging automatique de #279 (1 Gio) ne suffit
pas à notre usage : au redémarrage, 11 points de reprise Flash-Next de 1,39 à
1,50 Go refusés ; staging gardé à 8 Gio. Rétention passée au défaut de 8 Gio
pour la remesure ci-dessous, puis remise à 16 Gio le même jour, et
`--max-tokens 32768` retiré (défaut -1 de #276) : voir « Paramètres de gufo et
leur origine ».

Remesure du 26/09/2026 (gufo d9a84f1, staging 8 Gio, rétention 8 Gio, 27B et
Flash-Next seulement, mêmes bancs, 1 session), contre la référence gufo du
24/09 :

| gufo, 26/09 contre 24/09 | Qwen3.8-27B | Flash-Next |
|---|---|---|
| prefill, prompt court (t/s) | 560 contre 548 | 1 462 contre 1 391, soit +5 % |
| prefill à 52k (t/s) | 506 contre 502 | 1 379 contre 1 363 |
| décode, prose (t/s) | 43,7 contre 49,0, soit -11 % (acceptance DFlash 64,6 à 69,7 % contre 68,6 à 71,2 %) | non mesurable (arrêt avant 200 tokens) |
| décode, code (t/s) | 66,1 contre 65,8 (acceptance 97 à 98 %) | 61,8 contre 61,6 |
| justesse, cache au tour 2 | OK, 100 % | OK, 100 % |
| boucle agentique, médiane par passe | 16/16, 41,3 s contre 40 s | 16/16, 29,9 s contre 31 s |
| prompt repris (disque / RAM / ratés) | 90,2 % (12 / 34 / 3) contre 90 % | 88,8 % (11 / 34 / 4) contre 91 % |
| temps en prefill / décode, tout le run | 28 / 94 s contre 28 / 90 s | 23 / 78 s contre 16 / 71 s |

- Aucun point de reprise refusé pendant les boucles agentiques (36 écrits
  sur le 27B) : le staging de 8 Gio tient.
- La baisse du décode en prose du 27B suit celle de l'acceptance, pas la
  vitesse du moteur : à acceptance quasi totale (code), le décode est
  inchangé. Échantillonnage à temp 0,7, texte généré différent d'une version
  à l'autre ; à confirmer sur plus de passes avant d'y voir une régression.
- Prefill Flash-Next +5 % à prompt court, cohérent avec #255 (GEMM W8A8).
- Flash-Next agentique : première passe à 47 s (cache disque neuf, période
  d'apprentissage), les deux suivantes à 29,9 et 28,7 s.
- Les journaux agentiques bruts de la première série du 24/09 (sans cache
  disque, `agentic/gufo-27b.*` et `gufo-flashnext.*`) ont été écrasés par
  cette remesure ; leurs chiffres restent dans ce document.
- Résultat et refus du staging à 1 Gio publiés dans #259 le 26/09/2026.

### Release v0.1.1 (28/09/2026)

gufo publie des versions depuis le 28/09/2026 : v0.1.0 (`06ed62f`, simple mise
en place de la publication) puis v0.1.1 (`b0f8673`) le même jour. Les images
portent désormais des tags de version (`0.1.1`, `0.1`, `latest` pour la
dernière stable, `edge` et `sha-…` pour la branche principale), en plus des
tags datés d'avant (`20260926T093925`, `20260927T101849`). Contenu depuis
d9a84f1, pour ce qui nous touche : #281 (points de reprise Qwen, ferme #248),
#301 (reprise des requêtes annulées), #288 (borne du prompt rendu calculée
sur le contexte de la session), #292 (attention clairsemée de Flash-Next),
#294 (découpage en tokens des prompts Qwen proportionnel à leur longueur),
#284 et 30392d5 (arguments d'outils Qwen), #293 (plus de contrôle de
`general.basename`) ; à côté : sortie JSON contrainte (#283), complétions
brutes pour banc (#286), journal de progression optionnel (#289).

Choix du 28/09/2026 :

- **Image épinglée** sur `gufo-runtime:0.1.1` (`sha256:2e7ffbd…`) au lieu de
  `latest`, dans `lib/gufo.sh` (`GUFO_IMAGE`), `runtime-gufo/download.sh` et
  `runtime-gufo/Dockerfile.routeur` : comme pour le service, une image est
  une série de mesures, la version ne bouge plus toute seule. Monter de
  version : « Checklist de montée de version » (section « Reprendre les
  mesures »), questions à l'utilisateur avant d'appliquer.
- **Suivi en amont par un script** : `tools/gufo-amont.sh` (lecture seule,
  `gh api`) affiche releases, images publiées, commits récents et l'état des
  tickets du tableau ci-dessus (ses `| #NNN |` sont la liste suivie) et de
  ceux que nous avons ouverts ; `ticket <n> [k]` lit un ticket ou une PR et
  ses commentaires. Autorisé dans `.claude/settings.local.json`, pour que
  l'agent n'improvise plus de commandes `gh`.
- **PR #299 suivie** (Qwen3.6-35B-A3B, l'architecture d'Ornith) : voir le
  tableau.
- **DeepSeek non remesuré** (choix de l'utilisateur) : seuls le 27B (fichiers
  identiques au service) et Flash-Next sont rejoués.
- **Remesure** : banc HTTP (`run.sh gufo 27b flashnext`), boucle agentique
  avec cache disque (réglage d'usage), puis la même boucle **sans** cache
  disque, pour vérifier dans notre scénario l'affirmation de #259 (reprise
  des préfixes partagés sans disque). Journaux bruts dans
  `GUFO_DATA/resultats/agentic/2026-09-28-0.1.1/` (`avant/` garde ceux du
  26/09).

Remesure du 28/09/2026 (gufo 0.1.1 `b0f8673`, staging 8 Gio, rétention
16 Gio, 1 session), contre celle du 26/09 (d9a84f1). Débits du banc HTTP à
l'horloge du client, médianes des trois passes ; agentique relu dans le
journal de gufo, requête par requête :

| gufo, 0.1.1 contre 26/09 | Qwen3.8-27B | Flash-Next |
|---|---|---|
| prefill, prompt court (t/s) | 524 contre 560 | 1 307 contre 1 444, soit **-9,5 %** (premier token 1,05 s contre 0,95) |
| prefill à 6,5k (t/s) | 585 | 1 381 contre 1 411 |
| prefill à 52k (t/s) | 505 contre 506 | 1 379 contre 1 379 |
| décode, prose (t/s) | 47,2 contre 43,7 (acceptance à surveiller, voir 26/09) | non mesurable (arrêt avant 200 tokens) |
| décode, code (t/s) | 65,5 contre 66,1 | 62,2 contre 61,8 |
| justesse, aiguilles, cache au tour 2 | OK, 100 % | OK, 100 % |
| mémoire (relevé `free`) | 52 Gio | 95 Gio |
| boucle agentique, médiane par passe | 16/16, **38,8 s** contre 41,3 s | 16/16, 30,4 s contre 29,9 s |
| prompt repris (RAM / disque / ratés) | **92,9 %** (35 / 12 / 3) contre 90,2 % | **92,6 %** (36 / 12 / 3) contre 88,8 % |
| tokens recalculés, tout le run | **6,2k** contre 8,4k | **6,6k** contre 9,4k |
| temps en prefill / décode, tout le run | **17** / 95 s contre 28 / 94 s | **11** / 79 s contre 23 / 78 s |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | **212 ms** contre 346 | **172 ms** contre 236 |
| acceptance du spéculatif (réponses de plus de 20 tokens) | 71,4 % contre 71,0 % | 85,7 % contre 86,5 % |
| points de reprise écrits / refusés par le staging | 61 / 0 (36 / 0 le 26/09) | 42 / 0 |

- Le gain de v0.1.1 est dans le cache, pas dans le moteur : un tiers de
  tokens recalculés en moins et un prefill agentique divisé par 1,6 à 2,
  conformes à #281 (point de reprise avant la réponse de l'assistant, y
  compris en `--think off`) et #301. Le 27B y gagne 6 % de temps ; sur
  Flash-Next, les 12 s de prefill gagnées sur tout le run disparaissent
  dans la variation du décode d'une passe à l'autre (création de 15,0 à
  21,5 s selon la passe, temp 0,7).
- Second point de reprise par requête (#281) : 61 écritures au lieu de 36
  sur le 27B, aucune refusée, le staging de 8 Gio tient.
- Prefill à prompt court de Flash-Next en baisse de 9,5 % (27B : -6 %),
  inchangé à 52k : un coût fixe d'environ 0,1 s par requête neuve, sans
  doute la copie du point de reprise supplémentaire. Invisible en
  agentique, où les petites requêtes répondent au contraire plus vite.
  Le gain de #292 annoncé par gufo (décode sans spéculatif +6,7 % à 32k)
  n'est pas mesuré par ce banc (décode à contexte court, MTP actif).

Même boucle **sans** cache disque (macro sans `--cache-disk`, le temps du
run), pour vérifier l'affirmation portée dans #259 :

| gufo 0.1.1, agentique | 27B avec cache disque | 27B sans | Flash-Next avec | Flash-Next sans |
|---|---|---|---|---|
| médiane par passe | **38,8 s** | 50,5 s (56 s le 24/09) | **30,4 s** | 34,2 s (39 s le 24/09) |
| prompt repris | **92,9 %** | 71,6 % | **92,6 %** | 70,6 % |
| tokens recalculés | **6,2k** | 24,9k | **6,6k** | 24,8k |
| temps en prefill | **17 s** | 53 s | **11 s** | 24 s |
| ratés `prefix_changed` | 2 | 14 | 2 | 14 |

Sans cache disque, les 14 débuts de conversation sont toujours recalculés en
entier (1 508 ou 1 517 tokens communs avec un point de reprise en RAM,
aucun repris), exactement comme le 24/09 : le préfixe commun de deux
conversations DIFFÉRENTES ne se reprend toujours que par le disque (#267
ouvert). Le test cité dans #259 rejouait la même conversation, cas qui
marchait déjà. Le cache disque reste indispensable ; configuration
inchangée.

Rien n'est suivi en amont sur : d'autres quants (notre `IQ4_NL`), plusieurs
modèles par serveur (« HTTP model replacement not implemented »), un budget de
raisonnement.

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

### Paramètres de gufo et leur origine

Gufo n'a pas de réglage de production « officiel ». Jusqu'au 25/09/2026, ses
défauts visaient un usage minimal (4 096 tokens de contexte, 128 générés) ;
depuis d5fd781 et #276, contexte et longueur de génération suivent llama.cpp
(contexte natif, génération jusqu'à EOS). L'échantillonnage reste glouton et
ses propres mesures tournent en glouton. Les valeurs ci-dessous visent un
usage agentique comparable au service ; aucune n'est un réglage interne du
moteur. Confrontées le 26/09/2026 à `docs/SERVER.md` et aux guides des modèles
de gufo (commit d9a84f1) et à `gufo serve llm --help` de l'image déployée, puis
le 28/09/2026 à v0.1.1 (diff de la documentation d9a84f1...v0.1.1 et des deux
`--help`) : aucune recommandation de réglage nouvelle, défauts du cache disque
inchangés (8 Gio, staging automatique au plus 1 Gio), une seule option
ajoutée, `--log-progress` (journal de progression du prefill et du décode,
diagnostic seulement, non posée). Trois points de `docs/SERVER.md` nous
touchent sans rien changer à la configuration : le point de reprise Qwen
avant la réponse de l'assistant vaut désormais avec la réflexion coupée
(notre `--think off`), un second point sur le prompt entier est pris sur le
même budget d'instantanés (à surveiller : refus de staging ou rétention qui
tourne plus vite), et le prompt rendu est borné à 128 octets par token de
contexte (32 Mio à 262 144, une raison de plus de garder `--context`
explicite). `/v1/models` de gufo publie désormais `context_length`, mais
llama-swap sert sa propre liste : `capabilities.context` reste nécessaire.

| Paramètre | `runtime-gufo/gufo-llama-swap.yaml` | Défaut de gufo | Exemples gufo (guides des modèles) | Origine |
|---|---|---|---|---|
| `--context` | 262144 | contexte natif depuis d5fd781 (4096 avant) | 32768 | nous : contexte natif, celui du service ; redondant depuis d5fd781 (chargement : `context_tokens=262144`), gardé explicite parce que `capabilities.context` doit lui rester égal |
| `--sessions` | 2 | 1 | 2 | gufo (guides du 27B et de Flash-Next) et notre mesure (7 Gio, plus d'éviction par les requêtes annexes) |
| `--max-tokens` | non posé (-1, jusqu'à EOS) | -1 depuis #276 (128 avant) | non indiqué | gufo, comme le service (llama.cpp à -1, aucun `n-predict` dans le ini) ; 32768 explicite jusqu'au 26/09/2026, quand le défaut de 128 coupait un client sans `max_tokens` |
| échantillonnage | temp 0,7, top-k 20, top-p 0,8, min-p 0, presence 1,5 | glouton, aucun filtre | aucun | Qwen officiel, profil instruct (fiche du modèle, guide unsloth), celui des sections nothink du service ; surchargeable par requête |
| `--think` | off | gabarit du modèle (raisonnement, effort xhigh) | non indiqué | nous : équivalent des sections nothink |
| `--cache-disk` | activé, 16 Gio | désactivé (8 Gio si activé depuis #279) | non utilisé | nous : seul chemin de reprise d'un préfixe commun entre conversations (mesuré) ; 16 Gio car partagé entre les modèles et un point de reprise Flash-Next de session réelle pèse 1,5 Go (8 Gio en garde environ 5), et `docs/SERVER.md` demande plus que les défauts pour le 27B à contexte long. Passé au défaut de 8 Gio le matin du 26/09/2026, remis à 16 Gio le jour même |
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
   `GPU_MAX_HW_QUEUES=1` et `ttl: 60` sur la voix et la transcription
   (#272), `capabilities.context` de llama-swap, GGUF refusés (Flash-Next
   Signal en `IQ4_NL`, DeepSeek UD-IQ3_XXS, Ornith Q4_K_M si #299 est
   mergée).
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
6. **Remesurer**, un GPU donc en séquence, sur les modèles retenus :
   - `runtime-gufo/bench/run.sh gufo 27b flashnext` : justesse d'abord
     (aiguilles, `sanity`), puis prefill court et à 52k, décode prose et
     code, cache au tour 2, mémoire, temps de chargement ;
   - `runtime-gufo/bench/agentic.sh gufo 27b flashnext` : 16/16, temps par
     passe, part du cache (disque / RAM / ratés) ;
   - sauvegarder avant les journaux bruts de `resultats/agentic/`, que le
     banc écrase (`resultats/agentic/<date>-<version>/`).
7. **Lire les journaux**, pas seulement les débits : refus de staging
   (`reason=staging_capacity`), `cache_miss_reason`, points de reprise écrits,
   premier token des petites requêtes (un coût fixe par requête ne se voit
   pas à 52k), acceptance du spéculatif (une baisse de décode en prose peut
   venir d'elle et non du moteur).
8. **Documenter et répondre** : section de la release dans « Suivi en amont »
   (contenu, choix, tableau contre la mesure précédente), tableau
   « À surveiller », tableau des paramètres (date de confrontation) ;
   réponses aux tickets où l'on nous a posé une question, **rédigées puis
   montrées à l'utilisateur avant publication**.
9. **Remettre l'usage réel** : `./setup-llm.sh --gufo flashnext` (ou le
   modèle d'avant), `/v1/models`, une requête avec `stop` par le proxy, voix
   et transcription si elles servent.

Pour rejouer contre une nouvelle version de gufo sans la checklist complète :
`runtime-gufo/download.sh image`, puis `runtime-gufo/bench/run.sh gufo 27b` et
`runtime-gufo/bench/agentic.sh gufo 27b`. Ce sont les deux mesures qui
comparent les moteurs à fichiers identiques ; les chiffres du service
ci-dessus sont la référence du 24/09/2026.
