# ARCHITECTURE

Le dépôt est découpé en **runtimes** depuis le 09/10/2026 : un dossier
`runtime/<nom>/` par moteur, autonome, et un socle générique (`lib/`) qui ne
nomme aucun moteur. Ce document décrit le socle. L'architecture de chaque
moteur est dans son dossier :

- [`runtime/llama-cpp-rocm-strix/ARCHITECTURE.md`](runtime/llama-cpp-rocm-strix/ARCHITECTURE.md)
  (l'`ARCHITECTURE.md` du dépôt avant le découpage : modèles, `models.ini`,
  tuners, bancs, garde mémoire, journaux) ;
- [`runtime/gufo/README.md`](runtime/gufo/README.md).

Ce qu'un runtime doit fournir : [`runtime/CONTRAT.md`](runtime/CONTRAT.md).

## Vue d'ensemble

```
setup-llm.sh ──► lib/common.sh    helpers, MODELS_BASE, SERVER_PORT, registre des runtimes
             ──► lib/svc.sh       pilotage générique du conteneur
             ──► runtime/*/runtime.sh   TOUS, dans l'ordre alphabétique : chacun se
             │                          déclare et définit ses fonctions rt_<id>_*
             ──► lib/help.sh
             │
             ▼
   RT = runtime visé : LLM_RUNTIME, sinon runtime.conf, sinon llama-cpp-rocm-strix
             │
   commande commune ───► lib/svc.sh ──┬─► rt_<id>_check / avant_demarrage / env / pret / etat
   (--start, --stop…)                 │      (ce que le runtime sait de lui-même)
                                      └─► docker compose --project-directory <dossier du .env>
                                             --env-file <.env généré>
                                             -f runtime/<nom>/docker-compose.yml …
   sous-commande ──────► rt_<id>_commande    (si elle est dans RT_COMMANDES du runtime visé)
   (--bench, --requetes…)
```

Trois fichiers par runtime suffisent au pilotage : `runtime.sh` (ce qu'il
déclare et sait faire), `docker-compose.yml` (versionné, sans valeur machine),
et le `.env` que le pilotage écrit hors du dépôt à partir de `rt_<id>_env`.

## Modules

`setup-llm.sh` définit `SCRIPT_DIR` puis source, dans cet ordre imposé :

```
lib/common.sh → lib/svc.sh → runtime/*/runtime.sh → lib/help.sh
```

Les `source` restent au niveau du script, jamais dans une fonction : un
`declare -A` d'un module sourcé depuis une fonction lui serait local.

- `lib/common.sh` : `info` / `warn` / `error` ; `MODELS_BASE` (`~/models`) et
  `SERVER_PORT` (8009), communs à tous les runtimes ; `_compose_gid` (gid
  **numérique** d'un groupe de l'hôte, dont tout runtime GPU a besoin pour son
  `.env`) ; et le **registre** : `RUNTIMES` (noms, remplis par le point
  d'entrée), les tableaux de déclaration `RT_CONTENEUR`, `RT_ENV_FILE`,
  `RT_DESCRIPTION`, `RT_COMMANDES`, `RT_DELAI_DEMARRAGE`, `RT_DELAI_ARRET`,
  `RT_PARC_RESERVE`, `RUNTIME_CONF`, `RUNTIME_DEFAUT`, `_rt_id` (nom → préfixe
  de fonction), `_rt_existe`, `_rt_a <nom> <fonction>` (fonction optionnelle
  présente ?), `_rt <fonction> [args]` (**le seul point d'appel d'une fonction
  de contrat**), `_rt_actif`, `_rt_proprietaire <sous-commande>`.
- `lib/svc.sh` : **le seul point d'appel de `docker compose` pour un
  service**. `_svc_compose` (runtime visé) et `_svc_compose_de <nom>`,
  `_svc_is_active` / `_svc_actif_de`, `_svc_installed` (= `check` muet),
  `_svc_regen_env` (fichier temporaire, remplacement seulement si le contenu
  diffère), `_svc_wait_ready` (boucle `/health`, sortie anticipée avec le code
  de sortie si le conteneur est `exited`), `_svc_stop` / `_svc_stop_de`
  (`compose stop`, ou `docker stop` sur le nom quand le `.env` manque),
  `_svc_arreter_autres` (l'exclusivité), `_svc_start`, `_svc_restart`,
  `_svc_logs`, et les commandes `cmd_start`, `cmd_stop`, `cmd_restart`,
  `cmd_status`, `cmd_logs`, `cmd_en_marche`, `cmd_runtime`.
- `runtime/<nom>/runtime.sh` : voir le contrat. Un runtime peut appeler les
  `_svc_*` dans ses propres commandes (les tuners de `llama-cpp-rocm-strix`
  redémarrent le service) : elles visent le runtime en cours.
- `lib/help.sh` : `cmd_help`, commandes communes puis `rt_<id>_aide` du runtime
  visé.

## Déroulé des commandes communes

| Commande | Déroulé |
|---|---|
| `--start [args]` | `check` (refus expliqué) → `avant_demarrage` → `.env` par `env` → arrêt de tout autre runtime en marche → `up -d --force-recreate --remove-orphans` → attente de `/health` → `pret` |
| `--stop` | `compose stop -t <RT_DELAI_ARRET>` : arrêté, pas supprimé (`ps -a` garde le dernier code de sortie) |
| `--restart [args]` | `--stop` puis `--start` |
| `--runtime <nom> [args]` | nom connu ? → `check` du nouveau, **avant tout** → `runtime.conf` → démarrage ; en cas d'échec : `runtime.conf` remis, ancien runtime relancé s'il tournait |
| `--setup [args]` | `setup` |
| `--status` | `compose ps -a`, `/health`, `etat` ; ou « c'est tel autre runtime qui tient le port » |
| `--en-marche` | code de retour seul, pour les scripts (les bancs savent ainsi s'il y avait quelque chose à relancer) |
| autre `--xxx` | dans `RT_COMMANDES` du runtime visé : `commande` ; dans celles d'un autre : refus qui le nomme ; sinon : commande inconnue |

Les arguments de `--start`, `--restart` et `--runtime <nom>` sont transmis au
runtime, qui leur donne un sens (gufo : le modèle préchargé).

## Ce qui est partagé entre runtimes

| Chose | Où | Règle |
|---|---|---|
| Le port | `SERVER_PORT` | un seul runtime à la fois ; le pilotage arrête l'autre |
| Le parc | `~/models` | monté au même chemin et en lecture seule ; deux runtimes peuvent lire les mêmes fichiers (27B, tête MTP et mmproj de Flash-Next) ; un dossier propre à un runtime se déclare dans `RT_PARC_RESERVE` pour que le ménage d'un autre l'épargne |
| Les prompts de mesure | `prompts/` | les modifier invalide les comparaisons de TOUS les runtimes |
| La boucle agentique | `bench-agentic/` | pi en conteneur jetable (version épinglée), joué contre `SERVER_URL` ; même règle que les prompts |
| Les journaux | `logs/` (ignoré par git) | toujours avec l'étiquette de version du runtime (`rt_<id>_etiquette`) |

## Tests

`tests/sh-unit.sh`, sans GPU ni démon ni réseau (faux `docker`, `getent`,
`curl`) :

1. **Conformité** de chaque dossier de `runtime/` au contrat : fichiers,
   déclarations, fonctions obligatoires, aucun effet de bord ni sortie au
   chargement, étiquette propre à une colonne TSV et lue sans docker, aide qui
   cite chaque sous-commande, règles du compose, conteneurs, `.env`,
   sous-commandes et noms de fonctions sans collision entre runtimes.
2. **Pilotage générique**, sur deux runtimes factices dans un dépôt jetable :
   runtime actif (`runtime.conf`, `LLM_RUNTIME`), aiguillage des
   sous-commandes, ordre du démarrage, `.env` idempotent, exclusivité,
   `--restart` sans jamais `compose restart`, arrêt sans `.env`, échec
   immédiat sur un conteneur sorti, bascule et retour arrière.
3. Les `tests/sh-unit.sh` de chaque runtime, qui ne testent que ce que le
   runtime a de propre.

`--contrat` s'arrête après la partie 2.

## Invariants (à ne pas casser)

- **Rien dans `lib/` ne nomme un runtime**, hormis `RUNTIME_DEFAUT`. Un
  comportement propre à un moteur passe par une fonction de contrat ou une
  déclaration, pas par un `if` sur son nom.
- **Un runtime ne nomme pas les autres**, ni leurs fichiers ni leurs dossiers.
- **Tout démarrage passe par `docker compose`** sur le compose versionné du
  runtime, depuis `lib/svc.sh` et nulle part ailleurs.
- **Jamais `docker compose restart`** : il relance le conteneur existant, donc
  l'ancienne image, l'ancienne ligne de commande et l'ancien `.env`.
- Le `.env` est **régénéré à chaque démarrage**, hors du dépôt, jamais édité.
  Le compose ne porte **aucune** valeur machine (`${VAR:?}` partout).
- **Un seul runtime sur le port**, par construction (`_svc_arreter_autres`),
  sans garde écrite dans les runtimes.
- **Une bascule ne laisse jamais le port vide** : prérequis vérifiés avant,
  retour arrière après.
- L'attente de `/health` vit à UN endroit, `_svc_wait_ready` : une commande
  qui rend la main a un service qui répond, ou elle a échoué en le disant.
- `runtime.conf` est un **choix utilisateur**, écrit par `--runtime` seul.
  Sans lui, le défaut est `llama-cpp-rocm-strix` : une machine installée
  avant le découpage se comporte comme avant.
- Charger un `runtime.sh` ne fait rien : tous le sont à chaque commande.
- Entrée non interactive (`! -t 0`) : jamais de question, jamais de restart
  automatique.
