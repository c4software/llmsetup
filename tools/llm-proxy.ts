import type { ExtensionAPI, ProviderModelConfig } from "@earendil-works/pi-coding-agent";

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
  costs: { input: number; output: number };
}

/** Number(undefined) donne NaN, pas undefined : ?? ne rattrape rien. */
function num(value: unknown, fallback: number): number {
  const n = Number(value);
  return Number.isFinite(n) && n > 0 ? n : fallback;
}

/**
 * Thinking : piloté par chat_template_kwargs, que la requête écrase côté
 * serveur (vérifié le 28/08/2026 : ornith-1.5-35b-a3b lancé nothink répond
 * avec reasoning_content dès que la requête envoie enable_thinking:true).
 * Le proxy ne relaie ni /props ni les arguments de lancement, donc on envoie
 * la même chose à tous : un template Jinja ignore les variables qu'il ne lit
 * pas. Qwen3.8 prend reasoning_effort (low..xhigh), Ornith et Qwen3.5/3.6 ne
 * voient que enable_thinking (on/off, le niveau choisi n'a pas d'effet), les
 * autres ignorent tout et /think ne change rien.
 */
const THINKING: Partial<ProviderModelConfig> = {
  reasoning: true,
  thinkingLevelMap: { off: "off", minimal: null, low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: null },
  compat: {
    thinkingFormat: "chat-template",
    chatTemplateKwargs: {
      enable_thinking: { $var: "thinking.enabled" },
      reasoning_effort: { $var: "thinking.effort", omitWhenOff: true },
    },
  },
};

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
      ...THINKING,
    })),
  });
}
