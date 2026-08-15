#!/usr/bin/env python3
# Parse le champ `timings` d'une réponse /v1/chat/completions de llama-server
# et produit la ligne d'affichage d'une passe + les valeurs machine consommées
# par le bash (sed -n 's/^PP=//p' etc.) — sorties au caractère près identiques
# aux anciens heredocs de _bench_one et cmd_spec_test.
#
# Usage :
#   timings.py --bench <json> <n° de passe>            → ligne + PP=/G=/A=
#     (+ PPCACHED=1 si cache_n > 0 en passe 1 : prefill contaminé, marqué "*"
#      dans le récap côté bash)
#   timings.py --spec  <json> <n° de passe> <flag>     → ligne + GEN=/ACC=/DN=
#     (flag = "spec" si le modèle est spéculatif : affiche "acceptance=n/a …"
#      quand draft_n est absent des timings ; "" sinon)
#
# Les deux branches sont les copies exactes des heredocs d'origine : sys.argv
# est décalé d'un cran (pop du mode) pour ne pas toucher aux indices.
import json, sys

mode = sys.argv.pop(1) if len(sys.argv) > 1 else ""

if mode == "--bench":
    try:
        d = json.loads(sys.argv[1])
    except Exception:
        print(f"  passe {sys.argv[2]} : réponse illisible"); sys.exit(1)
    if "error" in d:
        e = d["error"]
        msg = e.get("message", e) if isinstance(e, dict) else e
        print(f"  passe {sys.argv[2]} : erreur serveur — {msg}"); sys.exit(1)
    t = d.get("timings") or {}
    pp, tg = t.get("prompt_per_second", 0), t.get("predicted_per_second", 0)
    pn, n = t.get("prompt_n", 0), t.get("predicted_n", 0)
    cached = t.get("cache_n", 0)
    dn, da = t.get("draft_n"), t.get("draft_n_accepted")
    acc = f"  acceptance={da/dn:.2f}" if dn else ""
    note = "" if sys.argv[2] == "1" else "  (prompt cache)"
    # cache_n > 0 en passe 1 : le prefill est partiellement servi depuis un état
    # antérieur (slot-prompt-similarity + cache-ram/checkpoints) → chiffre gonflé.
    # Signalé (ligne + PPCACHED= pour le "*" du récap), jamais corrigé ici :
    # --bench reste une mesure passive du serveur tel qu'il tourne.
    warn = "  ⚠ prefill partiellement servi par le cache" if sys.argv[2] == "1" and cached else ""
    print(f"  passe {sys.argv[2]} : prefill={pp:.0f} t/s (n={pn}, cache={cached})  décode={tg:.2f} t/s (n={n}){acc}{note}{warn}")
    if sys.argv[2] == "1":
        print(f"PP={pp:.2f}")
        if cached:
            print("PPCACHED=1")
    else:
        print(f"G={tg:.2f}")
    if dn:
        print(f"A={da/dn:.2f}")
elif mode == "--spec":
    try:
        d = json.loads(sys.argv[1])
    except Exception:
        print(f"passe {sys.argv[2]} : réponse illisible"); sys.exit(1)
    if "error" in d:
        print(f"passe {sys.argv[2]} : erreur serveur — {d['error']}"); sys.exit(1)
    t = d.get("timings") or {}
    pp, tg, n = t.get("prompt_per_second", 0), t.get("predicted_per_second", 0), t.get("predicted_n", 0)
    pn = t.get("prompt_n", 0)
    cached = t.get("cache_n", 0)
    dn, da = t.get("draft_n"), t.get("draft_n_accepted")
    if dn:
        acc = f"  acceptance={da/dn:.2f} ({da}/{dn})"
    elif "spec" in sys.argv[3]:
        acc = "  acceptance=n/a (pas de draft_n dans timings : spéculation inactive ?)"
    else:
        acc = ""
    tag = "  (cache froid, à ignorer)" if sys.argv[2] == "1" else ""
    # prompt_n petit = prompt cache actif → prompt t/s non significatif (résidu + overhead)
    pptxt = f"prompt={pp:.0f} t/s (n={pn}, cache={cached})" if pn else f"prompt={pp:.0f} t/s"
    print(f"passe {sys.argv[2]} : {pptxt}  gen={tg:.2f} t/s  n={n}{acc}{tag}")
    print(f"GEN={tg:.2f}")
    if dn: print(f"ACC={da/dn:.3f}"); print(f"DN={dn} DA={da} PN={n}")
else:
    print(f"timings.py : mode inconnu '{mode}' (--bench|--spec)", file=sys.stderr)
    sys.exit(2)
