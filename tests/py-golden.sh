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
#  référence régénérée au passage au filler numéroté « [i] », 15/08/2026.)
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
python3 "$PY/timings.py" --spec "$(cat "$F/chat-spec.json")" 1 spec  > "$TMP/o" || true; _ck spec-p1.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-spec.json")" 2 spec  > "$TMP/o" || true; _ck spec-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-plain.json")" 2 ""   > "$TMP/o" || true; _ck spec-plain-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-plain.json")" 2 spec > "$TMP/o" || true; _ck spec-plain-spec-p2.txt "$TMP/o"
python3 "$PY/timings.py" --spec "$(cat "$F/chat-error.json")" 1 spec > "$TMP/o" || true; _ck spec-error.txt "$TMP/o"

# --- spec_server_nmax.py -----------------------------------------------------
python3 "$PY/spec_server_nmax.py" qwen3.8-27b-mtp-nothink < "$F/models.json" > "$TMP/o"; _ck nmax-found.txt "$TMP/o"
python3 "$PY/spec_server_nmax.py" qwen3.8-27b             < "$F/models.json" > "$TMP/o"; _ck nmax-noargs.txt "$TMP/o"
python3 "$PY/spec_server_nmax.py" inconnu                 < "$F/models.json" > "$TMP/o"; _ck nmax-absent.txt "$TMP/o"

# --- spec_analyze.py (cwd = tmp, chemins de log relatifs → sorties stables ;
#     copies des logs : la quarantaine réécrit le fichier) ---------------------
cp "$F/spec-tests.log" "$F/spec-tests-quarantine.log" "$TMP/"
(
  cd "$TMP"
  python3 "$PY/spec_analyze.py" spec-tests.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 6 rec > full.txt
  head -1 spec-tests.log > single.log
  python3 "$PY/spec_analyze.py" single.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 2 > single.txt
  python3 "$PY/spec_analyze.py" spec-tests-quarantine.log qwen3.8-27b-mtp-nothink Qwen3.8-27B-UD-Q4_K_XL.gguf ROCm0 6 rec > quarantine.txt
  python3 "$PY/spec_analyze.py" absent.log qwen3.8-27b-mtp-nothink x ROCm0 2 > empty.txt
)
_ck analyze-full.txt "$TMP/full.txt"
_ck analyze-single.txt "$TMP/single.txt"
_ck analyze-quarantine.txt "$TMP/quarantine.txt"
_ck analyze-quarantine-log.txt "$TMP/spec-tests-quarantine.log"
_ck analyze-empty.txt "$TMP/empty.txt"

# --- build_body.py : équivalence json.loads avec les bodies de référence -----
python3 "$PY/build_body.py" qwen3.8-27b-mtp-nothink 1500 43 "$PROMPTS/spec-test.txt" > "$TMP/body-spec.json"
python3 "$PY/build_body.py" qwen3.6-35b-a3b-nothink 1000 43 "$PROMPTS/bench-task.txt" \
  --filler-file "$PROMPTS/bench-filler.txt" --filler-repeat 400 > "$TMP/body-bench.json"
for b in body-spec body-bench; do
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
