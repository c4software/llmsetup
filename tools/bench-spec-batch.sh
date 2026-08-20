#!/usr/bin/env bash
# =============================================================================
# bench-spec-batch.sh — coût d'un forward selon la taille du batch.
#
# Un décodage spéculatif vérifie k tokens draftés dans UN forward de batch k+1.
# Le gain dépend donc entièrement de la forme de t_forward(batch) :
#   - plat  (dense, borné bande passante) → les longs drafts sont ~gratuits,
#     on ne peut jamais perdre : seuil de non-perte = 1 token accepté ;
#   - pentu (MoE creux : à batch k on lit l'UNION des experts routés ; ou mur
#     compute) → un draft long mal accepté coûte plus cher que pas de
#     spéculation du tout.
#
# Ce script mesure cette courbe et en déduit, par taille de draft :
#   - le SEUIL DE NON-PERTE = t_fwd(k+1)/t_fwd(1), nombre minimal de tokens à
#     faire accepter pour ne pas être plus lent qu'en décodage normal ;
#   - le GAIN MAX = k+1 divisé par ce seuil (si TOUT le draft est accepté).
#
# C'est la mesure à faire AVANT d'ajouter un spec-type n-gram à un modèle, et
# elle donne directement le --spec-ngram-map-k-size-m à retenir.
#
# Usage :
#   tools/bench-spec-batch.sh                    # tous les GGUF présents
#   tools/bench-spec-batch.sh <gguf> [<gguf>...] # modèles précis
#
# Variables d'env :
#   DEV=ROCm0        device ggml (défaut : auto — cf. llama-bench --list-devices)
#   DEPTH=0          tokens de contexte déjà en KV avant la mesure.
#                    0 = rapide, isole le coût des poids (suffit à classer
#                    dense/MoE). 32768 = réaliste agentic mais TRÈS lent
#                    (un prefill par test) — à réserver aux finalistes.
#   BATCHES=1,8,16,32,48
#   REPS=2
#   FA=auto          -fa on|off|auto
# =============================================================================
set -euo pipefail

MODELS_BASE="${MODELS_BASE:-$HOME/models}"
DEV="${DEV:-}"
DEPTH="${DEPTH:-0}"
BATCHES="${BATCHES:-1,8,16,32,48}"
REPS="${REPS:-2}"
FA="${FA:-auto}"

command -v llama-bench >/dev/null || { echo "llama-bench introuvable (paquet llama-cpp)" >&2; exit 1; }
command -v python3     >/dev/null || { echo "python3 introuvable" >&2; exit 1; }

# Modèles : argv, sinon tous les .gguf sous $MODELS_BASE (1er shard seulement)
declare -a GGUFS=()
if [[ $# -gt 0 ]]; then
  GGUFS=("$@")
else
  while IFS= read -r f; do
    # shards : ne garder que le 00001-of-*, llama-bench charge la suite tout seul
    [[ "$f" =~ -0*[2-9][0-9]*-of-[0-9]+\.gguf$ ]] && continue
    GGUFS+=("$f")
  done < <(find "$MODELS_BASE" -name '*.gguf' -type f 2>/dev/null | sort)
fi

[[ ${#GGUFS[@]} -gt 0 ]] || { echo "Aucun GGUF trouvé sous $MODELS_BASE" >&2; exit 1; }

declare -a DEVARG=()
[[ -n "$DEV" ]] && DEVARG=(-dev "$DEV")

echo "# bench-spec-batch — $(date '+%F %T')"
echo "# host=$(hostname)  device=${DEV:-auto}  depth=$DEPTH  batches=$BATCHES  reps=$REPS  fa=$FA"
echo "# llama-bench: $(llama-server --version 2>&1 | head -1 || true)"
echo

for gguf in "${GGUFS[@]}"; do
  [[ -f "$gguf" ]] || { echo "absent, ignoré : $gguf" >&2; continue; }
  echo "═══ $(basename "$gguf") ═══"
  if ! out="$(llama-bench -m "$gguf" -p "$BATCHES" -n 0 -d "$DEPTH" \
                          -r "$REPS" -fa "$FA" "${DEVARG[@]}" -o jsonl 2>/dev/null)"; then
    echo "  échec llama-bench (VRAM/RAM insuffisante ? arch non supportée ?)"
    echo
    continue
  fi
  printf '%s\n' "$out" | python3 -c '
import sys, json
rows = []
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        r = json.loads(line)
    except ValueError:
        continue
    n, ts = r.get("n_prompt", 0), r.get("avg_ts", 0.0)
    if n and ts:
        rows.append((n, n/ts))          # t_forward en secondes
rows.sort()
if not rows:
    print("  aucune mesure exploitable"); sys.exit()
t1 = dict(rows).get(1) or rows[0][1]

hdr = ("batch", "t_forward", "cout rel.", "seuil non-perte", "gain max")
print("  %6s %12s %10s %18s %9s" % hdr)
print("  " + "-" * 60)
best_m, best_gain = None, 0.0
for n, t in rows:
    rel  = t / t1                      # = nb mini de tokens a faire accepter
    frac = rel / n                     # ... rapporte a la longueur du draft
    gain = n / rel                     # debit max si TOUT est accepte
    print("  %6d %9.1f ms %9.2fx %8.1f tok (%2.0f%%) %8.1fx"
          % (n, t * 1000, rel, rel, 100 * frac, gain))
    # size_m retenu : meilleur gain parmi les tailles ou le seuil reste sous
    # 25%% du draft (au-dela, une acceptance partielle devient perdante)
    if n > 1 and frac <= 0.25 and gain > best_gain:
        best_m, best_gain = n, gain
print()
print("  seuil non-perte = tokens a faire accepter pour ne pas etre plus lent")
print("                    que le decodage normal ; (%) = part du draft.")
print()
if best_m is None:
    print("  VERDICT : aucune taille de draft viable — courbe trop pentue,")
    print("            ne pas activer de spec-type n-gram sur ce modele.")
else:
    n_last, t_last = rows[-1]
    rel_last = t_last / t1
    print("  VERDICT : --spec-ngram-map-k-size-m %d  (gain max x%.1f si tout accepte)"
          % (best_m, best_gain))
    if rel_last / n_last > 0.25:
        print("            NB : au-dela de %d la courbe se degrade (seuil %.0f%% a batch %d)"
              % (best_m, 100 * rel_last / n_last, n_last))
    if rel_last < 1.5:
        print("            courbe PLATE (dense, borne bande passante) : aucun risque de perte.")
    else:
        print("            courbe PENTUE (MoE / mur compute) : ajouter --spec-ngram-map-k-min-hits 2")
        print("            pour eviter les faux departs qui paient le batch sans etre acceptes.")
'
  echo
done
