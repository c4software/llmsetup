#!/usr/bin/env python3
# Trois SVG statiques versionnés à partir de docs/perfs.tsv, pour lire d'un
# coup d'oeil la comparaison paquet Arch contre fork strix-llama.cpp :
#   docs/graphs/prefill.svg   barres groupées paquet / fork, t/s
#   docs/graphs/decode.svg    idem sur le décode
#   docs/graphs/ecarts.svg    écart du fork en % du paquet, zéro au centre
#
# Rendu « crayon » : chaque trait est une polyligne à segments courts dont les
# points sont décalés de 1 à 2 px, tracée deux fois (contour doublé), hachures
# diagonales clipées dans la barre, police manuscrite avec repli cursive. Le
# hasard est tiré d'un random.Random(GRAINE) et les figures sont dessinées
# toujours dans le même ordre : la sortie est reproductible, un régénéré ne
# produit un diff que si les chiffres du TSV ont bougé.
#
# Contraintes GitHub (qui assainit les SVG des README) : pas de <script>, pas
# de <foreignObject>, pas de police ni d'image externe. XML écrit à la main,
# stdlib seule (csv, random). Vérification :
#   python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])' \
#     docs/graphs/prefill.svg
#
# Usage : perf_graphs.py [<perfs.tsv> [<dossier de sortie>]]
# (défauts : docs/perfs.tsv et docs/graphs/, relatifs à la racine du dépôt,
#  déduite du chemin du script, pas du cwd.)
import csv
import os
import random
import sys

GRAINE = 20260913          # figée : changer la graine rejoue tout le rendu
LARGEUR = 900
MARGE_G = 258              # place des noms de sections, les plus longs du parc
MARGE_D = 74               # place des valeurs au bout des barres
HAUT_TITRE = 94            # titre + légende
HAUT_AXE = 44              # graduations sous le cadre
H_BARRE = 16
ECART_BARRES = 5           # entre les deux barres d'un même modèle
ECART_GROUPES = 20         # entre deux modèles

POLICE = "Comic Neue, Comic Sans MS, Segoe Print, Bradley Hand, cursive"
# Couleurs « crayon » : graphite pour le paquet, bleu de couleur pour le fork,
# rouge pour les écarts négatifs.
GRAPHITE = "#4a4a4a"
GRAPHITE_CLAIR = "#b9b9b9"
BLEU = "#2f6fb0"
BLEU_CLAIR = "#a9c8e6"
ROUGE = "#b2382f"
ROUGE_CLAIR = "#e3b0ab"
AXE = "#8a8a8a"


# --- XML minimal -------------------------------------------------------------

def esc(t):
    """Échappement du texte et des attributs (GitHub sert le SVG tel quel)."""
    return (str(t).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def texte(x, y, t, taille=12, couleur=GRAPHITE, ancre="start", opacite=0.9):
    return ('<text x="%.1f" y="%.1f" font-family="%s" font-size="%d" '
            'fill="%s" text-anchor="%s" opacity="%.2f">%s</text>'
            % (x, y, esc(POLICE), taille, couleur, ancre, opacite, esc(t)))


# --- traits tremblés ---------------------------------------------------------

def _jitter(rng):
    """Décalage d'un point : 1 à 2 px, d'un côté ou de l'autre."""
    return rng.uniform(1.0, 2.0) * rng.choice((-1.0, 1.0))


def densifie(points, pas=13.0):
    """Redécoupe une polyligne en segments d'au plus `pas` px."""
    sortie = [points[0]]
    for (x1, y1), (x2, y2) in zip(points, points[1:]):
        d = ((x2 - x1) ** 2 + (y2 - y1) ** 2) ** 0.5
        n = max(1, int(d / pas))
        for i in range(1, n + 1):
            sortie.append((x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n))
    return sortie


def tremble(points, rng, dx=0.0, dy=0.0):
    """Points densifiés puis décalés au hasard, translatés de (dx, dy)."""
    return [(x + dx + _jitter(rng), y + dy + _jitter(rng))
            for x, y in densifie(points)]


def _d(points):
    return " ".join("%.1f,%.1f" % p for p in points)


def trait(points, rng, couleur=GRAPHITE, epaisseur=1.6, opacite=0.8,
          passes=2, ferme=False):
    """Un trait crayonné : deux passes de contour légèrement décalées."""
    pts = list(points)
    if ferme and pts[0] != pts[-1]:
        pts.append(pts[0])
    out = []
    for i in range(passes):
        dx, dy = (0.0, 0.0) if i == 0 else (0.6, 0.5)
        out.append('<polyline points="%s" fill="none" stroke="%s" '
                   'stroke-width="%.1f" stroke-linecap="round" '
                   'stroke-linejoin="round" opacity="%.2f"/>'
                   % (_d(tremble(pts, rng, dx, dy)), couleur, epaisseur,
                      opacite))
    return out


def barre(x0, x1, y0, y1, rng, couleur, clair, cid):
    """Barre horizontale crayonnée : aplat pâle, hachures diagonales clipées
    dans la barre, puis le contour doublé."""
    if x1 < x0:
        x0, x1 = x1, x0
    coins = [(x0, y0), (x1, y0), (x1, y1), (x0, y1)]
    h = y1 - y0
    out = ['<polygon points="%s" fill="%s" stroke="none" opacity="0.55"/>'
           % (_d(tremble(coins + [coins[0]], rng)), clair)]
    # Hachures : le clip est un rectangle net, les lignes restent tremblées.
    out.append('<clipPath id="%s"><rect x="%.1f" y="%.1f" width="%.1f" '
               'height="%.1f"/></clipPath>' % (cid, x0, y0, max(0.1, x1 - x0), h))
    out.append('<g clip-path="url(#%s)">' % cid)
    k = 0.0
    while k < (x1 - x0) + h:
        # hachures : trop courtes pour être densifiées, seuls les bouts bougent
        out.append('<polyline points="%s" fill="none" stroke="%s" '
                   'stroke-width="1" stroke-linecap="round" opacity="0.42"/>'
                   % (_d([(x0 + k - h + _jitter(rng), y1 + _jitter(rng)),
                          (x0 + k + _jitter(rng), y0 + _jitter(rng))]), couleur))
        k += 8.0
    out.append("</g>")
    out += trait(coins, rng, couleur, epaisseur=1.7, opacite=0.8, ferme=True)
    return out


# --- lecture du TSV ----------------------------------------------------------

def lire(chemin):
    """Lignes du TSV, commentaires `#` ignorés. Les colonnes numériques vides
    (acceptance d'un modèle sans spéculation) deviennent None."""
    with open(chemin, encoding="utf-8") as f:
        lignes = [l for l in f if not l.startswith("#")]
    rows = []
    for r in csv.DictReader(lignes, delimiter="\t"):
        if not (r.get("modele") or "").strip():
            continue
        for c in ("prefill_paquet", "prefill_fork", "decode_paquet",
                  "decode_fork", "acceptance_paquet", "acceptance_fork"):
            v = (r.get(c) or "").strip()
            r[c] = float(v) if v else None
        rows.append(r)
    if not rows:
        raise SystemExit("perf_graphs : aucune ligne exploitable dans le TSV")
    return rows


def nombre(v, unite="", forcer=None):
    """Affichage français : virgule décimale. `forcer=1` garde la décimale même
    nulle (50,0 t/s de décode se lit comme les autres lignes de la colonne)."""
    if forcer == 1:
        t = ("%.1f" % v).replace(".", ",")
    elif abs(v - round(v)) < 1e-9:
        t = "%d" % round(v)
    else:
        t = ("%.1f" % v).replace(".", ",")
    return t + unite


def graduations(vmax, cibles=6):
    """Pas « rond » (1, 2, 2,5 ou 5 × 10^n) couvrant vmax en ~cibles crans."""
    if vmax <= 0:
        return [0.0], 1.0
    brut = vmax / cibles
    mag = 10.0 ** int(("%e" % brut).split("e")[1])
    for m in (1, 2, 2.5, 5, 10):
        pas = m * mag
        if brut <= pas:
            break
    haut = pas
    while haut < vmax:
        haut += pas
    n = int(round(haut / pas))
    return [i * pas for i in range(n + 1)], haut


# --- squelette commun --------------------------------------------------------

def _entete(rng, titre, sous_titre, legende, largeur, hauteur):
    """Fond blanc, titre, soulignement crayonné et légende à pastilles."""
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
           'viewBox="0 0 %d %d" role="img" aria-label="%s">'
           % (largeur, hauteur, largeur, hauteur, esc(titre)),
           '<rect x="0" y="0" width="%d" height="%d" fill="#ffffff"/>'
           % (largeur, hauteur),
           texte(24, 34, titre, taille=19, opacite=0.95),
           texte(24, 54, sous_titre, taille=11, couleur=AXE)]
    out += trait([(24, 41), (24 + min(560, 10 * len(titre)), 41)], rng,
                 GRAPHITE, epaisseur=1.4, opacite=0.55)
    x = 24
    for libelle, couleur, clair in legende:
        out += barre(x, x + 22, 64, 78, rng, couleur, clair,
                     "lg%d" % int(x))
        out.append(texte(x + 28, 76, libelle, taille=12, couleur=couleur))
        x += 34 + int(7.0 * len(libelle))
    return out


def _axe_vertical(out, rng, x, y0, y1, valeurs, xs, unite=""):
    """Graduations verticales (grille pâle) et leurs étiquettes sous le cadre."""
    for v, xv in zip(valeurs, xs):
        out += trait([(xv, y0), (xv, y1)], rng, GRAPHITE_CLAIR,
                     epaisseur=1.0, opacite=0.45, passes=1)
        out.append(texte(xv, y1 + 18, nombre(v, unite), taille=11,
                         couleur=AXE, ancre="middle"))
    out += trait([(x, y1), (xs[-1] if xs else x, y1)], rng, AXE,
                 epaisseur=1.4, opacite=0.7)


# --- graphes groupés (prefill, décode) ---------------------------------------

def graphe_groupe(rows, cle_paquet, cle_fork, titre, sous_titre, chemin,
                  forcer=None):
    rng = random.Random(GRAINE)
    h_groupe = 2 * H_BARRE + ECART_BARRES + ECART_GROUPES
    y_top = HAUT_TITRE
    hauteur = HAUT_TITRE + h_groupe * len(rows) + HAUT_AXE
    x0 = MARGE_G
    x_max = LARGEUR - MARGE_D
    vmax = max(max(r[cle_paquet], r[cle_fork]) for r in rows)
    ticks, haut = graduations(vmax)
    ech = (x_max - x0) / haut

    out = _entete(rng, titre, sous_titre,
                  [("paquet Arch", GRAPHITE, GRAPHITE_CLAIR),
                   ("fork strix-llama.cpp", BLEU, BLEU_CLAIR)],
                  LARGEUR, hauteur)
    y_bas = y_top + h_groupe * len(rows)
    _axe_vertical(out, rng, x0, y_top - 6, y_bas,
                  ticks, [x0 + t * ech for t in ticks])

    for i, r in enumerate(rows):
        yg = y_top + i * h_groupe + ECART_GROUPES / 2
        out.append(texte(x0 - 12, yg + H_BARRE + 2, r["modele"], taille=12,
                         ancre="end"))
        for j, (cle, couleur, clair) in enumerate(
                ((cle_paquet, GRAPHITE, GRAPHITE_CLAIR),
                 (cle_fork, BLEU, BLEU_CLAIR))):
            y = yg + j * (H_BARRE + ECART_BARRES)
            x1 = x0 + r[cle] * ech
            out += barre(x0, x1, y, y + H_BARRE, rng, couleur, clair,
                         "b%d%d" % (i, j))
            out.append(texte(x1 + 8, y + H_BARRE - 3,
                             nombre(r[cle], forcer=forcer),
                             taille=11, couleur=couleur))
    out.append("</svg>")
    ecrire(chemin, out)


# --- graphe des écarts -------------------------------------------------------

def ecart(paquet, fork):
    return (fork - paquet) / paquet * 100.0 if paquet else 0.0


def graphe_ecarts(rows, titre, sous_titre, chemin):
    rng = random.Random(GRAINE)
    h_groupe = 2 * H_BARRE + ECART_BARRES + ECART_GROUPES
    y_top = HAUT_TITRE
    hauteur = HAUT_TITRE + h_groupe * len(rows) + HAUT_AXE
    x0 = MARGE_G
    x_max = LARGEUR - MARGE_D
    vals = [(ecart(r["prefill_paquet"], r["prefill_fork"]),
             ecart(r["decode_paquet"], r["decode_fork"])) for r in rows]
    amax = max(max(abs(a), abs(b)) for a, b in vals)
    ticks, haut = graduations(amax)
    # Zéro au centre : l'échelle est symétrique, les crans se miroitent.
    ticks = [-t for t in reversed(ticks[1:])] + ticks
    x_zero = (x0 + x_max) / 2.0
    ech = (x_max - x_zero) / haut

    out = _entete(rng, titre, sous_titre,
                  [("prefill", BLEU, BLEU_CLAIR),
                   ("décode", GRAPHITE, GRAPHITE_CLAIR),
                   ("négatif", ROUGE, ROUGE_CLAIR)],
                  LARGEUR, hauteur)
    y_bas = y_top + h_groupe * len(rows)
    _axe_vertical(out, rng, x0, y_top - 6, y_bas,
                  ticks, [x_zero + t * ech for t in ticks], unite=" %")
    # L'axe du zéro, plus appuyé que la grille.
    out += trait([(x_zero, y_top - 6), (x_zero, y_bas)], rng, GRAPHITE,
                 epaisseur=1.5, opacite=0.7)

    for i, (r, (e_pp, e_gen)) in enumerate(zip(rows, vals)):
        yg = y_top + i * h_groupe + ECART_GROUPES / 2
        out.append(texte(x0 - 12, yg + H_BARRE + 2, r["modele"], taille=12,
                         ancre="end"))
        for j, (v, couleur, clair) in enumerate(
                ((e_pp, BLEU, BLEU_CLAIR), (e_gen, GRAPHITE, GRAPHITE_CLAIR))):
            if v < 0:
                couleur, clair = ROUGE, ROUGE_CLAIR
            y = yg + j * (H_BARRE + ECART_BARRES)
            x1 = x_zero + v * ech
            out += barre(x_zero, x1, y, y + H_BARRE, rng, couleur, clair,
                         "e%d%d" % (i, j))
            signe = "+" if v >= 0 else "-"
            etiq = signe + nombre(abs(v), " %")
            if v >= 0:
                out.append(texte(x1 + 8, y + H_BARRE - 3, etiq, taille=11,
                                 couleur=couleur))
            else:
                out.append(texte(x1 - 8, y + H_BARRE - 3, etiq, taille=11,
                                 couleur=couleur, ancre="end"))
    out.append("</svg>")
    ecrire(chemin, out)


def ecrire(chemin, morceaux):
    os.makedirs(os.path.dirname(os.path.abspath(chemin)), exist_ok=True)
    with open(chemin, "w", encoding="utf-8") as f:
        f.write("\n".join(morceaux) + "\n")
    print("écrit %s" % chemin)


def main(argv):
    racine = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    tsv = argv[1] if len(argv) > 1 else os.path.join(racine, "docs", "perfs.tsv")
    sortie = argv[2] if len(argv) > 2 else os.path.join(racine, "docs", "graphs")
    rows = lire(tsv)
    # Sous-titre commun : les deux séries ne partagent ni le build ni le jour,
    # la colonne source du TSV garde le détail ligne par ligne.
    st = ("colonne paquet : dernier run bNNNNN du modèle ; colonne fork : "
          "strix-0007bc6, Vulkan0, --bench 3 passes, 12 et 13/09/2026")
    graphe_groupe(rows, "prefill_paquet", "prefill_fork",
                  "Prefill : paquet Arch contre fork",
                  "tokens/s du prompt, passe 1 à froid. " + st,
                  os.path.join(sortie, "prefill.svg"))
    graphe_groupe(rows, "decode_paquet", "decode_fork",
                  "Décode : paquet Arch contre fork",
                  "tokens/s générés, médiane hors 1re passe. " + st,
                  os.path.join(sortie, "decode.svg"), forcer=1)
    graphe_ecarts(rows, "Écart du fork, en % du paquet",
                  "positif = le fork gagne ; réglages parfois différents "
                  "des deux côtés, deux séries non comparables à la décimale",
                  os.path.join(sortie, "ecarts.svg"))


if __name__ == "__main__":
    main(sys.argv)
