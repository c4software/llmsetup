#!/usr/bin/env python3
# Construit le body JSON d'une requête /v1/chat/completions à partir des
# fichiers de prompt de prompts/. L'échappement JSON passe par json.dumps
# (les fichiers sont du texte brut multiligne) — remplace l'ancien printf bash
# sur des chaînes pré-échappées (\n littéraux, apostrophes contournées).
#
# Usage :
#   build_body.py <modèle> <max_tokens> <seed> <fichier prompt> [fichier...]
#       un message user = contenus des fichiers, joints par une ligne vide
#       (spec-test : un seul fichier ; bench : contexte puis tâche)
#
# temperature fixée à 0.7 (identique aux printf d'origine). Le JSON émis
# doit rester ÉQUIVALENT (json.loads) aux bodies de référence de
# tests/fixtures/expected/ — vérifié par tests/py-golden.sh.
import json, sys


def read_prompt(path):
    """Texte brut du fichier, moins l'unique newline final."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return text[:-1] if text.endswith("\n") else text


def main():
    args = sys.argv[1:]
    if len(args) < 4:
        sys.exit("usage : build_body.py <modèle> <max_tokens> <seed> <fichier prompt> [fichier...]")
    modèle, max_tokens, seed = args[0], int(args[1]), int(args[2])

    content = "\n\n".join(read_prompt(f) for f in args[3:])

    print(json.dumps({
        "model": modèle,
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "seed": seed,
        "messages": [{"role": "user", "content": content}],
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
