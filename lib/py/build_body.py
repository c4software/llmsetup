#!/usr/bin/env python3
# Construit le body JSON d'une requête /v1/chat/completions à partir des
# fichiers de prompt de lib/prompts/. L'échappement JSON passe par json.dumps
# (les fichiers sont du texte brut multiligne) — remplace l'ancien printf bash
# sur des chaînes pré-échappées (\n littéraux, apostrophes contournées).
#
# Usage :
#   build_body.py <preset> <max_tokens> <seed> <fichier prompt>
#       body spec-test : un message user = contenu du fichier
#   build_body.py <preset> <max_tokens> <seed> <fichier tâche> \
#       --filler-file <fichier> --filler-repeat <N>
#       body bench : un message user = filler répété N fois + tâche
#
# temperature fixée à 0.7 (identique aux deux printf d'origine). Le JSON émis
# doit rester ÉQUIVALENT (json.loads) aux bodies de référence de
# tests/fixtures/expected/ — vérifié par tests/py-golden.sh.
import json, sys


def read_prompt(path):
    """Texte brut du fichier, moins l'unique newline final (les chaînes
    d'origine n'en avaient pas ; le trailing space du filler est préservé)."""
    with open(path, encoding="utf-8") as fh:
        text = fh.read()
    return text[:-1] if text.endswith("\n") else text


def main():
    args = sys.argv[1:]
    filler_file, filler_repeat = None, 0
    if "--filler-file" in args:
        i = args.index("--filler-file"); filler_file = args[i+1]; del args[i:i+2]
    if "--filler-repeat" in args:
        i = args.index("--filler-repeat"); filler_repeat = int(args[i+1]); del args[i:i+2]
    if len(args) != 4:
        sys.exit("usage : build_body.py <preset> <max_tokens> <seed> <fichier prompt>"
                 " [--filler-file F --filler-repeat N]")
    preset, max_tokens, seed, prompt_file = args[0], int(args[1]), int(args[2]), args[3]

    content = read_prompt(prompt_file)
    if filler_file:
        content = read_prompt(filler_file) * filler_repeat + content

    print(json.dumps({
        "model": preset,
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "seed": seed,
        "messages": [{"role": "user", "content": content}],
    }, ensure_ascii=False))


if __name__ == "__main__":
    main()
