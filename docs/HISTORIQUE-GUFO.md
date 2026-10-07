# Journal de gufo

Journal daté de [gufo](https://github.com/gufo-org/gufo), moteur d'inférence
spécialisé Strix Halo servi à la place du service llama.cpp sur demande
(`./setup-llm.sh --gufo`) : évaluation, releases amont, tickets, mesures.
Pendant de [`docs/HISTORIQUE.md`](HISTORIQUE.md), qui garde le journal du
service llama.cpp. L'état courant, les réglages, le tableau des tickets
ouverts et la checklist de montée de version sont dans
[`docs/GUFO.md`](GUFO.md) : les renvois vers « Verdict », « À surveiller »,
« Paramètres de gufo et leur origine », « Checklist de montée de version » et
« Reprendre les mesures » visent ce document.

Entrées de la plus récente à la plus ancienne, décision ou résultat en tête.
Les deux tableaux de remesure, qui couvrent plusieurs entrées, sont à la fin
(« Mesures d'une version à l'autre »). Tickets et commentaires sont publiés
sous le compte c4software.

## Release v0.9.0 (07/10/2026), retenue le jour même

Choix de l'utilisateur du 07/10/2026 (« oui monte et remesure ») : image
épinglée en `gufo-runtime:0.9.0` (`7ea60a0`), yaml inchangé, puis
`remesure.sh flashnext` (Flash-Next seul, pas de `SANS_CACHE=1` ; **27B non
remesuré depuis la 0.7.0**). Pas de régression, 16/16 aux deux séries.
Vérifié après la remesure : `gufo version 0.9.0 (2e35aaf)` dans le conteneur
d'usage (Flash-Next préchargé), une requête avec `stop` en direct sur `:8009`
(« 1 à 4 », `finish_reason` stop) ; proxy, voix, transcription et image non
revérifiés.

Deux séries le 07/10/2026 (8 min chacune, journaux dans
`resultats/agentic/2026-10-07-0.9.0/` et `…-0.9.0-passe2/`, colonne v0.9.0 du
second tableau = la première), contre la première série de la 0.8.1 :

| Flash-Next, 1 session | 0.8.1, passe 1 | 0.9.0, passe 1 | 0.9.0, passe 2 |
|---|---|---|---|
| banc HTTP, justesse | OK | sanity, aiguilles, tour 2 à 100 % : OK | OK |
| prefill court, 1,4 à 1,6k (t/s) | 1 243 à 1 329 | 1 241 à 1 347 | 1 242 à 1 346 |
| prefill à 6,5k / 52k / 32k (t/s) | 1 400 à 1 404 / 1 406,2 / 1 421,9 | 1 416 / 1 424,1 / 1 432,4 | 1 400 à 1 417 / 1 415,6 / 1 428,9 |
| décode code (t/s) | 67,4 à 69,5 | 66,2 à 68,4 | 65,8 à 69,0 |
| chargement, mémoire | 83,5 s, 111 Gio | 85,5 s, 107 Gio | 81,1 s, 107 Gio |
| agentique, cache disque | 16/16, 49 requêtes, repris 91,2 %, prefill 11 s, décode 52,4 t/s, acceptance 85,7 % | 16/16, 53 requêtes, repris 93,1 %, prefill 11 s, décode 82 s à 51,1 t/s, acceptance 84,6 % | 16/16, 51 requêtes, repris 98,6 %, prefill 7 s, décode 78 s à 50,6 t/s, acceptance 85,7 % |
| reprises disque / RAM / ratés | 0 / 45 / 4 | 1 / 49 / 3 | 3 / 48 / 0 |
| `creation`, passes 1/2/3 (s) | 15,5 / 14,5 / 12,8 | 23,0 / 20,9 / 14,0 | 15,3 / 14,5 / 21,5 |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | 252 ms | 254 ms | 254 ms |

Lecture :

- **Pas de régression de débit**, et pas de gain net non plus : prefill à
  52k à 1 424 puis 1 416 t/s (1 406 et 1 399 en 0.8.1, 1 432 en 0.8.0), à 32k
  à 1 432 puis 1 429 (1 422 et 1 423), une requête par série. Les +9,5 % à
  32k que #445 annonce ne se voient pas à notre banc HTTP (écart de méthode
  non cherché) ; #463 vise 128k, que nous ne mesurons pas. Décode du code et décode agentique au niveau de
  la 0.8.1.
- **Mémoire à 107 Gio au lieu de 111** aux deux séries (107 375 et
  107 371 Mio), première baisse depuis que la ligne est tenue. Cohérent avec
  #445 (plus de copie de l'état complet aux points de reprise), non vérifié
  dans le code.
- **Reprise à 93,1 % à la première série, encore un effet de première
  série** : r5 (`no_checkpoint`), r7 et r15 (`prefix_changed`), trois débuts
  de conversation d'environ 1 550 tokens recalculés en entier, une seule
  reprise disque ; la seconde série, sur un cache disque écrit par la 0.9.0,
  revient à 98,6 % avec 3 reprises disque et aucun raté. Même forme qu'en
  0.8.1, mais sans la cause avancée alors : rien dans la 0.9.0 ne change le
  rendu du prompt de pi (#449 ne joue que sur un message système en cours de
  conversation, non vu dans les sessions de pi, sans vérification du prompt
  rendu) et `docs/KV-CACHE.md` annonce un format
  disque inchangé. Cause non établie. Deux montées de suite : compter une
  série à cache disque froid après chaque changement de version, quelle que
  soit la release, et lire la reprise sur la seconde.
- **`creation` plus long à la première série** (23,0 et 20,9 s aux deux
  premières passes, 21,5 s à la troisième de la seconde série) : le modèle
  écrit une valeur attendue fausse dans `test.js`, la corrige et relance, ce
  qu'il dit lui-même dans sa réponse (« mon attente était fausse »). Quelques
  tours de plus (53 et 51 requêtes contre 49), pas de boucle de vérification
  comme à la seconde série de la 0.8.1 ; échantillonnage non glouton, non
  imputé à la version.
- **Aucun refus de staging**, trois points de reprise disque écrits à la
  première série (`write_ms` 115 à 127 ms), aucun à la seconde (74 et 75
  sautés, `min_step`). Budget RAM automatique du cache inchangé (17,8 Gio) :
  `CmaTotal` vaut 0 sur bigchuck, 88d2139 est sans effet ici.
- Non observés dans ces séries, donc non vérifiés ici : #449 (message
  système en cours de conversation), #466 (points de branchement sous
  pression RAM), et la file par client à 16 (#467 ; `queue_budget` identique
  au démarrage, aucun rejet).

v0.9.0 (`2e35aaf`, image `gufo-runtime:0.9.0`, digest `c8a37c14ffbc`),
publiée le 07/10/2026 à 11:50 UTC. Contenu depuis v0.8.1 : #445, points de
reprise du prompt de Flash-Next pris dans la passe finale de prefill, K/V
laissés dans la session vivante au lieu d'être copiés ; #463, moins de
travail de prefill à long contexte (lignes de sortie inutilisées de la
dernière couche sautées, +1,8 % annoncés à 128k) ; #466, points de
branchement appris gardés sous pression RAM ; 88d2139, pages CMA libres
retirées de la RAM disponible pour le budget automatique ; #449, messages
`system` et `developer` acceptés en cours de conversation, remontés dans le
tour système de tête pour Qwen (la requête qui en introduit un est
recalculée en entier) ; #467, `--max-pending-per-client` au défaut de
`--max-pending` ; #458, `--trace <fichier>` en opt-in (corps des requêtes,
prompt rendu, texte généré et réponse, en JSON Lines).

Ticket suivi qui a bougé : #228, commentaire de jtsylve du 06/10/2026 (la
baisse en ROCm 10 vient de clang 23 et non des bibliothèques, PR #459 ;
clang 23 change le texte glouton de Flash-Next). Aucune question ne nous
est posée.

Confrontation des paramètres à la documentation amont :

- **07/10/2026, v0.9.0** (diff v0.8.1...v0.9.0 de la documentation, `--help`
  0.8.1 et 0.9.0 comparés sur bigchuck : deux lignes d'écart) : `--trace`
  ajoutée, non posée (le fichier garde les conversations entières, à
  n'activer que pour diagnostiquer une sortie cassée) ;
  `--max-pending-per-client` passe du défaut 4 à la valeur de
  `--max-pending` (16), non posée, donc 16 requêtes en file au lieu de 4
  derrière llama-swap ; budget RAM automatique redéfini (`MemAvailable`
  moins `CmaFree`), sans effet ici. Contournements non revus.

## Release v0.8.1 (06/10/2026), retenue le jour même

Choix de l'utilisateur du 06/10/2026 (« on update ») : image épinglée en
`gufo-runtime:0.8.1` (`458c36b`), yaml inchangé, puis `remesure.sh flashnext`
(Flash-Next seul, choix de l'utilisateur, pas de `SANS_CACHE=1` ; **27B non
remesuré depuis la 0.7.0**, alors que #441 touche aussi ses appels d'outils).
Pas de régression, 16/16 aux deux passes. Depuis cette montée la version ne
s'écrit plus qu'à un endroit, `runtime-gufo/IMAGE` (`65fb0f2`, au lieu de
trois). Vérifié après la remesure : `gufo version 0.8.1 (543300e)` dans le
conteneur d'usage (Flash-Next préchargé), une requête avec `stop` en direct
sur `:8009` (« 1 à 4 », `finish_reason` stop) ; proxy, voix, transcription et
image non revérifiés.

Deux séries le 06/10/2026 (8 min chacune, journaux dans
`resultats/agentic/2026-10-06-0.8.1/` et `…-0.8.1-passe2/`, colonne v0.8.1 du
second tableau = la première), contre la 0.8.0 de la veille :

| Flash-Next, 1 session | 0.8.0 | 0.8.1, passe 1 | 0.8.1, passe 2 |
|---|---|---|---|
| banc HTTP, justesse | OK | sanity, aiguilles, tour 2 à 100 % : OK | OK |
| prefill court, 1,4 à 1,6k (t/s) | 1 035, puis 1 231 à 1 337 | 1 243 à 1 329 | 1 241 à 1 332 |
| prefill à 6,5k / 52k / 32k (t/s) | 1 402 à 1 415 / 1 432,0 / 1 442,5 | 1 400 à 1 404 / 1 406,2 / 1 421,9 | 1 401 à 1 402 / 1 399,3 / 1 422,9 |
| décode code (t/s) | 66,3 à 68,5 | 67,4 à 69,5 | 66,9 à 67,5 |
| chargement, mémoire | 86,4 s, 111 Gio | 83,5 s, 111 Gio | 80,0 s, 111 Gio |
| agentique, cache disque | 16/16, 49 requêtes, repris 98,7 %, prefill 7 s, décode 51,0 t/s, acceptance 84,6 %, 27,9 s par passe | 16/16, 49 requêtes, repris 91,2 %, prefill 11 s, décode 52,4 t/s, acceptance 85,7 %, 27,1 s par passe | 16/16, 79 requêtes, repris 98,4 %, prefill 19 s, décode 48,4 t/s, acceptance 76,6 %, 30,6 s par passe |
| reprises disque / RAM / ratés | 3 / 46 / 0 | 0 / 45 / 4 | 4 / 75 / 0 |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | 257 ms | 252 ms | 270 ms |

Lecture :

- **Pas de régression de débit** : prefill, décode et acceptance de la passe 1
  au niveau de la 0.8.0. Le prefill à 52k est 2 % plus bas aux deux passes
  (1 406 et 1 399 contre 1 432), une seule requête par série : à revoir à la
  prochaine montée, pas concluant.
- **Reprise à 91,2 % à la passe 1 : les points de reprise disque de la 0.8.0
  ne servent plus, effet de première série.** Les quatre premiers débuts de
  conversation (r5, r7, r11, r15, environ 1 550 tokens chacun) sont
  recalculés en entier (`no_checkpoint` 1, `prefix_changed` 3, aucune reprise
  disque), puis la RAM reprend le préfixe. La passe 2, qui part d'un cache
  disque écrit par la 0.8.1, revient à 98,4 % avec 4 reprises disque et aucun
  raté, comme la 0.8.0 sur son cache du matin. Cause probable, non vérifiée
  dans le code : #441 retire la consigne JSON injectée dans le prompt des
  outils, donc le préfixe tokenisé change (84 594 tokens de prompt contre
  84 603 sur les mêmes 49 requêtes). À prévoir à chaque version qui touche le
  rendu du prompt : une première série à cache disque froid.
- **Une boucle de vérification sur `creation` à la passe 2** (88,7 s au lieu
  de 15 s, 30 requêtes de plus, PASS quand même). Le modèle écrit une valeur
  attendue fausse dans `test.js` (médiane de [4, 1, 7, 2] = 4, puis 4,5),
  la corrige en 3, obtient « Tous les tests passent » dès le 9e tour, puis
  enchaîne une vingtaine de `node -e` qui revérifient (2 + 4) / 2 avant de
  conclure seul. C'est la forme déjà décrite dans « Ticket #388 » (valeur
  attendue fausse, puis sondages), vue dès la 0.2.0 : pas imputable à la
  0.8.1 sur une occurrence en deux séries, mais #441 ne la supprime pas non
  plus. C'est elle qui tire l'acceptance (76,6 %) et le décode agentique
  (48,4 t/s) de la passe 2, faits de petits appels répétés ; transcript dans
  `2026-10-06-0.8.1-passe2/avec-cache/gufo-flashnext.sessions/`.
- **Aucun refus de staging**, écritures du cache disque : une première à
  1 958 ms juste après le chargement, les suivantes à 105 à 110 ms (même
  forme que « Prefill court en baisse au banc »).
- Non observé dans ces séries, donc non vérifié ici : le cas que #441
  corrige (appel d'outil émis sans fermer `</think>`, fin de tour vide de
  #266), nos sections tournant en `--think off`.

v0.8.1 (`543300e`, image `gufo-runtime:0.8.1`, digest `56f0a052e784`),
publiée le 06/10/2026 à 12:04 UTC. Contenu depuis v0.8.0, trois correctifs :
#441, appels d'outils gardés dans la syntaxe native du modèle (XML pour
Qwen, DSML pour DeepSeek) quel que soit le schéma, sans enveloppe JSON ni
consigne ajoutée au prompt, et en-tête de fonction natif accepté comme fin
du raisonnement quand le modèle omet `</think>` ; #446, lignes vides
retirées en tête de réponse après le raisonnement ; #447, plus de plafond
fixe au nombre d'images d'un historique Qwen, limité par le contexte.
Non incluse : la PR #445 (points de reprise de Flash-Next sans copie de
l'état complet, +9,5 % de prefill à 32k et +25,5 % à 128k annoncés), encore
ouverte.

Confrontation des paramètres à la documentation amont :

- **06/10/2026, v0.8.1** (diff 0.8.0...0.8.1 de la documentation, `--help`
  0.8.0 et 0.8.1 comparés sur bigchuck : identiques) : aucune option ajoutée
  ni retirée, aucun défaut changé ; `docs/SERVER.md` ne change que sur les
  outils (syntaxe native, frontière du raisonnement) et les images.
  Contournements non revus.

## Release v0.8.0 (05/10/2026), retenue le jour même

Choix de l'utilisateur du 05/10/2026 (« nouvelle version dispo, update ») :
`GUFO_IMAGE` épinglée en `gufo-runtime:0.8.0` aux trois endroits (`a28725a`),
yaml inchangé, puis `remesure.sh flashnext` (périmètre du matin : Flash-Next
seul, pas de `SANS_CACHE=1`, **27B non remesuré depuis la 0.7.0**). Pas de
régression, 16/16. Vérifié après la remesure : `gufo version 0.8.0 (e03bb91)`
dans le conteneur d'usage (Flash-Next préchargé), une requête avec `stop` en
direct sur `:8009` ; proxy, voix, transcription et image non revérifiés.

Remesure du 05/10/2026 (8 min, journaux dans
`resultats/agentic/2026-10-05-0.8.0/`, colonne v0.8.0 du second tableau),
contre la passe 0.7.1 du matin :

| Flash-Next, 1 session | 0.7.1 (matin) | 0.8.0 |
|---|---|---|
| banc HTTP, justesse | OK | sanity, aiguilles, tour 2 à 100 % : OK |
| prefill court, 1,4 à 1,6k (t/s) | 416 à 989 (`fstrim` en cours) | 1 035, puis 1 231 à 1 337 |
| prefill à 6,5k / 52k / 32k (t/s) | 1 424 / 1 439,9 / 1 458,1 | 1 402 à 1 415 / 1 432,0 / 1 442,5 |
| décode code (t/s) | 65,5 à 67,8 | 66,3 à 68,5 |
| chargement, mémoire | 83,3 s, 111 Gio | 86,4 s, 111 Gio |
| agentique, cache disque | 16/16, 53 requêtes, repris 93,8 %, prefill 10 s, décode 50,7 t/s, acceptance 84,8 %, 31,8 s par passe | 16/16, 49 requêtes, repris 98,7 %, prefill 7 s, décode 51,0 t/s, acceptance 84,6 %, 27,9 s par passe |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | 257 ms | 257 ms |

Lecture :

- **Pas de régression**, comme attendu d'une version sans changement de
  moteur : prefill, décode et acceptance au niveau de la 0.7.1.
- **Reprise à 98,7 % et aucun raté : effet du cache disque, pas de la
  version.** La série part des points de reprise écrits le matin par la même
  boucle (3 reprises disque, 0 raté, 0 point écrit, appel froid en 0,7 s
  contre 1,7 s ; la requête de justesse du banc reprend elle aussi 28 tokens
  du disque). Les 27,9 s par passe contre 31,8 s ne sont donc pas un gain de
  la 0.8.0 ; `creation` n'a pas écrit de valeur attendue fausse dans cette
  série (15,1 / 13,9 / 15,5 s), ce qui pèse aussi.
- **Écritures lentes juste après le chargement, de nouveau** : les deux
  premiers points de reprise du banc en 2 612 et 1 214 ms, les suivants en
  108 à 275 ms (puis 1 122 et 633 ms sur les fichiers de 1,5 et 1 Go) ;
  première requête courte à 1 035 t/s, les autres à 1 231 à 1 337. Pas de
  `fstrim` cette fois : même forme que les rafales relevées plus bas
  (« Prefill court en baisse au banc »), cause toujours non établie.

v0.8.0 (`e03bb91`, image `gufo-runtime:0.8.0`, digest `479f736cc6ec`),
publiée le 05/10/2026 à 12:19 UTC. Contenu depuis v0.7.1, un seul commit :
#434, compatibilité de `/v1/responses` avec les clients OpenAI (Codex CLI) :
outils hébergés (`web_search`, `mcp`…) acceptés et ignorés, `namespace`
aplatis en fonctions, champs sans effet tolérés (`include`,
`reasoning.summary`, `prompt_cache_key`…), éléments `reasoning` rejoués à
contenu nul acceptés.

Confrontation des paramètres à la documentation amont :

- **05/10/2026, v0.8.0** (diff 0.7.1...0.8.0 de la documentation, `--help`
  0.7.1 et 0.8.0 comparés sur bigchuck : identiques) : aucune option ajoutée
  ni retirée, aucun défaut changé ; `docs/SERVER.md` ne change que sur la
  route Responses. Contournements non revus.

## Release v0.7.1 (05/10/2026), retenue le jour même

Choix de l'utilisateur du 05/10/2026 : d'abord une passe de mesure sur
Flash-Next seul, image non épinglée (`GUFO_IMAGE` par l'environnement,
`essais/passe-flashnext-0.7.1.sh`, qui appelle `remesure.sh flashnext`), puis
montée : `GUFO_IMAGE` épinglée en `gufo-runtime:0.7.1` dans `lib/gufo.sh`,
`runtime-gufo/download.sh` et `runtime-gufo/Dockerfile.routeur` (`c1ebaa2`),
yaml inchangé. Pas de régression sur Flash-Next, 16/16 ; **27B non
remesuré** ; pas de série `SANS_CACHE=1`. Vérifié après la montée :
`gufo version 0.7.1 (96a4647)` dans le conteneur d'usage (Flash-Next
préchargé), une requête avec `stop` en direct sur `:8009` ; proxy, voix,
transcription et image non revérifiés.

Passe du 05/10/2026 (10 min, journaux dans
`resultats/agentic/2026-10-05-0.7.1/`, colonne v0.7.1 du second tableau de
« Mesures d'une version à l'autre »), contre la remesure de la 0.7.0 de la
veille, une série de chaque côté :

| Flash-Next, 1 session | 0.7.0 (04/10) | 0.7.1 (05/10) |
|---|---|---|
| banc HTTP, justesse | sanity, aiguilles, tour 2 à 100 % : OK | OK |
| prefill à 6,5k (t/s) | 1 354 à 1 374 | 1 424 |
| prefill à 52k (t/s) | 1 364,6 | 1 439,9 |
| prefill à 32k, tour 1 du cache (t/s) | 1 370,2 | 1 458,1 |
| prefill court, 1,4 à 1,6k (t/s) | 1 236 à 1 317 | 416 à 989 (écriture disque lente, voir plus bas) |
| décode code (t/s) | 60,4 à 63,4 | 65,5 à 67,8 |
| chargement, mémoire | 80,2 s, 111 Gio | 83,3 s, 111 Gio |
| agentique, cache disque | 16/16, repris 93,1 %, prefill 12 s, décode 48,1 t/s, acceptance 85,7 %, 35,7 s par passe | 16/16, repris 93,8 %, prefill 10 s, décode 50,7 t/s, acceptance 84,8 %, 31,8 s par passe |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | 259 ms | 257 ms |

Lecture :

- **Pas de régression** : 53 requêtes agentiques des deux côtés (disque 1,
  RAM 49, ratés 3 : 1 `no_checkpoint`, 2 `prefix_changed`), aucun refus de
  staging, 3 points de reprise disque écrits et 66 sautés (`min_step`).
- **Prefill long à +4 à +6 %** : #421 annonce +1,4 à +3,2 %. Décode
  agentique à 50,7 t/s, niveau de la 0.2.0 (50,4) ; #415 annonce +3,6 % de
  décode sur notre profil d'échantillonnage. Une série : indication, pas
  écart établi, de même que les 31,8 s contre 35,7 s par passe.
- **Fausse valeur attendue de #388 revue sans boucle** : en `creation`,
  4 au lieu de 3 aux passes 2 et 3 (20,4 et 21,3 s contre 16,3 s), corrigée
  juste les deux fois.
- **#400** (cadrage des appels d'outils), à vérifier depuis la 0.7.0 : rien
  d'anormal dans les 16 scénarios, pas de vérification dédiée.

### Prefill court en baisse au banc : le disque, pas la version

Au banc HTTP de la passe, le prefill des prompts de 1,4 à 1,6k tokens tombait
de 1 305 à 1 317 t/s (0.7.0, la veille) à 834 à 989 t/s, 416 et 511 à la
première passe, soit 0,4 s de plus avant le premier token (1,61 s contre
1,21 s), sans effet à 6,5k ni sur les petites requêtes agentiques.

Lecture du code amont (sous-agent, `git diff v0.7.0 v0.7.1` et PR #421 et
#415) : aucun mécanisme propre aux prompts courts dans l'intervalle.

- #421 : ses noyaux s'appliquent autant à un lot de 1 375 tokens qu'aux lots
  pleins de 2 048 (taille de lot du moteur, `kPrefillChunkTokens` ; le
  `--prefill-chunk` 512 ne borne le prefill qu'en présence d'un décodeur
  concurrent) ; aucun seuil sous 2 048. Validée en amont sur pp4096 et sur
  des prompts de 6,5k à 102k seulement.
- #415 : échantillonnage, hors du chrono du prefill (`prompt_ms` ne compte
  que `Prefill`). #407 : inactif sur une requête à un seul message, cas du
  banc. #392, #394 et les parseurs : hors du chemin de prefill.
- Dans le chrono du prefill, et identiques dans les deux versions : la copie
  synchrone du point de reprise au préfixe stable (coût à peu près constant,
  visible sur un lot unique, noyé sur un prompt long) et l'attente de la
  lecture `O_DIRECT` de la table n-gram, qui partage le NVMe avec l'écriture
  du point de reprise. La PR #421 écarte elle-même des points de mesure pour
  « a single sample stalled on n-gram disk I/O ».

Sonde du 05/10/2026 (`essais/prefill-court.sh` et `prefill-court.py`, bras
croisés, 1 session, 5 requêtes de 1 375 tokens puis 3 de 1 587 par bras,
journaux gufo dans `resultats/prefill-court-2026-10-05/`), cache disque plein
(16 Gio sur 16) :

| Bras | prefill 1 375 tokens (t/s) | prefill 1 587 tokens (t/s) | écriture d'un point de reprise (ms) |
|---|---|---|---|
| A1, 0.7.0, cache disque | 380, puis 1 296 à 1 339 | 1 290 à 1 376 | 2 304, puis 105 à 128 |
| B1, 0.7.1, cache disque | 1 265 à 1 363 | 1 296 à 1 380 | 103 à 150 |
| A2, 0.7.0, cache disque | 1 260 à 1 351 | 1 285 à 1 370 | 91 à 159 |
| B2, 0.7.1, cache disque | 409 à 532 | 437, 997, 1 159 | 2 270 à 3 200 |
| C, 0.7.1, sans `--cache-disk` | 1 265 à 1 359 | 1 270 à 1 373 | aucune |
| D, 0.7.0, sans `--cache-disk` | 1 048 à 1 244 | 1 122 à 1 269 | aucune |

- **La version n'y est pour rien** : à disque rapide, 0.7.1 et 0.7.0 sont à
  égalité (B1 contre A1 et A2, 1 357 contre 1 339 t/s en médiane sur 1 375
  tokens), et la 0.7.0 ralentit aussi (première requête de A1 : 380 t/s).
- **Le ralentissement suit l'écriture disque** : chaque requête lente
  coïncide avec un point de reprise de 330 Mo écrit en 2,3 à 3,2 s au lieu
  de 0,1 s ; sans `--cache-disk`, aucun ralentissement (C). Le banc de la
  passe montrait la même chose (2 273 puis 1 122, 321 et 221 ms).
- **Le NVMe seul n'est pas lent** (YMTC PC41Q 2 To, btrfs `compress=zstd:1`,
  `discard=async`, 41 % plein, 34 à 41 °C) : `essais/ecriture-disque.py`
  reproduit l'écriture de gufo (fichier temporaire de 330 Mo, `fsync`,
  `rename`, `fsync` du répertoire), 35 fois de suite sans gufo : 75 à 99 ms,
  trois fois 157 à 363 ms, jamais plus, y compris après la suppression d'un
  fichier de 6 Go.
- **L'épisode du banc de la passe est le `fstrim` hebdomadaire** :
  `fstrim.service` a tourné de 10:23:32 à 10:25:07 (1,1 Tio rendus, timer
  rattrapé après le démarrage de bigchuck à 10:10), les requêtes lentes vont
  de 10:23:43 à 10:25:08 et le prefill à 6,5k de 10:25:13 est rapide.
- **Les deux épisodes de la sonde restent sans cause** (bras B2 entier,
  11:40:39 à 11:41:01, et première écriture de A1 à 11:35:55) : rien dans le
  journal système à ces instants. Sur les 5 095 écritures de plus de 100 Mo
  des journaux gufo archivés (24/09 au 05/10), 30 passent sous 150 Mo/s
  (médiane des autres : 1 328 Mo/s), toutes à 51 à 84 Mo/s, sur des
  fichiers de 120 à 175 Mo, en rafales de 15 à 30 s dans la minute qui suit
  un chargement de modèle : 26/09 à 11:11, 01/10 à 14:17, 04/10 à 13:26,
  05/10. Débit constant qui ne ressemble pas à un disque saturé ; piste non
  vérifiée : un coût côté gufo ou noyau juste après le chargement. À prendre
  sur le fait (pression CPU, mémoire et E/S, threads de gufo, à la seconde,
  pendant le banc HTTP).
- **Non expliqué non plus** : l'écart de D (0.7.0 sans cache disque, -9 % sur
  C, un seul bras).
- **Chargement** : 78 à 86 s avec `--cache-disk`, 23 à 26 s sans (bras C et
  D). L'écart est la phase `artifact_identity`, absente sans cache disque :
  47 s pour le GGUF de 104 Go puis 10 s pour la tête MTP (bras B1), payées à
  chaque chargement, donc à chaque bascule de modèle par llama-swap. Constat
  de journal, non creusé (ni le code, ni un chargement à froid sans cache
  disque).
- **Portée** : prompts neufs de 1 à 2k tokens seulement (un seul lot, juste
  après l'écriture du point de reprise de la requête précédente). En boucle
  agentique, 3 points de reprise disque écrits par série et premier token
  des petites requêtes inchangé. Réglages gardés ; ne pas lire une baisse du
  prefill court du banc HTTP sans regarder les `write_ms` du journal.

v0.7.1 (`96a4647`, image `gufo-runtime:0.7.1`, digest `d0c2bc755474`),
publiée le 05/10/2026 à 08:05 UTC, image à 08:22 UTC. Contenu depuis v0.7.0 :
prefill de Flash-Next (#421 : projections, attention, indexeur),
échantillonnage qui saute les blocs de vocabulaire sans effet (#415), point de
reprise stable gardé avant un contexte utilisateur de fin remplacé (#407),
écritures du cache disque préservées au démarrage (#392, verrou sur le
répertoire), capacité de sortie reprise aux flux abandonnés (#394), cadrage
des appels d'outils hors du contenu assistant (#400), balises de raisonnement
littérales gardées sans raisonnement (#391), DeepSeek (#397, #420), champs de
raisonnement de Claude Code sur `/v1/messages` (#405, #428).

Confrontation des paramètres à la documentation amont :

- **05/10/2026, v0.7.1** (diff 0.7.0...0.7.1 de la documentation, `--help`
  0.7.0 et 0.7.1 comparés sur bigchuck : identiques) : aucune option
  ajoutée ni retirée, aucun défaut changé. `docs/SERVER.md` ne change que
  sur la route Messages (`thinking.type` `adaptive`, `output_config.effort`),
  les appels d'outils de DeepSeek et un conseil : garder le même
  `reasoning_effort` d'un tour à l'autre quand le raisonnement est actif
  (l'effort est écrit dans le prompt, le changer force un prefill complet),
  sans objet en `--think off`. Contournements non revus (staging 8 Gio :
  #259 toujours ouvert).

## Release v0.7.0 (04/10/2026), retenue le jour même

Choix de l'utilisateur du 04/10/2026 : passage de la 0.5.0 à la 0.7.0 sans
passer par la 0.6.0, `GUFO_IMAGE` épinglée en `gufo-runtime:0.7.0` dans
`lib/gufo.sh`, `runtime-gufo/download.sh` et
`runtime-gufo/Dockerfile.routeur`, yaml inchangé (`--think off`, 2 sessions,
cache disque 16 Gio, staging 8 Gio). Remesurée le jour même sur bigchuck
(justesse puis banc complet, 27B et Flash-Next, `SANS_CACHE=1`) : pas de
régression, 16/16 partout, réglages gardés. Vérifié après la remesure :
`gufo version 0.7.0 (aedc129)` dans le conteneur d'usage (Flash-Next
préchargé), une requête avec `stop` en direct sur `:8009` ; proxy, voix,
transcription et image non revérifiés.

Remesure du 04/10/2026 (`runtime-gufo/bench/remesure.sh 27b flashnext`,
`SANS_CACHE=1`, 21 min, journaux dans `resultats/agentic/2026-10-04-0.7.0/`,
colonnes v0.7.0 du second tableau de « Mesures d'une version à l'autre ») :

| Série, 1 session | 27B | Flash-Next |
|---|---|---|
| banc HTTP | justesse et aiguilles OK, prefill court 520 à 544 t/s, à 6,5k 570, à 52k 501,7 ; décode prose 45,1 à 50,3, code 64,6 à 66,5 t/s ; tour 2 repris à 100 % ; chargement 27,4 s ; 77 Gio | justesse et aiguilles OK, prefill court 1 236 à 1 315 t/s, à 6,5k 1 354 à 1 374, à 52k 1 364,6 ; décode code 60,4 à 63,4 t/s ; tour 2 repris à 100 % ; chargement 80,2 s ; 111 Gio |
| agentique, cache disque | 16/16, repris 93,6 %, prefill 17 s, décode 42,5 t/s, acceptance 71,8 %, somme des médianes par passe 37,1 s | 16/16, repris 93,1 %, prefill 12 s, décode 48,1 t/s, acceptance 85,7 %, 35,7 s par passe |
| agentique, sans cache disque | 16/16, repris 91,8 % (90,1 % en 0.5.0), prefill 21 s (25 s), décode 40,7 t/s, 42,1 s par passe | 16/16, repris 91,7 % (89,9 %), prefill 10 s (12 s), décode 48,9 t/s, 27,9 s par passe |

Lecture :

- **Pas de régression** : prefill, décode et acceptance au niveau de la
  0.5.0 sur les deux modèles ; mémoire inchangée (77 et 111 Gio, comme le
  02/10) ; aucun refus de staging, aucun `byte_capacity`, aucun
  `device_lost`.
- **#386 vérifié, gain partiel chez nous** : sans cache disque, la reprise
  passe de 90 à 91,8 % (27B) et de 89,9 à 91,7 % (Flash-Next), un
  `shared_prefix_learned` par série (1 508 tokens appris sur un prompt de
  1 589 pour le 27B). Le disque rapporte encore 1,4 à 1,8 point de reprise et
  4 s de prefill sur le 27B (17 contre 21 s), un raté `prefix_changed` de
  moins ; sur Flash-Next l'écart de prefill est dans le bruit (12 contre
  10 s, pour 4 295 contre 3 631 tokens générés). `--cache-disk` et le
  staging 8 Gio gardés, d'autant que ce banc ne mesure ni un redémarrage ni
  une bascule de modèle par llama-swap, où seul le disque survit.
- **Décode agentique de Flash-Next** : 48,1 t/s avec cache disque et 48,9
  sans, contre 44,7 à 46,4 en 0.5.0 et 50,4 en 0.2.0 ; l'écart à la 0.2.0
  se réduit, point clos faute de régression nette.
- **Fausse correction de #388 revue sans boucle** : en `creation`, Flash-Next
  a écrit une valeur attendue fausse (4 au lieu de 3) puis l'a corrigée aux
  passes 2 et 3 avec cache disque (22,2 et 22,7 s contre 17,5 s), d'où les
  35,7 s par passe contre 27,9 s sans cache disque : écart de génération,
  pas de cache.
- **Budget du cache RAM** (`snapshot_cache_configured`) : 27B 32 Gio
  automatiques, 80,8 Gio au plus en explicite ; Flash-Next en 1 session
  16,6 Gio et 29,3 Gio au plus ; Flash-Next d'usage réel en 2 sessions
  13,2 Gio et 22,3 Gio au plus. `--cache-ram-bytes` non posée : aucun refus
  `byte_capacity` dans ce banc, à revoir sur des sessions réelles longues.
- La colonne `avant/` du bilan de `remesure.sh` porte les essais de #388 du
  03/10 (2 sessions), pas la remesure de la 0.5.0 : comparaison faite contre
  les chiffres du 02/10 de ce journal.

v0.7.0 (`aedc129`, image `gufo-runtime:0.7.0`, digest `b280a3781e05`),
publiée le 04/10/2026 à 11:09 UTC ; v0.6.0 (`cb46d63`, digest
`31b86b99ac2d`) le 03/10/2026 à 10:26 UTC. Contenu depuis v0.5.0 :

- 0.6.0 : préfixes en cours de prefill partagés entre requêtes concurrentes
  (#382 : une requête froide attend le point de reprise d'une requête qui
  partage au moins 512 tokens de plus avec elle ; rien n'attend en
  `--sessions 1`), sortie avec `device_lost` quand le contexte GPU est perdu
  (#390), message d'erreur d'un flux en échec (#385), chaînes JSON gardées à
  la reprise d'un appel d'outil (#396), blocs `thinking` de la route Messages
  (#380) ;
- 0.7.0 : préfixe partagé appris dans le cache RAM (#386, ferme #267 :
  appris à la deuxième conversation, repris à la troisième, sans
  `--cache-disk`), `--cache-ram-bytes` explicite au-delà du budget
  automatique, jusqu'à la RAM disponible moins 4 Gio (#384), `/slots` et
  métriques au format llama.cpp (#389 : tokens repris du cache, secondes de
  prefill et de décode), métriques des tours de vérification spéculative
  (#403), perte du GPU détectée au repos et en-têtes de flux différés (#406),
  sortie d'outil lue au format de la requête admise (#393), tours d'outils
  rejoués repris du cache avec arguments typés ou en union (#404).

Hors de la 0.7.0, mergés le 04/10/2026 après la release : #400 (cadrage des
appels d'outils hors du contenu assistant) et #415 (échantillonnage).

Confrontation des paramètres à la documentation amont :

- **04/10/2026, v0.7.0** (diff 0.5.0...0.7.0 de la documentation, `--help`
  0.5.0 et 0.7.0 comparés sur bigchuck : seule la description de
  `--cache-ram-bytes` change) : aucune option ajoutée ni retirée, aucun
  défaut changé. Trois points touchent nos réglages, aucun appliqué :
  - `--cache-disk` n'est plus le seul chemin de reprise d'un préfixe commun
    (`docs/KV-CACHE.md`, « Learned divergence points » : « Without disk,
    this needs no configuration »). Gardé : le cache RAM appartient au
    processus, donc perdu à chaque redémarrage et à chaque bascule de modèle
    par llama-swap (déduction, non mesuré), et `docs/KV-CACHE.md` conseille
    encore `--cache-disk` avec un staging supérieur à la taille des points de
    reprise pour Flash-Next à 262144 de contexte en 2 sessions (14,8 Go
    libres après chargement, budget RAM automatique 7,76 Go pour des points
    de reprise de 5,70 Go à 200k tokens : une seule conversation profonde
    retenue). Tranché par la boucle `SANS_CACHE=1` : gardé (lecture plus
    haut) ;
  - staging 8 Gio gardé : le défaut reste le plus petit de 1 Gio, un huitième
    de la RAM disponible et le budget disque (#259 toujours ouvert) ;
  - `--cache-ram-bytes` non posée : la ligne `snapshot_cache_configured` du
    démarrage publie désormais `automatic_bytes` et `max_bytes`, relevés
    plus haut.
- Non vérifié à la remesure (aucune perte du GPU) : `/health` répond 503 `device_lost` après une
  perte du contexte GPU et gufo sort en statut 75 (`checkEndpoint: /health`
  de llama-swap ; comportement de llama-swap sur cette sortie non vérifié) ;
  les en-têtes d'un flux attendent l'admission de la requête, 5 s au plus.

## Ticket #267 : fermé par #386 (03/10/2026)

Fermé le 03/10/2026 à 10:35 UTC par la fusion de #386 (« Closes #267 »),
livrée dans la 0.7.0. Chiffres de la PR (Flash-Next UD-Q4_K_XL en
`--sessions 4`, prompt système partagé de 5,4k tokens, troisième et quatrième
conversations) : 5 413 tokens repris au lieu de 4 096, premier token de
1,30 s à 0,41 s sur des tâches courtes, 15,0 s contre 15,5 à 15,8 s sur des
tâches de 18k tokens ; 27B en `--sessions 2` de 3,8 s à 0,60 s. Rien de
mesuré chez nous. Un commentaire de relecture du 03/10 (jabata) signale un
chemin d'éviction sous pression mémoire qui retire encore le préfixe
partagé ; suite non lue.

## Ticket #259 : point d'étape du mainteneur (03/10/2026)

Trois des quatre points sont corrigés : #369 est déjà dans la 0.5.0 que nous
servons, #386 n'est que sur `main` ; reste le staging par défaut. Aucune
question ne nous est posée.

fedeizzo, le 03/10/2026 à 15:04 UTC, sur `main` (1b4e6825) :

- points 2 et 3 (reprise du préfixe partagé sans `--cache-disk`,
  apprentissage dès la deuxième conversation et reprise à la troisième)
  corrigés par #386. Ses chiffres : Flash-Next avec 5,4k tokens de prompt
  système partagé, 5 413 tokens repris au lieu de 4 096, premier token de
  1,3 s à 0,4 s ; 27B de 3,8 s à 0,6 s ;
- point 4 (éviction en `--sessions 1`) corrigé par #369 (128 points de
  reprise indépendants de `--sessions`) ;
- refus de staging désormais journalisé ;
- reste le défaut de `--cache-disk-staging-bytes`, toujours le plus petit de
  1 Gio, un huitième de la RAM disponible et le budget disque : un point de
  reprise du 27B à 24k tokens fait environ 1,85 Go, donc refusé par défaut.
  Correction prévue en retirant le plafond fixe de 1 Gio (environ 9 Go sur
  le 27B), ticket fermable quand ce sera fait.

#386 n'est pas dans la 0.5.0 : à vérifier à la prochaine release, c'est un
candidat au retrait du contournement « staging 8 Gio » et de `--cache-disk`.
Début de l'historique : « Tickets #259 et #267 » plus bas.

## Ticket #388 : boucle d'appels d'outils de Flash-Next (02 et 03/10/2026)

Ticket fermé le 03/10/2026 à 15:14 UTC par francescobozzo (collaborateur),
état « completed », avec ce mot : « Ok, I'm closing the issue. @c4software
thanks a lot for your deep dive ». Conclusions et tableau des séries avec
boucle dans `docs/GUFO.md` (« Ticket #388 ») : pas une régression, le texte
avant l'edit décide, presence 0,0 n'est pas un correctif établi, deux leviers
côté client, rien de changé au réglage d'usage. Avant sa fermeture, la ligne
du tableau « À surveiller » donnait pour sujet : boucle de répétition de
Flash-Next en boucle d'outils (vue en v0.4.0 et v0.5.0, puis en v0.2.0 aussi
le 03/10/2026 : pas une régression), suite de #368.

Flash-Next en `--think off` (profil Qwen sans raisonnement de gufo,
presence 1,5), dans le scénario `creation` de la boucle pi, écrit parfois un
test dont la valeur attendue est fausse, le « corrige » vers une autre valeur
fausse, puis recopie sans fin le même appel d'outil.

Ce qui a été dit ou publié en amont, puis corrigé :

| Dit ou publié | Remplacé par | Quand |
|---|---|---|
| boucle « jamais vue en 0.2.0 », donc régression de la 0.4.0 (#368, réponse au tiers dans #388) | la 0.2.0 boucle aussi ; le « jamais vue » venait de n'avoir que 2 séries | témoin du 03/10/2026, annoncé dans #388 |
| choix du 02/10 : 0.5.0 non retenue | passage en 0.5.0, la boucle n'étant plus un motif | 03/10/2026 |
| piste des pénalités aveugles au prompt depuis #332 | affaiblie par le `--help` de la 0.2.0 (la pénalité ne voyait déjà pas le prompt) | 02/10 au soir |
| piste « presence 0,0 comme correctif » de l'analyse | affaiblie par le rejeu (la seconde valeur fausse arrive aussi à 0,0) | 03/10/2026 |
| 2 sur 9 contre 0 sur 20 : « moins de 1 % » | p = 0,09 (le calcul publié prenait 2 sur 9 pour un taux exact) | commentaire final du 03/10/2026 |
| premier décompte : 28 sessions et 6 erreurs à 1,5, 100 et 19 à 0,0 | 38 et 8, 100 et 24 (périmètre corrigé, étape 4) | commentaire final du 03/10/2026 |

### Échanges dans le ticket

- **02/10/2026** : commentaire sur #368 avec les chiffres de la 0.5.0 ; à la
  demande du mainteneur, #388 ouvert (le nôtre), #368 fermé (ralentissement
  corrigé par #373). Le soir, boucle capturée en debug : journal `-v` et
  session pi, chemins de l'hôte masqués, dans un gist secret, lien en
  commentaire avec le mécanisme et la piste non vérifiée des pénalités
  (#332).
- Un tiers suggère `--think xhigh` (recommandé par Qwen pour le code) :
  écarté, le sujet étant alors la régression à réglage égal (`--think off`
  identique en 0.2.0, sans boucle), réponse publiée dans ce sens. Le tiers
  donne ses réglages (raisonnement xhigh, presence 0, 1 session), d'où
  l'essai de l'étape 2.
- **03/10/2026** : décompte de l'essai en `--presence-penalty 0.0` publié
  (0 boucle sur 20 séries contre 2 sur 9 en 1,5), avec journaux `-v`,
  sorties et sessions pi des 20 séries dans un gist secret (chemins de l'hôte masqués). Témoin
  0.2.0 : boucle en série 5 sur 5, pré-commentaire publié (le sujet devient
  le profil Qwen sans raisonnement, plus la version). Un collaborateur
  (francescobozzo) envisage de désactiver la pénalité sans raisonnement si
  d'autres preuves arrivent.
- **03/10/2026, commentaire final** : ticket renommé (« tool-call loop with
  the no-think profile (presence penalty 1.5), all versions ») ; décompte du
  témoin, chiffres corrigés, rejeu de la première correction (la pénalité à
  0 n'empêche pas la seconde valeur fausse), second gist secret (session en
  boucle de la 0.2.0, archive des 5 séries, requête et 300 réponses du
  rejeu) ; fermeture laissée au choix des mainteneurs.
- **03/10/2026** : résultats de la consigne côté pi publiés aussi, sans autre
  demande côté gufo. Le raisonnement faible n'est pas publié dans #388.
- **03/10/2026 à 15:14 UTC** : fermeture par francescobozzo, les mesures du
  raisonnement faible (étape 7) n'ayant pas été publiées avant.

### 1. Boucle capturée en debug (nuit du 02/10/2026)

Tout en debug (`-v`, sessions pi gardées), Flash-Next en 0.5.0, 2 sessions,
5 passes par série : deux rejeux sans boucle, puis une nuit de 10 séries au
plus arrêtée à la première boucle
(`resultats/agentic/2026-10-02-0.5.0/nuit/`), capturée en série 04, passe 4
de `creation` : 2 578 s, ~230 requêtes en plus, sortie seule (comme les
43 min de 0.4.0). `-v` ne l'empêche donc pas. Mécanisme lu dans la session
pi :

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
#332 (0.4.0). Affaiblie le soir même : le `--help` de la 0.2.0 décrit déjà
`--presence-penalty` comme « Generated-token presence penalty », la pénalité
ne voyait donc pas le prompt avant #332 non plus.

### 2. Essai en presence 0,0 (03/10/2026)

Même banc que la nuit du 02/10 (Flash-Next 0.5.0, `--think off`, 2 sessions,
5 passes, `-v`, sessions pi gardées), seule la macro `qwen` du yaml passée à
`--think off --presence-penalty 0.0` le temps du banc (`presence_penalty=0`
vérifié au journal, yaml restauré). Deux salves de 10 séries
(`resultats/agentic/2026-10-03-0.5.0-presence0/` et `-presence0-b/`) : 26/26
partout, 85 à 95 requêtes par série, aucune boucle.

Premier décompte des sessions pi `creation` gardées en 0.5.0, où le test
écrit par le modèle échoue sur une valeur attendue fausse (le plus souvent
`3 !== 4`), **tel que publié dans #388 ; périmètre et chiffres corrigés à
l'étape 4** :

| réglage | sessions | valeur attendue fausse | rattrapées | boucle |
|---|---|---|---|---|
| presence 1,5 (nuit du 02/10, deux rejeux debug) | 28 | 6 | 5 (5 à 7 appels d'outils) | 1 (234 appels) |
| presence 0,0 | 100 | 19 | 19 (5 à 8 appels d'outils) | 0 |

L'erreur de départ est aussi fréquente sans la pénalité (une session sur cinq
dans les deux cas) : c'est le rattrapage qui change. En 0,0 chaque session
fautive ne montre qu'une valeur d'assertion ratée ; en 1,5, 2 sur 6 en
montrent deux (`3 !== 4` puis `3 !== 5.5` pour la boucle, `3 !== 4` et
`1.5 !== 5.5` pour une session rattrapée en 7 appels). Limites : la boucle de
la 0.5.0 sans debug n'a pas de session gardée (hors tableau) ; l'essai ne dit
pas si la pénalité à 0 corrige la cause ou la masque, ni rien du cache ; et
la 0.2.0 n'avait que 2 séries en presence 1,5, ce qui ne suffisait pas à
établir qu'elle ne boucle pas (à 2 sur 9, deux séries propres arrivent par
hasard six fois sur dix).

### 3. Témoin 0.2.0 (03/10/2026)

Même banc sur l'image 0.2.0, yaml inchangé (`presence_penalty=1.5` au
journal), 20 séries au plus, arrêt à la première boucle
(`resultats/agentic/2026-10-03-0.2.0-temoin/`). Séries 01 et 02 à 83
requêtes, 03 à 134, 04 à 106, puis boucle en série 05 : 2 140 requêtes, pas
de sortie seule, coupée par le garde-temps d'une heure. **La 0.2.0 boucle
donc aussi : ce n'est pas une régression de la 0.4.0.**

### 4. Analyse des sessions et décompte corrigé (03/10/2026)

Analyse par un sous-agent, en lecture seule des journaux et sessions ; le
périmètre, la recopie identique et la copie de sessions ont été revérifiés à
la main, le reste est repris de son rapport.

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

### 5. Rejeu de la première correction (03/10/2026, gufo 0.2.0)

Mesure recommandée par l'analyse (`resultats/388-rejeu-2026-10-03/` :
`rejeu-correction.py`, `requete.json`, `reponses.jsonl`) : la requête qui
suit le premier `3 !== 4` de la session en boucle du témoin, avec l'enveloppe
exacte de pi (système, outils, paramètres, capturés par un relais local ; pi
n'envoie aucun paramètre d'échantillonnage), rejouée 100 fois par bras sur
gufo d'usage en 0.2.0, sans flux, bras alternés :

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

### 6. Consigne côté client (03/10/2026, gufo 0.5.0, presence 1,5)

Une phrase ajoutée au prompt système de pi (`prompts/pi-consigne-edit.txt`,
« Avant chaque appel d'outil qui modifie un fichier, écris une phrase courte
qui dit ce que tu vas changer et pourquoi. », passée par `PI_CONSIGNE`, pi la
place dans un bloc `<addendum>`). Elle coûte environ +50 % de temps par passe
sur ce banc (plus de texte, et plus de tests ratés au premier jet), contre
x2,3 pour `--think xhigh`. Non décidé : rien n'est posé dans la configuration
d'usage de pi, d'omp ni du proxy ; résultats publiés dans #388 le 03/10/2026.

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
  Médianes dans le tableau de l'étape 7.

### 7. Raisonnement faible (03/10/2026, gufo 0.5.0)

Idée de l'utilisateur. gufo l'accepte par requête : `reasoning_effort: "low"`
(ou `minimal`) active le raisonnement pour cette requête seule et bascule sur
le profil Qwen avec raisonnement
(`thinking=on temperature=1 presence_penalty=0` quand il est posé au
serveur). **Règle de l'utilisateur : le niveau de raisonnement se règle côté
client (pi, omp), au lancement ou par requête, jamais en modifiant la
configuration du serveur**, qui reste en `--think off`.

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

  | médianes, 0.5.0 | sans raisonnement ni consigne (7 séries sans boucle) | consigne pi (10 séries) | low au serveur (6 séries) | low par pi (1 série) |
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

## Release v0.5.0 (02/10/2026), retenue le 03/10/2026

Le ralentissement de #368 est corrigé, la boucle de répétition de Flash-Next
est toujours là. Choix du 02/10/2026 : 0.5.0 non retenue, `GUFO_IMAGE` reste
en 0.2.0. Le motif « boucle » de ce choix est tombé le 03/10/2026 (la 0.2.0
boucle aussi, témoin de la section « Ticket #388 »), d'où le **passage en
0.5.0 le 03/10/2026** (choix de l'utilisateur, version seule) : `GUFO_IMAGE`
épinglée en `gufo-runtime:0.5.0` dans `lib/gufo.sh`,
`runtime-gufo/download.sh` et `runtime-gufo/Dockerfile.routeur`, yaml
inchangé (`--think off`, profil Qwen de gufo, cache disque et staging).
Mesures de la 0.5.0 : celles du 02/10. Vérifié sur bigchuck après bascule :
`gufo version 0.5.0 (23cacbb)` dans le conteneur d'usage,
`presence_penalty=1.5` au journal, une requête avec `stop` ; voix,
transcription et image non revérifiées ce jour-là.

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
édition à graine fixe diffère des versions précédentes). Recommandations de
réglage : confrontation du 02/10, à la fin de cette entrée.

Banc d'abord (choix de l'utilisateur) : 0.5.0 passée par l'environnement
(`GUFO_IMAGE`) aux bancs seulement, rien d'épinglé, gufo d'usage réel resté
en 0.2.0. 27B et Flash-Next, DeepSeek non remesuré. Quatre séries
agentiques : 1 session avec cache disque (colonne v0.5.0 du second tableau),
1 session sans cache disque (`SANS_CACHE=1`, cache RAM seul), 2 sessions avec
cache disque, puis rejeu debug de Flash-Next en 2 sessions
(`DEBUG=1 PI_SESSIONS=1`). Journaux dans
`resultats/agentic/2026-10-02-0.5.0/` (`avec-cache/`, `sans-cache/`,
`sessions2/`, `rejeu-debug-s2/`). Même pi (0.87.0) que les mesures de 0.2.0
et 0.4.0.

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
  Reste ouvert après le passage en 0.5.0 (44,7 à 46,4 contre 50,4 t/s en
  0.2.0).

Commentaire publié sur #368 le 02/10/2026 avec ces chiffres ; à la demande du
mainteneur, la boucle est suivie dans un ticket à part,
[#388](https://github.com/gufo-org/gufo/issues/388), ouvert le jour même.

Confrontation des paramètres à la documentation amont :

- **02/10/2026, v0.5.0** (diff 0.4.0...0.5.0 de la documentation, `--help`
  0.2.0 et 0.5.0 comparés sur bigchuck) : une option ajoutée,
  `--cache-ram-bytes` (0 = automatique, au plus 32 Gio et la moitié de la RAM
  libre après chargement ; le budget RAM des instantanés existait déjà, il
  devient réglable ; non posée), aucun défaut changé. `docs/SERVER.md`
  précise que `--sessions` borne le pool d'exécution, plus le nombre de
  conversations retenues (128 points de reprise, indépendants de
  `--sessions`, #369), ce qui contredit la lecture de `docs/KV-CACHE.md` en
  0.4.0 (« le cache garde environ `--sessions` conversations ») ; nos 2
  sessions restent mesurées utiles (section « Release v0.5.0 »). Version non
  retenue le 02/10 (boucle de #368), retenue le 03/10/2026 sans changement de
  réglage.

## Release v0.4.0 (01/10/2026), non retenue

Montée faite (`7c98484`), remesurée le jour même sur le 27B et Flash-Next
(`runtime-gufo/bench/remesure.sh`, journaux dans
`resultats/agentic/2026-10-01-0.4.0/`, `avant/` = v0.2.0 du 29/09), puis
**annulée** (`b758eb7`, choix de l'utilisateur) : gufo d'usage réel revenu en
`gufo-runtime:0.2.0`. Motif : régression sur les requêtes avec outils et
boucle de 43 min sur Flash-Next. Ticket
[#368](https://github.com/gufo-org/gufo/issues/368) publié le jour même avec
ces chiffres et les fichiers (modèles et quants).

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

Lecture (colonnes v0.2.0 et v0.4.0 du second tableau) :

- Le banc HTTP est inchangé au bruit près, la régression ne touche que les
  requêtes avec outils, sur les deux modèles (20 à 40 % de temps en plus,
  acceptance en baisse).
- Passe 2 de `creation` sur Flash-Next : environ 1 600 requêtes presque
  identiques (14 à 15 tokens générés, prompt +241 tokens par tour), contexte
  monté à ~114k, compacté par pi, puis reparti, 43 min avant de finir en
  PASS ; la transcription pi n'est pas conservée par le banc, l'appel répété
  n'est pas connu.
- Au démarrage de Flash-Next, pendant ~45 s, chaque écriture de point de
  reprise prenait 2,1 à 2,7 s (0,1 à 0,2 s ensuite) et le prefill court
  tombait à 430-770 t/s (au lieu de ~1 300), pendant que les points de
  reprise v0.2.0 du cache disque étaient écartés.

Rejeu du même jour à la demande du mainteneur (fedeizzo) : gufo en `-v`
(`DEBUG=1`) et sessions pi gardées (`PI_SESSIONS=1`) dans
`runtime-gufo/bench/agentic.sh`, 5 passes, 0.4.0 puis 0.2.0, pi épinglé en
0.87.0 dans `bench-agentic/Dockerfile` (une reconstruction avait installé la
0.99.2) ; journaux dans `resultats/agentic/2026-10-01-debug-<version>/`.
26/26 partout, boucle de 43 min non reproduite, ralentissement reproduit :

| Rejeu debug | 27B v0.2.0 | 27B v0.4.0 | Flash-Next v0.2.0 | Flash-Next v0.4.0 |
|---|---|---|---|---|
| décode agentique (t/s) | 45,5 | 30,7 | 49,8 | 42,6 |
| acceptance du spéculatif (médiane) | 71,0 % | 49,3 % | 84,6 % | 70,2 % |
| `creation`, 5 passes (s) | 17,1 à 23,6 | 23,5 à 28,6 | 13,9 à 20,9 | 15,4 à 27,0 |
| `bugfix`, 5 passes (s) | 8,6 à 11,7 | 11,4 à 14,9 | 6,1 à 7,7 | 9,2 à 9,9 |

En 0.2.0, `-v` n'ajoute aucune ligne ; en 0.4.0, le debug montre l'admission
et les décisions du cache, rien sur le décodage contraint. Journaux des deux
séries et sessions pi (chemins de l'hôte masqués) publiés dans un gist secret,
lien en commentaire de #368 le 01/10/2026.

Confrontation des paramètres à la documentation amont :

- **01/10/2026, v0.4.0** (diff 0.2.0...0.4.0 et des deux `--help`) : une
  seule option ajoutée, `--log-level` (`-v` en devient le raccourci `debug`,
  `--log-progress` refusé en `warn`/`error`), aucun défaut changé ; la
  nouvelle `docs/KV-CACHE.md` confirme le staging (1 Gio sous un seul point
  de reprise du 27B à 24k tokens) et chiffre `--sessions` : le cache garde
  environ `--sessions` conversations, une de plus fait tomber la reprise
  d'environ 95 % à 0 %. Version non retenue (#368).

## Release v0.3.0 (30/09/2026)

Non montée. v0.3.0 (`fd1710b`, image `gufo-runtime:0.3.0`, aussi `latest`),
publiée le 30/09/2026. Contenu depuis v0.2.0 : une bannière de démarrage sur
les commandes interactives de la CLI (#323) et un lien vers les forks dans le
README (#327). Ni noyau, ni cache, ni serveur : image laissée épinglée sur
`gufo-runtime:0.2.0` (choix de l'utilisateur, 30/09/2026), pas de remesure.

## Tickets #259 et #267 : cache entre conversations (24/09 au 30/09/2026)

Suite du 03/10/2026 en tête de ce journal. Avant ce point d'étape, la ligne
#259 du tableau « À surveiller » portait : ouvert (le nôtre), résumé en tête
et dernier commentaire sur `--sessions` ; contournement : `--cache-disk` +
staging relevé.

Le préfixe commun de deux conversations différentes ne se reprend que par le
cache disque, et le staging par défaut refuse nos points de reprise ; d'où
`--cache-disk` et un staging de 8 Gio.

- **24/09/2026**, [#259](https://github.com/gufo-org/gufo/issues/259)
  ouvert : cache non réutilisé entre conversations au même préfixe. Corrigé
  par nos soins le même soir en deux commentaires : c'était en grande partie
  une configuration (`--cache-disk` absent, staging trop petit pour le 27B),
  chiffres agentiques à l'appui. Restent trois points pour gufo : limite de
  staging qui coupe en silence, préfixes partagés réservés au disque, période
  d'apprentissage. La reprise « un tour en retard » vue avec Claude Code
  vient du proxy (omp reprend depuis la RAM) : commentaire corrigé.
- **25/09**, réponse du mainteneur : journal quand une sauvegarde dépasse le
  staging, défaut de 512 Mio revu (idéalement déduit du modèle) et
  documentation de `--cache-disk` en une seule modification (points 1 à 3) ;
  `--sessions 2` documenté pour les clients agentiques ; préfixes partagés en
  RAM et apprentissage déplacés dans
  [#267](https://github.com/gufo-org/gufo/issues/267) ; identité du cache
  disque (nombre de sessions ?) à examiner. Notre réponse : prêts à rejouer
  la même boucle agentique sur les deux correctifs.
- **26/09**, point 1 corrigé par la PR #279 (d9a84f1 : staging automatique au
  plus petit de 1 Gio, 1/8 de la RAM disponible et de la rétention disque,
  rétention par défaut 8 Gio, instantanés refusés journalisés) ; point 2 :
  1 Gio, seuil fixe reconnu imparfait. Chez nous, au redémarrage sur cette
  image, 11 points de reprise Flash-Next réels de 1,39 à 1,50 Go refusés au
  défaut : staging gardé à 8 Gio, remesure agentique inchangée. Commentaire
  du 26/09 avec les refus et la remesure, suggestion d'un staging automatique
  déduit du modèle chargé.
- **26/09 au soir**, un utilisateur affirme que sur l'image
  `20260926T093925` la reprise d'un préfixe partagé marche **sans**
  `--cache-disk` (6,3 s ramenées à 0,1 s), mais en rejouant trois fois la
  même requête, pas une nouvelle conversation après une autre. Vérifié chez
  nous le 28/09 (section « Release v0.1.1 ») : faux pour une nouvelle
  conversation, 14 débuts recalculés sans disque. Commentaire publié le 28/09
  avec la remesure v0.1.1 (cache repris 92,9 / 92,6 %).
- **30/09**, le mainteneur confirme les quatre points sur f783fed (27B,
  `--sessions 4`) : au défaut, staging de 1 Gio contre des points de reprise
  de 1,85 Go à 24,5k tokens, **tous** refusés, cache disque inerte ; staging
  8 Gio : 24,9k tokens repris en 1,8 s contre ~50 s à froid ; préfixe commun
  repris seulement à partir de la 5e conversation ; `--sessions 1` : une
  requête annexe évince la conversation (0,23 s à 5,3 s) ; le manque est le
  niveau RAM (suite dans #331) ; aucun correctif annoncé.

## Release v0.2.0 (29/09/2026)

Retenue : image épinglée sur `gufo-runtime:0.2.0`. Rien ne bouge au-delà du
bruit sur le 27B et Flash-Next ; nos valeurs d'échantillonnage deviennent le
défaut de gufo ; DeepSeek, qui raisonne désormais par défaut, est remis en
`--think off` après mesure.

v0.2.0 (`992113b`), publiée le 29/09/2026. Contenu depuis v0.1.1 :

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

Lecture (colonne 0.2.0 contre 0.1.1). Journaux bruts dans
`GUFO_DATA/resultats/agentic/2026-09-29-0.2.0/` (`avant/` y garde la boucle
sans cache disque du 28/09, pas la boucle avec cache, comparée ici à la
section v0.1.1) :

- Rien ne bouge au-delà du bruit, ce qu'attend une release qui ne touche ni
  les noyaux ni le cache. `mesure.py` fixe la température de chaque requête
  (0 ou 0,7, comme avant) ; `bench-agentic/` n'en fixe aucune pour pi, qui
  reçoit donc, sauf valeur propre à pi, le profil sans raisonnement de gufo,
  identique à notre ancienne macro.
- Les passes agentiques restent dominées par le scénario `stats.js` (27B :
  17,7 à 28,1 s selon la passe, l'agent y corrige parfois son propre test) :
  écart de médiane de 1 s, dans la variation d'une passe à l'autre.
- Aucun point de reprise refusé, le staging de 8 Gio tient toujours.

**DeepSeek**, remesuré le même jour à la demande de l'utilisateur
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

Confrontation des paramètres à la documentation amont :

- **29/09/2026, v0.2.0** (diff 0.1.1...0.2.0 et des deux `--help`) :
  échantillonnage et raisonnement par défaut changés (#282), nos valeurs Qwen
  explicites retirées (identiques au profil sans raisonnement), macro
  DeepSeek retirée ; aucune option ajoutée ou retirée, cache disque et
  staging inchangés.

## Ticket #272 : GPU occupé à 100 % au repos (25/09 au 29/09/2026)

Corrigé en v0.2.0 par #317 ; de notre contournement, seul `ttl: 60` reste
(section « Release v0.2.0 »). Publié le 25/09/2026 :

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

**Les trois questions du mainteneur (28/09/2026).** Mesuré sur gufo 0.1.1,
Flash-Next résident (2 sessions), serveurs audio
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

**Test de la PR #317 (28/09/2026).** PR
[#317](https://github.com/gufo-org/gufo/pull/317) (fedeizzo, commit
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

## Release v0.1.1 (28/09/2026)

Retenue, première image épinglée. Le gain est dans le cache, pas dans le
moteur, et le cache disque reste indispensable.

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
- **Suivi en amont par un script**, `tools/gufo-amont.sh`, et **PR #299
  suivie** (Qwen3.6-35B-A3B, l'architecture d'Ornith) : tableau
  « À surveiller ».
- **DeepSeek non remesuré** (choix de l'utilisateur) : seuls le 27B (fichiers
  identiques au service) et Flash-Next sont rejoués.
- **Remesure** : banc HTTP (`run.sh gufo 27b flashnext`), boucle agentique
  avec cache disque (réglage d'usage), puis la même boucle **sans** cache
  disque, pour vérifier dans notre scénario l'affirmation de #259 (reprise
  des préfixes partagés sans disque). Journaux bruts dans
  `GUFO_DATA/resultats/agentic/2026-09-28-0.1.1/` (`avant/` garde ceux du
  26/09).

Lecture (colonne 0.1.1 contre 26/09) :

- Un tiers de tokens recalculés en moins et un prefill agentique divisé par
  1,6 à 2, conformes à #281 (point de reprise avant la réponse de
  l'assistant, y compris en `--think off`) et #301. Le 27B y gagne 6 % de
  temps ; sur Flash-Next, les 12 s de prefill gagnées sur tout le run
  disparaissent dans la variation du décode d'une passe à l'autre (création
  de 15,0 à 21,5 s selon la passe, temp 0,7).
- Second point de reprise par requête (#281) : 61 écritures au lieu de 36
  sur le 27B, aucune refusée, le staging de 8 Gio tient.
- Prefill à prompt court de Flash-Next en baisse de 9,5 % (27B : -6 %),
  inchangé à 52k : un coût fixe d'environ 0,1 s par requête neuve.
  L'instantané du point de reprise n'en explique qu'une partie (24 à 44 ms
  par requête, `cache_snapshot_ms` des `timings`, mesuré le même jour).
  Invisible en agentique, où les petites requêtes répondent au contraire
  plus vite.
- Le gain de #292 annoncé par gufo (décode sans spéculatif +6,7 % à 32k)
  n'est pas mesuré par ce banc (décode à contexte court, MTP actif).

Même boucle **sans** cache disque (macro sans `--cache-disk`, le temps du
run) :

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
marchait déjà. Configuration inchangée.

Confrontation des paramètres à la documentation amont :

- **28/09/2026, v0.1.1** (diff de la documentation d9a84f1...v0.1.1 et des
  deux `--help`) : aucune recommandation de réglage nouvelle, défauts du
  cache disque inchangés (8 Gio, staging automatique au plus 1 Gio), une
  seule option ajoutée, `--log-progress` (journal de progression du prefill
  et du décode, diagnostic seulement, non posée). Trois points de
  `docs/SERVER.md` nous touchent sans rien changer à la configuration : le
  point de reprise Qwen avant la réponse de l'assistant vaut désormais avec
  la réflexion coupée (notre `--think off`), un second point sur le prompt
  entier est pris sur le même budget d'instantanés (à surveiller : refus de
  staging ou rétention qui tourne plus vite), et le prompt rendu est borné à
  128 octets par token de contexte (32 Mio à 262 144, une raison de plus de
  garder `--context` explicite). `/v1/models` de gufo publie désormais
  `context_length`, mais llama-swap sert sa propre liste :
  `capabilities.context` reste nécessaire.

## Image du 26/09/2026 (d9a84f1)

Prefill court de Flash-Next +5 % (#255), décode en prose du 27B en baisse
avec l'acceptance, à confirmer avant d'y voir une régression ; le staging
automatique de #279 ne suffit pas, 8 Gio gardés.

Image `gufo-runtime:latest` republiée le 26/09/2026 (`20260926T093925`,
`sha256:09507c0…`, commit d9a84f1 ou plus récent) : contient #255, #257, #260
et #279, déployée sur bigchuck le même jour (`stop` vérifié en OpenAI et en
Anthropic, jusqu'au proxy). Staging automatique de #279 (1 Gio) : les 11
refus décrits au ticket #259. Rétention passée au défaut de 8 Gio pour la
remesure, puis remise à 16 Gio le même jour, et `--max-tokens 32768` retiré
(défaut -1 de #276) : voir « Paramètres de gufo et leur origine ». Remesure
du 27B et de Flash-Next seulement, mêmes bancs, contre la référence du
24/09 :

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

Confrontation des paramètres à la documentation amont :

- **26/09/2026** : `docs/SERVER.md` et guides des modèles de gufo (commit
  d9a84f1), `gufo serve llm --help` de l'image déployée.

## Routeur llama-swap, audio et image (25/09/2026)

Mise en place décrite dans `docs/GUFO.md` (« Routeur », « Audio et image ») ;
ici les mesures du jour et l'essai de la variante heretic.

| Mesure du 25/09/2026, bigchuck | Résultat |
|---|---|
| Relais par llama-swap | sans coût : décode vu du client 47,4 t/s contre 47,6 mesurés par gufo |
| Bascule Flash-Next vers 27B (arrêt de l'un, chargement de l'autre) | 64,6 s avant le premier token |
| Bascule 27B vers Flash-Next | 31,4 s |
| Bascule Flash-Next vers DeepSeek (IQ2XXS) | 70,4 s, réponse juste ; sans raisonnement par défaut (le gabarit d'antirez répond directement, là où la section du service raisonne avec un budget de 6 144 tokens) |
| Modèle déjà chargé | premier token en 0,3 s |
| Requête avec `stop` | acceptée ; retiré par llama-swap jusqu'au 26/09/2026, transmis depuis (gufo#260 corrigé, arrêt vérifié en OpenAI et en Anthropic) |
| Mémoire | un seul modèle chargé à la fois (99 Gio avec Flash-Next) |

| Mesure du 25/09/2026, bigchuck (Flash-Next préchargé) | Résultat |
|---|---|
| Synthèse (CustomVoice, voix intégrée « aiden ») | 6,5 s d'audio en 2,6 s, soit 2,5 fois le temps réel ; chargement quasi nul (2,9 s au premier appel) |
| Transcription du WAV produit | 3,2 s chargement compris ; texte fidèle, noms propres approximés (« Big Jack », « Guffaw », « Lama Swap ») |
| Flash-Next + voix + transcription chargés ensemble | 110 Gio utilisés, 14 Gio libres ; Flash-Next répond toujours en 0,4 s |
| Image 512², 20 étapes | 16,3 s, bascule depuis Flash-Next comprise |
| Image 1024², 40 étapes (défaut) | 90,2 s, image conforme à la demande |
| Retour à Flash-Next après une image | 38,0 s ; voix et transcription restées chargées |

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

## Évaluation face au service (24/09/2026)

Résumé, tel qu'il figurait dans `docs/HISTORIQUE.md` jusqu'à la création de
ce journal. Évaluation de gufo (moteur HIP spécialisé Strix Halo, MIT, commit
`9cad139`) sur ses trois modèles de texte, tous dans le parc, contre l'image
`llm-rocm-strix`, série `strix-8c1c282+r7dda3ac`. `docs/HISTORIQUE.md` disait
« v0.1.0, commit `9cad139` » ; `docs/GUFO.md` précise que cette mesure
précède toute release, la v0.1.0 (`06ed62f`) n'étant publiée que le
28/09/2026.

- Banc HTTP, 27B à fichiers identiques : prefill 547 contre 263 t/s (+108 %),
  décode 48,9 contre 35,7 (+37 %). Flash-Next et DeepSeek sur des quants
  différentes (gufo refuse les nôtres) : prefill +69 % et +212 %.
- Boucle agentique pi, 16/16 partout. Première série, gufo sans cache
  disque : 27B 56 contre 57 s par passe, Flash-Next 39 contre 44 s, DeepSeek
  90 contre 116 s ; sans `--cache-disk`, gufo ne reprend pas le préfixe commun
  d'une nouvelle conversation (14 ratés sur 16). Seconde série avec
  `--cache-disk` et `--cache-disk-staging-bytes` relevé (le défaut de 512 Mio
  coupe en silence les points de reprise du 27B dès 4k tokens) : 27B **40**
  contre 57 s, Flash-Next **31** contre 44 s, soit 30 % de temps en moins,
  90 % du prompt repris.
- Verdict : gufo bat le service en agentique une fois configuré, mais ne le
  remplace pas (quants imposées, un modèle par processus, pas de n-gram).
  Issue amont [#259](https://github.com/gufo-org/gufo/issues/259) ouverte puis
  corrigée par nos soins (configuration). Banc (`runtime-gufo/`, piloté par
  `./setup-llm.sh --gufo`) et GGUF de référence conservés sur bigchuck dans
  `~/llm/gufo-test`.

Le 24/09, rien n'était intégré au dépôt ; pilotage et bancs ont été
versionnés ensuite dans `runtime-gufo/`.

### Protocole

- Service arrêté pendant chaque passage gufo (`--stop`, relancé par trap
  `--start`), jamais deux moteurs à la fois sur le GPU.
- Gufo : `gufo serve llm --context 262144 --sessions 1`, spéculatif du
  modèle (`dflash2`, `mtp` avec tête shared Q8_0 et mmproj, `dspark`).
  Service : sections de production, `models.ini` inchangé.
- Banc HTTP (`mesure.py`) : mêmes requêtes aux deux moteurs, en streaming,
  débits à l'horloge du client recoupés avec les `timings` des moteurs.
  Justesse (prompt de `--bench-sanity`), conditions du `--bench` (contexte +
  tâche, 1 000 tokens, temp 0,7, seed 42+i, 3 passes), `spec-refactor`
  (1 500 tokens, 3 passes), prefill avec aiguille à 6,5k et 52k tokens (42k et
  5,3k sur DeepSeek, autre tokenizer), reprise de cache au tour 2 sur 32k.
  Préfixe aléatoire par requête : aucune reprise de cache entre passes.
- Boucle agentique (`agentic.sh`) : scénarios de `bench-agentic/` (même image
  pi, même `scenarios.sh`), 3 passes + appel froid, sur l'un ou l'autre
  moteur ; rien écrit dans `logs/bench-agentic.log`. Pour gufo,
  l'échantillonnage de la section est reporté en défauts serveur (Qwen : temp
  0,7, top-k 20, top-p 0,8, presence-penalty 1,5, `--think off` ; DeepSeek :
  temp 1,0, top-k 40, top-p 0,95) ; cache, prefill et décode relus dans son
  journal, requête par requête.
- Seconde série agentique (27B et Flash-Next), le soir du 24/09 : gufo lancé
  par `serve-8009.sh` (remplacé depuis par `./setup-llm.sh --gufo`) sur le
  port du service, avec `--cache-disk` et
  `--cache-disk-staging-bytes 8589934592` (voir « Le cache »), même conteneur
  pi pointé sur `:8009`.

### Banc HTTP (médianes, gufo contre service)

| Modèle | prefill, prompt court (t/s) | prefill long (t/s) | décode, prose (t/s) | décode, code (t/s) | justesse | mémoire |
|---|---|---|---|---|---|---|
| **Qwen3.8-27B** (dense, mêmes fichiers UD-Q4_K_XL + DFlash 2 Q8_0) | 547 contre 263, soit **+108 %** | 502 contre 213 à 52k, soit **+136 %** | 48,9 contre 35,7, soit **+37 %** | 65,9 contre 52,4, soit **+26 %** | OK / OK | 44 contre 54 Gio |
| **Flash-Next** (MoE ; gufo UD-Q4_K_XL unsloth, service AP-Q4_K_XL Signal) | 1 391 contre 825, soit **+69 %** | 1 363 contre 964 à 52k, soit **+41 %** | non comparable (voir ci-dessous) | 61,6 contre 88,7, soit **-31 %** | OK / OK | 97 contre 106 Gio |
| **DeepSeek V4 Flash** (MoE ; gufo IQ2XXS antirez 87 Go, service UD-IQ3_XXS 104 Go) | 402 contre 129, soit **+212 %** | 457 contre 88 à 42k, soit **+419 %** | 34,1 contre 31,0, soit **+10 %** | 38,3 contre 33,5, soit **+14 %** | **KO** gufo (comptage à 26k : 1 au lieu de 8) / OK | 104 contre 119 Gio |

- Seul le 27B compare deux moteurs à fichiers identiques ; les lignes
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
- Reprise de cache au tour 2 d'une même conversation : 100 % partout.
- Chargement gufo : 10 à 32 s (32 s à froid pour le 27B, 20 s pour
  Flash-Next et DeepSeek). Mémoire : relevé `free` global, approximatif.
- Le « KO » DeepSeek n'est arrivé qu'une fois, sur une seule mesure : quant
  IQ2XXS ou moteur, non tranché.

#### Variante large-ub du service (Flash-Next, section `-large-ub`)

| Flash-Next, banc HTTP | gufo (UD-Q4_K_XL) | service ub 4096 | service ub 16384 |
|---|---|---|---|
| prefill, prompt court | **1 391** | 825 | 827 |
| prefill à 6,5k | **1 380** | 991 | 1 062 |
| prefill à 32,5k | **1 388** | 980 | 1 097 |
| prefill à 52k | **1 363** | 964 | 1 072 |
| décode code (3 passes) | 61,7 / 61,8 / 59,0 | 59,5 / 88,7 / 107,9 | 97,0 / 108,2 / 97,4 |
| mémoire utilisée | **97 Gio** | 106 Gio | 116 Gio |

Le grand micro-lot gagne 7 à 12 % de prefill dès 6,5k tokens et coûte 10 Gio.
Son décode à 97 t/s dès la première passe vient de l'instance qui sortait de
la boucle agentique (pool `ngram-mod` déjà rempli), pas du micro-lot.

### Boucle agentique (pi, 3 passes, médianes)

16/16 partout, sur les deux moteurs, les trois modèles et les deux séries.
La seconde série, le soir même, corrige la première : sans `--cache-disk`,
gufo ne reprend pas le préfixe commun de deux conversations, ce qui le
faisait paraître à égalité avec le service.

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

- Débits agentiques à lire avec prudence : le prefill « réel » est une
  moyenne dominée par de minuscules morceaux, presque tout venant du cache.
  Gufo sur Flash-Next (cache disque) : 37 requêtes de moins de 100 tokens
  recalculés à 131 t/s en moyenne (le coût fixe de la requête domine), 9 de
  100 à 499 tokens à 470 t/s, 3 de 500 à 1 999 tokens à 1 172 t/s. Le temps
  passé en prefill (16 s sur tout le run) dit plus que le débit moyen.
- Le décode de Flash-Next (51 t/s) est son régime normal (parc : 46,7 au
  `--bench`) ; le 27B dense s'en approche (46 t/s) grâce aux blocs de 7
  tokens de DFlash 2, bien acceptés sur du code.
- Identité des modèles vérifiée à chaque passage (fichier chargé par gufo,
  modèle demandé par pi) ; appel froid de 1 542 tokens côté service à 597 t/s
  sur Flash-Next contre 295 sur le 27B, le rapport attendu.
- Appel froid non comparable : côté service, il comprend le chargement du
  modèle à la demande (9,7 s, 21,6 s, 86 s), gufo étant déjà chargé.
- Sur DeepSeek, le service a généré 20 % de tokens en plus (6,7k contre
  5,6k) : raisonnement sans doute réglé autrement (budget côté service,
  défaut du template côté gufo).

#### Le cache : la configuration compte

- Dans une même conversation, gufo reprend le prompt dès la configuration par
  défaut (94 % sur le 27B dans la première série).
- Le préfixe commun de deux conversations différentes (même prompt système,
  nouveau message) ne se reprend **qu'avec `--cache-disk`** : le disque garde
  les points de reprise des préfixes partagés (au plus 4 par prompt,
  128 tokens minimum). Sans lui, première série : 14 débuts de conversation sur
  16 recalculés en entier (`prefix_changed`, 1 508 à 1 517 tokens communs, 0
  repris), même un prompt identique dès qu'une autre conversation s'est
  intercalée.
- Piège du 27B : un point de reprise pèse environ 165 Mo plus 0,1 Mo par token
  (575 Mo à 5k tokens), au-delà du `--cache-disk-staging-bytes` par défaut de
  512 Mio dès 4k tokens environ. Gufo renonce alors à l'écrire, sans le
  signaler dans son journal. Flash-Next (170 à 190 Mo) et DeepSeek (45 à
  57 Mo) restent loin de la limite aux tailles de prompt de pi.
- Période d'apprentissage : le point de reprise du préfixe apparaît à la 3e
  conversation qui le partage, et sert à partir de la 4e ou 5e. Sur un prompt
  système de 5k tokens : premier token en 8,5 à 9,1 s, puis 0,66 à 0,74 s
  (5 045 tokens repris du disque).
- Avec cette configuration, seconde série : 12 requêtes servies par le disque,
  34 par la RAM, 3 ratés (l'apprentissage), soit 90 à 91 % du prompt repris,
  autant ou plus que le service.
- Pourquoi c'est décisif : en agentique, quand le cache marche, le prefill ne
  pèse qu'une petite part du temps (29 s sur 168 pour le service sur le 27B),
  et c'est le décode qui départage. Le prefill ×2 de gufo ne compte vraiment
  que sur les prompts neufs (document collé, première requête d'une session).

### Sessions réelles (Claude Code via le proxy, omp, pi, 24/09/2026 au soir)

Trois clients sur le même gufo (Flash-Next sur `:8009`, cache disque) ; la
session Claude Code d'origine dure cinq minutes d'usage réel. Le cache
reprend 86 à 93 % du prompt partout ; la reprise « un tour en retard » de
Claude Code venait du proxy, pas de gufo. Aucune session équivalente n'a été
jouée sur le service : pas de comparaison directe pour cet usage.

| Session réelle | Claude Code via le proxy | Claude Code, proxy corrigé | omp (direct) | pi (direct) |
|---|---|---|---|---|
| Tours, contexte | 42, de 19,5k à 61,2k tokens | 12, de 19,5k à 28,7k | 9, de 22,1k à 34,1k | 16, de 3,1k à 22,0k |
| Reprise | disque, avant-dernier tour | RAM, tour précédent | RAM, tour précédent | RAM, tour précédent |
| Prompt repris | 92,7 % | 90,5 % | 86,2 % | 91,0 % |
| Tokens recalculés deux fois | 64k sur 125k tokens | 7 sur 28k | 40 tokens sur 34k | 7 sur 19k |
| Premier tour (prompt système) | 16,7 s | 15,4 s | 16,8 s (22k tokens) | 2,4 s (3,1k tokens) |
| Premier token ensuite, médiane | 2,7 s (5,4 s pour 90 % des tours) | **0,5 s** | 1,0 s (0,5 à 3,9 s) | 0,8 s (0,3 à 3,0) |
| Attente cumulée / génération | 150 s / 122 s | 26 / 56 s | 28 s / 83 s | 18 / 97 s |
| Décode, médiane | 53 t/s (acceptance MTP 85 %, sans baisse avec le contexte) | 46 t/s | 40 t/s | 50 t/s |
| Requêtes rejetées | 6 requêtes sur 50 (`stop`) | 0 | 0 | 0 |

- **Reprise par le proxy** : chaque tour repartait du point de reprise de
  l'avant-dernier tour, toutes les reprises venant du disque (1,4 s minimum
  par tour) ; omp (OpenAI en direct, sans proxy) reprend le tour précédent
  entier depuis la RAM. Cause, dans llm-proxy : un rappel `system` de Claude
  Code (`<total_tokens>…`) qui fermait la requête était reporté, au tour
  suivant, après le résultat d'outil d'après, donc le préfixe divergeait
  juste avant la dernière génération. Corrigé (commit du 24/09/2026, rappel
  gardé à sa place) : sur le même scénario, tours de suivi repris en RAM,
  43 à 150 tokens recalculés au lieu de 1 800 à 1 960, premier token en 0,3 à
  0,5 s au lieu de 1,8 à 2,1 s.
- **Rejets `unsupported_field`** : le proxy traduit les `stop_sequences`
  Anthropic en `stop`, que gufo refusait (reproduit, issue
  [#260](https://github.com/gufo-org/gufo/issues/260)). Le proxy a retiré
  `stop` pour gufo (option `anthropic_drop_fields`) jusqu'à la correction de
  #260 : option supprimée le 26/09/2026 (commit 588776f du proxy).
- **`--sessions`** : en `--sessions 1`, une requête annexe de Claude Code
  (titre, 770 tokens) prend la place de la conversation en RAM, et le tour
  suivant repart du disque (2,3 s au lieu d'environ 0,5 s). En `--sessions 2`
  (défaut de `./setup-llm.sh --gufo`), la seconde session coûte 7 Gio sur
  Flash-Next (100,4 Gio de GPU contre 93,4, 26,7 Gio de RAM encore libres) et
  règle le problème : même scénario, 11 tours de suivi sur 11 repris depuis
  la RAM, aucun depuis le disque, y compris après une requête annexe de
  29,8k tokens ; une petite requête annexe tourne en parallèle du tour
  principal (`batch_width=2`) ; décode inchangé (46 t/s).
- Changer la configuration du serveur vide le cache disque (le prompt
  système de Claude Code repart en `no_checkpoint`) : la fixer une fois pour
  toutes.

### Récupérer ses optimisations dans le service

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

### Ticket #239 : n-gram

[#239](https://github.com/gufo-org/gufo/issues/239) : deux commentaires de
notre part le 24/09/2026. Le même jour, un contributeur y a publié un
résultat négatif : recherche dans le prompt en complément de la MTP, greedy,
+0,2 à 1,1 % seulement (la MTP accepte déjà 92 % en greedy). Notre réponse :
mesure en temp 0,7 et gain lié à un pool persistant, donc conception
différente, à suivre dans un ticket séparé.

## Mesures d'une version à l'autre

Deux tableaux portent les remesures du 27B et de Flash-Next ; les sections
des releases en donnent la lecture (DeepSeek : « Release v0.2.0 »). Débits du
banc HTTP à l'horloge du client, médianes des trois passes ; agentique relu
dans le journal de gufo, requête par requête, 1 session, cache disque. Case
vide : valeur non relevée pour ce modèle.

Premier tableau : 24/09 = référence gufo `9cad139` (agentique de la seconde
série) ; 26/09 = `d9a84f1`, staging 8 Gio, rétention 8 Gio ; 0.1.1 =
`b0f8673`, le 28/09, staging 8 Gio, rétention 16 Gio ; 0.2.0 = `992113b`, le
29/09, mêmes réglages de cache.

| Mesure | 27B 24/09 | 27B 26/09 | 27B 0.1.1 | 27B 0.2.0 | Flash-Next 24/09 | Flash-Next 26/09 | Flash-Next 0.1.1 | Flash-Next 0.2.0 |
|---|---|---|---|---|---|---|---|---|
| prefill, prompt court (t/s) | 547 | 560 | 524 | 528 | 1 391 | 1 462 | 1 307 | 1 300 |
| prefill à 6,5k (t/s) | | | 585 | 594 | 1 380 | 1 411 | 1 381 | 1 399 |
| prefill à 52k (t/s) | 502 | 506 | 505 | 508 | 1 363 | 1 379 | 1 379 | 1 395 |
| décode, prose (t/s) | 48,9 | 43,7 | 47,2 | 44,1 | | | | |
| décode, code (t/s) | 65,9 | 66,1 | 65,5 | 66,3 | 61,6 | 61,8 | 62,2 | 61,4 |
| mémoire (relevé `free`) | 44 Gio | | 52 Gio | 53 Gio | 97 Gio | | 95 Gio | 97 Gio |
| boucle agentique, médiane par passe | 40 s | 41,3 s | **38,8 s** | 40,0 s | 31 s | 29,9 s | 30,4 s | 31,4 s |
| prompt repris | 90 % | 90,2 % | **92,9 %** | 92,7 % | 91 % | 88,8 % | **92,6 %** | 92,2 % |
| reprises RAM / disque / ratés | | 34 / 12 / 3 | 35 / 12 / 3 | 36 / 12 / 3 | | 34 / 11 / 4 | 36 / 12 / 3 | 34 / 12 / 3 |
| tokens recalculés, tout le run | | 8,4k | **6,2k** | 6,6k | | 9,4k | **6,6k** | 6,6k |
| temps en prefill / décode, tout le run | 28 / 90 s | 28 / 94 s | **17** / 95 s | 18 / 98 s | 16 / 71 s | 23 / 78 s | **11** / 79 s | 11 / 78 s |
| premier token, requêtes de moins de 100 tokens recalculés (médiane) | | 346 ms | **212 ms** | 210 ms | | 236 ms | **172 ms** | 164 ms |
| acceptance du spéculatif (réponses de plus de 20 tokens) | | 71,0 % | 71,4 % | 69,9 % | | 86,5 % | 85,7 % | 84,6 % |
| points de reprise écrits / refusés par le staging | | 36 / 0 | 61 / 0 | 58 / 0 | | | 42 / 0 | 44 / 0 |

- Dans toutes les colonnes : boucle agentique 16/16, justesse et aiguilles
  OK, cache au tour 2 à 100 % ; décode en prose de Flash-Next non mesurable
  (arrêt avant 200 tokens).
- 26/09 contre 24/09 : décode en prose du 27B à -11 % (acceptance DFlash 64,6
  à 69,7 % contre 68,6 à 71,2 %), décode du code inchangé (acceptance 97 à
  98 %), prefill court de Flash-Next à +5 %.
- 0.1.1 contre 26/09 : prefill court de Flash-Next à **-9,5 %** (premier
  token 1,05 s contre 0,95) ; décode en prose du 27B : acceptance à
  surveiller, voir 26/09.
- 0.2.0 : passes du décode en prose du 27B de 43,6 à 50,3.
- Écarts de report entre les tableaux d'origine, non tranchés : la remesure
  du 26/09 citait pour le 27B du 24/09 un prefill court de 548, une prose de
  49,0 et un code de 65,8 (547, 48,9 et 65,9 au banc du 24/09) ; la remesure
  de la 0.1.1 citait 1 444 pour le prefill court de Flash-Next du 26/09
  (1 462 dans la remesure du 26/09), et c'est contre 1 444 qu'est calculé le
  -9,5 %.

Second tableau : 0.2.0 (29/09), 0.4.0 (01/10), 0.5.0 (02/10) et 0.7.0
(04/10), boucle
agentique en 1 session avec cache disque, même pi 0.87.0
pour les quatre mesures (image du 22/09 pour la 0.2.0 et la 0.4.0). Dans les huit colonnes : 16/16, justesse (sanity,
aiguilles 4k et 52k) OK, tour 2 sur 32k repris à 100 %.
Neuvième colonne : 0.7.1 (05/10), Flash-Next seul (27B non remesuré), mêmes
conditions et mêmes constats.
Dixième colonne : 0.8.0 (05/10 après-midi), Flash-Next seul, mêmes constats ;
sa boucle agentique part d'un cache disque déjà peuplé par la série du matin
(voir « Release v0.8.0 »), reprise et temps non comparables aux autres
colonnes.
Onzième colonne : 0.8.1 (06/10), Flash-Next seul, première des deux séries
du jour ; à l'inverse de la 0.8.0, elle part d'un cache disque inutilisable
(préfixe changé par #441, voir « Release v0.8.1 »).
Douzième colonne : 0.9.0 (07/10), Flash-Next seul, première des deux séries
du jour, elle aussi sur un cache disque presque inutilisable (voir « Release
v0.9.0 »).

| Mesure | 27B v0.2.0 | 27B v0.4.0 | 27B v0.5.0 | 27B v0.7.0 | Flash-Next v0.2.0 | Flash-Next v0.4.0 | Flash-Next v0.5.0 | Flash-Next v0.7.0 | Flash-Next v0.7.1 | Flash-Next v0.8.0 | Flash-Next v0.8.1 | Flash-Next v0.9.0 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| prefill 52k (t/s) | 508,3 | 504,6 | 499,8 | 501,7 | 1 395,5 | 1 370,5 | 1 361,0 | 1 364,6 | 1 439,9 | 1 432,0 | 1 406,2 | 1 424,1 |
| décode code, banc HTTP (t/s) | ~66 | ~65 | ~66 | ~66 | ~61 | ~61 | 55 à 62 | 60 à 63 | 65 à 68 | 66 à 69 | 67 à 69 | 66 à 68 |
| tour 2 sur 32k en cache (t/s) | 107,4 | 107,1 | | | 151,2 | 160,4 | | | | |  |  |
| `creation`, passes 1/2/3 (s) | 18,5 / 17,7 / 28,1 | 25,1 / 22,8 / 33,1 | 21,5 / 21,1 / 26,1 | 22,8 / 18,4 / 17,6 | 16,4 / 15,3 / 17,7 | 23,1 / **2 563,7** / 19,5 | 16,9 / 24,4 / 17,3 | 17,5 / 22,2 / 22,7 | 16,3 / 20,4 / 21,3 | 15,1 / 13,9 / 15,5 | 15,5 / 14,5 / 12,8 | 23,0 / 20,9 / 14,0 |
| `bugfix`, passes 1/2/3 (s) | 9,6 / 8,9 / 8,8 | 12,3 / 11,4 / 12,8 | 9,4 / 10,0 / 9,7 | 9,8 / 9,1 / 10,6 | 7,7 / 7,1 / 6,3 | 9,7 / 12,4 / 10,8 | 7,5 / 6,8 / 7,4 | 7,2 / 6,6 / 7,2 | 7,1 / 5,6 / 5,4 | 6,8 / 6,0 / 6,5 | 6,5 / 6,5 / 6,1 | 6,6 / 6,6 / 5,4 |
| requêtes agentiques | 51 | 54 | 51 | 49 | 49 | 1 645 | 51 | 53 | 53 | 49 | 49 | 53 |
| décode agentique (t/s) | 43,9 | 30,5 | 42,3 | 42,5 | 50,4 | 27,8 (boucle comprise) | 44,7 | 48,1 | 50,7 | 51,0 | 52,4 | 51,1 |
| acceptance du spéculatif (médiane) | 69,9 % | 50,7 % | 71,0 % | 71,8 % | 84,6 % | 60,0 % | 85,7 % | 85,7 % | 84,8 % | 84,6 % | 85,7 % | 84,6 % |
| prompt repris du cache | 92,7 % | 90,4 % | 93,2 % | 93,6 % | 92,2 % | 99,2 % | 93,3 % | 93,1 % | 93,8 % | 98,7 % (cache disque déjà peuplé) | 91,2 % (points de reprise disque de la 0.8.0 inutilisables) | 93,1 % (une seule reprise disque sur le cache de la 0.8.1) |
| reprises disque / RAM | 12 / 36 | 12 / 39 | 2 / 46 | 1 / 45 | 12 / 34 | 10 / 1 623 | 2 / 46 | 1 / 49 | 1 / 49 | 3 / 46 | 0 / 45 | 1 / 49 |
| points de reprise disque écrits | 58 | 37 | 3 (82 sautés, `min_step`) | 3 (75 sautés, `min_step`) | 44 | 1 355 | 3 (67 sautés, `min_step`) | 3 (80 sautés, `min_step`) | 3 (66 sautés, `min_step`) | 0 (72 sautés, `min_step`) | 4 (61 sautés, `min_step`) | 3 (74 sautés, `min_step`) |
| points de reprise refusés (staging) | 0 | 0 | | 0 | 0 | 296 | | 0 | 0 | 0 | 0 | 0 |
