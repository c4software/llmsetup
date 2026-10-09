#!/usr/bin/env python3
# Contrôle de justesse minimal d'une réponse : la valeur attendue doit
# apparaître dans le texte généré (contenu, ou raisonnement pour un modèle qui
# pense et n'a pas fini). Complète le garde-fou « sortie dégénérée » de
# timings.py : un backend peut produire un texte propre et faux (dérive
# numérique d'un noyau), ce que seule une question à réponse connue attrape.
#
# Usage : check_answer.py <json> <attendu>
# Sortie : ligne lisible, code 0 si trouvé, 1 sinon (2 si réponse illisible)
import json, re, sys


def main():
    attendu = sys.argv[2]
    try:
        d = json.loads(sys.argv[1])
        m = d["choices"][0]["message"]
    except Exception:
        print("  justesse : réponse illisible"); sys.exit(2)
    contenu = (m.get("content") or "").strip()
    pensee = (m.get("reasoning_content") or "")
    # la valeur doit apparaître entière (LAMPADAIRE-2719, pas LAMPADAIRE-27190)
    motif = r"(?<![0-9A-Za-z])%s(?![0-9A-Za-z])" % re.escape(attendu)
    if re.search(motif, contenu):
        print("  justesse : OK (%s dans la réponse : %r)" % (attendu, contenu[:60])); sys.exit(0)
    if re.search(motif, pensee):
        print("  justesse : OK dans le raisonnement seulement (%s ; réponse : %r)" % (attendu, contenu[:60])); sys.exit(0)
    print("  justesse : ÉCHEC — attendu %s, réponse : %r" % (attendu, (contenu or pensee)[:80])); sys.exit(1)


if __name__ == "__main__":
    main()
