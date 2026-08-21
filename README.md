# LLM Setup

LLM Setup pilote un `llama-server` en router mode natif sur une machine Strix Halo
(Ryzen AI Max+ 395, 128 Go unifiés, CachyOS/Arch), avec un seul point d'entrée :
`./setup-llm.sh`.

Ce qu'il gère :

- téléchargement des GGUF depuis Hugging Face (`hf`, mises à jour par etags) ;
- génération de `~/models/models.ini` : les réglages de chaque modèle vivent
  dans `lib/models.sh` avec leurs justifications en commentaire ;
- préchargement always-on ou chargement à la demande (LRU) ;
- mesure des perfs par l'API du serveur (`--bench`, `--bench-devices`,
  `--spec-test`) ;
- réglage de la spéculation par mesure : MTP (`spec-draft-n-max`, calibration
  α) et n-gram (`spec-ngram-map-k-size-m`, courbe de coût du batch puis
  arbitrage réel) ;
- service systemd user.

Les backends ggml (Vulkan par défaut, ROCm/HIP optionnel) sont des paquets
Arch séparés depuis le split de mi-août 2026. Tout est piloté par des fichiers
de conf locaux à côté du script (non versionnés, propres à la machine). Le `models.ini` est généré, jamais édité.

## Prérequis

- Arch/CachyOS, `paru`, bash 4.3 ou plus, python3 (stdlib seule), curl.
- `hf` (python-huggingface-hub, python-hf-xet). `gum` optionnel (menus).
- Paquets llama.cpp : `llama-cpp`, plus les backends ggml splittés :
  `ggml-cpu` et `ggml-vulkan` (obligatoires, installés par `--setup`).
- Pour ROCm0 : `ggml-hip` et le runtime ROCm (`rocm-hip-runtime`, `hipblas`,
  `rocblas`, `hipblaslt`). Le runtime seul ne suffit pas. Contrôle :
  `rocminfo | grep gfx` doit donner `gfx1151`.

## Installation

```bash
./setup-llm.sh --setup            # dépendances, GGUF, préchargement, models.ini
./setup-llm.sh --install-service  # service systemd user llama-server (démarrage au boot via linger)
systemctl --user start llama-server
```

## Sous-commandes

| Commande | Rôle |
|---|---|
| `--setup` | Installe les dépendances, propose ROCm, télécharge les GGUF manquants, sélectionne le préchargement, génère le ini |
| `--update [modèle]` | Comme `--setup`, mais laisse `hf` comparer les etags : seul ce qui a bougé est retéléchargé |
| `--cleanup [--yes]` | Supprime les dossiers et GGUF orphelins (dry-run par défaut) |
| `--preload` | Re-sélectionne les modèles always-on et régénère le ini |
| `--bench [modèle\|all] [n]` | Mesure le serveur tel qu'il tourne : prefill, décode médian, acceptance MTP, tableau récapitulatif. N'écrit rien |
| `--bench-devices [modèle] [devices] [n]` | Compare les devices d'un modèle (défaut Vulkan0,ROCm0) : bench avec restart par device, verdict par temps de tour simulé, vainqueur écrit dans `bench-devices.conf` (détail dans ARCHITECTURE.md) |
| `--bench-parallel [modèle] [n] [passes]` | Débit sous `n` requêtes simultanées (défaut : le `parallel` du modèle) : agrégé et décode par requête contre 1 requête ; montre ce que vaut `parallel = N` et la file d'attente au-delà |
| `--bench-cache [modèle]` | Efficacité du cache de prompt sur le pattern agentic (contexte froid, tour suivant, édition au milieu, requête identique) : part du prompt servie du cache et prefill à chaque fois ; c'est la mesure de `cache-ram` / `ctx-checkpoints` / `cache-reuse` |
| `--list-devices` | Backends ggml installés et devices exposés, croisés avec `bench-devices.conf` |
| `--spec-test [modèle] [n] [prompt]` | Décode réel via l'API (spéculation incluse), journalise, calibre et persiste le n-max dès 2 valeurs mesurées. Prompt par défaut `spec-test.txt` ; un autre prompt est journalisé à part et ne calibre pas |
| `--spec-tune [modèle] [k1,k2,..] [n]` | Boucle automatique sur plusieurs n-max avec restart entre chaque, retient le meilleur mesuré |
| `--spec-ngram-tune [modèle] [n] [prompt]` | Règle la longueur de draft n-gram (`spec-ngram-map-k-size-m`) : courbe `t_forward(batch)` pour localiser la marche de noyau ggml, puis arbitrage des candidats sur mesure réelle (prompt de refactor par défaut) |
| `--start` | Lance llama-server sur le port 8009 (commande du service) |
| `--install-service`, `--uninstall-service` | Service systemd user (systemctl --user) |
| `--help` | Aide, liste des modèles et des clés de téléchargement |

## Workflow typique

```bash
./setup-llm.sh --setup                # première mise en place
./setup-llm.sh --bench all            # perfs de tous les modèles présents
./setup-llm.sh --bench-devices        # Vulkan ou ROCm pour un modèle ?
./setup-llm.sh --spec-tune            # règle spec-draft-n-max d'un modèle MTP
./setup-llm.sh --spec-ngram-tune      # règle la longueur de draft n-gram
./setup-llm.sh --update qwen3.8-27b   # après un re-upload unsloth
```

## Mesures de perfs (--bench)

Le script ne mesure jamais les GGUF directement : tout passe par l'API du
serveur tel qu'il tourne (`/v1/chat/completions`), donc avec les réglages
réels du `models.ini` (quantisation du cache KV, flash-attn, spéculation MTP
incluse). Un chiffre de bench est un chiffre de production, pas un
`llama-bench` sur les poids nus.

`--bench` envoie n passes (défaut 3) par modèle, toutes avec le même prompt :

- la passe 1 porte un long contexte réaliste (`prompts/bench-context.txt`,
  un cahier des charges, plus la tâche `prompts/bench-task.txt`). Le serveur
  doit le calculer entièrement : c'est la mesure de prefill. La taille qui
  fait foi est le `n=` affiché sur la passe, pas une taille visée ;
- les passes suivantes resoumettent le même contexte, servi par le prompt
  cache : le temps est dominé par la génération, c'est la mesure de décode
  (et d'acceptance MTP le cas échéant). Le récap donne la médiane hors
  passe 1.

La mesure est passive : rien n'est écrit, pas de restart, pas de purge de
cache. Si la passe 1 a été partiellement servie par le cache (le modèle
avait déjà vu un préfixe du prompt), le prefill est marqué `*` au récap :
signalé comme non comparable, jamais corrigé.

Comparabilité : les chiffres dépendent des prompts de `prompts/`. Modifier
`bench-context.txt` ou `bench-task.txt` invalide la comparaison avec les
tableaux antérieurs ; ne jamais les toucher au détour d'un autre changement.

## Choix du device (--bench-devices)

Chaque modèle peut tourner sur Vulkan0 (défaut) ou ROCm0, et le meilleur
choix varie selon le modèle : ROCm est souvent devant en prefill, Vulkan en
décode. `--bench-devices` tranche automatiquement, sans édition manuelle :

```bash
./setup-llm.sh --bench-devices                          # choix interactif du modèle
./setup-llm.sh --bench-devices qwen3.8-27b-mtp-nothink  # modèle donné
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
prefill et l'autre le décode. Exemple réel (qwen3.8-27b-mtp-nothink) :
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

## Spéculation n-gram (--spec-ngram-tune)

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

Mesuré le 21/08/2026 sur Vulkan0 : 27B Q4 et Qwopus Q5 retiennent 47
(+8 % et +16 % sur 7), le 35B-A3B MoE retient 7 (sa pente sous la marche
est trop raide pour amortir un draft large). Un run en `spec-type` mixte est
journalisé mais exclu de la calibration α (k variable par forward) ; pour la
même raison `--spec-tune` mesure en `draft-mtp` seul le temps du réglage.

Pour explorer sans régler (autre GGUF, comparer ROCm0 et Vulkan0, modèle
sans MTP) : `tools/bench-spec-batch.sh` (voir Outils).

## Résultats mesurés (bigchuck, 21/08/2026)

Machine : AMD Ryzen AI MAX+ 395 (Radeon 8060S, 124 Go de mémoire unifiée),
CachyOS noyau 7.1.8, llama-cpp b10433 / ggml 0.20.0. Médianes hors première
passe, 4 passes sauf mention. Les lignes `spec-test.txt` (écriture d'un module
de zéro, meilleur cas MTP) et `spec-refactor.txt` (recopie de blocs exacts,
le cas n-gram) ne se comparent pas entre elles.

| Modèle | GGUF | Device | Configuration | Gen t/s | Acceptance | Prompt |
|---|---|---|---|---|---|---|
| qwen3.8-27b-mtp-nothink | UD-Q4_K_XL (17 Go) | Vulkan0 | draft-mtp n-max 2 | 26,8 | 0,95 | spec-test |
| | | | draft-mtp n-max 4 | 31,8 | 0,85 | spec-test |
| | | | **draft-mtp n-max 6** (retenu) | **33,1** | 0,75 | spec-test |
| | | | ngram-map-k 7 + mtp 4 | 44,0 | 0,94 | spec-refactor |
| | | | **ngram-map-k 47 + mtp 4** (retenu) | **47,4** | 0,73 | spec-refactor |
| | | ROCm0 (15/08) | draft-mtp n-max 2 / 4 / 6 | 22,2 / 25,5 / 26,0 | | spec-test |
| qwopus3.6-27b-coder-mtp-nothink | Q5_K_M | Vulkan0 | ngram-map-k 7 + mtp 4 | 43,9 | 0,95 | spec-refactor |
| | | | **ngram-map-k 47 + mtp 4** (retenu) | **50,7** | 0,78 | spec-refactor |
| qwen3.6-35b-a3b-mtp-nothink | UD-Q4_K_XL (MoE) | Vulkan0 | **ngram-map-k 7 + mtp 4** (retenu) | **110,3** | 0,93 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 105,3 | 0,71 | spec-refactor |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go, MoE) | Vulkan0 | sans spéculation | 11,3 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **12,3** | 0,9 sur les hits | spec-refactor |
| | | | ngram-map-k 31 | 11,8 | 0,27 à 0,66 | spec-refactor |
| | | ROCm0 | sans spéculation | ~550 (**charabia**, exclu) | | bench |

Prefill (passe 1, cache froid) : 27B ~220 t/s sur spec-test, ~275 t/s sur
spec-refactor ; 35B-A3B ~865 t/s ; DeepSeek 108 à 120 t/s (Vulkan0).

Courbes `t_forward(batch)` sur Vulkan0 (`tools/bench-spec-batch.sh`, reps=5) :

| GGUF | batch 1 | batch 8 | batch 9 | batch 48 | Lecture |
|---|---|---|---|---|---|
| Qwen3.8-27B Q4 | 83 ms | 101 ms | 215 ms | 283 ms | marche x2,13 entre 8 et 9, plateau jusqu'à 16 |
| Qwopus3.6-27B Q5 | 89 ms | 106 ms | 257 ms | 310 ms | marche x2,42 |
| Qwen3.6-35B-A3B Q4 (MoE) | 17 ms | 33 ms | 68 ms | 136 ms | marche x2,06, mais pente raide sous la marche (batch 8 = 1,9x) |
| DeepSeek-V4-Flash IQ3 (MoE) | 83 ms | 302 ms | | 1087 ms | pas de marche, x3,6 dès le batch 8 : la courbe disait « non », la mesure a dit +9 % |

Enseignements : la marche Vulkan 8→9 (`mul_mat_vec_max_cols = 8`) vaut pour
les denses comme pour les MoE ; le régime large (47) gagne sur les denses,
le régime sûr (7) sur les MoE ; l'optimum du n-max MTP dépend du device
(4 sur ROCm0, 6 sur Vulkan0 pour le même GGUF) ; ROCm0 est inutilisable sur
DeepSeek V4 avec ce build (sortie dégénérée silencieuse, détectée depuis par
le garde-fou de `timings.py`).

## Fichiers de configuration

À côté du script, locaux et non versionnés (propres à la machine) :

| Fichier | Rôle |
|---|---|
| `bench-devices.conf` | clé (dossier GGUF) = device (Vulkan0/ROCm0), écrit par `--bench-devices`, édition manuelle OK |
| `preload.conf` | modèles préchargés, un par ligne |
| `spec-nmax.conf` | modèle = spec-draft-n-max retenu par les mesures |
| `spec-ngram.conf` | modèle = spec-ngram-map-k-size-m retenu par les mesures |
| `logs/spec-tests.log` | journal TSV des runs `--spec-test` |
| `logs/bench.log` | journal TSV des `--bench` (avec le build llama.cpp) ; chaque `--bench` se compare au run précédent du même modèle/GGUF/device et signale un écart de plus de 5 % |
| `logs/bench-parallel.log` | journal TSV des `--bench-parallel` |
| `logs/bench-cache.log` | journal TSV des `--bench-cache` |
| `logs/spec-batch.log` / `.tsv` | journal des balayages `tools/bench-spec-batch.sh` |

Côté `~/models/` : `models.ini`, généré. Ne jamais l'éditer : relancer
`--preload` ou `--setup`. Le routeur ne le lit qu'au démarrage, toute
modification demande un restart du service.

## Ajouter un modèle

Un seul endroit : un bloc dans `lib/models.sh`, à la position voulue dans le
ini (l'ordre de déclaration est l'ordre d'émission) :

1. `download_hf <dossier> <repo> VAR_PATH=<fichier>` (ou
   `download_hf_shards` avec le shard 00001 ; plusieurs `VAR=` pour un
   drafter MTP externe) — définit le chemin, alimente `KNOWN_FILES`
   (source unique de `--cleanup`) et les téléchargements de `--setup` ;
2. `llama_model <section> "<corps ini>"` avec son commentaire métier (sampling,
   cache, contraintes MTP) — un `download_hf` peut servir plusieurs
   sections (même GGUF) ;
3. `groupe "; --- titre ---"` avant le premier `llama_model` si nouvelle famille.

Exemple complet (le corps ini reprend la variable définie par
`download_hf`, qui doit donc être déclaré avant) :

```bash
groupe "; --- Mon-Modele 7B (nouvelle famille) ---"

# Mon-Modele 7B : pourquoi ce repo et ce quant (taille, reco amont, date)
download_hf mon-modele-7b "org/Mon-Modele-7B-GGUF" \
  MON_MODELE_7B_PATH="Mon-Modele-7B-UD-Q4_K_XL.gguf"

# Mon-Modele 7B : justification des réglages (sampling officiel, cache,
#   contraintes) ; ce commentaire est la connaissance métier du modèle
llama_model mon-modele-7b "
model            = $MON_MODELE_7B_PATH
ctx-size         = 32768
cache-ram        = 2048
temp             = 0.7
top-k            = 20
top-p            = 0.8
min-p            = 0.0
parallel         = 4"
```

Variantes : `download_hf_shards` prend le shard 00001 avec son sous-dossier
de quant (le glob de téléchargement en est dérivé) ; un appel `download_hf`
peut porter plusieurs `VAR=fichier` (ex : modèle + drafter spéculatif externe) ;
deux `llama_model` peuvent référencer le même `*_PATH` (même GGUF, cas Qwen3.8-27B).

Puis `./setup-llm.sh --update <dossier>` pour télécharger et régénérer.
Les garde-fous de préchargement (poids dupliqués) sont dérivés des
déclarations : même GGUF partagé, ou dossiers `<clé>` et `<clé>-mtp` — nommer
la variante MTP avec le suffixe `-mtp` suffit, rien d'autre à maintenir.

## Outils (tools/)

| Fichier | Rôle |
|---|---|
| `opencode-sync-model.sh` | Synchronise la liste des modèles du serveur (`/v1/models`) dans la config opencode (`~/.config/opencode/opencode.json`, provider `llamaswap`). Variables : `ENDPOINT`, `CONFIG`, `PROVIDER` |
| `bench-spec-batch.sh` | Courbe brute `t_forward(batch)` d'un ou plusieurs GGUF par `llama-bench`, hors service, sur un ou plusieurs devices (`DEV=Vulkan0,ROCm0`, `BATCHES`, `REPS`, `DEPTH`, `FA`). Analyse par `py/batch_curve.py`, journal `spec-batch.log` + `spec-batch.tsv`. Pour régler un modèle, préférer `--spec-ngram-tune` |
| `bench-depth.sh` | Prefill et décode selon la profondeur de contexte (`llama-bench -d`, défaut 0 / 16k / 32k, KV q8_0 comme le service), par device, avec le tour simulé de `--bench-devices` recalculé à chaque profondeur : c'est le régime agentic réel, où le classement des devices peut s'inverser. Journal `logs/bench-depth.log` + `.tsv` |
| `llm-setup.ts` | Extension pi : découvre les modèles sur `/v1/models` (ctx, n-predict, reasoning depuis `status.args`) et enregistre le provider `llamaswap`. A copier dans `~/.pi/agent/extensions/`. Variable : `LLAMASWAP_ENDPOINT` |

Les deux pointent sur `http://bigchuck:8009` par défaut (surchargeable par variable d'environnement).

## FAQ

**Un modèle échoue au chargement, ROCm0 a disparu.**
`--list-devices` croise `bench-devices.conf` avec les devices réellement
exposés. Réinstaller `ggml-hip`, ou forcer Vulkan0 dans la conf puis `--preload`.

**Je peux éditer models.ini ?**
Non, il est régénéré à chaque `--setup`, `--preload` ou `--spec-*`.
Éditer les fichiers `.conf` ou `lib/models.sh`.

**Pourquoi `parallel = 1` sur les modèles MTP ?**
Contrainte llama.cpp : `-np` supérieur à 1 et `--mmproj` ne sont pas supportés
avec MTP. Un modèle non-MTP séparé sur le même GGUF rend le parallélisme.
