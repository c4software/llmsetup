import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Valeurs en dur pour le test — repasser sur process.env avant de committer.
const ENDPOINT = "http://llmproxy";
const API_KEY = "unused";

// Albert n'expose pas de cap de génération : on plafonne nous-mêmes.
const DEFAULT_MAX_TOKENS = 16384;
const DEFAULT_CONTEXT = 128000;

interface AlbertModel {
  id: string;
  type?: string;
  aliases?: string[];
  max_context_length?: number | null;
  owned_by?: string;
  costs?: { prompt_tokens?: number; completion_tokens?: number };
}

interface ModelInfo {
  id: string;
  contextWindow: number;
  maxTokens: number;
  reasoning: boolean;
  costs: { input: number; output: number };
}

/** Number(undefined) donne NaN, pas undefined : ?? ne rattrape rien. */
function num(value: unknown, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/** Albert ne déclare pas la capacité de raisonnement : heuristique sur l'id. */
function isReasoning(id: string): boolean {
  return /(?:^|[\/\-_])(?:r1|qwq|thinking|reasoner)(?:[\-_.]|$)/i.test(id);
}

export default async function (pi: ExtensionAPI) {
  let models: ModelInfo[] = [];

  try {
    const res = await fetch(`${ENDPOINT}/v1/models`, {
      headers: { Authorization: `Bearer ${API_KEY}` },
      signal: AbortSignal.timeout(10000),
    });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const payload = (await res.json()) as { data: AlbertModel[] };

    models = payload.data
      // seuls les text-generation acceptent /v1/chat/completions
      .filter((m) => m.type === "text-generation")
      .map((m) => {
        const contextWindow = num(m.max_context_length, DEFAULT_CONTEXT);
        return {
          id: m.id,
          contextWindow,
          maxTokens: Math.min(DEFAULT_MAX_TOKENS, contextWindow),
          reasoning: isReasoning(m.id),
          costs: {
            input: num(m.costs?.prompt_tokens, 0),
            output: num(m.costs?.completion_tokens, 0),
          },
        };
      })
      .sort((a, b) => a.id.localeCompare(b.id));
  } catch (err) {
    // Albert injoignable ou clé expirée : on n'enregistre rien plutôt que
    // de bloquer le démarrage
    console.error(`[albert] découverte impossible : ${err}`);
    return;
  }

  if (models.length === 0) {
    console.error("[albert] aucun modèle text-generation exposé");
    return;
  }

  pi.registerProvider("albert", {
    name: "Albert API (DINUM)",
    baseUrl: `${ENDPOINT}/v1`,
    apiKey: API_KEY,
    api: "openai-completions",
    models: models.map((m) => ({
      id: m.id,
      name: m.id,
      reasoning: m.reasoning,
      input: ["text"],
      // Albert facture en unités de budget par million de tokens.
      cost: {
        input: m.costs.input,
        output: m.costs.output,
        cacheRead: 0,
        cacheWrite: 0,
      },
      contextWindow: m.contextWindow,
      maxTokens: m.maxTokens,
    })),
  });
}
