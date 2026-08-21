---
name: ajout-modele
description: Procédure complète d'ajout d'un modèle dans ce dépôt (lib/models.sh) jusqu'au récap de performance partageable. À charger dès qu'on ajoute, remplace ou re-qualifie un modèle (nouveau GGUF, nouvelle quant, variante MTP, changement de device).
---

# Ajouter un modèle, de la fiche HF au tableau de perfs

Six étapes, dans l'ordre. Chacune a un livrable et un critère de passage ;
on ne passe pas à la suivante sans lui. Les commandes se lancent sur la
machine qui héberge le service (`./setup-llm.sh`, service systemd user
`llama-server`), jamais en parallèle les unes des autres : un seul GPU.

Lire `AGENTS.md` et `ARCHITECTURE.md` avant d'éditer. Le bloc de
`lib/models.sh` est la seule source de vérité du modèle ; ses commentaires
sont la connaissance métier et doivent citer les mesures (date, device,
quant) qui justifient chaque réglage.

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
| Thinking : défaut, kwargs de désactivation | template chat | `chat-template-kwargs`, `reasoning` |
| État récurrent (GDN, conv, Mamba) ou SWA | architecture | `cache-reuse 0`, `swa-full`, `ctx-checkpoints` |
| Vision (mmproj) | Files | texte seul sauf besoin, incompatible MTP |
| Date de dernier upload, repo squashé | commits HF | note « prévoir un --update » |

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

1. **Le GGUF porte-t-il une tête MTP ?** La fiche le dit (« MTP for fast
   inference », repo `-MTP` séparé, ou `nextn`/`mtp` dans les metadata).
   Si oui, la section spéculative s'appelle `<clé>-mtp` (ou
   `<clé>-mtp-nothink`) : `_preload_sanity` en dérive ses garde-fous.
2. **Veut-on la spéculation sur ce modèle ?** Contraintes à respecter :
   `parallel = 1` obligatoire, `cache-reuse = 0`, pas de mmproj. Sur une
   architecture à état récurrent (GDN des Qwen3.5+, conv LFM2), le rollback
   partiel sur rejet de draft est en mainline (PR #22673) mais n'a pas été
   validé ici sur Vulkan en boucle de tool calls : garder une variante sans
   spéculation pour l'agentic tant que ce n'est pas mesuré.

Si MTP : `spec-type = draft-mtp`, `spec-draft-n-max = 4` en valeur de
départ. Si on veut aussi les n-grams (modèle utilisé en édition de code,
où le prompt se ré-émet) : `spec-type = ngram-map-k,draft-mtp`,
`spec-ngram-map-k-size-m = 7`, `spec-ngram-map-k-min-hits = 2`, à régler à
l'étape 4.

Critère de passage : après restart, `curl localhost:8009/v1/models` montre
le `--spec-type` attendu dans `status.args`, et un premier
`./setup-llm.sh --spec-test <modèle> 2` affiche une acceptance (pas
« n/a ») : la tête MTP est bien chargée.

## 3. spec-tune (longueur de draft MTP)

```bash
./setup-llm.sh --spec-tune <modèle>            # k = 2,4,6 par défaut, 4 passes
./setup-llm.sh --spec-tune <modèle> 2,4,6,8 4  # plage et passes explicites
```

Restart entre chaque k, mesure réelle via l'API sur `prompts/spec-test.txt`,
calibration du modèle alpha, écriture du gagnant dans `spec-nmax.conf`.
À moins de 2 % d'écart, le plus petit k gagne.

Critère de passage : `spec-nmax.conf` contient la ligne du modèle, et le
commentaire du bloc cite les t/s par k, la date et le device. Relancer
après tout changement de quant, de build llama.cpp ou de device (la courbe
dépend du backend).

## 4. spec-ngram-tune (longueur de draft n-gram)

Seulement si `ngram-map-k` est dans le `spec-type`. Pour un modèle **sans
MTP** (ou avant d'ajouter n-gram à un modèle MTP déjà réglé), commencer
par la courbe seule, hors service :

```bash
systemctl --user stop llama-server
DEV=Vulkan0,ROCm0 REPS=5 tools/bench-spec-batch.sh ~/models/<dossier>/<gguf>
systemctl --user start llama-server
```

Sortie dans `spec-batch.log` (lisible) et `spec-batch.tsv`. La courbe ne
tranche jamais seule : même « défavorable » (seuil de non-perte au-dessus
de 25 % du draft partout), elle propose deux tailles à mesurer, parce qu'un
miss n-gram ne coûte qu'une sonde de hash et que seuls les hits paient le
batch (DeepSeek V4, 21/08/2026 : +9 % réels malgré une courbe à 45 %).
Ajouter `ngram-map-k` au `spec-type` (+ `size-m`, `min-hits 2`) et lancer
le tune ci-dessous : sur un modèle sans MTP il mesure d'abord une référence
sans spéculation et n'écrit rien si aucun `size_m` ne la bat. C'est ce
résultat, pas la courbe, qui décide de garder ou de retirer le bloc. Limite connue : sans MTP, `--spec-test` affiche
la mesure mais ne l'écrit pas dans `spec-tests.log` (pas de n-max), le
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

Lire la courbe : sur Vulkan, denses comme MoE ont une marche x2 entre
batch 8 et 9 (`mul_mat_vec_max_cols = 8`), mesurée le 21/08/2026 sur le 27B
dense et le 35B-A3B. La différence est la pente sous la marche : quasi
plate sur un dense (batch 8 = 1,2x le batch 1), raide sur un MoE (1,9x, le
trafic mémoire croît avec l'union des experts routés), donc un gain n-gram
bien plus faible. Un balayage grossier ne voit pas la marche, c'est le
raffinement automatique qui la trouve : ne pas conclure sur la première
table affichée. Une courbe défavorable n'interdit rien : elle abaisse
l'attente, et la mesure tranche.

Critère de passage : `spec-ngram.conf` contient la ligne du modèle, le
commentaire du bloc cite les deux candidats, leurs t/s et acceptances.

## 5. bench (ROCm ou Vulkan)

```bash
./setup-llm.sh --bench-devices <modèle>        # Vulkan0,ROCm0, 3 passes
./setup-llm.sh --bench <modèle> 3              # perfs telles que servies
```

`--bench-devices` régénère le ini et redémarre par device, mesure un tour
d'usage simulé (prefill froid + génération) et écrit le vainqueur dans
`bench-devices.conf`, clé = dossier du GGUF (donc partagée par toutes les
sections qui utilisent ce fichier). Le bench ne mesure pas le chemin
spéculatif : après une bascule de device sur un modèle MTP, refaire les
étapes 3 et 4 (les seuils de noyau changent de backend) et vérifier
l'acceptance dans `--spec-test`.

Critère de passage : une ligne dans `bench-devices.conf` (ou la décision
explicite de rester sur le défaut), et les étapes 3 et 4 refaites si le
device a changé.

## 6. Récap de performance (tableau partageable)

Rassembler les chiffres dans un tableau unique, à coller dans le message
de commit, le README ou un artefact partagé. Toujours préciser machine,
build llama.cpp, quant, device et date : un chiffre sans ces cinq colonnes
n'est pas comparable.

```markdown
### qwen3.8-27b-mtp-nothink : Qwen3.8-27B-UD-Q4_K_XL.gguf (17 Go), bigchuck (Ryzen AI MAX+ 395), llama.cpp b10433, 21/08/2026

| Configuration | Device | Prompt t/s | Gen t/s | Acceptance | Source |
|---|---|---|---|---|---|
| draft-mtp, n-max 4 | ROCm0 | n/c | 25,5 | n/c | --spec-tune du 15/08 (spec-test.txt) |
| draft-mtp, n-max 4 | Vulkan0 | 220 | 31,4 | 0,82 | --spec-test (spec-test.txt) |
| ngram-map-k 7 + draft-mtp 4 | Vulkan0 | 277 | 44,0 | 0,94 | --spec-ngram-tune, 4 passes (spec-refactor.txt) |
| ngram-map-k 47 + draft-mtp 4 | Vulkan0 | 274 | 47,4 | 0,73 | --spec-ngram-tune, 4 passes (spec-refactor.txt) |

Retenu : ngram-map-k 47 + draft-mtp 4 sur Vulkan0 (spec-ngram.conf, spec-nmax.conf, bench-devices.conf).
```

(exemple réel ; « n/c » = non conservé, le journal de l'époque n'a pas
été gardé : c'est précisément ce que le tableau évite pour la suite.)

Règles du tableau :

- une ligne par (configuration, device) mesurée, médianes hors première
  passe ;
- le prompt de mesure dans la colonne Source : `spec-test.txt` et
  `spec-refactor.txt` ne se comparent pas entre eux ;
- la dernière ligne dit ce qui est retenu et dans quel `.conf` ;
- les mêmes chiffres vont, résumés, dans le commentaire du bloc
  `lib/models.sh` (date, device, quant), c'est là que les lecteurs
  suivants les chercheront.

Sources des chiffres : `spec-tests.log` (TSV, colonnes spec-type et
prompt), `spec-batch.log` / `.tsv` (courbes), sortie de `--bench` et
`--bench-devices`.

## Clôture

- `./tests/py-golden.sh` si un `py/*.py` a bougé, `bash -n` sur les
  fichiers touchés.
- Commit par étape (bloc, puis réglages mesurés), message avec les
  chiffres. Les `.conf` et logs restent locaux (.gitignore) : ce qui doit
  survivre à la machine va dans le commentaire du bloc.
- Si le modèle remplace un autre : le retirer de `lib/models.sh`, noter la
  date dans le commentaire `KNOWN_FILES`, et signaler que
  `./setup-llm.sh --cleanup` purgera l'ancien GGUF (ne pas le lancer
  sans demande).
