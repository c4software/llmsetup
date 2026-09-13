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

# Trois dépôts, comme en vrai : l'amont llama.cpp (UPS, avec ses tags bNNNNN),
# le fork qui le suit (UP = "origin"), et le clone local (FCLONE). Le bump
# testé apporte UN commit propre au fork (le merge de sync) et UN commit
# d'amont : le changelog doit les compter séparément — mesuré le 13/09/2026 sur
# bigchuck, un bump réel valait 210 commits dont 209 d'amont.
UPS="$TMP/llamacpp"
_git init -q "$UPS"
echo un > "$UPS/a.txt"
_git -C "$UPS" add -A && _git -C "$UPS" commit -qm "llama.cpp : commit d'amont initial"
_git -C "$UPS" tag b10800

_git clone -q "$UPS" "$UP"
echo fork > "$UP/f.txt"
_git -C "$UP" add -A && _git -C "$UP" commit -qm "strix : reglage propre au fork, deja dans le clone"
_git clone -q "$UP" "$FCLONE"

echo deux >> "$UPS/a.txt"
_git -C "$UPS" commit -qam "vulkan : optimisation d'amont, pas un commit du fork"
_git -C "$UPS" tag b10810
_git -C "$UP" remote add ups "$UPS"
_git -C "$UP" fetch -q ups
_git -C "$UP" merge -q --no-ff ups/master -m "Merge pull request #47 : sync amont llama.cpp"

# Remote upstream déjà posé dans le clone : _fork_upstream_prep ne réécrit
# jamais un remote existant, c'est ce qui permet de le pointer ici sur le faux
# llama.cpp local plutôt que sur github.
_git -C "$FCLONE" remote add upstream "$UPS"

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
if [[ "$grc" -eq 0 && "$out" == *"Merge pull request #47"* \
      && "$out" == *"FORK_UPDATE_YES=1"* && "$(_head_clone)" == "$avant_head" ]]; then
  echo "[OK]   update-fork : changelog affiché, rien tiré sans confirmation"
else
  echo "[FAIL] update-fork : sans confirmation, code $grc, HEAD $(_head_clone) (attendu $avant_head)"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# Le tri : le commit propre au fork est listé, celui d'amont seulement compté.
if [[ "$out" == *"Commits propres au fork (1)"* \
      && "$out" == *"Commits llama.cpp amont intégrés : 1"* \
      && "$out" != *"optimisation d'amont"* ]]; then
  echo "[OK]   update-fork : changelog trié (1 commit propre listé, 1 d'amont compté)"
else
  echo "[FAIL] update-fork : tri fork/amont du changelog"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# Bornes de version d'amont, quand les tags bNNNNN sont atteignables.
if [[ "$out" == *"(amont : b10800 → b10810)"* ]]; then
  echo "[OK]   update-fork : bornes d'amont bNNNNN affichées"
else
  echo "[FAIL] update-fork : bornes d'amont absentes"
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

# 4quinquies. Proposition du fork en fin de --setup (_setup_propose_fork,
# lib/setup.sh). Isolée de cmd_setup exprès : celui-ci fait paru, hf et réseau,
# la proposition ne lit que l'état du disque. Deux cas contractuels — le fork
# déjà en place ne doit RIEN demander, et une entrée non interactive ne doit
# rien installer mais nommer --setup-fork. cmd_setup_fork est surchargée après
# le source (résolution à l'appel) pour tracer un appel sans rien construire.
SH="$TMP/shome"
mkdir -p "$SH/.local/bin" "$SH/llm/strix-llama.cpp/build/bin"
for b in llama-server llama-bench llama-cli llama-quantize; do
  cp "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$SH/llm/strix-llama.cpp/build/bin/$b"
  chmod +x "$SH/llm/strix-llama.cpp/build/bin/$b"
done

_run_propose() {  # stdin fermé = entrée non interactive
  env -i HOME="$SH" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/fork.sh'
      source '$REPO_DIR/lib/setup.sh'
      cmd_setup_fork() { echo 'APPEL cmd_setup_fork'; }
      _setup_propose_fork" </dev/null 2>&1
}

# (a) fork en place (étiquette strix-<commit> ET les quatre liens dans son
#     build) : aucune question, aucun appel, juste le rappel --update-fork.
for b in llama-server llama-bench llama-cli llama-quantize; do
  ln -sfn "$SH/llm/strix-llama.cpp/build/bin/$b" "$SH/.local/bin/$b"
done
out="$(_run_propose)"; grc=$?
if [[ "$grc" -eq 0 && "$out" == *"strix-0007bc6"* && "$out" == *"--update-fork"* \
      && "$out" != *"Installer le fork"* && "$out" != *"APPEL cmd_setup_fork"* ]]; then
  echo "[OK]   setup : fork en place ⇒ pas de question, rappel --update-fork"
else
  echo "[FAIL] setup : fork en place, code $grc, sortie : $out"; rc=1
fi

# (b) pas de fork (aucun lien, moteur = paquet b10809) en entrée non
#     interactive : rien n'est installé, --setup-fork est indiqué.
rm -f "$SH/.local/bin/llama-server" "$SH/.local/bin/llama-bench" \
      "$SH/.local/bin/llama-cli" "$SH/.local/bin/llama-quantize"
out="$(_run_propose)"; grc=$?
if [[ "$grc" -eq 0 && "$out" == *"./setup-llm.sh --setup-fork"* \
      && "$out" != *"APPEL cmd_setup_fork"* ]]; then
  echo "[OK]   setup : sans fork, non interactif ⇒ --setup-fork indiqué, rien lancé"
else
  echo "[FAIL] setup : sans fork non interactif, code $grc, sortie : $out"; rc=1
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

[[ "$rc" -eq 0 ]] && echo "── sh-unit : helpers de moteur, garde-fou moteur/ini, garde mémoire, --update-fork (refus, changelog, confirmation) et proposition du fork en fin de --setup conformes. ──"
exit "$rc"
