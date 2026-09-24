#!/usr/bin/env python3
# Banc neutre gufo contre llama-server : mêmes requêtes HTTP (chat, streaming)
# aux deux moteurs, débits mesurés à l'horloge du client (TTFT, puis tokens
# générés / temps entre premier et dernier token) ET relevés dans les
# `timings` compatibles llama.cpp que les deux moteurs renvoient.
#
# Appelé par runtime-gufo/bench/run.sh ; les prompts sont ceux de prompts/.
#
# Usage : mesure.py <url> <modèle> <étiquette> <dossier résultats> <dossier prompts>
import json, os, random, sys, time, urllib.request

URL, MODEL, LABEL, OUT, PROMPTS = sys.argv[1:6]
os.makedirs(os.path.join(OUT, "reponses"), exist_ok=True)
TSV = os.path.join(OUT, "resultats.tsv")
COLS = ["date", "etiquette", "test", "passe", "prompt_n", "cache_n", "gen_n",
        "ttft_s", "prefill_horloge", "decode_horloge", "prefill_moteur",
        "decode_moteur", "juste", "note"]


def lire(nom):
    with open(os.path.join(PROMPTS, nom), encoding="utf-8") as f:
        t = f.read()
    return t[:-1] if t.endswith("\n") else t


def requete(messages, max_tokens, temperature, seed, nonce=True):
    """Une requête streaming ; retourne un dict de mesures et le texte."""
    if nonce:  # préfixe unique : pas de reprise de cache entre passes
        messages = [dict(messages[0], content="[run %08x]\n" % random.getrandbits(32)
                         + messages[0]["content"])] + messages[1:]
    body = {"model": MODEL, "messages": messages, "max_tokens": max_tokens,
            "temperature": temperature, "seed": seed, "stream": True,
            "stream_options": {"include_usage": True},
            "chat_template_kwargs": {"enable_thinking": False}}
    req = urllib.request.Request(URL + "/v1/chat/completions",
                                 data=json.dumps(body).encode(),
                                 headers={"Content-Type": "application/json"})
    t0 = time.monotonic(); t1 = t2 = None
    texte, pensee, usage, timings = [], [], {}, {}
    with urllib.request.urlopen(req, timeout=3600) as r:
        for ligne in r:
            ligne = ligne.decode().strip()
            if not ligne.startswith("data:"):
                continue
            data = ligne[5:].strip()
            if data == "[DONE]":
                break
            d = json.loads(data)
            usage = d.get("usage") or usage
            timings = d.get("timings") or timings
            for c in d.get("choices") or []:
                delta = c.get("delta") or {}
                morceau = (delta.get("content") or "") + (delta.get("reasoning_content") or "")
                if morceau:
                    now = time.monotonic()
                    t1 = t1 or now
                    t2 = now
                    texte.append(delta.get("content") or "")
                    pensee.append(delta.get("reasoning_content") or "")
    tfin = time.monotonic()
    gen_n = usage.get("completion_tokens") or timings.get("predicted_n") or 0
    prompt_total = usage.get("prompt_tokens") or 0
    cache_n = timings.get("cache_n", 0) or 0
    prompt_n = timings.get("prompt_n") or (prompt_total - cache_n)
    ttft = (t1 or tfin) - t0
    m = {
        "prompt_n": prompt_n, "cache_n": cache_n, "gen_n": gen_n,
        "ttft_s": round(ttft, 3),
        "prefill_horloge": round(prompt_n / ttft, 1) if ttft > 0 else 0,
        "decode_horloge": round((gen_n - 1) / (t2 - t1), 2) if t1 and t2 and t2 > t1 and gen_n > 1 else 0,
        "prefill_moteur": round(timings.get("prompt_per_second", 0) or 0, 1),
        "decode_moteur": round(timings.get("predicted_per_second", 0) or 0, 2),
    }
    return m, "".join(texte), "".join(pensee)


def ecrire(test, passe, m, juste, note="", texte=""):
    neuf = not os.path.exists(TSV)
    with open(TSV, "a", encoding="utf-8") as f:
        if neuf:
            f.write("\t".join(COLS) + "\n")
        ligne = dict(m, date=time.strftime("%Y-%m-%dT%H:%M:%S"), etiquette=LABEL,
                     test=test, passe=passe, juste=juste, note=note)
        f.write("\t".join(str(ligne.get(c, "")) for c in COLS) + "\n")
    with open(os.path.join(OUT, "reponses", "%s_%s_%s.txt" % (LABEL, test, passe)), "w") as f:
        f.write(texte)
    print("%-28s %-10s p%s  prompt %6s (cache %6s)  gen %5s  pp %7s  tg %6s  [moteur %7s / %6s]  %s %s"
          % (LABEL, test, passe, m["prompt_n"], m["cache_n"], m["gen_n"], m["prefill_horloge"],
             m["decode_horloge"], m["prefill_moteur"], m["decode_moteur"], juste, note), flush=True)


def filler(n_tokens, code, position=0.37):
    """Lignes numérotées avec une aiguille. La taille visée suppose ~22 tokens
    par ligne, il en faut ~36 avec le tokenizer Qwen : « prefill4k » fait en
    réalité 6,5k tokens et « prefill32k » 52k (5,3k et 42k chez DeepSeek). Les
    étiquettes sont gardées telles quelles, pour rester comparables aux mesures
    du 24/09/2026."""
    n = max(1, n_tokens // 22)
    lignes = ["Ligne %05d : le capteur %d du bâtiment %s relève %d unités à %02d h %02d."
              % (i, i * 7 % 997, "ABCDEFGH"[i % 8], (i * 7919) % 10000, i % 24, i * 13 % 60)
              for i in range(n)]
    lignes.insert(int(n * position), "Note de service : le code d'accès du local technique est %s." % code)
    return "\n".join(lignes)


def main():
    random.seed()
    # 1. Justesse courte (prompt de --bench-sanity)
    m, t, p = requete([{"role": "user", "content": lire("bench-sanity.txt")}], 400, 0.0, 7, nonce=False)
    ecrire("sanity", 1, m, "OK" if "LAMPADAIRE-2719" in t + p else "KO", texte=t or p)

    # 2. Conditions du --bench du dépôt : contexte + tâche, 1000 tokens, 0.7, seed 42+i
    corps = lire("bench-context.txt") + "\n\n" + lire("bench-task.txt")
    for i in range(1, 4):
        m, t, p = requete([{"role": "user", "content": corps}], 1000, 0.7, 42 + i)
        ecrire("bench", i, m, "OK" if "class Inventory" in t else "?", texte=t or p)

    # 3. Réécriture de code (prompt spec-refactor, favorable au spéculatif)
    for i in range(1, 4):
        m, t, p = requete([{"role": "user", "content": lire("spec-refactor.txt")}], 1500, 0.7, 42 + i)
        ecrire("refactor", i, m, "OK" if "def " in t else "?", texte=t or p)

    # 4. Prefill à 4k et 32k avec aiguille (justesse en contexte long)
    for cible, passes in ((4000, 2), (32000, 1)):
        for i in range(1, passes + 1):
            code = "HIBOU-%04d" % random.randrange(10000)
            q = filler(cible, code) + "\n\nQuel est le code d'accès du local technique ? Réponds uniquement par le code."
            m, t, p = requete([{"role": "user", "content": q}], 60, 0.0, 1)
            ecrire("prefill%dk" % (cible // 1000), i, m, "OK" if code in t + p else "KO", code, texte=t or p)

    # 5. Reprise de cache : tour 1 à ~20k, tour 2 = même historique + question
    code = "CHOUETTE-%04d" % random.randrange(10000)
    doc = filler(20000, code, 0.8)
    # préfixe fixe propre à ce run : le tour 1 est neuf, le tour 2 le prolonge
    q1b = [{"role": "user", "content": "[run %08x]\n" % random.getrandbits(32) + doc
            + "\n\nCombien de bâtiments différents sont cités ? Réponds par un nombre."}]
    m, t1, p = requete(q1b, 60, 0.0, 1, nonce=False)
    ecrire("cache_t1", 1, m, "OK" if "8" in t1 else "?", texte=t1 or p)
    q2 = q1b + [{"role": "assistant", "content": t1},
                {"role": "user", "content": "Quel est le code d'accès du local technique ? Réponds uniquement par le code."}]
    m, t, p = requete(q2, 60, 0.0, 1, nonce=False)
    ecrire("cache_t2", 1, m, "OK" if code in t + p else "KO",
           "cache %.0f %%" % (100.0 * m["cache_n"] / max(1, m["cache_n"] + m["prompt_n"])), texte=t or p)


if __name__ == "__main__":
    main()
