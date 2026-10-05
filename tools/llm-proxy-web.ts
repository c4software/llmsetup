import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

// Recherche web et lecture de page pour pi et omp, par les outils que le
// proxy (llm-proxy, « Outils hébergés ») exécute lui-même : `web_search`
// (son instance SearXNG, joignable du proxy seulement) et `web_fetch` (page
// rendue en texte, sous son garde-fou d'adresses privées). Pour Codex le
// proxy les branche tout seul sur l'API Responses ; pi et omp parlent en
// chat/completions et gardent leurs appels d'outils dans leur historique :
// l'extension les leur déclare et appelle les deux routes d'appel direct,
//   GET  {LLM_PROXY_URL}/v1/tools        les outils actifs et leur schéma
//   POST {LLM_PROXY_URL}/v1/tools/<nom>  arguments en JSON → { result, is_error }
// Plus deux commandes directes, sans appel au modèle : /web <requête> et
// /page <url>. Copier dans ~/.pi/agent/extensions et ~/.omp/agent/extensions.
//
// Découverte au démarrage plutôt que déclaration en dur : seuls les outils
// ACTIFS du proxy sont enregistrés (un outil désactivé répondrait 404 à
// chaque appel), avec la description et le schéma du proxy tels quels (JSON
// Schema brut, accepté par pi comme par omp), et rien du tout si le proxy
// est injoignable, comme llm-proxy.ts pour les modèles. Le démarrage de
// l'agent attend la découverte : son délai est court (DELAI_DECOUVERTE).
//
// Noms : préfixe « proxy_ » (proxy_web_search, proxy_web_fetch). omp a un
// `web_search` intégré, et dans pi comme dans omp un outil d'extension de même
// nom REMPLACE l'intégré sans rien dire. Noms anglais, contrairement à
// gufo-media.ts : ce sont ceux du proxy, que ses descriptions (en anglais)
// citent l'un dans l'autre ; le préfixe y est reporté.
//
// Dans omp, ces outils s'ajoutent au `web_search` intégré (fournisseurs
// publics, ou une instance SearXNG joignable du poste) et à `read <url>` :
// deux recherches côte à côte, le modèle choisit. Pour n'en garder qu'une,
// soit `web_search.enabled: false` dans la configuration d'omp, soit
// LLM_PROXY_WEB=0 dans son environnement (l'extension n'enregistre rien).

const ENDPOINT = (process.env.LLM_PROXY_URL ?? "http://llmproxy").replace(/\/+$/, "");
// Deux noms pour la même clé : gufo-media.ts lit LLM_PROXY_KEY, llm-proxy.ts
// LLM_PROXY_API_KEY.
const API_KEY = process.env.LLM_PROXY_KEY ?? process.env.LLM_PROXY_API_KEY ?? "unused";
const ACTIF = !/^(0|false|no|non|off)$/i.test((process.env.LLM_PROXY_WEB ?? "").trim());
const PREFIXE = "proxy_";
// Proxy éteint : le démarrage de l'agent n'attend pas plus.
const DELAI_DECOUVERTE = 3_000;
// Le proxy borne lui-même une exécution à 60 s (tools.run_timeout) et rend
// alors son propre « Error: … timed out » : on attend un peu plus que lui.
const DELAI_APPEL = 70_000;

interface OutilProxy {
  name: string;
  description?: string;
  parameters?: Record<string, unknown>;
}

const LIBELLES: Record<string, string> = {
  web_search: "Recherche web (proxy)",
  web_fetch: "Lecture de page (proxy)",
};

function texte(t: string, details: Record<string, unknown> = {}) {
  return { content: [{ type: "text" as const, text: t }], details };
}

function entetes(): Record<string, string> {
  return { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" };
}

// Exécute un outil du proxy et rend son texte. Tout échec est une exception
// (pi et omp en font un résultat d'outil en erreur, que le modèle lit) :
// `is_error` du proxy avec son texte « Error: … » tel quel, erreur HTTP,
// proxy injoignable, délai dépassé, annulation.
async function appeler(nom: string, args: unknown, signal?: AbortSignal): Promise<string> {
  let res: Response;
  let corps: string;
  try {
    res = await fetch(`${ENDPOINT}/v1/tools/${encodeURIComponent(nom)}`, {
      method: "POST",
      headers: entetes(),
      body: JSON.stringify(args ?? {}),
      signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(DELAI_APPEL)]) : AbortSignal.timeout(DELAI_APPEL),
    });
    corps = await res.text();
  } catch (e) {
    const err = e as Error & { cause?: { code?: string; message?: string } };
    if (signal?.aborted) throw new Error(`${nom} : annulé`);
    if (err.name === "TimeoutError") throw new Error(`${nom} : pas de réponse du proxy en ${DELAI_APPEL / 1000} s`);
    throw new Error(`${nom} : proxy injoignable (${ENDPOINT}) : ${err.cause?.code ?? err.cause?.message ?? err.message}`);
  }
  let json: any = null;
  try { json = JSON.parse(corps); } catch { /* corps non JSON : rendu brut plus bas */ }
  if (!res.ok) {
    const detail = String(json?.error?.message ?? corps).slice(0, 300);
    if (res.status === 401 || res.status === 403) throw new Error(`${nom} : clé refusée par le proxy (HTTP ${res.status}, LLM_PROXY_KEY) : ${detail}`);
    if (res.status === 404) throw new Error(`${nom} : outil absent ou désactivé sur le proxy (HTTP 404) : ${detail}`);
    throw new Error(`${nom} : HTTP ${res.status} ${detail}`);
  }
  if (typeof json?.result !== "string") throw new Error(`${nom} : réponse inattendue du proxy : ${corps.slice(0, 300)}`);
  if (json.is_error) throw new Error(json.result);
  return json.result;
}

export default async function (pi: ExtensionAPI) {
  if (!ACTIF) return;

  let outils: OutilProxy[] = [];
  try {
    const res = await fetch(`${ENDPOINT}/v1/tools`, { headers: entetes(), signal: AbortSignal.timeout(DELAI_DECOUVERTE) });
    if (!res.ok) throw new Error(`HTTP ${res.status}`);
    const liste = ((await res.json()) as { data?: OutilProxy[] }).data;
    outils = (Array.isArray(liste) ? liste : []).filter((o) => o && typeof o.name === "string" && o.name);
  } catch (err) {
    // Proxy injoignable, clé refusée ou proxy sans la route (404) : on
    // n'enregistre rien plutôt que de bloquer le démarrage.
    console.error(`[llm-proxy-web] découverte impossible (${ENDPOINT}/v1/tools) : ${err}`);
    return;
  }

  // Les descriptions du proxy se citent (« Use web_fetch to read a result
  // page ») : y reporter le préfixe, sinon le modèle appelle un nom qui
  // n'existe pas (pi) ou l'outil intégré (omp).
  const noms = outils.map((o) => o.name);
  const prefixer = (t: string) => noms.reduce((s, n) => s.replace(new RegExp(`(?<![\\w-])${n}(?![\\w-])`, "g"), PREFIXE + n), t);

  for (const o of outils) {
    const label = LIBELLES[o.name] ?? `${o.name} (proxy)`;
    pi.registerTool({
      name: PREFIXE + o.name,
      label,
      description: prefixer(o.description ?? o.name),
      parameters: (o.parameters ?? { type: "object", properties: {} }) as any,
      async execute(_id, params: any, signal, onUpdate, _ctx) {
        onUpdate?.(texte(`${label} : appel en cours...`));
        const t0 = Date.now();
        const r = await appeler(o.name, params, signal);
        return texte(r, { outil: o.name, secondes: Number(((Date.now() - t0) / 1000).toFixed(1)) });
      },
    });
  }

  // Commandes directes : le modèle n'est pas appelé. Le résultat est versé
  // dans la conversation (message d'extension affiché, sans lancer de tour) :
  // le modèle l'aura sous les yeux au tour suivant, et il compte dans le
  // contexte (une page : jusqu'à 20 000 caractères, max_chars du proxy).
  const commande = (nom: string, outil: string, usage: string, args: (a: string) => Record<string, unknown>, description: string) => {
    if (!noms.includes(outil)) return;
    pi.registerCommand(nom, {
      description: `${description} : ${usage}`,
      handler: async (saisie: string, ctx: any) => {
        const a = (saisie ?? "").trim();
        if (!a) return ctx.ui.notify(`Usage : ${usage}`, "warning");
        ctx.ui.notify(`${LIBELLES[outil]} : appel en cours...`, "info");
        try {
          const r = await appeler(outil, args(a));
          pi.sendMessage({ customType: "llm-proxy-web", content: `${usage.split(" ")[0]} ${a}\n\n${r}`, display: true, details: { outil } });
        } catch (e) {
          ctx.ui.notify(`${nom} : ${(e as Error).message}`, "error");
        }
      },
    });
  };
  commande("web", "web_search", "/web <requête>", (a) => ({ query: a }), "Recherche web par le proxy, versée dans la conversation");
  commande("page", "web_fetch", "/page <url>", (a) => ({ url: a }), "Lit une page web par le proxy, versée dans la conversation");
}
