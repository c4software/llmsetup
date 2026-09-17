#!/usr/bin/env bash
# =============================================================================
# Test unitaire des helpers bash de lib/common.sh qui dépendent de
# l'ENVIRONNEMENT plutôt que d'une entrée : _llama_bin, _llama_build et
# _ec_power_mode (mode d'alimentation de l'APU lu sur le contrôleur embarqué).
#
# Pourquoi : le 12/09/2026, deux lignes de logs/bench.log ont été étiquetées
# "b10809" (paquet Arch) pour des mesures faites par le fork strix-llama.cpp —
# la session ssh n'avait pas $HOME/.local/bin dans son PATH. La résolution du
# binaire et la forme de l'étiquette sont donc testées ici, sur des faux
# llama-server qui n'impriment qu'une ligne de --version.
#
# S'y sont ajoutés depuis : le garde-fou moteur/ini et l'épinglage du fork
# (lib/fork.sh), la garde mémoire (lib/common.sh) et le moteur conteneurisé
# (lib/runtime.sh, sur un faux docker et un faux git ls-remote).
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
# 1bis. Clone approfondi : le fork affiche alors un vrai numéro ("build 2224",
#    arrivé le 13/09/2026 après --update-fork) ; l'étiquette reste celle du
#    commit, sinon _fork_keys_guard le prendrait pour un paquet upstream.
mkdir -p "$TMP/home/llm/strix-llama.cpp/build/bin"
cat > "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server.deep" <<'EOF2'
#!/usr/bin/env bash
echo "version: 0.4.0-dev (build 2224, commit 654803517)"
EOF2
chmod +x "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server.deep"
ln -sfn "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server.deep" "$TMP/home/.local/bin/llama-server"
_ck "fork approfondi : étiquette" "strix-6548035" "$(_run '_llama_build')"
ln -sfn "$TMP/home/llm/strix-llama.cpp/build/bin/llama-server" "$TMP/home/.local/bin/llama-server"

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

# 4sexies. Épinglage du moteur (--setup-fork <commit>, fork.conf). Un sync
# d'amont peut faire régresser un modèle (13/09/2026 : 6548035 / b10917 fait
# tomber pp7 de 69 à 58 t/s sur Qwen3.8-27B) : il faut revenir à un commit connu
# et Y RESTER, sans que --update-fork le fasse avancer au prochain passage.
# Même dépôt jetable que 4quater, toujours FORK_SKIP_BUILD=1 (ni cmake ni liens).
_run_fork_cmd() {  # $1 = appel bash ; stdin fermé = entrée non interactive
  env -i HOME="$FH" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
      FORK_SKIP_BUILD=1 \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/fork.sh'
      $1" </dev/null 2>&1
}

FORK_CONF_TEST="$TMP/repo/fork.conf"
premier="$(git -C "$FCLONE" rev-parse --short "$(git -C "$FCLONE" rev-list --max-parents=0 HEAD)")"
sommet="$(_head_clone)"

# (a) épinglage : HEAD détaché sur le commit demandé, fork.conf écrit avec la
#     raison. C'est le geste de secours, il doit marcher en une commande.
out="$(_run_fork_cmd "cmd_setup_fork '$premier' 'regression pp7 sur 27B'")"; grc=$?
if [[ "$grc" -eq 0 && "$(_head_clone)" == "$premier" ]] \
   && ! git -C "$FCLONE" symbolic-ref -q HEAD >/dev/null \
   && grep -q "^pin = $premier$" "$FORK_CONF_TEST" 2>/dev/null \
   && grep -q "^raison = regression pp7 sur 27B$" "$FORK_CONF_TEST"; then
  echo "[OK]   setup-fork <commit> : HEAD détaché sur $premier, fork.conf écrit"
else
  echo "[FAIL] setup-fork <commit> : code $grc, HEAD $(_head_clone) (attendu $premier)"
  echo "$out" | sed 's/^/       /'
  [[ -f "$FORK_CONF_TEST" ]] && sed 's/^/       conf: /' "$FORK_CONF_TEST"; rc=1
fi

# (b) --update-fork sur un moteur épinglé : il dit l'épinglage, montre quand
#     même ce qui attend en amont (c'est ainsi qu'on verra passer le correctif),
#     ne demande RIEN et ne bouge pas d'un commit.
out="$(_run_fork_cmd "cmd_update_fork")"; grc=$?
if [[ "$grc" -eq 0 && "$out" == *"épinglé sur $premier"* \
      && "$out" == *"regression pp7 sur 27B"* \
      && "$out" == *"Merge pull request #47"* \
      && "$out" == *"--setup-fork"* \
      && "$out" != *"FORK_UPDATE_YES"* \
      && "$(_head_clone)" == "$premier" ]]; then
  echo "[OK]   update-fork : épinglé ⇒ changelog affiché, aucune question, HEAD figé"
else
  echo "[FAIL] update-fork épinglé : code $grc, HEAD $(_head_clone) (attendu $premier)"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (c) --setup-fork sans argument : dépingle et revient au sommet de la branche.
out="$(_run_fork_cmd "cmd_setup_fork")"; grc=$?
if [[ "$grc" -eq 0 && "$(_head_clone)" == "$sommet" \
      && "$(git -C "$FCLONE" rev-parse --abbrev-ref HEAD)" == "master" ]] \
   && ! grep -q "^pin = " "$FORK_CONF_TEST"; then
  echo "[OK]   setup-fork sans argument : épinglage retiré, retour au sommet de master"
else
  echo "[FAIL] setup-fork sans argument : code $grc, HEAD $(_head_clone) (attendu $sommet)"
  echo "$out" | sed 's/^/       /'
  [[ -f "$FORK_CONF_TEST" ]] && sed 's/^/       conf: /' "$FORK_CONF_TEST"; rc=1
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

# 4bis. Mode d'alimentation de l'APU (_ec_power_mode) : lecture du sysfs, repli
#       sur "inconnu", et surtout JAMAIS d'échec : aucune mesure ne doit être
#       refusée parce que le contrôleur embarqué est muet.
_run_ec() {  # $1 = chemin de EC_POWER_MODE_FILE
  HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
    EC_POWER_MODE_FILE="$1" \
    bash -c "source '$REPO_DIR/lib/common.sh'; _ec_power_mode" 2>/dev/null
}
printf 'balanced\n' > "$TMP/ec-mode"
_ck "mode EC : lu dans le sysfs" "balanced" "$(_run_ec "$TMP/ec-mode")"
printf 'performance' > "$TMP/ec-mode"   # sans saut de ligne final
_ck "mode EC : sans saut de ligne"  "performance" "$(_run_ec "$TMP/ec-mode")"
: > "$TMP/ec-vide"
_ck "mode EC : fichier vide"        "inconnu"     "$(_run_ec "$TMP/ec-vide")"
_ck "mode EC : fichier absent"      "inconnu"     "$(_run_ec "$TMP/ec-absent")"
# set -e chez l'appelant : la fonction sort toujours en 0, même sans fichier.
if HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$TMP/repo" \
   EC_POWER_MODE_FILE="$TMP/ec-absent" \
   bash -c "set -euo pipefail; source '$REPO_DIR/lib/common.sh'; _ec_power_mode >/dev/null; echo suite" 2>/dev/null \
   | grep -q '^suite$'; then
  echo "[OK]   mode EC : ne tue pas un script sous set -e"
else
  echo "[FAIL] mode EC : la fonction a fait échouer l'appelant sous set -e"; rc=1
fi

# 6. Moteur conteneurisé (lib/runtime.sh). Ce qui est testé ici est ce qui, en
# cas de bug, casse SILENCIEUSEMENT : une image qui ne contient pas les
# révisions demandées (toutes les mesures suivantes seraient étiquetées à
# tort), un --image-update qui avancerait le moteur sans qu'on l'ait dit, et un
# ménage d'images qui déborderait sur les images des autres outils de la
# machine. Tout passe par un faux `docker` (petit magasin d'images sur disque)
# et un faux `git ls-remote` : aucun build, aucun réseau, aucun daemon.
IMG="$TMP/img"
mkdir -p "$IMG/bin" "$IMG/repo/runtime" "$IMG/store" "$IMG/store/dangling" "$IMG/store/nolabel"

cat > "$IMG/repo/runtime/image.conf" <<'EOF'
# commentaire, ligne ignorée
ENGINE_REPO=https://example.invalid/moteur.git
ENGINE_BRANCH=master
ENGINE_REV=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

ROCM_SYSTEMS_REPO=https://example.invalid/rocm.git
ROCM_SYSTEMS_BRANCH=ilintar-experiments
ROCM_SYSTEMS_REV=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

IMAGE_NAME=llm-rocm-strix
EOF
: > "$IMG/repo/runtime/Dockerfile.rocm-strix"

# Faux docker : magasin d'images en fichiers ($IMG/store/<nom>_<tag>), chaque
# fichier portant les révisions "compilées". `dangling/` = images sans tag qui
# portent notre label, `nolabel/` = une image sans tag d'un AUTRE outil, qui ne
# doit jamais être listée quand le filtre de label est présent — c'est ce qui
# fait échouer le test si le ménage oubliait le filtre.
cat > "$IMG/bin/docker" <<EOF
#!/usr/bin/env bash
S="$IMG/store"
EOF
cat >> "$IMG/bin/docker" <<'EOF'
_f() { echo "$S/${1//[:\/]/_}"; }
printf '%s\n' "$*" >> "$S/../docker.log"
case "$1" in
  build)
    # Révisions demandées, reprises telles quelles sauf si le test force un
    # écart (FAKE_BUILD_ENGINE) pour simuler un cache de couche menteur.
    e=""; r=""; t=""; prev=""
    for a in "$@"; do
      case "$prev" in
        --build-arg) case "$a" in ENGINE_REV=*) e="${a#*=}" ;; ROCM_SYSTEMS_REV=*) r="${a#*=}" ;; esac ;;
        -t) t="$a" ;;
      esac
      prev="$a"
    done
    [[ "${FAKE_BUILD_FAIL:-0}" == "1" ]] && exit 1
    printf 'engine=%s\nrocm=%s\n' "${FAKE_BUILD_ENGINE:-$e}" "${FAKE_BUILD_ROCM:-$r}" > "$(_f "$t")"
    exit 0 ;;
  tag)
    src="$(_f "$2")"; dst="$(_f "$3")"
    [[ -f "$src" ]] || exit 1
    # L'ancienne image du tag de destination perd son tag : elle devient une
    # image sans tag portant notre label, exactement comme docker le fait.
    [[ -f "$dst" ]] && mv "$dst" "$S/dangling/id$RANDOM$RANDOM"
    cp "$src" "$dst"; exit 0 ;;
  run)
    ref=""; mode=""
    for a in "$@"; do
      case "$a" in
        --entrypoint) mode="next" ;;
        *) if [[ "$mode" == "next" ]]; then mode="$a"; elif [[ -z "$ref" && "$a" == *:* && -f "$(_f "$a")" ]]; then ref="$a"; fi ;;
      esac
    done
    [[ -n "$ref" ]] || exit 1
    case "$mode" in
      cat)     sed -e 's/^engine=/llama_cpp=/' -e 's/^rocm=/rocm_systems=/' "$(_f "$ref")" ;;
      /bin/sh) [[ "${FAKE_BINS_MISSING:-0}" == "1" ]] && exit 1 ;;
    esac
    exit 0 ;;
  image)
    case "$2" in
      inspect)
        ref="$3"
        [[ -f "$(_f "$ref")" ]] || exit 1
        case "$*" in
          *Size*)   echo 8000000000 ;;
          *engine_rev*) sed -n 's/^engine=//p' "$(_f "$ref")" ;;
          *rocm_rev*)   sed -n 's/^rocm=//p'   "$(_f "$ref")" ;;
          *build_date*) echo "2026-09-18T00:00:00Z" ;;
        esac
        exit 0 ;;
      rm)
        for d in "$(_f "$3")" "$S/dangling/$3" "$S/nolabel/$3"; do
          [[ -f "$d" ]] && { rm -f "$d"; exit 0; }
        done
        exit 1 ;;
      ls)
        if [[ "$*" == *"label=llm-setup.engine_rev"* ]]; then
          ls "$S/dangling" 2>/dev/null
        else
          ls "$S/dangling" "$S/nolabel" 2>/dev/null
        fi
        exit 0 ;;
    esac
    exit 1 ;;
  system) printf 'TYPE\tTOTAL\tACTIVE\tSIZE\tRECLAIMABLE\nBuild Cache\t45\t0\t2.5GB\t2.5GB\n'; exit 0 ;;
esac
exit 1
EOF

# Faux git : seul ls-remote est utilisé par lib/runtime.sh. Le sommet de chaque
# branche est lu dans un fichier que le test réécrit — c'est lui qui joue « un
# commit est arrivé en amont ».
cat > "$IMG/bin/git" <<EOF
#!/usr/bin/env bash
if [[ "\$1" == "ls-remote" ]]; then
  case "\$2" in
    *moteur*) printf '%s\trefs/heads/master\n' "\$(cat "$IMG/head-engine")" ;;
    *rocm*)   printf '%s\trefs/heads/ilintar-experiments\n' "\$(cat "$IMG/head-rocm")" ;;
  esac
  exit 0
fi
exec /usr/bin/git "\$@"
EOF
chmod +x "$IMG/bin/docker" "$IMG/bin/git"
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$IMG/head-engine"
printf 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n' > "$IMG/head-rocm"

_run_img() {  # $1 = appel bash ; $2 = env supplémentaire ; stdin fermé = non interactif
  env -i HOME="$TMP/home" PATH="$IMG/bin:/usr/bin:/bin" SCRIPT_DIR="$IMG/repo" ${2:-} \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/runtime.sh'
      $1" </dev/null 2>&1
}

# (a) Lecture de image.conf : les sept clés, commentaires et lignes vides
#     ignorés. C'est le fichier qui décide de ce qu'on compile.
_ck "image.conf : ENGINE_REV" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
    "$(_run_img '_image_read_conf; echo "$ENGINE_REV"')"
_ck "image.conf : ROCM_SYSTEMS_BRANCH" "ilintar-experiments" \
    "$(_run_img '_image_read_conf; echo "$ROCM_SYSTEMS_BRANCH"')"
_ck "image.conf : IMAGE_NAME" "llm-rocm-strix" \
    "$(_run_img '_image_read_conf; echo "$IMAGE_NAME"')"

# (b) Une clé inconnue est une faute de frappe qui, tolérée, ferait construire
#     la branche au lieu de la révision : refus explicite, pas un silence.
out="$(_run_img '_image_read_conf' "" )"
printf 'ENGINE_REVISION=zz\n' >> "$IMG/repo/runtime/image.conf"
out="$(_run_img '_image_read_conf')"; grc=$?
if [[ "$grc" -ne 0 && "$out" == *"ENGINE_REVISION"* ]]; then
  echo "[OK]   image.conf : clé inconnue ⇒ refus nommant la clé"
else
  echo "[FAIL] image.conf : clé inconnue acceptée, code $grc, sortie : $out"; rc=1
fi
sed -i '/^ENGINE_REVISION=/d' "$IMG/repo/runtime/image.conf"

# (c) Tag et référence. Un seul tag depuis le 17/09/2026 : la référence de
#     l'image courante ne dépend plus d'un tri, mais l'absence d'image doit
#     rester distinguable (code 1, rien sur la sortie).
_ck "tag de l'image" "latest" "$(_run_img '_image_read_conf; _image_tag')"
_ck "image absente : rien" "absente" \
    "$(_run_img '_image_read_conf; _image_ref || echo absente')"

# (d) --image-update sans confirmation. Un bump d'image ouvre une série de
#     mesures à part : en entrée non interactive, la commande doit MONTRER
#     l'écart et ne toucher ni image.conf ni docker.
printf 'cccccccccccccccccccccccccccccccccccccccc\n' > "$IMG/head-engine"
: > "$IMG/docker.log"
avant="$(md5sum < "$IMG/repo/runtime/image.conf")"
out="$(_run_img 'cmd_image_update')"; grc=$?
grep -q '^build' "$IMG/docker.log" && batie=1 || batie=0
if [[ "$grc" -eq 0 && "$out" == *"aaaaaaa → ccccccc"* && "$out" == *"IMAGE_UPDATE_YES=1"* \
      && "$(md5sum < "$IMG/repo/runtime/image.conf")" == "$avant" && "$batie" -eq 0 ]]; then
  echo "[OK]   image-update : écart montré, image.conf intact, aucun build"
else
  echo "[FAIL] image-update sans confirmation : code $grc"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (e) Rien de nouveau en amont ⇒ aucun build non plus (le cas courant).
printf 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n' > "$IMG/head-engine"
: > "$IMG/docker.log"
out="$(_run_img 'cmd_image_update')"; grc=$?
grep -q '^build' "$IMG/docker.log" && batie=1 || batie=0
if [[ "$grc" -eq 0 && "$out" == *"Rien de nouveau en amont"* && "$batie" -eq 0 ]]; then
  echo "[OK]   image-update : amonts à jour ⇒ rien à faire"
else
  echo "[FAIL] image-update à jour : code $grc, sortie : $out"; rc=1
fi

# (f) Build nominal : construction sous le tag TEMPORAIRE, vérification, puis
#     promotion en :latest et ménage. Une image d'un autre outil, sans tag et
#     sans notre label, doit survivre — c'est la garantie qu'on ne fait jamais
#     de prune global.
echo "vieille" > "$IMG/store/nolabel/id-autre-outil"
out="$(_run_img 'cmd_image_build')"; grc=$?
if [[ "$grc" -eq 0 && -f "$IMG/store/llm-rocm-strix_latest" \
      && ! -f "$IMG/store/llm-rocm-strix_build" \
      && -f "$IMG/store/nolabel/id-autre-outil" ]]; then
  echo "[OK]   image-build : promu en :latest, tag temporaire retiré, image tierce intacte"
else
  echo "[FAIL] image-build nominal : code $grc"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (g) Ménage : le second build réussi doit supprimer l'image que le nouveau
#     :latest vient de remplacer (sans tag, avec notre label) et laisser
#     l'autre tranquille.
out="$(_run_img 'cmd_image_build')"; grc=$?
if [[ "$grc" -eq 0 && -z "$(ls "$IMG/store/dangling" 2>/dev/null)" \
      && -f "$IMG/store/nolabel/id-autre-outil" ]]; then
  echo "[OK]   image-build : ancienne image sans tag purgée, image tierce intacte"
else
  echo "[FAIL] image-build ménage : code $grc, dangling : $(ls "$IMG/store/dangling" 2>/dev/null)"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (h) LE test qui compte : versions.txt ne correspond PAS aux révisions
#     demandées (cache de couche, branche réécrite, build-arg perdu). Il faut
#     un refus qui NOMME les deux révisions, un :latest laissé intact et le tag
#     temporaire retiré — sinon on mesurerait pendant des jours un moteur qui
#     n'est pas celui que le dépôt annonce.
ref_avant="$(cat "$IMG/store/llm-rocm-strix_latest")"
out="$(_run_img 'cmd_image_build' 'FAKE_BUILD_ENGINE=dddddddddddddddddddddddddddddddddddddddd')"; grc=$?
if [[ "$grc" -ne 0 && "$out" == *"aaaaaaaaaa"* && "$out" == *"dddddddd"* \
      && "$(cat "$IMG/store/llm-rocm-strix_latest")" == "$ref_avant" \
      && ! -f "$IMG/store/llm-rocm-strix_build" ]]; then
  echo "[OK]   image-build : versions.txt discordant ⇒ refus, :latest intacte"
else
  echo "[FAIL] image-build versions.txt discordant : code $grc"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (i) Même exigence si un des quatre binaires manque : pas de promotion.
out="$(_run_img 'cmd_image_build' 'FAKE_BINS_MISSING=1')"; grc=$?
if [[ "$grc" -ne 0 && "$out" == *"llama-quantize"* \
      && "$(cat "$IMG/store/llm-rocm-strix_latest")" == "$ref_avant" ]]; then
  echo "[OK]   image-build : binaire manquant ⇒ refus, :latest intacte"
else
  echo "[FAIL] image-build binaire manquant : code $grc"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (j) Build en échec (docker build non nul) : aucune promotion, :latest intacte.
out="$(_run_img 'cmd_image_build' 'FAKE_BUILD_FAIL=1')"; grc=$?
if [[ "$grc" -ne 0 && "$(cat "$IMG/store/llm-rocm-strix_latest")" == "$ref_avant" ]]; then
  echo "[OK]   image-build : docker build en échec ⇒ :latest intacte"
else
  echo "[FAIL] image-build en échec : code $grc, sortie : $out"; rc=1
fi

# (k) --image-status : ne construit rien, ne purge rien, et dit la conformité.
: > "$IMG/docker.log"
out="$(_run_img 'cmd_image_status')"; grc=$?
grep -qE '^(build|tag|image rm)' "$IMG/docker.log" && ecrit=1 || ecrit=0
if [[ "$grc" -eq 0 && "$out" == *"llm-rocm-strix:latest"* && "$out" == *"conf"* && "$ecrit" -eq 0 ]]; then
  echo "[OK]   image-status : lecture seule (aucun build, aucun rm)"
else
  echo "[FAIL] image-status : code $grc"
  echo "$out" | sed 's/^/       /'; rc=1
fi

# (l) IMAGE_UPDATE_YES=1 vaut accord explicite (même convention que
#     FORK_UPDATE_YES) : image.conf est réécrit sur la révision d'amont, et le
#     build enchaîne. C'est le seul chemin qui fait avancer le moteur sans
#     terminal.
printf 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
' > "$IMG/head-engine"
out="$(_run_img 'cmd_image_update' 'IMAGE_UPDATE_YES=1')"; grc=$?
if [[ "$grc" -eq 0 ]] \
   && grep -q '^ENGINE_REV=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee$' "$IMG/repo/runtime/image.conf" \
   && grep -q '^ROCM_SYSTEMS_REV=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb$' "$IMG/repo/runtime/image.conf" \
   && grep -q '^ENGINE_BRANCH=master$' "$IMG/repo/runtime/image.conf"; then
  echo "[OK]   image-update : IMAGE_UPDATE_YES=1 ⇒ image.conf réécrit, reste intact, build enchaîné"
else
  echo "[FAIL] image-update IMAGE_UPDATE_YES=1 : code $grc"
  echo "$out" | sed 's/^/       /'
  sed 's/^/       conf: /' "$IMG/repo/runtime/image.conf"; rc=1
fi

# 5. Étiquette utilisable en colonne TSV : ni espace, ni tabulation.
etiquette="$(_run '_llama_build')"
if [[ "$etiquette" =~ ^[A-Za-z0-9._-]+$ ]]; then
  echo "[OK]   étiquette sans espace ni tabulation"
else
  echo "[FAIL] étiquette impropre à une colonne TSV : '$etiquette'"; rc=1
fi

[[ "$rc" -eq 0 ]] && echo "── sh-unit : helpers de moteur, garde-fou moteur/ini, garde mémoire, --update-fork (refus, changelog, confirmation), épinglage du moteur (fork.conf), proposition du fork en fin de --setup et moteur conteneurisé (image.conf, promotion après vérification, ménage ciblé, --image-update sans accord) conformes. ──"
exit "$rc"
