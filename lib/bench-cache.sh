# lib/bench-cache.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-devices → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → help
# Sorti de bench.sh (trop gros). Réutilise _bench_select_one de bench.sh.

# =============================================================================
# bench-cache — efficacité du cache de prompt (cache-ram, ctx-checkpoints,
# cache-reuse, slot-prompt-similarity) sur le pattern d'un client agentic.
#
# Usage : ./setup-llm.sh --bench-cache [modèle]
#
# Quatre requêtes, dans l'ordre, sur le contexte du bench (bench-context.txt) :
#   1. froid      : contexte + tâche, max_tokens 48 — remplit le cache
#   2. suite      : même contexte, tâche allongée — le préfixe doit être servi
#                   du cache (c'est le tour suivant d'une conversation)
#   3. édition    : contexte modifié AU PREMIER TIERS, même tâche — le préfixe
#                   commun (~2/3) reste au-dessus du seuil slot-prompt-similarity
#                   (0.5 dans le [*]) ; seul ce préfixe est réutilisable par
#                   restauration d'état ; au-delà, seul cache-reuse (décalage
#                   de KV) peut récupérer la suite — impossible sur GDN/état
#                   récurrent. (Première version : édition au milieu → préfixe
#                   ~45 % < 0.5 → 0 % partout, DeepSeek compris : on mesurait
#                   le seuil, pas la réutilisation. Corrigé le 21/08/2026.)
#   4. identique  : requête 1 rejouée — cache complet attendu (moins 1 token)
# Pour chaque requête : part du prompt servie par le cache et temps de
# prefill. Journal : logs/bench-cache.log (TSV, avec build).
# =============================================================================
BENCH_CACHE_LOG="$LOG_DIR/bench-cache.log"

cmd_bench_cache() {
  local preset="${1:-}"
  command -v curl >/dev/null || error "curl introuvable"
  curl -sf "$SPEC_TEST_URL/health" >/dev/null 2>&1 \
    || error "llama-server ne répond pas sur $SPEC_TEST_URL — systemctl --user start $SERVICE_NAME"
  if [[ -z "$preset" ]]; then
    _bench_select_one
    [[ -n "$BENCH_DEV_CHOICE" ]] || { info "Rien sélectionné — bench-cache annulé."; return; }
    preset="$BENCH_DEV_CHOICE"
  fi
  [[ -n "${MODEL_INI[$preset]:-}" ]] || error "Modèle inconnu : '$preset' (voir --help)"
  local ctx="$SCRIPT_DIR/prompts/bench-context.txt" task="$SCRIPT_DIR/prompts/bench-task.txt"
  [[ -f "$ctx" && -f "$task" ]] || error "Prompts manquants : $ctx / $task"

  # Variantes écrites dans un dossier temporaire. Le contexte de base reçoit
  # une ligne d'horodatage en tête, commune aux quatre requêtes : sans elle,
  # un --bench-cache lancé juste après un --bench (même bench-context.txt)
  # trouve sa requête « froide » déjà en cache (100 % mesuré sur gpt-oss le
  # 21/08/2026). Puis : tâche allongée, contexte modifié au premier tiers (une
  # ligne remplacée, le reste intact).
  local tmp; tmp="$(mktemp -d)"
  { echo "(run --bench-cache $(date '+%F %T.%N'))"; cat "$ctx"; } > "$tmp/ctx.txt"
  ctx="$tmp/ctx.txt"
  { cat "$task"; echo ""; echo "Ajoute ensuite un paragraphe sur les limites de cette conception."; } > "$tmp/task-suite.txt"
  python3 - "$ctx" "$tmp/ctx-edit.txt" <<'PY'
import sys
lignes = open(sys.argv[1], encoding="utf-8").read().split("\n")
m = len(lignes) // 3
lignes[m] = "(ligne modifiée par --bench-cache : édition au premier tiers du contexte)"
open(sys.argv[2], "w", encoding="utf-8").write("\n".join(lignes))
PY

  info "bench-cache '$preset' — 4 requêtes sur bench-context.txt (froid, suite, édition au milieu, identique)"
  echo ""
  local -a etiq=("1. froid" "2. suite (tour suivant)" "3. édition au 1er tiers" "4. identique à la 1re")
  local -a fichiers=("$ctx $task" "$ctx $tmp/task-suite.txt" "$tmp/ctx-edit.txt $task" "$ctx $task")
  local -a parts=() pms=()
  local i body out line pn cn ms
  for i in 0 1 2 3; do
    # shellcheck disable=SC2086
    body="$(python3 "$SCRIPT_DIR/py/build_body.py" "$preset" 48 42 ${fichiers[$i]})"
    out="$(curl -s "$SPEC_TEST_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$body")" \
      || { warn "  ${etiq[$i]} : échec curl"; parts+=("-"); pms+=("-"); continue; }
    line="$(python3 "$SCRIPT_DIR/py/cache_stats.py" "$out" "${etiq[$i]}")" || true
    echo "$line" | grep -v '^PN=\|^CN=\|^PMS='
    pn="$(echo "$line" | sed -n 's/^PN=//p')"; cn="$(echo "$line" | sed -n 's/^CN=//p')"; ms="$(echo "$line" | sed -n 's/^PMS=//p')"
    if [[ "$pn" =~ ^[0-9]+$ && "$pn" -gt 0 ]]; then
      parts+=("$(awk -v c="$cn" -v p="$pn" 'BEGIN{printf "%.0f", 100*c/p}')"); pms+=("$ms")
    else
      parts+=("-"); pms+=("-")
    fi
  done
  rm -rf "$tmp"

  echo ""
  info "──── lecture ────"
  # 2 : préfixe réutilisé ? 3 : au-delà du préfixe (cache-reuse) ? 4 : tout ?
  # Mesuré le 21/08/2026 (b10433) : tous les modèles à état récurrent (GDN
  # Qwen3.5/3.6/Next, conv LFM2) plafonnent à 62-66 % au tour suivant ET à
  # l'identique, quel que soit le tokenizer ; DeepSeek (attention pure, MLA)
  # fait 99 % et 100 %. La restauration d'état des archs récurrentes ne se
  # fait qu'à un checkpoint, pas au token près : tout ce qui suit le dernier
  # checkpoint est repayé. C'est le coût de ces architectures en boucle
  # agentic, à mettre en face de leur débit.
  [[ "${parts[1]}" != "-" ]] && { if (( parts[1] >= 80 )); then info "  suite : ${parts[1]} % servi du cache — le tour suivant d'une conversation ne repaie pas le contexte."; else warn "  suite : ${parts[1]} % seulement — arch à état récurrent : restauration au dernier checkpoint, le reste est repayé (62-66 % mesuré sur GDN/conv, 99 % sur attention pure)."; fi; }
  # Édition : 0 % mesuré PARTOUT le 21/08/2026, DeepSeek (attention pure)
  # compris, avec 2/3 de préfixe commun : le cache de prompt du serveur ne sert
  # que les continuations (prompt en cache = préfixe exact du nouveau). Un
  # résultat non nul ici serait une nouveauté côté llama-server.
  [[ "${parts[2]}" != "-" ]] && { if (( parts[2] > 70 )); then info "  édition : ${parts[2]} % — au-delà du préfixe, cache-reuse récupère la suite après l'édition."; elif (( parts[2] > 0 )); then info "  édition : ${parts[2]} % — le préfixe avant l'édition est réutilisé, pas la suite."; else info "  édition : 0 % — toute modification en amont repaie tout le contexte (le cache ne sert que les continuations ; mesuré ainsi sur toutes les archs, attention pure comprise)."; fi; }
  [[ "${parts[3]}" != "-" ]] && { if (( parts[3] >= 95 )); then info "  identique : ${parts[3]} % — cache complet."; else warn "  identique : ${parts[3]} % — même une requête identique n'est pas entièrement servie : arch à état récurrent, le cache s'arrête au dernier checkpoint."; fi; }

  local dev
  dev="$(curl -s "$SPEC_TEST_URL/v1/models" 2>/dev/null \
    | python3 "$SCRIPT_DIR/py/spec_server_nmax.py" "$preset" --device 2>/dev/null || true)"
  # date modèle device build part_suite part_edit part_identique ms_froid ms_suite ms_edit ms_identique
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date '+%F %T')" "$preset" "${dev:-$DEFAULT_DEVICE}" \
    "$(_llama_build)" "${parts[1]}" "${parts[2]}" "${parts[3]}" "${pms[0]}" "${pms[1]}" "${pms[2]}" "${pms[3]}" \
    >> "$BENCH_CACHE_LOG" 2>/dev/null || true
}
