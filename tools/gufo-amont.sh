#!/usr/bin/env bash
# gufo-amont.sh - suivi de gufo en amont (gufo-org/gufo), en LECTURE SEULE.
#
# Rien n'est écrit, ni ici ni sur GitHub : uniquement des GET de l'API par
# `gh api` (gh connecté requis, portée read:packages pour les images). Chemin
# fixe et lecture seule : c'est ce script que l'agent lance (et que
# .claude/settings.local.json autorise) au lieu de commandes gh improvisées.
#
# Usage :
#   tools/gufo-amont.sh [etat]          releases, images publiées, commits des
#                                       7 derniers jours, état des tickets suivis
#   tools/gufo-amont.sh ticket <n> [k]  ticket ou PR n : titre, état, corps et
#                                       ses k derniers commentaires (défaut tous)
#   tools/gufo-amont.sh release [tag]   notes d'une release (défaut la dernière)
#   tools/gufo-amont.sh commits [date]  commits de la branche principale depuis
#                                       date (AAAA-MM-JJ, défaut : 7 jours)
#   tools/gufo-amont.sh images [n]      n dernières images gufo-runtime et
#                                       leurs tags (défaut 10)
#   tools/gufo-amont.sh diff <de> [à]   documentation changée entre deux
#                                       révisions (tag ou commit, à = dernière
#                                       release) : liste, puis le détail des
#                                       fichiers de réglage (SERVER.md, CLI.md,
#                                       guides des modèles, CHANGELOG.md)
#
# Tickets suivis : les « | #NNN | » du tableau « À surveiller » de
# docs/GUFO.md, seule liste à tenir ; les tickets ouverts par l'utilisateur gh
# connecté sont ajoutés. Image épinglée : la ligne de runtime-gufo/IMAGE.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO="gufo-org/gufo"
PAQUET="toolboxes%2Fgufo-runtime"
DOC="$SCRIPT_DIR/docs/GUFO.md"

command -v gh >/dev/null 2>&1 || { echo "ERREUR : gh introuvable" >&2; exit 2; }

_image_epinglee() { cat "$SCRIPT_DIR/runtime-gufo/IMAGE"; }

# Nos tickets : ouverts seulement. Un ticket suivi qui se ferme reste visible
# (fermé) tant que sa ligne est dans le tableau de docs/GUFO.md, qui la retire.
_tickets_suivis() {
  { sed -n 's/^| #\([0-9]\{1,\}\) |.*/\1/p' "$DOC"
    gh api "repos/$REPO/issues?creator=$(gh api user -q .login)&state=open&per_page=50" \
      -q '.[].number' 2>/dev/null || true
  } | sort -un
}

images() {
  gh api "orgs/gufo-org/packages/container/$PAQUET/versions?per_page=${1:-10}" \
    -q '.[] | "\(.created_at)  \(.name[7:19])  \(.metadata.container.tags | join(","))"'
}

commits() {
  local depuis="${1:-$(date -d '7 days ago' +%F)}"
  gh api "repos/$REPO/commits?since=${depuis}T00:00:00Z&per_page=100" --paginate \
    -q '.[] | "\(.sha[0:7])  \(.commit.author.date[0:16])  \(.commit.message | split("\n")[0])"'
}

release() {
  if [[ -n "${1:-}" ]]; then
    gh release view "$1" -R "$REPO"
  else
    gh release view -R "$REPO"
  fi
}

diff() {
  local de="${1:?révision de départ (tag ou commit)}" a="${2:-}"
  [[ -n "$a" ]] || a="$(gh release view -R "$REPO" --json tagName -q .tagName)"
  echo "== Documentation changée, $de...$a"
  gh api "repos/$REPO/compare/$de...$a" \
    -q '.files[] | select(.filename | test("\\.md$")) | "\(.status)  \(.filename)  +\(.additions) -\(.deletions)"'
  echo
  gh api "repos/$REPO/compare/$de...$a" \
    -q '.files[] | select(.filename | test("^(docs/SERVER|docs/CLI|CHANGELOG)\\.md$|^docs/models/[^/]+/(README|QUALITY|EXPERIMENTS)\\.md$")) | "######## \(.filename)\n\(.patch // "(diff trop gros, voir GitHub)")\n"'
}

ticket() {
  local n="${1:?numéro de ticket}" k="${2:-0}"
  gh api "repos/$REPO/issues/$n" \
    -q '"#\(.number) \(.state) \(if .pull_request then "(PR" + (if .pull_request.merged_at then ", mergée " + .pull_request.merged_at[0:10] else "" end) + ")" else "" end) par \(.user.login), \(.created_at[0:10])\n\(.title)\nétiquettes : \([.labels[].name] | join(", "))\n\n\(.body // "")"'
  echo
  gh api "repos/$REPO/issues/$n/comments?per_page=100" --paginate \
    -q '.[] | "──── \(.user.login) \(.created_at[0:16])\n\(.body)\n"' \
    | if ((k > 0)); then awk -v k="$k" '
        /^──── /{ n++ } { l[n] = l[n] $0 "\n" }
        END { for (i = (n > k ? n - k + 1 : 1); i <= n; i++) printf "%s", l[i] }'
      else cat; fi
}

etat() {
  local img n
  img="$(_image_epinglee)"
  echo "== Releases"
  gh release list -R "$REPO" -L 5
  echo
  echo "== Images gufo-runtime (épinglée : ${img##*/})"
  images 6
  echo
  echo "== Commits des 7 derniers jours"
  commits
  echo
  echo "== Tickets suivis (docs/GUFO.md + les nôtres) : état, maj, commentaires, dernier auteur"
  for n in $(_tickets_suivis); do
    gh api "repos/$REPO/issues/$n" \
      -q '"#\(.number)  \(.state)  \(.updated_at[0:16])  \(.comments) comm.  \(.title[0:90])"'
    gh api "repos/$REPO/issues/$n/comments?per_page=100" \
      -q 'if length > 0 then "        dernier : \(.[-1].user.login) \(.[-1].created_at[0:16])" else empty end'
  done
}

cmd="${1:-etat}"; shift || true
case "$cmd" in
  etat|ticket|release|commits|images|diff) "$cmd" "$@" ;;
  *) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//' >&2; exit 2 ;;
esac
