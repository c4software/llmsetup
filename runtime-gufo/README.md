# runtime-gufo : gufo à la place du service, et ses bancs

[gufo](https://github.com/gufo-org/gufo) est un moteur HIP spécialisé
Strix Halo, évalué contre le service le 24/09/2026 : mesures, verdict,
paramètres et tickets amont dans [`docs/GUFO.md`](../docs/GUFO.md). En
résumé : bien configuré, il fait le même travail agentique en 30 % de temps
en moins sur le 27B et Flash-Next, mais il ne sert qu'un modèle par
processus et n'accepte que ses propres GGUF. Ces scripts ne l'intègrent pas
au service : ils le mettent à sa place sur `:8009` le temps d'un essai, ou
le mesurent contre lui.

## Mise en route, depuis un clone

Sur la machine du service (bigchuck), le service déjà installé
(`./setup-llm.sh --setup`, qui télécharge les GGUF du parc) :

```bash
runtime-gufo/telecharger.sh image        # l'image de gufo (8,3 Go)
runtime-gufo/telecharger.sh flashnext    # Flash-Next UD-Q4_K_XL (104 Go), seulement pour flashnext
runtime-gufo/serve-8009.sh gufo 27b      # ou : gufo flashnext
```

Le 27B tourne avec les fichiers du parc, rien d'autre à télécharger.
Retour au service : `runtime-gufo/serve-8009.sh service`. Chaque script
affiche son aide sans argument.

## Les scripts

| Script | Rôle |
|---|---|
| `serve-8009.sh gufo [27b\|flashnext]` / `service` / `logs` | Bascule `:8009` entre gufo et le service ; le dernier lancé repart seul au démarrage de la machine |
| `telecharger.sh image\|flashnext\|deepseek\|27b-q4km\|tout` | Image et GGUF de référence de gufo, aux révisions épinglées par ses guides |
| `bench/run.sh gufo\|llama <cas>...` | Banc HTTP (`bench/mesure.py`) : justesse, `--bench`, `spec-refactor`, prefill long avec aiguille, cache au tour 2 |
| `bench/agentic.sh gufo\|llama <cas>...` | Boucle pi de `bench-agentic/`, contre gufo ou le service, sans toucher `logs/` |
| `commun.sh` | Sourcé par les autres : chemins, image, fichiers et arguments de gufo par modèle, échantillonnage, cache disque |

Nom exposé par gufo : `qwen3.8-27b` ou `qwen3.8-flash-next` (via le proxy :
`bigchuck/<nom>`), distinct des sections du service.

## Où vont les données

Hors du dépôt et hors de `~/models` (où `--cleanup` les verrait orphelines),
dans `GUFO_DATA`, par défaut `~/llm/gufo-test` :

- `models/` : GGUF de référence de gufo (`telecharger.sh`) ;
- `cache/` : cache disque de gufo (16 Gio au plus) ;
- `resultats/` : sorties des bancs.

Variables : `GUFO_DATA`, `MODELS_BASE` (défaut `~/models`), `GUFO_IMAGE`,
`SESSIONS` (serve et banc agentique), `PASSES` (banc agentique).

## Règles

- Jamais deux moteurs sur le GPU : chaque script arrête le service avant de
  lancer gufo, et les bancs le relancent à la sortie. Ne pas lancer
  `./setup-llm.sh --start` pendant que gufo tient `:8009`.
- Garder la configuration de gufo stable : la changer (`--sessions`…) rend
  son cache disque inutilisable.
- Le proxy (llm-proxy) doit retirer `stop` des requêtes Anthropic pour gufo
  (`anthropic_drop_fields = ["stop"]` sous le backend), à enlever au retour
  du service (gufo-org/gufo#260).
