#!/usr/bin/env python3
# Agrège N réponses /v1/chat/completions lancées en même temps (--bench-parallel)
# : tokens générés au total, débit agrégé sur le temps mur, décode médian par
# requête, et nombre de réponses en erreur. C'est le seul endroit où l'on voit
# ce que vaut `parallel = N` d'un modèle : à parallel 1 le serveur sérialise
# (agrégat ≈ une requête, temps mur x N) ; à parallel N le batch partage les
# poids et l'agrégat grimpe, au prix du décode par requête et d'une tranche de
# KV par slot.
#
# Usage : parallel_agg.py <temps_mur_s> <réponse.json>...
# Sortie : ligne lisible + AGG=<t/s> MED=<t/s> TOK=<n> ERR=<n>
import json, sys


def main():
    mur = float(sys.argv[1])
    gens, toks, err = [], 0, 0
    for p in sys.argv[2:]:
        try:
            d = json.load(open(p, encoding="utf-8"))
        except (OSError, ValueError):
            err += 1
            continue
        if "error" in d or not d.get("timings"):
            err += 1
            continue
        t = d["timings"]
        toks += int(t.get("predicted_n", 0))
        if t.get("predicted_per_second"):
            gens.append(float(t["predicted_per_second"]))
    n = len(sys.argv) - 2
    gens.sort()
    med = (gens[len(gens) // 2] if len(gens) % 2 else (gens[len(gens) // 2 - 1] + gens[len(gens) // 2]) / 2) if gens else 0.0
    agg = toks / mur if mur > 0 else 0.0
    print("  %d requête(s) : %d tokens en %.1f s → agrégé %.2f t/s, décode médian par requête %.2f t/s%s"
          % (n, toks, mur, agg, med, ("  (%d en erreur)" % err) if err else ""))
    print("AGG=%.2f" % agg)
    print("MED=%.2f" % med)
    print("TOK=%d" % toks)
    print("ERR=%d" % err)


if __name__ == "__main__":
    main()
