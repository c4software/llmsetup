#!/usr/bin/env python3
# Analyse des runs journalisés (spec-tests.log) pour (modèle, gguf, device).
# Modèle : par forward, k tokens draftés, acceptés en séquence avec proba α par
# position (α^i) → tokens/forward T(k) = 1 + Σ_{i=1..k} α^i ; temps/forward
# t(k) = t_base + k·t_draft. α est ajusté sur le run courant (accepted/drafted),
# t_base/t_draft par régression sur les runs à n-max distincts. Prédit t/s pour
# k = 1..10, recommande l'argmax (à égalité <2 %, le k le plus petit — l'accep-
# tance chute sur du texte moins prévisible que le prompt de test, un draft
# court est plus robuste).
# Garde-fou : tokens/forward > k+1 = run incohérent (le serveur ne tournait pas
# à ce n-max : ini changé sans restart) → quarantaine automatique dans le log
# (ligne commentée ";", conservée pour trace), exclue de la calibration.
#
# Appelé par lib/spec.sh (_spec_analyze) :
#   spec_analyze.py <log> <modèle> <gguf> <device> <k courant> [rec]
# Sortie texte d'affichage ; ligne "REC=k" si "rec" demandé et >= 2 n-max
# mesurés (consommée par sed -n 's/^REC=//p' côté bash).
import sys, math


def load_runs(log, modèle, gguf, dev):
    """Lit le log TSV, filtre (modèle, gguf, device), écarte les runs en
    spec-type mixte, met en quarantaine les runs incohérents (réécrit le log).
    Retourne (runs valides, nombre de runs mixtes écartés)."""
    runs, lines, bad_idx, n_mixte = [], [], [], 0
    try:
        lines = open(log, encoding="utf-8").read().splitlines()
    except FileNotFoundError:
        pass
    for i, line in enumerate(lines):
        if line.startswith(";"): continue  # ligne mise en quarantaine
        f = line.split("\t")
        if len(f) < 10 or f[1] != modèle or f[2] != gguf or f[3] != dev: continue
        # 11e colonne = spec-type du run. Absente des lignes antérieures au
        # support des listes : à l'époque c'était forcément draft-mtp seul.
        spectype = f[10] if len(f) > 10 and f[10] else "draft-mtp"
        # Le modèle T(k) = 1 + Σα^i suppose un k CONSTANT à chaque forward. En
        # spec-type mixte un hit n-gram drafte jusqu'à size_m tokens, le k varie
        # d'un pas à l'autre, et draft_n/draft_n_accepted sont agrégés sur toutes
        # les implémentations (stats au niveau slot côté llama-server, cf.
        # server_slot_stats::to_json). α n'a alors plus de sens. Ces runs sont
        # écartés de la calibration — surtout PAS mis en quarantaine : ils sont
        # valides, simplement hors modèle. Sans ce filtre le garde-fou
        # tokens/forward > k+1 les prendrait tous pour des runs incohérents et
        # commenterait le log.
        if spectype != "draft-mtp":
            n_mixte += 1
            continue
        try:
            r = dict(k=int(f[4]), gen=float(f[5]), dn=int(f[7]), da=int(f[8]), pn=int(f[9]))
        except ValueError:
            continue
        # Cohérence : tokens/forward > k+1 = le serveur ne tournait pas à ce n-max
        # (ini changé sans restart, anciens runs) → quarantaine automatique (ligne
        # commentée ";" dans le log, conservée pour trace), exclue de la calibration.
        if r["pn"] / max(1, r["pn"] - r["da"]) > r["k"] + 1.05:
            bad_idx.append(i)
            continue
        runs.append(r)
    if bad_idx:
        for i in bad_idx:
            lines[i] = "; QUARANTAINE (tokens/forward > plafond, n-max réel différent) " + lines[i]
        try:
            open(log, "w", encoding="utf-8").write("\n".join(lines) + "\n")
            print(f"  ⚠ {len(bad_idx)} run(s) incohérent(s) mis en quarantaine dans {log} (lignes commentées) — ignorés.")
        except OSError:
            print(f"  ⚠ {len(bad_idx)} run(s) incohérent(s) ignorés (quarantaine impossible : {log} non inscriptible).")
    return runs, n_mixte


def fit_alpha(cur):
    """α : résout (Σ_{i=1..k} α^i)/k = accepted/drafted par bissection."""
    def acc_ratio(a, k): return sum(a**i for i in range(1, k+1)) / k
    target = cur["da"] / cur["dn"]
    lo, hi = 0.0, 1.0
    for _ in range(60):
        mid = (lo+hi)/2
        if acc_ratio(mid, cur["k"]) < target: lo = mid
        else: hi = mid
    return (lo+hi)/2, target


def fit_timing(pts):
    """Régression t_fwd(k) = t_base + t_draft·k, avec t_fwd = tokens/forward / t/s."""
    xs = [r["k"] for r in pts]
    ys = [(r["pn"] / max(1, r["pn"] - r["da"])) / r["gen"] for r in pts]
    n = len(xs); mx, my = sum(xs)/n, sum(ys)/n
    sxx = sum((x-mx)**2 for x in xs)
    t_draft = sum((x-mx)*(y-my) for x, y in zip(xs, ys)) / sxx if sxx else 0.0
    t_base = my - t_draft*mx
    return xs, t_base, t_draft


def predict(alpha, t_base, t_draft):
    """t/s prédit = T(k)/(t_base + k·t_draft) pour k = 1..10."""
    def T(k): return 1 + sum(alpha**i for i in range(1, k+1))
    return {k: T(k)/(t_base + t_draft*k) for k in range(1, 11)}


def recommend(pred, pts):
    """Reco modèle (sur la courbe prédite) et reco MESURÉE (sur les runs) :
    à <2 % du max, le plus petit k. Les mesures priment sur le modèle."""
    best_k = max(pred, key=pred.get)
    best = pred[best_k]
    # à <2 % du max, préférer le plus petit k
    rec = min(k for k, v in pred.items() if v >= best*0.98)
    best_meas = max(r["gen"] for r in pts)
    rec_meas = min(r["k"] for r in pts if r["gen"] >= best_meas*0.98)
    return rec, best_k, best, rec_meas, best_meas


def main():
    log, modèle, gguf, dev, cur_k = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], int(sys.argv[5])
    runs, n_mixte = load_runs(log, modèle, gguf, dev)
    if n_mixte:
        print(f"  {n_mixte} run(s) en spec-type mixte écarté(s) : k variable par forward,"
              " le modèle α ne s'applique pas (comparer les t/s bruts).")
    if not runs:
        print("  (aucun run exploitable journalisé)"); sys.exit(0)

    # un point par n-max : le plus récent
    by_k = {}
    for r in runs: by_k[r["k"]] = r
    cur = by_k.get(cur_k) or runs[-1]

    alpha, target = fit_alpha(cur)
    # tokens/forward mesurés = predicted / forwards, forwards = predicted - accepted
    tpf_meas = cur["pn"] / max(1, cur["pn"] - cur["da"])
    print(f"  run courant : n-max {cur['k']}  {cur['gen']:.2f} t/s  acceptance/token {target:.3f}"
          f"  → α≈{alpha:.3f}  tokens/forward {tpf_meas:.2f} (plafond {cur['k']+1})")

    pts = sorted(by_k.values(), key=lambda r: r["k"])
    if len(pts) < 2:
        nxt = cur["k"] + 2 if cur["k"] < 6 else max(1, cur["k"] - 2)
        print(f"  1 seul n-max journalisé — pas de calibration possible.")
        print(f"  → lancer un run à spec-draft-n-max = {nxt} pour calibrer et obtenir la courbe prédite.")
        sys.exit(0)

    xs, t_base, t_draft = fit_timing(pts)
    if t_base <= 0 or t_draft < 0:
        print(f"  calibration incohérente (t_base={t_base*1000:.0f} ms, t_draft={t_draft*1000:.1f} ms) — runs trop bruités ?"
              " Refaire un run propre (service fraîchement redémarré, machine au repos).")
        sys.exit(0)
    print(f"  calibration sur n-max {xs} : t_base≈{t_base*1000:.0f} ms/forward (≈{1/t_base:.1f} t/s sans spéculation),"
          f" t_draft≈{t_draft*1000:.1f} ms/token drafté")

    pred = predict(alpha, t_base, t_draft)
    rec, best_k, best, rec_meas, best_meas = recommend(pred, pts)
    line = "  prédiction  : " + "  ".join(f"k{k}={v:.1f}" for k, v in pred.items())
    print(line)
    meas = "  mesuré      : " + "  ".join(f"k{r['k']}={r['gen']:.1f}" for r in pts)
    print(meas)
    # Recommandation MESURÉE (sert à --spec-tune) : parmi les k réellement testés,
    # le plus petit à <2 % du meilleur mesuré — les mesures priment sur le modèle.
    print(f"  → mesuré : n-max {rec_meas} (meilleur {best_meas:.1f} t/s ; à <2 %, le plus petit k gagne)")
    if len(sys.argv) > 6 and sys.argv[6] == "rec" and len(pts) >= 2:
        print(f"REC={rec_meas}")
    gain = (pred[rec] / cur["gen"] - 1) * 100
    if rec == cur["k"]:
        print(f"  → modèle : n-max {cur['k']} est déjà l'optimum (max prédit {best:.1f} t/s à k{best_k}, écart <2 %).")
    elif gain < 3:
        print(f"  → modèle : n-max {rec} suggéré mais gain <3 % vs {cur['k']} : plateau atteint.")
    else:
        print(f"  → modèle : n-max {rec} suggéré (prédit {pred[rec]:.1f} t/s, +{gain:.0f} % vs {cur['k']}) — à confirmer par un run (--spec-tune l'inclura).")


if __name__ == "__main__":
    main()
