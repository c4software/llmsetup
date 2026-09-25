import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { spawn } from "node:child_process";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";

// Deux outils pour pi et omp : générer une image et parler, par gufo
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
const MODELE_IMAGE = process.env.GUFO_IMAGE_MODEL ?? "bigchuck/Qwen-Image-2.1";
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

export default function (pi: ExtensionAPI) {
  pi.registerTool({
    name: "generer_image",
    label: "Image (gufo)",
    description:
      "Génère une image avec Qwen-Image sur gufo et l'enregistre en PNG. " +
      "Lent : 15 à 90 s de calcul, plus le déchargement du modèle de conversation (rechargé au tour suivant). " +
      "Rédiger le prompt en anglais pour de meilleurs résultats.",
    parameters: {
      type: "object",
      properties: {
        prompt: { type: "string", description: "Description de l'image" },
        chemin: { type: "string", description: "Fichier PNG à écrire, relatif au dossier de travail (défaut image-<horodatage>.png)" },
        taille: { type: "string", description: "LARGEURxHAUTEUR, multiples de 16 (défaut 1024x1024 ; 512x512 est 4 fois plus rapide)" },
        etapes: { type: "number", description: "Étapes de débruitage (défaut 40 ; 20 suffit pour un brouillon)" },
        graine: { type: "number", description: "Graine, pour reproduire une image" },
      },
      required: ["prompt"],
    } as any,
    async execute(_id, params: any, signal, onUpdate, ctx) {
      const chemin = resolve(ctx.cwd, params.chemin ?? `image-${new Date().toISOString().replace(/[:.]/g, "-")}.png`);
      onUpdate?.(texte("Génération en cours (bascule de modèle comprise)..."));
      const t0 = Date.now();
      const res = await post("/v1/images/generations", {
        model: MODELE_IMAGE,
        prompt: params.prompt,
        size: params.taille ?? "1024x1024",
        ...(params.etapes ? { steps: params.etapes } : {}),
        ...(params.graine !== undefined ? { seed: params.graine } : {}),
      }, signal, 600_000);
      const b64 = ((await res.json()) as { data: { b64_json: string }[] }).data[0].b64_json;
      await mkdir(dirname(chemin), { recursive: true });
      await writeFile(chemin, Buffer.from(b64, "base64"));
      const s = ((Date.now() - t0) / 1000).toFixed(1);
      return texte(`Image enregistrée : ${chemin} (${s} s).`, { chemin, secondes: Number(s) });
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
        ? resolve(ctx.cwd, params.chemin)
        : resolve(process.env.XDG_RUNTIME_DIR ?? "/tmp", `gufo-voix-${process.pid}.wav`);
      await mkdir(dirname(chemin), { recursive: true });
      await writeFile(chemin, wav);
      try {
        await jouer(chemin, signal);
      } finally {
        if (!params.chemin) await rm(chemin, { force: true });
      }
      const duree = ((wav.length - 44) / 48000).toFixed(1); // PCM 16 bits mono 24 kHz
      return texte(`Dit (${duree} s d'audio)${params.chemin ? `, WAV : ${chemin}` : ""}.`, { duree: Number(duree) });
    },
  });
}
