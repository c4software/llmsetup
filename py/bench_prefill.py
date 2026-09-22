#!/usr/bin/env python3
# bench_prefill.py — prefill à froid en profondeur, par l'API du service.
#
# Deux modes, appelés par lib/bench/bench-prefill.sh :
#
#   mesure <url> <modèle> <passes> <tailles,séparées,par,virgules> <fichier>...
#     Pour chaque taille (en tokens visés) et chaque passe, une requête
#     /v1/chat/completions avec un contenu UNIQUE (nonce + tranche des fichiers
#     de corpus prise à un décalage aléatoire, ~3 caractères par token), sans
#     cache de prompt (cache_prompt false), max_tokens 8, température 0. Lit
#     les `timings` de llama-server : prompt_n (tokens réellement prefillés),
#     prompt_ms, prompt_per_second. Une requête est SAINE si le serveur n'a
#     rien servi du cache (cached_tokens = 0) et si la réponse n'est pas vide :
#     un prefill « trop beau » vient toujours d'un préfixe déjà en cache (cf.
#     le 835 t/s du 18/09/2026 dans docs/HISTORIQUE.md) ou d'un moteur qui ne
#     génère rien. Sort une ligne lisible par requête et une ligne
#     contractuelle :
#       TSV\t<cible>\t<passe>\t<prompt_n>\t<prompt_ms>\t<prefill_tps>\t<cache_n>\t<sain 1|0>
#     consommée par le bash (journal logs/bench-prefill.log) et par `bilan`.
#
#   bilan   (stdin = les lignes TSV ci-dessus, avec ou sans préfixe "TSV\t")
#     Tableau des médianes par taille sur les passes SAINES seulement, et
#     une ligne contractuelle par taille :
#       MED=<cible>:<prompt_n médian>:<prefill_tps médian>:<passes saines>/<passes>
#
# Aucune dépendance hors stdlib. Le corpus n'est pas un prompt de prompts/ :
# n'importe quel texte long fait l'affaire, seule l'unicité compte.
import json
import random
import sys
import time
import urllib.error
import urllib.request

CHARS_PAR_TOKEN = 3


def _median(vals):
    vals = sorted(vals)
    n = len(vals)
    if n == 0:
        return 0.0
    return vals[n // 2] if n % 2 else (vals[n // 2 - 1] + vals[n // 2]) / 2


def mesure(url, modele, passes, tailles, fichiers):
    corpus = ""
    for f in fichiers:
        try:
            with open(f, errors="ignore") as fh:
                corpus += fh.read() + "\n"
        except OSError:
            pass
    if len(corpus) < 1000:
        print("ERREUR : corpus vide (fichiers illisibles)", file=sys.stderr)
        return 2
    print("cible\tpasse\tprompt_n\tprompt_ms\tprefill t/s\tcache_n\tsain")
    rc = 0
    for cible in tailles:
        besoin = cible * CHARS_PAR_TOKEN
        for passe in range(1, passes + 1):
            random.seed(time.time_ns())
            texte = corpus
            while len(texte) < besoin + 1000:
                texte += corpus
            debut = random.randrange(0, len(texte) - besoin)
            body = "nonce-%d\n%s\n\nRéponds par un seul mot." % (random.randrange(10 ** 12), texte[debut:debut + besoin])
            req = {"model": modele, "messages": [{"role": "user", "content": body}],
                   "max_tokens": 8, "temperature": 0, "cache_prompt": False}
            data = json.dumps(req).encode()
            t0 = time.time()
            try:
                r = urllib.request.urlopen(urllib.request.Request(
                    url + "/v1/chat/completions", data, {"Content-Type": "application/json"}), timeout=3600)
                d = json.load(r)
            except (urllib.error.URLError, urllib.error.HTTPError, ValueError, OSError) as e:
                print("%d\t%d\tERREUR : %s" % (cible, passe, str(e)[:120]))
                print("TSV\t%d\t%d\t0\t0\t0\t0\t0" % (cible, passe))
                rc = 1
                continue
            mur = time.time() - t0
            t = d.get("timings") or {}
            u = d.get("usage") or {}
            pn = int(t.get("prompt_n") or u.get("prompt_tokens") or 0)
            pms = float(t.get("prompt_ms") or mur * 1000)
            tps = float(t.get("prompt_per_second") or (pn / (pms / 1000) if pms else 0))
            cache_n = int((u.get("prompt_tokens_details") or {}).get("cached_tokens") or t.get("cache_n") or 0)
            # Réponse « vide » = ni content ni reasoning_content : sur un modèle à
            # réflexion (LFM2.5, Muse, DeepSeek), les 8 tokens partent dans
            # reasoning_content et content reste vide, ce n'est pas un moteur muet
            # (mesuré le 22/09/2026 : 8 passes saines exclues à tort).
            contenu = ""
            try:
                m = d["choices"][0]["message"]
                contenu = ((m.get("content") or "") + (m.get("reasoning_content") or "")).strip()
            except (KeyError, IndexError, TypeError):
                pass
            sain = 1 if (cache_n == 0 and contenu and pn > 0) else 0
            note = "" if sain else ("  ⚠ %s" % ("cache %d tok" % cache_n if cache_n else "réponse vide"))
            print("%d\t%d\t%d\t%.0f\t%.0f\t%d\t%s%s" % (cible, passe, pn, pms, tps, cache_n, "oui" if sain else "non", note), flush=True)
            print("TSV\t%d\t%d\t%d\t%.0f\t%.1f\t%d\t%d" % (cible, passe, pn, pms, tps, cache_n, sain), flush=True)
    return rc


def bilan(lignes):
    par = {}
    ordre = []
    for l in lignes:
        l = l.rstrip("\n")
        if l.startswith("TSV\t"):
            l = l[4:]
        c = l.split("\t")
        if len(c) < 7:
            continue
        try:
            cible, pn, tps, sain = int(c[0]), int(c[2]), float(c[4]), int(c[6])
        except ValueError:
            continue
        if cible not in par:
            par[cible] = []
            ordre.append(cible)
        par[cible].append((pn, tps, sain))
    if not ordre:
        print("Aucune mesure.")
        return 1
    # Aligné ici plutôt que par `column -t` : sous une locale absente (ssh non
    # interactif) column abîme les accents.
    print("%-8s %14s %18s %14s" % ("cible", "prompt_n méd.", "prefill t/s méd.", "passes saines"))
    for cible in ordre:
        sains = [(pn, tps) for pn, tps, s in par[cible] if s]
        n, ns = len(par[cible]), len(sains)
        pn_med = _median([pn for pn, _ in sains]) if sains else 0
        tps_med = _median([tps for _, tps in sains]) if sains else 0
        flag = "" if ns == n else "  ⚠ %d exclue(s)" % (n - ns)
        print("%-8d %14.0f %18.0f %14s%s" % (cible, pn_med, tps_med, "%d/%d" % (ns, n), flag))
        print("MED=%d:%.0f:%.0f:%d/%d" % (cible, pn_med, tps_med, ns, n))
    return 0


def main():
    if len(sys.argv) < 2:
        print("Usage : bench_prefill.py mesure <url> <modèle> <passes> <tailles> <fichier>... | bilan", file=sys.stderr)
        return 2
    if sys.argv[1] == "bilan":
        return bilan(sys.stdin)
    if sys.argv[1] == "mesure" and len(sys.argv) >= 7:
        tailles = [int(x) for x in sys.argv[5].split(",") if x.strip()]
        return mesure(sys.argv[2].rstrip("/"), sys.argv[3], int(sys.argv[4]), tailles, sys.argv[6:])
    print("Usage : bench_prefill.py mesure <url> <modèle> <passes> <tailles> <fichier>... | bilan", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
