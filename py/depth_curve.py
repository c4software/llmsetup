#!/usr/bin/env python3
# Prefill et décode selon la profondeur de contexte déjà en KV, mesurés par
# llama-bench -d (tools/bench-depth.sh). Le bench du service prefill ~1500
# tokens ; en agentic le contexte réel est à 30 à 100k, et c'est là que
# l'attention pèse : le décode chute, le prefill aussi, et le classement
# ROCm0 / Vulkan0 peut s'inverser. Le verdict reprend le « tour simulé » de
# --bench-devices (PP tokens de prefill froid + GEN générés) à chaque
# profondeur, pour que les deux outils parlent la même langue.
#
# Usage : depth_curve.py <modèle> <device> <pp_profil> <gen_profil> [tsv] [rec]
#   (jsonl de llama-bench sur stdin ; une ligne par (n_depth, n_prompt|n_gen))
#   tsv : fichier où ajouter les mesures ("" pour ne rien écrire)
#   rec : émet TOUR_<depth>=<secondes> par profondeur (consommé par le bash
#         pour comparer les devices)
import json, sys, datetime


def charger(flux):
    """→ {depth: {"pp": (t/s, sd), "tg": (t/s, sd)}}, infos (type_k/v, fa)."""
    par = {}
    infos = set()
    for ligne in flux:
        ligne = ligne.strip()
        if not ligne.startswith("{"):
            continue
        try:
            r = json.loads(ligne)
        except ValueError:
            continue
        d = r.get("n_depth", r.get("depth", 0))
        ts, sd = r.get("avg_ts", 0.0), r.get("stddev_ts", 0.0)
        if not ts:
            continue
        if r.get("n_prompt", 0) and not r.get("n_gen", 0):
            par.setdefault(d, {})["pp"] = (ts, sd)
        elif r.get("n_gen", 0) and not r.get("n_prompt", 0):
            par.setdefault(d, {})["tg"] = (ts, sd)
        infos.add("%s/%s fa=%s" % (r.get("type_k", "?"), r.get("type_v", "?"), r.get("flash_attn", "?")))
    return par, ", ".join(sorted(infos))


def main():
    modele, device = sys.argv[1], sys.argv[2]
    prof_pp, prof_gen = float(sys.argv[3]), float(sys.argv[4])
    tsv = sys.argv[5] if len(sys.argv) > 5 else ""
    rec = len(sys.argv) > 6 and sys.argv[6] == "rec"
    par, infos = charger(sys.stdin)
    if not par:
        print("  aucune mesure exploitable")
        return
    print("  KV %s ; tour simulé = %d tokens de prefill froid + %d générés, à cette profondeur"
          % (infos, prof_pp, prof_gen))
    print("  %9s %14s %14s %11s %9s" % ("depth", "prefill t/s", "décode t/s", "tour (s)", "vs 0"))
    print("  " + "-" * 62)
    horodatage = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
    ecritures, tours = [], {}
    base = None
    for d in sorted(par):
        pp, tg = par[d].get("pp"), par[d].get("tg")
        if not (pp and tg):
            continue
        tour = prof_pp / pp[0] + prof_gen / tg[0]
        tours[d] = tour
        if base is None:
            base = tour
        print("  %9d %8.0f±%-4.0f %8.2f±%-4.2f %10.1f %8s"
              % (d, pp[0], pp[1], tg[0], tg[1], tour,
                 "" if d == min(par) else "x%.2f" % (tour / base)))
        ecritures.append("%s\t%s\t%s\t%d\t%.1f\t%.1f\t%.2f\t%.2f\t%.1f"
                         % (horodatage, modele, device, d, pp[0], pp[1], tg[0], tg[1], tour))
    if len(tours) >= 2:
        ds = sorted(tours)
        d0, dn = ds[0], ds[-1]
        pp0, ppn = par[d0]["pp"][0], par[dn]["pp"][0]
        tg0, tgn = par[d0]["tg"][0], par[dn]["tg"][0]
        print()
        print("  De %d à %d tokens de contexte : prefill %.0f → %.0f t/s (%+.0f %%), décode %.2f → %.2f t/s (%+.0f %%)."
              % (d0, dn, pp0, ppn, (ppn - pp0) / pp0 * 100, tg0, tgn, (tgn - tg0) / tg0 * 100))
        if tours[dn] / tours[d0] > 1.5:
            print("  Le tour d'usage s'allonge de plus de moitié en profondeur : c'est le")
            print("  régime agentic réel, le verdict device doit se lire à cette profondeur.")
    if tsv and ecritures:
        try:
            with open(tsv, "a", encoding="utf-8") as fh:
                fh.write("\n".join(ecritures) + "\n")
        except OSError as e:
            print("  (TSV non écrit : %s)" % e)
    if rec:
        for d in sorted(tours):
            print("TOUR_%d=%.1f" % (d, tours[d]))


if __name__ == "__main__":
    main()
