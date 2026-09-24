# lib/service.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → svc → models → ini → compose → preload → setup → runtime → bench → bench-parallel → bench-cache → bench-load → bench-agentic → spec → service → gufo → help

# =============================================================================
# Sortie de systemd - commande de bascule, TEMPORAIRE
#
# Le service n'est plus une unité systemd user : c'est un conteneur décrit par
# runtime/docker-compose.yml (valeurs machine dans ~/models/.env, lib/compose.sh)
# et piloté par les _svc_*
# (lib/svc.sh). Il ne reste ici que la commande qui débranche l'ancienne unité
# sur une machine qui l'avait installée - elle sera retirée du dépôt quand le
# parc sera passé.
#
# Ce qui a disparu avec l'unité : cmd_install_service / cmd_uninstall_service,
# le linger (le démon docker démarre au boot, c'est lui qui relance le
# conteneur grâce à restart: unless-stopped) et le PATH de l'unité, qui mettait
# en tête les liens du fork strix-llama.cpp : le moteur vit dans l'image, et le
# fork a été retiré du dépôt le 18/09/2026.
# =============================================================================

# cmd_migrate_off_systemd - débranche l'unité systemd user, dans l'ordre :
# arrêt, désactivation, suppression du fichier d'unité, daemon-reload, puis
# contrôle que le port du routeur est bien libre avant de rendre la main.
# Le signalement des liens llama-* de l'hôte est tombé le 18/09/2026 avec le
# fork : le dépôt n'en pose plus et n'en lit plus.
# Idempotente : une machine sans unité la traverse sans rien casser.
cmd_migrate_off_systemd() {
  info "Sortie de systemd pour $SERVICE_NAME..."

  if command -v systemctl >/dev/null 2>&1; then
    # Aucun de ces appels n'est fatal : l'unité peut être déjà arrêtée, déjà
    # désactivée, ou n'avoir jamais existé (machine neuve, ou commande rejouée).
    systemctl --user stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
    info "  unité arrêtée et désactivée (si elle existait)."
  else
    warn "  systemctl introuvable - aucune unité à débrancher ici."
  fi

  if [[ -f "$SERVICE_FILE" ]]; then
    rm -f "$SERVICE_FILE"
    info "  unité supprimée : $SERVICE_FILE"
  else
    info "  aucune unité à supprimer ($SERVICE_FILE absent)."
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
  fi

  # Le port doit être libre avant --start : un llama-server survivant ferait
  # échouer la publication de port du conteneur, sur un message docker qui ne
  # dit pas qui occupe la place.
  # Pas de « ss | grep -q » : sous pipefail, grep -q sort au 1er match et ss
  # meurt sur EPIPE (141), ce qui rendrait le contrôle faussement négatif.
  if command -v ss >/dev/null 2>&1; then
    local occupe
    occupe="$(ss -ltn 2>/dev/null | grep -E "[:.]$SERVER_PORT[[:space:]]" || true)"
    if [[ -n "$occupe" ]]; then
      warn "  ⚠ le port $SERVER_PORT est ENCORE occupé :"
      sed 's/^/      /' <<<"$occupe"
      warn "    Un llama-server a survécu à l'arrêt de l'unité : le terminer avant --start."
    else
      info "  port $SERVER_PORT libre."
    fi
  else
    warn "  ss introuvable - port $SERVER_PORT non vérifié."
  fi

  echo ""
  info "✅ Migration faite. Démarrer le service conteneurisé : ./setup-llm.sh --start"
  return 0
}
