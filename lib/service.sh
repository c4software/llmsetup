# lib/service.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → bench-agentic → spec → service → help

# =============================================================================
# start
# =============================================================================

cmd_start() {
  export PATH="$HOME/.local/bin:$PATH"
  command -v llama-server >/dev/null || error "llama-server introuvable"
  [[ -f "$CONFIG_DIR/models.ini" ]] || error "Config introuvable — lance d'abord --setup"

  # --models-max dérivé de preload.conf : nb de modèles préchargés + 1 slot
  #   LRU pour le modèle appelé à la demande (minimum 2).
  load_preload_conf
  local models_max=$(( ${#PRELOADED[@]} + 1 ))
  (( models_max < 2 )) && models_max=2

  info "Lancement de llama-server (router mode) sur :$SERVER_PORT..."
  info "  Préchargés : $(_preload_summary) — models-max=$models_max"

  # --models-autoload : désormais activé par défaut côté llama-server, gardé
  #   explicite par lisibilité.
  # WebUI disponible sur http://0.0.0.0:<SERVER_PORT>
  llama-server \
    --host 0.0.0.0 \
    --port "$SERVER_PORT" \
    --models-preset "$CONFIG_DIR/models.ini" \
    --models-max "$models_max" \
    --models-autoload \
    --jinja
}

# =============================================================================
# Service systemd USER — piloté par systemctl --user.
# loginctl enable-linger : les services user de ce compte démarrent au boot,
# sans session ouverte (polkit autorise le linger sur son propre compte).
# =============================================================================

cmd_install_service() {
  info "Génération du service systemd user..."

  local script_path
  script_path="$(realpath "$0")"

  # GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 : sans effet côté Vulkan, nécessaire côté
  # ROCm/HIP sur iGPU (alloc en mémoire unifiée/GTT au lieu de la VRAM dédiée) —
  # posé d'office pour que la bascule d'un modèle en ROCm0 ne demande pas de
  # retoucher le service.
  mkdir -p "$(dirname "$SERVICE_FILE")"
  cat > "$SERVICE_FILE" << SERVICE
[Unit]
Description=llama-server — LLM router mode natif
After=network.target

[Service]
Type=simple
ExecStart=${script_path} --start
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment="PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="GGML_CUDA_ENABLE_UNIFIED_MEMORY=1"

[Install]
WantedBy=default.target
SERVICE

  systemctl --user daemon-reload
  systemctl --user enable "$SERVICE_NAME"
  # linger : sans lui, les services user ne démarrent qu'à l'ouverture de
  # session (et s'arrêtent à la fermeture) — indispensable pour un serveur
  if loginctl enable-linger "$USER" 2>/dev/null; then
    info "  Linger activé : le service démarre au boot, sans session ouverte."
  else
    warn "  loginctl enable-linger a échoué — le service ne démarrera qu'à l'ouverture"
    warn "  de session. Activer à la main : sudo loginctl enable-linger $USER"
  fi

  info "✅ Service installé : $SERVICE_FILE"
  info "Commandes utiles :"
  info "  systemctl --user start   $SERVICE_NAME"
  info "  systemctl --user stop    $SERVICE_NAME"
  info "  systemctl --user restart $SERVICE_NAME"
  info "  systemctl --user status  $SERVICE_NAME"
  info "  journalctl --user -u $SERVICE_NAME -f"
}

cmd_uninstall_service() {
  if ! systemctl --user is-enabled "$SERVICE_NAME" &>/dev/null && [[ ! -f "$SERVICE_FILE" ]]; then
    warn "Service '$SERVICE_NAME' non installé, rien à faire."
    return
  fi
  systemctl --user disable --now "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl --user daemon-reload
  info "✅ Service user '$SERVICE_NAME' désinstallé."
}
