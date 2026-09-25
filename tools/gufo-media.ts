import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

// Deux outils pour pi et omp (le modèle les appelle) et leurs commandes
// directes, sans passer par le modèle : /image [LxH] <prompt> et
// /parler [voix décrite] <texte>. Générer une image et parler, par gufo
// (runtime-gufo/, docs/GUFO.md) derrière le proxy (llm-proxy, routage au
// préfixe « bigchuck/ »). Copier dans ~/.pi/agent/extensions et
// ~/.omp/agent/extensions.
//
// Coût à connaître : Qwen-Image est dans le groupe mémoire « gros » de
// gufo-llama-swap.yaml, avec les LLM. Générer une image décharge le LLM de
// la conversation (bascule ~30 s), et le tour suivant le recharge (~38 s pour
// Flash-Next). La voix (groupe « voix ») tient à côté du LLM : pas de bascule.
//
// Paramètres en JSON Schema brut plutôt que TypeBox : pi importe « typebox »,
// omp « @sinclair/typebox » ; le schéma brut marche pour les deux.

const ENDPOINT = process.env.LLM_PROXY_URL ?? "http://llmproxy";
const API_KEY = process.env.LLM_PROXY_KEY ?? "unused";
const MODELE_IMAGE = process.env.GUFO_IMAGE_MODEL ?? "bigchuck/Qwen-Image-2.1-heretic";
// 512x512 : ~16 s en 20 étapes, 4 fois plus rapide que 1024x1024 (défaut de gufo).
const TAILLE_IMAGE = process.env.GUFO_IMAGE_SIZE ?? "512x512";
const MODELE_VOIX = process.env.GUFO_TTS_MODEL ?? "bigchuck/qwen3-tts-12hz-1.7b-customvoice";
// Voix décrite en langage naturel (champ instructions) : variante VoiceDesign.
const MODELE_VOIX_DECRITE = process.env.GUFO_TTS_DESIGN_MODEL ?? "bigchuck/qwen3-tts-12hz-1.7b-voice-design";
// Lecteur audio : pw-play (PipeWire), sinon paplay ou aplay via la variable.
const LECTEUR = process.env.GUFO_PLAYER ?? "pw-play";

async function post(chemin: string, corps: unknown, signal: AbortSignal | undefined, delai: number): Promise<Response> {
  const res = await fetch(`${ENDPOINT}${chemin}`, {
    method: "POST",
    headers: { Authorization: `Bearer ${API_KEY}`, "Content-Type": "application/json" },
    body: JSON.stringify(corps),
    signal: signal ? AbortSignal.any([signal, AbortSignal.timeout(delai)]) : AbortSignal.timeout(delai),
  });
  if (!res.ok) throw new Error(`${chemin} : HTTP ${res.status} ${(await res.text()).slice(0, 300)}`);
  return res;
}

function jouer(fichier: string, signal: AbortSignal | undefined): Promise<void> {
  return new Promise((ok, ko) => {
    const p = spawn(LECTEUR, [fichier], { stdio: "ignore", signal });
    p.on("error", ko);
    p.on("exit", (code) => (code === 0 ? ok() : ko(new Error(`${LECTEUR} a rendu ${code}`))));
  });
}

function texte(t: string, details: Record<string, unknown> = {}) {
  return { content: [{ type: "text" as const, text: t }], details };
}

// Génère l'image et l'écrit en PNG ; rend le chemin et la durée.
async function genererImage(params: any, cwd: string, signal?: AbortSignal) {
  const chemin = resolve(cwd, params.chemin ?? `image-${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
  const t0 = Date.now();
  const res = await post("/v1/images/generations", {
    model: MODELE_IMAGE,
    prompt: params.prompt,
    size: params.taille ?? TAILLE_IMAGE,
    ...(params.etapes ? { steps: params.etapes } : {}),
    ...(params.graine !== undefined ? { seed: params.graine } : {}),
  }, signal, 600_000);
  const b64 = ((await res.json()) as { data: { b64_json: string }[] }).data[0].b64_json;
  await mkdir(dirname(chemin), { recursive: true });
  await writeFile(chemin, Buffer.from(b64, "base64"));
  return { chemin, secondes: Number(((Date.now() - t0) / 1000).toFixed(1)) };
}

// Synthétise et joue le texte ; rend la durée d'audio et le WAV gardé (ou null).
async function parler(params: any, cwd: string, signal?: AbortSignal) {
  const res = await post("/v1/audio/speech", {
    input: params.texte,
    language: params.langue ?? "French",
    response_format: "wav",
    ...(params.description_voix
      ? { model: MODELE_VOIX_DECRITE, instructions: params.description_voix }
      : { model: MODELE_VOIX, voice: params.voix ?? "aiden" }),
  }, signal, 300_000);
  const wav = Buffer.from(await res.arrayBuffer());
  const chemin = params.chemin
    ? resolve(cwd, params.chemin)
    : resolve(process.env.XDG_RUNTIME_DIR ?? "/tmp", `gufo-voix-${process.pid}.wav`);
  await mkdir(dirname(chemin), { recursive: true });
  await writeFile(chemin, wav);
  try {
    await jouer(chemin, signal);
  } finally {
    if (!params.chemin) await rm(chemin, { force: true });
  }
  const duree = Number(((wav.length - 44) / 48000).toFixed(1)); // PCM 16 bits mono 24 kHz
  return { duree, wav: params.chemin ? chemin : null };
}

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "generer_image",
    label: "Image (gufo)",
    description:
      "Génère une image avec Qwen-Image sur gufo et l'enregistre en PNG. " +
      "Lent : 15 s (512x512) à 90 s (1024x1024) de calcul, plus le déchargement du modèle de conversation (rechargé au tour suivant). " +
      "Rédiger le prompt en anglais pour de meilleurs résultats.",
    parameters: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "Description de l'image" },
        chemin: { type: "string", description: "Fichier PNG à écrire, relatif au dossier de travail (défaut image-<horodatage>.png)" },
        taille: { type: "string", description: `LARGEURxHAUTEUR, multiples de 32 (défaut ${TAILLE_IMAGE} ; 1024x1024 pour plus de détail, 4 fois plus lent)` },
        etapes: { type: "number", description: "Étapes de débruitage (défaut 40 ; 20 suffit pour un brouillon)" },
        graine: { type: "number", description: "Graine, pour reproduire une image" },
      },
      required: ["prompt"],
    } as any,
    async execute(_id, params: any, signal, onUpdate, ctx) {
      onUpdate?.(texte("Génération en cours (bascule de modèle comprise)..."));
      const r = await genererImage(params, ctx.cwd, signal);
      return texte(`Image enregistrée : ${r.chemin} (${r.secondes} s).`, r);
    },
  });

  pi.registerTool({
    name: "parler",
    label: "Voix (gufo)",
    description:
      "Lit un texte à voix haute sur les haut-parleurs de l'utilisateur (Qwen3-TTS sur gufo). " +
      "Rapide (environ 2,5 fois le temps réel). Garder des phrases courtes.",
    parameters: {
      type: "object",
      properties: {
        texte: { type: "string", description: "Texte à dire" },
        langue: { type: "string", description: "Langue (défaut French ; English, Chinese, Japanese...)" },
        voix: { type: "string", description: "Voix intégrée (défaut aiden ; liste : GET /v1/audio/voices)" },
        description_voix: { type: "string", description: "Voix décrite en langage naturel, à la place de voix (ex. « a calm deep male voice, slow pace »)" },
        chemin: { type: "string", description: "Garder aussi le WAV à ce chemin (optionnel)" },
      },
      required: ["texte"],
    } as any,
    async execute(_id, params: any, signal, _onUpdate, ctx) {
      const r = await parler(params, ctx.cwd, signal);
      return texte(`Dit (${r.duree} s d'audio)${r.wav ? `, WAV : ${r.wav}` : ""}.`, r);
    },
  });

  // Commandes directes : ni le modèle ni la conversation ne sont touchés
  // (/image décharge quand même le LLM côté gufo, groupe « gros »).
  // /parler [voix décrite] <texte> : la description entre crochets passe par
  // VoiceDesign, sans crochets c'est la voix intégrée par défaut.
  pi.registerCommand("parler", {
    description: "Lit le texte à voix haute (gufo) : /parler [voix décrite] <texte>",
    handler: async (args: string, ctx: any) => {
      const m = (args ?? "").trim().match(/^(?:\[([^\]]+)\]\s*)?([\s\S]+)$/);
      if (!m) return ctx.ui.notify("Usage : /parler [voix décrite] <texte>", "warning");
      try {
        const r = await parler({ texte: m[2], ...(m[1] ? { description_voix: m[1].trim() } : {}) }, ctx.cwd);
        ctx.ui.notify(`Dit (${r.duree} s d'audio).`, "info");
      } catch (e) {
        ctx.ui.notify(`parler : ${(e as Error).message}`, "error");
      }
    },
  });

  pi.registerCommand("image", {
    description: `Génère une image PNG (gufo) : /image [LxH] <prompt> (défaut ${TAILLE_IMAGE})`,
    handler: async (args: string, ctx: any) => {
      const m = (args ?? "").trim().match(/^(?:(\d+x\d+)\s+)?([\s\S]+)$/);
      if (!m) return ctx.ui.notify("Usage : /image [LxH] <prompt>", "warning");
      ctx.ui.notify("Génération en cours (bascule de modèle comprise)...", "info");
      try {
        const r = await genererImage({ prompt: m[2], ...(m[1] ? { taille: m[1] } : {}) }, ctx.cwd);
        ctx.ui.notify(`Image enregistrée : ${r.chemin} (${r.secondes} s).`, "info");
      } catch (e) {
        ctx.ui.notify(`image : ${(e as Error).message}`, "error");
      }
    },
  });
}
