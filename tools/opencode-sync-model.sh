#!/usr/bin/env bash
set -euo pipefail

ENDPOINT="${ENDPOINT:-http://bigchuck:8009}"
CONFIG="${CONFIG:-$HOME/.config/opencode/opencode.json}"
PROVIDER="${PROVIDER:-llamaswap}"

[[ -s "$CONFIG" ]] || { echo "Config introuvable : $CONFIG" >&2; exit 1; }

# le provider doit déjà exister dans le fichier de base
jq -e --arg p "$PROVIDER" '.provider[$p] | objects' "$CONFIG" >/dev/null \
  || { echo "Provider '$PROVIDER' absent de $CONFIG" >&2; exit 1; }

models=$(curl -sf --max-time 5 "$ENDPOINT/v1/models" \
  | jq -e '[.data[].id] | sort | map({(.): {name: .}}) | add')

tmp=$(mktemp "${CONFIG}.XXXXXX")
trap 'rm -f "$tmp"' EXIT

jq --argjson models "$models" --arg p "$PROVIDER" \
   '.provider[$p].models = $models' "$CONFIG" > "$tmp"

mv -f "$tmp" "$CONFIG"
trap - EXIT

echo "$(jq -r --arg p "$PROVIDER" '.provider[$p].models | length' "$CONFIG") modèles synchronisés"
