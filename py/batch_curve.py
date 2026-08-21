#!/usr/bin/env python3
# Analyse d'une courbe t_forward(batch) mesurée par llama-bench, pour choisir
# la longueur de draft d'un décodage spéculatif n-gram.
#
# Un décodage spéculatif vérifie size_m tokens draftés dans UN forward de batch
# size_m + 1 (le token échantillonné + les draftés — per_seq = 1 + n_draft dans
# common/speculative.cpp). Le gain dépend donc entièrement de la forme de
# t_forward(batch), et cette forme n'est pas une pente lisse : ggml choisit son
# noyau selon la taille du batch, ce qui crée des MARCHES. Côté Vulkan,
# ggml-vulkan.cpp déclare `mul_mat_vec_max_cols = 8` et n'emprunte le noyau
# vectoriel que jusqu'à 8 colonnes ; au-delà il bascule sur le matmul général et
# son coût de mise en place (mesuré x2,12 sur un 27B dense, 21/08/2026). La
# dernière taille dans le chemin rapide est donc size_m = 7. C'est un seuil du
# BACKEND, pas du modèle. Les MoE passent par mul_mat_id (dispatch distinct) et
# ROCm/HIP a le sien — d'où la mesure, qui reste la référence.
#
# Conséquence contre-intuitive : les tailles juste AU-DESSUS d'une marche sont
# les pires du lot, puisqu'elles paient le coût fixe sans l'amortir. Deux
# régimes seulement ont du sens, et ce script sort les deux :
#   - SÛR   : la plus grande taille sous la première marche. Seuil de non-perte
#             minimal, gain plafonné.
#   - LARGE : la taille qui maximise le gain une fois le coût fixe amorti.
# Arbitrer entre les deux demande de connaître la distribution des longueurs de
# match sur l'usage réel : c'est la mesure empirique de --spec-ngram-tune, pas
# celle-ci.
#
# Usage :
#   batch_curve.py <modèle> <device> <depth> [tsv] [rec]   (jsonl sur stdin)
#     tsv : fichier où ajouter les mesures en colonnes ("" pour ne rien écrire)
#     rec : émet en plus les lignes machine consommées par le bash —
#           SIZEM_SAFE=, SIZEM_LARGE=, STEP_LO=, STEP_HI= (vides si non
#           déterminés). STEP_LO/HI encadrent la première marche, ou à défaut
#           le premier saut brut suspect entre deux batches non consécutifs :
#           c'est l'intervalle à raffiner pour la localiser au batch près.
import json, sys, datetime

# Marche = saut de coût par UNITÉ de batch. Normaliser est indispensable : entre
# deux points espacés (1 puis 8), la pente progressive d'un MoE — dont le trafic
# mémoire croît avec l'union des experts routés — double aussi le coût, sans
# qu'aucun noyau n'ait changé. Un vrai changement de noyau double d'un batch à
# l'autre : x2,12 par unité côté Vulkan, contre x1,11 par unité pour la pente
# MoE. Le seuil sépare largement les deux.
FACTEUR_MARCHE = 1.5
# Au-delà de cette part du draft, un seuil de non-perte devient risqué : une
# acceptance partielle passe sous la rentabilité.
PART_SEUIL_MAX = 0.25
# Une baisse de t_forward est physiquement impossible : en deçà de ce nombre
# d'écarts-types combinés c'est un plateau, au-delà un palier de noyau.
SIGMA_BAISSE = 3.0


def charger(flux):
    """jsonl de llama-bench → ([(batch, t_forward_s, ecart_type_s)], flash_attn).
    stddev_ts est en tokens/s : |dt/dts| = t/ts le ramène en secondes."""
    # dict par batch : deux balayages (grossier puis raffiné autour de la
    # marche) peuvent être concaténés, le plus récent fait foi.
    vus, fa = {}, set()
    for ligne in flux:
        ligne = ligne.strip()
        if not ligne.startswith("{"):
            continue
        try:
            r = json.loads(ligne)
        except ValueError:
            continue
        n, ts, sd = r.get("n_prompt", 0), r.get("avg_ts", 0.0), r.get("stddev_ts", 0.0)
        if not (n and ts):
            continue
        t = n / ts
        vus[n] = (t, (sd / ts) * t)
        fa.add(str(r.get("flash_attn", "?")))
    return ([(n, t, sd) for n, (t, sd) in sorted(vus.items())],
            ",".join(sorted(fa)))


def marches(pts, facteur=FACTEUR_MARCHE):
    """Sauts de coût entre deux batches consécutifs → [(bas, haut, facteur brut)].
    Le test porte sur le facteur PAR UNITÉ de batch (cf. FACTEUR_MARCHE)."""
    out = []
    for i in range(1, len(pts)):
        (b0, t0, _), (b1, t1, _) = pts[i-1], pts[i]
        if t0 <= 0 or b1 <= b0:
            continue
        brut = t1 / t0
        if brut ** (1.0 / (b1 - b0)) > facteur:
            out.append((b0, b1, brut))
    return out


def suspects(pts, facteur=FACTEUR_MARCHE):
    """Sauts bruts > facteur entre deux batches NON consécutifs, qui ne passent
    pas le test par unité → [(bas, haut, facteur brut)]. Une marche cachée
    entre deux points d'un balayage grossier (1,8,16,...) ressemble exactement
    à ça : x2,12 entre 8 et 9 noyé dans x2,33 entre 8 et 16, soit x1,11 par
    unité. Impossible de trancher sans point intermédiaire — c'est l'intervalle
    à raffiner. Une pente MoE lisse y passe aussi : le raffinement coûte un
    balayage et conclut alors « pas de marche », ce qui est le bon verdict."""
    out = []
    for i in range(1, len(pts)):
        (b0, t0, _), (b1, t1, _) = pts[i-1], pts[i]
        if t0 <= 0 or b1 - b0 <= 1:
            continue
        brut = t1 / t0
        if brut > facteur and brut ** (1.0 / (b1 - b0)) <= facteur:
            out.append((b0, b1, brut))
    return out


def baisses(pts, sigma=SIGMA_BAISSE):
    """Inversions réelles (au-delà du bruit combiné) → [(bas, haut)].
    En deçà du seuil c'est un plateau, pas une anomalie."""
    out = []
    for i in range(1, len(pts)):
        (b0, t0, s0), (b1, t1, s1) = pts[i-1], pts[i]
        if t1 < t0 and t0 - t1 > sigma * ((s0**2 + s1**2) ** 0.5):
            out.append((b0, b1))
    return out


def enveloppe(pts):
    """Enveloppe monotone croissante : un point anormalement bas ne doit pas
    gonfler le verdict."""
    out, plafond = [], 0.0
    for n, t, _ in pts:
        plafond = max(plafond, t)
        out.append((n, plafond))
    return out


def dominees(pts, t1):
    """Tailles battues par une plus courte sur les DEUX axes (gain et seuil) —
    typiquement celles qui suivent une marche."""
    out = []
    for i, (n, t, _) in enumerate(pts):
        if n <= 1:
            continue
        gain_n, seuil_n = n / (t / t1), t / t1
        for m, tm, _ in pts[:i]:
            if m > 1 and m / (tm / t1) >= gain_n and (tm / t1) <= seuil_n:
                out.append((n, m))
                break
    return out


def candidats(pts, t1):
    """(size_m sûr, size_m large) — None si non déterminé. Le sûr reste sous la
    première marche ; le large maximise le gain sous PART_SEUIL_MAX."""
    ms = marches(pts)
    # « sûr » = la plus grande taille sous la première marche ; sans marche, la
    # plus grande mesurée. Un size_m < 1 n'a pas de sens (rien à drafter).
    sur = (ms[0][0] - 1) if ms else (pts[-1][0] - 1 if len(pts) > 1 else None)
    if sur is not None and sur < 1:
        sur = None
    large, meilleur = None, 0.0
    for n, t in enveloppe(pts):
        if n <= 1:
            continue
        seuil = t / t1
        if seuil / n <= PART_SEUIL_MAX and n / seuil > meilleur:
            large, meilleur = n - 1, n / seuil
    return sur, large, meilleur, ms


def main():
    modele = sys.argv[1] if len(sys.argv) > 1 else "?"
    device = sys.argv[2] if len(sys.argv) > 2 else "?"
    depth = sys.argv[3] if len(sys.argv) > 3 else "?"
    tsv = sys.argv[4] if len(sys.argv) > 4 else ""
    rec = len(sys.argv) > 5 and sys.argv[5] == "rec"

    pts, fa = charger(sys.stdin)
    if not pts:
        print("  aucune mesure exploitable")
        if rec:
            print("SIZEM_SAFE="); print("SIZEM_LARGE=")
            print("STEP_LO="); print("STEP_HI=")
        return
    t1 = dict((n, t) for n, t, _ in pts).get(1) or pts[0][1]
    horodatage = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")

    print("  batch = size_m + 1 (le token échantillonné + les size_m draftés)")
    print("  %6s %7s %14s %10s %16s %8s"
          % ("batch", "size_m", "t_forward", "coût rel.", "seuil non-perte", "gain"))
    print("  " + "-" * 66)
    baisses_reelles = dict.fromkeys(b for _, b in baisses(pts))
    ecritures = []
    precedent = None
    for n, t, sd in pts:
        seuil, gain = t / t1, n / (t / t1)
        drapeau = ""
        if precedent is not None and t < precedent:
            drapeau = "  <-- BAISSE" if n in baisses_reelles else "  (plateau)"
        print("  %6d %7d %8.1f±%-4.1f ms %8.2fx %6.1f tok (%2.0f%%) %7.1fx%s"
              % (n, n - 1, t * 1000, sd * 1000, seuil, seuil,
                 100 * seuil / n, gain, drapeau))
        ecritures.append("%s\t%s\t%s\t%s\t%s\t%d\t%.2f\t%.2f\t%.4f\t%.3f"
                         % (horodatage, modele, device, depth, fa,
                            n, t * 1000, sd * 1000, seuil, gain))
        precedent = t
    print()
    print("  seuil non-perte = tokens à faire accepter pour ne pas être plus lent")
    print("                    que le décodage normal ; (%) = part du draft.")
    print()

    sur, large, gain_large, ms = candidats(pts, t1)

    if baisses(pts):
        print("  ⚠ courbe NON MONOTONE au-delà du bruit :")
        for a, b in baisses(pts):
            print("      entre batch %d et %d" % (a, b))
        print("    Un palier de noyau : le batch du haut emprunte un chemin plus")
        print("    rapide que celui du bas. La taille du bas est à ÉVITER.")
        print()

    if ms:
        print("  MARCHE(S) — coût fixe franchi entre deux tailles :")
        for a, b, f in ms:
            print("      entre batch %d et %d : x%.2f d'un coup" % (a, b, f))
        print()

    susp = suspects(pts)
    if susp:
        print("  SAUT(S) sans point intermédiaire — une marche peut s'y cacher :")
        for a, b, f in susp:
            print("      entre batch %d et %d : x%.2f (à raffiner batch par batch)" % (a, b, f))
        print()

    dom = dominees(pts, t1)
    if dom:
        print("  Tailles DOMINÉES (une plus courte fait mieux sur les deux axes) :")
        for n, m in dom:
            print("      size_m %d (batch %d) : size_m %d fait mieux en gain ET en seuil"
                  % (n - 1, n, m - 1))
        print()

    if sur is not None and large is not None and sur != large:
        seuil_sur = dict((n, t) for n, t, _ in pts)[sur + 1] / t1
        print("  DEUX RÉGIMES à départager par la mesure :")
        print("    size_m %-3d (SÛR)   seuil %.1f tok, gain plafonné x%.1f"
              % (sur, seuil_sur, (sur + 1) / seuil_sur))
        print("    size_m %-3d (LARGE) amortit le coût fixe, gain jusqu'à x%.1f"
              % (large, gain_large))
        print("    Le choix dépend de la longueur des répétitions réellement")
        print("    rencontrées — aucune courbe ne peut le dire.")
    elif large is not None:
        print("  VERDICT : --spec-ngram-map-k-size-m %d (gain max x%.1f si tout accepté)"
              % (large, gain_large))
    else:
        print("  VERDICT : aucune taille viable — courbe trop pentue,")
        print("            ne pas activer de spec-type n-gram sur ce modèle.")

    if pts[-1][1] / t1 >= 1.5:
        print("  Courbe pentue : ajouter --spec-ngram-map-k-min-hits 2 pour éviter")
        print("  les faux départs, qui paient le batch sans être acceptés.")

    if tsv and ecritures:
        try:
            with open(tsv, "a", encoding="utf-8") as fh:
                fh.write("\n".join(ecritures) + "\n")
        except OSError as e:
            print("  (TSV non écrit : %s)" % e)

    if rec:
        print("SIZEM_SAFE=%s" % ("" if sur is None else sur))
        print("SIZEM_LARGE=%s" % ("" if large is None else large))
        # intervalle à raffiner : la première marche si elle n'est pas encore
        # localisée au batch près, sinon le premier saut suspect
        etape = ms[0] if ms else (susp[0] if susp else None)
        print("STEP_LO=%s" % (etape[0] if etape else ""))
        print("STEP_HI=%s" % (etape[1] if etape else ""))


if __name__ == "__main__":
    main()
