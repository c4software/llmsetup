# lib/service.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → ini → preload → setup → bench → spec → service → help

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
# Service systemd système
# =============================================================================


cmd_install_service() {
  info "Génération du service systemd système..."

  local script_path
  script_path="$(realpath "$0")"

  # GGML_CUDA_ENABLE_UNIFIED_MEMORY=1 : sans effet côté Vulkan, nécessaire côté
  # ROCm/HIP sur iGPU (alloc en mémoire unifiée/GTT au lieu de la VRAM dédiée) —
  # posé d'office pour que la bascule d'un modèle en ROCm0 ne demande pas de
  # retoucher le service.
  sudo tee "$SERVICE_FILE" > /dev/null << SERVICE
[Unit]
Description=llama-server — LLM router mode natif
After=network.target

[Service]
Type=simple
User=$USER
Group=$(id -gn)
ExecStart=${script_path} --start
Restart=on-failure
RestartSec=5
StandardOutput=journal
StandardError=journal
Environment="PATH=$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin"
Environment="HOME=$HOME"
Environment="GGML_CUDA_ENABLE_UNIFIED_MEMORY=1"

[Install]
WantedBy=multi-user.target
SERVICE

  sudo systemctl daemon-reload
  sudo systemctl enable "$SERVICE_NAME"

  info "✅ Service installé : $SERVICE_FILE"
  info "  Démarrage automatique au boot activé (multi-user.target)"
  info "Commandes utiles :"
  info "  sudo systemctl start   $SERVICE_NAME"
  info "  sudo systemctl stop    $SERVICE_NAME"
  info "  sudo systemctl restart $SERVICE_NAME"
  info "  sudo systemctl status  $SERVICE_NAME"
  info "  journalctl -u $SERVICE_NAME -f"
}

cmd_uninstall_service() {
  if ! systemctl is-enabled "$SERVICE_NAME" &>/dev/null; then
    warn "Service '$SERVICE_NAME' non installé, rien à faire."
    return
  fi

  sudo systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  sudo systemctl disable "$SERVICE_NAME"
  sudo rm -f "$SERVICE_FILE"
  sudo systemctl daemon-reload

  info "✅ Service '$SERVICE_NAME' désinstallé."
}
