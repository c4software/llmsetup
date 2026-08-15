# lib/help.sh — sourcé par setup-llm.sh (ne pas exécuter directement)
# Ordre de source : common → models → presets → ini → preload → setup → bench → spec → service → help

# =============================================================================
# help
# =============================================================================

cmd_help() {
  cat <<HELP
setup-llm.sh — llama-server en router mode natif (Strix Halo, Vulkan/ROCm)

Usage : ./setup-llm.sh [commande] [options]

Commandes :
  --setup                  Installe les dépendances (paru), propose le runtime ROCm
                           + ggml-hip, télécharge les GGUF manquants, sélection
                           interactive du préchargement, génère $CONFIG_DIR/models.ini
  --update [modèle]        Comme --setup mais laisse hf comparer les etags et ne
                           retélécharge que ce qui a bougé en amont
                           (modèle = dossier sous $MODELS_BASE, ex. qwen3.8-27b)
  --cleanup [--yes]        Supprime dossiers/GGUF orphelins (plus dans KNOWN_FILES).
                           Dry-run par défaut, --yes pour exécuter
  --preload                Re-sélectionne les modèles préchargés (always-on) et
                           régénère models.ini (--models-max = nb préchargés + 1)
  --bench [modèle|all] [n] Perfs du serveur tel qu'il tourne : n passes (défaut 3)
                           par modèle, long préfixe de remplissage (passe 1) +
                           décode et acceptance MTP médians, tableau récapitulatif.
                           Pas de restart, rien d'écrit. Sans argument : sélection
                           interactive
  --list-devices           Backends ggml installés + devices exposés par llama-bench,
                           croisés avec bench-devices.conf (alerte si device disparu)
  --spec-test [modèle] [n] Mesure le décode réel via l'API (spéculation incluse) :
                           n passes du même prompt code, prompt/gen t/s, acceptance
                           MTP + médianes (seed fixe/passe, 4 passes par défaut).
                           Journalise (quarantaine auto des runs incohérents),
                           et dès 2 n-max mesurés : prédit la courbe, choisit la
                           cible et l'écrit dans spec-nmax.conf (ini régénéré,
                           restart proposé).
  --spec-tune [modèle] [k1,k2,..] [n]
                           Boucle automatique : pour chaque n-max (défaut 2,4,6),
                           ini régénéré + restart + spec-test ; retient le meilleur
                           mesuré (à <2 %, le plus petit), l'écrit dans
                           spec-nmax.conf (surcharge du défaut script), restart final.
                           sudo requis (restarts du service système entre les n-max)
                           Sans modèle : choix interactif parmi les MTP présents.
                           3 passes par défaut. Sert à régler
                           spec-draft-n-max (éditer le script, --preload, re-tester)
  --start                  Lance llama-server sur :8009 (défaut sans argument)
  --install-service        Installe/active le service systemd $SERVICE_NAME
  --uninstall-service      Arrête, désactive et supprime le service
  --help, -h               Cette aide

Fichiers (à côté du script, versionnables) :
  bench-devices.conf       clé (dossier GGUF) = device (Vulkan0/ROCm0), édition manuelle
  preload.conf             modèles préchargés, un par ligne
  spec-tests.log           journal des --spec-test (TSV), base de l'analyse n-max
  spec-nmax.conf           modèle = spec-draft-n-max retenu par --spec-tune
Fichiers ($CONFIG_DIR) :
  models.ini               généré — ne pas éditer à la main, relancer --preload/--bench

Workflow typique :
  ./setup-llm.sh --setup && ./setup-llm.sh --install-service
  sudo systemctl start $SERVICE_NAME ; journalctl -u $SERVICE_NAME -f
  ./setup-llm.sh --bench all          # perfs de tous les modèles présents
  ./setup-llm.sh --update qwen3.8-27b # après un re-upload unsloth
  ./setup-llm.sh --spec-test          # décode réel d'un modèle MTP (choix interactif)
  ./setup-llm.sh --spec-tune          # règle spec-draft-n-max tout seul (2,4,6)

Modèles (models.ini, ${#PRESET_ORDER[@]}) :
$(printf '  %s\n' "${PRESET_ORDER[@]}")
Clés modèles (--update / --bench) :
$(for f in "${KNOWN_FILES[@]}"; do _key "$f"; done | sort -u | sed 's/^/  /')
HELP
}
