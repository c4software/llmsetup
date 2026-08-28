# Plan de reprise : Qwen3.8-Flash-Next (branche qwen3.8-flash-next)

Fichier temporaire, à supprimer au merge de la branche. Rédigé le 27/08/2026.

## État au 27/08/2026

- Bloc `qwen3.8-flash-next-mtp-nothink` dans `lib/models.sh` (commit f90049e) :
  shards UD-IQ4_XS (93,7 Go), nothink + sampling instruct (temp 0.7, top-p 0.80,
  top-k 20, presence 1.5), `spec-type = ngram-map-k,draft-mtp`, n-max 4,
  size-m 7, min-hits 2, cache-type-v q8_0, cache-reuse 0, jinja, parallel 1.
  Le ini généré ne diffère de master que par cette section (vérifié en local
  et sur bigchuck).
- GGUF téléchargé sur bigchuck : `~/models/qwen3.8-flash-next/UD-IQ4_XS/`
  (3 shards : 10,9 Mo + 49,8 Go + 43,8 Go), via `--setup` lancé depuis la
  branche le 27/08 vers 23:00. `models.ini` de bigchuck contient déjà la
  section, service pas redémarré.
- bigchuck est sur la branche `qwen3.8-flash-next` (worktree propre). Le dépôt
  local est sur master.
- Upstream : PR ggml-org/llama.cpp #27742 (arch `qwen4exp`) mergée le 27/08 à
  19:32 UTC, dans b10661. DFlash2 (#27342) mergée le même jour. Les quants
  unsloth ont été converties avant le merge (uploads 15:01 à 15:16 UTC) :
  ré-upload probable.
- Bloquant : paquet Arch `llama-cpp` en 0.2.0-1 (b10566, 22/08), sans
  `qwen4exp`. Tout le reste attend ce paquet.
- Décisions prises : quant IQ4_XS (validée, pas le Q4_K_XL à 111 Go) ; pas de
  test DFlash2 ni DFlash v1 pour l'instant.
- Surveillance du paquet : bot Hermes, source
  https://archlinux.org/packages/extra/x86_64/llama-cpp/json/ (référence
  pkgver 0.2.0, last_update 2026-08-22T21:34:15Z).

## À la mise à disposition du paquet (>= b10661)

Sur bigchuck, dans `~/llm/llmsetup` (branche `qwen3.8-flash-next`,
`git pull --ff-only` d'abord si la branche a bougé) :

1. Mise à jour et contrôle du support :
   `paru -Syu llama-cpp ggml-vulkan ggml-hip ggml-cpu`
   `strings /usr/lib/libllama.so* | grep -x qwen4exp` (doit sortir une ligne)
   `llama-server --version` (noter le build : il va dans tous les logs).
2. Ré-upload éventuel des quants : `./setup-llm.sh --update qwen3.8-flash-next`
   (vérifier d'abord les dates sur HF ; prévoir 2x la taille du plus gros
   shard en écriture).
3. Étape 2 de la skill (MTP) : `systemctl --user restart llama-server`, charger
   le modèle, puis `curl localhost:8009/v1/models` et vérifier `--spec-type`
   dans `status.args`, puis `./setup-llm.sh --spec-test qwen3.8-flash-next-mtp-nothink 2`.
   Acceptance affichée = tête MTP présente. Si « n/a » : retirer `draft-mtp`
   et `spec-draft-n-max` du bloc, garder `ngram-map-k`, renommer la section
   `qwen3.8-flash-next-nothink`.
   Contrôle de justesse à la main (curl chat/completions, fonction Python
   inverse une liste chaînée) et `journalctl --user -u llama-server` sans
   warn/error/CPU fallback.
4. Étape 3 (device) : `./setup-llm.sh --bench-devices qwen3.8-flash-next-mtp-nothink`.
   ROCm0 suspect (DeepSeek V4 et Qwen3-Coder-Next y sortent du charabia) :
   lire le texte généré, pas seulement les t/s. Optionnel pour l'agentic long :
   `tools/bench-depth.sh` (service arrêté).
5. Étape 4 (MTP) si la tête existe : `./setup-llm.sh --spec-tune qwen3.8-flash-next-mtp-nothink 2,4,6,8 4`.
6. Étape 5 (n-gram) : `./setup-llm.sh --spec-ngram-tune qwen3.8-flash-next-mtp-nothink 4`.
   Attendre un surcoût fixe par pas spéculatif (GDN + MoE 512 experts, comme
   Qwen3-Coder-Next où size_m 7 a divisé le débit par 2) : mesurer 7 ET 47,
   et `--spec-ab` avec `spec-type=none` en référence si le tune ne la fait pas.
7. Étape 6 : `./setup-llm.sh --bench qwen3.8-flash-next-mtp-nothink 3`,
   `--bench-cache` (part du prompt repayée, état récurrent : attendre 62 à
   66 %), `--bench-load` (bascule LRU de 94 Go : attendre > 90 s).
8. Reporter les chiffres (date, build, quant, device, prompt) dans le
   commentaire du bloc, tableau récap dans le message de commit et le README.
   Commit par étape, rien d'édité sur bigchuck (les .conf s'y écrivent seuls).
9. Merger la branche dans master, supprimer ce fichier, remettre bigchuck sur
   master (`git checkout master && git pull --ff-only`).
10. Bump ggml 0.22 : relancer `--bench` sur les autres modèles du parc, le
    journal signale les écarts > 5 %.

## Pistes gardées pour plus tard (non engagées)

- DFlash2 sur Qwen3.8-27B : drafter `z-lab/Qwen3.8-27B-DFlash2-GGUF` (Q8_0
  2,1 Go), même paquet requis. Mesure : `--spec-ab qwen3.8-27b 4 - base
  "spec-type=draft-dflash;spec-draft-model=<gguf>;spec-draft-n-max=7;cache-reuse=0"`.
- DFlash v1 sur qwen3.6-35b-a3b-nothink : drafter
  `Anbeeld/Qwen3.6-35B-A3B-DFlash-GGUF` (Q8_0 0,42 Go), supporté dès b10566.
- Vision Flash-Next : `mmproj-F16.gguf` publié, incompatible MTP, non prévu.
