#!/usr/bin/env python3
# Compare le dernier run --bench de chaque modèle demandé au run précédent du
# même (modèle, GGUF, device) dans logs/bench.log, quelle que soit la version
# de llama.cpp : un écart de plus de SEUIL sur le prefill ou le décode est
# signalé, et le changement de build est rappelé, c'est le cas typique (une
# mise à jour du paquet qui fait perdre 10 % en silence).
#
# Usage : bench_compare.py <bench.log> <modèle> [<modèle>...]
# Colonnes du log (cf. _bench_one) :
#   date modèle gguf device build prefill décode acceptance passes prefill_cache ec_mode
# ec_mode (11e colonne, 16/09/2026) = mode d'alimentation de l'APU lu sur le
# contrôleur embarqué. Un run en "balanced" perd 10 à 13 % de décode (3 % sur un
# dense) : au-dessus du seuil de 5 %, donc de quoi inventer une régression à lui
# seul. La référence est donc cherchée d'abord parmi les runs du MÊME mode ; à
# défaut on garde le dernier run (même calcul) en disant que l'écart n'est pas
# comparable. Les lignes antérieures n'ont pas la colonne : mode "inconnu".
import sys

SEUIL = 0.05


def lire(log):
    runs = []
    try:
        lignes = open(log, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        return runs
    for l in lignes:
        f = l.split("\t")
        if len(f) < 9 or l.startswith(";"):
            continue
        try:
            runs.append(dict(date=f[0], modele=f[1], gguf=f[2], device=f[3], build=f[4],
                             pp=float(f[5]), gen=float(f[6]), acc=f[7], passes=f[8],
                             ppcache=(f[9] == "1") if len(f) > 9 else False,
                             ec=(f[10] if len(f) > 10 and f[10] else "inconnu")))
        except ValueError:
            continue
    return runs


def pct(a, b):
    return (b - a) / a * 100 if a else 0.0


def drapeau(p):
    if p <= -100 * SEUIL:
        return "  ⚠ RÉGRESSION"
    if p >= 100 * SEUIL:
        return "  ▲ gain"
    return ""


def main():
    log, modeles = sys.argv[1], sys.argv[2:]
    runs = lire(log)
    for m in modeles:
        miens = [r for r in runs if r["modele"] == m]
        if not miens:
            print("  %s : rien dans le journal (journal non inscriptible ?)" % m)
            continue
        cur = miens[-1]
        prev = [r for r in miens[:-1] if r["gguf"] == cur["gguf"] and r["device"] == cur["device"]]
        if not prev:
            print("  %s (%s, %s) : première mesure journalisée sur ce GGUF/device" % (m, cur["device"], cur["build"]))
            continue
        # Référence de même mode EC d'abord ; sinon le dernier run tout court,
        # avec la mention qui dit que l'écart ne se lit pas.
        meme_ec = [r for r in prev if r["ec"] == cur["ec"]]
        p = (meme_ec or prev)[-1]
        ec_note = "" if p["ec"] == cur["ec"] else \
            "  (mode EC différent : %s contre %s, écart non comparable)" % (cur["ec"], p["ec"])
        dpp, dgen = pct(p["pp"], cur["pp"]), pct(p["gen"], cur["gen"])
        build = "" if p["build"] == cur["build"] else "  (build %s → %s)" % (p["build"], cur["build"])
        note_pp = " (prefill contaminé par le cache, écart non significatif)" if (cur["ppcache"] or p["ppcache"]) else drapeau(dpp)
        print("  %s (%s) vs %s%s%s" % (m, cur["device"], p["date"], build, ec_note))
        print("    prefill %.0f → %.0f t/s (%+.1f %%)%s" % (p["pp"], cur["pp"], dpp, note_pp))
        print("    décode  %.2f → %.2f t/s (%+.1f %%)%s" % (p["gen"], cur["gen"], dgen, drapeau(dgen)))
        if p["acc"] != cur["acc"] and cur["acc"] != "-":
            print("    acceptance %s → %s" % (p["acc"], cur["acc"]))


if __name__ == "__main__":
    main()
