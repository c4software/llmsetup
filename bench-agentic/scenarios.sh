#!/bin/sh
# Les scénarios de --bench-agentic : une vraie boucle de tool calls (pi,
# API OpenAI de llama-server, en direct) sur le modèle MODEL. Repris des
# scénarios pi d'envTest (llm-proxy), avec la mesure en plus : pour chaque
# scénario, PASS/FAIL, temps mur, et le delta des compteurs
# /metrics?model= de llama-server (tokens de prompt, part servie du cache,
# tokens générés, prefill et décode t/s). Tout se passe dans /work du
# conteneur. Les lignes "TSV<tab>..." sont reprises par cmd_bench_agentic
# (lib/bench.sh) pour le journal logs/bench-agentic.log.
set -u
cd /work
fails=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fails=$((fails + 1)); }

# Compteurs cumulés de llama-server pour ce modèle :
#   prompt_tokens_total prompt_tokens_cached_total tokens_predicted_total
#   prompt_seconds_total tokens_predicted_seconds_total
snap() {
  curl -s "$SERVER_URL/metrics?model=$MODEL" | awk '
    /^llamacpp:prompt_tokens_total /{pt=$2} /^llamacpp:prompt_tokens_cached_total /{pc=$2}
    /^llamacpp:tokens_predicted_total /{gt=$2} /^llamacpp:prompt_seconds_total /{ps=$2}
    /^llamacpp:tokens_predicted_seconds_total /{gs=$2}
    END{printf "%s %s %s %s %s", pt+0, pc+0, gt+0, ps+0, gs+0}'
}
# mesure <nom> <verdict> <t0> <snap0> : imprime la ligne lisible et la ligne TSV
mesure() {
  nom="$1" verdict="$2" t0="$3"; shift 3
  t1=$(date +%s.%N); s1=$(snap)
  echo "$* $s1 $t0 $t1" | awk -v nom="$nom" -v v="$verdict" '{
    pt=$6-$1; pc=$7-$2; gt=$8-$3; ps=$9-$4; gs=$10-$5; mur=$12-$11
    part=(pt+pc)>0 ? 100*pc/(pt+pc) : 0
    pp=ps>0 ? pt/ps : 0; tg=gs>0 ? gt/gs : 0
    printf "  %.1f s mur, prompt %d tok (+%d du cache, %.0f %%), généré %d tok, prefill %.0f t/s, décode %.1f t/s\n", mur, pt, pc, part, gt, pp, tg
    printf "TSV\t%s\t%s\t%s\t%.1f\t%d\t%d\t%d\t%.0f\t%.1f\n", ENVIRON["PASSE"], nom, v, mur, pt, pc, gt, pp, tg }'
}
run() { pi -p --no-session --provider local --model "$MODEL" "$@" 2>&1 | tail -n 20; }

version=$(pi --version 2>/dev/null | head -1)
PASSES="${PASSES:-1}"
echo "════ pi $version → $SERVER_URL | modèle $MODEL | $PASSES passe(s) ════"
rm -rf /work/* 2>/dev/null

echo "0. Froid : première question de la conversation (prompt système de pi)"
PASSE=0; export PASSE
t0=$(date +%s.%N); s0=$(snap)
out=$(run "Réponds en un seul mot : quelle est la capitale de la France ?")
case "$out" in *Paris*) pass "$out"; v=PASS ;; *) fail "$out"; v=FAIL ;; esac
mesure froid $v "$t0" $s0

p=1
while [ "$p" -le "$PASSES" ]; do
PASSE=$p; export PASSE
echo
echo "──── passe $p/$PASSES ────"
rm -rf /work/* 2>/dev/null
echo "1. Réponse simple (sans outil)"
t0=$(date +%s.%N); s0=$(snap)
out=$(run "Réponds en un seul mot : quelle est la capitale de la France ?")
case "$out" in *Paris*) pass "$out"; v=PASS ;; *) fail "$out"; v=FAIL ;; esac
mesure simple $v "$t0" $s0

echo "2. Outils : write + bash + read"
rm -f hello.txt
t0=$(date +%s.%N); s0=$(snap)
out=$(run "Crée un fichier hello.txt contenant exactement le mot bonjour, affiche-le avec cat, puis relis-le avec l'outil read et confirme son contenu en une phrase.")
if [ "$(cat hello.txt 2>/dev/null | tr -d '[:space:]')" = "bonjour" ]; then pass "hello.txt = bonjour — $(echo "$out" | tail -n 1)"; v=PASS; else fail "hello.txt absent ou différent — $out"; v=FAIL; fi
mesure outils $v "$t0" $s0

echo "3. Outils : edit"
mkdir -p src && printf 'def add(a, b):\n    return a - b\n' > src/calc.py
t0=$(date +%s.%N); s0=$(snap)
out=$(run "Lis src/calc.py, corrige le bug évident avec l'outil edit, puis affiche le fichier corrigé avec cat.")
if grep -q 'return a + b' src/calc.py; then pass "src/calc.py corrigé — $(echo "$out" | tail -n 1)"; v=PASS; else fail "src/calc.py non corrigé — $out"; v=FAIL; fi
mesure edit $v "$t0" $s0

echo "4. Création de code : module Node + tests"
rm -rf stats && mkdir stats && cd stats
t0=$(date +%s.%N); s0=$(snap)
out=$(run "Crée un module CommonJS stats.js qui exporte mean(tableau) et median(tableau) (médiane correcte pour un nombre pair d'éléments), puis test.js qui les vérifie avec node:assert sur quatre cas, exécute node test.js jusqu'à ce qu'il passe.")
if node test.js >/dev/null 2>&1 && node -e 'const s=require("./stats");process.exit(s.median([1,2,3,4])===2.5?0:1)'; then pass "stats.js + test.js — $(echo "$out" | tail -n 1)"; v=PASS; else fail "$out"; v=FAIL; fi
cd /work
mesure creation $v "$t0" $s0

echo "5. Corriger un bug sans toucher au test"
rm -rf slug && mkdir slug && cd slug
cat > slugify.js <<'JS'
module.exports = function slugify(title) {
  return title.toLowerCase().replace(/ /g, "-");
};
JS
cat > slugify.test.js <<'JS'
const assert = require("node:assert");
const slugify = require("./slugify");
assert.strictEqual(slugify("Hello World"), "hello-world");
assert.strictEqual(slugify("  Déjà   vu ! "), "deja-vu");
assert.strictEqual(slugify("--a--b--"), "a-b");
console.log("ok");
JS
sum=$(cksum slugify.test.js)
t0=$(date +%s.%N); s0=$(snap)
out=$(run "Lance node slugify.test.js : il échoue. Corrige slugify.js (accents retirés, tout caractère non alphanumérique devient un tiret, tirets fusionnés et retirés aux extrémités) sans modifier slugify.test.js, et relance jusqu'à ce que ça passe.")
if [ "$(cksum slugify.test.js)" != "$sum" ]; then fail "test modifié — $out"; v=FAIL
elif node slugify.test.js >/dev/null 2>&1; then pass "slugify.js corrigé — $(echo "$out" | tail -n 1)"; v=PASS; else fail "$out"; v=FAIL; fi
cd /work
mesure bugfix $v "$t0" $s0

p=$((p + 1))
done

echo
echo "Résumé : $MODEL : $((5 * PASSES + 1 - fails))/$((5 * PASSES + 1)) (froid compris)"
[ "$fails" -eq 0 ] || exit 1
