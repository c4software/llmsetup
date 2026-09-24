# gufo : évaluation du 24/09/2026

Évaluation de [gufo](https://github.com/gufo-org/gufo), moteur d'inférence
spécialisé Strix Halo, face au moteur du service (image `llm-rocm-strix`,
série `strix-8c1c282+r7dda3ac`). Rien n'a été intégré au dépôt : ce document
garde les mesures, le verdict et ce qu'il faut surveiller pour y revenir.
Tout le banc et les fichiers sont conservés sur bigchuck (voir « Reprendre les
mesures »).

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

## Banc HTTP (médianes, gufo contre service)

| Modèle | prefill, prompt court (t/s) | prefill long (t/s) | décode, prose (t/s) | décode, code (t/s) | justesse | mémoire |
|---|---|---|---|---|---|---|
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

16/16 partout, sur les deux moteurs et les trois modèles.

| Suite complète, par passe | gufo | service | écart |
|---|---|---|---|
| **Qwen3.8-27B** (mêmes fichiers) | 56 s | 57 s | **+2 %** |
| **Flash-Next** (quants différentes) | 39 s | 44 s (46 s en large-ub) | **+13 %** |
| **DeepSeek V4 Flash** (quants différentes) | 90 s | 116 s | **+29 %** |

| Détail par scénario | 27B gufo | 27B service | Flash-Next gufo | Flash-Next service | DeepSeek gufo | DeepSeek service |
|---|---|---|---|---|---|---|
| simple | 3,0 s | **1,9 s** | **1,5 s** | 2,4 s | **4,0 s** | 5,0 s |
| outils (write + bash + read) | 6,9 s | **4,4 s** | 4,3 s | **3,6 s** | **11,1 s** | 19,7 s |
| edit | 7,8 s | **6,3 s** | 5,3 s | **5,1 s** | **16,0 s** | 20,6 s |
| création (module + tests) | **25,6 s** | 29,9 s | **22,1 s** | 23,4 s | **27,4 s** | 43,2 s |
| bugfix | **12,3 s** | 15,0 s | **8,0 s** | 9,4 s | 25,9 s | **25,5 s** |
| tokens recalculés (tout le run) | 27,7k (30 %) | **7,0k (8 %)** | 27,3k (29 %) | **17,6k (17 %)** | 27,5k (30 %) | **11,3k (12 %)** |
| temps en prefill / décode | 63 / **101 s** | **29** / 139 s | **30 / 82 s** | 33 / 96 s | **92 / 179 s** | 102 / 255 s |
| prefill / décode réels (t/s) | **438 / 45,9** | 242 / 32,4 | **897 / 50,7** | 531 / 48,5 | **300 / 31,1** | 111 / 26,3 |

L'appel froid n'est pas comparable : côté service, il comprend le chargement
du modèle à la demande (9,7 s, 21,6 s, 86 s), alors que gufo était déjà chargé.
Sur DeepSeek, le service a généré 20 % de tokens en plus (6,7k contre 5,6k) :
le raisonnement n'était sans doute pas réglé pareil (budget côté service,
défaut du template côté gufo).

### Pourquoi l'avance de gufo fond en agentique : le cache

- Dans une même conversation, gufo reprend 94 % du prompt (4,1k tokens
  recalculés sur 68,3k pour le 27B) : aussi bien que le service.
- À chaque nouvelle conversation (chaque scénario ouvre une session pi, même
  prompt système d'environ 1,5k tokens, puis un nouveau message), gufo
  recalcule tout : 14 ratés sur 16 en `cache_miss_reason=prefix_changed`
  avec `common_prefix_tokens` de 1 508 à 1 517, et 0 token réutilisé. Le
  premier appel n'avait pas encore de point de reprise ; seul le deuxième
  (répétition exacte du premier) a été repris.
- Même un prompt identique rate dès qu'une autre conversation s'est intercalée :
  gufo semble ne savoir restaurer que la dernière conversation, et seulement
  comme prolongement exact.
- Le service, avec `cache-ram 12288` et `ctx-checkpoints 128`, reprend 1 077 à
  1 538 tokens du préfixe commun sur ces mêmes requêtes.
- Ces ratés représentent environ 23,5k des 27,7k tokens recalculés par gufo
  sur le 27B. Ils annulent son prefill ×1,8 et son décode +40 % : égalité à
  56 contre 57 s.

## Verdict

À ce jour, gufo ne remplace pas le service, même en ne gardant que ses trois
modèles.

- Gain réel en boucle agentique : +2 % (27B), +13 % (Flash-Next), +29 %
  (DeepSeek, en partie grâce à une quant plus légère dont la justesse n'est
  pas établie).
- Pertes : le fine-tune Signal de Flash-Next et notre quant DeepSeek, le
  n-gram (décode du code répété +58 % côté service sur Flash-Next), le routeur
  multi-modèle, la WebUI, le préchargement, tout l'outillage du dépôt
  (`models.ini`, `--spec-tune`, `qualif-modele.sh`), le budget de raisonnement,
  et la stabilité (projet v0.1.0, commits quotidiens, deux contributeurs
  principaux).
- Ce qui changerait l'avis, par ordre d'importance : la reprise d'un préfixe
  commun entre conversations (#259), un n-gram autonome (#239), la justesse
  de DeepSeek en IQ2XXS (série de comptages à faire).
- Piste la plus défendable si le besoin apparaît : gufo pour DeepSeek seul sur
  des longs contextes neufs (prefill jusqu'à ×5), après contrôle de justesse.

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
  entre conversations au même préfixe (le point bloquant, mesures ci-dessus).
- [#239](https://github.com/gufo-org/gufo/issues/239) : deux commentaires sur
  le n-gram. Le même jour, un contributeur y a publié un résultat négatif :
  recherche dans le prompt en complément de la MTP, greedy, +0,2 à 1,1 %
  seulement (la MTP accepte déjà 92 % en greedy). Notre réponse : mesure en
  temp 0,7 et gain lié à un pool persistant, donc conception différente, à
  suivre dans un ticket séparé.

À surveiller :

| Ticket | Sujet | État au 24/09/2026 |
|---|---|---|
| #259 | reprise d'un préfixe commun entre conversations | ouvert (le nôtre) |
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

Tout est conservé sur bigchuck dans `~/llm/gufo-test` (hors du dépôt, hors de
`~/models`, qui n'est monté qu'en lecture seule) :

- `run.sh` + `mesure.py` : banc HTTP.
  `./run.sh gufo <cas>...` arrête le service et le relance à la sortie ;
  `./run.sh llama <cas>...` mesure la section du service. Cas : `27b`,
  `27b-q4km`, `flashnext`, `flashnext-unsloth`, `flashnext-large-ub`,
  `deepseek`, `deepseek-antirez` (`flashnext` et `deepseek` côté gufo
  échouent au chargement, cf. plus haut).
- `agentic.sh` : boucle pi, mêmes cas et même convention
  (`PASSES=3` par défaut, garde-temps d'une heure).
- `resultats/` : `resultats.tsv` (banc HTTP), `chargements.tsv`,
  `reponses/` (textes générés), journaux gufo, `agentic/` (sorties pi et
  journaux gufo par requête).
- `models/` (192 Go) : les GGUF de référence de gufo, téléchargés le
  24/09/2026 aux révisions épinglées par gufo : Flash-Next UD-Q4_K_XL
  unsloth (`38bb39e`, 4 shards, 104 Go), DeepSeek IQ2XXS antirez
  (`1cd7b56`, 87 Go) et DSpark (`e7f0403`, 6 Go), drafter DFlash 2 Q4_K_M du
  27B (`2d9571f`, 1,1 Go).
- Image `ghcr.io/gufo-org/toolboxes/gufo-runtime:latest` (8,3 Go).

Pour rejouer contre une nouvelle version de gufo : `docker pull` de l'image,
puis `./run.sh gufo 27b` et `./agentic.sh gufo 27b`. Ce sont les deux mesures
qui comparent les moteurs à fichiers identiques ; les chiffres du service
ci-dessus sont la référence du 24/09/2026.
