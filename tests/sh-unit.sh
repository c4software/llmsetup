#!/usr/bin/env bash
# =============================================================================
# Test du CONTRAT des runtimes (runtime/CONTRAT.md) et du pilotage générique
# (lib/common.sh, lib/svc.sh, setup-llm.sh), puis les tests de chaque runtime.
#
# Trois parties :
#   1. Conformité : chaque dossier de runtime/ respecte le contrat (fichiers,
#      déclarations, fonctions, règles du compose, aucun effet de bord au
#      chargement, pas de collision entre runtimes). C'est ce test qui dit
#      si un runtime NEUF est recevable.
#   2. Pilotage générique, sur deux runtimes FACTICES dans un dépôt jetable :
#      choix du runtime actif, aiguillage des sous-commandes, ordre du
#      démarrage, exclusivité, bascule et retour arrière, .env idempotent,
#      jamais « compose restart ». Aucun moteur réel n'y entre : ce qui est
#      prouvé ici vaut pour tout runtime conforme.
#   3. Les tests de chaque runtime (runtime/<nom>/tests/sh-unit.sh).
#
# Tout passe par un faux `docker`, un faux `getent` et un faux `curl` : aucun
# démon, aucun conteneur, aucun réseau.
# Lancement : ./tests/sh-unit.sh [--contrat]   (--contrat : parties 1 et 2 seules)
# =============================================================================
set -uo pipefail

TESTS_DIR="$(dirname "$(realpath "$0")")"
REPO_DIR="$(dirname "$TESTS_DIR")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
rc=0

ok()   { echo "[OK]   $*"; }
fail() { echo "[FAIL] $*"; rc=1; }

mkdir -p "$TMP/bin" "$TMP/home" "$TMP/etat"

# Faux docker. Journalise chaque appel, et tient l'état des conteneurs dans
# etat/<conteneur>.running : `compose up` met en marche le conteneur nommé par
# la ligne CONTENEUR= du --env-file, `compose stop` et `docker stop` l'arrêtent.
# etat/up-echec (un nom de conteneur) fait échouer son `up`.
cat > "$TMP/bin/docker" <<EOF
#!/usr/bin/env bash
E="$TMP/etat"
EOF
cat >> "$TMP/bin/docker" <<'EOF'
printf '%s\n' "$*" >> "$E/docker.log"
conteneur_du_env() {
  local f="" prec=""
  for a in "$@"; do [[ "$prec" == "--env-file" ]] && f="$a"; prec="$a"; done
  [[ -f "$f" ]] && sed -n 's/^CONTENEUR=//p' "$f"
}
case "$1" in
  info) exit 0 ;;
  image) exit 0 ;;
  inspect)
    c="${@: -1}"
    case "$*" in
      *State.Running*)  cat "$E/$c.running" 2>/dev/null || echo false ;;
      *State.Status*)   cat "$E/$c.status"  2>/dev/null || echo running ;;
      *State.ExitCode*) cat "$E/$c.exitcode" 2>/dev/null || echo 0 ;;
    esac
    exit 0 ;;
  stop) echo false > "$E/${@: -1}.running"; exit 0 ;;
  compose)
    c="$(conteneur_du_env "$@")"
    case " $* " in
      *" up "*)
        [[ "$(cat "$E/up-echec" 2>/dev/null)" == "$c" ]] && exit 1
        [[ -n "$c" ]] && echo true > "$E/$c.running" ;;
      *" stop "*) [[ -n "$c" ]] && echo false > "$E/$c.running" ;;
    esac
    exit 0 ;;
esac
exit 1
EOF
cat > "$TMP/bin/getent" <<'EOF'
#!/usr/bin/env bash
[[ "$1" == "group" ]] || exit 2
case "$2" in
  render) echo "render:x:303:" ;;
  video)  echo "video:x:986:" ;;
  *) exit 2 ;;
esac
EOF
cat > "$TMP/bin/curl" <<EOF
#!/usr/bin/env bash
[[ "\$(cat "$TMP/etat/health" 2>/dev/null || echo ok)" == "ok" ]] || exit 7
exit 0
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/getent" "$TMP/bin/curl"

# =============================================================================
# 1. Conformité de chaque runtime du dépôt
# =============================================================================

# Commandes du cycle de vie : communes, aucun runtime ne peut les redéclarer.
GENERIQUES="--runtime --setup --start --stop --restart --status --logs --en-marche --help -h"
REQUISES="check env setup etiquette aide commande"

RUNTIMES_PRESENTS=()
for d in "$REPO_DIR"/runtime/*/; do
  [[ -d "$d" ]] && RUNTIMES_PRESENTS+=("$(basename "$d")")
done
if [[ ${#RUNTIMES_PRESENTS[@]} -gt 0 ]]; then
  ok "runtimes présents : ${RUNTIMES_PRESENTS[*]}"
else
  fail "aucun dossier dans runtime/"
fi

# _charge <nom> <appel> - le générique puis CE runtime seul, dans un
# environnement vide (HOME et PATH bidons), sur le vrai dépôt.
_charge() {
  env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$REPO_DIR" \
    bash -c "set -euo pipefail
      source '$REPO_DIR/lib/common.sh'
      source '$REPO_DIR/lib/svc.sh'
      RUNTIMES=('$1'); RT='$1'
      source '$REPO_DIR/runtime/$1/runtime.sh'
      $2" </dev/null
}

declare -A VU_CONTENEUR=() VU_ENV=() VU_CMD=() VU_FN=()
BASE_FN="$(env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" SCRIPT_DIR="$REPO_DIR" \
  bash -c "source '$REPO_DIR/lib/common.sh'; source '$REPO_DIR/lib/svc.sh'; declare -F | cut -d' ' -f3")"

for nom in ${RUNTIMES_PRESENTS[@]+"${RUNTIMES_PRESENTS[@]}"}; do
  D="$REPO_DIR/runtime/$nom"
  id="${nom//[^A-Za-z0-9]/_}"
  avant=$rc

  # Fichiers imposés.
  for f in runtime.sh docker-compose.yml tests/sh-unit.sh; do
    [[ -f "$D/$f" ]] || fail "$nom : $f absent"
  done
  [[ -x "$D/tests/sh-unit.sh" ]] || fail "$nom : tests/sh-unit.sh non exécutable"
  [[ "$nom" =~ ^[a-z0-9][a-z0-9.-]*$ ]] || fail "$nom : nom de dossier hors [a-z0-9.-]"
  [[ -f "$D/runtime.sh" && -f "$D/docker-compose.yml" ]] || continue

  # Chargement : rien sur stdout, aucun appel à docker ni à curl.
  : > "$TMP/etat/docker.log"
  sortie="$(_charge "$nom" ':' 2>&1)" || fail "$nom : runtime.sh ne se charge pas : $sortie"
  [[ -z "$sortie" ]] || fail "$nom : runtime.sh affiche quelque chose en se chargeant : $sortie"
  [[ ! -s "$TMP/etat/docker.log" ]] || fail "$nom : runtime.sh appelle docker en se chargeant"

  # Déclarations.
  decl="$(_charge "$nom" 'printf "%s\n" "${RT_CONTENEUR['"$nom"']:-}" "${RT_ENV_FILE['"$nom"']:-}" "${RT_DESCRIPTION['"$nom"']:-}" "${RT_COMMANDES['"$nom"']:-}"' 2>/dev/null)"
  { IFS= read -r conteneur; IFS= read -r envf; IFS= read -r desc; IFS= read -r cmds; } <<<"$decl"
  [[ -n "$conteneur" ]] || fail "$nom : RT_CONTENEUR[$nom] non déclaré (le runtime se déclare-t-il sous le nom de son dossier ?)"
  [[ "$envf" == /* ]] || fail "$nom : RT_ENV_FILE[$nom] n'est pas un chemin absolu : '$envf'"
  [[ -n "$desc" ]] || fail "$nom : RT_DESCRIPTION[$nom] vide"
  [[ "$envf" != "$REPO_DIR"/* ]] || fail "$nom : le .env généré vivrait dans le dépôt ($envf)"
  if [[ -n "$conteneur" ]]; then
    [[ -z "${VU_CONTENEUR[$conteneur]:-}" ]] || fail "$nom : conteneur '$conteneur' déjà pris par ${VU_CONTENEUR[$conteneur]}"
    VU_CONTENEUR[$conteneur]="$nom"
  fi
  if [[ -n "$envf" ]]; then
    [[ -z "${VU_ENV[$envf]:-}" ]] || fail "$nom : .env '$envf' déjà pris par ${VU_ENV[$envf]}"
    VU_ENV[$envf]="$nom"
  fi

  # Sous-commandes : en --xxx, hors cycle de vie, propres à ce runtime.
  for c in $cmds; do
    [[ "$c" == --* ]] || fail "$nom : sous-commande '$c' sans --"
    [[ " $GENERIQUES " != *" $c "* ]] || fail "$nom : '$c' est une commande commune, pas une sous-commande"
    [[ -z "${VU_CMD[$c]:-}" ]] || fail "$nom : sous-commande '$c' déjà déclarée par ${VU_CMD[$c]}"
    VU_CMD[$c]="$nom"
  done

  # Fonctions du contrat, et collisions de noms avec un autre runtime.
  fns="$(_charge "$nom" 'declare -F | cut -d" " -f3' 2>/dev/null)"
  for f in $REQUISES; do
    grep -qx "rt_${id}_$f" <<<"$fns" || fail "$nom : fonction rt_${id}_$f absente"
  done
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    grep -qx "$f" <<<"$BASE_FN" && continue
    [[ -z "${VU_FN[$f]:-}" ]] || fail "$nom : fonction $f déjà définie par ${VU_FN[$f]} (tous les runtimes sont chargés ensemble)"
    VU_FN[$f]="$nom"
  done <<<"$fns"

  # etiquette : une chaîne sans espace (colonne de journal TSV), sans docker.
  : > "$TMP/etat/docker.log"
  etiq="$(_charge "$nom" '_rt etiquette' 2>/dev/null)"
  [[ "$etiq" =~ ^[A-Za-z0-9._+?-]+$ ]] || fail "$nom : étiquette impropre à une colonne TSV : '$etiq'"
  [[ ! -s "$TMP/etat/docker.log" ]] || fail "$nom : etiquette lance docker (elle est appelée à chaque journal)"

  # aide : cite chaque sous-commande déclarée.
  aide="$(_charge "$nom" '_rt aide' 2>/dev/null)"
  [[ -n "$aide" ]] || fail "$nom : aide vide"
  for c in $cmds; do
    grep -qF -- "$c" <<<"$aide" || fail "$nom : l'aide ne cite pas la sous-commande $c"
  done

  # Compose : règles lues hors commentaires.
  yml="$(grep -v '^[[:space:]]*#' "$D/docker-compose.yml")"
  mauvaises="$(grep -oE '\$\{[^}]*\}' <<<"$yml" | grep -vE '^\$\{[A-Z_][A-Z0-9_]*:\?\}$' | sort -u | tr '\n' ' ')"
  [[ -z "$mauvaises" ]] || fail "$nom : compose : variables hors \${VAR:?} : $mauvaises"
  grep -qE '^[[:space:]]*container_name:[[:space:]]*"?\$\{[A-Z_]+:\?\}' <<<"$yml" || fail "$nom : compose : container_name n'est pas une variable \${VAR:?}"
  grep -qE '^[[:space:]]*restart:' <<<"$yml" || fail "$nom : compose : politique restart absente"
  grep -qE '^[[:space:]]*user:[[:space:]]*"\$\{[A-Z_]+:\?\}:\$\{[A-Z_]+:\?\}"' <<<"$yml" || fail "$nom : compose : user n'est pas l'uid:gid de l'hôte par variables (le conteneur tournerait en root)"
  grep -qE '^[[:space:]]*ports:' <<<"$yml" || fail "$nom : compose : aucun port publié"
  for interdit in 'privileged' 'docker.sock' 'network_mode: host' 'network_mode: "host"' 'mem_limit'; do
    grep -qF -- "$interdit" <<<"$yml" && fail "$nom : compose : '$interdit' interdit par le contrat"
  done
  if grep -qF 'MODELS_BASE' <<<"$yml"; then
    grep -qE '\$\{MODELS_BASE:\?\}:\$\{MODELS_BASE:\?\}:ro' <<<"$yml" || fail "$nom : compose : le parc n'est pas monté au même chemin en :ro"
  fi
  [[ "$(grep -cE '^  [A-Za-z0-9_-]+:[[:space:]]*$' <<<"$(awk '/^services:/{f=1;next} f&&/^[^[:space:]]/{f=0} f' <<<"$yml")")" -eq 1 ]] \
    || fail "$nom : compose : un service et un seul"

  [[ $rc -eq $avant ]] && ok "contrat : $nom conforme (fichiers, déclarations, ${REQUISES// /, }, étiquette '$etiq', compose)"
done

# Le défaut du dépôt existe.
defaut="$(env -i HOME="$TMP/home" PATH="/usr/bin:/bin" SCRIPT_DIR="$REPO_DIR" bash -c "source '$REPO_DIR/lib/common.sh'; echo \$RUNTIME_DEFAUT")"
if [[ -d "$REPO_DIR/runtime/$defaut" ]]; then
  ok "runtime par défaut présent : $defaut"
else
  fail "RUNTIME_DEFAUT ($defaut) n'est pas un dossier de runtime/"
fi

# =============================================================================
# 2. Pilotage générique, sur deux runtimes factices
# =============================================================================

R="$TMP/depot"
mkdir -p "$R/lib" "$R/runtime"
cp "$REPO_DIR/setup-llm.sh" "$R/"
cp "$REPO_DIR/lib/common.sh" "$REPO_DIR/lib/svc.sh" "$REPO_DIR/lib/help.sh" "$R/lib/"

# _faux <nom> - un runtime minimal et conforme. Chaque fonction de contrat
# écrit son nom dans etat/appels.log ; etat/<nom>.check à 0 fait échouer check.
_faux() {
  local n="$1"
  mkdir -p "$R/runtime/$n"
  cat > "$R/runtime/$n/docker-compose.yml" <<'EOF'
services:
  svc:
    container_name: ${CONTENEUR:?}
    restart: unless-stopped
    user: "${SVC_UID:?}:${SVC_GID:?}"
    ports:
      - "8009:8009"
EOF
  cat > "$R/runtime/$n/runtime.sh" <<EOF
RT_CONTENEUR[$n]="c-$n"
RT_ENV_FILE[$n]="$TMP/home/$n/.env"
RT_DESCRIPTION[$n]="runtime factice $n"
RT_COMMANDES[$n]="--propre-$n"
RT_DELAI_ARRET[$n]=7
rt_${n}_check() { echo "$n check" >> "$TMP/etat/appels.log"; [[ "\$(cat "$TMP/etat/$n.check" 2>/dev/null || echo 1)" == 1 ]] || { warn "$n pas prêt" >&2; return 1; }; }
rt_${n}_env() { echo "$n env \$*" >> "$TMP/etat/appels.log"; printf 'CONTENEUR=c-%s\nARG=%s\n' "$n" "\${1:-}"; }
rt_${n}_avant_demarrage() { echo "$n avant_demarrage" >> "$TMP/etat/appels.log"; }
rt_${n}_pret() { echo "$n pret" >> "$TMP/etat/appels.log"; }
rt_${n}_setup() { echo "$n setup \$*" >> "$TMP/etat/appels.log"; }
rt_${n}_etiquette() { echo "$n-1"; }
rt_${n}_aide() { echo "aide de $n : --propre-$n"; }
rt_${n}_commande() { echo "$n commande \$*" >> "$TMP/etat/appels.log"; }
EOF
}
_faux un
_faux deux

# _llm [env…] -- args : le point d'entrée du dépôt jetable.
_llm() {
  local -a e=()
  while [[ "${1:-}" != "--" ]]; do e+=("$1"); shift; done
  shift
  env -i HOME="$TMP/home" PATH="$TMP/bin:/usr/bin:/bin" ${e[@]+"${e[@]}"} "$R/setup-llm.sh" "$@" </dev/null 2>&1
}
_raz() { : > "$TMP/etat/docker.log"; : > "$TMP/etat/appels.log"; }
_marche() { cat "$TMP/etat/c-$1.running" 2>/dev/null || echo false; }

# (a) Choix du runtime actif : défaut absent refusé, runtime.conf, LLM_RUNTIME.
if out="$(_llm -- --status)"; then
  fail "runtime par défaut absent du dépôt jetable : aurait dû être refusé"
elif grep -q "Runtime inconnu" <<<"$out" && grep -q "un deux\|deux un" <<<"$out"; then
  ok "runtime actif : un défaut absent est refusé en listant les présents"
else
  fail "runtime inconnu mal signalé : $out"
fi
echo "un" > "$R/runtime.conf"
# (sorties capturées, pas de tube : un grep -q qui sort tôt ferait échouer le
#  tube sous pipefail)
out_conf="$(_llm -- --status)"; out_env="$(_llm LLM_RUNTIME=deux -- --status)"
if grep -q "Runtime actif : un " <<<"$out_conf" && grep -q "Runtime actif : deux " <<<"$out_env"; then
  ok "runtime actif : runtime.conf, et LLM_RUNTIME qui prime pour une commande"
else
  fail "runtime actif : runtime.conf ou LLM_RUNTIME ignoré"
fi
if [[ "$(cat "$R/runtime.conf")" == "un" ]]; then
  ok "runtime actif : LLM_RUNTIME ne mémorise rien"
else
  fail "LLM_RUNTIME a réécrit runtime.conf"
fi

# (b) Aiguillage : sous-commande du runtime actif exécutée, celle d'un autre
#     refusée en le nommant, inconnue refusée, --setup délégué.
_raz
_llm -- --propre-un a b >/dev/null
if grep -qx "un commande --propre-un a b" "$TMP/etat/appels.log"; then
  ok "aiguillage : sous-commande du runtime actif exécutée avec ses arguments"
else
  fail "aiguillage : sous-commande du runtime actif perdue"
fi
if out="$(_llm -- --propre-deux)"; then
  fail "aiguillage : sous-commande d'un autre runtime acceptée"
elif grep -q "commande du runtime deux" <<<"$out" && ! grep -q "deux commande" "$TMP/etat/appels.log"; then
  ok "aiguillage : sous-commande d'un autre runtime refusée en le nommant"
else
  fail "aiguillage : refus mal formulé : $out"
fi
if out="$(_llm -- --nimporte)"; then
  fail "aiguillage : commande inconnue acceptée"
else
  ok "aiguillage : commande inconnue refusée"
fi
_raz
_llm -- --setup x >/dev/null; _llm LLM_RUNTIME=deux -- --setup y >/dev/null
if grep -qx "un setup x" "$TMP/etat/appels.log" && grep -qx "deux setup y" "$TMP/etat/appels.log"; then
  ok "aiguillage : --setup délégué au runtime visé (LLM_RUNTIME installe sans basculer)"
else
  fail "aiguillage : --setup mal délégué"
fi

# (c) Démarrage : check, avant_demarrage, env, up --force-recreate, pret, dans
#     cet ordre ; .env écrit dans le dossier déclaré ; arguments transmis.
_raz
out="$(_llm -- --start modele)"
if [[ "$(tr '\n' '|' < "$TMP/etat/appels.log")" == "un check|un avant_demarrage|un env modele|un pret|" ]] \
   && grep -qx "ARG=modele" "$TMP/home/un/.env" \
   && grep -q "compose --project-directory $TMP/home/un --env-file $TMP/home/un/.env -f $R/runtime/un/docker-compose.yml up -d --force-recreate" "$TMP/etat/docker.log"; then
  ok "démarrage : check, avant_demarrage, env, up --force-recreate, pret ; .env et compose aux places du contrat"
else
  fail "démarrage : séquence inattendue : $(tr '\n' '|' < "$TMP/etat/appels.log") / $out"
fi
# .env identique : pas réécrit (la date de modification garde son sens).
touch -d '2020-01-01' "$TMP/home/un/.env"
_llm -- --start modele >/dev/null
if [[ "$(date -r "$TMP/home/un/.env" +%Y)" == "2020" ]]; then
  ok ".env : contenu identique, fichier non réécrit"
else
  fail ".env réécrit alors que rien n'a changé"
fi
_llm -- --start autre >/dev/null
if grep -qx "ARG=autre" "$TMP/home/un/.env" && [[ "$(date -r "$TMP/home/un/.env" +%Y)" != "2020" ]]; then
  ok ".env : contenu changé, fichier réécrit"
else
  fail ".env non réécrit alors que son contenu change"
fi

# (d) Exclusivité : démarrer un runtime arrête celui qui tient le port.
_raz
_llm LLM_RUNTIME=deux -- --start >/dev/null
if [[ "$(_marche un)" == false && "$(_marche deux)" == true ]] \
   && grep -q -- "--env-file $TMP/home/un/.env .* stop -t 7" "$TMP/etat/docker.log"; then
  ok "exclusivité : démarrer « deux » arrête « un » (délai d'arrêt déclaré), un seul runtime sur le port"
else
  fail "exclusivité : un=$(_marche un) deux=$(_marche deux)"; cat "$TMP/etat/docker.log"
fi

# (e) --restart : stop puis start, JAMAIS compose restart ; --stop ; --en-marche.
_raz
_llm LLM_RUNTIME=deux -- --restart >/dev/null
if grep -q ' stop -t 7' "$TMP/etat/docker.log" && grep -q ' up -d --force-recreate' "$TMP/etat/docker.log" \
   && ! grep -qE 'compose .* restart' "$TMP/etat/docker.log"; then
  ok "--restart : stop puis up, jamais compose restart"
else
  fail "--restart : séquence docker inattendue"; cat "$TMP/etat/docker.log"
fi
if _llm LLM_RUNTIME=deux -- --en-marche && ! _llm -- --en-marche; then
  ok "--en-marche : 0 pour le runtime qui tourne, 1 pour l'autre, sans rien afficher"
else
  fail "--en-marche : codes de retour inattendus"
fi
_llm LLM_RUNTIME=deux -- --stop >/dev/null
if [[ "$(_marche deux)" == false ]]; then ok "--stop : conteneur arrêté"; else fail "--stop sans effet"; fi

# Arrêt sans .env (machine jamais démarrée sur ce format, fichier retiré) :
# arrêt propre par `docker stop` sur le nom du conteneur, jamais sauté.
_llm LLM_RUNTIME=deux -- --start >/dev/null
mv "$TMP/home/deux/.env" "$TMP/home/deux/.env.garde"; _raz
_llm LLM_RUNTIME=deux -- --stop >/dev/null
if grep -qx 'stop -t 7 c-deux' "$TMP/etat/docker.log" && ! grep -q '^compose' "$TMP/etat/docker.log" && [[ "$(_marche deux)" == false ]]; then
  ok "--stop sans .env : docker stop sur le nom du conteneur"
else
  fail "--stop sans .env : $(cat "$TMP/etat/docker.log")"
fi
mv "$TMP/home/deux/.env.garde" "$TMP/home/deux/.env"

# (f) Attente de /health : le conteneur est sorti, il ne répondra jamais. La
#     boucle rend la main tout de suite en donnant le code de sortie, sans
#     attendre le plafond (deux mesures perdues autrement, 17/09/2026).
echo ko > "$TMP/etat/health"; echo exited > "$TMP/etat/c-un.status"; echo 137 > "$TMP/etat/c-un.exitcode"
t0=$SECONDS
if out="$(_llm -- --start)"; then
  fail "attente : un conteneur sorti devrait faire échouer --start"
elif (( SECONDS - t0 < 20 )) && grep -q "est sorti (code 137)" <<<"$out"; then
  ok "attente : conteneur sorti détecté en $((SECONDS - t0)) s, code de sortie donné, sans attendre le plafond"
else
  fail "attente : $((SECONDS - t0)) s, sortie : $out"
fi
echo ok > "$TMP/etat/health"; echo running > "$TMP/etat/c-un.status"

# (g) Bascule (--runtime). Prérequis du nouveau vérifiés avant de toucher à
#     quoi que ce soit ; succès mémorisé ; échec du démarrage = retour arrière.
_llm -- --start >/dev/null                      # « un » sert
echo 0 > "$TMP/etat/deux.check"; _raz
if out="$(_llm -- --runtime deux)"; then
  fail "bascule : un runtime pas prêt aurait dû être refusé"
elif [[ "$(cat "$R/runtime.conf")" == "un" && "$(_marche un)" == true ]] && ! grep -q ' stop ' "$TMP/etat/docker.log" \
     && grep -q "LLM_RUNTIME=deux ./setup-llm.sh --setup" <<<"$out"; then
  ok "bascule : runtime pas prêt refusé, rien arrêté, runtime.conf intact, renvoi à --setup"
else
  fail "bascule vers un runtime pas prêt : conf=$(cat "$R/runtime.conf") un=$(_marche un) : $out"
fi
echo 1 > "$TMP/etat/deux.check"
if _llm -- --runtime deux >/dev/null && [[ "$(cat "$R/runtime.conf")" == "deux" && "$(_marche un)" == false && "$(_marche deux)" == true ]]; then
  ok "bascule : « deux » mémorisé et en marche, « un » arrêté"
else
  fail "bascule réussie mal appliquée : conf=$(cat "$R/runtime.conf") un=$(_marche un) deux=$(_marche deux)"
fi
echo "c-un" > "$TMP/etat/up-echec"
if out="$(_llm -- --runtime un)"; then
  fail "bascule : un démarrage en échec aurait dû sortir en erreur"
elif [[ "$(cat "$R/runtime.conf")" == "deux" && "$(_marche deux)" == true && "$(_marche un)" == false ]]; then
  ok "bascule : démarrage en échec, retour arrière (runtime.conf remis, ancien runtime relancé)"
else
  fail "retour arrière : conf=$(cat "$R/runtime.conf") un=$(_marche un) deux=$(_marche deux) : $out"
fi
: > "$TMP/etat/up-echec"
if out="$(_llm -- --runtime trois)"; then
  fail "bascule vers un runtime inexistant acceptée"
elif grep -q "Runtime inconnu" <<<"$out" && [[ "$(cat "$R/runtime.conf")" == "deux" ]]; then
  ok "bascule : runtime inexistant refusé"
else
  fail "bascule vers un runtime inexistant : $out"
fi
if out="$(_llm -- --runtime)" && grep -qE '^\* deux +en marche' <<<"$out" && grep -qE '^  un +arrêté' <<<"$out"; then
  ok "--runtime : liste, actif marqué, état de chacun"
else
  fail "--runtime sans argument : $out"
fi

# (h) Aide : commandes communes, runtimes présents, aide du runtime actif.
out="$(_llm -- --help)"
if grep -q -- "--runtime <nom>" <<<"$out" && grep -q "runtime factice un" <<<"$out" && grep -q "aide de deux" <<<"$out"; then
  ok "aide : commandes communes, runtimes présents, aide du runtime actif"
else
  fail "aide incomplète"
fi

[[ "$rc" -eq 0 ]] && echo "── contrat et pilotage générique conformes (${RUNTIMES_PRESENTS[*]}). ──"

# =============================================================================
# 3. Les tests de chaque runtime
# =============================================================================
if [[ "${1:-}" != "--contrat" ]]; then
  for nom in ${RUNTIMES_PRESENTS[@]+"${RUNTIMES_PRESENTS[@]}"}; do
    t="$REPO_DIR/runtime/$nom/tests/sh-unit.sh"
    [[ -x "$t" ]] || continue
    echo ""
    echo "── runtime $nom ──"
    "$t" || rc=1
  done
fi
exit "$rc"
