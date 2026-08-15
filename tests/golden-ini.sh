#!/usr/bin/env bash
# =============================================================================
# Test golden du models.ini — le ini généré doit rester BYTE-IDENTIQUE aux
# références tests/fixtures/golden.ini (sans conf) et golden-overrides.ini
# (avec bench-devices.conf / spec-nmax.conf / preload.conf factices).
#
# À rejouer après toute modification de generate_models_ini, d'un preset ou du
# découpage en modules. Mise à jour VOLONTAIRE des références (jamais en
# silence) : ./tests/golden-ini.sh --update
#
# Principe : le script est copié dans un dossier temporaire (SCRIPT_DIR isolé,
# donc confs isolées), sourcé avec --help (le dispatch ne lance rien de
# dangereux), puis generate_models_ini est appelé directement — sans réseau,
# sans service, sans sudo. HOME est figé à /golden-home pour que les chemins
# de modèles embarqués dans le ini soient stables d'une machine à l'autre.
# =============================================================================
set -euo pipefail

TESTS_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$TESTS_DIR")"
FIX="$TESTS_DIR/fixtures"
UPDATE=0
[[ "${1:-}" == "--update" ]] && UPDATE=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

_setup_app() {  # $1 = dossier app isolé
  mkdir -p "$1"
  cp "$REPO_DIR/setup-llm.sh" "$1/"
  [[ -d "$REPO_DIR/lib" ]] && cp -r "$REPO_DIR/lib" "$1/"
  cat > "$1/runner.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "$(realpath "$0")")/setup-llm.sh" --help > /dev/null
generate_models_ini
EOF
  chmod +x "$1/runner.sh"
}

# --- Cas 1 : aucune conf (défauts du script) --------------------------------
_setup_app "$TMP/app1"
HOME="/golden-home" "$TMP/app1/runner.sh" > "$TMP/out1.ini"

# --- Cas 2 : surcharges factices (device, n-max, préchargement) -------------
_setup_app "$TMP/app2"
cat > "$TMP/app2/bench-devices.conf" <<'EOF'
; factice — couvre la surcharge device par preset (clé = dossier du GGUF)
qwen3-coder-next = ROCm0
qwen3.8-27b = ROCm0
EOF
cat > "$TMP/app2/spec-nmax.conf" <<'EOF'
; factice — couvre la substitution spec-draft-n-max par-dessus MODEL_INI
qwen3.8-27b-mtp-nothink = 6
qwen3.5-9b-mtp = 4
EOF
cat > "$TMP/app2/preload.conf" <<'EOF'
; factice — couvre load-on-startup piloté par preload.conf
qwen3.5-2b
gpt-oss
EOF
HOME="/golden-home" "$TMP/app2/runner.sh" > "$TMP/out2.ini"

# --- Comparaison / mise à jour ----------------------------------------------
if [[ "$UPDATE" -eq 1 ]]; then
  mkdir -p "$FIX"
  cp "$TMP/out1.ini" "$FIX/golden.ini"
  cp "$TMP/out2.ini" "$FIX/golden-overrides.ini"
  echo "[OK] Références mises à jour : $FIX/golden.ini, $FIX/golden-overrides.ini"
  exit 0
fi

rc=0
diff -u "$FIX/golden.ini" "$TMP/out1.ini" || { echo "[FAIL] golden.ini diverge"; rc=1; }
diff -u "$FIX/golden-overrides.ini" "$TMP/out2.ini" || { echo "[FAIL] golden-overrides.ini diverge"; rc=1; }
[[ "$rc" -eq 0 ]] && echo "[OK] models.ini byte-identique aux deux références."
exit "$rc"
