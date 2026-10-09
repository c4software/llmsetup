#!/usr/bin/env bash
# =============================================================================
# Test unitaire du runtime gufo : ce qui dépend de l'ENVIRONNEMENT plutôt que
# d'une entrée, et qui, en cas de bug, casse SILENCIEUSEMENT ou coûte une
# série de mesures. Le .env généré (runtime.sh) et son rendu par le VRAI
# `docker compose config` quand il est là, la cohérence de
# gufo-llama-swap.yaml (noms, contexte annoncé, groupes), l'image épinglée à
# un seul endroit, ce que gufo ajoute au pilotage générique (modèle préchargé
# gardé par --restart, refus avant écriture) et les cibles de téléchargement.
#
# Jusqu'au 09/10/2026 c'était la section (i) du tests/sh-unit.sh du dépôt ;
# chaque runtime porte désormais ses tests (runtime/CONTRAT.md), et
# tests/sh-unit.sh, à la racine, vérifie le contrat puis lance ceux-ci.
#
# Tout passe par un faux `docker`, un faux `getent` et un faux `curl` : aucun
# démon, aucun conteneur, aucun réseau.
# Lancement : runtime/gufo/tests/sh-unit.sh
# =============================================================================
set -uo pipefail

TESTS_DIR="$(dirname "$(realpath "$0")")"
# Dossier du runtime, et racine du dépôt (lib/ générique).
RT_DIR="$(dirname "$TESTS_DIR")"
REPO_DIR="$(dirname "$(dirname "$RT_DIR")")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0

SVC="$TMP/svc"
mkdir -p "$SVC/bin" "$SVC/repo/runtime/gufo" "$SVC/home/models" "$SVC/etat"
# runtime.sh lit l'image épinglée de gufo dans ce fichier dès qu'il est sourcé,
# et le pilotage générique cherche le compose à runtime/<nom>/docker-compose.yml.
cp "$RT_DIR/IMAGE" "$RT_DIR/docker-compose.yml" "$SVC/repo/runtime/gufo/"

# Faux docker : journalise chaque appel (c'est lui qui prouve qu'aucun
# « compose restart » n'est émis) et lit l'état du conteneur dans des fichiers
# que le test pose. etat/image à 0 simule une image absente.
cat > "$SVC/bin/docker" <<EOF
#!/usr/bin/env bash
E="$SVC/etat"
EOF
cat >> "$SVC/bin/docker" <<'EOF'
printf '%s\n' "$*" >> "$E/docker.log"
case "$1" in
  info) exit 0 ;;
  image)
    [[ "$2" == "inspect" ]] || exit 1
    [[ "$(cat "$E/image" 2>/dev/null || echo 1)" == "1" ]] || exit 1
    exit 0 ;;
  inspect)
    case "$*" in
      *State.Running*)  cat "$E/running"  2>/dev/null || echo false ;;
      *State.Status*)   cat "$E/status"   2>/dev/null || echo running ;;
      *State.ExitCode*) cat "$E/exitcode" 2>/dev/null || echo 0 ;;
    esac
    exit 0 ;;
  compose | stop | logs) exit 0 ;;
esac
exit 1
EOF

cat > "$SVC/bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "group" ]] || exit 2
case "$2" in
  render) echo "render:x:303:" ;;
  video)  echo "video:x:986:" ;;
  *) exit 2 ;;
esac
EOF

# Faux curl : /health (et le reste) répond selon un fichier d'état.
cat > "$SVC/bin/curl" <<EOF
#!/usr/bin/env bash
[[ "\$(cat "$SVC/etat/health" 2>/dev/null || echo ok)" == "ok" ]] || exit 7
exit 0
EOF
chmod +x "$SVC/bin/docker" "$SVC/bin/getent" "$SVC/bin/curl"

echo 1 > "$SVC/etat/image"
echo ok > "$SVC/etat/health"
echo true > "$SVC/etat/running"
echo running > "$SVC/etat/status"

# Le générique puis ce runtime seul, comme le fait le point d'entrée.
_run_svc() {  # $1 = appel bash ; $2 = env supplémentaire ; stdin fermé
  env -i HOME="$SVC/home" PATH="$SVC/bin:/usr/bin:/bin" SCRIPT_DIR="$SVC/repo" ${2:-} \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/svc.sh'
      RUNTIMES=(gufo); RT=gufo
      source '$RT_DIR/runtime.sh'
      $1" </dev/null 2>&1
}

# (a) Le .env généré et le compose versionné (runtime.sh, docker-compose.yml,
#     toujours derrière llama-swap). Le .env porte les valeurs machine (uid:gid
#     de l'hôte, gid NUMÉRIQUES, modèle préchargé) ; le compose rendu par le
#     vrai docker compose tourne sous l'utilisateur de l'hôte, lance llama-swap
#     et ne laisse aucune variable ; gufo-llama-swap.yaml est cohérent.
GENV="$(_run_svc 'generate_gufo_env qwen3.8-flash-next')"
for attendu in "GUFO_PRECHARGE=qwen3.8-flash-next" "COMPOSE_PROJECT_NAME=gufo" "GUFO_CONTENEUR=gufo-8009" \
               "GUFO_RESTART=unless-stopped" "GUFO_PORT=8009" "GUFO_SESSIONS=2" \
               "GUFO_CACHE=$SVC/home/.local/state/llm-setup/gufo-cache" \
               "GID_RENDER=303" "GID_VIDEO=986" "SVC_UID=$(id -u)"; do
  if grep -qxF -- "$attendu" <<<"$GENV"; then
    echo "[OK]   gufo env : $attendu"
  else
    echo "[FAIL] gufo env : ligne absente : $attendu"; rc=1
  fi
done
GENV_BANC="$(_run_svc 'generate_gufo_env qwen3.8-27b' "GUFO_PORT=8090 GUFO_RESTART=no GUFO_SESSIONS=1 GUFO_PROJET=gufo-banc")"
if grep -qx "GUFO_PORT=8090" <<<"$GENV_BANC" && grep -qx "GUFO_RESTART=no" <<<"$GENV_BANC" \
   && grep -qx "COMPOSE_PROJECT_NAME=gufo-banc" <<<"$GENV_BANC" && grep -qx "GUFO_PRECHARGE=qwen3.8-27b" <<<"$GENV_BANC"; then
  echo "[OK]   gufo env : réglages du banc (port, redémarrage, projet, préchargé) surchargeables"
else
  echo "[FAIL] gufo env : les surcharges du banc ne passent pas"; rc=1
fi
# L'image de gufo n'est épinglée qu'à UN endroit, IMAGE : le .env
# la porte telle quelle, l'environnement la surcharge (bancs), et aucun autre
# fichier exécuté ne récrit une version en dur (trois endroits à tenir
# ensemble jusqu'au 06/10/2026).
GIMG="$(<"$RT_DIR/IMAGE")"
if [[ "$GIMG" =~ ^[^[:space:]]+:[^[:space:]:]+$ && "$GIMG" != *:latest ]] \
   && grep -qxF -- "GUFO_IMAGE=$GIMG" <<<"$GENV" \
   && grep -qx "GUFO_IMAGE=autre:1" <<<"$(_run_svc 'generate_gufo_env' "GUFO_IMAGE=autre:1")"; then
  echo "[OK]   gufo env : image = la ligne de IMAGE ($GIMG), surchargeable"
else
  echo "[FAIL] gufo env : image épinglée ('$GIMG') absente du .env ou non surchargeable"; rc=1
fi
if en_dur="$(grep -rnE 'gufo-runtime:[0-9]' "$REPO_DIR/lib" "$REPO_DIR/tools" "$REPO_DIR/setup-llm.sh" \
               "$RT_DIR" --include='*.sh' --include='*.yml' --include='*.yaml' \
               --include='Dockerfile*' --include='*.py')"; then
  echo "[FAIL] gufo : version d'image écrite en dur hors de IMAGE :"; echo "$en_dur"; rc=1
else
  echo "[OK]   gufo : aucune version d'image en dur hors de IMAGE"
fi
# Noms acceptés par --start : courts et complets, tout le reste refusé.
if [[ "$(_run_svc '_gufo_nom 27b; _gufo_nom deepseek-v4-flash')" == $'qwen3.8-27b\ndeepseek-v4-flash' ]] \
   && ! _run_svc '_gufo_nom routeur' >/dev/null && ! _run_svc '_gufo_nom ""' >/dev/null; then
  echo "[OK]   gufo : noms de modèle courts et complets reconnus, inconnus refusés"
else
  echo "[FAIL] gufo : résolution des noms de modèle"; rc=1
fi
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  GD="$SVC/gufo-data"; mkdir -p "$GD"
  sed "s|^GUFO_CACHE=.*|GUFO_CACHE=$GD/cache|" <<<"$GENV" > "$GD/.env"
  if out="$(docker compose --project-directory "$GD" --env-file "$GD/.env" -f "$SVC/repo/runtime/gufo/docker-compose.yml" config 2>&1)"; then
    if grep -qF "user: $(id -u):$(id -g)" <<<"$out" && grep -qF "container_name: gufo-8009" <<<"$out" \
       && grep -qF "/usr/local/bin/llama-swap" <<<"$out" && grep -qF "GUFO_PRECHARGE: qwen3.8-flash-next" <<<"$out" \
       && grep -qF "gufo-llama-swap.yaml" <<<"$out" && grep -qF "GUFO_CACHE: $GD/cache" <<<"$out" \
       && ! grep -q '\${' <<<"$out"; then
      echo "[OK]   gufo compose : llama-swap, utilisateur de l'hôte, préchargé, aucune variable non résolue"
    else
      echo "[FAIL] gufo compose : rendu inattendu"; rc=1
    fi
  else
    echo "[FAIL] gufo compose : refusé par docker compose : $out"; rc=1
  fi
else
  echo "[SKIP] gufo compose : docker compose absent"
fi
# gufo-llama-swap.yaml : chaque modèle porte le même nom que son
# --served-model-name (sinon gufo répond 404), ne retire plus stop ni
# stop_sequences (gérés par gufo depuis #260), annonce le --context de la macro gufo (capabilities.context, lu
# par le proxy), ne pointe que sous le parc (MODELS_BASE, dont MODELS_BASE/gufo) ; groupe exclusif ; chaque
# nom court de runtime.sh existe ; llama-swap épinglé par somme.
LSY="$(cat "$RT_DIR/gufo-llama-swap.yaml")"
LSY_CTX="$(grep -oE -- '--context [0-9]+' <<<"$LSY" | head -1 | cut -d' ' -f2)"
for m in qwen3.8-27b qwen3.8-flash-next deepseek-v4-flash; do
  bloc="$(awk -v m="  \"$m\":" '$0==m{f=1;next} f&&/^  "/{f=0} f' <<<"$LSY")"
  if grep -q -- "--served-model-name $m" <<<"$bloc" && ! grep -q 'stripParams' <<<"$bloc" \
     && [[ -n "$LSY_CTX" ]] && grep -qE "^      context: $LSY_CTX$" <<<"$bloc" \
     && ! grep -oE '[^ ]+\.gguf' <<<"$bloc" | grep -vqE '^\$\{env\.MODELS_BASE\}/'; then
    echo "[OK]   llama-swap : $m nommé comme gufo le sert, stop transmis, contexte annoncé ($LSY_CTX), fichiers sous le parc"
  else
    echo "[FAIL] llama-swap : bloc $m incohérent dans gufo-llama-swap.yaml"; rc=1
  fi
done
# Tous les modèles (LLM, voix, transcription, image) : nom = --served-model-name,
# et chacun dans un groupe (sinon llama-swap le laisse coexister avec tout).
LSY_MODELES="$(awk '/^models:/{f=1;next} /^routing:/{f=0} f' <<<"$LSY")"
avant=$rc
for m in $(grep -oE '^  "[^"]+":' <<<"$LSY_MODELES" | tr -d ' ":'); do
  bloc="$(awk -v m="  \"$m\":" '$0==m{f=1;next} f&&/^  "/{f=0} f' <<<"$LSY")"
  grep -q -- "--served-model-name $m\b" <<<"$bloc" \
    || { echo "[FAIL] llama-swap : $m servi sous un autre nom"; rc=1; }
  grep -qE "^            - \"$m\"$" <<<"$LSY" \
    || { echo "[FAIL] llama-swap : $m dans aucun groupe"; rc=1; }
done
[[ $rc -eq $avant ]] && echo "[OK]   llama-swap : $(grep -cE '^  "[^"]+":' <<<"$LSY_MODELES") modèles, chacun nommé comme gufo le sert et rangé dans un groupe"
# Groupes : les gros (LLM, Qwen-Image) exclusifs, un à la fois ; la voix et la
# transcription persistantes, jamais déchargées par un gros modèle.
grp() { awk -v g="        $1:" '$0==g{f=1;next} f&&/^        [a-z]/{f=0} f' <<<"$LSY"; }
if grep -q 'exclusive: true' <<<"$(grp gros)" && grep -q 'swap: true' <<<"$(grp gros)" \
   && grep -q '"Qwen-Image-2.1-heretic"' <<<"$(grp gros)" \
   && grep -q 'persistent: true' <<<"$(grp voix)" && grep -q 'exclusive: false' <<<"$(grp voix)" \
   && grep -q 'persistent: true' <<<"$(grp transcription)"; then
  echo "[OK]   llama-swap : gros exclusifs (LLM, Qwen-Image), voix et transcription persistantes"
else
  echo "[FAIL] llama-swap : groupes gros / voix / transcription mal réglés"; rc=1
fi
if grep -qE '^ADD --checksum=sha256:[0-9a-f]{64}' "$RT_DIR/Dockerfile.routeur"; then
  echo "[OK]   llama-swap : binaire vérifié par SHA-256"
else
  echo "[FAIL] llama-swap : binaire non épinglé par somme dans Dockerfile.routeur"; rc=1
fi

# (b) Le pilotage GÉNÉRIQUE (lib/svc.sh) appliqué à ce runtime. Seul ce que
#     gufo y ajoute par ses fonctions de contrat est testé ici : le modèle
#     préchargé de --start, que --restart sans argument garde (celui du .env
#     en place, et non le défaut) ; une image absente ou un modèle inconnu qui
#     arrêtent tout avant qu'un .env soit écrit ; les valeurs du banc, à part.
#     L'ordre du démarrage, « jamais compose restart », l'échec rapide sur un
#     conteneur sorti et la forme de l'étiquette sont prouvés pour tout
#     runtime par le test du contrat (tests/sh-unit.sh à la racine).
GENVF="$SVC/home/llm/gufo-test/.env"
: > "$SVC/etat/docker.log"
if out="$(_run_svc 'cmd_start 27b')" && grep -qx "GUFO_PRECHARGE=qwen3.8-27b" "$GENVF"; then
  echo "[OK]   --start : .env écrit dans GUFO_DATA, modèle préchargé posé"
else
  echo "[FAIL] --start 27b : $out"; rc=1
fi
: > "$SVC/etat/docker.log"
if _run_svc 'cmd_restart' >/dev/null && grep -qx "GUFO_PRECHARGE=qwen3.8-27b" "$GENVF"; then
  echo "[OK]   --restart : modèle préchargé du .env gardé (et non le défaut)"
else
  echo "[FAIL] --restart : modèle préchargé perdu"; rc=1
fi
if _run_svc 'cmd_restart flashnext' >/dev/null && grep -qx "GUFO_PRECHARGE=qwen3.8-flash-next" "$GENVF"; then
  echo "[OK]   --restart <modèle> : l'argument prime sur le .env"
else
  echo "[FAIL] --restart flashnext : modèle préchargé non changé"; rc=1
fi
if out="$(_run_svc 'cmd_start routeur')"; then
  echo "[FAIL] --start devrait refuser un modèle inconnu"; rc=1
elif grep -q "Modèle gufo inconnu" <<<"$out" && grep -qx "GUFO_PRECHARGE=qwen3.8-flash-next" "$GENVF"; then
  echo "[OK]   --start : modèle inconnu refusé, .env en place intact"
else
  echo "[FAIL] --start routeur : $out"; rc=1
fi
# Image absente, dans un GUFO_DATA neuf : rien ne doit y être écrit.
echo 0 > "$SVC/etat/image"
if out="$(_run_svc 'cmd_start' "GUFO_DATA=$SVC/neuf")"; then
  echo "[FAIL] --start devrait refuser sans image"; rc=1
elif grep -q -- "--setup image" <<<"$out" && [[ ! -e "$SVC/neuf" ]]; then
  echo "[OK]   --start : image absente refusée avant toute écriture (renvoie à --setup image)"
else
  echo "[FAIL] --start sans image : $out"; rc=1
fi
echo 1 > "$SVC/etat/image"
# Valeurs du banc : projet, conteneur et .env à part, sur le même pilotage.
: > "$SVC/etat/docker.log"
if _run_svc 'cmd_start 27b' "GUFO_PROJET=gufo-banc GUFO_CONTENEUR=gufo-banc GUFO_RESTART=no GUFO_SESSIONS=1 GUFO_ENV_FILE=$SVC/home/llm/gufo-test/banc.env" >/dev/null \
   && grep -qx "GUFO_CONTENEUR=gufo-banc" "$SVC/home/llm/gufo-test/banc.env" \
   && grep -qx "GUFO_PRECHARGE=qwen3.8-flash-next" "$GENVF" \
   && grep -q -- "--env-file $SVC/home/llm/gufo-test/banc.env" "$SVC/etat/docker.log"; then
  echo "[OK]   banc : banc.env à part, .env d'usage réel intact, compose lancé sur banc.env"
else
  echo "[FAIL] banc : les valeurs du banc débordent sur l'usage réel"; cat "$SVC/etat/docker.log"; rc=1
fi

# (c) Téléchargements : chaque fichier que gufo-llama-swap.yaml charge hors de
#     MODELS_BASE/gufo (les poids partagés avec le runtime
#     llama-cpp-rocm-strix) est pris par une ligne du_parc de download.sh, au
#     même chemin. Sans cela le runtime ne serait pas autonome : une machine
#     sans l'autre runtime n'aurait aucun moyen de les obtenir.
DLS="$(cat "$RT_DIR/download.sh")"
avant=$rc
while IFS= read -r chemin; do
  dossier="${chemin%%/*}"; fichier="${chemin#*/}"
  grep -qE "^[[:space:]]+du_parc $dossier [^ ]+ $fichier( ;;)?$" <<<"$DLS" \
    || { echo "[FAIL] download.sh : $chemin (chargé par llama-swap) n'est téléchargé par aucune cible"; rc=1; }
done < <(grep -oE '\$\{env\.MODELS_BASE\}/[^ ]+\.gguf' <<<"$LSY" | sed 's|^\${env\.MODELS_BASE}/||' | grep -v '^gufo/')
[[ $rc -eq $avant ]] && echo "[OK]   download.sh : les poids partagés chargés par llama-swap ont tous leur ligne du_parc"
if out="$(MODELS_BASE="$SVC/home/models" bash "$RT_DIR/download.sh" inconnu 2>&1 </dev/null)"; then
  echo "[FAIL] download.sh : cible inconnue acceptée"; rc=1
elif grep -q "download.sh 27b" <<<"$out"; then
  echo "[OK]   download.sh : cible inconnue refusée, usage affiché (27b compris)"
else
  echo "[FAIL] download.sh : usage sans la cible 27b : $out"; rc=1
fi

[[ "$rc" -eq 0 ]] && echo "── sh-unit gufo : .env, compose llama-swap rendu par docker compose config, configuration llama-swap cohérente (LLM, voix, transcription, image, groupes), image épinglée à un seul endroit, noms de modèle, pilotage (modèle préchargé gardé, image absente et modèle inconnu refusés, valeurs du banc à part) et téléchargements (poids partagés) conformes. ──"
exit "$rc"
