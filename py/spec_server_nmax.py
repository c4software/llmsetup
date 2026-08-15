#!/usr/bin/env python3
# Lit sur stdin le JSON de /v1/models du routeur llama-server et imprime le
# spec-draft-n-max RÉEL du preset passé en argv[1] (status.args, l'état du
# serveur — pas le ini, que le routeur ne relit qu'au démarrage). Sortie vide
# si le preset est absent ou sans --spec-draft-n-max dans ses args.
# Appelé par lib/spec.sh (cmd_spec_test). Copie exacte de l'ancien python3 -c.
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data", []):
    if m.get("id") == sys.argv[1]:
        a = (m.get("status") or {}).get("args") or []
        for i, x in enumerate(a):
            if x == "--spec-draft-n-max" and i + 1 < len(a):
                print(a[i+1]); break
        break
