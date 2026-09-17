---
name: ajout-modele
description: Procédure complète d'ajout d'un modèle dans ce dépôt (lib/models.sh) jusqu'au récap de performance partageable. À charger dès qu'on ajoute, remplace ou re-qualifie un modèle (nouveau GGUF, nouvelle quant, variante MTP, changement de moteur).
---

# Ajouter un modèle, de la fiche HF au tableau de perfs

Sept étapes, dans l'ordre (justesse avant spéculation : mesurer un moteur qui
répond faux n'a aucun sens). Chacune a un livrable et un critère de passage ;
on ne passe pas à la suivante sans lui. Les commandes se lancent sur la
machine qui héberge le service (`./setup-llm.sh`, conteneur `llama-server`),
jamais en parallèle les unes des autres : un seul GPU.

Lire `AGENTS.md` et `ARCHITECTURE.md` avant d'éditer. Le bloc de
`lib/models.sh` est la seule source de vérité du modèle ; ses commentaires
sont la connaissance métier et doivent citer les mesures (date, device,
quant) qui justifient chaque réglage.

## Le moteur d'abord : fork ou paquet Arch

Depuis le 12/09/2026 le service tourne sur le fork
[halo-box/strix-llama.cpp](https://github.com/halo-box/strix-llama.cpp)
(`~/llm/strix-llama.cpp`, quatre liens dans `~/.local/bin` que l'unité
systemd met en tête du PATH), pas sur le paquet Arch `llama-cpp`.
`./setup-llm.sh --setup-fork` installe ET met à jour (clone ou
`git pull --ff-only`, build, liens) ; `--update-fork` ne fait que le suivi
d'amont d'un fork déjà en place (à lancer après un `--update`, il s'arrête
sans rebuild si rien n'a bougé) ; `--unset-fork` retire les liens et rend la
main au paquet ; `--list-devices` dit quel binaire répond réellement. Aucune
des trois ne redémarre le service ni ne lance de mesure. `--setup` propose
lui-même l'installation du fork (défaut oui) quand il n'est pas le moteur
résolu, et rappelle `--update-fork` sinon.

Trois conséquences pour toute la procédure ci-dessous :

- **Comparabilité** : les mesures faites sous le fork portent l'étiquette
  `strix-<commit>` dans la colonne build des journaux (`_llama_build`), les
  campagnes du paquet portent `bNNNNN`. Deux séries distinctes, jamais
  comparées à la décimale : le dire dans chaque récap, et garder la valeur de
  l'autre série entre parenthèses plutôt que de la remplacer.
- **Clés propres au fork** (`FORK_ONLY_KEYS`, `lib/fork.sh`) : `ngram-on-disk`,
  `lazy-mode`, `fit`, `load-mode`,
  `reasoning-budget-enable` / `-soft-ratio` / `-soft2-ratio` /
  `-grace-tokens`, `spec-draft-adaptive`, `spec-prefill*`. Les trois premières
  sont posées par le dépôt lui-même : `fit` et `load-mode` en flags GLOBAUX
  (`[*]`), `lazy-mode` sur la section Flash-Next. Le paquet Arch
  refuse toute clé inconnue et c'est le **routeur entier** qui ne démarre pas,
  pas seulement le modèle fautif. En poser une dans un bloc verrouille donc le
  parc sur un moteur qui les comprend - l'image du service les comprend, le
  paquet Arch non (`_fork_keys_guard` le signale côté hôte). Pour revenir au
  paquet : retirer ces lignes de `lib/models.sh`, puis `--preload`.
- **Ne pas proposer `spec-prefill*`** : mesuré le 12-13/09/2026 sur
  qwen3.8-27b, il triple le prefill mais met le cache de prompt à 0 %, même
  sur une requête identique : perdant en boucle agentic, retiré.

## 1. Valider les informations de base (fiche du modèle)

Demander ou récupérer la fiche du modèle. Deux sources, à croiser :

- le guide unsloth du modèle, `https://unsloth.ai/docs/models/<modèle>`
  (index : `https://unsloth.ai/docs/models`). C'est la source la plus
  directement exploitable : sampling officiel par mode (thinking et
  instruct), quant conseillée et VRAM, contexte maximum et YaRN, commande
  llama.cpp de référence, note MTP, mises en garde sur le template chat.
  Vérifié le 21/08/2026 sur le guide Qwen3.8 : toutes ces rubriques y sont ;
- la model card HF du repo GGUF (onglet Files pour les fichiers et les
  shards, commits pour la date du dernier upload), et celle du checkpoint
  d'origine quand le repo GGUF n'est qu'un miroir.

En extraire et vérifier :

| Donnée | Où la trouver | Ce qu'on en fait |
|---|---|---|
| Repo GGUF et fichier (ou shard 00001) | page HF, onglet Files | `download_hf` ou `download_hf_shards` |
| Quant retenue et taille | guide unsloth (reco et VRAM), tableau des quants HF | commentaire du bloc (pourquoi cette quant) |
| Architecture llama.cpp (`general.architecture`) | metadata GGUF, ou `gguf-dump` | support mainline, version minimale de llama.cpp |
| Contexte natif, YaRN | guide unsloth, model card | `ctx-size` |
| Sampling officiel (temp, top-k, top-p, min-p, presence) | guide unsloth, model card | corps ini |
| Thinking : défaut, désactivation | template chat | `reasoning = off` (`chat-template-kwargs` seulement pour les niveaux : reasoning_effort, reasoning_strength) |
| État récurrent (GDN, conv, Mamba) ou SWA | architecture | `cache-reuse 0`, `swa-full`, `ctx-checkpoints` |
| Vision (mmproj) | Files | texte seul sauf besoin, incompatible MTP |
| Drafter externe (DFlash, Eagle, sidecar MTP) | Files, repo `-DFlash`/`MTP/` | `download_hf` supplémentaire, `spec-draft-model` |
| Date de dernier upload, repo squashé | commits HF | note « prévoir un --update » |

Trois façons de déclarer un fichier, toutes dans le bloc :

- `download_hf <dossier> <repo> VAR=<fichier>` : un ou plusieurs fichiers d'un
  repo. `<fichier>` peut être en sous-dossier (`MTP/x.gguf`), recréé tel quel.
  Plusieurs appels peuvent viser le **même dossier modèle** depuis des repos
  différents : c'est ainsi que se déclare un drafter externe (DFlash 2 de
  z-lab dans `~/models/qwen3.8-27b/`, sidecar MTP d'unsloth dans `MTP/`) ;
- `download_hf_shards <dossier> <repo> VAR=<shard 00001>` : le glob hf est
  dérivé du sous-dossier de quant, changer de quant = changer la seule entrée ;
(un troisième mode, `derive_gguf`, déclarait un GGUF calculé en local par un
script du dépôt. Il a été retiré le 18/09/2026 avec son seul usage, le sidecar
MTP de Qwen3.8-Flash-Next renommé pour le commit 0007bc6 du fork : le moteur de
l'image lit la tête « shared » d'unsloth telle quelle. Tout est dans
l'historique git si le besoin revient.)

Les deux alimentent `KNOWN_FILES` (donc `--cleanup`) : un fichier déclaré est
protégé, un fichier qui cesse de l'être devient un orphelin supprimable.

Critère de passage : le bloc `lib/models.sh` est écrit (commentaire métier
compris), `bash -n lib/models.sh` passe, et le ini généré n'a changé que
pour ce modèle :

```bash
cp ~/models/models.ini /tmp/models.ini.avant
./setup-llm.sh --preload       # revalider la même sélection : le ini est régénéré
diff /tmp/models.ini.avant ~/models/models.ini
```

L'écart doit se limiter à la nouvelle section (et à son en-tête de groupe
s'il y en a un). Puis `./setup-llm.sh --setup` ou
`--update <modèle>` pour télécharger le GGUF.

## 2. Décider MTP ou pas MTP

Deux questions indépendantes :

1. **D'où vient le draft ?** Trois sources, et le `spec-type` qui va avec :
   - tête MTP **embarquée** dans le GGUF principal (« MTP for fast
     inference », `nextn`/`mtp` dans les metadata) : `spec-type = draft-mtp`,
     rien d'autre à déclarer ;
   - tête MTP en **sidecar** (repo `-MTP` séparé ou sous-dossier `MTP/`) :
     `download_hf` du sidecar + `spec-draft-model`. Préférer la variante
     « shared » quand le repo en publie une : le moteur de l'image sait
     emprunter les tenseurs de la cible (2,6 Go au lieu de 4,1 sur
     Flash-Next) ;
   - **drafter externe** (DFlash 2 de z-lab pour Qwen3.8-27B, Eagle…) :
     `download_hf` dans le dossier du modèle, `spec-type = draft-dflash`,
     `spec-draft-model = $…_DFLASH_PATH`, `spec-draft-n-max` selon la carte du
     drafter (7 pour DFlash 2). Le GGUF devient nécessaire au démarrage du
     modèle : ne pas le retirer du dossier.

   Le nom de la section porte un **suffixe explicite** disant quel drafter est
   servi : `<clé>-mtp-nothink`, `<clé>-dflash-nothink`. Les garde-fous de
   `_preload_sanity` reposent sur la ligne `model =` identique et sur la
   convention de dossiers `<clé>` / `<clé>-mtp`, pas sur ce suffixe : il est
   là pour le lecteur, et il se renomme quand le drafter change (cf. Clôture).
2. **Veut-on la spéculation sur ce modèle ?** Contraintes à respecter :
   `cache-reuse = 0`, pas de mmproj (seul interdit dur avec un drafter).
   `parallel = 1` était donné ici comme obligatoire jusqu'au 15/09/2026 : c'est
   un CHOIX à justifier par modèle (contexte par slot, mémoire, rendement
   mesuré), pas un interdit du moteur (vérifié dans le fork le 15/09/2026, cf.
   en-tête de `lib/models.sh`). Sur une
   architecture à état récurrent (GDN des Qwen3.5+, conv LFM2), le rollback
   partiel sur rejet de draft est en mainline (PR #22673) mais n'a pas été
   validé ici sur Vulkan en boucle de tool calls : garder une variante sans
   spéculation pour l'agentic tant que ce n'est pas mesuré.

Si MTP : `spec-type = draft-mtp`, `spec-draft-n-max = 4` en valeur de
départ. Si on veut aussi les n-grams (modèle utilisé en édition de code,
où le prompt se ré-émet) : `spec-type = ngram-map-k,draft-mtp` (ou
`ngram-map-k,draft-dflash`), `spec-ngram-map-k-size-m = 7`,
`spec-ngram-map-k-min-hits = 2`, à régler à l'étape 5.

Piège du **découpage mat-vec du fork** : sa PR #27 découpe les mat-vec batchés en
colonnes 4/2/1, sur les tenseurs q8_0 et q6_K seulement, donc sur un
UD-Q4_K_XL aussi (110 tenseurs q8_0, 56 q6_K). Le batch de vérification vaut
`n-max + 1` : à 7 colonnes il se découpe en 4+2+1, le pire cas (-7,4 % mesuré
au llama-bench du 13/09/2026, pp7 68,9 contre 74,4 t/s). Choisir un n-max dont
le batch évite ce cas : 4 (batch 5) ou 7 (batch 8 = 4+4), pas 6 (batch 7).
`GGML_VK_MMV_NO_SPLIT=1` annule la pénalité mais désactive le découpage pour
tout le parc : non retenu.

### Test isolé AVANT déclaration

Déclarer un modèle coûte un bloc, un ini régénéré, un restart et un
préchargement : quand le drafter est neuf (premier DSpark, premier DFlash, un
sidecar jamais servi ici) ou que le `spec-draft-n-max` reste à choisir, le
répondre d'abord hors service, sur un `llama-server` jetable qui ne touche ni
au ini ni aux `.conf` :

```bash
PASSES=2 MAX_TOKENS=1200 tools/spec-isolate.sh <tag> -- \
  -m ~/models/<dossier>/<gguf> -md ~/models/<dossier>/<drafter.gguf> \
  --spec-type draft-dspark --spec-draft-n-max 3 -c 32768 \
  --temp 0.1 --top-k 50 --min-p 0 --repeat-penalty 1.1 -ctk f16 -ctv f16
```

Tout ce qui suit `--` va tel quel à `llama-server` (le script ajoute seulement
`--device Vulkan0 -ngl 99 -fa on --jinja` devant, surchargeables). ⚠ Cet outil
tourne sur le moteur de l'HÔTE (fork Vulkan), pas sur l'image du service : il
dégrossit, il ne mesure pas ce qui sera servi. Mettre le
sampling réel du modèle, pas un sampling de confort, sinon les chiffres ne
valent rien pour le bloc. L'outil arrête le service et le relance par son trap,
et refuse de démarrer si un `--bench*`, un `--spec*` ou un conteneur
`bench-agentic-*` tourne (un seul GPU). Lecture : l'**acceptance** doit exister
(« n/a » = le drafter n'est pas chargé, relire `logs/spec-isolate/<tag>/serveur.log`)
et rester haute ; la **sanité** doit dire « ok » sur chaque passe (un « SORTIE
DÉGÉNÉRÉE » invalide la mesure, si beaux que soient les t/s : c'est le
charabia à 550 t/s de l'étape 3) ; le **décode** se lit sur la médiane hors 1re passe, et
se compare à un run `--spec-type none` des mêmes arguments. Enchaîner plusieurs
`<tag>` (un par n-max) coûte un redémarrage chacun et tranche la question. Puis
seulement : écrire le réglage retenu dans `lib/models.sh` avec ses chiffres
datés, et le CONFIRMER tel qu'il est servi par
`./setup-llm.sh --spec-ab <modèle> <n> - <variante>` (ou `--spec-test`) ; le
test isolé est un dégrossissage, le service reste l'arbitre.

Pour un modèle qu'on envisage à `parallel > 1`, refaire le même test avec
`NP=2` : le script ajoute `-np 2` et mesure en plus une salve de 2 requêtes
simultanées (agrégé = tokens sur temps mur, par requête = médiane). La règle
d'arbitrage est celle du découpage mat-vec ci-dessus, appliquée au batch
multi-slot : `np x (n-max + 1) <= 8` colonnes sur ggml-vulkan ; à np 2 et
n-max 3 on tombe pile sur 8, à np 2 et n-max 7 sur 16 et la spéculation coûte
plus qu'elle ne rapporte. Ne pas conclure sur la théorie seule : le MTP
multi-slot s'effondre en pratique (qwen3.5-9b, 15/09/2026 : 18,2 t/s agrégés à
np 4 contre 80,8 sans spéculation), et le seul gain mesuré du parc est
deepseek-v4-flash à np 2. Sans mesure `NP>1`, déclarer `parallel = 1` et le
dire dans le commentaire.

Critère de passage : après restart, `curl localhost:8009/v1/models` montre
le `--spec-type` attendu dans `status.args`, et un premier
`./setup-llm.sh --spec-test <modèle> 2` affiche une acceptance (pas
« n/a ») : le drafter (tête MTP, sidecar ou GGUF externe) est bien chargé.

## Enchaînement automatique des étapes 3 à 7

Le modèle est déclaré et servi (fin de l'étape 2) : sur la machine du service,

```bash
tools/qualif-modele.sh <section>
```

joue dans l'ordre l'étape 3 (`--bench-sanity`, **bloquante**), l'étape 5
(`--spec-ab` sur `spec-refactor.txt` puis sur `spec-test.txt`), l'étape 6
(`--bench`, `--bench-cache`, `--bench-load`) et l'étape 7
(`--bench-agentic 3`), une à la
fois (un seul GPU), lit le drafter et le `size-m` réellement servis dans
`status.args` de `/v1/models`, et écrit `logs/qualif/<tag>/resume.md` : les
sorties brutes par étape plus le tableau de l'étape 6 déjà rempli. Options :
`--passes`, `--size-m`, `--sans-agentic`, `--sans-cache`,
`--sans-load`, `--tag`. Une étape en échec n'arrête pas les suivantes, sauf la
justesse : là, tout s'arrête.

Ce qu'il ne fait pas : l'étape 4 (`--spec-tune`) reste manuelle, elle n'a de
sens que pour `draft-mtp` et elle écrit dans `spec-nmax.conf` ; le test isolé
(`tools/spec-isolate.sh`) se joue avant la déclaration ; et rien n'est écrit
dans `lib/models.sh`, le README ou `docs/HISTORIQUE.md` : les chiffres du
récapitulatif restent à reporter à la main.

## 3. Contrôle de justesse sur ROCm0 (--bench-sanity)

Il n'y a plus de device à choisir : le moteur du service est l'image de
`runtime/`, construite en HIP seul, qui n'expose que `ROCm0`
(`--bench-devices` et `bench-devices.conf` ont été retirés le 18/09/2026).
Ce qui reste de cette étape est ce qui la justifiait, et elle passe donc
toujours en premier, AVANT toute mesure de spéculation :

```bash
./setup-llm.sh --bench-sanity <modèle>
```

Une tâche à réponse connue (`prompts/bench-sanity.txt` : recopier un code
exact), volontairement triviale pour ne tester que le backend. Un moteur qui
dérive la rate forcément ; `timings.py` attrape en plus les sorties dégénérées
(mot dominant, mots distincts, répétition périodique de caractères).

Regarder ce que le serveur GÉNÈRE, pas seulement ses t/s : DeepSeek V4 sur le
ROCm SYSTÈME (b10433) répondait un charabia répétitif à ~550 t/s, réponse vide,
sans une erreur dans le journal, et a été couronné deux fois avant qu'un
garde-fou n'existe ; Qwen3-Coder-Next y répondait « LAMPAMPAMP ». Les deux sont
GUÉRIS par le runtime retained-PM4 de l'image (comptages justes, 18/09/2026),
ce qui ne rend pas le contrôle inutile : il est justement là pour le prochain
bump d'image. Si un chiffre semble « trop beau », vérifier à la main :

```bash
curl -s localhost:8009/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<modèle>","messages":[{"role":"user","content":"Écris une fonction Python qui inverse une liste chaînée."}],"max_tokens":200}' \
  | python3 -c 'import json,sys; m=json.load(sys.stdin)["choices"][0]["message"]; print(repr((m.get("reasoning_content") or "")[:300])); print(repr(m["content"][:300]))'
./setup-llm.sh --logs --tail 400 | grep -i "warn\|error\|cpu"
```

Pour un modèle destiné à l'agentic long (gros dossiers en contexte), le
bench à ~1500 tokens ne suffit pas : mesurer aussi en profondeur, hors
service (⚠ `llama-bench` de l'HÔTE, donc le fork Vulkan, pas l'image : c'est
un ordre de grandeur, pas la mesure du service) :

```bash
./setup-llm.sh --stop
tools/bench-depth.sh ~/models/<dossier>/<gguf>    # 0 / 16k / 32k
./setup-llm.sh --start
```

Un `--image-update` change les noyaux et rouvre la question, comme un
changement de quant : refaire ce contrôle après chaque bump d'image.

Critère de passage : `--bench-sanity` répond juste (`tools/qualif-modele.sh`
s'ARRÊTE sinon), le texte généré est lisible, et toute anomalie est notée dans
le commentaire du bloc avec la révision d'image et le symptôme.

## 4. spec-tune (longueur de draft MTP)

```bash
./setup-llm.sh --spec-tune <modèle>            # k = 2,4,6 par défaut, 4 passes
./setup-llm.sh --spec-tune <modèle> 2,4,6,8 4  # plage et passes explicites
```

Restart entre chaque k, mesure réelle via l'API sur `prompts/spec-test.txt`,
calibration du modèle alpha, écriture du gagnant dans `spec-nmax.conf`.
À moins de 2 % d'écart, le plus petit k gagne.

Sur un `spec-type` en liste (n-gram + MTP) la commande mesure en
`draft-mtp` seul le temps du réglage (`SPEC_TYPE_FORCE`), la liste revient
au restart final.

Attention, ce forçage vaut `draft-mtp` quelle que soit la liste. Sur un modèle
servi par un **drafter externe** (`ngram-map-k,draft-dflash`), `--spec-tune`
mesurerait donc la tête MTP et non le drafter réellement servi. Y régler le n-max par
`--spec-ab` (`spec-draft-n-max=4` contre `=7`…), et reporter le retenu dans
`lib/models.sh` avec ses chiffres.

Critère de passage : `spec-nmax.conf` contient la ligne du modèle, et le
commentaire du bloc cite les t/s par k, la date, le device et l'étiquette de
moteur. Relancer après tout changement de quant, de moteur (build `bNNNNN` ou
commit `strix-<commit>`) ou de device : la courbe dépend du backend (27B Q4,
optimum 4 sur ROCm0 et 6 sur Vulkan0) et le découpage mat-vec du fork a fait
passer ce même modèle de 6 à 4 (+6,8 %, 13/09/2026).

## 5. spec-ngram-tune (longueur de draft n-gram)

Seulement si `ngram-map-k` est dans le `spec-type`. Pour un modèle **sans
MTP** (ou avant d'ajouter n-gram à un modèle MTP déjà réglé), commencer
par la courbe seule, hors service :

```bash
./setup-llm.sh --stop
DEV=Vulkan0,ROCm0 REPS=5 tools/bench-spec-batch.sh ~/models/<dossier>/<gguf>
./setup-llm.sh --start
```

Sortie dans `logs/spec-batch.log` (lisible) et `logs/spec-batch.tsv`. La courbe ne
tranche jamais seule : même « défavorable » (seuil de non-perte au-dessus
de 25 % du draft partout), elle propose deux tailles à mesurer, parce qu'un
miss n-gram ne coûte qu'une sonde de hash et que seuls les hits paient le
batch (DeepSeek V4, 21/08/2026 : +9 % réels malgré une courbe à 45 %).
Ajouter `ngram-map-k` au `spec-type` (+ `size-m`, `min-hits 2`) et lancer
le tune ci-dessous : sur un modèle sans MTP il mesure d'abord une référence
sans spéculation et n'écrit rien si aucun `size_m` ne la bat. C'est ce
résultat, pas la courbe, qui décide de garder ou de retirer le bloc. Limite connue : sans MTP, `--spec-test` affiche
la mesure mais ne l'écrit pas dans `logs/spec-tests.log` (pas de n-max), le
tune fonctionne mais sans historique, noter les chiffres dans le
commentaire du bloc.

```bash
./setup-llm.sh --spec-ngram-tune <modèle> 4
```

Deux temps : courbe `t_forward(batch)` par llama-bench (service arrêté)
pour localiser la marche de noyau ggml et sortir deux candidats (sûr sous
la marche, large qui amortit le coût fixe), puis arbitrage des candidats
sur mesure réelle avec `prompts/spec-refactor.txt` (le seul prompt où les
n-grams ont des hits). Gagnant écrit dans `spec-ngram.conf`.

Sur un modèle servi par un **drafter externe** (`ngram-map-k,draft-dflash`,
`…,draft-dspark`), `tools/qualif-modele.sh` ne passe pas par cette commande
mais par `--spec-ab` : l'arbitrage de `--spec-ngram-tune` se fait contre une
référence « sans spéculation » (`spec-type none`) qui ne dit rien ici, la
bonne référence étant le drafter seul, réellement servi ; et `--spec-ab`
n'écrit dans aucune conf, ce qui laisse le choix au commentaire du bloc.

Lire la courbe : sur Vulkan, denses comme MoE ont une marche x2 entre
batch 8 et 9 (`mul_mat_vec_max_cols = 8`), mesurée le 21/08/2026 sur le 27B
dense et le 35B-A3B. La différence est la pente sous la marche : quasi
plate sur un dense (batch 8 = 1,2x le batch 1), raide sur un MoE (1,9x, le
trafic mémoire croît avec l'union des experts routés), donc un gain n-gram
bien plus faible. Un balayage grossier ne voit pas la marche, c'est le
raffinement automatique qui la trouve : ne pas conclure sur la première
table affichée. Une courbe défavorable n'interdit rien : elle abaisse
l'attente, et la mesure tranche.

Toute autre comparaison (min-hits, size-n, `ngram-map-k4v` contre
`ngram-map-k`, une taille que le tune ne propose pas, un n-max de drafter
externe, un drafter contre un autre, une référence sans spéculation) passe par
`--spec-ab` : une variante = des surcharges `clé=val;clé=val` du corps ini
(`base` = la configuration courante), et pour chacune ini régénéré, restart,
`--spec-test`, puis bilan comparé et **retour à la configuration courante**,
Ctrl-C compris. Rien n'est écrit dans les conf : le choix se reporte à la main
dans `lib/models.sh`, avec ses chiffres.

```bash
./setup-llm.sh --spec-ab <modèle> 4 - base "spec-ngram-map-k-min-hits=1" "spec-ngram-map-k-min-hits=3"
./setup-llm.sh --spec-ab <modèle> 4 - "spec-type=none" base "spec-ngram-map-k-size-m=15"
./setup-llm.sh --spec-ab <modèle> 4 - base "spec-type=ngram-map-k4v,draft-mtp;spec-ngram-map-k4v-size-m=47"
./setup-llm.sh --spec-ab <modèle> 4 - base "spec-draft-n-max=4"   # n-max d'un drafter externe
```

(C'est la forme outillée de ce qui a été fait à la main pour DeepSeek le
21/08/2026 : `--spec-test` + `SPEC_NGRAM_FORCE` + `--preload < /dev/null` +
restart.) Pour un modèle sans MTP, `--spec-test` affiche la mesure mais ne
l'écrit pas dans `logs/spec-tests.log` : noter les chiffres tout de suite
dans le tableau de l'étape 6.

Critère de passage : `spec-ngram.conf` contient la ligne du modèle (ou le
bloc n-gram a été retiré parce que rien ne bat la référence), le
commentaire du bloc cite la référence, les candidats, leurs t/s et
acceptances.

## 6. bench final et récap de performance (tableau partageable)

Une dernière mesure telle que servie, avec tous les réglages retenus et le
service dans son état normal, puis selon le rôle du modèle :

```bash
./setup-llm.sh --bench <modèle> 3            # toujours : journalisé et comparé au run précédent
./setup-llm.sh --bench-parallel <modèle>     # si parallel > 1 : ce que vaut le N choisi
./setup-llm.sh --bench-cache <modèle>        # si usage agentic : part du prompt repayée à chaque tour (62 à 66 % sur les archs récurrentes, 99 % en attention pure)
./setup-llm.sh --bench-load <modèle>         # si chargé à la demande : coût d'une bascule LRU
```

`--bench` écrit dans `logs/bench.log` et signale tout écart de plus de 5 %
avec le run précédent du même GGUF/device **et du même mode EC** : à relancer
après chaque changement de moteur (paquet ou commit du fork). Faute de run de
même mode, le comparateur garde le dernier run et le dit (« mode EC différent :
X contre Y, écart non comparable »). Le comparateur ne sait pas qu'un réglage
a changé entre deux runs : une « régression » annoncée après un retrait
d'option se justifie dans le récap, elle ne se corrige pas.

Piège de l'**OOM du routeur** sur une suite de gros modèles (`--bench all`) : la
politique LRU ignore la taille des modèles, et `--models-max` (préchargés + 1)
autorise deux géants résidents à la fois. Le routeur a été tué deux fois par
l'OOM killer le 13/09/2026 (Laguna 73 Go chargé pendant que gpt-oss 59 Go
tenait encore, puis DeepSeek 104 Go). Décharger explicitement le précédent
(`POST /models/unload` du routeur) ou ordonner la suite du plus petit au plus
gros. Le service se relance seul, mais la mesure en cours est perdue.

Puis rassembler les chiffres dans un tableau unique, à coller dans le message
de commit, le README ou un artefact partagé. Toujours préciser machine,
moteur (`bNNNNN` ou `strix-<commit>`), quant, device, date et mode EC
(`/sys/class/ec_su_axb35/apu/power_mode` : `balanced` ou `performance`, lu et
journalisé par les mesures) : un chiffre sans ces six colonnes n'est pas
comparable. Mesuré le 16/09/2026, `balanced` coûte 10 à 13 % de décode sur tous
les modèles sauf un dense (Muse, 3 %) ; un tableau pris en `balanced` ne se
compare pas à un tableau pris en `performance`. Ce n'est pas le profil de
`powerprofilesctl`, qui en est décorrélé.

```markdown
### qwen3.8-27b-dflash-nothink : Qwen3.8-27B-UD-Q4_K_XL.gguf (17 Go), bigchuck (Ryzen AI MAX+ 395), fork strix-0007bc6, mode EC performance, 13/09/2026

| Configuration | Device | Prompt t/s | Gen t/s | Acceptance | Source |
|---|---|---|---|---|---|
| ngram 47 + draft-mtp, n-max 6 | Vulkan0 | n/c | 53,8 | 0,67 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 47 + draft-mtp, n-max 4 | Vulkan0 | n/c | 57,6 | 0,71 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 47 + draft-dflash, n-max 7 | Vulkan0 | n/c | 64,5 | 0,67 | --spec-ab, 4 passes (spec-refactor.txt) |
| draft-dflash seul, n-max 7 | Vulkan0 | n/c | 47,0 | 0,96 | --spec-ab, 4 passes (spec-refactor.txt) |
| ngram 47 + draft-dflash, n-max 7 | Vulkan0 | 359 | 32,6 | 0,595 | --bench, 3 passes (bench-task) |

Retenu : ngram-map-k 47 + draft-dflash 7 (spec-ngram.conf, spec-draft-n-max
dans lib/models.sh). Paquet Arch b10433, même GGUF, ancien réglage MTP :
261 / 29,5 / 0,65 (autre série, citée pour situer, pas pour comparer à la décimale).
```

(exemple réel ; « n/c » = non conservé : `--spec-ab` ne journalise pas le
prefill, c'est `--bench` qui le donne.)

Règles du tableau :

- une ligne par (configuration, device) mesurée, médianes hors première
  passe ;
- le prompt de mesure dans la colonne Source : `spec-test.txt` et
  `spec-refactor.txt` ne se comparent pas entre eux ;
- une seule série de moteur par tableau ; la valeur de l'autre série se cite
  entre parenthèses ou en note, jamais dans la même colonne ;
- un seul mode EC par tableau, pour la même raison (10 à 13 % de décode) : le
  mode est affiché en en-tête de `--bench`, `--spec-test`, `--spec-ab`,
  `tools/spec-isolate.sh` et `tools/qualif-modele.sh`, et journalisé en fin de
  ligne de `logs/bench.log`, `logs/spec-tests.log` et `mesures.tsv` ;
- la dernière ligne dit ce qui est retenu et dans quel `.conf` ;
- les mêmes chiffres vont, résumés, à trois endroits versionnés : le
  commentaire du bloc `lib/models.sh` (date, moteur, device, quant), la table
  « Parc au <date> » du README, et la section « Paquet Arch contre fork »
  de `docs/HISTORIQUE.md` quand la mesure oppose les deux séries ;
- mettre à jour la ligne du modèle dans `docs/perfs.tsv` (mêmes chiffres,
  point décimal) puis régénérer les figures du README :
  `python3 py/perf_graphs.py`. Les trois SVG de `docs/graphs/` se commitent
  avec le reste, ils ne sont pas produits à la volée.

Sources des chiffres : `logs/spec-tests.log` (TSV, colonnes spec-type et
prompt), `logs/spec-batch.log` / `.tsv` (courbes) et la sortie de `--bench`.

## 7. bench-agentic : le modèle en vraie boucle de tool calls

Le tableau de l'étape 6 mesure du débit sur des requêtes isolées ; il ne dit
pas si le modèle tient une boucle agentic (tool calls bien formés, edit qui
aboutit, test relancé jusqu'au vert) ni ce que coûte le cache au fil des
tours. C'est l'objet de `--bench-agentic` : pi dans un conteneur jetable
(`bench-agentic/`, docker requis sur la machine du service, réseau hôte),
un appel froid mesuré à part (la première question de la conversation :
prompt système de pi, 1,5 k tokens, payé une fois par conversation, sauf si
le serveur l'a encore en cache-ram) puis N passes de cinq scénarios (réponse simple,
write+bash+read, edit, création d'un module + tests, correction d'un bug
sans toucher au test), en direct sur `:8009`.

```bash
./setup-llm.sh --bench-agentic <modèle> 3
```

Par scénario : PASS/passes et médianes du temps mur, du prompt (et part
servie du cache), des tokens générés, du prefill et du décode réels lus
sur `/metrics?model=`. Trois passes, pas une : à temp > 0 le même bug se
corrige en un tour ou en trois (Ornith, 28/08/2026 : 6,7 s contre 49 s
sur le scénario 5, même jour, même build). Lire :

- un scénario en échec = le modèle, pas le serveur : c'est le résultat,
  à mettre en face de son débit ;
- part du cache 89 à 98 % en continuation sur une arch récurrente (GDN),
  et un décode qui chute avec le nombre de tours (les re-prefills au
  dernier checkpoint sont comptés dedans) : c'est le coût du 62 % du
  `--bench-cache`, vu du client ;
- le décode médian des scénarios 2 à 5 doit rejoindre celui du `--bench`
  (Ornith, 28/08/2026 : 71 t/s partout contre 70,7 au `--bench`) ; s'il
  est nettement en dessous, le prefill mange le temps (historique repayé),
  pas la génération.

Sur un modèle à `parallel > 1` destiné à un orchestrateur et ses sous-agents,
ajouter un 3e argument : `./setup-llm.sh --bench-agentic <modèle> 2 <N>` joue
chaque passe d'abord seule puis à `N` boucles pi simultanées (2 à 3, le nombre
de slots réellement vus), la série seule ne disant rien de ce cas. Le facteur
de débit de tâches se lit ainsi : `(N x temps solo) / temps parallèle`, donc
x1 = le serveur sérialise (les boucles font la queue, `parallel` trop bas) et
xN = le batch sert les N boucles pour le prix d'une ; entre les deux, c'est le
gain réel à attendre d'un sous-agent de plus.

Critère de passage : 5/5 sur au moins une passe, une ligne dans le tableau
de l'étape 6 (« Boucle agentic réelle » dans `docs/HISTORIQUE.md`) avec pi, build,
date, et le résumé dans le commentaire du bloc (verdict, part du cache).

## Déroulé quand la machine de mesure n'est pas celle du dépôt

Le dépôt est aussi cloné sur la machine qui héberge le service : pousser la
branche, puis là-bas `git pull --ff-only` avant chaque série de commandes,
lancer les commandes du projet, ne rien commiter ni éditer sur place (les
`.conf` et journaux y sont écrits par les commandes, c'est leur place).
Vérifier `git status` propre et `bash tests/py-golden.sh` après le pull.
Une mesure à la fois ; les longues (rechargement de 100 Go, 4 passes) se
lancent en arrière-plan avec leur sortie dans un fichier, et on lit la
sortie complète avant de conclure, pas seulement la dernière ligne.

## Clôture

- `./tests/py-golden.sh` si un `py/*.py` a bougé, `./tests/sh-unit.sh` si
  `_llama_bin` / `_llama_build` (lib/common.sh) ou `FORK_ONLY_KEYS` /
  `_fork_keys_guard` (lib/fork.sh) ont bougé, `bash -n` sur les fichiers
  touchés (`sh -n` sur `bench-agentic/*.sh`).
- Commit par étape (bloc, puis réglages mesurés), message avec les
  chiffres et l'étiquette de moteur. Les `.conf` et logs restent locaux
  (.gitignore) : ce qui doit survivre à la machine va dans le commentaire du
  bloc.
- **Renommer une section** (changement de drafter : `-mtp-nothink` →
  `-dflash-nothink`) casse les `.conf` non versionnés de la machine de mesure,
  indexés par nom de section : renommer la clé dans `spec-nmax.conf`,
  `spec-ngram.conf` et `preload.conf` sur bigchuck, sans quoi le modèle repart
  silencieusement sur les valeurs par défaut du script (et sort du
  préchargement).
- Si le modèle remplace un autre : le retirer de `lib/models.sh`, noter la
  date dans le commentaire `KNOWN_FILES`, et signaler que
  `./setup-llm.sh --cleanup` purgera l'ancien GGUF (ne pas le lancer
  sans demande).
