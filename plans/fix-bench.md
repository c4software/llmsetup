# Durcir la mesure de `--bench` (suite d'analyse d'un premier run réel)

## Contexte

Le dépôt contient `setup-llm.sh` (peut-être déjà découpé en `lib/` + `py/` + `prompts/` selon l'avancement du refactor — adapte les emplacements, la logique visée est la même). La sous-commande `--bench` mesure les perfs d'un ou plusieurs presets via l'API du routeur llama-server (`http://localhost:8009`) : N passes par preset (défaut 3), la passe 1 porte un long préfixe de remplissage (~400 répétitions d'une phrase) pour mesurer le prefill, les passes suivantes tournent en prompt cache et mesurent le décode ; acceptance MTP lue dans `timings` ; tableau récapitulatif final. Pas de restart, rien d'écrit.

Un premier run réel a montré trois faiblesses. Lis d'abord `_bench_one`, `cmd_bench` et, s'il existe déjà, `prompts/bench-filler.txt` avant de toucher quoi que ce soit. Comportement CLI inchangé (`--bench [preset|all] [passes]`), sorties enrichies mais pas restructurées.

## Problème 1 — bug réel : l'acceptance du récap n'est pas une médiane

Run observé : passes à 0.79 / 0.85 / 0.75 → le récap affiche 0.75. Le code écrase une variable `acc` à chaque passe et garde donc la **dernière** valeur. Attendu : même traitement que le décode — **médiane des passes hors passe 1** (la passe 1 est cache froid et exclue du décode ; par cohérence, exclue aussi de l'acceptance). S'il n'y a qu'une passe utile, sa valeur ; si le preset n'est pas spéculatif, `-` comme aujourd'hui. La médiane se calcule déjà pour le décode via un `awk` — réutilise le même mécanisme, n'introduis pas une seconde façon de faire.

## Problème 2 — le prefill peut être contaminé par le cache sans qu'on le voie

`timings` de llama-server contient `prompt_n` (tokens réellement traités) et `cache_n` (tokens repris du cache). La passe 1 est censée être du prefill pur, mais `slot-prompt-similarity` + `cache-ram`/checkpoints peuvent en servir une partie depuis un état antérieur — le chiffre affiché est alors gonflé et on ne le sait pas. Attendu :

- Afficher `cache=<cache_n>` sur la passe 1 (les passes suivantes l'affichent déjà implicitement via leur note "(prompt cache)" — ajoute le chiffre là aussi, format identique à ce que fait déjà `--spec-test` : `prefill=983 t/s (n=12087, cache=0)`).
- Si `cache_n > 0` en passe 1 : marquer la mesure — suffixe ` ⚠ prefill partiellement servi par le cache` sur la ligne de passe, et dans le récap, suffixer la valeur de prefill d'un `*` avec une ligne de légende sous le tableau (`* prefill contaminé par le cache — chiffre non comparable`). Ne pas exclure la mesure : l'utilisateur voit et juge.
- Ne tente PAS de purger le cache côté serveur (pas d'appel slots/erase, pas de restart) : `--bench` doit rester une mesure passive du serveur tel qu'il tourne. La contamination se signale, elle ne se corrige pas ici.

## Problème 3 — le remplissage répétitif est un meilleur cas irréaliste

Le préfixe actuel répète 400 fois la même phrase : prefill mesuré en conditions idéales (batching parfait, tokenisation triviale), et run observé à 983 t/s là où un prompt réaliste donnerait nettement moins. La taille réelle a aussi surpris : ~12K tokens au lieu des ~8K annoncés (la phrase tokenise plus long que prévu).

Attendu :
- **Varier chaque répétition** en la préfixant de son numéro : `[i] <phrase>` (i = 1..N). Ça casse la répétitivité exacte sans changer la nature du texte ni compliquer le code. Ne pas générer de texte aléatoire (reproductibilité entre runs : le préfixe doit être identique d'un run à l'autre).
- **Documenter la taille réelle, pas la taille visée** : après la passe 1, le script connaît `prompt_n` — c'est lui qui fait foi. Remplacer les mentions "~8K" (en-tête de section, ligne d'intro du bench, help) par une formulation neutre ("long préfixe de remplissage") + afficher le `n=` mesuré, déjà présent. Si un `prompts/bench-filler.txt` existe, la phrase y reste ; la numérotation des répétitions se fait au moment de la construction, pas dans le fichier.
- Le nombre de répétitions reste une constante du script (`BENCH_FILLER_REPEAT`) — ne pas en faire une option CLI.

## Ce qui ne change PAS

- Le prompt de tâche (module `inventory.py` + pytest) : il est volontairement prévisible (meilleur cas MTP assumé) — c'est documenté, pas un bug. Ne le modifie pas.
- Les seeds fixes par passe (42+i), `max_tokens`, la structure passes/médiane, le tableau `column -t`.
- Aucune écriture (ni conf, ni journal `spec-tests.log` — le bench ne journalise pas, c'est voulu : son préfixe n'est pas comparable au prompt de référence spec-test).
- `--spec-test` n'est pas concerné par les problèmes 1 et 3 (il a déjà `cache=` et médiane d'acceptance ; son prompt n'a pas de filler). Vérifie juste qu'aucun helper partagé ne régresse de son côté.

## ⚠ Comparabilité

Le changement du filler (problème 3) invalide les comparaisons de **prefill** avec les tableaux de bench antérieurs (le décode reste comparable : même tâche, mêmes seeds). À dire explicitement : dans le message de commit, et dans MEMORY.md si le dépôt en a un (section mesures) — une ligne suffit : "filler numéroté depuis <date>, prefills antérieurs non comparables".

## Vérification

- `bash -n` (ou la suite de tests du dépôt si le refactor est passé : golden ini non impacté — aucun preset ne change — et `tests/py-golden.sh` si les timings passent par un `py/`).
- Test à blanc du parseur : forger deux réponses JSON `timings` (une avec `cache_n: 0`, une avec `cache_n: 3000`) et vérifier ligne de passe + marquage `*` dans le récap.
- Test de la médiane d'acceptance : trois passes 0.79/0.85/0.75 → récap 0.85 (médiane de 0.85 et 0.75 = 0.80 si 2 passes utiles — attention : avec 3 passes dont la 1 exclue, il reste 2 valeurs, la médiane est leur moyenne ; vérifie que l'awk existant fait bien ça, c'est le même que le décode).
- Un run réel sur un preset chargé, coller la sortie dans le récap de PR.

## Livraison

Un seul commit (ou une PR courte) : les trois problèmes sont liés à la même fonction. Récap final : ce qui a changé ligne à ligne dans la sortie du bench (avant/après sur le run réel), et la note de comparabilité.
