#!/usr/bin/env python3
# Parse le champ `timings` d'une réponse /v1/chat/completions de llama-server
# et produit la ligne d'affichage d'une passe + les valeurs machine consommées
# par le bash (sed -n 's/^PP=//p' etc.) — sorties au caractère près identiques
# aux anciens heredocs de _bench_one et cmd_spec_test.
#
# Usage :
#   timings.py --bench <json> <n° de passe>            → ligne + PP=/G=/A=
#     (+ PPCACHED=1 si cache_n > 0 en passe 1 : prefill contaminé, marqué "*"
#      dans le récap côté bash)
#   timings.py --spec  <json> <n° de passe> <flag>     → ligne + GEN=/ACC=/DN=
#     (flag = "spec" si le modèle est spéculatif : affiche "acceptance=n/a …"
#      quand draft_n est absent des timings ; "" sinon. "specmix" = spec-type
#      en liste : draft_n/draft_n_accepted sont alors agrégés sur TOUTES les
#      implémentations — les stats sont au niveau slot côté llama-server
#      (server_slot_stats::to_json), le détail par implémentation n'existe que
#      dans le log du serveur via common_speculative_print_stats().)
#
# Les deux branches sont les copies exactes des heredocs d'origine : sys.argv
# est décalé d'un cran (pop du mode) pour ne pas toucher aux indices.
import json, sys

mode = sys.argv.pop(1) if len(sys.argv) > 1 else ""

# Sortie dégénérée : un backend peut produire des tokens à toute vitesse sans
# rien dire ("Nous dev dev dev dev…" à 500 t/s sur DeepSeek V4 / ROCm0, b10433,
# 21/08/2026 : des opérateurs fusionnés renvoyés sur CPU, aucune erreur loggée).
# Les timings sont alors excellents et parfaitement faux : --bench-devices a
# couronné ce device. Trois signaux sur >= 40 mots générés, un seul suffit :
#   - le mot le plus fréquent fait > 40 % des mots (« dev » = 80 % dans le cas
#     réel ; dans du texte ou du code, le mot dominant reste < 10 %) ;
#   - moins de 8 % de mots distincts. Seuil abaissé de 15 à 8 % le 21/08 :
#     une vraie réponse de refactor (la même classe recopiée plusieurs fois,
#     ce que le prompt demande — fixture chat-refactor-legit.json) tombe à
#     14 % sans être dégénérée, et le charabia réel n'est de toute façon pas
#     attrapé par ce critère (16 à 17 % à cause des tokens collés) mais par
#     la répétition périodique ci-dessous ;
#   - plus de 40 % des caractères sont couverts par une répétition immédiate de
#     période 1 à 12 (« dev dev dev », « ponseponseponse », « èteèteète »,
#     « le le le ») — c'est le seul signal qui tient sur les 1000 tokens réels
#     (fixture chat-degen-rocm.json : 0,64, quand les critères par mots donnent
#     11 % de mot dominant et 16 % de distincts, dans la zone du texte normal).
#     Texte réel : 0,02 à 0,27, le pire étant un tableau ASCII indenté.
# (Un critère de compression zlib < 10 % a été essayé puis retiré : il ne
#  prenait aucun charabia réel que les autres ne prennent déjà, et il
#  signalait le code de refactor légitime à 9,5 %.)
# Signalé par DEGEN=1, à l'appelant d'exclure la passe.
def periodique(t, kmax=12):
    """Part des caractères couverts par une répétition immédiate de période 1..kmax."""
    n = len(t)
    couvert = bytearray(n)
    for k in range(1, kmax + 1):
        i = 0
        while i + 2 * k <= n:
            if t[i:i + k] == t[i + k:i + 2 * k]:
                couvert[i:i + 2 * k] = b"\x01" * (2 * k)
                i += k
            else:
                i += 1
    return sum(couvert) / max(1, n)


def degenere(d):
    try:
        m = d["choices"][0]["message"]
    except (KeyError, IndexError, TypeError):
        return False
    texte = (m.get("reasoning_content") or "") + " " + (m.get("content") or "")
    mots = texte.split()
    if len(mots) < 40:
        return False
    freq = {}
    for w in mots:
        freq[w] = freq.get(w, 0) + 1
    if max(freq.values()) / len(mots) > 0.40:
        return True
    if len(freq) / len(mots) < 0.08:
        return True
    return periodique(texte) > 0.40


if mode == "--bench":
    try:
        d = json.loads(sys.argv[1])
    except Exception:
        print(f"  passe {sys.argv[2]} : réponse illisible"); sys.exit(1)
    if "error" in d:
        e = d["error"]
        msg = e.get("message", e) if isinstance(e, dict) else e
        print(f"  passe {sys.argv[2]} : erreur serveur — {msg}"); sys.exit(1)
    t = d.get("timings") or {}
    pp, tg = t.get("prompt_per_second", 0), t.get("predicted_per_second", 0)
    pn, n = t.get("prompt_n", 0), t.get("predicted_n", 0)
    cached = t.get("cache_n", 0)
    dn, da = t.get("draft_n"), t.get("draft_n_accepted")
    acc = f"  acceptance={da/dn:.2f}" if dn else ""
    note = "" if sys.argv[2] == "1" else "  (prompt cache)"
    # cache_n en passe 1 : le prefill est partiellement servi depuis un état
    # antérieur (slot-prompt-similarity + cache-ram/checkpoints) → chiffre gonflé.
    # Seuil relatif (> 10 % du prompt) : un préambule de template partagé avec
    # la requête de contrôle de --bench-sanity (60 tokens sur 1368 sur gpt-oss,
    # template harmony) ne change pas le t/s et ne doit pas marquer la mesure.
    # Signalé (ligne + PPCACHED= pour le "*" du récap), jamais corrigé ici :
    # --bench reste une mesure passive du serveur tel qu'il tourne.
    part_cache = cached / (pn + cached) if (pn + cached) else 0.0
    contamine = sys.argv[2] == "1" and part_cache > 0.10
    warn = "  ⚠ prefill partiellement servi par le cache (%.0f %%)" % (100 * part_cache) if contamine else ""
    degen = degenere(d)
    if degen:
        warn += "  ⚠ SORTIE DÉGÉNÉRÉE (charabia répétitif) : mesure invalide"
    print(f"  passe {sys.argv[2]} : prefill={pp:.0f} t/s (n={pn}, cache={cached})  décode={tg:.2f} t/s (n={n}){acc}{note}{warn}")
    if degen:
        print("DEGEN=1")
    if sys.argv[2] == "1":
        print(f"PP={pp:.2f}")
        if contamine:
            print("PPCACHED=1")
    else:
        print(f"G={tg:.2f}")
    if dn:
        print(f"A={da/dn:.2f}")
elif mode == "--spec":
    try:
        d = json.loads(sys.argv[1])
    except Exception:
        print(f"passe {sys.argv[2]} : réponse illisible"); sys.exit(1)
    if "error" in d:
        print(f"passe {sys.argv[2]} : erreur serveur — {d['error']}"); sys.exit(1)
    t = d.get("timings") or {}
    pp, tg, n = t.get("prompt_per_second", 0), t.get("predicted_per_second", 0), t.get("predicted_n", 0)
    pn = t.get("prompt_n", 0)
    cached = t.get("cache_n", 0)
    dn, da = t.get("draft_n"), t.get("draft_n_accepted")
    if dn:
        acc = f"  acceptance={da/dn:.2f} ({da}/{dn})"
        if "mix" in sys.argv[3]:
            acc += " agrégée — détail par implémentation : journalctl"
    elif "spec" in sys.argv[3]:
        acc = "  acceptance=n/a (pas de draft_n dans timings : spéculation inactive ?)"
    else:
        acc = ""
    tag = "  (cache froid, à ignorer)" if sys.argv[2] == "1" else ""
    # prompt_n petit = prompt cache actif → prompt t/s non significatif (résidu + overhead)
    pptxt = f"prompt={pp:.0f} t/s (n={pn}, cache={cached})" if pn else f"prompt={pp:.0f} t/s"
    degen = degenere(d)
    if degen:
        tag += "  ⚠ SORTIE DÉGÉNÉRÉE (charabia répétitif) : mesure invalide"
    print(f"passe {sys.argv[2]} : {pptxt}  gen={tg:.2f} t/s  n={n}{acc}{tag}")
    if degen:
        print("DEGEN=1")
    print(f"GEN={tg:.2f}")
    if dn: print(f"ACC={da/dn:.3f}"); print(f"DN={dn} DA={da} PN={n}")
else:
    print(f"timings.py : mode inconnu '{mode}' (--bench|--spec)", file=sys.stderr)
    sys.exit(2)
