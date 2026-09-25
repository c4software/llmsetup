# runtime-gufo : gufo à la place du service, et ses bancs

[gufo](https://github.com/gufo-org/gufo) est un moteur HIP spécialisé
Strix Halo, évalué contre le service le 24/09/2026 : mesures, verdict,
paramètres et tickets amont dans [`docs/GUFO.md`](../docs/GUFO.md). En
résumé : bien configuré, il fait le même travail agentique en 30 % de temps
en moins sur le 27B et Flash-Next, mais il ne sert qu'un modèle par
processus et n'accepte que ses propres GGUF. Il ne s'intègre pas au routeur
du service : il **prend sa place** sur `:8009`, les deux sont exclusifs.

## Mise en route, depuis un clone

Sur la machine du service (bigchuck), le service déjà installé
(`./setup-llm.sh --setup`, qui télécharge les GGUF du parc) :

```bash
./setup-llm.sh --gufo-download image       # l'image de gufo (8,3 Go)
./setup-llm.sh --gufo-download flashnext   # Flash-Next UD-Q4_K_XL (104 Go), seulement pour flashnext
./setup-llm.sh --gufo routeur              # 27B et Flash-Next, le client choisit
./setup-llm.sh --gufo-off                  # retour au service
```

`--gufo 27b` ou `--gufo flashnext` servent un seul modèle ; `--gufo routeur`
met **llama-swap** devant gufo (la voie que gufo recommande) : le client
choisit `qwen3.8-27b` ou `qwen3.8-flash-next` par le champ `model`, comme avec
le routeur du service, et llama-swap arrête un gufo pour lancer l'autre. Un
seul modèle est chargé à la fois (145 Gio ne tiennent pas dans 124) ;
Flash-Next est préchargé (`GUFO_PRECHARGE`). Mesuré sur bigchuck le
25/09/2026 : bascule vers le 27B 64,6 s, retour vers Flash-Next 31,4 s,
relais sans coût (décode vu du client 47,4 t/s contre 47,6 mesurés par
gufo). Les clients agentiques doivent faire pointer tous leurs rôles
(principal et tâches annexes, le « Haiku » de Claude Code) sur le même
modèle, sinon chaque requête annexe déclenche une bascule.

Le 27B tourne avec les fichiers du parc, rien d'autre à télécharger.
`./setup-llm.sh --status` dit qui tient le port, `--gufo-logs` suit les
requêtes de gufo.

## Le dossier

| Fichier | Rôle |
|---|---|
| `docker-compose.yml` | La description de gufo, versionnée : un service par modèle (`27b`, `flashnext`, `27b-q4km`, `deepseek`) sélectionné par profil, ligne de commande complète, utilisateur de l'hôte, `restart: ${GUFO_RESTART}`. Aucune valeur machine : tout vient du `.env` |
| `Dockerfile.routeur` | Image du profil `routeur` : celle de gufo plus le binaire llama-swap, épinglé par version et SHA-256 ; construite par compose quand elle manque |
| `llama-swap.yaml` | Configuration du routeur, versionnée, sans valeur machine (`${env.VAR}`) : mêmes lignes de commande que les profils `27b` et `flashnext`, groupe exclusif, préchargement, `stop` et `stop_sequences` retirés pour tous les clients (gufo#260) |
| `download.sh image\|flashnext\|deepseek\|27b-q4km\|all` | Image et GGUF de référence de gufo, aux révisions épinglées par ses guides (`./setup-llm.sh --gufo-download`) |
| `bench/run.sh gufo\|llama <cas>...` | Banc HTTP (`bench/mesure.py`) : justesse, `--bench`, `spec-refactor`, prefill long avec aiguille, cache au tour 2 |
| `bench/agentic.sh gufo\|llama <cas>...` | Boucle pi de `bench-agentic/`, contre gufo ou le service, sans toucher `logs/` |

Le `.env` est généré par `./setup-llm.sh --gufo` (`lib/gufo.sh`) dans
`GUFO_DATA`, comme celui du service dans `~/models`. Il porte `COMPOSE_FILE`
et `COMPOSE_PROFILES`, d'où l'usage à la main :

```bash
cd ~/llm/gufo-test && docker compose ps     # ou logs -f
```

Nom exposé par gufo : `qwen3.8-27b` ou `qwen3.8-flash-next` (via le proxy :
`bigchuck/<nom>`), distinct des sections du service.

## Où vont les données

Hors du dépôt et hors de `~/models` (où `--cleanup` les verrait orphelines),
dans `GUFO_DATA`, par défaut `~/llm/gufo-test` :

- `.env` (usage réel) et `banc.env` (bancs) : générés ;
- `models/` : GGUF de référence de gufo (`--gufo-download`) ;
- `cache/` : cache disque de gufo (16 Gio au plus) ;
- `resultats/` : sorties des bancs.

Variables : `GUFO_DATA`, `GUFO_IMAGE`, `GUFO_SESSIONS` (défaut 2 ; `SESSIONS`
pour les bancs, défaut 1), `PASSES` (banc agentique). Les bancs posent
eux-mêmes `GUFO_PROJET=gufo-banc`, `GUFO_CONTENEUR=gufo-banc`,
`GUFO_RESTART=no` et leur `.env`.

## Règles

- Un seul moteur à la fois sur `:8009` : `--gufo` arrête le service,
  `--gufo-off` supprime gufo et relance le service, `--start` et `--restart`
  refusent tant que gufo tourne. Le dernier lancé repart seul au démarrage
  de la machine.
- Les bancs retirent un gufo d'usage réel au départ et relancent le service
  à la fin.
- Garder la configuration de gufo stable : la changer (`GUFO_SESSIONS`…) rend
  son cache disque inutilisable.
- `stop` : gufo le refuse (gufo-org/gufo#260). Le routeur le retire lui-même
  pour tous les clients ; avec `--gufo 27b` ou `flashnext`, c'est au proxy
  (llm-proxy, `anthropic_drop_fields = ["stop"]`) de le faire, à enlever au
  retour du service.
- Modifier `llama-swap.yaml` demande de relancer `--gufo routeur` (lu au
  démarrage) ; garder ses lignes de commande identiques à celles des profils
  du compose (vérifié par `tests/sh-unit.sh`).
