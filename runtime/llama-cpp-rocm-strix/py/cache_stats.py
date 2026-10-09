#!/usr/bin/env python3
# Lit une réponse /v1/chat/completions et en sort ce qui concerne le cache de
# prompt : tokens du prompt, tokens servis depuis le cache (cache_n), temps de
# prefill. Sert à --bench-cache, qui rejoue le pattern d'un client agentic
# (même conversation renvoyée avec un peu plus, puis modifiée au milieu).
#
# Usage : cache_stats.py <json> <étiquette>
# Sortie : ligne lisible + PN= CN= PMS= (vides si réponse illisible)
import json, sys


def main():
    etiquette = sys.argv[2] if len(sys.argv) > 2 else ""
    try:
        d = json.loads(sys.argv[1])
    except Exception:
        print("  %-34s réponse illisible" % etiquette); print("PN="); print("CN="); print("PMS="); sys.exit(1)
    if "error" in d:
        e = d["error"]
        print("  %-34s erreur serveur — %s" % (etiquette, e.get("message", e) if isinstance(e, dict) else e))
        print("PN="); print("CN="); print("PMS="); sys.exit(1)
    t = d.get("timings") or {}
    pn, cn, pms = int(t.get("prompt_n", 0)), int(t.get("cache_n", 0)), float(t.get("prompt_ms", 0.0))
    total = pn + cn
    part = 100.0 * cn / total if total else 0.0
    print("  %-34s prompt %5d tok, cache %5d tok (%3.0f %%), prefill %7.0f ms"
          % (etiquette, total, cn, part, pms))
    print("PN=%d" % total)
    print("CN=%d" % cn)
    print("PMS=%.0f" % pms)


if __name__ == "__main__":
    main()
