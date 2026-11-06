#!/usr/bin/env python3
# Divergence des sorties d'un modèle servi par gufo contre une référence :
# même jeu de prompts en glouton, 20 meilleurs logprobs par token généré,
# puis comparaison position par position tant que le contexte est le même.
# Sert à juger une variante de poids (table n-gram de Flash-Next en Q8_0 ou
# IQ4_NL contre BF16 sans perte, table-ngram.sh) là où les bancs à tâches ne
# voient rien : nos 16 scénarios pi passent avec toutes.
#
# Usage :
#   divergence.py collecte <url> <modèle> <prompts.txt> <sortie.jsonl>
#   divergence.py compare <référence.jsonl> <candidat.jsonl>... [--tsv f --image i]
#
# Collecte : prompts séparés par une ligne « ==== » (prompts/divergence.txt),
# 256 tokens, température 0, sans raisonnement (macro du yaml), sans
# reprise ni écriture de cache (cache_persist false : une table ne doit pas
# reprendre l'état calculé par une autre). Une ligne JSON par prompt : texte
# et, par token, ses octets en hexadécimal, son logprob et les 20 meilleurs.
#
# Compare, pour chaque candidat contre la référence, sur les positions où les
# deux ont vu le même contexte (jusqu'au premier token différent compris) :
# - identiques : prompts dont les 256 tokens sont les mêmes ;
# - préfixe : longueur moyenne du début identique, en tokens ;
# - KL : divergence de Kullback-Leibler de la référence vers le candidat,
#   approchée sur les 20 meilleurs tokens de la référence (un token absent
#   du top 20 du candidat y prend le plus petit logprob de ce top 20), en
#   nats par token : moyenne, 99e centile et maximum ;
# - écart top-1/top-2 de la référence aux points de divergence (médiane) :
#   petit, la divergence tient à une quasi-égalité, pas à une erreur franche.
# Deux collectes de la même table (bf16 bf16) donnent le plancher de bruit :
# MoE servi en spéculatif, le glouton de gufo n'est pas garanti identique
# d'une exécution à l'autre.
# Garde-fous : une réponse sans logprobs arrête tout (une métrique à zéro
# passerait pour une identité parfaite) ; une réponse dégénérée (moins de
# 20 % de tokens distincts) est comptée et signalée.
import json, statistics, sys, time, urllib.request

MAX_TOKENS = 256
TOP = 20


def lire_prompts(chemin):
    with open(chemin, encoding="utf-8") as f:
        blocs = f.read().split("\n====\n")
    return [b.strip() for b in blocs if b.strip()]


def collecte(url, modele, prompts, sortie):
    with open(sortie, "w", encoding="utf-8") as out:
        for i, p in enumerate(lire_prompts(prompts), 1):
            body = {"model": modele, "messages": [{"role": "user", "content": p}],
                    "max_tokens": MAX_TOKENS, "temperature": 0, "seed": 1,
                    "logprobs": True, "top_logprobs": TOP, "cache_persist": False,
                    "chat_template_kwargs": {"enable_thinking": False}}
            req = urllib.request.Request(url + "/v1/chat/completions",
                                         data=json.dumps(body).encode(),
                                         headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=3600) as r:
                d = json.load(r)
            c = d["choices"][0]
            lp = (c.get("logprobs") or {}).get("content") or []
            if not lp:
                sys.exit("ERREUR : prompt %d sans logprobs, collecte arrêtée" % i)
            toks = [[bytes(t["bytes"]).hex(), t["logprob"],
                     [[bytes(a["bytes"]).hex(), a["logprob"]] for a in t["top_logprobs"]]]
                    for t in lp]
            out.write(json.dumps({"i": i, "texte": c["message"].get("content") or "",
                                  "tokens": toks}, ensure_ascii=False) + "\n")
            print("prompt %2d : %3d tokens" % (i, len(toks)), flush=True)


def charger(chemin):
    with open(chemin, encoding="utf-8") as f:
        return {r["i"]: r for r in map(json.loads, f)}


def centile(v, q):
    v = sorted(v)
    return v[min(len(v) - 1, int(q * len(v)))] if v else 0.0


def degeneree(toks):
    return len(toks) >= 50 and len({t[0] for t in toks}) < 0.2 * len(toks)


def compare1(ref, cand):
    kls, prefixes, ecarts = [], [], []
    identiques = degen = 0
    for i, r in ref.items():
        if i not in cand:
            sys.exit("ERREUR : prompt %d absent du candidat" % i)
        a, b = r["tokens"], cand[i]["tokens"]
        if not a or not b:
            sys.exit("ERREUR : prompt %d sans tokens (référence ou candidat)" % i)
        degen += degeneree(b)
        n = min(len(a), len(b))
        d = next((k for k in range(n) if a[k][0] != b[k][0]), None)
        if d is None and len(a) == len(b):
            identiques += 1
        fin = n if d is None else d + 1
        prefixes.append(n if d is None else d)
        if d is not None:
            top = sorted((x[1] for x in a[d][2]), reverse=True)
            ecarts.append(top[0] - top[1] if len(top) > 1 else 0.0)
        for k in range(fin):
            pc = {x[0]: x[1] for x in b[k][2]}
            plancher = min(pc.values())
            kls.append(sum(2.718281828459045 ** lr * (lr - pc.get(t, plancher))
                           for t, lr in a[k][2]))
    return {"prompts": len(ref), "identiques": identiques,
            "prefixe": round(statistics.mean(prefixes), 1),
            "positions": len(kls), "kl_moyen": round(statistics.mean(kls), 5),
            "kl_p99": round(centile(kls, 0.99), 4), "kl_max": round(max(kls), 4),
            "ecart_div": round(statistics.median(ecarts), 3) if ecarts else "",
            "degenerees": degen}


def compare(args):
    tsv = image = None
    if "--tsv" in args:
        k = args.index("--tsv"); tsv = args[k + 1]; del args[k:k + 2]
    if "--image" in args:
        k = args.index("--image"); image = args[k + 1]; del args[k:k + 2]
    ref = charger(args[0])
    cols = ["prompts", "identiques", "prefixe", "positions", "kl_moyen", "kl_p99",
            "kl_max", "ecart_div", "degenerees"]
    print("référence : %s" % args[0])
    print("%-34s %s" % ("candidat", "  ".join("%9s" % c for c in cols)))
    for chemin in args[1:]:
        m = compare1(ref, charger(chemin))
        nom = chemin.rsplit("/", 1)[-1].removesuffix(".jsonl")
        print("%-34s %s%s" % (nom, "  ".join("%9s" % m[c] for c in cols),
                              "  RÉPONSES DÉGÉNÉRÉES" if m["degenerees"] else ""))
        if tsv:
            neuf = False
            try:
                open(tsv).close()
            except FileNotFoundError:
                neuf = True
            with open(tsv, "a", encoding="utf-8") as f:
                if neuf:
                    f.write("\t".join(["date", "image", "reference", "candidat"] + cols) + "\n")
                ligne = [time.strftime("%Y-%m-%dT%H:%M:%S"), image or "",
                         args[0].rsplit("/", 1)[-1].removesuffix(".jsonl"), nom]
                f.write("\t".join(ligne + [str(m[c]) for c in cols]) + "\n")


if __name__ == "__main__":
    if len(sys.argv) == 6 and sys.argv[1] == "collecte":
        collecte(*sys.argv[2:6])
    elif len(sys.argv) >= 4 and sys.argv[1] == "compare":
        compare(sys.argv[2:])
    else:
        sys.exit(__doc__ if __doc__ else open(__file__).read().split("import json")[0])
