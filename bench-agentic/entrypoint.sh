#!/bin/sh
# Génère la configuration pi : un provider "local" (API OpenAI de
# llama-server, SERVER_URL) avec une seule entrée de modèle, MODEL.
# La clé est bidon : llama-server n'en demande pas, le SDK de pi si.
set -eu
mkdir -p "$PI_CODING_AGENT_DIR"
cat > "$PI_CODING_AGENT_DIR/models.json" <<JSON
{
  "providers": {
    "local": {
      "baseUrl": "${SERVER_URL}/v1",
      "api": "openai-completions",
      "apiKey": "unused",
      "models": [{"id": "${MODEL}", "name": "${MODEL}", "reasoning": false,
                  "input": ["text"], "contextWindow": 131072, "maxTokens": 8192,
                  "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0}}]
    }
  }
}
JSON
exec "$@"
