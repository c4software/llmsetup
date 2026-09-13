# Historique et campagnes de mesure détaillées

Archive des campagnes de mesure et des essais du dépôt, sortie du README le
13/09/2026 pour n'y garder que l'état courant. Le contenu est celui des
sections correspondantes du README, repris tel quel : chiffres, protocoles et
récits datés. L'état courant du parc (réglages retenus et perfs sur le fork)
reste dans `README.md`, section « Parc au 13/09/2026 ».

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

## Récapitulatif par modèle, campagne des 12 et 13/09/2026 (fork strix-0007bc6)

| Modèle | GGUF | Device | Réglage retenu | Prefill t/s | Gen t/s | État |
|---|---|---|---|---|---|---|
| lfm2.5-2.6b | Q8_0 (2,7 Go) | Vulkan0 (mesuré) | parallel 4 | **3048** (2279 au paquet b10433) | **70,8** (67,7 au paquet ; 205 agrégés à 4 requêtes, x3,06) | fork strix-0007bc6, 13/09/2026 ; cache tour suivant 62 % ; chargement 0,5 s, TTFT 27 ms |
| qwen3.5-9b | UD-Q6_K_XL (8,2 Go) | Vulkan0 (mesuré) | parallel 4 | **971** (837 au paquet b10433) | **25,7** (25,7 au paquet ; 78,6 agrégés à 4, x3,06) | fork strix-0007bc6, 13/09/2026 ; cache 62 % ; chargement 1,9 s |
| ornith-1.5-35b-a3b | Q4_K_M (22 Go) | Vulkan0 (mesuré : ROCm0 931 / 57,6) | parallel 4, sans spéculation | **1129** (974 au paquet b10566) | **73,3** (70,7 au paquet ; 136,8 agrégés à 4, x1,93) | fork strix-0007bc6, 13/09/2026 ; cache 62 % ; remplace les trois Qwen3.6-35B-A3B le 28/08/2026 |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0 (mesuré) | **draft-dflash 7** (DFlash 2 z-lab, retenu le 13/09/2026 sur le fork ; spec-prefill essayé et retiré, cache de prompt à 0 %) | **349** (215 au paquet b10433 ; 289 → 183 à 32k en llama-bench) | **21,7** (acc. 0,35 ; 12,1 sans spéculation au paquet, +79 %) | fork strix-0007bc6, 13/09/2026 ; reasoning-budget 4096 (fork) ; spec-prefill lossy et incompatible avec le cache de prompt, perdant en agentic |
| qwen3.8-27b-dflash-nothink | idem | Vulkan0 (mesuré) | ngram-map-k 47 + **draft-dflash 7** (drafter DFlash 2 z-lab, 2,0 Go ; remplace la tête MTP le 13/09/2026 : le batch de vérification 8 se découpe en 4+4 et échappe au pire cas du découpage mat-vec) | **359** (261 au paquet b10433) | **32,6** (acc. 0,595 ; 29,5 acc. 0,65 au paquet, +11 % ; 26,6 acc. 0,59 en MTP n-max 6 sur le fork, +23 %) ; **64,5** (refactor, acc. 0,67) et **35,9** (générique, acc. 0,70) en `--spec-ab` | fork strix-0007bc6, 13/09/2026 ; DFlash 2 bat la tête MTP sur les deux prompts (+12 % en refactor, +18 % en générique) et annule le retrait de décode du fork ; réglage non mesuré sur le paquet Arch ; chargement 4,4 s |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go) | Vulkan0 (mesuré) | ngram-map-k 7 | **205** (110 au paquet b10433) | **19,9** (acc. 0,65 ; 12,3 au paquet) | fork strix-0007bc6, 13/09/2026, plus gros gain de décode du parc (+62 %) ; ROCm0 inutilisable (b10433) ; cache 99 % (attention pure) ; reasoning-budget 6144 (fork) |
| qwen3-coder-next | UD-Q4_K_XL (47 Go) | Vulkan0 (mesuré, ROCm0 exclu) | ngram-map-k 47 (compromis : +47 % refactor, -5 % générique) | **763** (468 au paquet b10433) | **48,7** (bench, acc. 0,27 ; 43,7 au paquet) ; 68,7 (refactor, paquet) | fork strix-0007bc6, 13/09/2026 ; ROCm0 répond « LAMPAMPAMP… » ; cache 64 % ; chargement 72 s depuis le disque |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE) | Vulkan0 (mesuré : ROCm0 219 / 31,5, juste lent) | ngram-map-k 7 | **599** (333 au paquet b10548) | **52,9** (bench, acc. 0,57 ; 51,9 au paquet) ; 59,8 (refactor, paquet) | fork strix-0007bc6, 13/09/2026 ; cache 99 % (attention, pas d'état récurrent) ; chargement 91 s depuis le disque |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 (mesuré : ROCm0 320 / 23,6) | **ngram-map-k 7** seul (draft-dflash refusé par le mainline `wrong number of tensors; expected 76, got 69` **et** par le fork le 12/09/2026 : `failed to load draft model`) | **346** (255 au paquet b10548) | **29,6** (bench, acc. 0,80 ; 30,3 acc. 0,835 au paquet) ; 53,0 (refactor, +85 %, paquet) | fork strix-0007bc6, 13/09/2026 ; cache 99 % ; chargement 67 s depuis le disque |
| qwen3.8-flash-next-mtp-nothink | UD-IQ4_XS (94 Go, MoE, GDN) | Vulkan0 (mesuré, ROCm0 exclu) | **ngram-map-k 7** + **draft-mtp 4** (confirmé, k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7) sur le fork (sidecar autonome Q8_0 renommé par `tools/mtp-rename-hc-head.py` ; le mainline ne sait toujours pas le charger, PR #28243) | **383** (414 en n-gram seul sur le fork ; 197 au paquet b10809) | **50,0** (bench mixte, acc. 0,87 ; 30,9 en n-gram seul sur le fork, 25,9 au paquet) ; **54,0** (refactor, +115 %) | fork strix-0007bc6, 12/09/2026 (le MTP n'existe pas sur le paquet) ; ROCm0 répond « LAMPAMPAMP… » ; cache 62 % ; chargement 14 s (cache de pages chaud) |

Prefill et Gen : valeur du fork strix-0007bc6 en gras, valeur du paquet Arch
entre parenthèses. Médianes hors première passe ; « cache » = part du prompt
servie du cache pour tour suivant / édition au milieu / requête identique.
Détail et écarts en pourcentage ci-dessous.

Historique du parc : qwen3.8-27b-mtp-nothink renommé qwen3.8-27b-dflash-nothink
le 13/09/2026 : tête MTP remplacée par le drafter DFlash 2. Le même jour,
qwopus3.6-27b-coder-mtp-nothink a été retiré, plus utilisé ; ses mesures
restent dans `logs/`. Avant lui, les trois Qwen3.6-35B-A3B ont été remplacés
par ornith-1.5-35b-a3b le 28/08/2026.

## Paquet Arch contre fork : mesures

Comparaison des deux séries, faite le 13/09/2026 ; les figures tirées de
cette table (`docs/graphs/*.svg`) sont restées dans le README.

Protocole `--bench` du dépôt (prefill de la passe 1 à froid, décode médian des
passes suivantes, acceptance médiane), sauf mention. Colonne « paquet » :
dernière valeur de la série `bNNNNN` dans `logs/bench.log` pour ce modèle.
Colonne « fork » : campagne `--bench` 3 passes, Vulkan0, `strix-0007bc6`, les
12 et 13/09/2026, parc entier.

| Modèle | Paquet (prefill / gen) | Fork strix-0007bc6 (prefill / gen) | Écart prefill | Écart gen | Note |
|---|---|---|---|---|---|
| lfm2.5-2.6b | 2279 / 67,7 (b10433, 21/08) | 3048 / 70,8 (13/09) | +33,7 % | +4,6 % | bench.log du 02/09 (b10621) donnait déjà 2743 / 69,4 : l'essentiel de l'écart de prefill vient du build, pas du fork (+11 % sur cette base) |
| qwen3.5-9b | 837 / 25,7 (b10433, 21/08) | 971 / 25,7 (13/09) | +16,0 % | 0 % | décode identique au dixième ; bench.log 02/09 (b10621) 25,59, prefill inexploitable (67, contaminé par le cache) |
| ornith-1.5-35b-a3b | 974 / 70,7 (b10566, 28/08) | 1129 / 73,3 (13/09) | +15,9 % | +3,7 % | sans spéculation des deux côtés |
| qwen3.8-27b (thinking) | 215 / 12,1 (b10433, 21/08) | 349 / 21,7 / acc. 0,35 (13/09, draft-dflash 7, reasoning_effort medium) | +62,3 % | +79,3 % | réglage différent des deux côtés : le paquet tournait sans spéculation, le fork avec le drafter DFlash 2. Le comparateur du dépôt affiche « prefill 759 → 349 régression » : les 759 t/s du 12/09 à 23:15 portaient `spec-prefill-p` 0,30, option retirée depuis (cache de prompt à 0 %) ; 349 est la première mesure du réglage réellement servi, ce n'est pas une régression. Référence sans spéculation sur le paquet : bench.log 02/09 (b10621) 239 / 12,13 ; `--spec-test` du 13/09 : 24,5 t/s contre 12,3 sans |
| qwen3.8-27b-dflash-nothink | 261 / 29,5 / acc. 0,65 (b10433, 21/08) | 359 / 32,6 / acc. 0,595 (13/09, réglage retenu : ngram 47 + draft-dflash 7) | +37,5 % | +10,5 % | le décode du fork passe au gain net avec le drafter DFlash 2. Sur l'ancien réglage MTP n-max 6, le même fork donnait 360 / 26,6 / 0,59, soit -9,8 % de décode : DFlash 2 gagne +22,6 % sur cette base. Ce seul écart de décode négatif du parc **s'expliquait** par le découpage des mat-vec batchés du fork (colonnes 4/2/1, restreint à q8_0 et q6_K par sa PR #27 ; le UD-Q4_K_XL porte 110 tenseurs q8_0 et 56 q6_K), à son pire cas au batch de vérification 7 = n-max 6 + 1, découpé en 4+2+1. llama-bench du 13/09 (Vulkan0, `-b 8 -ub 8 -r 3`) : pp7 68,9 t/s contre 74,4 avec `GGML_VK_MMV_NO_SPLIT=1` et 74,5 au paquet b10809 (-7,4 %), pp5 54,2 contre 56,9 (-4,7 %), pp4 47,8 contre 47,7 (aucune pénalité). Le réglage du fork n'est plus celui du paquet : **ngram 47 + draft-dflash n-max 7** (drafter DFlash 2 z-lab), qui bat la tête MTP sur les deux prompts en `--spec-ab` du 13/09 (4 passes, décode médian hors 1re passe). Sur spec-refactor.txt : 64,5 t/s acc. 0,67 contre 57,6 / 0,71 en MTP n-max 4 et 53,8 / 0,67 en n-max 6 ; spec-test.txt : 35,9 / 0,70 contre 30,5 / 0,65 en MTP n-max 4 (draft-dflash seul : 47,0 / 0,96 en refactor, 37,0 / 0,77 en générique). Le batch de vérification vaut alors 8, découpé en 4+4 : le pire cas du découpage est contourné, ce que le `--bench` du 13/09 confirme (32,6 t/s) |
| qwen3.8-flash-next-mtp-nothink | 197 / 25,9 / acc. 0,75 (b10809, 05/09) | 414 / 30,9 / acc. 0,80 en n-gram seul avec `ngram-on-disk` (12/09) | +110,2 % | +19,3 % | à réglage égal (n-gram seul) ; sur spec-refactor.txt le paquet fait 54,0 en n-gram seul |
| qwen3.8-flash-next-mtp-nothink (n-gram + draft-mtp 4) | impossible sur le paquet | 383 / 50,0 / acc. 0,87 (12/09) | +94,4 % contre le paquet en n-gram seul | +93,1 % contre le paquet en n-gram seul | le MTP n'existe pas sur le paquet (sidecar refusé) ; `--spec-tune` draft-mtp seul k2/4/6/8 = 43,0 / **50,7** / 49,5 / 32,7 ; `--spec-test` mixte 48,8 acc. 0,86 |
| qwen3-coder-next | 468 / 43,7 (b10433, 21/08) | 763 / 48,7 / acc. 0,27 (13/09) | +63,0 % | +11,4 % | acceptance n-gram inchangée (0,29 au paquet) : le gain vient du moteur, pas de la spéculation |
| gpt-oss | 333 / 51,9 (b10548, 21/08) | 599 / 52,9 / acc. 0,57 (13/09) | +79,9 % | +1,9 % | décode neutre ; le fork journalise une acceptance n-gram là où le paquet n'en donnait pas |
| laguna-s-2.1 | 255 / 30,3 / acc. 0,835 (b10548, 21/08) | 346 / 29,6 / acc. 0,80 (13/09) | +35,7 % | -2,3 % | dans le bruit de mesure ; DFlash refusé par le fork comme par le paquet (12/09) |
| deepseek-v4-flash | 110 / 12,3 (b10433, 21/08) | 205 / 19,9 / acc. 0,65 (13/09) | +86,4 % | +61,8 % | plus gros gain de décode du parc ; reasoning-budget 6144 posé au passage (seuil non atteint sur le test fait) |

Deux valeurs de la colonne paquet diffèrent au chiffre près de la table du parc
d'origine, qui arrondissait un autre run du même jour : qwen3-coder-next 468 au
lieu de 457, laguna-s-2.1 255 au lieu de 247. C'est `logs/bench.log` qui fait foi.

Bilan. Le fork gagne le prefill sur tout le parc, de +16 % (qwen3.5-9b,
ornith) à +110 % (Qwen3.8-Flash-Next), sans exception. Il gagne nettement le
décode partout où la spéculation change de régime : DeepSeek V4 +62 %,
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
rien faire tant que l'épinglage est en place).

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

