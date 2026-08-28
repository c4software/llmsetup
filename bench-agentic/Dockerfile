# pi (pi.dev) jetable pour --bench-agentic : tape llama-server EN DIRECT
# (réseau hôte, 127.0.0.1:8009), sans proxy. Sa configuration est générée
# au démarrage dans PI_CODING_AGENT_DIR, à l'intérieur du conteneur :
# ~/.pi de l'hôte n'est jamais lu ni écrit. curl sert à lire /metrics.
FROM node:22-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && npm install -g --ignore-scripts @earendil-works/pi-coding-agent \
 && mkdir -p /work /pi && chown node:node /work /pi
USER node
WORKDIR /work
ENV PI_CODING_AGENT_DIR=/pi/agent
COPY --chown=node:node entrypoint.sh scenarios.sh ./
ENTRYPOINT ["./entrypoint.sh"]
CMD ["./scenarios.sh"]
