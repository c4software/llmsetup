# Sections, méthodes et procédures retirées : archive

Archive de ce qui ne sert plus au quotidien mais ne doit pas se perdre. Deux
parties :

1. **Les blocs des sections retirées du parc** (cinq entrées, de
   « qwen3.8-27b (thinking) » à « lfm2.5-8b-a1b-nothink ») : pour chacune, le
   commentaire métier et le corps de `lib/models.sh` tels qu'ils étaient au
   retrait, à recopier pour remettre la section en place ;
2. **« Méthodes et procédures retirées »**, en fin de fichier : le détail de
   commandes, de variantes et d'essais qui n'existent plus (`--bench-devices`,
   variantes `-parallel`, procédures du fork Vulkan, essai batch 16384 du
   17/09/2026).

L'histoire (décision, motif, chiffres clés) reste dans
[`docs/HISTORIQUE.md`](HISTORIQUE.md), à la section citée en tête de chaque
entrée.

Règles de la première partie :

- les blocs sont du texte à recopier dans le code : ils sont verbatim, tirets
  longs et renvois internes (« ci-dessus », « ci-dessous », « cf.
  docs/HISTORIQUE.md ») compris. Ne pas les résumer ni les corriger ;
- un bloc est daté par son retrait : ses réglages et ses chiffres sont ceux du
  moteur d'alors (fork `strix-0007bc6` sur Vulkan0 pour quatre d'entre eux),
  pas de l'image ROCm servie depuis le 18/09/2026. Remettre une section
  impose de la re-qualifier (`tools/qualif-modele.sh`, justesse d'abord) ;
- pour quatre blocs (`qwen3.5-9b`, `laguna-s-2.1`, `gpt-oss`,
  `lfm2.5-8b-a1b-nothink`), les fichiers ne sont plus dans `KNOWN_FILES` :
  `./setup-llm.sh --cleanup` les purge, les déclarations de téléchargement
  sont donc à remettre avec le bloc. Le cinquième, `qwen3.8-27b` (thinking),
  partageait le GGUF de `qwen3.8-27b-dflash-nothink`, toujours déclaré : son
  bloc ne porte aucune déclaration de téléchargement.

| Section | Retirée le | Histoire dans `docs/HISTORIQUE.md` |
|---|---|---|
| `qwen3.8-27b` (thinking) | 13/09/2026 | « Qwen3.8-27B thinking : section retirée le 13/09/2026 » |
| `qwen3.5-9b` | 15/09/2026 | « qwen3.5-9b remplacé par Ornith-1.5-9B (15/09/2026) » |
| `laguna-s-2.1` | 15/09/2026 | « Laguna-S-2.1 retiré (15/09/2026) » |
| `gpt-oss` | 16/09/2026 | « gpt-oss retiré (16/09/2026) » |
| `lfm2.5-8b-a1b-nothink` | 18/09/2026 | « lfm2.5-8b-a1b-nothink retiré (18/09/2026) » |

## qwen3.8-27b (thinking), retirée le 13/09/2026

Pour ravoir la section : remettre ce bloc dans `lib/models.sh` avec
`parallel 1` et sans la précharger en même temps que la nothink
`qwen3.8-27b-dflash-nothink` (même GGUF, 16 Go chargés deux fois).

Le commentaire du bloc retiré, tel quel (connaissance à conserver :
reasoning-budget, speculative prefill essayé et retiré, DFlash 2 sur du
raisonnement), puis le corps de la section tel qu'il était émis dans
`models.ini`.

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

## qwen3.5-9b, retirée le 15/09/2026

Pour ravoir la section : remettre la déclaration de téléchargement, le
commentaire et le corps ci-dessous dans `lib/models.sh`.

Le commentaire du bloc retiré, tel quel (connaissance à conserver : incident du
GGUF homonyme écrasé, effondrement du MTP multi-slot, part du cache inchangée
par la spéculation), fermé par le corps `llama_model`, puis le corps de la
section tel qu'il était émis dans `models.ini`. Les deux corps ne diffèrent que
par deux écritures : `model = $QWEN35_9B_MTP_PATH` et les guillemets du
`chat-template-kwargs` échappés, `{\"enable_thinking\":false}`.

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

## laguna-s-2.1, retirée le 15/09/2026

Pour ravoir la section : remettre les deux déclarations de téléchargement
(`download_hf_shards` sur `unsloth/Laguna-S-2.1-GGUF` pour la quant,
`download_hf` sur `poolside/Laguna-S-2.1-GGUF` pour le drafter), le commentaire
et le corps ci-dessous dans `lib/models.sh`, avec sa bannière de groupe :
`; --- Laguna S 2.1 : arch 'laguna', servie par le fork strix-llama.cpp ; sur
le paquet Arch de secours, b10087 minimum (vérifié jusqu'à b10548) ---`.

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

## gpt-oss, retirée le 16/09/2026

Pour ravoir la section : remettre la déclaration de téléchargement, le
commentaire et le corps ci-dessous dans `lib/models.sh`, sous la bannière
`; --- Géants ---` (toujours là pour DeepSeek), avant DeepSeek.

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

## lfm2.5-8b-a1b-nothink, retirée le 18/09/2026

Pour ravoir la section : remettre les deux `download_hf`, le commentaire et le
corps ci-dessous dans `lib/models.sh`, sous la bannière du groupe, entre
`lfm2.5-2.6b` et `qwen3-coder-next`.

Le bloc retiré, tel quel (connaissance à conserver : quant officielle, drafter
DSpark sidecar, thinking coupé par `reasoning-budget-enable` + budget 0, réglage
n-gram 47 arbitré par `--spec-ab`, et les mesures des deux moteurs). Les tirets
longs de l'original sont rendus en tirets simples : c'était déjà le cas dans
`docs/HISTORIQUE.md` au moment de l'archivage, ce bloc est repris de là sans
autre changement.

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

## Méthodes et procédures retirées

Détail de ce qui a existé puis disparu du dépôt. Chaque entrée dit quand et
pourquoi, et renvoie à la section de `docs/HISTORIQUE.md` qui en garde la
décision. Rien ici ne décrit une commande utilisable aujourd'hui.

### Choix du device (--bench-devices)

Commande, `bench-devices.conf` et `lib/bench/bench-devices.sh` retirés le
18/09/2026 : l'image du service n'expose que `ROCm0`. Histoire : « Choix du
device (--bench-devices) : méthode et exemples datés » et « Campagne du moteur
conteneurisé (17 au 18/09/2026) ». Méthode complète et exemple du 16/08/2026
(paquet Arch b10433), tels qu'ils valaient alors :

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
prefill et l'autre le décode. Exemple réel (qwen3.8-27b-mtp-nothink,
16/08/2026, avant son renommage en qwen3.8-27b-dflash-nothink) : ROCm0 gagne
le prefill (356 contre 307 t/s) mais perd le décode (21,8 contre 29,9 t/s) ;
en temps de tour, Vulkan0 fait 106,7 s contre 143,3 s et l'emporte nettement.
Le profil se surcharge à l'appel pour un usage différent, par exemple
`BENCH_PROFILE_PP=8000 BENCH_PROFILE_GEN=500` pour du gros contexte à réponse
courte. À moins de 2 % d'écart, le device par défaut est conservé (pas de
bascule sur du bruit de mesure).

Le vainqueur est écrit dans `bench-devices.conf` (clé = dossier du GGUF,
donc partagée entre les variantes d'un même fichier), le ini est régénéré
et le service redémarre sur la config retenue. Le fichier reste éditable à
la main pour forcer un choix. Formule, garde-fous et limites : section
dédiée dans ARCHITECTURE.md.

### Variantes -parallel (15/09/2026)

Sections `lfm2.5-2.6b-parallel` et `qwen3.5-9b-parallel`, créées et retirées
le 15/09/2026 (fork strix-0007bc6, Vulkan0). Histoire et motif (« pas de
parallel si perte de perf ») : « Variantes -parallel retirées (15/09/2026) ».

Ce que portaient ces deux variantes, gardé ici puisque les sections n'existent
plus. Toutes deux : 4 slots, pas de drafter.

| | lfm2.5-2.6b-parallel | qwen3.5-9b-parallel |
|---|---|---|
| GGUF | même GGUF cible que la section principale (le DSpark n'étant simplement pas chargé) | GGUF du repo unsloth SANS tête MTP (dossier `qwen3.5-9b/`, devenu orphelin par ce retrait, cf. les retraits de l'inventaire dans « Résultats mesurés ») |
| `ctx-size` (pool partagé) | 131072, donc 32768 par slot | 32768, donc 8192 par slot ; toutes les autres clés étaient celles de la section principale (sampling, `n-predict`, `swa-full`, `ctx-checkpoints`) |
| 21/08/2026, Vulkan0, b10433, prefill / décode | 2279 / 67,7 t/s | 837 / 25,7 t/s |
| `--bench-parallel` 4 requêtes (21/08) | 205 t/s agrégés (x3,06) | 78,6 t/s agrégés (x3,06), 20 t/s par requête |
| `--bench-load` (21/08) | 0,5 s (2,7 Go), TTFT 27 ms | 1,9 s (8,2 Go), TTFT à chaud 65 ms |
| `--bench-cache` (21/08) | 62 % / 63 %, comme les GDN (autre tokenizer, même plafond : c'est l'état récurrent, conv ici) | 62 % au tour suivant, 63 % à l'identique |
| 13/09/2026, fork strix-0007bc6, `--bench` 3 passes | 3048 / 70,8, soit +34 % de prefill contre le 21/08, mais `bench.log` du 02/09 (b10621) donnait déjà 2743 : l'essentiel vient du build | 971 / 25,7, prefill +16 %, décode identique au dixième |
| 15/09/2026, même fork, sous le nom `-parallel` | 3602 / 68,2, l'ancien réglage retrouvé à 1,3 % près, ce qui a servi de témoin au prefill perdu par la section principale spéculée | 791 / 25,5, décode identique au 13/09 mais prefill 20 % plus bas (993 dans `bench.log` ce jour-là) sans changement de réglage ni de GGUF |

Sur le 9b : justesse OK (recopie) ; un calcul mental simple, lui, est raté
(93 → 33) : tâches auxiliaires, pas de raisonnement. Et son prefill 20 % plus
bas le 15/09 est de la dispersion de plateforme, à garder en tête avant de lire
un écart de prefill entre deux journées comme un effet de réglage.

La justification écrite alors pour les garder tenait en deux points, tous deux
caducs : « les 4 slots de tâches auxiliaires CONCURRENTES font tout l'intérêt
du 9b » (elles n'ont jamais eu lieu) et « le chemin MTP multi-slot du fork est
inutilisable » (18,2 t/s agrégés à np 4 contre 80,8 sans spéculation, cf.
point 3 de « Multi-slot et drafters »). Ce second point reste vrai, mais il
justifie le parallel 1 de la section à drafter, pas l'existence d'une seconde
section. De même côté LFM2.5 : DSpark à np 2 respecte le seuil des 8 colonnes
(2 x (3 + 1)) et ne rend pourtant que ~x1,1 agrégé pour un débit par requête
divisé par deux (mesure `tools/spec-isolate.sh NP=2` du 15/09/2026, 400 tokens,
2 salves : solo 105 à 124 t/s, deux requêtes simultanées 120 à 136 t/s
agrégés).

Note sur le prefill du 9b au 13/09 : cette table porte 971 (campagne `--bench`)
et 993 (`bench.log`) pour le même réglage. Non tranché dans les sources.

### Procédures du fork

Le fork Vulkan `strix-llama.cpp` installé sur l'hôte a été le moteur du 12 au
18/09/2026 ; `lib/fork.sh`, `--setup-fork`, `--update-fork`, `--unset-fork`,
`fork.conf` et `tools/mtp-rename-hc-head.py` sont partis le 18/09/2026.
Histoire : « Passage au fork (12 et 13/09/2026) » et « Le fork Vulkan n'est
plus un moteur du dépôt (18/09/2026) ».

**Changelog de `--update-fork`.** Au 12/09/2026 : le fork resynchronise le
llama.cpp officiel par blocs (0007bc6 → 6548035 = 210 commits, dont 209
d'amont), d'où le tri : les titres listés sont ceux des commits propres au fork
(merges de PR compris, 40 lignes au plus), le reste n'étant qu'un compte,
« Commits llama.cpp amont intégrés : 209 (amont : b10809 → b10950) ». Le tri
demande un remote `upstream` sur
[ggml-org/llama.cpp](https://github.com/ggml-org/llama.cpp), ajouté au clone à
la première mise à jour s'il manque ; sans lui (pas de réseau), la liste
complète est affichée avec un avertissement.

Ces comptes (210 commits dont 209 d'amont, b10809 → b10950) diffèrent de ceux
de la mise à jour réelle du 13/09 (PR de sync #47, 206 commits amont, b10891
vers b10917, dans « Mise à jour du fork vers 654803517 ») : le 13/09 est le
dernier en date, mais rien dans les sources ne dit lequel est juste.

**Épinglage par `fork.conf`** (13/09/2026, après la régression de 654803517,
puis de nouveau le 17/09/2026 après l'essai de 0636c9aee). Retour à 0007bc6 le
jour même, fork épinglé par `fork.conf` tant que l'amont n'est pas corrigé ; à
re-tester à chaque `--update-fork` (le changelog s'affiche sans rien faire tant
que l'épinglage est en place).

**Renommage du sidecar MTP de Qwen3.8-Flash-Next** (jalon 2, 12/09/2026). Le
graphe MTP `qwen4exp` et le drafter externe (`spec-draft-model`) du fork, ce
qui débloque le MTP de Qwen3.8-Flash-Next (jalon 2), à une condition : le
sidecar MTP d'unsloth doit d'abord être **renommé** par
`tools/mtp-rename-hc-head.py` (voir README, « Outils »). Le fork lit le
mixeur des hyper-connexions sous `output_hc_{norm,down,up}`, unsloth le range
sous `blk.<n>.nextn.hc_head_*` (convention de la PR mainline #28243) : sans
renommage, `check_tensor_dims: tensor 'output_hc_norm.weight' not found` et
le modèle ne charge pas du tout. Le renommage est automatique au `--setup`
(`derive_gguf` dans `lib/models.sh`).

**Retour arrière par `image.conf`** (18/09/2026). Texte écrit avec le retrait
du fork : il ne passe plus par un fork installé sur l'hôte mais par
`runtime/image.conf` : y remettre d'anciennes révisions (`git revert` sur ce
fichier, ou `--image-update <engine-rev> <rocm-rev>`) puis `--image-build`,
l'historique git de ce fichier étant le journal des révisions. Cette procédure
contredit « Un Dockerfile et un compose (18/09/2026) », qui est le dernier en
date : `image.conf` et `--image-update` ont été retirés le même jour, les
révisions vivent dans les deux `ARG` de `runtime/Dockerfile.rocm-strix` et le
retour arrière consiste à y remettre les anciennes valeurs.

### Essai retiré sur Flash-Next (17/09/2026)

`batch-size` / `ubatch-size` 16384 et `lazy-mode on-direct` sur
`qwen3.8-flash-next-mtp-nothink`, bigchuck, Vulkan0, mode EC performance.
Histoire : « Campagne du 17/09/2026 : cache V f16 sur le 27B, `reasoning =
off`, essais retirés sur Flash-Next », sous-section « Essai retiré sur
Flash-Next : `batch-size` / `ubatch-size` 16384 et `lazy-mode on-direct` ».
Texte d'origine :

Paramètres retirés, retour au batch par défaut et à `cache-type-v q8_0` sur
cette section : le gain de prefill au bench court est payé deux fois, en
décode, et par un prefill servi qui s'écroule là où ce modèle sert justement.

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

Le fork 0636c9aee lui-même n'est pas retenu : le 27B y tombe à 255 / 25,5
(cache-type-v f16) contre 302 / 32,2 sur 0007bc6. Ré-épinglage sur 0007bc6 le
soir même, même schéma que « Mise à jour du fork vers 654803517 (13/09/2026) :
régression, retour à 0007bc6 ».
