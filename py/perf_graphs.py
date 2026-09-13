#!/usr/bin/env python3
# Trois SVG statiques versionnés à partir de docs/perfs.tsv, pour lire d'un
# coup d'oeil la comparaison paquet Arch contre fork strix-llama.cpp :
#   docs/graphs/prefill.svg   barres groupées paquet / fork, t/s
#   docs/graphs/decode.svg    idem sur le décode
#   docs/graphs/ecarts.svg    écart du fork en % du paquet, zéro au centre
#
# Rendu sobre : barres rectangulaires à remplissage plein, sans contour ni
# dégradé, grille verticale fine en gris clair, valeurs au bout des barres,
# légende à carrés de couleur, fond blanc. Aucun aléa : le tracé ne dépend que
# des chiffres du TSV, donc un régénéré ne produit un diff que si ces chiffres
# ont bougé.
#
# Contraintes GitHub (qui assainit les SVG des README) : pas de <script>, pas
# de <foreignObject>, pas de police ni d'image externe (la famille demandée a
# un repli Helvetica/Arial). XML écrit à la main, stdlib seule (csv).
# Vérification :
#   python3 -c 'import xml.dom.minidom,sys; xml.dom.minidom.parse(sys.argv[1])' \
#     docs/graphs/prefill.svg
#
# Usage : perf_graphs.py [<perfs.tsv> [<dossier de sortie>]]
# (défauts : docs/perfs.tsv et docs/graphs/, relatifs à la racine du dépôt,
#  déduite du chemin du script, pas du cwd.)
import csv
import os
import sys

LARGEUR = 900
MARGE_G = 258              # place des noms de sections, les plus longs du parc
MARGE_D = 74               # place des valeurs au bout des barres
HAUT_TITRE = 116           # titre + sous-titre sur deux lignes + légende
HAUT_AXE = 44              # graduations sous le cadre
H_BARRE = 16
ECART_BARRES = 5           # entre les deux barres d'un même modèle
ECART_GROUPES = 20         # entre deux modèles

POLICE = "Inter, Helvetica, Arial, sans-serif"
# Gris moyen pour le paquet, bleu pour le fork, rouge pour les écarts négatifs.
GRIS = "#9aa0a6"
BLEU = "#2f6fdd"
ROUGE = "#c0392b"
TEXTE = "#3c4043"          # gris foncé des libellés et des valeurs
TEXTE_FAIBLE = "#5f6368"   # sous-titre et étiquettes de graduation
GRILLE = "#e4e6e9"         # grille verticale
AXE = "#bdc1c6"            # ligne de base et axe du zéro


# --- XML minimal -------------------------------------------------------------

def esc(t):
    """Échappement du texte et des attributs (GitHub sert le SVG tel quel)."""
    return (str(t).replace("&", "&amp;").replace("<", "&lt;")
            .replace(">", "&gt;").replace('"', "&quot;"))


def texte(x, y, t, taille=12, couleur=TEXTE, ancre="start", graisse=None):
    poids = ' font-weight="%s"' % graisse if graisse else ""
    return ('<text x="%.1f" y="%.1f" font-family="%s" font-size="%d" '
            'fill="%s" text-anchor="%s"%s>%s</text>'
            % (x, y, esc(POLICE), taille, couleur, ancre, poids, esc(t)))


def ligne(x1, y1, x2, y2, couleur, epaisseur=1.0):
    return ('<line x1="%.1f" y1="%.1f" x2="%.1f" y2="%.1f" stroke="%s" '
            'stroke-width="%.1f"/>' % (x1, y1, x2, y2, couleur, epaisseur))


def barre(x0, x1, y0, y1, couleur):
    """Barre horizontale : un rectangle plein, coins droits, sans contour."""
    if x1 < x0:
        x0, x1 = x1, x0
    return ('<rect x="%.1f" y="%.1f" width="%.1f" height="%.1f" fill="%s"/>'
            % (x0, y0, max(0.0, x1 - x0), y1 - y0, couleur))


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

def _entete(titre, sous_titre, legende, largeur, hauteur):
    """Fond blanc, titre, sous-titre (une ou deux lignes) et légende à carrés."""
    out = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" '
           'viewBox="0 0 %d %d" role="img" aria-label="%s">'
           % (largeur, hauteur, largeur, hauteur, esc(titre)),
           '<rect x="0" y="0" width="%d" height="%d" fill="#ffffff"/>'
           % (largeur, hauteur),
           texte(24, 34, titre, taille=18, graisse="600")]
    for i, l in enumerate(str(sous_titre).split("\n")):
        out.append(texte(24, 56 + 16 * i, l, taille=12, couleur=TEXTE_FAIBLE))
    x = 24
    for libelle, couleur in legende:
        out.append('<rect x="%.1f" y="%.1f" width="11" height="11" '
                   'fill="%s"/>' % (x, 89, couleur))
        out.append(texte(x + 17, 98, libelle, taille=12))
        x += 24 + int(7.0 * len(libelle))
    return out


def _axe_vertical(out, x, y0, y1, valeurs, xs, unite=""):
    """Grille verticale fine et étiquettes des graduations sous le cadre."""
    for v, xv in zip(valeurs, xs):
        out.append(ligne(xv, y0, xv, y1, GRILLE))
        out.append(texte(xv, y1 + 18, nombre(v, unite), taille=11,
                         couleur=TEXTE_FAIBLE, ancre="middle"))
    out.append(ligne(x, y1, xs[-1] if xs else x, y1, AXE))


# --- graphes groupés (prefill, décode) ---------------------------------------

def graphe_groupe(rows, cle_paquet, cle_fork, titre, sous_titre, chemin,
                  forcer=None):
    h_groupe = 2 * H_BARRE + ECART_BARRES + ECART_GROUPES
    y_top = HAUT_TITRE
    hauteur = HAUT_TITRE + h_groupe * len(rows) + HAUT_AXE
    x0 = MARGE_G
    x_max = LARGEUR - MARGE_D
    vmax = max(max(r[cle_paquet], r[cle_fork]) for r in rows)
    ticks, haut = graduations(vmax)
    ech = (x_max - x0) / haut

    out = _entete(titre, sous_titre,
                  [("paquet Arch", GRIS), ("fork strix-llama.cpp", BLEU)],
                  LARGEUR, hauteur)
    y_bas = y_top + h_groupe * len(rows)
    _axe_vertical(out, x0, y_top - 6, y_bas,
                  ticks, [x0 + t * ech for t in ticks])

    for i, r in enumerate(rows):
        yg = y_top + i * h_groupe + ECART_GROUPES / 2
        out.append(texte(x0 - 12, yg + H_BARRE + 2, r["modele"], taille=12,
                         ancre="end"))
        for j, (cle, couleur) in enumerate(
                ((cle_paquet, GRIS), (cle_fork, BLEU))):
            y = yg + j * (H_BARRE + ECART_BARRES)
            x1 = x0 + r[cle] * ech
            out.append(barre(x0, x1, y, y + H_BARRE, couleur))
            out.append(texte(x1 + 8, y + H_BARRE - 3,
                             nombre(r[cle], forcer=forcer), taille=11))
    out.append("</svg>")
    ecrire(chemin, out)


# --- graphe des écarts -------------------------------------------------------

def ecart(paquet, fork):
    return (fork - paquet) / paquet * 100.0 if paquet else 0.0


def graphe_ecarts(rows, titre, sous_titre, chemin):
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

    out = _entete(titre, sous_titre,
                  [("prefill", BLEU), ("décode", GRIS), ("négatif", ROUGE)],
                  LARGEUR, hauteur)
    y_bas = y_top + h_groupe * len(rows)
    _axe_vertical(out, x0, y_top - 6, y_bas,
                  ticks, [x_zero + t * ech for t in ticks], unite=" %")
    # L'axe du zéro, plus appuyé que la grille.
    out.append(ligne(x_zero, y_top - 6, x_zero, y_bas, AXE, epaisseur=1.5))

    for i, (r, (e_pp, e_gen)) in enumerate(zip(rows, vals)):
        yg = y_top + i * h_groupe + ECART_GROUPES / 2
        out.append(texte(x0 - 12, yg + H_BARRE + 2, r["modele"], taille=12,
                         ancre="end"))
        for j, (v, couleur) in enumerate(((e_pp, BLEU), (e_gen, GRIS))):
            if v < 0:
                couleur = ROUGE
            y = yg + j * (H_BARRE + ECART_BARRES)
            x1 = x_zero + v * ech
            out.append(barre(x_zero, x1, y, y + H_BARRE, couleur))
            signe = "+" if v >= 0 else "-"
            etiq = signe + nombre(abs(v), " %")
            if v >= 0:
                out.append(texte(x1 + 8, y + H_BARRE - 3, etiq, taille=11))
            else:
                out.append(texte(x1 - 8, y + H_BARRE - 3, etiq, taille=11,
                                 ancre="end"))
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
    # Sous-titre commun, sur sa propre ligne : les deux séries ne partagent ni
    # le build ni le jour, la colonne source du TSV garde le détail ligne par
    # ligne.
    st = ("colonne paquet : dernier run bNNNNN du modèle ; colonne fork : "
          "strix-0007bc6, Vulkan0, --bench 3 passes, 12 et 13/09/2026")
    graphe_groupe(rows, "prefill_paquet", "prefill_fork",
                  "Prefill : paquet Arch contre fork",
                  "tokens/s du prompt, passe 1 à froid.\n" + st,
                  os.path.join(sortie, "prefill.svg"))
    graphe_groupe(rows, "decode_paquet", "decode_fork",
                  "Décode : paquet Arch contre fork",
                  "tokens/s générés, médiane hors 1re passe.\n" + st,
                  os.path.join(sortie, "decode.svg"), forcer=1)
    graphe_ecarts(rows, "Écart du fork, en % du paquet",
                  "positif = le fork gagne ; réglages parfois différents des "
                  "deux côtés,\ndeux séries non comparables à la décimale",
                  os.path.join(sortie, "ecarts.svg"))


if __name__ == "__main__":
    main(sys.argv)
