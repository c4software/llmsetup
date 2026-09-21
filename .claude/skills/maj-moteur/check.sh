#!/usr/bin/env bash
# check.sh - état des quatre pièces épinglées de l'image ROCm face à leur amont.
#
# Lecture seule : rien n'est écrit, rien n'est construit, aucun conteneur lancé.
# Sort un rapport par partie (moteur, runtime ROCr, Dockerfile amont, patchs,
# image publiée) et termine avec un résumé A_JOUR= / EN_RETARD= lu par la
# skill maj-moteur. Dépendances : bash, git, curl, python3 stdlib (les mêmes
# que le dépôt). L'API GitHub : GH_TOKEN ou GITHUB_TOKEN s'il est défini, sinon
# le jeton de `gh auth token` si gh est connecté, sinon anonyme (60 requêtes
# par heure, vite épuisées : « injoignable » partout = quota, pas amont).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
DOCKERFILE="$SCRIPT_DIR/runtime/Dockerfile.rocm-strix"
AMONT="$SCRIPT_DIR/runtime/AMONT.md"
PATCHES="$SCRIPT_DIR/runtime/patches"

# Dépôt amont du Dockerfile (cf. runtime/AMONT.md, « Provenance »).
UP_REPO="kyuz0/amd-strix-halo-toolboxes"
UP_FILE="toolboxes/Dockerfile.rocm-10.0-strix-llama"
UP_TAG="docker.io/kyuz0/amd-strix-halo-toolboxes:rocm-10.0-strix-llama"

[[ -f "$DOCKERFILE" ]] || { echo "ERREUR : $DOCKERFILE absent" >&2; exit 2; }
[[ -f "$AMONT" ]]      || { echo "ERREUR : $AMONT absent" >&2; exit 2; }

_arg() { sed -n "s/^ARG $1=//p" "$DOCKERFILE" | head -1; }
_gh() {
  # _gh <chemin API> : JSON brut, ou chaîne vide si l'API répond mal.
  local -a auth=()
  local tok="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [[ -z "$tok" ]] && command -v gh >/dev/null 2>&1 && tok="$(gh auth token 2>/dev/null || true)"
  [[ -n "$tok" ]] && auth=(-H "Authorization: Bearer $tok")
  curl -sf "${auth[@]}" -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/$1" || true
}
_repo_of() { sed -E 's#^https://github.com/##; s#\.git$##' <<<"$1"; }

en_retard=()
a_jour=()
titre() { printf '\n=== %s ===\n' "$1"; }

# ---------------------------------------------------------------------------
# 1 et 2 : moteur et runtime, même mécanique (ARG *_REV contre sommet de branche)
# ---------------------------------------------------------------------------
_compare_rev() {
  local nom="$1" repo_url="$2" branche="$3" rev="$4"
  local repo tip
  repo="$(_repo_of "$repo_url")"
  titre "$nom : $repo ($branche)"
  echo "épinglé : ${rev:-<VIDE : sommet de branche au build, non comparable>}"
  tip="$(git ls-remote --heads "$repo_url" "refs/heads/$branche" 2>/dev/null | cut -f1)"
  if [[ -z "$tip" ]]; then
    echo "amont   : injoignable (git ls-remote a échoué)"
    en_retard+=("$nom (injoignable)")
    return 0
  fi
  echo "amont   : $tip"
  if [[ -z "$rev" ]]; then
    en_retard+=("$nom (non épinglé)")
    return 0
  fi
  if [[ "$tip" == "$rev" ]]; then
    echo "état    : à jour"
    a_jour+=("$nom")
    return 0
  fi
  echo "état    : EN RETARD"
  en_retard+=("$nom")
  _gh "repos/$repo/compare/$rev...$branche" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
except Exception:
    print("  (comparaison GitHub indisponible : voir git log sur un clone)"); sys.exit(0)
print("  statut : %s, %s commit(s) devant, %s derrière" % (d.get("status"), d.get("ahead_by"), d.get("behind_by")))
print("  commits :")
for c in d.get("commits", []):
    print("    %s %s %s" % (c["sha"][:12], c["commit"]["committer"]["date"][:10], c["commit"]["message"].splitlines()[0][:100]))
files = d.get("files", [])
if files:
    print("  fichiers (%d) :" % len(files))
    for f in files[:60]:
        print("    %-8s %s (+%d/-%d)" % (f["status"], f["filename"], f["additions"], f["deletions"]))
    if len(files) > 60: print("    ... %d autres" % (len(files) - 60))
'
}

_prs_ouvertes() {
  local repo="$1"
  echo "PR ouvertes vers master (non servies, pour information) :"
  _gh "repos/$repo/pulls?state=open&base=master&sort=updated&direction=desc&per_page=15" | python3 -c '
import json, sys
try:
    prs = json.load(sys.stdin)
except Exception:
    print("  (indisponible)"); sys.exit(0)
if not prs: print("  aucune")
for p in prs:
    print("  #%-4d %s  %s" % (p["number"], p["updated_at"][:10], p["title"][:90]))
'
}

_compare_rev "Moteur" "$(_arg REPO)" "$(_arg BRANCH)" "$(_arg ENGINE_REV)"
_prs_ouvertes "$(_repo_of "$(_arg REPO)")"

_compare_rev "Runtime ROCr/HIP" "$(_arg ROCM_SYSTEMS_REPO)" "$(_arg ROCM_SYSTEMS_BRANCH)" "$(_arg ROCM_SYSTEMS_REV)"

# ---------------------------------------------------------------------------
# 3 : Dockerfile amont (celui dont runtime/Dockerfile.rocm-strix est la copie)
# ---------------------------------------------------------------------------
titre "Dockerfile amont : $UP_REPO/$UP_FILE (main)"
local_up="$(sed -n 's/^| Commit du fichier en amont | `\([0-9a-f]*\)` |$/\1/p' "$AMONT" | head -1)"
echo "repris  : ${local_up:-<ligne « Commit du fichier en amont » introuvable dans AMONT.md>}"
last_json="$(_gh "repos/$UP_REPO/commits?path=$UP_FILE&sha=main&per_page=10")"
if [[ -z "$last_json" ]]; then
  echo "amont   : injoignable"
  en_retard+=("Dockerfile amont (injoignable)")
else
  # Le JSON passe en argument : le script python occupe déjà stdin (heredoc).
  # Code de retour : 0 à jour, 3 en retard.
  if python3 - "$local_up" "$last_json" <<'PY'
import json, sys
local_up, cs = sys.argv[1], json.loads(sys.argv[2])
if not cs:
    print("amont   : aucun commit sur ce chemin (fichier déplacé ?)"); sys.exit(3)
print("amont   : %s (%s)" % (cs[0]["sha"][:7], cs[0]["commit"]["committer"]["date"][:10]))
if local_up and cs[0]["sha"].startswith(local_up):
    print("état    : à jour"); sys.exit(0)
print("état    : EN RETARD, commits sur le fichier depuis %s :" % (local_up or "?"))
for c in cs:
    if local_up and c["sha"].startswith(local_up): break
    print("    %s %s %s" % (c["sha"][:12], c["commit"]["committer"]["date"][:10], c["commit"]["message"].splitlines()[0][:100]))
print("  Diff à lire : gh api repos/%s/contents/%s?ref=main --jq .content | base64 -d" % ("kyuz0/amd-strix-halo-toolboxes", "toolboxes/Dockerfile.rocm-10.0-strix-llama"))
print("  puis ne réappliquer que les cinq écarts listés dans runtime/AMONT.md.")
sys.exit(3)
PY
  then a_jour+=("Dockerfile amont"); else en_retard+=("Dockerfile amont"); fi
fi

# ---------------------------------------------------------------------------
# 4 : patchs (partagés entre Dockerfiles amont, bougent sans que le nôtre bouge)
# ---------------------------------------------------------------------------
titre "Patchs : runtime/patches contre $UP_REPO/toolboxes (main)"
patch_retard=0
for p in "$PATCHES"/*.patch; do
  nom="$(basename "$p")"
  up="$(_gh "repos/$UP_REPO/contents/toolboxes/$nom?ref=main" | python3 -c '
import json, sys, base64
try:
    d = json.load(sys.stdin); sys.stdout.write(base64.b64decode(d["content"]).decode())
except Exception:
    pass')"
  if [[ -z "$up" ]]; then
    echo "$nom : absent en amont (ou API injoignable)"
    patch_retard=1
  elif [[ "$up" == "$(cat "$p")" ]]; then
    echo "$nom : identique"
  else
    echo "$nom : DIFFÈRE de l'amont"
    diff -u "$p" <(printf '%s\n' "$up") | head -40 || true
    patch_retard=1
  fi
done
if (( patch_retard )); then en_retard+=("Patchs"); else a_jour+=("Patchs"); fi

# ---------------------------------------------------------------------------
# 5 : image publiée en amont ? (« Manual build only » au 18/09/2026)
# ---------------------------------------------------------------------------
titre "Image publiée : $UP_TAG"
tags="$(curl -sf "https://hub.docker.com/v2/repositories/kyuz0/amd-strix-halo-toolboxes/tags/?name=rocm-10.0-strix-llama&page_size=5" \
  | python3 -c 'import json,sys
try:
    print(" ".join(t["name"] for t in json.load(sys.stdin).get("results", [])))
except Exception: pass' || true)"
if [[ -z "$tags" ]]; then
  echo "toujours absente du registre : le build local reste nécessaire."
else
  echo "tag(s) trouvé(s) : $tags"
  echo "Pour information seulement : le build local reste le choix du dépôt (épinglage, cf. AMONT.md écart 1)."
fi

# ---------------------------------------------------------------------------
# 6 : ce qui tourne ici, si l'image existe (n'échoue pas sinon)
# ---------------------------------------------------------------------------
titre "Image locale"
if command -v docker >/dev/null 2>&1 && docker image inspect llm-rocm-strix:latest >/dev/null 2>&1; then
  docker image inspect llm-rocm-strix:latest --format 'créée : {{.Created}}'
  docker run --rm --entrypoint cat llm-rocm-strix:latest /opt/strix/versions.txt 2>/dev/null \
    | sed 's/^/  /' || echo "  (versions.txt illisible)"
else
  echo "pas d'image llm-rocm-strix:latest sur cette machine (normal hors de la machine du service)."
fi

# ---------------------------------------------------------------------------
# résumé contractuel
# ---------------------------------------------------------------------------
echo
IFS=,; echo "A_JOUR=${a_jour[*]:-}"; echo "EN_RETARD=${en_retard[*]:-}"; unset IFS
(( ${#en_retard[@]} == 0 )) && exit 0 || exit 1
