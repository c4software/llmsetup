# pi (pi.dev) jetable pour --bench-agentic : tape llama-server EN DIRECT
# (réseau hôte, 127.0.0.1:8009), sans proxy. Sa configuration est générée
# au démarrage dans PI_CODING_AGENT_DIR, à l'intérieur du conteneur :
# ~/.pi de l'hôte n'est jamais lu ni écrit. curl sert à lire /metrics.
# pi épinglé : celui de toutes les mesures depuis le 22/09/2026 (image
# construite ce jour-là). Sans version, une reconstruction installait la
# dernière (0.99.2 le 01/10/2026) et cassait la comparaison des runs.
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --ignore-scripts @earendil-works/pi-coding-agent@0.87.0 \
 && mkdir -p /work /pi && chown node:node /work /pi
USER node
WORKDIR /work
ENV PI_CODING_AGENT_DIR=/pi/agent
COPY --chown=node:node entrypoint.sh scenarios.sh ./
ENTRYPOINT ["./entrypoint.sh"]
CMD ["./scenarios.sh"]
