# Historique et campagnes de mesure détaillées

Archive des campagnes de mesure et des essais du dépôt, sortie du README le
13/09/2026 pour n'y garder que l'état courant. Le contenu est celui des
sections correspondantes du README, repris tel quel : chiffres, protocoles et
récits datés. L'état courant du parc (réglages retenus et perfs sur le fork)
reste dans `README.md`, section « Parc au 15/09/2026 ».

Deux séries de mesures cohabitent ici et ne se comparent jamais entre elles :
le paquet Arch (`bNNNNN`) et le fork strix-llama.cpp (`strix-<commit>`).

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
| qwen3.5-9b | UD-Q6_K_XL (8,4 Go, GGUF MTP unsloth, dossier `qwen3.5-9b-mtp/`) | Vulkan0 (hérité : bench-devices.conf est indexé par dossier de GGUF) | **ngram-map-k 7 + draft-mtp 4**, min-hits 2, parallel 1 (retenu le 15/09/2026, tête MTP embarquée blk.32.nextn) | **745** (837 au paquet b10433 le 21/08, réglage sans spéculation à 4 slots sur le GGUF sans MTP ; 971 sur le fork le 13/09 et 791 le 15/09 avec ce même réglage) | **33,0** (acc. 0,58 ; 25,7 au paquet comme sur le fork le 13/09 sans spéculation, 25,5 re-mesuré le 15/09, soit +29 % ; 52,1 en test isolé, x2,1) | fork strix-0007bc6, 15/09/2026 ; cache 62 % au tour suivant, 0 % après édition, 64 % à l'identique, inchangé par le MTP ; multi-slot MTP inutilisable (np 4 n-max 1 = 18,2 t/s agrégés contre 80,8) ; le réglage sans spéculation à 4 slots (78,6 t/s agrégés à 4 requêtes, x3,06 ; chargement 1,9 s, TTFT 65 ms) a été gardé en variante `-parallel` la journée du 15/09/2026 puis retiré, cf. « Variantes -parallel retirées » |
| ornith-1.5-35b-a3b-parallel | Q4_K_M (22 Go) | Vulkan0 (mesuré : ROCm0 931 / 57,6) | parallel 4, sans spéculation | **1129** (974 au paquet b10566) | **73,3** (70,7 au paquet ; 136,8 agrégés à 4, x1,93) | fork strix-0007bc6, 13/09/2026 ; cache 62 % ; remplace les trois Qwen3.6-35B-A3B le 28/08/2026 ; **section renommée `-parallel` le 15/09/2026** (le suffixe dit l'usage, comme `-mtp`) : partout plus bas, les entrées datées et les mesures gardent le nom d'alors `ornith-1.5-35b-a3b`, qui reste aussi celui du dossier de GGUF |
| ornith-1.5-35b-a3b-mtp | idem (même GGUF) | Vulkan0 (hérité : bench-devices.conf est indexé par dossier de GGUF) | **ngram-map-k 7 + draft-mtp 4**, parallel 1 (tête MTP embarquée blk.40.nextn, découverte le 15/09/2026) | **1073** (jamais mesuré au paquet) | **76,2** (acc. 0,55 ; 73,3 pour la section de base sans spéculation) ; **113,2** (refactor, acc. 0,83) et **90,3** (générique, acc. 0,65) en test isolé | fork strix-0007bc6, 15/09/2026 ; section créée pour l'usage mono-utilisateur (+24 % en solo, 88,7 contre 71,6 t/s) ; la section de base reste le défaut agentic, elle bat la variante MTP en concurrence réelle (138 t/s agrégés à 4 requêtes contre 102) |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0 (mesuré) | **draft-dflash 7** (DFlash 2 z-lab, retenu le 13/09/2026 sur le fork ; spec-prefill essayé et retiré, cache de prompt à 0 %) | **349** (215 au paquet b10433 ; 289 → 183 à 32k en llama-bench) | **21,7** (acc. 0,35 ; 12,1 sans spéculation au paquet, +79 %) | fork strix-0007bc6, 13/09/2026 ; reasoning-budget 4096 (fork) ; spec-prefill lossy et incompatible avec le cache de prompt, perdant en agentic |
| qwen3.8-27b-dflash-nothink | idem | Vulkan0 (mesuré) | ngram-map-k 47 + **draft-dflash 7** (drafter DFlash 2 z-lab, 2,0 Go ; remplace la tête MTP le 13/09/2026 : le batch de vérification 8 se découpe en 4+4 et échappe au pire cas du découpage mat-vec) | **359** (261 au paquet b10433) | **32,6** (acc. 0,595 ; 29,5 acc. 0,65 au paquet, +11 % ; 26,6 acc. 0,59 en MTP n-max 6 sur le fork, +23 %) ; **64,5** (refactor, acc. 0,67) et **35,9** (générique, acc. 0,70) en `--spec-ab` | fork strix-0007bc6, 13/09/2026 ; DFlash 2 bat la tête MTP sur les deux prompts (+12 % en refactor, +18 % en générique) et annule le retrait de décode du fork ; réglage non mesuré sur le paquet Arch ; chargement 4,4 s |
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
Dans la foulée, la section de base est renommée `ornith-1.5-35b-a3b-parallel` :
le nom dit ce qu'elle sert, comme `-mtp` et `-dflash-nothink` ailleurs, puisque
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
mais distinct de celui du dossier `qwen3.5-9b-mtp/` que sert la section
`qwen3.5-9b`. `./setup-llm.sh --cleanup` les purge.

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
contexte).

| Modèle | Architecture | Tour suivant | Édition au 1er tiers | Requête identique | Prefill froid → identique |
|---|---|---|---|---|---|
| lfm2.5-2.6b | conv récurrente (autre tokenizer) | 63 % (62) | 0 % (0) | 64 % (63) | 373 → 151 ms |
| qwen3.5-9b | hybride SWA/GDN | 62 % (62) | 0 % (0) | 64 % (63) | 1 419 → 549 ms |
| qwen3.8-27b | dense, GDN + gated attention | 62 % | 0 % | 64 % | 3 814 → 1 463 ms |
| qwen3.8-27b-dflash-nothink | idem (même GGUF) | 62 % | 0 % | 64 % | 3 838 → 1 472 ms |
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
attention pure comprise. Le cache de prompt du serveur ne sert que les
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
existe. L'état du cache de pages est déduit de la variation de `buff/cache`
pendant le chargement.

| Modèle | Taille | Chargement + 1er token | TTFT à chaud | État du cache de pages |
|---|---|---|---|---|
| lfm2.5-2.6b | 2,7 Go | 0,9 s (0,5) | 26 ms (27) | chaud |
| qwen3.5-9b | 8,2 Go | 5,0 s (1,9) | 63 ms (65) | disque (+8 Go de cache de pages) |
| qwen3.8-27b | 17 Go | 3,6 s (4,4) | 129 ms (165) | chaud (~4,7 Go/s) |
| qwen3.8-27b-dflash-nothink | 17 Go (même GGUF) | 3,5 s | 131 ms | chaud |
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

