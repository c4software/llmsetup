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

# 4bis. --update-fork : commande de SUIVI, pas d'installation. Elle doit refuser
# tout de suite (avant tout git ou cmake) si le fork n'est pas cloné, ou si les
# liens de ~/.local/bin ne viennent pas de son build — sinon elle mettrait à
# jour un dépôt dont le moteur en place ne sort pas, sans que rien ne change.
# Ici $TMP/home/llm/strix-llama.cpp existe (build/bin peuplé) mais sans .git, et
# $TMP/home/.local/bin/llama-server est une COPIE, pas un lien vers le build :
# les deux refus sont donc atteints sans qu'aucun vrai git/cmake ne tourne.
out="$(_run_fork "cmd_update_fork" 2>&1)"; grc=$?
if [[ "$grc" -ne 0 && "$out" == *"--setup-fork d'abord"* ]]; then
  echo "[OK]   update-fork : pas de clone ⇒ refus, renvoi vers --setup-fork"
else
  echo "[FAIL] update-fork : pas de clone, code $grc, sortie : $out"; rc=1
fi

mkdir -p "$TMP/home/llm/strix-llama.cpp/.git"   # clone simulé, liens toujours faux
out="$(_run_fork "cmd_update_fork" 2>&1)"; grc=$?
if [[ "$grc" -ne 0 && "$out" == *"--setup-fork d'abord"* && "$out" == *"llama-bench"* ]]; then
  echo "[OK]   update-fork : liens hors du fork ⇒ refus nommant les binaires"
else
  echo "[FAIL] update-fork : liens hors du fork, code $grc, sortie : $out"; rc=1
fi
rmdir "$TMP/home/llm/strix-llama.cpp/.git"

# 4quater. --update-fork : changelog PUIS confirmation. Un bump de moteur casse
# la comparabilité de toutes les mesures qui suivent : la commande doit montrer
# ce qui change avant de tirer, et ne rien tirer sans accord. Testé sur un vrai
# petit dépôt git jetable (origine + clone + un commit d'avance), sans réseau ;
# FORK_SKIP_BUILD=1 (réservé aux tests) évite cmake et la pose des liens.
FH="$TMP/fhome"                       # HOME du test : le fork y est cloné
UP="$TMP/upstream"                    # "amont" du fork
FCLONE="$FH/llm/strix-llama.cpp"
mkdir -p "$FH/.local/bin" "$FH/llm"

_git() { git -c user.name=test -c user.email=test@example.invalid \
             -c init.defaultBranch=master -c commit.gpgsign=false "$@"; }

_git init -q "$UP"
echo un > "$UP/a.txt"
_git -C "$UP" add -A && _git -C "$UP" commit -qm "init : premier commit"
echo deux >> "$UP/a.txt"
_git -C "$UP" commit -qam "core : deuxieme commit, deja dans le clone"
_git clone -q "$UP" "$FCLONE"
echo trois >> "$UP/a.txt"
_git -C "$UP" commit -qam "vulkan : troisieme commit, celui du changelog"

# Faux build du fork + les quatre liens, sinon _fork_links_ok refuse tout de
# suite. build/ est exclu du git du clone (le .gitignore du vrai llama.cpp le
# fait aussi) : sans ça, _fork_pull verrait un arbre sale.
echo 'build/' > "$FCLONE/.git/info/exclude"
mkdir -p "$FCLONE/build/bin"
for b in llama-server llama-bench llama-cli llama-quantize; do
  cp "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$FCLONE/build/bin/$b"
  chmod +x "$FCLONE/build/bin/$b"
  ln -sfn "$FCLONE/build/bin/$b" "$FH/.local/bin/$b"
done

_head_clone() { git -C "$FCLONE" rev-parse --short HEAD; }
_run_upd() {  # $1 = env supplémentaire ; stdin fermé = entrée non interactive
  env -i HOME="$FH" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
      FORK_SKIP_BUILD=1 ${1:-} \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/fork.sh'
      cmd_update_fork" </dev/null 2>&1
}

avant_head="$(_head_clone)"
out="$(_run_upd)"; grc=$?
if [[ "$grc" -eq 0 && "$out" == *"troisieme commit, celui du changelog"* \
      && "$out" == *"FORK_UPDATE_YES=1"* && "$(_head_clone)" == "$avant_head" ]]; then
  echo "[OK]   update-fork : changelog affiché, rien tiré sans confirmation"
else
  echo "[FAIL] update-fork : sans confirmation, code $grc, HEAD $(_head_clone) (attendu $avant_head)"
  echo "$out" | sed 's/^/       /'; rc=1
fi

out="$(_run_upd FORK_UPDATE_YES=1)"; grc=$?
attendu="$(git -C "$UP" rev-parse --short HEAD)"
if [[ "$grc" -eq 0 && "$(_head_clone)" == "$attendu" ]]; then
  echo "[OK]   update-fork : FORK_UPDATE_YES=1 ⇒ pull effectué ($avant_head → $attendu)"
else
  echo "[FAIL] update-fork : FORK_UPDATE_YES=1, code $grc, HEAD $(_head_clone) (attendu $attendu)"
  echo "$out" | sed 's/^/       /'; rc=1
fi

out="$(_run_upd)"; grc=$?
if [[ "$grc" -eq 0 && "$out" == *"Rien de nouveau en amont"* ]]; then
  echo "[OK]   update-fork : clone à jour ⇒ rien de nouveau, aucun rebuild"
else
  echo "[FAIL] update-fork : clone à jour, code $grc, sortie : $out"; rc=1
fi

# 4ter. Garde mémoire _ensure_room_for (lib/common.sh) : avant de laisser le
# routeur charger un modèle, décharger les plus gros modèles chargés tant que
# `free` ne montre pas la place. Testée sur de faux `free` et `curl` et des
# GGUF creux (truncate) — aucun serveur, aucun modèle réel. Les tailles sont
# en Mio pour rester lisibles ; seuls les rapports comptent.
ROOM="$TMP/room"
mkdir -p "$ROOM/bin" "$ROOM/repo" "$ROOM/w"
truncate -s 100M "$ROOM/w/geant.gguf"
truncate -s 10M  "$ROOM/w/geant-draft.gguf"   # spec-draft-model : compte aussi
truncate -s 80M  "$ROOM/w/gros.gguf"
truncate -s 20M  "$ROOM/w/petit.gguf"
echo "petit-precharge" > "$ROOM/repo/preload.conf"

# Faux free : la colonne "available" est lue dans un fichier d'état que le faux
# curl met à jour à chaque déchargement (le noyau rend les pages).
cat > "$ROOM/bin/free" <<EOF
#!/usr/bin/env bash
echo "               total        used        free      shared  buff/cache   available"
echo "Mem: 1000000000 0 0 0 0 \$(cat "$ROOM/avail")"
EOF
# Faux curl : GET /models → liste des chargés ; POST /models/unload → retire le
# modèle de la liste, rend sa taille au "free" et journalise le déchargement.
cat > "$ROOM/bin/curl" <<EOF
#!/usr/bin/env bash
if [[ "\$*" == *"/models/unload"* ]]; then
  m="\$(printf '%s\n' "\$@" | sed -n 's/.*"model": *"\([^"]*\)".*/\1/p' | head -1)"
  echo "\$m" >> "$ROOM/unloaded"
  grep -vx "\$m" "$ROOM/loaded" > "$ROOM/l.tmp" || true
  mv "$ROOM/l.tmp" "$ROOM/loaded"
  a="\$(cat "$ROOM/avail")"; s="\$(cat "$ROOM/size.\$m" 2>/dev/null || echo 0)"
  echo \$(( a + s )) > "$ROOM/avail"
  echo '{"success":true}'
  exit 0
fi
python3 -c '
import json, sys
ids = [l.strip() for l in open(sys.argv[1]) if l.strip()]
print(json.dumps({"data": [{"id": i, "status": {"value": "loaded"}} for i in ids]}))
' "$ROOM/loaded"
EOF
chmod +x "$ROOM/bin/free" "$ROOM/bin/curl"
echo $(( 80 * 1024 * 1024 )) > "$ROOM/size.gros"
echo $(( 20 * 1024 * 1024 )) > "$ROOM/size.petit-precharge"

# Déclarations minimales : deux modèles chargés (un gros à la demande, un petit
# préchargé) et le géant à charger.
ROOM_DECL="
declare -A MODEL_INI
MODEL_INI[geant]='model = $ROOM/w/geant.gguf
spec-draft-model = $ROOM/w/geant-draft.gguf'
MODEL_INI[gros]='model = $ROOM/w/gros.gguf'
MODEL_INI[petit-precharge]='model = $ROOM/w/petit.gguf'
"
_run_room() {  # \$1 = octets disponibles au départ, \$2 = env supplémentaire
  printf 'gros\npetit-precharge\n' > "$ROOM/loaded"
  : > "$ROOM/unloaded"
  echo "$1" > "$ROOM/avail"
  env -i HOME="$TMP/home" PATH="$ROOM/bin:/usr/bin:/bin" SCRIPT_DIR="$ROOM/repo" ${2:-} \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/ini.sh'
      $ROOM_DECL
      BENCH_ROOM_TIMEOUT=1
      _ensure_room_for geant" >/dev/null 2>&1
  tr '\n' ' ' < "$ROOM/unloaded" | sed 's/ *$//'
}

# (a) place suffisante (500 Mio pour ~121 Mio estimés) : rien déchargé.
_ck "garde mémoire : place suffisante" "" "$(_run_room $(( 500 * 1024 * 1024 )))"
# (b) place insuffisante (50 Mio) : le plus gros NON préchargé part, et lui
#     seul — une fois 'gros' déchargé, les 130 Mio suffisent, le préchargé reste.
_ck "garde mémoire : le plus gros non préchargé" "gros" "$(_run_room $(( 50 * 1024 * 1024 )))"
# (c) BENCH_NO_UNLOAD=1 : garde désactivée, rien déchargé malgré le manque.
_ck "garde mémoire : BENCH_NO_UNLOAD=1" "" "$(_run_room $(( 50 * 1024 * 1024 )) BENCH_NO_UNLOAD=1)"

# 5. Étiquette utilisable en colonne TSV : ni espace, ni tabulation.
etiquette="$(_run '_llama_build')"
if [[ "$etiquette" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[OK]   étiquette sans espace ni tabulation"
else
  echo "[FAIL] étiquette impropre à une colonne TSV : '$etiquette'"; rc=1
fi

[[ "$rc" -eq 0 ]] && echo "── sh-unit : helpers de moteur, garde-fou moteur/ini, garde mémoire et --update-fork (refus, changelog, confirmation) conformes. ──"
exit "$rc"
