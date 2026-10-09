#!/usr/bin/env python3
# Bilan agentique d'un ou plusieurs journaux gufo (sortie de docker logs, que
# runtime/gufo/bench/agentic.sh garde dans GUFO_DATA/resultats/agentic/) : le
# /metrics de gufo n'a ni compteur de cache ni secondes, les vraies valeurs
# sont dans ses lignes event=completed, une par requête.
#
# Seules les chat completions comptent. Pour chaque journal : sources du
# cache (memory / disk / miss) et raisons des ratés, part du prompt reprise,
# tokens recalculés, temps passé en prefill et en décode (tokens / débit de
# chaque requête, sommés), premier token des requêtes de moins de 100 tokens
# recalculés (le coût fixe par requête, invisible à 52k), acceptance du
# spéculatif sur les réponses de plus de 20 tokens, et les points de reprise
# du cache disque écrits (action=stored) et refusés (action=skipped, par
# exemple reason=staging_capacity).
#
# Usage : journal.py <journal gufo>...
import re, statistics as st, sys


def val(d, k):
    try:
        return float(d.get(k, 0) or 0)
    except ValueError:
        return 0.0


def bilan(chemin):
    req, ecrits, refus = [], 0, {}
    for ligne in open(chemin, errors="replace"):
        if "event=disk_cache " in ligne:
            if "action=stored" in ligne:
                ecrits += 1
            elif "action=skipped" in ligne:
                r = re.search(r"reason=(\S+)", ligne)
                refus[r.group(1) if r else "?"] = refus.get(r.group(1) if r else "?", 0) + 1
        if "event=completed" in ligne and "path=/v1/chat/completions" in ligne:
            req.append(dict(re.findall(r"(\w+)=(\S+)", ligne)))
    print(chemin)
    if not req:
        print("  aucune chat completion")
        return
    prompt = sum(val(d, "prompt_tokens") for d in req)
    repris = sum(val(d, "cached_tokens") for d in req)
    sources, rates = {}, {}
    for d in req:
        s = d.get("cache", "?")
        sources[s] = sources.get(s, 0) + 1
        if s == "miss":
            r = d.get("cache_miss_reason", "?")
            rates[r] = rates.get(r, 0) + 1
    t_pre = sum(val(d, "prefill_tokens") / val(d, "prefill_tps") for d in req if val(d, "prefill_tps") > 0)
    t_dec = sum(val(d, "generated_tokens") / val(d, "decode_tps") for d in req if val(d, "decode_tps") > 0)
    gen = sum(val(d, "generated_tokens") for d in req)
    petits = [val(d, "ttft_ms") for d in req if 0 < val(d, "prefill_tokens") < 100]
    acc = [val(d, "acceptance_pct") for d in req
           if val(d, "draft_proposed") > 0 and val(d, "generated_tokens") > 20]
    med = lambda l: st.median(l) if l else 0
    print(f"  requêtes {len(req)} : "
          + ", ".join(f"{k} {v}" for k, v in sorted(sources.items()))
          + (" ; ratés " + ", ".join(f"{k} {v}" for k, v in sorted(rates.items())) if rates else ""))
    print(f"  prompt repris {100 * repris / prompt:.1f} % ({repris:.0f} sur {prompt:.0f}), "
          f"recalculés {prompt - repris:.0f}")
    print(f"  temps en prefill {t_pre:.0f} s, en décode {t_dec:.0f} s "
          f"({gen:.0f} générés, {gen / t_dec if t_dec else 0:.1f} t/s)")
    print(f"  premier token des requêtes < 100 tokens recalculés : médiane {med(petits):.0f} ms (n = {len(petits)})")
    print(f"  acceptance du spéculatif (réponses > 20 tokens) : médiane {med(acc):.1f} %")
    print(f"  points de reprise disque écrits {ecrits}, refusés "
          + (", ".join(f"{k} {v}" for k, v in sorted(refus.items())) if refus else "0"))


if len(sys.argv) < 2:
    sys.exit("usage : journal.py <journal gufo>...")
for f in sys.argv[1:]:
    bilan(f)
