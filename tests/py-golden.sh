#!/usr/bin/env bash
# =============================================================================
# Test golden des scripts py/ — leurs sorties sur les fixtures doivent
# rester BYTE-IDENTIQUES aux références de tests/fixtures/expected/, capturées
# avec le code inline d'origine AVANT extraction.
#
# À rejouer après toute modification d'un py/*.py. Si la sortie change
# volontairement : mettre à jour la fixture attendue ET vérifier les sed/grep
# bash qui la consomment (PP=/G=/A=, GEN=/ACC=/DN=, REC=).
#
# Les bodies JSON de build_body.py sont comparés en ÉQUIVALENCE (json.loads),
# pas en octets : json.dumps et l'ancien printf ne sérialisent pas pareil,
# seul le contenu parsé (messages, seed, etc.) doit être identique.
# (body-spec.json = équivalent à l'ancien printf ; body-bench.json =
#  référence régénérée au passage au contexte réaliste bench-context.txt, 15/08/2026.)
# =============================================================================
set -euo pipefail

TESTS_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$TESTS_DIR")"
PY="$REPO_DIR/py"
PROMPTS="$REPO_DIR/prompts"
F="$TESTS_DIR/fixtures"
E="$F/expected"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0

_ck() {  # $1 = nom de la référence, $2 = fichier produit
  if diff -u "$E/$1" "$2" >"$TMP/diff" 2>&1; then
    echo "[OK]   $1"
  else
    echo "[FAIL] $1"; cat "$TMP/diff"; rc=1
  fi
}

# --- timings.py --------------------------------------------------------------
python3 "$PY/timings.py" --bench "$(cat "$F/chat-spec.json")" 1  > "$TMP/o" || true; _ck bench-p1.txt "$TMP/o"
python3 "$PY/timings.py" --bench "$(cat "$F/chat-spec.json")" 2  > "$TMP/o" || true; _ck bench-p2.txt "$TMP/o"
python3 "$PY/timings.py" --bench "$(cat "$F/chat-plain.json")" 1 > "$TMP/o" || true; _ck bench-plain-p1.txt "$TMP/o"
python3 "$PY/timings.py" --bench "$(cat "$F/chat-plain.json")" 2 > "$TMP/o" || true; _ck bench-plain-p2.txt "$TMP/o"
python3 "$PY/timings.py" --bench "$(cat "$F/chat-error.json")" 1 > "$TMP/o" || true; _ck bench-error.txt "$TMP/o"
# degen : charabia répétitif à 536 t/s (DeepSeek V4 sur ROCm0, 21/08/2026) —
# la ligne doit le signaler et émettre DEGEN=1, en bench comme en spec
python3 "$PY/timings.py" --bench "$(cat "$F/chat-degen.json")" 2 > "$TMP/o" || true; _ck bench-degen-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec  "$(cat "$F/chat-degen.json")" 2 "" > "$TMP/o" || true; _ck spec-degen-p2.txt "$TMP/o"
# degen-mix : même charabia ponctué de tokens collés (17 % de mots distincts,
# au-dessus du seuil) — c'est la part du mot dominant (80 %) qui doit le prendre
python3 "$PY/timings.py" --bench "$(cat "$F/chat-degen-mix.json")" 2 > "$TMP/o" || true; _ck bench-degen-mix-p2.txt "$TMP/o"
# degen-rocm : la VRAIE réponse de 1000 tokens (DeepSeek V4 / ROCm0, b10433,
# 21/08/2026) — les critères par mots n'y voient rien, seule la répétition
# périodique au niveau caractères (0,64) la prend
python3 "$PY/timings.py" --bench "$(cat "$F/chat-degen-rocm.json")" 1 > "$TMP/o" || true; _ck bench-degen-rocm-p1.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-spec.json")" 1 spec  > "$TMP/o" || true; _ck spec-p1.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-spec.json")" 2 spec  > "$TMP/o" || true; _ck spec-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-plain.json")" 2 ""   > "$TMP/o" || true; _ck spec-plain-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-plain.json")" 2 spec > "$TMP/o" || true; _ck spec-plain-spec-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-error.json")" 1 spec > "$TMP/o" || true; _ck spec-error.txt "$TMP/o"
# specmix = spec-type en liste : l'acceptance affichée est un agrégat des
# implémentations, la ligne doit le dire (les lignes machine GEN=/ACC=/DN=
# consommées par le bash restent identiques au cas "spec").
python3 "$PY/timings.py" --spec "$(cat "$F/chat-spec.json")" 2 specmix > "$TMP/o" || true; _ck spec-mix-p2.txt "$TMP/o"

# --- spec_server_nmax.py -----------------------------------------------------
python3 "$PY/spec_server_nmax.py" qwen3.8-27b-mtp-nothink < "$F/models.json" > "$TMP/o"; _ck nmax-found.txt "$TMP/o"
python3 "$PY/spec_server_nmax.py" qwen3.8-27b             < "$F/models.json" > "$TMP/o"; _ck nmax-noargs.txt "$TMP/o"
python3 "$PY/spec_server_nmax.py" inconnu                 < "$F/models.json" > "$TMP/o"; _ck nmax-absent.txt "$TMP/o"
# argv[2] = flag arbitraire : sert à lire le spec-type réel du serveur
python3 "$PY/spec_server_nmax.py" qwen3.8-27b-mtp-nothink --spec-type < "$F/models-mixte.json" > "$TMP/o"; _ck spectype-found.txt "$TMP/o"
python3 "$PY/spec_server_nmax.py" qwen3.8-27b-mtp-nothink --spec-type < "$F/models.json"       > "$TMP/o"; _ck spectype-absent.txt "$TMP/o"

# --- batch_curve.py (stdout déterministe : l'horodatage ne va que dans le TSV)
# marche  : vraie courbe Vulkan0 du 27B Q4, coupure de noyau entre 8 et 9
# plat    : dense borné bande passante, aucune marche → un seul candidat
# moe     : pente forte mais LISSE — ne doit PAS être prise pour une marche
# inverse : palier ROCm0 reproductible (batch 8 plus lent que 16)
# vide    : entrée illisible → pas de plantage, lignes machine vides
# grossiere : même courbe Vulkan0 que « marche » mais SANS le batch 9 (balayage
#           grossier 1,8,16,32,48) — la marche est invisible au test par unité,
#           le script doit rendre STEP_LO=8/STEP_HI=16 à raffiner, et non
#           conclure à un seul candidat (défaut mesuré le 21/08/2026)
for c in marche plat moe inverse vide grossiere; do
  python3 "$PY/batch_curve.py" m.gguf Vulkan0 0 "" rec < "$F/bench-$c.jsonl" > "$TMP/o"
  _ck "curve-$c.txt" "$TMP/o"
done

# --- spec_analyze.py (cwd = tmp, chemins de log relatifs → sorties stables ;
#     copies des logs : la quarantaine réécrit le fichier) ---------------------
cp "$F/spec-tests.log" "$F/spec-tests-quarantine.log" "$F/spec-tests-mixte.log" "$TMP/"
(
  cd "$TMP"
  python3 "$PY/spec_analyze.py" spec-tests.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 6 rec > full.txt
  head -1 spec-tests.log > single.log
  python3 "$PY/spec_analyze.py" single.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 2 > single.txt
  python3 "$PY/spec_analyze.py" spec-tests-quarantine.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 6 rec > quarantine.txt
  python3 "$PY/spec_analyze.py" absent.log qwen3.8-27b-mtp-nothink x ROCm0 2 > empty.txt
  # spec-type mixte : les runs à k variable sont ÉCARTÉS de la calibration et
  # surtout PAS mis en quarantaine — leurs tokens/forward dépassent
  # légitimement k+1 (un hit n-gram drafte plus que spec-draft-n-max). Le log
  # doit ressortir intact, d'où sa comparaison ci-dessous.
  python3 "$PY/spec_analyze.py" spec-tests-mixte.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 6 rec > mixte.txt
)
_ck analyze-full.txt "$TMP/full.txt"
_ck analyze-single.txt "$TMP/single.txt"
_ck analyze-quarantine.txt "$TMP/quarantine.txt"
_ck analyze-quarantine-log.txt "$TMP/spec-tests-quarantine.log"
_ck analyze-empty.txt "$TMP/empty.txt"
_ck analyze-mixte.txt "$TMP/mixte.txt"
_ck analyze-mixte-log.txt "$TMP/spec-tests-mixte.log"

# --- build_body.py : équivalence json.loads avec les bodies de référence -----
python3 "$PY/build_body.py" qwen3.8-27b-mtp-nothink 1500 43 "$PROMPTS/spec-test.txt" > "$TMP/body-spec.json"
python3 "$PY/build_body.py" qwen3.6-35b-a3b-nothink 1000 43 "$PROMPTS/bench-context.txt" "$PROMPTS/bench-task.txt" > "$TMP/body-bench.json"
# spec-refactor : prompt de l'arbitrage --spec-ngram-tune. La référence fige le
# prompt autant que le body — le modifier invalide les comparaisons avec les
# runs antérieurs de spec-tests.log (cf. AGENTS.md).
python3 "$PY/build_body.py" qwen3.8-27b-mtp-nothink 1500 43 "$PROMPTS/spec-refactor.txt" > "$TMP/body-refactor.json"
for b in body-spec body-bench body-refactor; do
  if python3 -c '
import json, sys
a, b = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
sys.exit(0 if a == b else 1)
' "$E/$b.json" "$TMP/$b.json"; then
    echo "[OK]   $b.json (équivalence json.loads)"
  else
    echo "[FAIL] $b.json : le body construit diverge de la référence printf"; rc=1
  fi
done

[[ "$rc" -eq 0 ]] && echo "── py-golden : tout est identique aux références. ──"
exit "$rc"
