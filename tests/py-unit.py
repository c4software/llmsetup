#!/usr/bin/env python3
# =============================================================================
# Tests unitaires de py/spec_analyze.py (fit_alpha / fit_timing / predict /
# recommend), sur données synthétiques exactes — complètent tests/py-golden.sh
# qui ne vérifie que la sortie texte de bout en bout.
#
# python3 stdlib seule (unittest), pas de framework. Lancer :
#   python3 tests/py-unit.py
# =============================================================================
import sys, os, unittest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "py"))
import spec_analyze as sa


def T(alpha, k):
    """tokens/forward théorique : 1 + Σ_{i=1..k} α^i."""
    return 1 + sum(alpha**i for i in range(1, k + 1))


def run_synthetique(k, alpha, t_base, t_draft, forwards=400):
    """Construit un run cohérent avec le modèle exact, comme les données
    réelles : dn = k·forwards draftés, da acceptés (T(k)-1 par forward),
    pn = forwards + da, gen = tokens/forward mesurés / t_fwd."""
    da = round(forwards * (T(alpha, k) - 1))
    dn = k * forwards
    pn = forwards + da
    tpf_meas = pn / (pn - da)
    gen = tpf_meas / (t_base + t_draft * k)
    return dict(k=k, gen=gen, dn=dn, da=da, pn=pn)


class TestFitAlpha(unittest.TestCase):
    def test_retrouve_alpha_connu(self):
        # da/dn posé exactement à (Σ α^i)/k → la bissection doit retrouver α
        for alpha_vrai in (0.5, 0.75, 0.9):
            for k in (2, 4, 6):
                target = sum(alpha_vrai**i for i in range(1, k + 1)) / k
                cur = dict(k=k, dn=10**6, da=round(target * 10**6))
                alpha, tgt = sa.fit_alpha(cur)
                self.assertAlmostEqual(alpha, alpha_vrai, places=3,
                                       msg=f"α={alpha_vrai} k={k}")
                self.assertAlmostEqual(tgt, target, places=5)

    def test_bornes(self):
        # rien d'accepté → α≈0 ; tout accepté → α≈1
        a0, _ = sa.fit_alpha(dict(k=4, dn=1000, da=0))
        a1, _ = sa.fit_alpha(dict(k=4, dn=1000, da=1000))
        self.assertLess(a0, 0.001)
        self.assertGreater(a1, 0.999)


class TestFitTiming(unittest.TestCase):
    def test_regression_exacte(self):
        # points générés par t_fwd = t_base + k·t_draft → régression exacte
        t_base_vrai, t_draft_vrai, alpha = 0.050, 0.004, 0.8
        pts = []
        for k in (2, 4, 6):
            tpf = T(alpha, k)
            pn, forwards = 4000, round(4000 / tpf)
            da = pn - forwards
            gen = (pn / forwards) / (t_base_vrai + t_draft_vrai * k)
            pts.append(dict(k=k, gen=gen, pn=pn, da=da))
        xs, t_base, t_draft = sa.fit_timing(pts)
        self.assertEqual(xs, [2, 4, 6])
        self.assertAlmostEqual(t_base, t_base_vrai, places=4)
        self.assertAlmostEqual(t_draft, t_draft_vrai, places=5)

    def test_un_seul_point(self):
        # sxx = 0 → t_draft = 0, t_base = t_fwd du point (pas de division par 0)
        pts = [dict(k=4, gen=50.0, pn=2000, da=1000)]
        _, t_base, t_draft = sa.fit_timing(pts)
        self.assertEqual(t_draft, 0.0)
        self.assertAlmostEqual(t_base, 2.0 / 50.0, places=9)


class TestPredict(unittest.TestCase):
    def test_formule(self):
        alpha, t_base, t_draft = 0.8, 0.050, 0.004
        pred = sa.predict(alpha, t_base, t_draft)
        self.assertEqual(sorted(pred), list(range(1, 11)))
        for k in pred:
            self.assertAlmostEqual(pred[k], T(alpha, k) / (t_base + t_draft * k),
                                   places=9)

    def test_draft_gratuit_monotone(self):
        # t_draft = 0 : chaque token drafté est gratuit → t/s croît avec k
        pred = sa.predict(0.9, 0.050, 0.0)
        for k in range(1, 10):
            self.assertGreater(pred[k + 1], pred[k])


class TestRecommend(unittest.TestCase):
    def test_plus_petit_k_a_moins_de_2_pct(self):
        # k4 est le max prédit mais k2 est à <2 % → reco modèle = 2
        pred = {2: 99.0, 4: 100.0, 6: 90.0}
        pts = [dict(k=2, gen=95.0), dict(k=4, gen=96.0), dict(k=6, gen=88.0)]
        rec, best_k, best, rec_meas, best_meas = sa.recommend(pred, pts)
        self.assertEqual((rec, best_k, best), (2, 4, 100.0))
        # mesuré : 95 ≥ 96·0.98 → le plus petit k mesuré gagne aussi
        self.assertEqual((rec_meas, best_meas), (2, 96.0))

    def test_mesures_priment(self):
        # le modèle prédit k6, les mesures donnent k2 nettement devant :
        # la reco mesurée (celle que consomme --spec-tune via REC=) reste k2
        pred = {2: 80.0, 4: 90.0, 6: 100.0}
        pts = [dict(k=2, gen=100.0), dict(k=6, gen=70.0)]
        rec, best_k, _, rec_meas, best_meas = sa.recommend(pred, pts)
        self.assertEqual((rec, best_k), (6, 6))
        self.assertEqual((rec_meas, best_meas), (2, 100.0))

    def test_ecart_superieur_a_2_pct(self):
        # k4 seul dans la fenêtre des 2 % → pas de repli sur un k plus petit
        pred = {2: 90.0, 4: 100.0, 6: 95.0}
        pts = [dict(k=2, gen=90.0), dict(k=4, gen=100.0)]
        rec, _, _, rec_meas, _ = sa.recommend(pred, pts)
        self.assertEqual(rec, 4)
        self.assertEqual(rec_meas, 4)


class TestCoherenceModele(unittest.TestCase):
    def test_bout_en_bout_synthetique(self):
        # runs générés par le modèle exact → la chaîne α + timing + predict
        # doit reproduire les t/s d'origine
        alpha, t_base, t_draft = 0.8, 0.050, 0.004
        pts = []
        for k in (2, 4, 6):
            pts.append(run_synthetique(k, alpha, t_base, t_draft))
        a, _ = sa.fit_alpha(pts[-1])
        _, tb, td = sa.fit_timing(pts)
        pred = sa.predict(a, tb, td)
        for r in pts:
            # tolérance large : pn/da arrondis à l'entier dans le run synthétique
            self.assertAlmostEqual(pred[r["k"]], r["gen"], delta=r["gen"] * 0.02)


if __name__ == "__main__":
    unittest.main(verbosity=2)
