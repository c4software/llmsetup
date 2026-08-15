import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const ENDPOINT = process.env.LLAMASWAP_ENDPOINT ?? "http://localhost:8009";

interface ModelInfo {
  id: string;
  contextWindow: number;
  maxTokens: number;
  reasoning: boolean;
}

function parseArgs(args: string[]): Map<string, string> {
  const map = new Map<string, string>();
  for (let i = 0; i < args.length - 1; i++) {
    if (args[i].startsWith("--")) {
      map.set(args[i], args[i + 1]);
      i++;
    }
  }
  return map;
}

export default async function (pi: ExtensionAPI) {
  let models: ModelInfo[] = [];

  try {
    const res = await fetch(`${ENDPOINT}/v1/models`, {
      signal: AbortSignal.timeout(5000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const payload = (await res.json()) as { data: Array<{ id: string; status?: { args?: string[] } }> };

    models = payload.data.map((m) => {
      const args = m.status?.args ? parseArgs(m.status.args) : new Map();
      return {
        id: m.id,
        contextWindow: Number(args.get("--ctx-size")) ?? 128000,
        maxTokens: Number(args.get("--n-predict")) ?? 16384,
        reasoning: args.get("--reasoning") !== "off",
      };
    }).sort((a, b) => a.id.localeCompare(b.id));
  } catch (err) {
    // serveur éteint : on n'enregistre rien plutôt que de bloquer le démarrage
    console.error(`[llamaswap] découverte impossible : ${err}`);
    return;
  }

  pi.registerProvider("llamaswap", {
    name: "llama-swap (localhost)",
    baseUrl: `${ENDPOINT}/v1`,
    apiKey: "llamaswap",
    api: "openai-completions",
    models: models.map((m) => ({
      id: m.id,
      name: m.id,
      reasoning: m.reasoning,
      input: ["text"],
      cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
      contextWindow: m.contextWindow,
      maxTokens: m.maxTokens,
    })),
  });
}
