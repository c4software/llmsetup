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
#   DEV=Vulkan0,ROCm0  device(s) ggml, liste comme --bench-devices (défaut :
#                    Vulkan0, le DEFAULT_DEVICE du models.ini) ; "auto" = ggml
#                    choisit. Chaque modèle est mesuré sur chaque device.
#   OUT=<fichier>    journal lisible, en APPEND (défaut : spec-batch.log à côté
#                    de setup-llm.sh, comme spec-tests.log). La sortie reste
#                    affichée à l'écran en même temps.
#   TSV=<fichier>    mêmes mesures en TSV pour analyse (défaut : spec-batch.tsv)
#   DEPTH=0          tokens de contexte déjà en KV avant la mesure.
#                    0 = rapide, isole le coût des poids (suffit à classer
#                    dense/MoE). 32768 = réaliste agentic mais TRÈS lent
#                    (un prefill par test) — à réserver aux finalistes.
#   BATCHES=1,8,16,32,48
#   REPS=2
#   FA=auto          -fa on|off|auto
# =============================================================================
set -euo pipefail

# Racine du dépôt = parent de tools/ ; les journaux vivent à côté de
# setup-llm.sh comme spec-tests.log / bench-devices.conf (locaux, .gitignore).
ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${OUT:-$ROOT_DIR/spec-batch.log}"
TSV="${TSV:-$ROOT_DIR/spec-batch.tsv}"

MODELS_BASE="${MODELS_BASE:-$HOME/models}"
# Liste séparée par des virgules, comme --bench-devices. Défaut = DEFAULT_DEVICE
# du models.sh (Vulkan0) ; "auto" laisse ggml choisir.
DEV="${DEV:-Vulkan0}"
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

# Devices demandés, croisés avec ceux réellement exposés par ggml (même
# garde-fou que --bench-devices : sans ggml-hip, ROCm0 n'existe pas).
declare -a DEVS=()
if [[ "$DEV" == "auto" ]]; then
  DEVS=("auto")
else
  exposed="$(llama-bench --list-devices 2>/dev/null || true)"
  IFS=',' read -r -a want <<< "$DEV"
  for d in "${want[@]}"; do
    if [[ -z "$exposed" ]] || grep -q "$d" <<<"$exposed"; then
      DEVS+=("$d")
    else
      echo "device '$d' non exposé (llama-bench --list-devices), ignoré." >&2
    fi
  done
  [[ ${#DEVS[@]} -gt 0 ]] || { echo "Aucun device demandé n'est exposé." >&2; exit 1; }
fi

# ROCm/HIP sur iGPU : sans ça les allocations visent la VRAM dédiée (petite)
# au lieu de la mémoire unifiée/GTT — les gros modèles échouent, et surtout on
# ne mesurerait pas ce que fait réellement le service (cf. lib/service.sh).
export GGML_CUDA_ENABLE_UNIFIED_MEMORY=1

# En-tête TSV. Si un fichier existe avec un autre jeu de colonnes (ancienne
# version du script), on ré-écrit une ligne d'en-tête avant les nouvelles
# lignes plutôt que d'écraser des mesures déjà collectées.
TSV_HDR=$'date\tmodele\tdevice\tdepth\tfa_reel\tbatch\tt_forward_ms\tsd_ms\tcout_rel\tgain_max'
if [[ ! -s "$TSV" ]]; then
  printf '%s\n' "$TSV_HDR" > "$TSV"
elif [[ "$(head -1 "$TSV")" != "$TSV_HDR" ]]; then
  printf '\n%s\n' "$TSV_HDR" >> "$TSV"
fi
export TSV DEPTH

# Le service occupe la mémoire unifiée et le GPU pendant la mesure. L'état est
# relevé ici mais journalisé DANS le bloc tee (plus bas) : une mesure dont on
# ignore si le service tournait n'est pas comparable à une autre.
SERVICE_STATE="arrêté"
systemctl --user is-active llama-server &>/dev/null && SERVICE_STATE="EN MARCHE"

# Tout ce qui suit est affiché ET ajouté à $OUT (append : un run ne détruit
# pas les précédents, on peut comparer deux backends ou deux DEPTH).
{
echo "# bench-spec-batch — $(date '+%F %T')"
echo "# host=$(hostname)  devices=${DEVS[*]}  depth=$DEPTH  batches=$BATCHES  reps=$REPS  fa=$FA"
echo "# llama-cpp: $(llama-server --version 2>&1 | head -1 || true)"
echo "# service llama-server : $SERVICE_STATE"
if [[ "$SERVICE_STATE" == "EN MARCHE" ]]; then
  echo "#   ⚠ contention GPU/mémoire — pour un run propre :"
  echo "#     systemctl --user stop llama-server"
fi
echo
echo "# NB : les points à gros batch sont bornés compute et donc sensibles à"
echo "#      l'état thermique. Un balayage enchaîné juste après un autre mesure"
echo "#      une puce chaude : c'est le régime soutenu, pas le pic à froid."
echo

for gguf in "${GGUFS[@]}"; do
 [[ -f "$gguf" ]] || { echo "absent, ignoré : $gguf" >&2; continue; }
 for dev in "${DEVS[@]}"; do
  declare -a DEVARG=()
  [[ "$dev" != "auto" ]] && DEVARG=(-dev "$dev")
  echo "═══ $(basename "$gguf")  [$dev] ═══"
  if ! out="$(llama-bench -m "$gguf" -p "$BATCHES" -n 0 -d "$DEPTH" \
                          -r "$REPS" -fa "$FA" "${DEVARG[@]}" -o jsonl 2>/dev/null)"; then
    echo "  échec llama-bench (RAM insuffisante ? arch non supportée par ce backend ?)"
    echo
    continue
  fi
  # export, pas un prefixe de commande : un prefixe ne s'appliquerait qu'a
  # printf (premiere commande du pipeline), pas au python3 qui ecrit le TSV.
  export DEV_NAME="$dev" MODEL_NAME="$(basename "$gguf")"
  printf '%s\n' "$out" | python3 -c '
import sys, json, os, datetime
rows = []
fa_seen = set()
for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue
    try:
        r = json.loads(line)
    except ValueError:
        continue
    n, ts, sd = r.get("n_prompt", 0), r.get("avg_ts", 0.0), r.get("stddev_ts", 0.0)
    if not (n and ts):
        continue
    t = n / ts                                   # t_forward en secondes
    # stddev_ts est en tokens/s : on le propage en secondes (|dt/dts| = t/ts)
    tsd = (sd / ts) * t if ts else 0.0
    rows.append((n, t, tsd))
    fa_seen.add(str(r.get("flash_attn", "?")))
rows.sort()
if not rows:
    print("  aucune mesure exploitable"); sys.exit()
t1 = dict((n, t) for n, t, _ in rows).get(1) or rows[0][1]
stamp = datetime.datetime.now().strftime("%Y-%m-%dT%H:%M:%S")
fa_real = ",".join(sorted(fa_seen))
tsv = []

print("  batch = size_m + 1 (le token echantillonne + les size_m draftes)")
print("  %6s %7s %14s %10s %16s %8s" % ("batch", "size_m", "t_forward", "cout rel.", "seuil non-perte", "gain"))
print("  " + "-" * 64)
noisy = []
prev = None
for n, t, tsd in rows:
    rel  = t / t1
    frac = rel / n
    gain = n / rel
    flag = ""
    if prev is not None and t < prev[1]:
        # Une baisse dans le bruit combine des deux points = plateau, pas une
        # inversion. On ne signale que ce qui la depasse nettement (3 sigma).
        sigma = (prev[2] ** 2 + tsd ** 2) ** 0.5
        if prev[1] - t > 3 * sigma:
            flag = "  <-- BAISSE"
            noisy.append((prev[0], n))
        else:
            flag = "  (plateau)"
    print("  %6d %7d %8.1f+-%-4.1f ms %8.2fx %6.1f tok (%2.0f%%) %7.1fx%s"
          % (n, n - 1, t * 1000, tsd * 1000, rel, rel, 100 * frac, gain, flag))
    tsv.append("%s\t%s\t%s\t%s\t%s\t%d\t%.2f\t%.2f\t%.4f\t%.3f" % (
        stamp, os.environ.get("MODEL_NAME", "?"), os.environ.get("DEV_NAME", "?"),
        os.environ.get("DEPTH", "?"), fa_real, n, t * 1000, tsd * 1000, rel, gain))
    prev = (n, t, tsd)
print()
print("  seuil non-perte = tokens a faire accepter pour ne pas etre plus lent")
print("                    que le decodage normal ; (%) = part du draft.")
print()

if noisy:
    print("  ⚠ courbe NON MONOTONE (t_forward baisse quand le batch grossit) :")
    for a, b in noisy:
        print("      entre batch %d et %d" % (a, b))
    print("    Le filtre a 3 sigma est deja passe : ce nest pas de la gigue de")
    print("    mesure, mais un palier de noyau ggml — le batch du haut emprunte")
    print("    un chemin plus rapide que celui du bas. La taille du bas est donc")
    print("    a EVITER comme size_m. Rejouer le balayage tranche : un palier se")
    print("    reproduit a lidentique, un artefact non.")
    print()

# Enveloppe monotone : un point anormalement bas ne doit pas gonfler le verdict.
env, run_max = [], 0.0
for n, t, _ in rows:
    run_max = max(run_max, t)
    env.append((n, run_max))

best_m, best_gain = None, 0.0
for n, t in env:
    if n > 1 and (t / t1) / n <= 0.25 and n / (t / t1) > best_gain:
        best_m, best_gain = n, n / (t / t1)

# Marche : un saut brutal entre deux batches consecutifs = changement de
# noyau. La plus grande taille SOUS la marche est un reglage sur : elle ne
# franchit jamais le cout fixe, donc son seuil de non-perte reste minuscule.
steps = []
for i in range(1, len(rows)):
    lo, hi = rows[i-1], rows[i]
    if hi[1] > 1.5 * lo[1]:
        steps.append((lo[0], hi[0], hi[1] / lo[1]))
if steps:
    print("  MARCHE(S) detectee(s) — cout fixe franchi entre deux tailles :")
    for a, b, f in steps:
        print("      entre batch %d et %d : x%.2f d un coup" % (a, b, f))
    a = steps[0][0]
    print("    -> size_m %d (batch %d) reste sous la premiere marche : reglage sur," % (a - 1, a))
    print("       seuil minimal, mais gain plafonne a x%.1f." % (a / (dict((n, t) for n, t, _ in rows)[a] / t1)))
    print("    -> au-dela, il faut viser LARGE pour amortir le cout fixe : les")
    print("       tailles juste au-dessus de la marche sont les pires du lot.")
    print()

dominated = []
for i, (n, t, _) in enumerate(rows):
    if n <= 1:
        continue
    g_n, s_n = n / (t / t1), (t / t1)
    for m2, t2, _ in rows[:i]:
        if m2 > 1 and m2 / (t2 / t1) >= g_n and (t2 / t1) <= s_n:
            dominated.append((n, m2)); break
if dominated:
    print("  Tailles DOMINEES (un draft plus court fait mieux sur les deux axes,")
    print("  typiquement un palier de noyau ggml juste en dessous) :")
    for n, m2 in dominated:
        print("      size_m %d (batch %d) : size_m %d fait mieux en gain ET en seuil"
              % (n - 1, n, m2 - 1))
    print()

if best_m is None:
    print("  VERDICT : aucune taille de draft viable — courbe trop pentue,")
    print("            ne pas activer de spec-type n-gram sur ce modele.")
else:
    rel_last = env[-1][1] / t1
    print("  VERDICT : --spec-ngram-map-k-size-m %d   (batch %d, gain max x%.1f)"
          % (best_m - 1, best_m, best_gain))
    if rel_last < 1.5:
        print("            courbe PLATE (dense, borne bande passante) : aucun risque de perte.")
    else:
        print("            courbe PENTUE (MoE / mur compute) : ajouter --spec-ngram-map-k-min-hits 2")
        print("            pour eviter les faux departs qui paient le batch sans etre acceptes.")

path = os.environ.get("TSV")
if path and tsv:
    try:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write("\n".join(tsv) + "\n")
    except OSError as e:
        print("  (TSV non ecrit : %s)" % e)
' || echo "  (analyse en échec — mesures brutes conservées dans $OUT)"
  echo
 done
done
} 2>&1 | tee -a "$OUT"

echo "→ journal  : $OUT"
echo "→ mesures  : $TSV"
