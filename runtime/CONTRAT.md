# Contrat d'un runtime

Un **runtime** est un moteur d'inférence que le dépôt sait installer, démarrer,
arrêter et surveiller. Chacun vit dans son dossier, `runtime/<nom>/`, et y est
**autonome** : son conteneur, son image, ses poids, ses réglages, ses mesures,
ses tests. `lib/` ne connaît aucun moteur ; il pilote le runtime visé par ce
que ce contrat lui garantit, et rien d'autre.

Deux runtimes existent : [`llama-cpp-rocm-strix`](llama-cpp-rocm-strix/)
(llama-server en router mode, image ROCm construite localement, le défaut) et
[`gufo`](gufo/) (gufo derrière llama-swap). Ce document dit ce qu'il faut pour
en écrire un troisième, et `./tests/sh-unit.sh --contrat` le vérifie sur
chaque dossier de `runtime/`.

## Les règles de fond

1. **Toujours un conteneur, toujours par compose.** Un runtime démarre par
   `docker compose` sur un fichier versionné, jamais par un binaire de l'hôte,
   un `docker run` écrit dans un script ou une unité systemd. C'est ce qui
   rend le pilotage identique d'un moteur à l'autre.
2. **Un seul runtime tient le port.** Tous servent sur `SERVER_PORT` (8009) :
   un GPU, une adresse pour les clients. Démarrer un runtime arrête celui qui
   tournait ; un runtime n'écrit aucune garde contre les autres.
3. **Rien de la machine dans le dépôt, rien du dépôt dans la machine.** Le
   compose est versionné et ne porte aucune valeur machine ; ces valeurs sont
   dans un `.env` **généré**, hors du dépôt, réécrit à chaque démarrage et
   jamais édité.
4. **Une configuration est une série de mesures.** Version du moteur et
   réglages sont épinglés dans le dossier du runtime, ne changent que dans un
   commit qui dit pourquoi, et un journal de mesure porte toujours
   l'étiquette de version du runtime.
5. **Un runtime ne connaît pas les autres.** Ni leur nom, ni leurs fichiers,
   ni leurs dossiers. Ce qu'ils partagent (le parc `~/models`, les prompts de
   mesure, le client pi de `bench-agentic/`) est à la racine du dépôt.

## Le dossier

```
runtime/<nom>/
  runtime.sh            OBLIGATOIRE : déclarations et fonctions du contrat
  docker-compose.yml    OBLIGATOIRE : le conteneur, versionné
  tests/sh-unit.sh      OBLIGATOIRE : exécutable, sans GPU ni réseau ni démon
  README.md             recommandé : mise en route, fichiers, où vont les données
  …                     libre : Dockerfile, lib/, bancs, outils, version épinglée
```

`<nom>` est en minuscules, chiffres, tirets et points. C'est lui que
`--runtime <nom>` et `LLM_RUNTIME` attendent, et sous lui que le runtime se
déclare.

## `runtime.sh`

Sourcé par `setup-llm.sh`, **après** `lib/common.sh` et `lib/svc.sh`, **avec
tous les autres runtimes** (pas seulement quand il est l'actif). Trois
conséquences :

- **Aucun effet de bord au chargement** : ni docker, ni réseau, ni question,
  ni sortie sur stdout. Lire ses propres fichiers versionnés (une version
  épinglée) est permis.
- **Aucune collision de noms** avec un autre runtime : préfixer fonctions et
  variables par le nom du moteur (`GUFO_*`, `_gufo_*`, `_llama_*`), les
  fonctions du contrat par `rt_<id>_`.
- Il peut sourcer d'autres fichiers de son dossier. `$SCRIPT_DIR` est la
  racine du dépôt ; son dossier est `$SCRIPT_DIR/runtime/<nom>`.

Ce que `lib/common.sh` met à sa disposition : `info`, `warn`, `error`,
`MODELS_BASE` (`~/models`), `SERVER_PORT`, `_compose_gid <groupe>` (gid
numérique d'un groupe de l'hôte). Ce que `lib/svc.sh` lui offre s'il en a
besoin dans ses propres commandes : `_svc_is_active`, `_svc_installed`,
`_svc_start`, `_svc_stop`, `_svc_restart`, `_svc_wait_ready`, `_svc_compose`,
`_svc_regen_env`, `SVC_URL`.

### Déclarations

Des entrées dans les tableaux associatifs de `lib/common.sh`, sous le nom du
runtime :

| Tableau | Obligatoire | Rôle |
|---|---|---|
| `RT_CONTENEUR[<nom>]` | oui | nom du conteneur, celui du `container_name` du compose ; unique parmi les runtimes |
| `RT_ENV_FILE[<nom>]` | oui | chemin absolu du `.env` généré, **hors du dépôt** ; son dossier est le dossier de projet compose ; unique parmi les runtimes |
| `RT_DESCRIPTION[<nom>]` | oui | une ligne, pour `--runtime` et l'aide |
| `RT_COMMANDES[<nom>]` | non | ses sous-commandes propres (`--xxx`), séparées par des espaces |
| `RT_DELAI_DEMARRAGE[<nom>]` | non | plafond d'attente de `/health`, en secondes (défaut 300) |
| `RT_DELAI_ARRET[<nom>]` | non | délai de grâce de l'arrêt, en secondes (défaut 10) |
| `RT_PARC_RESERVE[<nom>]` | non | dossiers de premier niveau de `~/models` qui ne sont qu'à lui : le ménage d'un autre runtime n'y touche pas |

### Fonctions

`<id>` est le nom du runtime où tout caractère hors `[A-Za-z0-9]` devient `_`
(`llama-cpp-rocm-strix` donne `rt_llama_cpp_rocm_strix_env`).

**Obligatoires**

| Fonction | Contrat |
|---|---|
| `rt_<id>_check` | Le runtime peut-il démarrer ici (docker, image, poids ou configuration, groupes GPU) ? Code 0 ou 1 ; explique sur **stderr** ce qui manque et comment l'obtenir ; **aucun effet de bord**. Appelée avant tout démarrage, et avant une bascule pour ne pas couper le runtime qui sert |
| `rt_<id>_env [args de --start]` | Écrit le `.env` du compose sur **stdout**, une ligne `CLÉ=valeur` sans guillemets, et **ne touche à rien d'autre** (c'est ce qui le rend testable et diffable). Échoue sans rien écrire si un prérequis manque ou si un argument est invalide. Le pilotage se charge du fichier : temporaire, puis remplacement seulement si le contenu diffère |
| `rt_<id>_setup [args]` | `--setup` : dépendances de l'hôte, image, poids. Ne démarre rien |
| `rt_<id>_etiquette` | Version du moteur servi, sur stdout : **une chaîne sans espace**, propre à une colonne TSV, obtenue **sans lancer de conteneur** (elle est appelée à chaque journal). Change dès que le moteur change |
| `rt_<id>_aide` | Texte d'aide du runtime : ses sous-commandes (toutes celles de `RT_COMMANDES`), ses fichiers, son workflow |
| `rt_<id>_commande <--xxx> [args]` | Exécute une sous-commande de `RT_COMMANDES`. Sans sous-commande, la fonction existe quand même et refuse |

**Optionnelles** (appelées si elles existent)

| Fonction | Quand | Pour quoi |
|---|---|---|
| `rt_<id>_avant_demarrage [args]` | avant l'écriture du `.env`, à chaque démarrage | créer les dossiers de l'hôte que le compose monte (docker les créerait en root), une migration, une annonce |
| `rt_<id>_pret [args]` | après que `/health` a répondu | attendre ce que `/health` ne dit pas (un modèle préchargé encore en chargement) ; un code non nul fait échouer le démarrage |
| `rt_<id>_etat` | `--status`, service en marche | une ou deux lignes de plus (modèles exposés) |

Les arguments de `--start`, `--restart` et `--runtime <nom>` sont transmis
tels quels à `avant_demarrage`, `env` et `pret` : c'est le runtime qui leur
donne un sens (gufo : le modèle préchargé). Un `--restart` sans argument doit
reprendre ce qui servait, pas retomber sur un défaut.

## `docker-compose.yml`

- **Un service et un seul.**
- **Aucune valeur machine** : toute variable est obligatoire, sous la forme
  `${VAR:?}`. Jamais `${VAR}` ni `${VAR:-défaut}` : un `.env` incomplet doit
  faire refuser le fichier par docker, pas monter un service à moitié.
- `container_name: ${…:?}`, dont la valeur est `RT_CONTENEUR[<nom>]`.
- **Le service écoute sur `SERVER_PORT` de l'hôte et y répond à `GET /health`**
  (code 2xx quand il sert). C'est tout ce que le pilotage attend de lui.
- `restart:` présent (`unless-stopped` en usage réel : le dernier runtime
  démarré repart seul avec la machine, l'autre ayant été arrêté).
- `user:` présent, l'uid:gid de l'utilisateur qui lance : **jamais root**.
  L'accès au GPU passe par `group_add` avec les gid **numériques** de `render`
  et `video` (`_compose_gid`), les noms n'existant pas dans les images.
- Le parc est monté **au même chemin absolu** et **en lecture seule** :
  `"${MODELS_BASE:?}:${MODELS_BASE:?}:ro"`. Ce que le moteur écrit (un cache)
  va dans un autre volume, hors de `~/models`.
- **Interdits** : `privileged`, la socket docker, `network_mode: host`,
  `mem_limit` (les gardes mémoire raisonnent sur la mémoire de l'hôte).
  Recommandés quand le moteur les supporte : `cap_drop: [ALL]`,
  `no-new-privileges`.
- L'image est soit construite par le compose (bloc `build`, révisions
  épinglées dans le Dockerfile du runtime), soit tirée à une version épinglée.
  Jamais `latest` d'un registre.

## Ce que le pilotage fait, et que le runtime ne refait pas

| Commande | Déroulé (`lib/svc.sh`) |
|---|---|
| `--start [args]` | `check` ; `avant_demarrage` ; `.env` régénéré par `env` ; arrêt de tout autre runtime en marche ; `docker compose up -d --force-recreate --remove-orphans` ; attente de `/health` avec sortie anticipée si le conteneur est sorti ; `pret` |
| `--stop` | `docker compose stop -t <RT_DELAI_ARRET>` : conteneur arrêté, pas supprimé |
| `--restart [args]` | `--stop` puis `--start`. **Jamais `docker compose restart`**, qui garderait l'ancienne image, l'ancienne commande et l'ancien `.env` |
| `--status` | runtime actif, `docker compose ps -a`, `/health`, puis `etat` |
| `--logs [-f] [--tail N]` | `docker compose logs --no-color` |
| `--runtime <nom> [args]` | `check` du nouveau **avant de toucher à quoi que ce soit** ; `runtime.conf` écrit ; démarrage ; en cas d'échec, `runtime.conf` remis et l'ancien runtime relancé |
| `--setup [args]` | `setup` |
| `--<sous-commande>` | `commande`, si elle est dans `RT_COMMANDES` du runtime visé ; refusée en le nommant si elle appartient à un autre |

Le runtime **visé** est celui de `LLM_RUNTIME` (pour une commande, sans rien
mémoriser), sinon de `runtime.conf` (choix utilisateur, écrit par
`--runtime`), sinon le défaut du dépôt.

Un runtime ne lance donc jamais lui-même le `docker compose` de son service,
ne réécrit pas de boucle d'attente, et n'arrête pas un autre runtime. Ses
bancs passent par le point d'entrée (`LLM_RUNTIME=<nom> ./setup-llm.sh
--start …`) et rendent la machine comme ils l'ont trouvée (`--en-marche` dit
s'il y avait quelque chose à relancer).

## Ce qui reste propre à chaque runtime

Le contrat s'arrête au cycle de vie. **Les mesures ne sont pas communes** : la
façon de mesurer dépend de ce que le moteur expose (les bancs de
`llama-cpp-rocm-strix` lisent `status.args` de son `/v1/models`, ceux de gufo
lisent son journal). Chaque runtime range les siennes dans son dossier, en
sous-commandes ou en scripts, avec trois obligations :

- journaliser la version par `rt_<id>_etiquette` (ou son équivalent interne) ;
- garder un garde-fou contre les mesures fausses (réponse fausse, sortie
  dégénérée, boucle) : un moteur cassé produit des t/s superbes ;
- ne rien écrire dans le dépôt : journaux dans `logs/` (ignoré par git) ou
  hors du dépôt.

Les prompts de `prompts/` et le client pi de `bench-agentic/` sont partagés
pour que deux runtimes se comparent à requêtes identiques : ne pas les
modifier au détour de l'ajout d'un runtime.

## Tests

`runtime/<nom>/tests/sh-unit.sh` teste ce que le runtime a de propre, sur un
faux `docker`, un faux `getent` et un faux `curl` : contenu de son `.env`,
rendu du compose par le vrai `docker compose config` quand il est disponible,
cohérence de sa configuration, ses fonctions de contrat. Il se lance seul, et
`./tests/sh-unit.sh` le lance après avoir vérifié le contrat.

## Ajouter un runtime : la marche

1. Créer `runtime/<nom>/` avec `docker-compose.yml`, en partant des règles
   ci-dessus ; épingler la version du moteur dans le dossier.
2. Écrire `runtime.sh` : les trois déclarations obligatoires, les six
   fonctions obligatoires, les optionnelles utiles.
3. `./tests/sh-unit.sh --contrat` jusqu'à ce que le runtime soit conforme,
   puis écrire `tests/sh-unit.sh`.
4. Sur la machine : `LLM_RUNTIME=<nom> ./setup-llm.sh --setup …`, puis
   `./setup-llm.sh --runtime <nom>` (l'ancien runtime est remis si le
   démarrage échoue).
5. **Justesse avant tout chiffre** : le moteur répond-il juste
   (`prompts/bench-sanity.txt`) ? Ensuite seulement les débits, et la boucle
   agentique de `bench-agentic/`.
6. Documenter : `README.md` du runtime, table des runtimes du README et
   d'`ARCHITECTURE.md`, journal daté dans `docs/`.
