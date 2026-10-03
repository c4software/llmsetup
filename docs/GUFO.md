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
  remesuré au commit `d9a84f1` le 26/09/2026, sur la release v0.1.1 le
  28/09/2026 (27B et Flash-Next) et sur la v0.2.0 le 29/09/2026 (27B,
  Flash-Next et DeepSeek), voir « Suivi en amont ». Les deux
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

À surveiller (tickets ouverts seulement : un ticket fermé sort du tableau,
ce qu'il a changé reste dans la section de sa release) :

| Ticket | Sujet | État au 02/10/2026 |
|---|---|---|
| #388 | boucle de répétition de Flash-Next en boucle d'outils (vue en v0.4.0 et v0.5.0, puis en v0.2.0 aussi le 03/10/2026 : pas une régression), suite de #368 | ouvert (le nôtre) le 02/10/2026 à la demande du mainteneur, #368 fermé (ralentissement corrigé par #373) ; boucle capturée en debug le soir même (section « Release v0.5.0 »), journaux et session pi dans un gist secret, commentaire publié le 02/10/2026 avec le mécanisme et une piste non vérifiée (pénalités, #332) ; un tiers suggère `--think xhigh` (recommandé par Qwen pour le code) : écarté, le sujet est la régression à réglage égal (`--think off` identique en 0.2.0, sans boucle), réponse publiée dans ce sens ; le tiers donne ses réglages (raisonnement xhigh, presence 0, 1 session), d'où l'essai du 03/10/2026 : même banc en `--presence-penalty 0.0`, 0 boucle sur 20 séries contre 2 sur 9 en 1,5, décompte et journaux (gist secret) publiés le jour même ; témoin 0.2.0 en presence 1,5 le même jour : boucle en série 5 sur 5, annoncée dans #388 (le sujet devient le profil Qwen sans raisonnement, plus la version) ; un collaborateur (francescobozzo) envisage de désactiver la pénalité sans raisonnement si d'autres preuves arrivent ; ticket renommé (« tool-call loop with the no-think profile (presence penalty 1.5), all versions ») et commentaire final publié le 03/10/2026 : décompte du témoin, chiffres corrigés, rejeu de la première correction (la pénalité à 0 n'empêche pas la seconde valeur fausse), fermeture laissée au choix des mainteneurs ; essai d'une consigne côté pi le même jour (section « Release v0.5.0 »), publié aussi, sans autre demande côté gufo |
| #259 | renommé : préfixes partagés réservés au cache disque, staging par défaut trop petit pour le 27B | ouvert (le nôtre), résumé en tête et dernier commentaire sur `--sessions` ; contournement : `--cache-disk` + staging relevé ; la reprise « un tour en retard » vue avec Claude Code vient du proxy (omp reprend depuis la RAM), commentaire corrigé ; plan du mainteneur le 25/09 : points 1 à 3 (staging) et `--sessions 2` documentés, le reste dans #267 ; le 26/09, point 1 corrigé par la PR #279 (d9a84f1 : staging automatique au plus petit de 1 Gio, 1/8 de la RAM disponible et de la rétention disque, rétention par défaut 8 Gio, instantanés refusés journalisés), point 2 : 1 Gio, seuil fixe reconnu imparfait ; le 26/09, 11 points de reprise Flash-Next réels de 1,39 à 1,50 Go refusés au défaut : staging gardé à 8 Gio, remesure agentique inchangée ; commentaire du 26/09 avec les refus et la remesure, suggestion d'un staging automatique déduit du modèle chargé ; le 26/09 au soir, un utilisateur affirme que sur l'image `20260926T093925` la reprise d'un préfixe partagé marche **sans** `--cache-disk` (6,3 s ramenées à 0,1 s), mais en rejouant trois fois la même requête, pas une nouvelle conversation après une autre : vérifié chez nous le 28/09 (section « Release v0.1.1 ») : faux pour une nouvelle conversation, 14 débuts recalculés sans disque ; commentaire publié le 28/09 avec la remesure v0.1.1 (cache repris 92,9 / 92,6 %) ; le 30/09, le mainteneur confirme les quatre points sur f783fed (27B, `--sessions 4`) : au défaut, staging de 1 Gio contre des points de reprise de 1,85 Go à 24,5k tokens, **tous** refusés, cache disque inerte ; staging 8 Gio : 24,9k tokens repris en 1,8 s contre ~50 s à froid ; préfixe commun repris seulement à partir de la 5e conversation ; `--sessions 1` : une requête annexe évince la conversation (0,23 s à 5,3 s) ; le manque est le niveau RAM (suite dans #331) ; aucun correctif annoncé |
| #267 | préfixes partagés gardés en RAM sans `--cache-disk`, apprentissage compris (ouvert par le mainteneur, nos chiffres en appui) | ouvert ; latence depuis la RAM à mesurer, rien de promis |
| #239 | n-gram (prompt lookup) | ouvert ; résultat négatif en greedy, clôture proposée, puis jugé « worth experimenting » par le mainteneur (25/09), après les premiers bugs ; porte aussi le pool persistant de #263 depuis le 28/09 |
| #228 | ROCm 10 | verdict gufo : rester sur ROCm 7.2.3 (décode -5 % en ROCm 10) |
| #200 | runtime HRX + noyaux Loom | ouvert depuis août, +3,6 % de prefill 27B |
| #299 | PR : Qwen3.6-35B-A3B (`qwen35moe`, GDN + MoE 256 experts, MTP, DFlash 2), par slimsami, ouverte le 27/09 | **suivie à la demande de l'utilisateur** (28/09) : même architecture qu'Ornith-1.5-35B-A3B, notre modèle agentique par défaut (fine-tune de Qwen3.6-35B-A3B). Annoncé sur UD-Q6_K_XL : prefill 1 790 à 2 702 t/s contre 1 057 à 1 202 pour llama.cpp Vulkan, DFlash 2 à 83,3 t/s en glouton ; MTP pas encore branché dans `gufo serve`. À vérifier si elle est mergée : notre Ornith est en Q4_K_M (la PR ne cite que Q6_K et Q8_0 pour les experts), et gufo refuse les quants hors de ses formats ; le 30/09, **mise en attente par le mainteneur** : pas de nouveau modèle ni de nouvelle quant avant un produit stable avec les modèles actuels |

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
  inchangé à 52k : un coût fixe d'environ 0,1 s par requête neuve.
  L'instantané du point de reprise n'en explique qu'une partie (24 à 44 ms
  par requête, `cache_snapshot_ms` des `timings`, mesuré le même jour).
  Invisible en agentique, où les petites requêtes répondent au contraire
  plus vite.
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

### #272 : les trois questions du mainteneur (28/09/2026)

Mesuré sur gufo 0.1.1, Flash-Next résident (2 sessions), serveurs audio
lancés à la main dans le conteneur (`docker exec … gufo serve tts|asr`, hors
llama-swap), files lues dans `/sys/class/kfd/kfd/proc/<pid>/queues/*/type`
toutes les 0,2 s (0 = calcul, 1 = SDMA), `gpu_busy_percent` en moyenne sur
10 s. Script et relevés dans `GUFO_DATA/resultats/272-2026-09-28/`, publiés
avec la réponse dans #272 le 28/09/2026 (commentaire et gist
https://gist.github.com/c4software/301eb249e8948cf31086a3e753311d9e).

| Chargés | Files de calcul (total) | GPU au repos | Prefill Flash-Next, prompt de 1,6k (t/s) | Décode (t/s) |
|---|---|---|---|---|
| LLM seul (deux séries) | 5 | 0 % | 1 344 à 1 390 | 56,3 à 63,1 |
| + voix, défaut | 5 + 4 = 9 | 100 % | 1 375 à 1 388 | 57,2 à 64,5 |
| + transcription, défaut | 5 + 4 = 9 | 100 % | 1 370 à 1 387 | 59,6 à 66,1 |
| + voix, `GPU_MAX_HW_QUEUES=1` | 5 + 2 = 7 | 0 % | | |
| + transcription, `GPU_MAX_HW_QUEUES=1` | 5 + 2 = 7 | 0 % | | |

- **Débit** : aucun coût mesurable à 9 files. Prefill et décode restent
  dans la plage du LLM seul ; le décode suit l'acceptance MTP (318 à 345
  brouillons acceptés sur 400 tokens), pas le nombre de files. Le coût est
  la consommation au repos (~30 W), pas l'inférence.
- **Par phase** : chaque serveur prend toutes ses files d'un coup au
  démarrage, dans la demi-seconde où son processus apparaît (LLM : 0, puis
  2, puis 5 en 0,4 s ; voix et transcription : 0 puis 4), et n'en prend
  jamais davantage pendant le chargement des poids (80 s pour Flash-Next) ni
  après. Pas de pic au-dessus du régime établi, ce qui est compatible avec
  un pool de HIP plafonné à `GPU_MAX_HW_QUEUES` qui absorbe les 16 flux de
  chargement (non vérifié en réduisant `kReaders`, ce qui demande un
  build).
- **`--sessions`** : 5 files en 1 comme en 2 sessions, pendant et après le
  chargement. Le budget ne dépend pas de ce réglage.
- `GPU_MAX_HW_QUEUES=1` ramène la voix et la transcription à 2 files
  (4 par défaut) ; le LLM en a une de plus que les serveurs audio (5).

### #272 : test de la PR #317 (28/09/2026)

PR [#317](https://github.com/gufo-org/gufo/pull/317) (fedeizzo, commit
`e7e7312`) : chaque serveur compte les files déjà prises sur la machine
(`/sys/class/kfd`) et fixe lui-même `GPU_MAX_HW_QUEUES` avant de charger
(LLM 2, voix et transcription 1, image et vidéo au défaut), jamais relevé,
jamais contre celui de l'opérateur, avertissement et démarrage quand même si
la machine est pleine. Pas d'image publiée pour la PR : `nix build` du commit
dans un conteneur `nixos/nix` jetable sur bigchuck (store dans le volume
Docker `gufo-nix`, supprimé après le test avec l'image `nixos/nix`, ROCm 7.2.3
du cache Nix, `gufo diagnose` en PASS), binaire
lancé dans ce même conteneur, gufo d'usage réel coupé le temps du test.
Même protocole que ci-dessus, **sans** notre `GPU_MAX_HW_QUEUES=1` ; script
et relevés dans `GUFO_DATA/resultats/317-2026-09-28/` (`test-317.sh`,
`serve-*.log`). Résultat publié dans #272 le 28/09/2026
(https://github.com/gufo-org/gufo/issues/272#issuecomment-5876144656).

| Chargés | Files de calcul (total) | GPU au repos | Journal de gufo | Prefill (t/s) | Décode (t/s) |
|---|---|---|---|---|---|
| LLM seul | 3 | 0 % | `observed=0 expected=3 cap=2` | 1 354 à 1 374 (1 160 à froid) | 56,3 à 61,3 |
| + voix | 3 + 2 = 5 | 0 % | `observed=3 expected=2 cap=1` | 1 363 à 1 382 | 56,4 à 61,2 |
| + transcription | 3 + 2 + 2 = 7 | 0 % | `observed=5 expected=2 cap=1` | 1 356 à 1 387 | 55,6 à 63,3 |
| voix relancée avec `GPU_MAX_HW_QUEUES=4` | 3 + 2 + 4 = 9 | 100 % | `expected=unknown cap=operator` (INFO seulement) | | |
| 4e serveur (voix) sur 7 files | 7 + 2 | | `queue_budget_exceeded` (WARN) | | |

- **Ça marche** : le parc texte, voix et transcription tient à 7 files et
  le GPU reste au repos, sans réglage de notre part ; débit identique à la
  v0.1.1 à 5 files (1 344 à 1 390 et 56,3 à 63,1). Chaque serveur prend ses
  files au démarrage et n'en change plus.
- **Réglage de l'opérateur** : respecté, mais un dépassement qu'il provoque
  n'est signalé qu'en INFO (`expected=unknown`), sans le WARN
  `queue_budget_exceeded` (le serveur ne sait pas combien il en ouvrira).
- **Machine pleine** : WARN émis puis chargement tenté, comme annoncé. Le 4e
  serveur est ensuite mort faute de mémoire (Flash-Next et trois serveurs
  audio : le noyau refuse les mappages, `SVM mapping failed, exceeds resident
  system memory limit`), sans aucune ligne d'erreur dans son journal après
  `load_started`. Limite de notre parc, pas de la PR.
- Synthèse et transcription non rejouées (la PR les mesure : durées et
  sorties identiques à 1 et 4 files).
- Contournement (`GPU_MAX_HW_QUEUES=1`, `ttl: 60`) conservé jusqu'à une
  release qui contient la PR ; il reste compatible (réglage de l'opérateur
  respecté, 2 files comme la PR). Le `ttl` devient inutile pour les files,
  pas forcément pour la mémoire.

### Release v0.2.0 (29/09/2026)

v0.2.0 (`992113b`, image `gufo-runtime:0.2.0`), publiée le 29/09/2026.
Contenu depuis v0.1.1 :

- **#282, échantillonnage officiel par défaut** (au lieu du glouton) :
  Qwen3.8 27B et Flash-Next avec raisonnement temp 1,0 / top-p 0,95 /
  top-k 20 / presence 0, sans raisonnement 0,7 / 0,8 / 20 / 1,5 ; DeepSeek
  profil agentic 0731, 1,0 / 0,95 / top-k 0. Priorité requête > option du
  serveur > profil, champ par champ ; une option du serveur non posée suit
  le profil du mode de raisonnement effectif. **DeepSeek raisonne désormais
  par défaut**, effort `high` (`xhigh` ramené à `high`) ; Qwen reste en
  raisonnement `xhigh` par défaut. `gufo bench` reste glouton.
- **#317, plafond des files matérielles** (ferme notre #272) : `serve llm`
  2 (3 files), `serve tts` et `serve asr` 1 (2 files), image et vidéo au
  défaut du runtime (jusqu'à 5) ; recensement des files déjà prises par tous
  les processus (`/sys/class/kfd`), plafond seulement abaissé, jamais
  relevé ; un `GPU_MAX_HW_QUEUES` de l'opérateur est respecté ; événements
  `queue_budget` et `queue_budget_exceeded` dans le journal.
- **#314** : noms d'outils à point ou espace de noms (`github.create_issue`)
  de nouveau acceptés (refusés en 0.1.0 et 0.1.1 par une règle venue avec
  #283).

`gufo serve llm --help` des deux images comparé sur bigchuck : seuls les
défauts de `--temperature`, `--top-k`, `--top-p`, `--presence-penalty` et
`--think` changent (« model/thinking preset »), aucune option ajoutée ou
retirée ; `serve tts --help` identique. Défauts du cache disque et du staging
inchangés. En amont, `inference_backend_gpu_test` (prefill Qwen concurrent)
échoue sur la branche principale, déjà avant la release selon le mainteneur.

Choix du 29/09/2026 (questions posées, réponses de l'utilisateur) :

- **Image épinglée** sur `gufo-runtime:0.2.0`.
- **Macro `qwen` réduite à `--think off`** : nos valeurs explicites étaient
  exactement le profil sans raisonnement de gufo. Même comportement par
  défaut ; une requête qui active le raisonnement reçoit désormais le profil
  avec raisonnement (1,0 / 0,95) au lieu de nos 0,7 figés.
- **Macro `deepseek` retirée** : profil de gufo (top-k 0 au lieu de 40) et
  raisonnement par défaut, comme la section du service ; raisonnement coupé
  le même jour après la remesure (plus bas).
- **`GPU_MAX_HW_QUEUES=1` retiré** de la voix et de la transcription
  (gufo pose la même valeur) ; **`ttl: 60` gardé** : Qwen-Image (jusqu'à
  5 files) + voix + transcription ferait encore 9 files.
- **Remesure** : 27B et Flash-Next (`remesure.sh 27b flashnext`) ; nos bancs
  fixent température et raisonnement dans chaque requête (`mesure.py`), le
  changement de défauts ne les touche pas.

Remesure du 29/09/2026 (gufo 0.2.0 `992113b`, mêmes réglages de cache,
1 session), contre celle du 28/09 (0.1.1). Journaux bruts dans
`GUFO_DATA/resultats/agentic/2026-09-29-0.2.0/` (`avant/` y garde la boucle
sans cache disque du 28/09, pas la boucle avec cache, comparée ici à la
section v0.1.1) :

| gufo, 0.2.0 contre 0.1.1 | Qwen3.8-27B | Flash-Next |
|---|---|---|
| prefill, prompt court (t/s) | 528 contre 524 | 1 300 contre 1 307 |
| prefill à 6,5k (t/s) | 594 contre 585 | 1 399 contre 1 381 |
| prefill à 52k (t/s) | 508 contre 505 | 1 395 contre 1 379 |
| décode, prose (t/s) | 44,1 contre 47,2 (passes de 43,6 à 50,3) | non mesurable (arrêt avant 200 tokens) |
| décode, code (t/s) | 66,3 contre 65,5 | 61,4 contre 62,2 |
| justesse, aiguilles, cache au tour 2 | OK, 100 % | OK, 100 % |
| mémoire (relevé `free`) | 53 Gio contre 52 | 97 Gio contre 95 |
| boucle agentique, médiane par passe | 16/16, 40,0 s contre 38,8 s | 16/16, 31,4 s contre 30,4 s |
| prompt repris (RAM / disque / ratés) | 92,7 % (36 / 12 / 3) contre 92,9 % | 92,2 % (34 / 12 / 3) contre 92,6 % |
| tokens recalculés, tout le run | 6,6k contre 6,2k | 6,6k contre 6,6k |
| temps en prefill / décode, tout le run | 18 / 98 s contre 17 / 95 s | 11 / 78 s contre 11 / 79 s |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | 210 ms contre 212 | 164 ms contre 172 |
| acceptance du spéculatif (réponses de plus de 20 tokens) | 69,9 % contre 71,4 % | 84,6 % contre 85,7 % |
| points de reprise écrits / refusés par le staging | 58 / 0 contre 61 / 0 | 44 / 0 contre 42 / 0 |

- Rien ne bouge au-delà du bruit, ce qu'attend une release qui ne touche ni
  les noyaux ni le cache. `mesure.py` fixe la température de chaque requête
  (0 ou 0,7, comme avant) ; `bench-agentic/` n'en fixe aucune pour pi, qui
  reçoit donc, sauf valeur propre à pi, le profil sans raisonnement de gufo,
  identique à notre ancienne macro.
- Les passes agentiques restent dominées par le scénario `stats.js` (27B :
  17,7 à 28,1 s selon la passe, l'agent y corrige parfois son propre test) :
  écart de médiane de 1 s, dans la variation d'une passe à l'autre.
- Aucun point de reprise refusé, le staging de 8 Gio tient toujours.

DeepSeek remesuré le même jour à la demande de l'utilisateur
(`remesure.sh deepseek`), pour le raisonnement désormais actif par défaut.
Référence : la mesure du 24/09 (gufo d9a84f1 ou antérieur, sans raisonnement,
sans cache disque ; aucune mesure DeepSeek avec cache disque avant celle-ci).
Le banc HTTP coupe le raisonnement dans chaque requête (`mesure.py`) : il ne
mesure que le moteur ; la boucle pi, elle, raisonne (défaut de gufo) :

| gufo DeepSeek V4 Flash (IQ2XXS antirez, DSpark) | 0.2.0 (29/09) | 24/09 |
|---|---|---|
| prefill, prompt court (t/s) | 417 | 402 |
| prefill à 42k (t/s) | 464 | 457 |
| décode, prose / code (t/s) | 33,6 / 37,1 | 34,1 / 38,3 |
| justesse, aiguilles, cache au tour 2 | OK (comptage à 26k juste), 100 % | **KO** (comptage à 26k : 1 au lieu de 8) |
| mémoire (relevé `free`) | 104 Gio | 104 Gio |
| boucle agentique, médiane par passe | 16/16, **128,7 s** (raisonnement, cache disque) | 16/16, 90 s (sans raisonnement, sans cache disque) ; service 116 s |
| tokens générés, tout le run | 9,0k, soit **+61 %** | 5,6k (service 6,7k) |
| temps en prefill / décode, tout le run | 51 / 331 s | 92 / 179 s |
| décode réel (t/s) | 27,3 | 31,1 |
| prompt repris (RAM / disque / ratés) | 88,9 % (37 / 12 / 3) | 70 % (sans cache disque) |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | 574 ms | non relevé |
| acceptance du spéculatif (réponses de plus de 20 tokens) | 73,0 % | non relevé |
| points de reprise écrits / refusés par le staging | 72 / 0 | sans objet |

- Moteur inchangé (banc HTTP à ±3 %), et le comptage à 26k qui avait
  échoué une fois le 24/09 est juste cette fois : la quant IQ2XXS n'est pas
  condamnée, sans être blanchie sur une seule mesure.
- Le raisonnement par défaut coûte cher en agentique : 61 % de tokens
  générés en plus, un décode presque doublé en temps (331 s contre 179 s)
  qu'aucun gain de prefill (cache disque : 51 s contre 92 s) ne rattrape.
  Passes à 140, 129 et 114 s, soit 43 % de plus que sans raisonnement et
  11 % de plus que le service (116 s le 24/09, raisonnement à budget de
  6 144 tokens) : gufo n'a pas de budget, l'effort `high` raisonne plus
  longtemps.
- Décision de l'utilisateur, le même jour : **`--think off` pour DeepSeek**
  (retour au comportement d'avant la 0.2.0) ; un client peut réactiver le
  raisonnement par requête.

Rien n'est suivi en amont sur : d'autres quants (notre `IQ4_NL`), plusieurs
modèles par serveur (« HTTP model replacement not implemented »), un budget de
raisonnement.

### Release v0.3.0 (30/09/2026)

v0.3.0 (`fd1710b`, image `gufo-runtime:0.3.0`, aussi `latest`), publiée le
30/09/2026. Contenu depuis v0.2.0 : une bannière de démarrage sur les
commandes interactives de la CLI (#323) et un lien vers les forks dans le
README (#327). Ni noyau, ni cache, ni serveur : image laissée épinglée sur
`gufo-runtime:0.2.0` (choix de l'utilisateur, 30/09/2026), pas de
remesure.

### Release v0.4.0 (01/10/2026), non retenue

v0.4.0 (`6aa87fc`, image `gufo-runtime:0.4.0`, digest `e1bc3ee3bfe8`), publiée
le 01/10/2026 à 11:39 UTC, image 22 min plus tard. Contenu depuis v0.3.0 :
métriques en direct (#351), éviction du cache journalisée (#353),
`--log-level` (#319), `return_progress` de llama-server (#344), appels
d'outils natifs gardés en décodage contraint, `tool_choice: required` forcé au
décodage et non plus vérifié après (#324), SSE maintenu pendant la génération
(#334), relecture MTP de Flash-Next stable à travers le cache (#330 : les
anciens points de reprise disque Flash-Next sont refusés puis reconstruits une
fois), pénalités du glouton sur GPU et plages d'échantillonnage corrigées sur
Flash-Next (#332 : +5 % de décode glouton court annoncé, sans effet attendu
chez nous, qui échantillonnons), `docs/KV-CACHE.md` (#360).

Montée faite (`7c98484`), remesurée le jour même sur le 27B et Flash-Next
(`runtime-gufo/bench/remesure.sh`, journaux dans
`resultats/agentic/2026-10-01-0.4.0/`, `avant/` = v0.2.0 du 29/09), puis
**annulée** (`b758eb7`, choix de l'utilisateur) : gufo d'usage réel revenu en
`gufo-runtime:0.2.0`. Même pi (image du 22/09, 0.87.0) pour les deux mesures.

| Mesure | 27B v0.2.0 | 27B v0.4.0 | Flash-Next v0.2.0 | Flash-Next v0.4.0 |
|---|---|---|---|---|
| prefill 52k (t/s) | 508,3 | 504,6 | 1 395,5 | 1 370,5 |
| décode code, banc HTTP (t/s) | ~66 | ~65 | ~61 | ~61 |
| tour 2 sur 32k en cache (t/s) | 107,4 | 107,1 | 151,2 | 160,4 |
| agentique PASS | 16/16 | 16/16 | 16/16 | 16/16 |
| `creation`, passes 1/2/3 (s) | 18,5 / 17,7 / 28,1 | 25,1 / 22,8 / 33,1 | 16,4 / 15,3 / 17,7 | 23,1 / **2 563,7** / 19,5 |
| `bugfix`, passes 1/2/3 (s) | 9,6 / 8,9 / 8,8 | 12,3 / 11,4 / 12,8 | 7,7 / 7,1 / 6,3 | 9,7 / 12,4 / 10,8 |
| requêtes agentiques | 51 | 54 | 49 | 1 645 |
| décode agentique (t/s) | 43,9 | 30,5 | 50,4 | 27,8 (boucle comprise) |
| acceptance du spéculatif (médiane) | 69,9 % | 50,7 % | 84,6 % | 60,0 % |
| points de reprise refusés (staging) | 0 | 0 | 0 | 296 |

Lecture : le banc HTTP est inchangé au bruit près, la régression ne touche
que les requêtes avec outils, sur les deux modèles (20 à 40 % de temps en
plus, acceptance en baisse). Passe 2 de `creation` sur Flash-Next : environ
1 600 requêtes presque identiques (14 à 15 tokens générés, prompt +241 tokens
par tour), contexte monté à ~114k, compacté par pi, puis reparti, 43 min avant
de finir en PASS ; la transcription pi n'est pas conservée par le banc, l'appel
répété n'est pas connu. Au démarrage de Flash-Next, pendant ~45 s, chaque
écriture de point de reprise prenait 2,1 à 2,7 s (0,1 à 0,2 s ensuite) et le
prefill court tombait à 430-770 t/s (au lieu de ~1 300), pendant que les
points de reprise v0.2.0 du cache disque étaient écartés. Ticket
[#368](https://github.com/gufo-org/gufo/issues/368) publié le jour même avec
ces chiffres et les fichiers (modèles et quants).

Rejeu du même jour à la demande du mainteneur (fedeizzo) : gufo en `-v`
(`DEBUG=1`) et sessions pi gardées (`PI_SESSIONS=1`) dans
`runtime-gufo/bench/agentic.sh`, 5 passes, 0.4.0 puis 0.2.0, pi épinglé en
0.87.0 dans `bench-agentic/Dockerfile` (une reconstruction avait installé la
0.99.2) ; journaux dans `resultats/agentic/2026-10-01-debug-<version>/`.
26/26 partout, boucle de 43 min non reproduite, ralentissement reproduit :

| Mesure | 27B v0.2.0 | 27B v0.4.0 | Flash-Next v0.2.0 | Flash-Next v0.4.0 |
|---|---|---|---|---|
| décode agentique (t/s) | 45,5 | 30,7 | 49,8 | 42,6 |
| acceptance du spéculatif (médiane) | 71,0 % | 49,3 % | 84,6 % | 70,2 % |
| `creation`, 5 passes (s) | 17,1 à 23,6 | 23,5 à 28,6 | 13,9 à 20,9 | 15,4 à 27,0 |
| `bugfix`, 5 passes (s) | 8,6 à 11,7 | 11,4 à 14,9 | 6,1 à 7,7 | 9,2 à 9,9 |

En 0.2.0, `-v` n'ajoute aucune ligne ; en 0.4.0, le debug montre l'admission
et les décisions du cache, rien sur le décodage contraint. Journaux des deux
séries et sessions pi (chemins de l'hôte masqués) publiés dans un gist secret,
lien en commentaire de #368 le 01/10/2026.

### Release v0.5.0 (02/10/2026), non retenue

v0.5.0 (`23cacbb`, image `gufo-runtime:0.5.0`, digest `371a731c5286`),
publiée le 02/10/2026 à 11:08 UTC. Contenu depuis v0.4.0 : schémas d'outils
natifs et appels historiques préservés (#373, le correctif de #368 selon le
mainteneur), marqueurs d'outils cités pendant le raisonnement laissés au
raisonnement (#361), cache qui continue d'avancer quand la conversation
grandit (#358), préfixes gardés après une édition de l'historique (#362),
conversations en cache indépendantes des sessions d'exécution (#369),
points de reprise qui avancent à peine sautés (#348, `reason=min_step`),
`/v1/models` qui publie `input_modalities` (#367), WebP accepté (#352),
bruit des éditions Qwen-Image lié aux pixels de référence (#377 : une
édition à graine fixe diffère des versions précédentes).

Recommandations de réglage (diff 0.4.0...0.5.0 de la documentation, `--help`
0.2.0 et 0.5.0 comparés sur bigchuck) : une option ajoutée,
`--cache-ram-bytes` (0 = automatique, au plus 32 Gio et la moitié de la RAM
libre après chargement ; le budget RAM des instantanés existait déjà, il
devient réglable), aucun défaut changé. `docs/SERVER.md` précise que
`--sessions` borne le pool d'exécution, plus le nombre de conversations
retenues (128 points de reprise, indépendants de `--sessions`), ce qui
contredit la lecture de `docs/KV-CACHE.md` en 0.4.0 (« le cache garde environ
`--sessions` conversations »).

Banc d'abord (choix de l'utilisateur) : 0.5.0 passée par l'environnement
(`GUFO_IMAGE`) aux bancs seulement, rien d'épinglé, gufo d'usage réel resté
en 0.2.0. 27B et Flash-Next, DeepSeek non remesuré. Quatre séries
agentiques : 1 session avec cache disque, 1 session sans cache disque
(`SANS_CACHE=1`, cache RAM seul), 2 sessions avec cache disque, puis rejeu
debug de Flash-Next en 2 sessions (`DEBUG=1 PI_SESSIONS=1`). Journaux dans
`resultats/agentic/2026-10-02-0.5.0/` (`avec-cache/`, `sans-cache/`,
`sessions2/`, `rejeu-debug-s2/`). Même pi (0.87.0) que les mesures de 0.2.0
et 0.4.0.

| Mesure | 27B v0.2.0 | 27B v0.4.0 | 27B v0.5.0 | Flash-Next v0.2.0 | Flash-Next v0.4.0 | Flash-Next v0.5.0 |
|---|---|---|---|---|---|---|
| prefill 52k (t/s) | 508,3 | 504,6 | 499,8 | 1 395,5 | 1 370,5 | 1 361,0 |
| décode code, banc HTTP (t/s) | ~66 | ~65 | ~66 | ~61 | ~61 | 55 à 62 |
| justesse (sanity, aiguilles 4k et 52k), tour 2 sur 32k | OK, 100 % | OK, 100 % | OK, 100 % | OK, 100 % | OK, 100 % | OK, 100 % |
| agentique PASS (1 session, cache disque) | 16/16 | 16/16 | 16/16 | 16/16 | 16/16 | 16/16 |
| `creation`, passes 1/2/3 (s) | 18,5 / 17,7 / 28,1 | 25,1 / 22,8 / 33,1 | 21,5 / 21,1 / 26,1 | 16,4 / 15,3 / 17,7 | 23,1 / **2 563,7** / 19,5 | 16,9 / 24,4 / 17,3 |
| `bugfix`, passes 1/2/3 (s) | 9,6 / 8,9 / 8,8 | 12,3 / 11,4 / 12,8 | 9,4 / 10,0 / 9,7 | 7,7 / 7,1 / 6,3 | 9,7 / 12,4 / 10,8 | 7,5 / 6,8 / 7,4 |
| requêtes agentiques | 51 | 54 | 51 | 49 | 1 645 | 51 |
| décode agentique (t/s) | 43,9 | 30,5 | 42,3 | 50,4 | 27,8 (boucle comprise) | 44,7 |
| acceptance du spéculatif (médiane) | 69,9 % | 50,7 % | 71,0 % | 84,6 % | 60,0 % | 85,7 % |
| prompt repris du cache | 92,7 % | 90,4 % | 93,2 % | 92,2 % | 99,2 % | 93,3 % |
| reprises disque / RAM | 12 / 36 | 12 / 39 | 2 / 46 | 12 / 34 | 10 / 1 623 | 2 / 46 |
| points de reprise disque écrits | 58 | 37 | 3 (82 sautés, `min_step`) | 44 | 1 355 | 3 (67 sautés, `min_step`) |

Séries complémentaires en v0.5.0 :

| Série | 27B | Flash-Next |
|---|---|---|
| 1 session, sans cache disque | 16/16, repris 90,1 %, prefill 25 s (19 s avec disque), décode 41,2 t/s | 16/16, repris 89,9 %, prefill 12 s (11 s), décode 48,2 t/s |
| 2 sessions, cache disque | 16/16, repris 98,2 %, décode 43,2 t/s | **boucle**, coupée par le garde-temps d'une heure (2 081 requêtes) |
| 2 sessions, rejeu debug | non joué | 16/16, repris 96,3 %, décode 46,4 t/s, acceptance 82,3 % |

Lecture :

- **Ralentissement de #368 corrigé** : en boucle d'outils, décode et
  acceptance du 27B reviennent au niveau de la 0.2.0 ; temps par passe au
  bruit près.
- **Boucle de répétition de Flash-Next toujours là** : une série sur quatre,
  au même endroit qu'en 0.4.0 (`creation`, passe 2), en 2 sessions cette
  fois (1 session en 0.4.0, donc rien ne la lie au nombre de sessions).
  Requêtes identiques : 63 tokens générés (`finish=stop`), 33 recalculés,
  prompt +96 tokens par tour, de ~4k à 104k tokens, acceptance ~93 %. Pas de
  sortie seule en une heure (43 min en 0.4.0). La série n'était pas en debug
  et le rejeu debug ne l'a pas reproduite : l'appel répété reste inconnu,
  d'où la règle « validation toujours en debug » de la checklist.
- **Cache surtout en RAM** : #348 saute presque tous les points de reprise
  disque, la RAM reprend ce que le disque couvrait (reprise inchangée, 93 %).
  Sans disque, 90 % : le disque rapporte encore quelques secondes de prefill
  dans ce banc, qui ne mesure pas la reprise d'un préfixe commun entre
  conversations distinctes (#259) ; contournement gardé.
- **2 sessions** : reprise du 27B 98,2 % contre 93,2 % en 1 session (requêtes
  annexes de pi plus évincées), réglage d'usage confirmé.
- Décode agentique de Flash-Next à 44,7 t/s contre 50,4 en 0.2.0 (sans perte
  d'acceptance) en 1 session, mais 46,4 t/s au rejeu : à reconfirmer à la
  prochaine version, pas tranché.

Choix du 02/10/2026 : 0.5.0 non retenue, `GUFO_IMAGE` reste en 0.2.0.
(Le motif « boucle » de ce choix est tombé le 03/10/2026 : la 0.2.0 boucle
aussi, voir le témoin plus bas.)
Commentaire publié sur #368 avec ces chiffres ; à la demande du mainteneur, la boucle est suivie dans un ticket à part, [#388](https://github.com/gufo-org/gufo/issues/388), ouvert le jour même.

Chasse à la boucle le soir même, tout en debug (`-v`, sessions pi gardées),
Flash-Next en 0.5.0, 2 sessions, 5 passes par série : deux rejeux sans
boucle, puis une nuit de 10 séries au plus arrêtée à la première boucle
(`resultats/agentic/2026-10-02-0.5.0/nuit/`), capturée en série 04, passe 4
de `creation` : 2 578 s, ~230 requêtes en plus, sortie seule (comme les
43 min de 0.4.0). Bilan Flash-Next : 0/2 séries en 0.2.0, 1/2 en 0.4.0, 2/9
en 0.5.0 ; `-v` ne l'empêche pas. Mécanisme lu dans la session pi :

1. `test.js` attend `median([4, 1, 7, 2]) === 4` (la bonne valeur est 3),
   échec `3 !== 4`. Erreur banale, vue dans environ une session `creation` sur
   cinq en 0.2.0, 0.4.0 et 0.5.0, d'ordinaire corrigée en un appel.
2. Ici, « correction » vers 5,5, fausse aussi ; le modèle soupçonne alors
   l'environnement (`md5sum`, `cat -A`, `require.resolve`, `env`, `1+2`).
3. À partir de l'appel 80, scripts `/tmp/t1.js`, `/tmp/t2.js`... puis, vers
   `t31`, recopie de l'appel précédent avec deux compteurs incrémentés (`t31`
   à `t204`, `seq 1 5` à `seq 1 1650`), sortie identique à chaque fois, aucune
   ligne de texte en 473 entrées.
4. Après `t204`, l'assertion est réécrite (comparée à la moyenne des deux
   éléments du milieu), le test passe.

Piste non vérifiée, donnée comme telle dans #388 : une recopie de ce genre
malgré presence 1,5 (`repeat_last_n=64` au journal) ferait penser à des
pénalités qui ne voient plus les appels déjà présents dans le prompt depuis
#332 (0.4.0). Journal `-v` et session pi, chemins de l'hôte masqués, dans un
gist secret, lien en commentaire de #388 le 02/10/2026.
Piste affaiblie le soir même : le `--help` de la 0.2.0 décrit déjà
`--presence-penalty` comme « Generated-token presence penalty », la pénalité
ne voyait donc pas le prompt avant #332 non plus.

Essai du 03/10/2026, sur les réglages donnés par un tiers dans #388
(raisonnement xhigh, presence 0) : même banc que la nuit du 02/10 (Flash-Next
0.5.0, `--think off`, 2 sessions, 5 passes, `-v`, sessions pi gardées), seule
la macro `qwen` du yaml passée à `--think off --presence-penalty 0.0` le temps
du banc (`presence_penalty=0` vérifié au journal, yaml restauré). Deux salves
de 10 séries (`resultats/agentic/2026-10-03-0.5.0-presence0/` et
`-presence0-b/`) : 26/26 partout, 85 à 95 requêtes par série, aucune boucle.

| Flash-Next, `--think off`, boucle pi | séries avec boucle |
|---|---|
| 0.2.0, presence 1,5 (avant le 03/10) | 0 sur 2 |
| 0.4.0, presence 1,5 | 1 sur 2 |
| 0.5.0, presence 1,5 | 2 sur 9 |
| 0.5.0, presence 0,0 | 0 sur 20 |
| 0.2.0, presence 1,5 (témoin du 03/10, voir plus bas) | 1 sur 5 |

Premier décompte des sessions pi `creation` gardées en 0.5.0, où le test écrit
par le modèle échoue sur une valeur attendue fausse (le plus souvent
`3 !== 4`), tel que publié dans #388 ; périmètre et chiffres corrigés plus bas :

| réglage | sessions | valeur attendue fausse | rattrapées | boucle |
|---|---|---|---|---|
| presence 1,5 (nuit du 02/10, deux rejeux debug) | 28 | 6 | 5 (5 à 7 appels d'outils) | 1 (234 appels) |
| presence 0,0 | 100 | 19 | 19 (5 à 8 appels d'outils) | 0 |

L'erreur de départ est aussi fréquente sans la pénalité (une session sur cinq
dans les deux cas) : c'est le rattrapage qui change. En 0,0 chaque session
fautive ne montre qu'une valeur d'assertion ratée ; en 1,5, 2 sur 6 en montrent
deux (`3 !== 4` puis `3 !== 5.5` pour la boucle, `3 !== 4` et `1.5 !== 5.5`
pour une session rattrapée en 7 appels). Limites : la boucle de la 0.5.0 sans
debug n'a pas de session gardée (hors tableau) ; l'essai ne dit pas si la
pénalité à 0 corrige la cause ou la masque, ni rien du cache ; et la 0.2.0
n'avait que 2 séries en presence 1,5, ce qui ne suffisait pas à établir qu'elle
ne boucle pas (à 2 sur 9, deux séries propres arrivent par hasard six fois sur
dix). Décompte publié dans #388 le 03/10/2026, journaux `-v`, sorties et
sessions pi des 20 séries dans un gist secret (chemins de l'hôte masqués).

Témoin du 03/10/2026 : même banc sur l'image 0.2.0, yaml inchangé
(`presence_penalty=1.5` au journal), 20 séries au plus, arrêt à la première
boucle (`resultats/agentic/2026-10-03-0.2.0-temoin/`). Séries 01 et 02 à 83
requêtes, 03 à 134, 04 à 106, puis boucle en série 05 : 2 140 requêtes, pas
de sortie seule, coupée par le garde-temps d'une heure. **La 0.2.0 boucle
donc aussi : ce n'est pas une régression de la 0.4.0**, et le « jamais vue en
0.2.0 » venait de n'avoir que 2 séries. Pré-commentaire publié dans #388.

Analyse du même jour (sous-agent, lecture seule des journaux et sessions ;
le périmètre, la recopie identique et la copie de sessions ont été revérifiés
à la main, le reste est repris de son rapport) :

- **Même phénomène en 0.2.0 et en 0.5.0** : `3 !== 4`, edit sans texte vers
  5,5, `3 !== 5.5`, enquête sur l'environnement (le modèle doute de node, pas
  de 5,5), puis recopie. Formes différentes : en 0.2.0, 2 059 appels dont
  2 003 fois la même commande octet pour octet
  (`node -e "console.log((2+4)/2)" | od -An -tx1; echo 4 | od -An -tx1`),
  aucun texte, deux compactions de pi sans effet ; en 0.5.0, 234 appels avec
  compteurs incrémentés et sortie seule. Dans les deux cas le test était
  passé au vert AVANT la boucle (appel 14 en 0.2.0, puis 5,5 remis à
  l'appel 38 ; appel 45 en 0.5.0) : le symptôme est une vérification
  compulsive après succès.
- **Séries 03 et 04 du témoin** : des débuts de boucle rattrapés (sessions
  `creation` de 31, 24, 17 et 10 appels, dont six fois de suite la même
  commande avant qu'un texte ne casse la série).
- **Périmètre corrigé** : les sessions de `2026-10-02-0.5.0/sessions2/` et
  `avant/` sont des copies de celles du debug 0.2.0 du 01/10 (à ne pas
  compter en 0.5.0, la boucle de `sessions2` n'a donc pas de session pi) ;
  `avec-cache` et `sans-cache` manquaient au premier décompte ; les
  assertions flottantes (`+ actual - expected`) n'étaient pas comptées.

| sessions `creation` | sessions | avec échec de test | 1re correction fausse | appels jusqu'au vert après échec | boucle |
|---|---|---|---|---|---|
| 0.2.0, presence 1,5 | 30 | 9 | 5 | 5 à 31 | 1 |
| 0.4.0, presence 1,5 | 5 | 1 | 0 | 6 | 0 (+1 sans session) |
| 0.5.0, presence 1,5 | 38 | 8 | 1 | 5 à 46 | 1 (+1 sans session) |
| 0.5.0, presence 0,0 | 100 | 24 | 0 | 5 à 7 | 0 |

Effectifs 38 / 8 et 100 / 24 recomptés à part ; témoin 0.2.0 seul : 25
sessions, 8 avec échec.

- **Ce qui est solide** (Fisher exact unilatéral) : l'erreur de départ est
  aussi fréquente à 0,0 qu'à 1,5 (24 sur 100 contre 17 sur 68, p = 0,51) ;
  la première correction est fausse 6 fois sur 17 à 1,5, toutes versions,
  contre 0 sur 24 à 0,0 (p = 0,003), et toutes les boucles passent par là.
  Critère choisi après lecture des données, à annoncer comme tel.
- **Ce qui ne l'est pas** : la 0.5.0 seule (2 séries sur 9 contre 0 sur 20,
  p = 0,09 ; le « moins de 1 % » publié prenait 2 sur 9 pour un taux exact) ;
  4 séries sur 17 contre 0 sur 20 toutes versions, p = 0,04 ; aucune
  différence 0.2.0 / 0.5.0 à pénalité égale dans un sens ni dans l'autre.
- **Levier de la pénalité** : la valeur choisie dans l'edit sans texte (à
  1,5, 4 corrects sur 9 ; à 0,0, 13 sur 13 ; avec un texte de raisonnement
  avant l'edit, 7 sur 8 et 11 sur 11). Elle n'agit pas sur la recopie entre
  tours (2 003 recopies malgré 1,5 : l'appel précédent est dans le prompt).
  À 0,0 la phase d'enquête ne s'ouvre jamais : on ne sait donc pas si 0,0
  corrige ou masque la recopie une fois cette phase ouverte.
- **Coût de presence 0,0 en 0.5.0, séries sans boucle** (20 séries contre 7) :
  rien de mesurable. `creation` 15,6 contre 16,5 s, `bugfix` 6,8 contre
  7,1 s, décode 50,3 contre 49,9 t/s (recalculé), acceptance MTP 81,8 contre 81,5 %,
  100 % de PASS et de `finish=stop` des deux côtés.
- **Explications concurrentes** : 2 sessions ni nécessaire ni suffisant (la
  boucle 0.4.0 est en 1 session), `-v` n'empêche pas, cache sans anomalie
  visible et identique sur les 100 sessions sans boucle (non exclu
  formellement), MTP non séparable.

Rejeu de la première correction, le 03/10/2026 (mesure recommandée par
l'analyse ; `resultats/388-rejeu-2026-10-03/` : `rejeu-correction.py`,
`requete.json`, `reponses.jsonl`) : la requête qui suit le premier `3 !== 4`
de la session en boucle du témoin, avec l'enveloppe exacte de pi (système,
outils, paramètres, capturés par un relais local ; pi n'envoie aucun
paramètre d'échantillonnage), rejouée 100 fois par bras sur gufo d'usage en
0.2.0, sans flux, bras alternés :

| bras | texte puis edit vers 3 | edit sans texte vers 5,5 | edit sans texte gardant 4 |
|---|---|---|---|
| `presence_penalty` absent (profil de gufo, 1,5) | 81 | 19 | 0 |
| `presence_penalty` 1,5 | 73 | 27 | 0 |
| `presence_penalty` 0,0 | 83 | 10 | 7 |

- **Ce qui décide, c'est le texte avant l'edit** : avec une phrase de
  raisonnement (« trié [1, 2, 4, 7], (2+4)/2 = 3 »), 237 edits justes sur
  237 ; sans texte, 63 faux sur 63, quelle que soit la pénalité.
- **La pénalité ne change pas nettement la part d'edits sans texte** : 17 sur
  100 à 0,0 contre 46 sur 200 à 1,5 (Fisher, p = 0,15). Elle change la valeur
  fausse : toujours 5,5 à 1,5 ; 5,5 ou le même 4 recommenté à 0,0, ce qui
  colle à une pénalité portant sur les tokens déjà générés dans la réponse
  (le `4` vient d'être écrit dans `oldText`) et confirme que la surcharge par
  requête est appliquée.
- **Conséquence** : la seconde valeur fausse arrive aussi à 0,0, ce que les
  20 séries propres ne montraient pas (0 sur 24, mais sur d'autres contextes ;
  celui-ci est choisi parce qu'il a bouclé, ses taux sont sans doute plus
  hauts que la moyenne). La piste « pénalité » de l'analyse ci-dessus en sort
  affaiblie : presence 0,0 n'est pas un correctif établi, et le levier réel
  est d'écrire avant d'agir, ce qui rejoint la remarque du tiers sur le
  raisonnement. Non mesuré : le même rejeu sur llama.cpp.

Publié dans #388 le 03/10/2026 : décompte du témoin, corrections de chiffres,
ce rejeu, et un second gist secret (session en boucle de la 0.2.0, archive des
5 séries, requête et 300 réponses du rejeu). Rien de changé au réglage
d'usage à ce stade. La boucle n'étant pas une régression, elle n'est plus un
motif pour rester en 0.2.0. Piste non mesurée : 10 séries 0.2.0 à presence
0,0.

**Passage en 0.5.0 le 03/10/2026** (choix de l'utilisateur, version seule) :
`GUFO_IMAGE` épinglée en `gufo-runtime:0.5.0` dans `lib/gufo.sh`,
`runtime-gufo/download.sh` et `runtime-gufo/Dockerfile.routeur`, yaml
inchangé (`--think off`, profil Qwen de gufo, cache disque et staging).
Mesures de la 0.5.0 : le tableau du 02/10 ci-dessus. Vérifié sur bigchuck
après bascule : `gufo version 0.5.0 (23cacbb)` dans le conteneur d'usage,
`presence_penalty=1.5` au journal, une requête avec `stop` ; voix,
transcription et image non revérifiées ce jour-là. Reste ouvert de la
lecture du 02/10 : le décode agentique de Flash-Next (44,7 à 46,4 contre
50,4 t/s en 0.2.0).

Consigne côté client, le 03/10/2026 : une phrase ajoutée au prompt système
de pi (`prompts/pi-consigne-edit.txt`, « Avant chaque appel d'outil qui
modifie un fichier, écris une phrase courte qui dit ce que tu vas changer et
pourquoi. », passée par `PI_CONSIGNE`, pi la place dans un bloc
`<addendum>`). Deux mesures sur la 0.5.0, presence 1,5 :

- **Rejeu** de la même requête (`bench/rejeu.py`, 100 fois par bras,
  `resultats/388-rejeu-2026-10-03/consigne-0.5.0.jsonl`) :

  | bras | correction juste (3) | fausse (5,5) sans texte | fausse (5,5) avec texte |
  |---|---|---|---|
  | sans consigne | 84 | 13 | 3 |
  | avec consigne | 100 | 0 | 0 |

  Avec la consigne, une phrase avant chaque edit (100 sur 100) et plus aucune
  fausse correction. Sans, 16 % d'erreurs, du même ordre qu'en 0.2.0 ; trois
  réponses écrivent une phrase et se trompent quand même (« trié :
  [1,4,7,9...] -> (4+7)/2 ») : le texte n'est pas une garantie.
- **Banc** : 10 séries (2 sessions, 5 passes, `-v`, sessions gardées,
  `resultats/agentic/2026-10-03-0.5.0-consigne/`), 26/26 partout, 95 à 102
  requêtes, aucune boucle (0 sur 10 contre 4 sur 17 sans consigne toutes
  versions : Fisher p = 0,14, pas concluant seul). 19 sessions `creation`
  sur 50 avec un test raté (6 sur 33 sans consigne), toutes rattrapées en 5 à
  8 appels d'outils.

  | médianes, 0.5.0 | sans consigne (7 séries sans boucle) | avec consigne (10 séries) |
  |---|---|---|
  | `outils` (s) | 2,6 | 4,35 |
  | `edit` (s) | 3,5 | 4,5 |
  | `creation` (s) | 16,5 | 26,95 |
  | `bugfix` (s) | 7,1 | 9,1 |
  | somme des quatre + `simple` (s) | 30,0 | 45,2 |
  | tokens générés par requête | 29 | 44 |
  | tokens générés par série | ~5 400 | ~9 600 |
  | décode (t/s) | 49,9 | 46,8 |
  | acceptance MTP | 81,5 % | 84,0 % |

  La consigne coûte donc environ +50 % de temps par passe sur ce banc (plus
  de texte, et plus de tests ratés au premier jet), contre x2,3 pour
  `--think xhigh`. Non décidé : rien n'est posé dans la configuration d'usage
  de pi, d'omp ni du proxy ; résultats publiés dans #388 le 03/10/2026.

Raisonnement faible, le 03/10/2026 (idée de l'utilisateur), 0.5.0. gufo
l'accepte par requête : `reasoning_effort: "low"` (ou `minimal`) active le
raisonnement pour cette requête seule et bascule sur le profil Qwen avec
raisonnement (`thinking=on temperature=1 presence_penalty=0` quand il est
posé au serveur). **Règle de l'utilisateur : le niveau de raisonnement se
règle côté client (pi, omp), au lancement ou par requête, jamais en modifiant
la configuration du serveur**, qui reste en `--think off`.

- **Rejeu** (`resultats/388-rejeu-2026-10-03/think-0.5.0.jsonl`, 100 fois
  par bras, champ de requête seul) :

  | bras | correction juste (3) | fausse (5,5) | tokens générés (médiane) | raisonnement (médiane) |
  |---|---|---|---|---|
  | sans raisonnement | 62 | 38 | 153 | 0 |
  | `reasoning_effort: minimal` | 100 | 0 | 188 | 109 caractères |
  | `reasoning_effort: low` | 100 | 0 | 192 | 122 caractères |

  Le bras sans raisonnement donne 38 erreurs ici contre 16 au rejeu de la
  consigne (même version, même requête) : écart inexpliqué, le taux « sans
  rien » n'est pas stable d'un rejeu à l'autre (19, 27, 16, 38 sur 100 au fil
  de la journée) ; seule la comparaison entre bras alternés d'un même rejeu
  vaut.
- **Banc, deux voies** : 6 séries avec la macro `qwen` passée à `--think on
  --reasoning-effort low` le temps du banc (`resultats/agentic/2026-10-03-0.5.0-think-low/`,
  arrêtées à 6 sur 10 à la demande de l'utilisateur : voie à ne plus
  employer), puis 1 série par le client, `PI_THINKING=low` du banc (pi
  `--thinking low`, modèle déclaré `reasoning: true` dans le `models.json`
  généré, requêtes capturées avec `reasoning_effort: "low"`, journal du
  serveur resté en `thinking=off presence_penalty=1.5`,
  `resultats/agentic/2026-10-03-0.5.0-pi-thinking-low/`). 26/26 partout,
  86 à 91 requêtes, aucune boucle en 7 séries. Un seul test raté au premier
  jet sur 35 sessions `creation` (rattrapé en 6 appels), contre environ une
  sur quatre sans raisonnement.

  | médianes, 0.5.0 | sans raisonnement (7 séries) | consigne pi (10 séries) | low au serveur (6 séries) | low par pi (1 série) |
  |---|---|---|---|---|
  | `simple` (s) | 0,3 | 0,3 | 1,0 | 0,9 |
  | `outils` (s) | 2,6 | 4,35 | 5,65 | 6,3 |
  | `edit` (s) | 3,5 | 4,5 | 8,9 | 9,3 |
  | `creation` (s) | 16,5 | 26,95 | 16,1 | 14,9 |
  | `bugfix` (s) | 7,1 | 9,1 | 17,45 | 16,4 |
  | somme des cinq (s) | 30,0 | 45,2 | 49,1 | 47,8 |
  | tokens générés par série | ~5 400 | ~9 600 | ~10 300 | ~10 900 |
  | tokens générés par requête | 29 | 44 | 84 | 86,5 |
  | décode (t/s) | 49,9 | 46,8 | 44,5 | 44,5 |
  | acceptance MTP | 81,5 % | 84,0 % | 79,5 % | 79,6 % |

  Les deux voies donnent le même résultat. Le raisonnement faible coûte
  environ +60 % de temps par passe (x2,3 pour `xhigh`), réparti autrement que
  la consigne : `creation` n'est pas plus lent (moins de tests ratés), les
  petites tâches (`edit`, `bugfix`) le sont 2,5 fois. Choix de l'utilisateur :
  on s'arrête là pour le 03/10, le niveau low suffit ; rien n'est posé dans
  la configuration d'usage, non publié dans #388.

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
(contexte natif, génération jusqu'à EOS) ; depuis v0.2.0 (#282),
l'échantillonnage suit les profils officiels des modèles (glouton avant), ses
propres bancs restant en glouton. Les valeurs ci-dessous visent un
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
Confrontées le 29/09/2026 à v0.2.0 (diff 0.1.1...0.2.0 et des deux
`--help`) : échantillonnage et raisonnement par défaut changés (#282), nos
valeurs Qwen explicites retirées (identiques au profil sans raisonnement),
macro DeepSeek retirée ; aucune option ajoutée ou retirée, cache disque et
staging inchangés. Confrontées le 01/10/2026 à v0.4.0 (diff 0.2.0...0.4.0
et des deux `--help`) : une seule option ajoutée, `--log-level` (`-v` en
devient le raccourci `debug`, `--log-progress` refusé en `warn`/`error`),
aucun défaut changé ; la nouvelle `docs/KV-CACHE.md` confirme le staging
(1 Gio sous un seul point de reprise du 27B à 24k tokens) et chiffre
`--sessions` : le cache garde environ `--sessions` conversations, une de plus
fait tomber la reprise d'environ 95 % à 0 %. Version non retenue (#368).
Confrontées le 02/10/2026 à v0.5.0 (diff 0.4.0...0.5.0, `--help` 0.2.0 et
0.5.0) : une option ajoutée, `--cache-ram-bytes` (budget RAM des instantanés,
automatique par défaut, non posée), aucun défaut changé ; `--sessions` ne
borne plus le nombre de conversations retenues (#369), nos 2 sessions restent
mesurées utiles (section « Release v0.5.0 »). Version non retenue (boucle de
#368).

| Paramètre | `runtime-gufo/gufo-llama-swap.yaml` | Défaut de gufo | Exemples gufo (guides des modèles) | Origine |
|---|---|---|---|---|
| `--context` | 262144 | contexte natif depuis d5fd781 (4096 avant) | 32768 | nous : contexte natif, celui du service ; redondant depuis d5fd781 (chargement : `context_tokens=262144`), gardé explicite parce que `capabilities.context` doit lui rester égal |
| `--sessions` | 2 | 1 | 2 | gufo (guides du 27B et de Flash-Next) et notre mesure (7 Gio, plus d'éviction par les requêtes annexes) |
| `--max-tokens` | non posé (-1, jusqu'à EOS) | -1 depuis #276 (128 avant) | non indiqué | gufo, comme le service (llama.cpp à -1, aucun `n-predict` dans le ini) ; 32768 explicite jusqu'au 26/09/2026, quand le défaut de 128 coupait un client sans `max_tokens` |
| échantillonnage | non posé (profil de gufo) ; temp 0,7, top-k 20, top-p 0,8, min-p 0, presence 1,5 explicites pour Qwen, temp 1,0, top-k 40, top-p 0,95 pour DeepSeek jusqu'au 29/09/2026 | profil officiel du modèle depuis v0.2.0 (#282) : Qwen sans raisonnement 0,7 / 0,8 / 20 / 1,5, avec 1,0 / 0,95 / 20 / 0 ; DeepSeek 1,0 / 0,95 / top-k 0 ; glouton avant | aucun | gufo, depuis v0.2.0 : Qwen officiel, profil instruct, celui des sections nothink du service et de nos anciennes valeurs ; surchargeable par requête |
| `--think` | off | raisonnement : Qwen effort xhigh, DeepSeek effort high depuis v0.2.0 (sans raisonnement avant) | non indiqué | nous : équivalent des sections nothink pour Qwen, mesuré le 02/10/2026 sur Flash-Next (0.2.0, boucle agentique pi, 3 passes) : `--think on --reasoning-effort xhigh` donne 16/16 aussi, mais 71,4 s par passe contre 30,9 s (x2,3, somme des médianes par scénario), 2,4 fois plus de tokens générés, décode 44,5 contre 50,4 t/s, acceptance MTP 76,2 contre 84,6 %, cache inchangé (93 %) ; à activer par requête côté client si besoin ; pour DeepSeek, raisonnement sans budget mesuré à +43 % de temps en agentique le 29/09/2026 (non posé entre la montée en 0.2.0 et cette mesure) |
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
8. **Documenter et répondre** : section de la release dans « Suivi en amont »
   (contenu, choix, tableau contre la mesure précédente), tableau
   « À surveiller » (tickets fermés retirés), tableau des paramètres (date
   de confrontation) ;
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
