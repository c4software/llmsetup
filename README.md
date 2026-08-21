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
| `--bench-cache [modèle]` | Efficacité du cache de prompt sur le pattern agentic (contexte froid, tour suivant, édition au premier tiers, requête identique) : part du prompt servie du cache et prefill à chaque fois ; c'est la mesure de `cache-ram` / `ctx-checkpoints` / `cache-reuse` |
| `--bench-sanity [modèle\|all]` | Recopie exacte d'un code (`prompts/bench-sanity.txt`, trivial pour ne tester que le backend) : un device qui répond faux est exclu de `--bench-devices`, en plus du garde-fou anti-charabia |
| `--bench-load [modèle\|all]` | Temps de chargement + premier token après restart, puis TTFT à chaud : ce que coûte un modèle à la demande (base pour `preload.conf` et `--models-max`) |
| `--list-devices` | Backends ggml installés et devices exposés, croisés avec `bench-devices.conf` |
| `--spec-test [modèle] [n] [prompt]` | Décode réel via l'API (spéculation incluse), journalise, calibre et persiste le n-max dès 2 valeurs mesurées. Prompt par défaut `spec-test.txt` ; un autre prompt est journalisé à part et ne calibre pas |
| `--spec-tune [modèle] [k1,k2,..] [n]` | Boucle automatique sur plusieurs n-max avec restart entre chaque, retient le meilleur mesuré |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | A/B de réglages spéculatifs sur mesure réelle : chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |
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
./setup-llm.sh --spec-ab <m> 4 - base "spec-ngram-map-k-min-hits=1"   # compare des réglages
./setup-llm.sh --bench-parallel <m>   # ce que vaut parallel = N
./setup-llm.sh --bench-cache <m>      # part du prompt repayée à chaque tour (agentic)
./setup-llm.sh --bench-load <m>       # coût d'une bascule LRU
./setup-llm.sh --update qwen3.8-27b   # après un re-upload unsloth
./setup-llm.sh --bench all            # après chaque mise à jour de llama-cpp : régressions
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

Chaque `--bench` est journalisé dans `logs/bench.log` avec le build de
llama.cpp et comparé au run précédent du même modèle, GGUF et device : un
écart de plus de 5 % sur le prefill ou le décode est signalé, le changement
de build rappelé. `./setup-llm.sh --bench all` après chaque mise à jour du
paquet suffit donc à voir une régression (b10433 a cassé DeepSeek sur ROCm0
en silence : rien ne l'aurait vu sans mesure).

## Mesures complémentaires

Chacune écrit son journal TSV dans `logs/` (avec le build) et se lit seule ;
la procédure d'ajout d'un modèle (`AGENTS.md`, skill `ajout-modele`) dit
laquelle lancer selon le rôle du modèle.

| Commande | Question à laquelle elle répond | Méthode |
|---|---|---|
| `--bench-sanity [modèle\|all]` | Le backend produit-il un texte juste ? | recopie exacte d'un code (`prompts/bench-sanity.txt`), trivial pour ne tester que le backend ; `--bench-devices` l'applique avant chaque device, en plus du garde-fou anti-charabia de `timings.py` (mot dominant, mots distincts, répétition périodique de caractères) |
| `--bench-parallel [modèle] [n] [passes]` | Que vaut `parallel = N` ? | salves de 1 puis n requêtes simultanées (spec-test.txt, 400 tokens), débit agrégé et décode médian par requête ; `parallel` réel lu sur `/v1/models`, au-delà les requêtes font la queue |
| `--bench-cache [modèle]` | Combien du prompt est repayé à chaque tour ? | quatre requêtes : contexte froid, tour suivant, édition au premier tiers (préfixe commun 2/3, au-dessus du seuil `slot-prompt-similarity 0.5`), requête identique ; part servie du cache (`cache_n`) et prefill |
| `--bench-load [modèle\|all]` | Que coûte un modèle à la demande ? | restart du service, première requête chronométrée (chargement + premier token), puis TTFT à chaud |
| `--spec-ab <modèle> <n> <prompt\|-> <variante>...` | Ce réglage vaut-il mieux que celui-là ? | chaque variante (`clé=val;clé=val` sur le corps ini, ou `base`) est appliquée au ini, le service redémarré, `--spec-test` mesuré ; bilan comparé, rien d'écrit dans les conf |
| `tools/bench-depth.sh <gguf>` | Et à 32k de contexte ? | `llama-bench -d`, hors service, prefill et décode à 0 / 16k / 32k par device, tour simulé par profondeur |
| `tools/bench-spec-batch.sh <gguf>` | Quelle longueur de draft n-gram le device amortit-il ? | `llama-bench -p`, courbe `t_forward(batch)`, marches de noyau, candidats sûr et large |

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
CachyOS noyau 7.1.8, llama-cpp **b10433 / ggml 0.20.0** jusqu'à 16:20, puis
**b10548 / ggml 0.20.2** (mise à jour système pendant la campagne : gpt-oss à
partir de son `--bench`, et tout Laguna, sont sur b10548 ; la colonne build
des journaux `logs/` fait foi). Médianes hors première passe, 4 passes sauf
mention. Les lignes `spec-test.txt` (écriture d'un module
de zéro, meilleur cas MTP) et `spec-refactor.txt` (recopie de blocs exacts,
le cas n-gram) ne se comparent pas entre elles.

### Récapitulatif par modèle

| Modèle | GGUF | Device | Réglage retenu | Prefill t/s | Gen t/s | État |
|---|---|---|---|---|---|---|
| lfm2.5-2.6b | Q8_0 (2,7 Go) | Vulkan0 (mesuré) | parallel 4 | 2279 | 67,7 (205 agrégés à 4 requêtes, x3,06) | cache tour suivant 62 % ; chargement 0,5 s, TTFT 27 ms |
| qwen3.5-9b | UD-Q6_K_XL (8,2 Go) | Vulkan0 (mesuré) | parallel 4 | 837 | 25,7 (78,6 agrégés à 4, x3,06) | cache 62 % ; chargement 1,9 s |
| qwen3.6-35b-a3b-nothink | UD-Q6_K_XL (29 Go) | Vulkan0 (mesuré) | parallel 2, sans spéculation | 640 | 53,1 (72,2 agrégés à 2, x1,43) | cache 62 % |
| qwen3.6-35b-a3b (thinking) | idem | Vulkan0 (mesuré) | parallel 3 | 874 | 52,5 (90,7 agrégés à 3, x1,73) | |
| qwen3.6-35b-a3b-mtp-nothink | UD-Q4_K_XL (22 Go) | Vulkan0 (mesuré : ROCm0 711 / 69,3) | ngram-map-k 7 + draft-mtp 4 (confirmé, k2/4/6 = 79,5 / **86,3** / 82,2) | 955 | 79,5 (bench, acc. 0,70) ; **110,3** (refactor) | chargement 36 s depuis le disque |
| qwen3.8-27b (thinking) | UD-Q4_K_XL (17 Go) | Vulkan0 (mesuré) | sans spéculation | 215 (289 → 183 à 32k en llama-bench) | 12,1 | |
| qwen3.8-27b-mtp-nothink | idem | Vulkan0 (mesuré) | ngram-map-k 47 + draft-mtp 6 | 261 | 29,5 (bench, acc. 0,65) ; **56,1** (refactor) ; 33,1 (spec-test, MTP seul) | chargement 4,4 s |
| qwopus3.6-27b-coder-mtp-nothink | Q5_K_M (19 Go) | Vulkan0 (mesuré : ROCm0 328 / 21,6) | ngram-map-k 47 + draft-mtp 4 (confirmé, k2/4/6 = 24,6 / **30,2** / 30,2) | 245 | 26,4 (bench, acc. 0,65) ; **50,7** (refactor) | cache 62 % ; chargement 4,5 s |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go) | Vulkan0 (mesuré) | ngram-map-k 7 | 110 | **12,3** (11,3 sans) | ROCm0 inutilisable (b10433) ; cache 99 % (attention pure) |
| qwen3-coder-next | UD-Q4_K_XL (47 Go) | Vulkan0 (mesuré, ROCm0 exclu) | ngram-map-k 47 (compromis : +47 % refactor, -5 % générique) | 457 | 46,2 sans ; **68,7** (refactor) ; 43,7 (bench) | ROCm0 répond « LAMPAMPAMP… » ; cache 64 % ; chargement 72 s depuis le disque |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE) | Vulkan0 (mesuré : ROCm0 219 / 31,5, juste lent) | ngram-map-k 7 | 333 (413 en bench-devices) | 51,9 sans ; **59,8** (refactor) | cache 99 % (attention, pas d'état récurrent) ; chargement 91 s depuis le disque |
| laguna-s-2.1 | UD-Q4_K_XL (73 Go, MoE) | Vulkan0 (mesuré : ROCm0 320 / 23,6) | n-gram : tune en cours ; **DFlash refusé par le mainline** (`wrong number of tensors; expected 76, got 69`, fork Poolside requis) | 247 | 28,6 (28,7 sans spéculation sur refactor) | b10548 |

Médianes hors première passe ; « cache » = part du prompt servie du cache
pour tour suivant / édition au milieu / requête identique. Détail ci-dessous.

### Spéculation

| Modèle | GGUF | Device | Configuration | Gen t/s | Acceptance | Prompt |
|---|---|---|---|---|---|---|
| qwen3.8-27b-mtp-nothink | UD-Q4_K_XL (17 Go) | Vulkan0 | draft-mtp n-max 2 | 26,8 | 0,95 | spec-test |
| | | | draft-mtp n-max 4 | 31,8 | 0,85 | spec-test |
| | | | **draft-mtp n-max 6** (retenu) | **33,1** | 0,75 | spec-test |
| | | | ngram-map-k 7 + mtp 4 | 44,0 | 0,94 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 47,4 | 0,73 | spec-refactor |
| | | | **ngram-map-k 47 + mtp 6** (retenu) | **56,1** | 0,80 | spec-refactor |
| | | ROCm0 (15/08) | draft-mtp n-max 2 / 4 / 6 | 22,2 / 25,5 / 26,0 | | spec-test |
| qwopus3.6-27b-coder-mtp-nothink | Q5_K_M | Vulkan0 | ngram-map-k 7 + mtp 4 | 43,9 | 0,95 | spec-refactor |
| | | | **ngram-map-k 47 + mtp 4** (retenu) | **50,7** | 0,78 | spec-refactor |
| qwen3.6-35b-a3b-mtp-nothink | UD-Q4_K_XL (MoE) | Vulkan0 | **ngram-map-k 7 + mtp 4** (retenu) | **110,3** | 0,93 | spec-refactor |
| | | | ngram-map-k 47 + mtp 4 | 105,3 | 0,71 | spec-refactor |
| qwen3-coder-next | UD-Q4_K_XL (MoE, GDN) | Vulkan0 | sans spéculation | 46,8 | | spec-refactor |
| | | | ngram-map-k 7 | 20,8 | 0,98 | spec-refactor : surcoût fixe par pas spéculatif, un petit draft ne l'amortit pas |
| | | | **ngram-map-k 47** (retenu) | **68,7** | | spec-refactor |
| | | | ngram-map-k 47 | 44,5 (min-hits 4 : 44,8) | 0,23 | spec-test : -5 % sans répétitions |
| gpt-oss | UD-Q4_K_XL (59 Go, MoE, SWA) | Vulkan0 | sans spéculation | 51,7 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **59,8** | | spec-refactor |
| | | | ngram-map-k 47 | 52,7 | | spec-refactor : le grand draft paie son batch x14,7 |
| deepseek-v4-flash | UD-IQ3_XXS (104 Go, MoE) | Vulkan0 | sans spéculation | 11,3 | | spec-refactor |
| | | | **ngram-map-k 7** (retenu) | **12,3** | 0,9 sur les hits | spec-refactor |
| | | | ngram-map-k 31 | 11,8 | 0,27 à 0,66 | spec-refactor |
| | | ROCm0 | sans spéculation | ~550 (**charabia**, exclu) | | bench |

Prefill (passe 1, cache froid) : 27B ~220 t/s sur spec-test, ~275 t/s sur
spec-refactor ; 35B-A3B ~865 t/s ; DeepSeek 108 à 120 t/s (Vulkan0).

### Courbes de batch

Sur Vulkan0 (`tools/bench-spec-batch.sh`, reps=5) :

| GGUF | batch 1 | batch 8 | batch 9 | batch 48 | Lecture |
|---|---|---|---|---|---|
| Qwen3.8-27B Q4 | 83 ms | 101 ms | 215 ms | 283 ms | marche x2,13 entre 8 et 9, plateau jusqu'à 16 |
| Qwopus3.6-27B Q5 | 89 ms | 106 ms | 257 ms | 310 ms | marche x2,42 |
| Qwen3.6-35B-A3B Q4 (MoE) | 17 ms | 33 ms | 68 ms | 136 ms | marche x2,06, mais pente raide sous la marche (batch 8 = 1,9x) |
| DeepSeek-V4-Flash IQ3 (MoE) | 83 ms | 302 ms | | 1087 ms | pas de marche, x3,6 dès le batch 8 : la courbe disait « non », la mesure a dit +9 % |
| Qwen3-Coder-Next Q4 (MoE, GDN) | 21 ms | 46 ms | marche | 199 ms | x2,16 au batch 8 ; en réel, surcoût fixe par pas spéculatif, seul 47 gagne |
| gpt-oss-120b Q4 (MoE, SWA) | 17 ms | 57 ms | | 246 ms | x3,4 au batch 8, x14,7 au batch 48 : la plus raide |

### Profondeur de contexte

`tools/bench-depth.sh`, 27B Q4, KV q8_0, sans spéculation, reps=2 :

| Device | depth 0 | depth 16k | depth 32k | Tour simulé 0 → 32k |
|---|---|---|---|---|
| Vulkan0 | 289 pp / 12,25 tg | 222 / 11,83 | 183 / 11,50 | 252 s → 272 s (x1,08) |
| ROCm0 | 352 pp / 11,97 tg | 263 / 10,73 | 214 / 9,54 | 256 s → 324 s (x1,26) |

ROCm0 prefill plus vite à vide mais décode moins bien, et se dégrade deux
fois plus vite en profondeur : Vulkan0 gagne à toutes les profondeurs sur ce
GGUF, et l'écart se creuse en contexte long (le régime agentic).

### Concurrence, cache de prompt, chargement

`--bench-parallel`, spec-test.txt, 400 tokens, 2 salves :

| Modèle | parallel | 1 requête | 4 requêtes | Lecture |
|---|---|---|---|---|
| qwen3.5-9b | 4 | 25,7 t/s | 78,6 t/s agrégés (x3,06), 20,1 t/s par requête | le `parallel 4` des tâches auxiliaires est justifié |
| lfm2.5-2.6b | 4 | 67,4 t/s | 205 t/s agrégés (x3,06), 52 t/s par requête | idem |
| qwen3.6-35b-a3b-nothink | 2 | 53,7 t/s | 72,2 t/s agrégés à 2 (x1,43), 40 t/s par requête | le MoE s'amortit moins bien : chaque requête route ses propres experts |
| qwen3.6-35b-a3b (thinking) | 3 | 53,0 t/s | 90,7 t/s agrégés à 3 (x1,73), 31 t/s par requête | idem |

### Réglages n-gram alternatifs

`--spec-ab`, 27B, n-max 6, spec-refactor.txt, 4 passes :

| Variante | Gen t/s | Acceptance | Lecture |
|---|---|---|---|
| base (ngram-map-k 47, min-hits 2, draft-mtp 6) | **56,1** | 0,80 | +18 % sur le même réglage n-gram avec n-max 4 (47,4) : le n-max 6 profite aussi au mode mixte |
| min-hits 1 | 55,8 | 0,80 | équivalent, 2 gardé |
| ngram-map-k4v 47, min-hits 2 | 44,9 | 0,91 | -20 % : drafte moins souvent malgré une meilleure acceptance |

`--bench-cache`, bench-context.txt ~1370 tokens :

| Modèle | Architecture | Tour suivant | Édition au 1er tiers | Requête identique |
|---|---|---|---|---|
| qwen3.5-9b | hybride SWA/GDN | 62 % (847 tok) | 0 % | 63 % (861 tok) |
| qwen3.6-35b-a3b-nothink | GDN, MoE | 62 % (847 tok) | 0 % | 63 % (861 tok) |
| qwopus3.6-27b | GDN | 62 % (847 tok) | 0 % | 63 % (861 tok) |
| lfm2.5-2.6b | conv récurrente (autre tokenizer) | 62 % (864 tok) | 0 % | 63 % (876 tok) |
| qwen3-coder-next | GDN, MoE | 64 % (962 tok) | 0 % | 66 % (978 tok) |
| **deepseek-v4-flash** | **attention pure (MLA)** | **99 %** | **0 %** | **100 %** |
| **gpt-oss** | **attention + SWA, MoE** | **99 %** | **4 %** | **100 %** |

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

`--bench-load`, restart puis première requête. Le chiffre dépend d'abord de
l'état du cache de pages du noyau : fichier chaud (benché à l'instant) ou
relu depuis le disque.

| Modèle | Taille | Chargement + 1er token | TTFT à chaud | État du cache de pages |
|---|---|---|---|---|
| lfm2.5-2.6b | 2,7 Go | 0,5 s | 27 ms | chaud |
| qwen3.5-9b | 8,2 Go | 1,9 s | 65 ms | chaud |
| qwen3.8-27b | 17 Go | 4,4 s | 165 ms | chaud (~4 Go/s) |
| qwopus3.6-27b | 19 Go | 4,5 s | 147 ms | chaud |
| qwen3.6-35b-a3b-mtp | 22 Go | 36 s | 54 ms | disque (~0,6 Go/s) |
| qwen3-coder-next | 47 Go | 72 s | 406 ms | disque |
| gpt-oss | 59 Go | 91 s | 86 ms | disque |

Une bascule LRU entre modèles moyens coûte quelques secondes si le fichier
est encore en cache de pages, une minute et plus s'il a été évincé (les
104 Go de DeepSeek évincent tout le reste).

### Enseignements

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
| `logs/bench-load.log` | journal TSV des `--bench-load` |
| `logs/spec-batch.log` / `.tsv` | journal des balayages `tools/bench-spec-batch.sh` |

Côté `~/models/` : `models.ini`, généré. Ne jamais l'éditer : relancer
`--preload` ou `--setup`. Le routeur ne le lit qu'au démarrage, toute
modification demande un restart du service.

## Ajouter un modèle

Tout se passe dans `lib/models.sh` : un bloc de deux appels, à la position
voulue dans le ini (l'ordre de déclaration est l'ordre d'émission), puis
`./setup-llm.sh --setup` télécharge le GGUF, régénère `models.ini` et propose
le redémarrage. Rien d'autre à toucher.

```bash
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

- `download_hf <dossier> <repo> VAR=<fichier>` déclare le fichier (chemin,
  inventaire pour `--cleanup`, téléchargement) ; pour un modèle en shards,
  `download_hf_shards` avec le shard 00001 et son sous-dossier de quant.
- `llama_model <section> "<corps ini>"` déclare la section ; deux sections
  peuvent partager le même `*_PATH` (cas Qwen3.8-27B, thinking et MTP).
- `groupe "; --- titre ---"` avant le premier `llama_model` d'une nouvelle
  famille, pour l'en-tête dans le ini.
- Variante MTP : nommer la section `<clé>-mtp`, les garde-fous de
  préchargement en dérivent.

Ensuite, pour choisir le device et régler la spéculation : la procédure
d'`AGENTS.md` (skill `ajout-modele`).

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
