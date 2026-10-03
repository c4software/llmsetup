#!/usr/bin/env python3
# Rejeu d'UNE requête d'une session pi, N fois par bras, pour compter ce que
# le modèle répond à contexte strictement égal (docs/GUFO.md, gufo#388 : la
# « première correction » après un test raté). Isole une décision du reste de
# la boucle agentique : quelques minutes de GPU au lieu d'heures de séries.
#
# Usage :
#   runtime-gufo/bench/rejeu.py <session.jsonl> <motif> <N> <sortie.jsonl> <bras>...
#     session.jsonl  session pi gardée par le banc (PI_SESSIONS=1)
#     motif          texte du résultat d'outil où la conversation est coupée
#                    (le premier qui le contient, par exemple « 3 !== 4 ») :
#                    la requête rejouée est celle que pi envoie juste après
#     bras           nom=capture.jsonl[,presence=X] : l'enveloppe (prompt
#                    système, outils, paramètres) vient de la requête de
#                    capture.jsonl (bench/capture.py) qui porte la même
#                    consigne utilisateur que la session ; presence=X ajoute
#                    presence_penalty à la requête (absent : profil du serveur)
#   URL=http://127.0.0.1:8009 par défaut (variable d'environnement URL).
#
# Les bras sont alternés à chaque tour (pas de dérive d'un bras à l'autre),
# sans flux. Chaque réponse brute va dans sortie.jsonl ({"i", "bras",
# "reponse"}), en ajout : relancer reprend à la suite. À la fin, un décompte
# par bras : outil appelé, texte avant l'appel ou non, et pour un edit le
# newText (120 premiers caractères), à classer selon la question posée.
import collections, json, os, sys, urllib.request

session, motif, n, sortie = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
URL = os.environ.get("URL", "http://127.0.0.1:8009")

suite, consigne, coupe = [], None, False
for l in open(session):
    m = json.loads(l).get("message") or {}
    c = m.get("content")
    if m.get("role") == "user" and consigne is None:
        consigne = "".join(b.get("text", "") for b in c) if isinstance(c, list) else c
    elif m.get("role") == "assistant":
        texte = "".join(b.get("text", "") for b in c if b.get("type") == "text")
        # Mêmes arguments que pi sur le fil : JSON compact, ordre des clés gardé.
        suite.append({"role": "assistant", "content": texte or None, "tool_calls": [
            {"id": b["id"], "type": "function", "function": {
                "name": b["name"],
                "arguments": json.dumps(b["arguments"], ensure_ascii=False, separators=(",", ":"))}}
            for b in c if b.get("type") == "toolCall"]})
    elif m.get("role") == "toolResult":
        t = "".join(b.get("text", "") for b in c)
        suite.append({"role": "tool", "content": t, "tool_call_id": m["toolCallId"]})
        if motif in t:
            coupe = True
            break
if not coupe:
    sys.exit(f"motif « {motif} » absent des résultats d'outils de {session}")

bras = []
for spec in sys.argv[5:]:
    nom, reste = spec.split("=", 1)
    capture, _, opt = reste.partition(",presence=")
    corps = [json.loads(l)["body"] for l in open(capture)]
    env = [b for b in corps if consigne in json.dumps(b["messages"][1], ensure_ascii=False)
           or consigne in str(b["messages"][1].get("content"))]
    if not env:
        sys.exit(f"{capture} : aucune requête avec la consigne de la session")
    base = {k: v for k, v in env[-1].items() if k not in ("messages", "stream", "stream_options")}
    base["messages"] = env[-1]["messages"][:2] + suite
    base["stream"] = False
    if opt:
        base["presence_penalty"] = float(opt)
    bras.append((nom, base))
if not bras:
    sys.exit("aucun bras (nom=capture.jsonl[,presence=X])")

with open(sortie, "a") as f:
    for i in range(n):
        for nom, base in bras:
            req = urllib.request.Request(URL + "/v1/chat/completions",
                                         data=json.dumps(base, ensure_ascii=False).encode(),
                                         headers={"Content-Type": "application/json"})
            try:
                r = json.load(urllib.request.urlopen(req, timeout=600))
            except Exception as e:  # on garde la trace et on continue
                r = {"erreur": repr(e)}
            f.write(json.dumps({"i": i, "bras": nom, "reponse": r}, ensure_ascii=False) + "\n")
            f.flush()
        if (i + 1) % 10 == 0:
            print("tour", i + 1, flush=True)

bilan = collections.Counter()
for l in open(sortie):
    e = json.loads(l)
    r = e["reponse"]
    if "erreur" in r:
        bilan[(e["bras"], "erreur", "", "")] += 1
        continue
    m = r["choices"][0]["message"]
    appels = m.get("tool_calls") or []
    outil = appels[0]["function"]["name"] if appels else "-"
    detail = ""
    if outil == "edit":
        try:
            detail = " | ".join(x["newText"] for x in json.loads(appels[0]["function"]["arguments"])["edits"])[:120]
        except Exception:
            detail = "arguments illisibles"
    bilan[(e["bras"], outil, "texte" if (m.get("content") or "").strip() else "sans texte", detail)] += 1
for (nom, outil, texte, detail), v in sorted(bilan.items()):
    print(f"BRAS={nom}\tN={v}\tOUTIL={outil}\t{texte}\t{detail}")
print("FIN", flush=True)
