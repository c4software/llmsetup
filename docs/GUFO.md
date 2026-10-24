# gufo : état courant et suivi

Document de travail sur [gufo](https://github.com/gufo-org/gufo), moteur
d'inférence spécialisé Strix Halo, évalué le 24/09/2026 face au moteur du
service puis servi à sa place sur `:8009` (les deux ne tiennent pas ensemble
en mémoire). Depuis le 09/10/2026 c'est un **runtime** du dépôt
(`runtime/gufo/`, contrat dans `runtime/CONTRAT.md`), au même rang que le
service, qui est le runtime `llama-cpp-rocm-strix` : on bascule de l'un à
l'autre par `./setup-llm.sh --runtime <nom>`. Pilotage et bancs sont versionnés
dans `runtime/gufo/`, sans intégration au routeur du service. Le détail daté
(évaluation, releases, tickets, mesures) est dans le journal
[`docs/HISTORIQUE-GUFO.md`](HISTORIQUE-GUFO.md) ; ce document n'en garde que
la synthèse et ce qui sert au travail courant.

État au 14/10/2026 :

- **Verdict** : bien configuré, gufo fait le même travail agentique que le
  service en 30 % de temps en moins sur le 27B et Flash-Next, sans le
  remplacer (section « Verdict »).
- **En service** : image épinglée par la ligne de `runtime/gufo/IMAGE`, seul
  endroit où la version courante est écrite (historique des montées dans
  « Versions : synthèse »), remesurée à chaque montée ; derrière llama-swap,
  en `--think off`, 2 sessions, cache disque 16 Gio par dossier (Flash-Next
  et le 27B ont chacun le leur), staging 8 Gio pour DeepSeek seul ;
  réglages dans « Paramètres de gufo et leur origine ».
- **Tickets** : les ouverts qui bougent encore sont dans le tableau
  « À surveiller ». Notre
  ticket #388 (boucle d'appels d'outils de Flash-Next) a été fermé le
  03/10/2026 ; sa synthèse est dans « Ticket #388 ».
- **Cache en 0.7.0** : #386 (préfixe partagé repris sans `--cache-disk`)
  vérifié le 04/10/2026, reprise sans disque de 90 à 91,8 % ; le disque
  rapporte encore 1,4 à 1,8 point et survit seul aux bascules de modèle,
  `--cache-disk` et staging 8 Gio gardés. Décode agentique de Flash-Next
  revenu à 48,1 t/s (44,7 à 46,4 en 0.5.0, 50,4 en 0.2.0).
- **0.7.1** : Flash-Next 16/16, décode agentique 50,7 t/s, prefill long à
  +4 à +6 % (#421) ; 27B non remesuré. Baisse du prefill court vue au banc
  HTTP : écritures lentes du cache disque (NVMe), dans les deux versions,
  pas la 0.7.1 (journal, « Prefill court en baisse au banc »).
- **0.8.0** : `/v1/responses` compatible avec les clients OpenAI (#434),
  rien d'autre ; Flash-Next 16/16, au niveau de la 0.7.1.
- **0.8.1** : appels d'outils en syntaxe native (#441) ; Flash-Next 16/16 sur
  deux séries, débits au niveau de la 0.8.0. Première série à 91,2 % de
  reprise (points de reprise disque de la 0.8.0 inutilisables, préfixe
  changé), 98,4 % à la seconde. Une boucle de vérification sur `creation`
  (forme de #388, 88,7 s, PASS).
- **0.9.0** : points de reprise de Flash-Next sans copie (#445), prefill à
  long contexte (#463) ; Flash-Next 16/16 sur deux séries, débits au niveau
  de la 0.8.1 (prefill 52k 1 424 puis 1 416 t/s, gain annoncé par #445 non
  vu à notre banc), mémoire 107 Gio au lieu de 111. Première série à 93,1 %
  de reprise (points de reprise disque de la 0.8.1 presque tous
  inutilisables, alors que le format disque est annoncé inchangé), 98,6 % à
  la seconde. `--max-pending-per-client` vaut désormais `--max-pending` par
  défaut (16 au lieu de 4). 27B remesuré le même jour, première fois depuis
  la 0.7.0 : 16/16, boucle agentique identique (décode 42,5 t/s, reprise
  93,4 %), prefill 1 à 2 % plus bas sur une série.
- **0.9.1** : prefill de Flash-Next par blocs de 4 096 tokens (#470),
  noyaux de prefill sans spill sous clang 23 (#459), staging automatique
  sans plafond de 1 Gio (#473). 16/16 sur le 27B (une série) et Flash-Next
  (deux séries), prefill long de Flash-Next à +4 % (1 481 et 1 480 t/s à
  52k contre 1 424 et 1 416), mémoire inchangée, 27B au niveau de la 0.9.0.
  Première série de Flash-Next à 91,5 % de reprise (cache disque froid),
  99,2 % à la seconde. Staging au défaut essayé sur le 27B (10,6 Gio
  résolus, aucun refus, aucune écriture exercée) ; 8 Gio gardés.
  Écritures du cache disque de Flash-Next à 2,3 à 3,2 s à la première série
  (115 à 127 ms en 0.9.0), non reproduites à l'essai croisé 0.9.0 / 0.9.1
  du même jour (94 à 155 ms dans les deux versions) : pas la version, pas
  de ticket.
- **0.10.0** : prefill et rattrapage MTP de Flash-Next (#485), outils et
  streaming sur `/v1/messages` (#469, non essayé), tuiles IQ2 de DeepSeek
  pour les lots de 2 à 31 tokens (#482, non mesuré). Flash-Next seul
  remesuré, deux séries : prefill long à +5 à +7 % (1 583 et 1 559 t/s à
  52k contre 1 481 et 1 480), décode et mémoire inchangés, `--help`
  identique à la 0.9.1. 16/16 à la première série (reprise 93,6 %, cache
  disque froid), **15/16 à la seconde** : boucle d'appels d'outils sur
  `creation` jusqu'au garde-temps de 300 s, forme de #388 (toutes
  versions), retenue quand même par l'utilisateur. Écritures du cache
  disque normales (119 à 164 ms), Flash-Next mesuré sans le 27B avant lui.
  27B remesuré après la décision (une série) : 16/16, pas de boucle, au
  niveau de la 0.9.1 (prefill 499,9 t/s à 52k, décode agentique 43,3 t/s,
  reprise 93,6 %).
- **0.11.0** : première livraison de la refonte du cache de continuation
  (#493 à #517), noyaux de décodage de Flash-Next (#518), images dans les
  résultats d'outils (#506, non essayé). **Mesurée sur silentchuck**, contre
  les séries 0.10.0 du 09/10 au soir sur cette machine (pas contre les
  chiffres de bigchuck des lignes précédentes), une série par modèle, 16/16
  sur les deux, pas de boucle. Flash-Next : décode à +6 à +8 % (71,5 à
  72,5 t/s en code contre 66,0 à 67,5, 52,7 t/s en agentique contre 48,6),
  prefill long à +1,4 à +2,7 % (1 606 t/s à 52k), dans la dispersion des
  séries. 27B au niveau de la 0.10.0 (prefill 522,5 t/s à 52k, décode
  agentique 43,8 t/s). Cache disque de la 0.10.0 relu sans rejet, écriture
  au nouveau format exercée par le 27B seul (3 points, 231 à 236 ms) ;
  `--help` identique, aucun réglage changé.
- **0.12.0** : snapshots de Flash-Next gardés dans la marge du device
  (#549, panne `generation_failed` puis segfault à l'arrêt quand la GTT est
  pleine), arguments des appels d'outils diffusés au fil de l'eau (#534),
  adaptateur de continuation de Flash-Next livré inactif (#536), images et
  `count_tokens` sur `/v1/messages` (#510, #512, non essayés). Mesurée sur
  silentchuck contre la 0.11.0 de la veille, une série, 27B puis Flash-Next,
  16/16 sur les deux, pas de boucle. 27B identique (prefill 522,3 t/s à 52k,
  décode agentique 42,5 t/s). Flash-Next : prefill long 1 à 2 % plus bas
  (1 589 t/s à 52k, dans la dispersion des séries), décode en code plus
  dispersé (68,1 à 73,9 t/s) mais décode agentique à 55,7 t/s, sans
  conclusion. Cache disque : le 27B reprend tout (98,8 %), Flash-Next
  recalcule ses trois débuts de conversation (93,5 %) et écrit en 103 à
  124 ms ; `--help` identique, aucun réglage changé.
- **0.13.0** (retenue le 12/10/2026) :
  128 lecteurs n-gram pour Flash-Next (#551, annoncé 6 à 7 % de prefill à
  5k-8k et 1 % à 65k), option `--stall-timeout-ms` (#541, sortie en
  `device_lost` quand la génération ne progresse plus, désactivée par défaut,
  non posée), `cache_prompt` sur les routes de complétion brutes (#557).
  Flash-Next seul remesuré sur silentchuck contre la 0.12.0 de la veille, une
  série, mesuré seul, 16/16, pas de boucle. Prefill long à +0,2 à +0,6 %
  (1 599 t/s à 52k), dans la dispersion : le gain de #551 ne se lit pas dans
  nos bancs (les lecteurs sont là, 133 threads contre 37). Décode en code
  70,2 à 71,7 t/s, agentique 53,1 t/s, acceptance 85,7 %. Reprise 99,1 % sans
  raté sur cache disque chaud, aucune écriture. 27B non remesuré.
- **0.14.0** (retenue le 13/10/2026) :
  Flash-Next servi par le nouveau cache par composants (#573 ; le 27B et
  DeepSeek gardent l'ancien), repli `hipMallocManaged` (#460). Flash-Next
  supprime désormais les `*.kvc` des autres modèles dans son dossier et
  ignore `--cache-disk-staging-bytes` : **yaml changé**, dossier
  `GUFO_CACHE/flash-next` pour lui, staging retiré de sa ligne. Flash-Next
  seul remesuré sur silentchuck, une série, 16/16, pas de boucle, aucune
  erreur. Premier token des petites requêtes 154 ms contre 256 ms. Prefill
  à 52k 1 532 t/s : 4 % sous la référence du 12/10, mais les limites de
  puissance du BIOS ont été changées le 13/10, et +0,7 % contre la série
  0.13.0 du même soir. Reprise 93,7 % sur cache disque froid (nouveau
  dossier), 21 points publiés. 27B non remesuré.
- **0.15.0** (retenue le 14/10/2026) : correctif de la régression amont de
  la 0.14.0 (#588, corrigée par #589 : pages du cache de Flash-Next
  épinglées sans compactage de la RAM de l'hôte), noyaux de prefill large
  de Flash-Next (#571). Aucun réglage changé. Flash-Next seul remesuré sur
  silentchuck, une série, 16/16, pas de boucle, aucune erreur. Prefill à 52k
  1 601 t/s (+4,5 % contre la 0.14.0, au niveau de la référence du 12/10),
  décode inchangé (agentique 52,2 t/s), chargement 79 s contre 98 s. Reprise
  99,1 % sur cache disque chaud du nouveau format. 27B non remesuré.
- **0.15.1** (retenue le 15/10/2026) : correctifs du cache de Flash-Next
  (#596 : images gardées dans un préfixe capturé, reprise après annulation,
  points résidents comptés dans l'espacement disque, mémoire des captures
  préparée avant le prefill ; #602 : empreintes sautées sans cache disque,
  sans effet chez nous). Aucun réglage changé. Flash-Next seul remesuré sur
  silentchuck contre la 0.15.0, une série, 16/16, pas de boucle, aucune
  erreur. Banc HTTP au niveau de la 0.15.0 (prefill à 52k 1 603 t/s, décode
  en code 66,9 à 77,1 t/s), décode agentique 50,4 t/s contre 52,2 (une
  série, sans conclusion), chargement 82 s. Reprise 98,5 % sur cache disque
  chaud, aucun point écrit (60 refus `min_step`, comme les 46 de la 0.15.0),
  aucun `persistence_incomplete` : rien de #597 vu. 27B remesuré ensuite,
  une série : 16/16, pas de boucle, décode en code 65,1 à 65,3 t/s (66,4 à
  66,9 en 0.12.0), agentique 42,1 t/s (42,5), acceptance 70,2 % ; prefill
  5 % plus bas (497 t/s à 52k contre 522), non attribuable à gufo : la
  plateforme (12/10 au soir) et les limites de puissance du BIOS (13/10)
  ont changé depuis la 0.12.0, sa dernière mesure.
- **0.17.0** (retenue le 17/10/2026, 0.16.0 sautée) : MTP de Flash-Next
  proposé sur un vocabulaire réduit (#603, logits de la cible identiques),
  surcoût des points de reprise réduit en contexte long (#615), cache
  réutilisé quand `tool_choice` change (#623), attente de publication disque
  bornée par le coût du prefill (#621), sidecar vision préparé au chargement
  et résident (#616 : mmproj de Flash-Next, 904 Mo). Aucun réglage changé,
  `--help` identique à celui de la 0.15.1. Flash-Next seul remesuré sur
  silentchuck contre la 0.15.1, une série, 16/16, pas de boucle, aucune
  erreur. Décode en code 80,7 à 82,0 t/s contre 66,9 à 73,9 (+10 à +20 %),
  agentique 57,0 contre 50,4 t/s (+13 %), acceptance 84,6 % ; passes 2 et 3
  de 21 à 27 % plus courtes. Prefill inchangé (1 599 t/s à 52k). Reprise
  93,5 % sur cache disque froid (aucune restauration disque, 3 ratés
  `no_compatible_boundary`), chargement 92,6 s contre 80,5. 27B non
  remesuré.
- **0.17.1** (retenue le 18/10/2026) : attention moins coûteuse en
  profondeur (#626), contexte répété copié dans les brouillons MTP de
  Flash-Next (#613, prompt lookup), blocages du cache et du premier prompt
  réduits (#633, #636). Aucun réglage changé, `--help` identique à celui de
  la 0.17.0. Flash-Next seul remesuré sur silentchuck contre la 0.17.0, une
  série (banc HTTP rejoué : un client étranger avait faussé le premier),
  16/16, pas de boucle, aucune erreur. Prefill +3 à +4 % de 6,5k à 52k
  (1 667 t/s à 52k contre 1 599), décode en code 93,9 à 96,2 t/s contre
  80,7 à 82,0 (+16 %), agentique 58,1 contre 57,0 t/s, acceptance
  agentique 92,3 % contre 84,6 %. Mêmes 3 ratés `no_compatible_boundary`
  en tête de boucle. 27B non remesuré.
- **0.18.0** (montée le 19/10/2026) : blocages du prompt et du décode de
  Flash-Next réduits (#653, mémoire hôte protégée du compactage), instantanés
  du cache disque hors du cache de pages (#477, #637), état récurrent
  dédoublé (#650, 27B), schémas d'outils non stricts conservés (#643),
  `--reasoning-budget` (#524, non posé). Une option ajoutée dans `--help`,
  aucun réglage changé. Flash-Next seul remesuré sur silentchuck contre la
  0.17.1, une série, 16/16, pas de boucle, aucune erreur. Prefill au niveau
  de la 0.17.1 (1 672 t/s à 52k), décode en code 89,9 à 92,8 t/s (-4 %,
  acceptance 2 points plus basse), prose regroupée à 86 à 90 t/s,
  agentique 56,7 t/s, acceptance agentique 93,5 %. Mêmes 3 ratés
  `no_compatible_boundary`. 27B non remesuré.
- **0.19.0** (montée le 20/10/2026) : petite tête MTP pour les requêtes
  échantillonnées à plusieurs sessions (#655) et brouillons gloutons
  tarifés à l'occupation du décode (#664, Flash-Next), somme des blocs
  q8_1 corrigée (#667), vérification du 27B en wave64 (#660), `/props` au
  format de llama-server (#669). `--help` identique, aucun réglage changé.
  27B et Flash-Next remesurés sur silentchuck, une série chacun, 16/16, pas
  de boucle, aucune erreur, aucun raté de cache. Flash-Next contre la
  0.18.0 : banc HTTP au même niveau (prefill 1 667 t/s à 52k, décode en
  code 89,1 à 93,7 t/s), agentique 59,5 t/s contre 56,7 (+5 %) avec une
  acceptance de 88,4 % contre 93,5 (brouillons tarifés par #664), reprise
  98,6 % sur cache disque chaud, chargement 99 s (115 la veille). 27B contre
  la 0.15.1, sa dernière mesure : décode en code 66,1 à 67,3 t/s (65,1 à
  65,3), prefill à 52k 506 t/s (497), agentique 42,7 t/s (42,1),
  acceptance 70,8 % (70,2), reprise 98,4 %, chargement 43 s. Passes 26,4 /
  26,1 / 21,9 s pour Flash-Next (27,5 / 30,0 / 26,3), 38,7 / 37,9 / 46,7 s
  pour le 27B (43,2 / 37,4 / 40,1). Détail dans `HISTORIQUE-GUFO.md`.
- **0.20.0** (montée le 21/10/2026) : le 27B passe au cache par
  composants, en AR comme en DFlash2 (#540) : il possède son dossier et y
  supprime les fichiers de l'ancien format, et ignore
  `--cache-disk-staging-bytes`. **yaml changé** comme pour Flash-Next en
  0.14.0 : dossier `GUFO_CACHE/qwen3.8-27b`, staging retiré de sa ligne,
  DeepSeek seul dans `GUFO_CACHE`. Aussi #676 (plus de contenu entre appels
  d'outils parallèles), #680, #681, #683, #609. `--help` identique. Les
  trois modèles remesurés sur silentchuck, 16/16 chacun, pas de boucle,
  aucune erreur ; le 27B deux fois. 27B : banc HTTP au niveau de la 0.19.0
  (prefill à 52k 506 t/s, décode en code 67 t/s quand l'acceptance tient),
  mémoire 64 398 Mio contre 82 160 ; première série sur dossier neuf, 3
  ratés `no_compatible_boundary` et reprise 93,7 %, seconde série sur
  disque chaud 98,2 % et aucun raté (98,4 % en 0.19.0), agentique 42,5 à
  44,3 t/s (42,7). Flash-Next au niveau de la 0.19.0 (1 664 t/s à 52k,
  décode en code 95 à 98 t/s, agentique 58,4 t/s contre 59,5, reprise
  98,4 %). DeepSeek, remesuré pour la première fois depuis la 0.2.0 :
  agentique 29,6 t/s contre 27,3, acceptance 87,1 % contre 73,0, reprise
  92,2 % contre 88,9, mais **chargement 172 à 287 s** contre 72 s, à suivre
  (#609 change son chargement). Détail dans `HISTORIQUE-GUFO.md`.
- **0.21.0** (montée le 22/10/2026) : capture du prompt DFlash2 du 27B en
  mémoire épinglée bornée (#688, absente du CHANGELOG : 400 Mio épinglés
  par session dès le chargement, `slot_pinned_bytes`, comptés en plus du
  budget du cache), décode échantillonné de Flash-Next allégé (#699), YaRN
  en option au-delà de 262144 (#350 : `--enable-yarn`, seule option
  ajoutée, refusée à notre `--context 262144`). Aucun réglage changé. Le
  format des instantanés change : la première série part à froid sur
  **les deux** Qwen (3 ratés `no_compatible_boundary` chacun, reprise
  93,3 à 93,5 %), pas seulement sur Flash-Next comme annoncé ; la seconde,
  sur disque chaud, reprend 98,4 % (27B) et 98,8 % (Flash-Next). 27B et
  Flash-Next remesurés deux fois sur silentchuck, 16/16, pas de boucle,
  aucune erreur, aucun client étranger. 27B : prefill +2 % partout (515 t/s
  à 52k contre 505,5, 579 à 580 à 6,5k contre 566), ce qu'annonce #688 ;
  décode, agentique (43,8 à 44,3 t/s) et mémoire (63 871 à 64 020 Mio)
  inchangés. Flash-Next au niveau de la 0.20.0 (1 671 à 1 673 t/s à 52k,
  décode en code 90,5 à 95,0 t/s, agentique 56,8 à 59,2 t/s, acceptance
  89,7 %) : le gain de #699 reste sous le bruit du banc. Détail dans
  `HISTORIQUE-GUFO.md`.
- **0.22.0** (montée le 23/10/2026) : DFlash2 du 27B accéléré (#705,
  absente du CHANGELOG mais dans le tag : recopie depuis l'historique du
  prompt par l'index de Flash-Next, pénalités dans le brouillon, dernier
  niveau du prefill allégé), arène `qfn_mmq` propre à chaque stream HIP
  (#707) et indexeur BF16 sommé dans un ordre fixe (#714) pour Flash-Next,
  RAM libérée avant un checkpoint disque trop gros (#677). `--help`
  identique, aucun réglage changé. Le cache disque du **27B** repart à
  froid (3 ratés `no_compatible_boundary`, reprise 93,5 %), pas celui de
  Flash-Next (98,1 %). 27B (deux séries) et Flash-Next remesurés sur
  silentchuck, 16/16, pas de boucle, aucune erreur, aucun client étranger.
  27B : prefill +1 à 2 % (523 à 524,5 t/s à 52k contre 515, 584 à 586 à
  6,5k contre 580) ; agentique au même niveau (43,0 t/s, acceptance 71,0 %,
  reprise 98,5 % sur disque chaud) : le gain de #705, annoncé sur la
  recopie, ne se voit pas dans notre boucle ; la passe 2 du `refactor`
  part en prose de réflexion dans les deux séries (35,0 et 37,1 t/s contre
  66,7). Flash-Next : banc HTTP au niveau de la 0.21.0, agentique 61,0 t/s
  contre 56,8 (acceptance 89,5 %, reprise 98,1 %), chargement 80 s contre
  93. Détail dans `HISTORIQUE-GUFO.md`.
- **0.23.0** (montée le 24/10/2026) : Flash-Next, boucle du sélecteur
  bornée et coûts mesurés de la petite tête de brouillon en échantillonné
  (#742), petite tête ouverte au greedy seul ou contraint (#733, #739),
  poids lus par `mapped_file` (#734, #738), EmbeddingGemma 2 hors parc
  (#700). La partie sélecteur de #742 ne vaut que sous Clang 23 et plus :
  l'image publiée est en ROCm 7.2.3 / Clang 22 (ROCm 10.1 / Clang 24 =
  build d'évaluation amont sans image, on reste sur l'image publiée).
  `--help` identique, aucun réglage changé. Cache disque de Flash-Next
  invalidé (3 ratés `no_compatible_boundary`, reprise 93,7 %), d'où une
  seconde série : reprise 98,9 %. Flash-Next seul remesuré sur
  silentchuck, 16/16, pas de boucle, aucune erreur, aucun client étranger.
  Banc HTTP au niveau de la 0.22.0 (1 674 à 1 678 t/s à 52k, décode en
  code 93,7 à 97,7 t/s) ; agentique 58,4 puis 58,7 t/s contre 61,0,
  acceptance 89,7 %, dans la dispersion entre séries ; chargement 84 à
  87 s contre 80. Détail dans `HISTORIQUE-GUFO.md`.
- **À vérifier à la prochaine release** : la refonte du cache (reprise après
  crash non exercée ; trois débuts de conversation recalculés par le 27B à
  la série 0.11.0 puis par Flash-Next à la série 0.12.0, pas en 0.13.0, cause
  non établie) ;
  Flash-Next (chargement en 103 s en 0.12.0 et en 0.13.0 contre 86 s en
  0.11.0, y compris mesuré seul ; première requête à 6,5k dispersée, 1 187 à
  1 498 t/s selon la série) ; `--stall-timeout-ms` (#541), à poser ou non ;
  le 27B, non remesuré en 0.13.0 ; le coût de #549 sur la capture des snapshots, non
  lisible dans nos journaux ; les deux défauts du banc vus sur silentchuck
  (`.out` agentique à 0 token, `failed to preload … 404` au lancement,
  toujours là en 0.13.0) ;
  la machine de mesure (0.11.0 à 0.13.0 mesurées sur silentchuck seulement ;
  **plateforme changée le 12/10/2026 au soir**, BIOS 1.11, EC 0.17, VRAM
  1 Gio, `ttm.page_pool_size` : la référence est la série 0.13.0 de 22:19,
  entrée « Plateforme de silentchuck » du journal ; **limites de puissance
  du BIOS changées le 13/10/2026**, valeurs d'avant non relevées : cette
  référence ne vaut plus pour le prefill long, entrée v0.14.0 du journal) ;
  le nouveau cache de Flash-Next depuis la 0.14.0 (cache disque chaud et
  reprise après redémarrage exercés en 0.15.0, reprise après crash non
  exercée ; 27B et DeepSeek non redémarrés depuis la 0.14.0) ;
  l'ordre de `remesure.sh` (les
  écritures lentes de Flash-Next sont apparues juste après le 27B, qui
  remplit et évince le cache disque ; en 0.10.0, Flash-Next mesuré seul
  écrit en 119 à 164 ms, ce qui va dans ce sens sans le prouver : lire les
  `write_ms` de Flash-Next quand il passe en second) ; le
  prefill du 27B (1 à 2 % sous la 0.7.0 en 0.9.0 et en 0.9.1, 0,5 à 1 %
  en 0.10.0) ; la première
  série après une montée, à cache disque froid quatre fois de suite (0.8.1,
  0.9.0, 0.9.1, 0.10.0) ; le décode MTP de Flash-Next après une requête d'image
  (ralentissement signalé en relecture de #470, non mesuré ici) ;
  l'acceptance MTP agentique de Flash-Next (82,0 % à la première série de
  la 0.10.0 contre 84,6 à 85,7 % depuis la 0.5.0, une série, #485 touche le
  rattrapage MTP) ; la fréquence de la boucle de `creation` (une session
  sur 6 en 0.10.0, 1 sur 30 et 2 sur 38 dans le décompte de #388) ; la
  reprise à cache disque chaud, non lisible en 0.10.0 (seconde série
  faussée par la boucle).

## Ce qu'est gufo

- Moteur HIP écrit à la main pour gfx1151, licence MIT. Testé au commit
  `9cad139` (image `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` du 24/09,
  ROCm 7.2.3 embarqué, `gufo diagnose` en PASS sur bigchuck), remesuré au
  commit `d9a84f1` le 26/09/2026, sur la v0.1.1 le 28/09/2026 (27B et
  Flash-Next), la v0.2.0 le 29/09/2026 (27B, Flash-Next et DeepSeek), puis la
  v0.4.0, la v0.5.0, la v0.7.0, la v0.7.1, la v0.8.0, la v0.8.1, la v0.9.0, la v0.9.1, la v0.10.0, la v0.11.0, la v0.12.0, la v0.13.0, la v0.14.0, la v0.15.0, la v0.15.1, la v0.17.0, la v0.17.1, la v0.18.0, la v0.19.0, la v0.20.0, la v0.21.0, la v0.22.0 et la v0.23.0 (Flash-Next seul de la v0.7.1 à la v0.8.1, de la v0.13.0 à la v0.15.0, de la v0.17.0 à la v0.18.0 et en v0.23.0, les deux Qwen de la v0.9.0 à la v0.12.0, en v0.15.1 et en v0.19.0, les trois en v0.20.0, les deux Qwen en v0.21.0 et en v0.22.0, sur silentchuck depuis la v0.11.0 ; « Suivi en amont »). Les deux premières mesures
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
   (mêmes fichiers, gain mesuré), lancé par `./setup-llm.sh --runtime gufo 27b` (`--gufo 27b` jusqu'au 09/10/2026) ; les
   autres modèles du parc ne sont alors plus servis.
2. Gufo en second moteur à côté du service, sur un autre port. Points durs :
   la mémoire partagée (27B gufo environ 45 Gio) et deux points d'entrée.
3. Attendre un routeur ou un aiguillage multi-modèle en amont (rien de suivi à
   ce jour).

## Routeur : basculer entre le 27B et Flash-Next par le client

gufo ne sert qu'un modèle par processus et renvoie à llama-swap
(https://github.com/mostlygeek/llama-swap, MIT) pour exposer plusieurs
processus sous une même URL. Le runtime gufo le fait toujours :
llama-swap (v257, épinglé par SHA-256, dans une image dérivée de celle de gufo,
sans socket docker) écoute sur `:8009` et lance `gufo serve llm` pour le modèle
demandé (lignes de commande dans `runtime/gufo/gufo-llama-swap.yaml`). Le
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
`gufo-llama-swap.yaml` et même démarrage : la voix et la
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
`image_generation` (PNG dans le dossier de travail) et `parler` (lecture par
`pw-play`, voix intégrée ou décrite, cette dernière par VoiceDesign).
Vérifié le 25/09/2026 : `parler` sous pi en 10,6 s pour tout le tour,
`image_generation` (alors nommé `generer_image`) 512² en 20 étapes sous omp en 90 s pour tout le tour (bascule
vers Qwen-Image, puis retour à Flash-Next pour la réponse).

Variante servie : `Qwen-Image-2.1-heretic` (encodeur de texte
« abliterated »), SEULE variante servie depuis le 25/09/2026, sans gain
constaté ni banc de régression ; essai détaillé dans le journal.

## Suivi en amont

Tickets et commentaires publiés sous le compte c4software. Suivi par
`runtime/gufo/tools/gufo-amont.sh` (lecture seule, `gh api`, choix du 28/09/2026) :
releases, images publiées, commits récents, état des tickets du tableau
ci-dessous (ses `| #NNN |` sont la liste suivie) et de ceux que nous avons
ouverts ; `ticket <n> [k]` lit un ticket ou une PR et ses commentaires.
Autorisé dans `.claude/settings.local.json`, pour que l'agent n'improvise
plus de commandes `gh`.

### À surveiller

Tickets ouverts et vivants seulement : un ticket fermé, ou ouvert mais
qui ne bouge plus, sort du tableau, ce qu'il a changé reste dans le journal
et dans « Tickets : synthèse » (#388, fermé le 03/10/2026, a sa synthèse
plus bas ; #200, #228 et #239, ouverts mais immobiles, retirés le
14/10/2026).

| Ticket | Sujet | État au 02/10/2026 |
|---|---|---|
| #299 | PR : Qwen3.6-35B-A3B (`qwen35moe`, GDN + MoE 256 experts, MTP, DFlash 2), par slimsami, ouverte le 27/09 | **suivie à la demande de l'utilisateur** (28/09) : même architecture qu'Ornith-1.5-35B-A3B, notre modèle agentique par défaut (fine-tune de Qwen3.6-35B-A3B). Annoncé sur UD-Q6_K_XL : prefill 1 790 à 2 702 t/s contre 1 057 à 1 202 pour llama.cpp Vulkan, DFlash 2 à 83,3 t/s en glouton ; MTP pas encore branché dans `gufo serve`. À vérifier si elle est mergée : notre Ornith est en Q4_K_M (la PR ne cite que Q6_K et Q8_0 pour les experts), et gufo refuse les quants hors de ses formats ; le 30/09, **mise en attente par le mainteneur** : pas de nouveau modèle ni de nouvelle quant avant un produit stable avec les modèles actuels ; le 17/10, web2bruno annonce le MTP servi pour le 35B sur son fork (UD-Q8_K_XL, `-d 1`, prefill 2 280 t/s et décode 50 t/s à 16k) et demande des retours de test, sans objet ici ; le 19/10, rebasée sur la 0.17.1 avec ces commits MTP, toujours ouverte |
| #524 | PR : budget de réflexion (`thinking.budget_tokens`) sur `/v1/messages`, par jabata, mergée le 18/10 (0.18.0) | **suivie à la demande de l'utilisateur** (20/10), bien que fermée : aucun ticket ouvert ne porte la suite qu'elle annonce, le budget par requête sur Chat Completions et Responses (pour l'instant, seule l'option serveur `--reasoning-budget` vaut pour ces deux API). C'est elle qu'attend llm-proxy, qui traduit `/v1/messages` en `/v1/chat/completions` et jette `thinking` : il pourra alors traduire `budget_tokens`. Ligne à remplacer par le ticket ou la PR de cette suite dès qu'il existe |

Constat du 29/09/2026 (v0.2.0), non revu depuis : rien n'est suivi en amont
sur d'autres quants (notre `IQ4_NL`), plusieurs modèles par serveur (« HTTP
model replacement not implemented »), un budget de raisonnement.

### Tickets : synthèse

Historique complet dans le journal.

- **#259 et #267, cache entre conversations** : #259 (le nôtre) fermé le
  07/10/2026 par #473, #267 fermé le 03/10/2026 par #386. Le 24/09/2026,
  ticket ouvert puis corrigé par nos soins (en grande partie une
  configuration) ; #279 (26/09) rend le staging automatique mais plafonné à
  1 Gio, insuffisant chez nous ; le 30/09 le mainteneur confirme les quatre
  points ; le 03/10/2026, trois sont corrigés : #369 (déjà dans la 0.5.0) et
  #386 (dans la 0.7.0). Le quatrième l'est par #473, mergée le 07/10/2026
  à 14:58 UTC, donc après la 0.9.0 et pas dedans : le plafond fixe de 1 Gio
  du staging automatique disparaît, il reste le huitième de la RAM
  disponible et le budget disque. D'après la PR, rien ne change pour
  Flash-Next à 262144 de contexte (le huitième de la RAM y borne déjà) et
  le conseil de poser 8 Gio à la main y est maintenu. Livrée en 0.9.1 et
  confrontée le 08/10/2026 : défaut résolu à 10,6 Gio sur le 27B (aucun
  refus sur une série agentique), environ 2 Gio estimés pour Flash-Next ;
  notre staging de 8 Gio reste.
- **#239, n-gram** : ouvert, deux commentaires de notre part le 24/09/2026,
  conception à pool persistant à suivre à part. Résultat négatif en
  glouton, puis jugé « worth experimenting » par le mainteneur (25/09) ;
  porte le pool persistant de #263 depuis le 28/09. Le 05/10/2026, un tiers
  mesure sur llama.cpp une cascade n-gram CPU puis MTP avec de vrais
  transcripts d'agent : n-gram seul au niveau du sans-spéculation (27,1 %
  d'acceptance), cascade 10 à 20 % plus lente que le MTP seul (pool
  persistant non mesuré). Retiré du tableau le 14/10/2026, immobile.
- **#228, ROCm 10** : verdict gufo, rester sur ROCm 7.2.3 (décode -5 % en
  ROCm 10) ; baisse attribuée le 06/10/2026 à clang 23 et non aux
  bibliothèques ROCm 10, PR #459 mergée le 07/10/2026 et livrée en 0.9.1
  (image toujours en clang 22) ; clang 23 change le texte glouton de
  Flash-Next, portes de qualité à repasser avant d'y passer. Ouvert,
  retiré du tableau le 14/10/2026, immobile.
- **#200, runtime HRX + noyaux Loom** : ouvert depuis août, +3,6 % de
  prefill 27B ; dernier commentaire le 29/08/2026, retiré du tableau le
  14/10/2026.
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
| v0.7.0 (`aedc129`) | 04/10/2026 | retenue | pas de régression, 16/16 ; préfixe partagé appris en RAM sans `--cache-disk` (#386, ferme #267 : reprise sans disque de 90 à 91,8 %, cache disque gardé) ; décode agentique de Flash-Next 48,1 t/s ; `--cache-ram-bytes` explicite au-delà du budget automatique (#384) ; métriques au format llama.cpp et `/slots` (#389, #403) ; aucun réglage changé |
| v0.7.1 (`96a4647`) | 05/10/2026 | retenue | Flash-Next seul remesuré, 16/16, pas de régression : prefill long +4 à +6 % (#421), décode agentique 50,7 t/s, 31,8 s par passe ; 27B non remesuré ; baisse du prefill court au banc HTTP due à des écritures lentes du cache disque, présente aussi en 0.7.0 ; aucun réglage changé |
| v0.8.0 (`e03bb91`) | 05/10/2026 | retenue | `/v1/responses` compatible avec les clients OpenAI comme Codex (#434), seul changement ; Flash-Next seul remesuré, 16/16, au niveau de la 0.7.1 (reprise à 98,7 % due au cache disque déjà peuplé par la série du matin) ; 27B non remesuré depuis la 0.7.0 ; aucun réglage changé |
| v0.8.1 (`543300e`) | 06/10/2026 | retenue | appels d'outils gardés en syntaxe native, sans enveloppe JSON, et appel reconnu sans `</think>` fermé (#441), lignes vides de tête retirées (#446), historiques d'images (#447) ; Flash-Next seul remesuré, deux séries, 16/16, débits au niveau de la 0.8.0 ; reprise à 91,2 % à la première série (points de reprise disque de la 0.8.0 inutilisables, préfixe changé) puis 98,4 % ; une boucle de vérification sur `creation` à la seconde (88,7 s, PASS, forme de #388) ; 27B non remesuré depuis la 0.7.0 ; aucun réglage changé |
| v0.9.0 (`2e35aaf`) | 07/10/2026 | retenue | points de reprise du prompt de Flash-Next sans copie de l'état complet (#445), prefill à long contexte (#463), points de branchement appris gardés sous pression RAM (#466), pages CMA libres hors du budget RAM (sans effet ici, `CmaTotal` 0), messages système en cours de conversation remontés en tête pour Qwen (#449), `--trace` (#458, non posée), `--max-pending-per-client` au défaut de `--max-pending` (#467, 16 au lieu de 4) ; Flash-Next seul remesuré, deux séries, 16/16, débits au niveau de la 0.8.1, mémoire 107 Gio au lieu de 111 ; reprise à 93,1 % à la première série (une seule reprise disque, trois débuts de conversation recalculés) puis 98,6 % ; 27B remesuré (une série), 16/16, boucle agentique au niveau de la 0.7.0, prefill 1 à 2 % plus bas ; aucun réglage changé |
| v0.9.1 (`dea22ce`) | 08/10/2026 | retenue | prefill de Flash-Next par blocs de 4 096 tokens (#470), noyaux de prefill du 27B et de Flash-Next sans spill sous clang 23 (#459, image toujours en clang 22), staging automatique sans plafond de 1 Gio (#473) ; 27B (une série) et Flash-Next (deux séries) remesurés, 16/16 ; prefill long de Flash-Next à +4 % (1 481 t/s à 52k), mémoire et threads inchangés, 27B au niveau de la 0.9.0 ; reprise de Flash-Next à 91,5 % à la première série (cache disque froid) puis 99,2 % ; écritures du cache disque de Flash-Next à 2,3 à 3,2 s à la première série (115 à 127 ms en 0.9.0), non reproduites à l'essai croisé 0.9.0 / 0.9.1 du même jour (94 à 155 ms dans les deux versions), donc pas la version ; staging au défaut essayé sur le 27B (10,6 Gio, aucun refus), 8 Gio gardés ; aucun réglage changé |
| v0.10.0 (`3020d24`) | 09/10/2026 | retenue | prefill et rattrapage MTP de Flash-Next (#485), outils et streaming sur `/v1/messages` (#469, non essayé), tuiles IQ2 de DeepSeek pour les lots de 2 à 31 tokens (#482, non mesuré), RFC d'une refonte du cache de continuation (#488, #489, documentation seule) ; Flash-Next remesuré, deux séries ; prefill long à +5 à +7 % (1 583 t/s à 52k), décode, mémoire et threads inchangés ; 16/16 puis 15/16 : boucle d'appels d'outils sur `creation` à la seconde série (garde-temps de 300 s, 150 appels, forme de #388, pas de ticket), retenue par l'utilisateur ; reprise à 93,6 % à la première série (cache disque froid), seconde non comparable ; acceptance agentique à 82,0 % à la première série, à relire ; écritures du cache disque en 119 à 164 ms ; 27B remesuré après la décision (une série), 16/16, sans boucle, au niveau de la 0.9.1 ; `--help` identique, aucun réglage changé |
| v0.11.0 (`e3c0d4c`) | 10/10/2026 | retenue | première livraison de la refonte du cache de continuation (#493 à #517 : index de préfixes, baux de slots, manifestes disque, publication avec reprise après crash, éviction), frontière vivante à la restauration d'un point de reprise emprunté (#476), noyaux de décodage de Flash-Next (#518), images dans les résultats d'outils (#506, non essayé) ; **mesurée sur silentchuck**, contre les séries 0.10.0 du 09/10 au soir sur cette machine, une série par modèle, 16/16 sur les deux, pas de boucle ; Flash-Next : décode à +6 à +8 % (71,5 à 72,5 t/s en code, 52,7 t/s en agentique), prefill long à +1,4 à +2,7 % (1 606 t/s à 52k, dans la dispersion), acceptance agentique 84,6 %, reprise 98,6 % sur cache disque chaud ; 27B au niveau de la 0.10.0, reprise 93,5 % avec trois débuts de conversation recalculés (cause non établie) ; cache disque de la 0.10.0 relu sans rejet, écriture au nouveau format exercée par le 27B seul (3 points en 231 à 236 ms), reprise après crash non exercée ; `.out` agentique à 0 token et `failed to preload … 404` sur silentchuck, dans les deux versions ; `--help` identique, aucun réglage changé |
| v0.12.0 (`88090af`) | 11/10/2026 | retenue | snapshots de Flash-Next gardés dans la marge du device (#549, ferme #487 : `generation_failed` puis segfault quand la GTT est pleine), arguments des appels d'outils natifs diffusés au fil de l'eau (#534), adaptateur de continuation de Flash-Next livré inactif (#536), images et `count_tokens` sur `/v1/messages` (#510, #512, non essayés), `input_tokens` de Messages sans les lectures de cache (#530) ; mesurée sur silentchuck contre la 0.11.0, une série, 27B puis Flash-Next, 16/16 sur les deux, pas de boucle ; 27B identique ; Flash-Next : prefill long 1 à 2 % plus bas (1 589 t/s à 52k, dans la dispersion), décode en code 68,1 à 73,9 t/s et décode agentique 55,7 t/s (sans conclusion), acceptance 85,7 %, reprise 93,5 % avec trois débuts de conversation recalculés (cause non établie), 3 points écrits en 103 à 124 ms ; 27B repris à 98,8 % ; coût de #549 et gain de #534 non mesurés par nos bancs ; `--help` identique, aucun réglage changé |
| v0.13.0 (`fcf8bf7`) | 12/10/2026 | retenue | 128 lecteurs n-gram pour Flash-Next (#551), `--stall-timeout-ms` (#541, sortie en `device_lost` sans progression, désactivée par défaut, non posée), `cache_prompt` sur `/v1/completions` et `/completion` (#557), `stream` booléen ou `null` (#544) ; Flash-Next seul remesuré sur silentchuck contre la 0.12.0, une série, mesuré seul, 16/16, pas de boucle ; prefill long à +0,2 à +0,6 % (1 599 t/s à 52k, dans la dispersion : gain de #551 non lisible dans nos bancs, 133 threads contre 37), décode en code 70,2 à 71,7 t/s, agentique 53,1 t/s, acceptance 85,7 %, reprise 99,1 % sans raté sur cache disque chaud, aucune écriture disque ; 27B non remesuré ; `--help` : une option ajoutée, aucun réglage changé |
| v0.14.0 (`6cdc73c`) | 13/10/2026 | retenue | Flash-Next servi par le nouveau cache par composants (#573 : sélection entre slots, RAM et disque, pages épinglées à la demande, dossier `--cache-disk` possédé par un seul serveur qui y supprime les `*.kvc` de l'ancien format, `--cache-disk-staging-bytes` ignoré), repli `hipMallocManaged` (#460) ; **yaml changé** : dossier `GUFO_CACHE/flash-next` pour Flash-Next, staging retiré de sa ligne ; Flash-Next seul remesuré sur silentchuck, une série, 16/16, pas de boucle, aucune erreur ; premier token des petites requêtes 154 ms contre 256 ms ; prefill à 52k 1 532 t/s, 4 % sous la référence du 12/10 mais limites de puissance du BIOS changées le 13/10, +0,7 % contre la série 0.13.0 du même soir ; décode en code 71,7 à 72,7 t/s, agentique 51,7 t/s, acceptance 85,7 % ; reprise 93,7 % sur cache disque froid, 21 points publiés ; 27B non remesuré ; `--help` : aucune option ajoutée ni retirée |
| v0.15.0 (`89d6185`) | 14/10/2026 | retenue | correctif de #588 (#589 : pages du cache de Flash-Next épinglées sans compactage de la RAM de l'hôte), noyaux de prefill large de Flash-Next (#571, logits identiques) ; Flash-Next seul remesuré sur silentchuck contre la 0.14.0, une série, 16/16, pas de boucle, aucune erreur ; prefill à 52k 1 601 t/s (+4,5 %, au niveau de la référence du 12/10), décode inchangé (code 71,0 à 72,9 t/s, agentique 52,2 t/s ; les -4 % vus en amont ne se voient pas), chargement 79 s contre 98 s ; reprise 99,1 % sur cache disque chaud du nouveau format, relu après la montée ; passes 0,5 à 2,9 s plus longues, réponses plus longues (+9,8 % de tokens) ; `--help` : une description changée, aucun réglage changé |
| v0.15.1 (`f711612`) | 15/10/2026 | retenue | correctifs du cache de Flash-Next : #596 (images gardées dans un préfixe capturé, reprise sans prefill d'une requête relancée après annulation, points encore en RAM comptés dans l'espacement disque, mémoire des captures préparée avant le prefill ; 48/48 suites fonctionnelles en amont, capture C1 de 16–18 à ~25 ms) et #602 (empreintes des poids sautées sans cache disque, sans effet chez nous qui gardons `--cache-disk`) ; Flash-Next seul remesuré sur silentchuck contre la 0.15.0, une série, 16/16, pas de boucle, aucune erreur ; banc HTTP au niveau de la 0.15.0 (prefill à 52k 1 603 t/s contre 1 601, décode en code 66,9 à 77,1 t/s contre 71,0 à 75,2), décode agentique 50,4 t/s contre 52,2 (une série, sans conclusion), acceptance 85,7 %, chargement 82 s ; reprise 98,5 % sur cache disque chaud (7 restaurations disque), aucun point écrit, 60 refus `min_step`, aucun `persistence_incomplete` (rien de #597, ouvert, vu) ; #598 (décode et chargement en retrait sur la 0.13.0 chez un utilisateur) non reproduit ; 27B remesuré ensuite contre la 0.12.0, sa dernière mesure, une série : 16/16, pas de boucle, décode en code 65,1 à 65,3 t/s contre 66,4 à 66,9, agentique 42,1 t/s contre 42,5, acceptance 70,2 %, reprise 93,6 % sur cache disque froid, prefill 5 % plus bas (497 t/s à 52k contre 522, 556 contre 586 à 6,5k), confondu avec les changements de plateforme du 12/10 et de limites de puissance du 13/10, postérieurs à la 0.12.0 ; `--help` non comparé ; aucun réglage changé |
| v0.17.0 (`2af314b`) | 17/10/2026 | retenue | 0.16.0 sautée ; MTP de Flash-Next proposé sur un vocabulaire réduit (#603 : logits de la cible identiques, texte échantillonné pouvant différer), surcoût des points de reprise réduit en contexte long (#615), `/health` en 503 pendant le chargement (#610, sans effet : llama-swap attend un 200), cache réutilisé quand `tool_choice` change (#623), attente de publication disque bornée par le coût du prefill (#621), éviction disque après récupération des orphelins (#625), attention creuse compactée (#622), sidecar vision préparé au chargement et résident (#616 : `event=vision_prepared`, 904 Mo pour le mmproj de Flash-Next, budget RAM du cache 14,32 Go contre 14,42) ; `--help` identique à celui de la 0.15.1 ; Flash-Next seul remesuré sur silentchuck contre la 0.15.1, une série, 16/16, pas de boucle, aucune erreur ; décode en code 80,7 à 82,0 t/s contre 66,9 à 73,9, agentique 57,0 t/s contre 50,4, acceptance 84,6 %, passes 31,1 / 24,5 / 22,7 s contre 27,7 / 31,0 / 31,2 ; prefill inchangé (1 599 t/s à 52k contre 1 603) ; reprise 93,5 % sur cache disque froid (aucune restauration disque, 3 ratés `no_compatible_boundary` en tête de boucle, cause non établie), chargement 92,6 s contre 80,5 ; 27B et DeepSeek non remesurés ; aucun réglage changé |
| v0.17.1 (`a8ed7af`) | 18/10/2026 | retenue | attention moins coûteuse en profondeur (#626, annoncé AR pp128K +2,5 %), contexte répété copié dans les brouillons MTP de Flash-Next (#613, prompt lookup : 3 requêtes agentiques sur 53 l'utilisent), blocages du cache et du premier prompt réduits (#633), tentatives refusées sur capacité avant lecture (#636) ; `--help` identique à celui de la 0.17.0 ; Flash-Next seul remesuré sur silentchuck contre la 0.17.0, une série, 16/16, pas de boucle, aucune erreur ; banc HTTP rejoué (cinq requêtes d'un client étranger sur `:8009` pendant le premier) ; prefill +3 à +4 % de 6,5k à 52k (1 667 t/s à 52k contre 1 599), décode en code 93,9 à 96,2 t/s contre 80,7 à 82,0, prose dispersée suivant l'acceptance (58 à 92 t/s), agentique 58,1 t/s contre 57,0, acceptance 92,3 % contre 84,6 %, passes 31,5 / 23,4 / 27,9 s ; reprise 93,3 % sur cache disque froid, mêmes 3 ratés `no_compatible_boundary` ; chargement 105,8 s ; 27B et DeepSeek non remesurés ; aucun réglage changé |
| v0.18.0 (`6c682a2`) | 19/10/2026 | montée | blocages du prompt et du décode de Flash-Next réduits (#653 : pages hôte protégées du compactage, patch ROCr requalifié), instantanés du cache disque hors du cache de pages (#477), cache de pages récupérable compté dans le cgroup (#637), état récurrent dédoublé (#650, 27B), schémas d'outils non stricts conservés sur Chat et Responses (#643), `--reasoning-budget` (#524, non posé), vocabulaire des sorties structurées préparé au chargement (#638, 26,4 ms) ; `--help` : une option ajoutée ; Flash-Next seul remesuré sur silentchuck contre la 0.17.1, une série, 16/16, pas de boucle, aucune erreur, aucun client étranger ; prefill au niveau de la 0.17.1 (1 672 t/s à 52k), décode en code 89,9 à 92,8 t/s contre 93,9 à 96,2 (acceptance 2 points plus basse), prose 86 à 90 t/s, agentique 56,7 t/s contre 58,1, acceptance 93,5 % contre 92,3 %, passes 27,5 / 30,0 / 26,3 s ; reprise 93,8 % sur cache disque froid, mêmes 3 ratés `no_compatible_boundary` ; chargement 94,8 s ; 27B et DeepSeek non remesurés ; aucun réglage changé |
| v0.19.0 (`7b27845`) | 20/10/2026 | montée | petite tête MTP pour les requêtes échantillonnées à plusieurs sessions (#655) et brouillons gloutons tarifés à l'occupation du décode (#664, Flash-Next), somme des blocs q8_1 corrigée (#667), vérification du 27B en wave64 (#660), `/props` au format de llama-server (#669) ; `--help` identique ; 27B et Flash-Next remesurés sur silentchuck, une série chacun, 16/16, pas de boucle, aucune erreur, aucun raté de cache ; Flash-Next contre la 0.18.0 : banc HTTP au même niveau (1 667 t/s à 52k, décode en code 89,1 à 93,7 t/s), agentique 59,5 t/s contre 56,7, acceptance 88,4 % contre 93,5 %, passes 26,4 / 26,1 / 21,9 s, reprise 98,6 % sur cache disque chaud, chargement 99 s ; 27B contre la 0.15.1 : décode en code 66,1 à 67,3 t/s contre 65,1 à 65,3, prefill à 52k 506 t/s contre 497, agentique 42,7 t/s contre 42,1, acceptance 70,8 % contre 70,2 %, reprise 98,4 %, chargement 43 s ; DeepSeek non remesuré ; aucun réglage changé |
| v0.20.0 (`0c03748`) | 21/10/2026 | montée | cache par composants pour le 27B en AR et DFlash2 (#540 : dossier possédé, staging ignoré, **yaml changé** : `GUFO_CACHE/qwen3.8-27b`, staging retiré de sa ligne), #676, cache sans réinitialisations répétées (#680), petites projections F16/BF16 de Flash-Next (#681), lignes n-gram préchargées (#683), chargement de DeepSeek au-delà du pool (#609) ; `--help` identique ; les trois modèles remesurés sur silentchuck, 16/16, pas de boucle, aucune erreur, le 27B deux fois ; 27B contre la 0.19.0 : prefill à 52k 506 t/s (505,5), décode en code 67,1 à 67,4 t/s quand l'acceptance tient (66,1 à 67,3), mémoire 64 398 Mio contre 82 160, agentique 44,3 puis 42,5 t/s (42,7), acceptance 70,0 puis 72,1 %, reprise 93,7 % sur dossier neuf (3 ratés `no_compatible_boundary`) puis 98,2 % sur disque chaud (aucun raté) ; Flash-Next contre la 0.19.0 : prefill à 52k 1 664 t/s (1 667), décode en code 95,1 et 97,8 t/s (une passe à 55,9 en prose de raisonnement), agentique 58,4 t/s (59,5), acceptance 88,0 %, reprise 98,4 %, chargement 102 à 158 s (97 à 123) ; DeepSeek contre la 0.2.0 : agentique 29,6 t/s (27,3), acceptance 87,1 % (73,0), reprise 92,2 % (88,9), premier token 696 ms (574), chargement 172 à 287 s (72) ; aucun autre réglage changé |
| v0.21.0 (`7110c79`) | 22/10/2026 | montée | capture du prompt DFlash2 du 27B en mémoire épinglée bornée (#688, absente du CHANGELOG : 400 Mio épinglés par session au chargement, comptés en plus du budget du cache), décode échantillonné de Flash-Next allégé (#699), YaRN en option au-delà de 262144 (#350) ; `--help` : `--enable-yarn` ajoutée, sans objet à notre `--context 262144` ; format des instantanés changé, première série à froid sur les deux Qwen (3 ratés `no_compatible_boundary`, reprise 93,5 et 93,3 %) ; 27B et Flash-Next remesurés deux fois sur silentchuck, 16/16, pas de boucle, aucune erreur ; 27B contre la 0.20.0 : prefill à 52k 515 t/s (505,5), à 6,5k 579 à 580 (566), décode en code 60,8 à 67,7 t/s, mémoire 63 871 à 64 020 Mio (64 398), agentique 44,3 puis 43,8 t/s (42,5), acceptance 72,1 puis 70,0 %, reprise 98,4 % sur disque chaud (98,2) ; Flash-Next contre la 0.20.0 : prefill à 52k 1 671 à 1 673 t/s (1 664), décode en code 90,5 à 95,0 t/s (95,1 et 97,8), agentique 59,2 puis 56,8 t/s (58,4), acceptance 89,7 % (88,0), reprise 98,8 % sur disque chaud (98,4), chargement 93 à 97 s (102) ; DeepSeek non remesuré ; aucun réglage changé |
| v0.22.0 (`7b1bf04`) | 23/10/2026 | montée | DFlash2 du 27B accéléré (#705, absente du CHANGELOG : recopie depuis l'historique du prompt, pénalités dans le brouillon, dernier niveau du prefill allégé), arène `qfn_mmq` par stream HIP (#707) et indexeur BF16 en ordre fixe (#714) pour Flash-Next, brouillons MTP échantillonnés tarifés à l'occupation (#703), RAM libérée avant un checkpoint disque trop gros (#677), « leaves » du portage Windows (#711, #713, #729, sans effet sous Linux) ; `--help` identique ; cache disque du 27B invalidé (3 ratés `no_compatible_boundary`, reprise 93,5 %), pas celui de Flash-Next ; 27B remesuré deux fois et Flash-Next une fois sur silentchuck, 16/16, pas de boucle, aucune erreur ; 27B contre la 0.21.0 : prefill à 52k 523 à 524,5 t/s (515), à 6,5k 584 à 586 (580), décode en code 67,6 à 68,7 t/s mais 35,0 et 37,1 sur la passe 2 (prose de réflexion, deux séries), mémoire 63 958 à 64 068 Mio (63 871), agentique 43,2 puis 43,0 t/s (43,8), acceptance 71,0 % (70,0), reprise 98,5 % sur disque chaud (98,4) ; Flash-Next contre la 0.21.0 : prefill à 52k 1 668 t/s (1 671), décode en code 92,4 à 96,0 t/s (92,4 à 95,0), agentique 61,0 t/s (56,8), acceptance 89,5 % (89,7), reprise 98,1 % (98,8), chargement 80 s (93) ; DeepSeek non remesuré ; aucun réglage changé |
| v0.23.0 (`1fafd5a`) | 24/10/2026 | montée | Flash-Next : boucle du sélecteur bornée (#742, Clang 23 et plus seulement, sans effet sur l'image publiée en ROCm 7.2.3 / Clang 22) et coûts mesurés de la petite tête de brouillon en échantillonné (#742), petite tête ouverte au greedy seul ou contraint (#733, #739) ; poids et shards lus par `mapped_file` (#734, #738) ; EmbeddingGemma 2 sur `/v1/embeddings` (#700, #751, hors parc) ; `--help` identique ; cache disque de Flash-Next invalidé (3 ratés `no_compatible_boundary`, reprise 93,7 %) ; Flash-Next remesuré deux fois sur silentchuck, 16/16, pas de boucle, aucune erreur ; contre la 0.22.0 : prefill à 52k 1 674 à 1 678 t/s (1 668), décode en code 93,7 à 97,7 t/s (92,4 à 96,0), agentique 58,4 puis 58,7 t/s (61,0), acceptance 89,7 % (89,5), reprise 98,9 % sur disque chaud (98,1), chargement 84 à 87 s (80) ; 27B et DeepSeek non remesurés ; aucun réglage changé |

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
| 0.10.0, presence 1,5 (remesure du 09/10, après la fermeture du ticket) | 1 sur 2 |

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
bancs sont versionnés dans [`runtime/gufo/`](../runtime/gufo/README.md). Les
données restent hors du dépôt et hors de `~/models`, dans `GUFO_DATA`
(défaut `~/llm/gufo-test` sur bigchuck, déjà peuplé), sauf les poids propres
à gufo, rangés avec le parc dans `~/models/gufo` depuis le 09/10/2026 :

- `./setup-llm.sh --runtime gufo [flashnext|27b|deepseek]` (bascule
  mémorisée ; `LLM_RUNTIME=gufo ./setup-llm.sh --start [modèle]` pour un essai
  sans rien mémoriser ; `--gufo [modèle]` jusqu'au 09/10/2026) : gufo, toujours derrière
  llama-swap (section « Routeur » ci-dessus), à la place du service sur
  `:8009`, l'argument choisissant le modèle préchargé (compose
  `runtime/gufo/docker-compose.yml`, `.env` généré dans
  `GUFO_DATA`, 2 sessions par défaut, `GUFO_SESSIONS=N` pour changer, nom
  exposé `qwen3.8-27b` ou `qwen3.8-flash-next`, cache disque 16 Gio, staging
  8 Gio pour DeepSeek, utilisateur de l'hôte). `--runtime llama-cpp-rocm-strix` pour revenir
  au service (`--gufo-off`), `--restart [modèle]` pour changer de modèle
  préchargé ou le garder, `--requetes` pour suivre les requêtes
  (`--gufo-logs`). Le dernier lancé repart seul au
  démarrage de bigchuck ; démarrer un runtime arrête l'autre (plus de refus).
- `LLM_RUNTIME=gufo ./setup-llm.sh --setup image|27b|flashnext|deepseek|all`
  (`--gufo-download` jusqu'au 09/10/2026 ; `runtime/gufo/download.sh`) : le
  27B et son drafter, la tête MTP et le mmproj de Flash-Next, partagés avec
  le service, aux mêmes chemins du parc et sans révision épinglée ; et image et GGUF de référence aux révisions
  épinglées par gufo (Flash-Next UD-Q4_K_XL unsloth `38bb39e`, 104 Go ;
  DeepSeek IQ2XXS antirez `1cd7b56`, 87 Go, et DSpark `e7f0403`, 6 Go ;
  le drafter DFlash 2 Q4_K_M `2d9571f`, 1,1 Go, téléchargé pour la
  comparaison au Q8_0, mesuré identique et supprimé le 25/09/2026). Présents
  sur bigchuck (191 Go dans `~/models/gufo`, `GUFO_DATA/models` avant le
  09/10/2026).
- `runtime/gufo/bench/run.sh gufo|llama <cas>...` : banc HTTP
  (`bench/mesure.py`). Cas gufo : `27b`, `flashnext`, `deepseek` ; cas service : `27b`, `flashnext`, `flashnext-large-ub`,
  `deepseek`.
- `runtime/gufo/bench/agentic.sh gufo|llama <cas>...` : boucle pi de
  `bench-agentic/`, `PASSES=3`, garde-temps d'une heure.
- Les deux bancs lancent gufo par le point d'entrée
  (`LLM_RUNTIME=gufo … --start <cas>`) sur le même port, en 1 session,
  sans redémarrage automatique, projet et `.env` séparés ; ils arrêtent le
  runtime d'usage réel au départ (gufo ou le service) et le relancent à la
  fin s'il tournait.
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
Dernière confrontation à la documentation amont : 24/10/2026, v0.23.0 (diff
de documentation depuis la v0.22.0 et `--help` des deux images comparés sur
silentchuck) : `--help` identique, aucun changement de sens pour `serve
llm` (seul ajout, la sous-commande `serve embedding`, hors parc) ; en
v0.22.0 (23/10/2026) : `--help` identique, un seul changement de sens, `detail`
des images accepté en `low`, `high` et `original`, tous traités comme
`auto` (#722) ; GGUF servis vérifiés contre les identités publiées par
gufo (`artifacts/model-identities.json`, sha256 du 27B UD-Q4_K_XL
republié le 19/08/2026 conforme sur silentchuck) : seul écart, le drafter
DFlash2 en Q8_0 au lieu du Q4_K_M conseillé, déjà connu ; en v0.21.0
(22/10/2026) : une option ajoutée, `--enable-yarn` (#350, YaRN statique de
Flash-Next, exigée au-delà de 262144 et refusée en deçà, donc sans objet
pour notre `--context 262144`), aucun défaut changé ; en v0.20.0
(21/10/2026) : `--help` identique, mais le sens de deux options change
pour le 27B comme pour Flash-Next en 0.14.0 (#540 : `--cache-disk` possédé
par un seul serveur, qui y supprime les fichiers de l'ancien format ;
`--cache-disk-staging-bytes` ignoré), d'où le dossier
`GUFO_CACHE/qwen3.8-27b` et le staging retiré de sa ligne ; en v0.19.0
(20/10/2026) : `--help` identique, un seul changement de sens, `/props`
qui décrit le serveur au format de llama-server au lieu d'un
emplacement vide (#669) ; en v0.18.0 (19/10/2026) : une option ajoutée, `--reasoning-budget` (#524, défaut -1
illimité, non posée : le raisonnement se règle par le client), aucune
retirée, aucun défaut changé ; un changement de sens, les schémas d'outils
sans `strict` conservés tels quels sur Responses (#643) ; en v0.17.1
(18/10/2026), `--help` identique, aucun changement de sens (deux métriques
de prompt lookup ajoutées à `/metrics`) ; en v0.17.0 (17/10/2026), un seul changement de sens, le sidecar
vision (`--mmproj` de Flash-Next) préparé au chargement et gardé résident
même sans image (#616) ; en v0.14.0 (13/10/2026),
aucune option ajoutée ni retirée, mais le sens de trois options change pour
Flash-Next (#573 : `--cache-disk` possédé par un seul serveur, qui y supprime
les fichiers de l'ancien format ; `--cache-disk-staging-bytes` ignoré ;
`--cache-ram-bytes` engagé par pas d'environ 1 Gio), d'où le dossier
`GUFO_CACHE/flash-next` et le staging retiré de sa ligne ; en v0.13.0, une
option ajoutée, `--stall-timeout-ms` (#541 : sortie en `device_lost`
quand la génération ne progresse plus pendant ce délai, 0 par défaut donc
désactivée, minimum 60000 ; non posée), aucune retirée, aucun défaut changé ;
`--help` de la 0.12.0 identique à celui de la 0.11.0 et de la 0.10.0, lui-même identique
à celui de la 0.9.1 (la refonte du cache n'apporte aucune option) ; en v0.9.1, un
défaut changé, celui de `--cache-disk-staging-bytes` (plus petit du huitième
de la RAM disponible et du budget disque, sans plafond de 1 Gio ; nos 8 Gio
gardés), aucune option ajoutée ni retirée ; en v0.9.0, une
option ajoutée, `--trace` (non posée : le fichier garde les conversations
entières), un défaut changé, `--max-pending-per-client` (valeur de
`--max-pending`, 16, au lieu de 4 ; non posée), premiers écarts depuis la
0.5.0 ;
`--cache-ram-bytes` explicite peut dépasser le budget automatique (non posée) ;
`--cache-disk` n'est plus le seul chemin de reprise d'un préfixe commun
(#386), gardé après la remesure. Les
confrontations datées (26/09, v0.1.1, v0.2.0, v0.4.0, v0.5.0, v0.7.0, v0.7.1, v0.8.0, v0.8.1, v0.9.0, v0.9.1, v0.10.0, v0.11.0, v0.12.0, v0.13.0, v0.14.0, v0.15.0, v0.17.0, v0.17.1) sont dans le
journal, à l'entrée de chaque version ; chaque montée de version y ajoute la
sienne et met cette ligne à jour.

| Paramètre | `runtime/gufo/gufo-llama-swap.yaml` | Défaut de gufo | Exemples gufo (guides des modèles) | Origine |
|---|---|---|---|---|
| `--context` | 262144 | contexte natif depuis d5fd781 (4096 avant) | 32768 | nous : contexte natif, celui du service ; redondant depuis d5fd781 (chargement : `context_tokens=262144`), gardé explicite parce que `capabilities.context` doit lui rester égal |
| `--sessions` | 2 | 1 | 2 | gufo (guides du 27B et de Flash-Next) et notre mesure (7 Gio, plus d'éviction par les requêtes annexes) |
| `--max-tokens` | non posé (-1, jusqu'à EOS) | -1 depuis #276 (128 avant) | non indiqué | gufo, comme le service (llama.cpp à -1, aucun `n-predict` dans le ini) ; 32768 explicite jusqu'au 26/09/2026, quand le défaut de 128 coupait un client sans `max_tokens` |
| échantillonnage | non posé (profil de gufo) ; temp 0,7, top-k 20, top-p 0,8, min-p 0, presence 1,5 explicites pour Qwen, temp 1,0, top-k 40, top-p 0,95 pour DeepSeek jusqu'au 29/09/2026 | profil officiel du modèle depuis v0.2.0 (#282) : Qwen sans raisonnement 0,7 / 0,8 / 20 / 1,5, avec 1,0 / 0,95 / 20 / 0 ; DeepSeek 1,0 / 0,95 / top-k 0 ; glouton avant | aucun | gufo, depuis v0.2.0 : Qwen officiel, profil instruct, celui des sections nothink du service et de nos anciennes valeurs ; surchargeable par requête |
| `--think` | off | raisonnement : Qwen effort xhigh, DeepSeek effort high depuis v0.2.0 (sans raisonnement avant) | non indiqué | nous : équivalent des sections nothink pour Qwen, mesuré le 02/10/2026 sur Flash-Next (0.2.0, boucle agentique pi, 3 passes) : `--think on --reasoning-effort xhigh` donne 16/16 aussi, mais 71,4 s par passe contre 30,9 s (x2,3, somme des médianes par scénario), 2,4 fois plus de tokens générés, décode 44,5 contre 50,4 t/s, acceptance MTP 76,2 contre 84,6 %, cache inchangé (93 %) ; à activer par requête côté client si besoin ; pour DeepSeek, raisonnement sans budget mesuré à +43 % de temps en agentique le 29/09/2026 (non posé entre la montée en 0.2.0 et cette mesure) |
| `--cache-disk` | activé, 16 Gio | désactivé (8 Gio si activé depuis #279) | non utilisé | nous : seul chemin de reprise d'un préfixe commun entre conversations jusqu'à la 0.5.0 (mesuré) ; depuis la 0.7.0 la RAM l'apprend aussi (#386, mesuré le 04/10/2026 : reprise sans disque de 90 à 91,8 %, contre 93,6 % avec), gardé parce que le disque rapporte encore 1,4 à 1,8 point et 4 s de prefill sur le 27B, et que le cache RAM est perdu à chaque redémarrage et à chaque bascule de modèle par llama-swap ; 16 Gio car partagé entre les modèles et un point de reprise Flash-Next de session réelle pèse 1,5 Go (8 Gio en garde environ 5), et `docs/SERVER.md` demande plus que les défauts pour le 27B à contexte long. Passé au défaut de 8 Gio le matin du 26/09/2026, remis à 16 Gio le jour même ; depuis la 0.14.0 (13/10/2026) Flash-Next a son dossier, `GUFO_CACHE/flash-next`, 16 Gio aussi : il possède son dossier et y supprime les fichiers de l'ancien format, ceux des autres modèles compris (#573) ; depuis la 0.20.0 (21/10/2026) le 27B aussi, `GUFO_CACHE/qwen3.8-27b` (#540, mêmes règles) ; DeepSeek reste seul dans `GUFO_CACHE` |
| `--cache-disk-staging-bytes` | 8 Gio | automatique : depuis v0.9.1 (#473) le plus petit de 1/8 de la RAM disponible et du budget disque ; de #279 à la 0.9.0, au plus 1 Gio en plus (512 Mio fixes avant) | non utilisé | nous : au défaut d'avant #473, les points de reprise du 27B étaient refusés dès ~8k tokens (4,5k avant #279), et le 26/09/2026 ceux de nos sessions Flash-Next (1,39 à 1,50 Go) l'ont été (`reason=staging_capacity`, journalisé depuis #279) ; depuis #473 le défaut suffit au 27B (10,6 Gio résolus le 08/10/2026, aucun refus) mais tomberait vers 2 Gio pour Flash-Next (estimation), où le huitième de la RAM borne ; non préalloué. Valeur que `docs/SERVER.md` recommande désormais pour Flash-Next à contexte plein ; depuis la 0.14.0 (13/10/2026) retiré de la ligne de Flash-Next, qui l'ignore (tampon interne de 1 Mio, #573) et dont `docs/SERVER.md` ne le recommande plus ; depuis la 0.20.0 (21/10/2026) retiré aussi de la ligne du 27B, qui l'ignore de même (#540) ; gardé sur DeepSeek seul, pour qui `docs/SERVER.md` décrit encore le défaut |
| spéculatif (adaptatif, 7 tokens max), `--prefill-chunk` 512 | inchangés | défauts gufo | défauts gufo | gufo |
| `--max-pending-per-client` | non posé (16 depuis la 0.9.0, 4 avant) | valeur de `--max-pending` (16) depuis v0.9.0 (#467), 4 avant | non indiqué | gufo ; derrière llama-swap, toutes les requêtes viennent de 127.0.0.1 : jusqu'à la 0.8.1, 4 en file au plus pour tous les clients réunis (aucun rejet vu), 16 depuis |
| fichiers | Flash-Next UD-Q4_K_XL, MTP shared Q8_0, DFlash 2 Q8_0 | | UD-Q4_K_XL, MTP shared Q8_0, DFlash 2 Q4_K_M | gufo, sauf le drafter du 27B pris dans le parc (Q8_0, mesuré identique au Q4_K_M) |

Les chiffres agentiques avec cache disque ont été mesurés avec ces réglages ;
gufo « nu » (sans cache disque) était à égalité avec le service sur le 27B.

### Checklist de montée de version

À dérouler dans l'ordre à chaque nouvelle release de gufo. Règle : **les
étapes 1 à 3 ne font que lire ; rien n'est appliqué (épinglage, réglage,
contournement retiré, modèle remesuré ou non) sans question posée à
l'utilisateur et réponse reçue**, une question par décision, avec la mesure
ou la ligne de documentation qui la motive. La version mesurée en dernier
est celle de `runtime/gufo/IMAGE` (défaut de `GUFO_IMAGE`).

Seconde règle (02/10/2026) : **toute validation se lance d'emblée en debug**
(gufo `-v` et sessions pi gardées), jamais une série normale suivie d'un
rejeu debug. Un incident rare (la boucle de #368, revue une fois sur
plusieurs séries) ne se reproduit pas forcément : son transcript doit venir de
la série qui l'a vu. `remesure.sh` le fait par défaut ; un appel direct à
`agentic.sh` pose `DEBUG=1 PI_SESSIONS=1`.

1. **Ce qui a changé** (lecture) :
   - `runtime/gufo/tools/gufo-amont.sh` : releases, images publiées, commits, tickets
     suivis (ceux du tableau « À surveiller », plus les nôtres) ;
   - `runtime/gufo/tools/gufo-amont.sh release <tag>` et le `CHANGELOG.md` amont ;
   - `runtime/gufo/tools/gufo-amont.sh ticket <n> 3` pour chaque ticket suivi qui a bougé,
     et chaque PR mergée qui touche le cache, le serveur, le 27B ou
     Flash-Next ;
   - repérer les tickets fermés, les questions qu'on nous pose (à noter
     pour l'étape 8) et les PR suivies (#299 : Ornith).
2. **Nouvelles recommandations de réglage** (lecture) :
   - `runtime/gufo/tools/gufo-amont.sh diff <version épinglée> <nouvelle>` (tags
     avec leur `v`, `v0.19.0 v0.20.0` : sans lui, 404) : `docs/SERVER.md`,
     `docs/CLI.md`, guides et `QUALITY.md` / `EXPERIMENTS.md` des modèles ;
   - `gufo serve llm --help` des deux images, comparé (`docker run --rm
     --entrypoint gufo <image> serve llm --help`, sur silentchuck) : options
     ajoutées, retirées, défauts changés ;
   - confronter au tableau « Paramètres de gufo et leur origine » : chaque
     ligne tient-elle encore (défauts du cache disque et du staging,
     `--context`, `--sessions`, `--max-tokens`, échantillonnage, `--think`) ?
3. **Contournements encore utiles ?** (lecture) : staging 8 Gio de DeepSeek (#259, #279),
   `ttl: 60` sur la voix et la transcription (#272, pour Qwen-Image au
   défaut du runtime depuis v0.2.0), `capabilities.context` de llama-swap,
   GGUF refusés (Flash-Next Signal en `IQ4_NL`, DeepSeek UD-IQ3_XXS, Ornith
   Q4_K_M si #299 est mergée).
4. **Questions à l'utilisateur**, avant tout changement : monter de version
   ou non ; quels modèles remesurer (DeepSeek n'est plus remesuré depuis le
   28/09/2026 sauf demande) ; chaque réglage ou contournement que les étapes
   2 et 3 proposent de changer ; la machine est-elle libre (les bancs
   coupent le service et gufo d'usage réel).
5. **Appliquer ce qui a été accepté** : la ligne de `runtime/gufo/IMAGE`
   (seul endroit depuis le 06/10/2026 : `runtime/gufo/runtime.sh`, `download.sh`,
   `bench/remesure.sh` et `runtime/gufo/tools/gufo-amont.sh` la lisent,
   `Dockerfile.routeur` la reçoit du `.env`), réglages dans
   `runtime/gufo/gufo-llama-swap.yaml` avec leur commentaire d'origine ;
   `./tests/sh-unit.sh`, `bash -n`, commit qui dit pourquoi, push ; sur
   silentchuck `git pull --ff-only` (dépôt dans `~/llm/llmsetup`) puis `LLM_RUNTIME=gufo ./setup-llm.sh --setup image`.
6. **Remesurer**, un GPU donc en séquence, sur les modèles retenus, en une
   commande : `nohup runtime/gufo/bench/remesure.sh 27b flashnext >
   ~/llm/gufo-test/remesure.log 2>&1 &` (`SANS_CACHE=1` pour ajouter la
   boucle sans cache disque ; boucles agentiques toujours en debug, gufo
   `-v` et sessions pi gardées, par défaut depuis le 02/10/2026 pour ne pas
   rejouer une série afin d'avoir le transcript d'un incident), qui enchaîne :
   - `runtime/gufo/bench/run.sh gufo 27b flashnext` : justesse d'abord
     (aiguilles, `sanity`), puis prefill court et à 52k, décode prose et
     code, cache au tour 2, mémoire, temps de chargement ;
   - `runtime/gufo/bench/agentic.sh gufo 27b flashnext` : 16/16, temps par
     passe, part du cache (disque / RAM / ratés) ;
   - la copie des journaux bruts de `resultats/agentic/`, que le banc
     écrase, dans `resultats/agentic/<date>-<version>/` (`avant/` = la
     remesure précédente), puis leur bilan par `runtime/gufo/bench/journal.py`
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
   ou immobiles retirés), tableau des paramètres (date de confrontation) ;
   réponses aux tickets où l'on nous a posé une question, **rédigées puis
   montrées à l'utilisateur avant publication**.
9. **Remettre l'usage réel** : `remesure.sh` relance le runtime qui servait ;
   à la main, `./setup-llm.sh --start flashnext` sous le runtime gufo (ou le
   modèle d'avant), `/v1/models`, une requête avec `stop` par le proxy, voix
   et transcription si elles servent.

Pour rejouer contre une nouvelle version de gufo sans la checklist complète :
`runtime/gufo/download.sh image`, puis `runtime/gufo/bench/run.sh gufo 27b` et
`runtime/gufo/bench/agentic.sh gufo 27b`. Ce sont les deux mesures qui
comparent les moteurs à fichiers identiques ; les chiffres du service du
24/09/2026 (journal, « Évaluation face au service ») sont la référence.
