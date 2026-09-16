#!/usr/bin/env python3
# =============================================================================
# spec_isolate_bench.py — mesures d'un serveur llama-server JETABLE monté par
# tools/spec-isolate.sh, hors service et hors models.ini.
#
# Rôle : dire, AVANT toute déclaration dans lib/models.sh, si un réglage
# spéculatif tient debout — le drafter est-il chargé (acceptance présente et
# non nulle), quel décode il donne, et la sortie est-elle du texte ou du
# charabia. C'est la mesure qui alimente le commentaire métier du bloc ;
# --spec-test / --spec-ab prennent le relais une fois le modèle déclaré.
#
# N'est pas appelé à la main : tools/spec-isolate.sh le lance avec le port du
# serveur jetable. Voir son en-tête pour l'exemple complet.
#
# Usage :
#   spec_isolate_bench.py --port 8099 --tag dsv4-dspark3 --out logs/spec-isolate/dsv4-dspark3 \
#       --prompts spec-test.txt,spec-refactor.txt --passes 2 --max-tokens 1200 --np 1 \
#       [--seed 42] [--temp 0.7]
#
# Sorties :
#   - un tableau texte lisible sur stdout (une ligne par mesure) ;
#   - <out>/mesures.tsv en APPEND : date tag prompt np mesure pp gen n
#     draft_n accepted acceptance sain agrege ec_mode ; agrege est vide sur les
#     lignes de passe séquentielle, et sur les lignes de salve (np > 1) porte
#     le débit agrégé de la salve (somme des predicted_n / temps mur), la
#     colonne gen y restant la médiane par requête ; ec_mode (dernière colonne,
#     16/09/2026) = mode d'alimentation de l'APU passé par --ec-mode, "inconnu"
#     par défaut : un run "balanced" perd 10 à 13 % de décode et ne se compare
#     qu'à un run de même mode ;
#   - <out>/gen-<prompt>-p<N>.txt : reasoning_content + content de chaque
#     passe, à relire quand un chiffre semble trop beau.
#
# Le contrôle de sanité réutilise py/timings.py par import (degenere/periodique) :
# mot dominant, part de mots distincts, répétition périodique de caractères —
# les trois critères calibrés sur le charabia réel de DeepSeek V4 / ROCm0
# (21/08/2026). Un seul jeu de seuils dans le dépôt, pas de copie.
#
# python3 stdlib seule.
# =============================================================================
import argparse
import json
import os
import re
import statistics
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from timings import degenere  # noqa: E402  (même seuils que --bench / --spec-test)

TSV_HDR = "date\ttag\tprompt\tnp\tmesure\tpp\tgen\tn\tdraft_n\taccepted\tacceptance\tsain\tagrege\tec_mode"


def mot_dominant(texte):
    """Mot le plus fréquent et son compte — affiché en appui du verdict de
    sanité, qui reste celui de timings.degenere()."""
    mots = re.findall(r"\w+", texte.lower())
    if not mots:
        return "", 0
    freq = {}
    for m in mots:
        freq[m] = freq.get(m, 0) + 1
    mot = max(freq, key=lambda k: freq[k])
    return mot, freq[mot]


def requete(url, prompt, seed, max_tokens, temp):
    """Une requête /v1/chat/completions. Renvoie un dict de mesures, ou un
    dict {"err": ...} : une passe en erreur ne doit pas tuer le run, le but
    est justement de qualifier un réglage qui peut ne pas marcher."""
    body = {
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "seed": seed,
        "temperature": temp,
    }
    req = urllib.request.Request(
        url, json.dumps(body).encode(), {"Content-Type": "application/json"}
    )
    t0 = time.time()
    try:
        rep = json.load(urllib.request.urlopen(req, timeout=3600))
    except Exception as e:  # réseau, timeout, JSON illisible
        return {"err": str(e), "wall": time.time() - t0}
    if "error" in rep:
        return {"err": str(rep["error"]), "wall": time.time() - t0}
    t = rep.get("timings") or {}
    m = rep["choices"][0]["message"]
    dn, da = t.get("draft_n"), t.get("draft_n_accepted")
    return {
        "pp": t.get("prompt_per_second", 0.0),
        "gen": t.get("predicted_per_second", 0.0),
        "n": t.get("predicted_n", 0),
        "dn": dn,
        "da": da,
        # acceptance = acceptés / draftés ; n/a si le champ manque ou vaut 0,
        # c'est le signe que la spéculation n'a pas tourné du tout.
        "acc": None if not dn else (da or 0) / dn,
        "reasoning": m.get("reasoning_content") or "",
        "content": m.get("content") or "",
        "degen": degenere(rep),
        "wall": time.time() - t0,
    }


def ligne_tsv(fh, tag, prompt, np_, mesure, r, agrege=None, ec_mode="inconnu"):
    fh.write(
        "%s\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n"
        % (
            datetime.now().strftime("%F %T"),
            tag,
            prompt,
            np_,
            mesure,
            "%.0f" % r.get("pp", 0),
            "%.2f" % r.get("gen", 0),
            r.get("n", 0),
            r.get("dn") if r.get("dn") is not None else "n/a",
            r.get("da") if r.get("da") is not None else "n/a",
            "n/a" if r.get("acc") is None else "%.3f" % r["acc"],
            "non" if r.get("degen") else "oui",
            "" if agrege is None else "%.2f" % agrege,
            ec_mode,
        )
    )
    fh.flush()


def sequentiel(args, fh, chemin_prompts):
    """PASSES requêtes séquentielles par prompt (seed 42+i), la 1re servant de
    cache froid comme dans --spec-test : les médianes de fin l'excluent."""
    recap = []
    for nom in args.prompts.split(","):
        nom = nom.strip()
        if not nom:
            continue
        chemin = os.path.join(chemin_prompts, nom)
        if not os.path.isfile(chemin):
            print("prompt introuvable, ignoré : %s" % chemin)
            continue
        with open(chemin, encoding="utf-8") as f:
            prompt = f.read()
        print("── %s (np %d, %d passes) ──" % (nom, args.np, args.passes))
        mesures = []
        for i in range(1, args.passes + 1):
            r = requete(args.url, prompt, args.seed + i, args.max_tokens, args.temp)
            if "err" in r:
                print("  passe %d : ERREUR — %s" % (i, r["err"][:300]))
                continue
            acc = "n/a" if r["acc"] is None else "%.3f (%d/%d)" % (r["acc"], r["da"] or 0, r["dn"])
            froid = "  (cache froid)" if i == 1 else ""
            print(
                "  passe %d : prefill=%.0f t/s  gen=%.2f t/s  n=%d  acceptance=%s%s"
                % (i, r["pp"], r["gen"], r["n"], acc, froid)
            )
            texte = r["reasoning"] + " " + r["content"]
            mot, cnt = mot_dominant(texte)
            print(
                "    sanité : %s  (longueur=%d, mot dominant « %s » x%d)"
                % ("SORTIE DÉGÉNÉRÉE — mesure invalide" if r["degen"] else "ok", len(texte), mot, cnt)
            )
            apercu = (r["content"] or r["reasoning"])[:160]
            print("    aperçu : %s" % repr(apercu))
            with open(
                os.path.join(args.out, "gen-%s-p%d.txt" % (nom.replace(".txt", ""), i)),
                "w",
                encoding="utf-8",
            ) as g:
                g.write(r["reasoning"] + "\n=====CONTENT=====\n" + r["content"])
            ligne_tsv(fh, args.tag, nom, args.np, "passe%d" % i, r, ec_mode=args.ec_mode)
            if i > 1:
                mesures.append(r)
        if mesures:
            recap.append((nom, mesures))
    return recap


def salve(args, prompt, k, seed0):
    """k requêtes simultanées (threads) : c'est ce que fait un serveur à np k
    quand k clients tapent en même temps. Agrégé = somme des tokens générés
    sur le temps mur de la salve ; par requête = médiane des t/s renvoyés."""
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=k) as ex:
        res = list(
            ex.map(
                lambda s: requete(args.url, prompt, s, args.max_tokens, args.temp),
                [seed0 + i for i in range(k)],
            )
        )
    return res, time.time() - t0


def multi_slot(args, fh, chemin_prompts):
    """NP requêtes simultanées, 2 salves (la 1re chauffe le cache de prompt,
    identique pour toutes les requêtes : c'est le cas favorable, le dire)."""
    nom = args.prompts.split(",")[0].strip()
    chemin = os.path.join(chemin_prompts, nom)
    if not os.path.isfile(chemin):
        print("salve NP : prompt introuvable (%s), sautée" % chemin)
        return
    with open(chemin, encoding="utf-8") as f:
        prompt = f.read()
    print("── salves de %d requêtes simultanées (%s) ──" % (args.np, nom))
    for s in (1, 2):
        res, mur = salve(args, prompt, args.np, args.seed + 1000 * s)
        ok = [r for r in res if "err" not in r]
        for r in res:
            if "err" in r:
                print("  ERREUR : %s" % r["err"][:300])
        if not ok:
            print("  salve %d : tout en erreur" % s)
            continue
        agg = sum(r["n"] for r in ok) / mur
        med = statistics.median(r["gen"] for r in ok)
        dn = sum(r["dn"] or 0 for r in ok)
        da = sum(r["da"] or 0 for r in ok)
        acc = None if not dn else da / dn
        degen = any(r["degen"] for r in ok)
        print(
            "  salve %d : ok=%d/%d  agrégé=%.2f t/s  par requête (médiane)=%.2f t/s"
            "  acceptance=%s  mur=%.1f s  sanité=%s"
            % (
                s,
                len(ok),
                args.np,
                agg,
                med,
                "n/a" if acc is None else "%.3f (%d/%d)" % (acc, da, dn),
                mur,
                "DÉGÉNÉRÉE" if degen else "ok",
            )
        )
        ligne_tsv(
            fh,
            args.tag,
            nom,
            args.np,
            "salve%d" % s,
            {
                "pp": statistics.median(r["pp"] for r in ok),
                "gen": med,
                "n": sum(r["n"] for r in ok),
                "dn": dn or None,
                "da": da if dn else None,
                "acc": acc,
                "degen": degen,
            },
            agrege=agg,
            ec_mode=args.ec_mode,
        )
        print("    agrégé = somme des tokens générés / temps mur de la salve")


def main(argv=None):
    p = argparse.ArgumentParser(description="Mesures d'un serveur spéculatif jetable")
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--tag", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--prompts", default="spec-test.txt,spec-refactor.txt")
    p.add_argument("--passes", type=int, default=2)
    p.add_argument("--max-tokens", type=int, default=1200)
    p.add_argument("--np", type=int, default=1)
    p.add_argument("--seed", type=int, default=42)
    p.add_argument("--temp", type=float, default=0.7)
    # Mode d'alimentation de l'APU, lu par tools/spec-isolate.sh sur le
    # contrôleur embarqué (jamais bloquant : "inconnu" si illisible).
    p.add_argument("--ec-mode", default="inconnu")
    p.add_argument(
        "--prompts-dir",
        default=os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "prompts"),
    )
    args = p.parse_args(argv)
    args.url = "http://127.0.0.1:%d/v1/chat/completions" % args.port

    os.makedirs(args.out, exist_ok=True)
    tsv = os.path.join(args.out, "mesures.tsv")
    neuf = not os.path.exists(tsv) or os.path.getsize(tsv) == 0
    with open(tsv, "a", encoding="utf-8") as fh:
        if neuf:
            fh.write(TSV_HDR + "\n")
        recap = sequentiel(args, fh, args.prompts_dir)
        if args.np > 1:
            multi_slot(args, fh, args.prompts_dir)

    print()
    print("── médianes hors 1re passe ──")
    for nom, mesures in recap:
        accs = [r["acc"] for r in mesures if r["acc"] is not None]
        print(
            "  %-20s gen=%.2f t/s  prefill=%.0f t/s  acceptance=%s  (%d passe(s))"
            % (
                nom,
                statistics.median(r["gen"] for r in mesures),
                statistics.median(r["pp"] for r in mesures),
                "n/a" if not accs else "%.3f" % statistics.median(accs),
                len(mesures),
            )
        )
    if not recap:
        print("  aucune passe utile (passes <= 1, ou toutes en erreur)")
    print("→ mesures : %s" % tsv)
    return 0


if __name__ == "__main__":
    sys.exit(main())
