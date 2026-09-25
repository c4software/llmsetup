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

- Moteur HIP écrit à la main pour gfx1151, sous licence MIT, v0.1.0, testé au
  commit `9cad139` (image `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest`,
  ROCm 7.2.3 embarqué, `gufo diagnose` en PASS sur bigchuck).
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
  0,5 s au lieu de 1,8 à 2,1 s. Le même proxy retire désormais `stop` pour
  gufo (option `anthropic_drop_fields`) ;
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
| Requête avec `stop` | acceptée (retiré par llama-swap, gufo#260) |
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
synthèse passe par `/upstream/<modèle>/`, pas par une route de llama-swap.

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
  partagés réservés au disque, période d'apprentissage.
- [#239](https://github.com/gufo-org/gufo/issues/239) : deux commentaires sur
  le n-gram. Le même jour, un contributeur y a publié un résultat négatif :
  recherche dans le prompt en complément de la MTP, greedy, +0,2 à 1,1 %
  seulement (la MTP accepte déjà 92 % en greedy). Notre réponse : mesure en
  temp 0,7 et gain lié à un pool persistant, donc conception différente, à
  suivre dans un ticket séparé.

À surveiller :

| Ticket | Sujet | État au 24/09/2026 |
|---|---|---|
| #259 | renommé : préfixes partagés réservés au cache disque, staging par défaut trop petit pour le 27B | ouvert (le nôtre), résumé en tête et dernier commentaire sur `--sessions` ; contournement : `--cache-disk` + staging relevé ; la reprise « un tour en retard » vue avec Claude Code vient du proxy (omp reprend depuis la RAM), commentaire corrigé |
| #260 | `stop` refusé (les `stop_sequences` Anthropic traduites par un proxy) | ouvert (le nôtre) |
| #263 | n-gram persistant autonome, à la llama.cpp `ngram-mod`, en option (le nôtre, issu de #239 ; mesure indépendante : ×1,6 à chaud) | ouvert |
| #248 | suite de conversation ratée quand la réflexion est active | ouvert, confirmé par un second utilisateur |
| #239 | n-gram (prompt lookup) | résultat négatif en greedy, clôture proposée |
| #255 | GEMM W8A8 du prefill Flash-Next, +5 % (pwilkin) | non reproduit : débordement propre à clang 23 |
| #228 | ROCm 10 | verdict gufo : rester sur ROCm 7.2.3 (décode -5 % en ROCm 10) |
| #200 | runtime HRX + noyaux Loom | ouvert depuis août, +3,6 % de prefill 27B |
| #257 | outils mal formés tolérés (clients agentiques) | en revue |
| #256 | format HGN de halogen (spécification en salle blanche) | ouvert |

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

Gufo n'a pas de réglage de production « officiel » : ses défauts visent un
usage minimal (4 096 tokens de contexte, 128 générés, glouton) et ses propres
mesures tournent en glouton. Les valeurs ci-dessous visent un usage agentique
comparable au service ; aucune n'est un réglage interne du moteur.

| Paramètre | `runtime-gufo/gufo-llama-swap.yaml` | Défaut de gufo | Exemples gufo (guides des modèles) | Origine |
|---|---|---|---|---|
| `--context` | 262144 | 4096 | 32768 | nous : contexte natif, celui du service |
| `--sessions` | 2 | non documenté | 2 | gufo et notre mesure (7 Gio, plus d'éviction par les requêtes annexes) |
| `--max-tokens` | 32768 | 128 | non indiqué | nous : à 128, un client qui n'envoie pas `max_tokens` serait coupé |
| échantillonnage | temp 0,7, top-k 20, top-p 0,8, min-p 0, presence 1,5 | glouton, aucun filtre | aucun | Qwen officiel, profil instruct (fiche du modèle, guide unsloth), celui des sections nothink du service ; surchargeable par requête |
| `--think` | off | gabarit du modèle (raisonnement, effort xhigh) | non indiqué | nous : équivalent des sections nothink |
| `--cache-disk` | activé, 16 Gio | désactivé (4 Gio si activé) | non utilisé | nous : seul chemin de reprise d'un préfixe commun entre conversations (mesuré) |
| `--cache-disk-staging-bytes` | 8 Gio | 512 Mio | non utilisé | nous : sinon les points de reprise du 27B sont abandonnés dès ~4,5k tokens (mesuré) |
| spéculatif (adaptatif, 7 tokens max), `--prefill-chunk` 512 | inchangés | défauts gufo | défauts gufo | gufo |
| fichiers | Flash-Next UD-Q4_K_XL, MTP shared Q8_0, DFlash 2 Q8_0 | | UD-Q4_K_XL, MTP shared Q8_0, DFlash 2 Q4_K_M | gufo, sauf le drafter du 27B pris dans le parc (Q8_0, mesuré identique au Q4_K_M) |

Les chiffres agentiques avec cache disque ont été mesurés avec ces réglages ;
gufo « nu » (sans cache disque) était à égalité avec le service sur le 27B.

Pour rejouer contre une nouvelle version de gufo : `runtime-gufo/download.sh
image`, puis `runtime-gufo/bench/run.sh gufo 27b` et
`runtime-gufo/bench/agentic.sh gufo 27b`. Ce sont les deux mesures qui
comparent les moteurs à fichiers identiques ; les chiffres du service
ci-dessus sont la référence du 24/09/2026.
