#!/usr/bin/env python3
# Lit sur stdin le JSON de /v1/models du routeur llama-server et imprime la
# valeur RÉELLE d'un flag du modèle passé en argv[1] (status.args, l'état du
# serveur — pas le ini, que le routeur ne relit qu'au démarrage). Sortie vide
# si le modèle est absent ou si le flag n'est pas dans ses args.
# argv[2] = flag à lire, défaut --spec-draft-n-max (le nom du script est resté
# celui de son usage d'origine ; il sert aussi à lire --spec-type depuis que le
# spec-type peut être une liste, cf. lib/spec.sh).
# Appelé par lib/spec.sh (cmd_spec_test).
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
flag = sys.argv[2] if len(sys.argv) > 2 else "--spec-draft-n-max"
for m in d.get("data", []):
    if m.get("id") == sys.argv[1]:
        a = (m.get("status") or {}).get("args") or []
        for i, x in enumerate(a):
            if x == flag and i + 1 < len(a):
                print(a[i+1]); break
        break
