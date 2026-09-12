#!/usr/bin/env bash
# =============================================================================
# Test unitaire des helpers bash de lib/common.sh qui dépendent de
# l'ENVIRONNEMENT plutôt que d'une entrée : _llama_bin et _llama_build.
#
# Pourquoi : le 12/09/2026, deux lignes de logs/bench.log ont été étiquetées
# "b10809" (paquet Arch) pour des mesures faites par le fork strix-llama.cpp —
# la session ssh n'avait pas $HOME/.local/bin dans son PATH. La résolution du
# binaire et la forme de l'étiquette sont donc testées ici, sur des faux
# llama-server qui n'impriment qu'une ligne de --version.
#
# Lancement : ./tests/sh-unit.sh (aucune dépendance, aucun modèle, aucun réseau)
# =============================================================================
set -uo pipefail

TESTS_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$TESTS_DIR")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0

# Faux binaires : le fork ne numérote pas ses builds ("build 1"), le paquet
# Arch porte le numéro de build upstream.
mkdir -p "$TMP/home/.local/bin" "$TMP/home/llm/strix-llama.cpp/build/bin" "$TMP/bin"
cat > "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "version: 0.4.0-dev (build 1, commit 0007bc6)"
echo "built with GNU 16.2.1 for Linux x86_64"
EOF
cat > "$TMP/bin/llama-server" <<'EOF'
#!/usr/bin/env bash
echo "version: 0.4.0-dev (build 10809, commit 5266f24da7)"
echo "built with GNU 16.2.1 for Linux x86_64"
EOF
chmod +x "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/bin/llama-server"

# _llama_build dans un environnement maîtrisé : HOME et PATH bidons, et
# SCRIPT_DIR pointé sur un dossier jetable (common.sh crée son logs/).
_run() {
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
    bash -c "source '$REPO_DIR/lib/common.sh'; $1"
}

_ck() {  # $1 = libellé, $2 = attendu, $3 = obtenu
  if [[ "$2" == "$3" ]]; then
    echo "[OK]   $1 = $3"
  else
    echo "[FAIL] $1 : attendu '$2', obtenu '$3'"; rc=1
  fi
}

mkdir -p "$TMP/repo"

# 1. Fork lié dans ~/.local/bin : il prime, même si le PATH d'origine ne le
#    contient pas (c'est le cas de la session ssh qui a produit le défaut).
ln -sfn "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/home/.local/bin/llama-server"
_ck "fork : binaire résolu" "$TMP/home/.local/bin/llama-server" "$(_run '_llama_bin llama-server')"
_ck "fork : étiquette"      "strix-0007bc6"                     "$(_run '_llama_build')"

# 2. Sans lien : repli sur le PATH, étiquette bNNNNN inchangée (c'est elle qui
#    figure dans toutes les campagnes antérieures, à ne pas casser).
rm -f "$TMP/home/.local/bin/llama-server"
_ck "paquet : binaire résolu" "$TMP/bin/llama-server" "$(_run '_llama_bin llama-server')"
_ck "paquet : étiquette"      "b10809"                "$(_run '_llama_build')"

# 3. Dépôt au nom quelconque : le préfixe tombe sur le nom du dossier, et sur
#    "fork" si le binaire n'est pas dans un <dépôt>/build/bin.
mkdir -p "$TMP/home/llm/essai/build/bin"
cp "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/home/llm/essai/build/bin/llama-server"
ln -sfn "$TMP/home/llm/essai/build/bin/llama-server" "$TMP/home/.local/bin/llama-server"
_ck "autre dépôt : étiquette" "essai-0007bc6" "$(_run '_llama_build')"

rm -f "$TMP/home/.local/bin/llama-server"
cp "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/home/.local/bin/llama-server"
_ck "hors build/bin : étiquette" "fork-0007bc6" "$(_run '_llama_build')"

# 4. Garde-fou moteur/ini : _fork_keys_guard (lib/fork.sh) doit refuser un
#    moteur upstream sur un ini qui porte une clé propre au fork, et se taire
#    sur le fork. Sans lui, c'est llama-server qui échoue au démarrage, sur un
#    message qui ne nomme qu'une clé et pas le modèle.
_run_fork() {
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
    bash -c "source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/fork.sh'; $1"
}

cat > "$TMP/fork.ini" <<'EOF'
[*]
device = Vulkan0

[modele-fork]
model            = /x/y.gguf
ngram-on-disk    = true
EOF
cat > "$TMP/arch.ini" <<'EOF'
[*]
device = Vulkan0

[modele-arch]
model            = /x/y.gguf
spec-draft-n-min = 2
EOF

rm -f "$TMP/home/.local/bin/llama-server"   # moteur = paquet (b10809)
out="$(_run_fork "_fork_keys_guard '$TMP/fork.ini'" 2>&1)"; grc=$?
if [[ "$grc" -ne 0 && "$out" == *"ngram-on-disk"* && "$out" == *"modele-fork"* ]]; then
  echo "[OK]   garde : paquet + clé de fork ⇒ erreur nommant modèle et clé"
else
  echo "[FAIL] garde : paquet + clé de fork, code $grc, sortie : $out"; rc=1
fi

out="$(_run_fork "_fork_keys_guard '$TMP/arch.ini'" 2>&1)"; grc=$?
if [[ "$grc" -eq 0 ]]; then
  echo "[OK]   garde : paquet + ini sans clé de fork ⇒ démarrage laissé passer"
else
  echo "[FAIL] garde : paquet + ini propre refusé (code $grc) : $out"; rc=1
fi

ln -sfn "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/home/.local/bin/llama-server"
out="$(_run_fork "_fork_keys_guard '$TMP/fork.ini'" 2>&1)"; grc=$?
if [[ "$grc" -eq 0 ]]; then
  echo "[OK]   garde : fork + clé de fork ⇒ démarrage laissé passer"
else
  echo "[FAIL] garde : fork + clé de fork refusé (code $grc) : $out"; rc=1
fi
rm -f "$TMP/home/.local/bin/llama-server"
cp "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/home/.local/bin/llama-server"

# 5. Étiquette utilisable en colonne TSV : ni espace, ni tabulation.
etiquette="$(_run '_llama_build')"
if [[ "$etiquette" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[OK]   étiquette sans espace ni tabulation"
else
  echo "[FAIL] étiquette impropre à une colonne TSV : '$etiquette'"; rc=1
fi

[[ "$rc" -eq 0 ]] && echo "── sh-unit : helpers de moteur et garde-fou moteur/ini conformes. ──"
exit "$rc"
