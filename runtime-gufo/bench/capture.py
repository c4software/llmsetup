#!/usr/bin/env python3
# Relais d'enregistrement pour les bancs de gufo : écoute en local, transmet
# tel quel au serveur du port 8009 (gufo ou le service) et garde le corps de
# chaque POST dans un JSONL ({"path", "body"}), une ligne par requête. Sert à
# obtenir l'enveloppe EXACTE d'un client (prompt système, outils, paramètres :
# pi n'envoie aucun paramètre d'échantillonnage) pour la rejouer ensuite avec
# bench/rejeu.py (docs/HISTORIQUE-GUFO.md, gufo#388).
#
# Usage :
#   runtime-gufo/bench/capture.py <sortie.jsonl> [port d'écoute, défaut 8019]
#   puis le client sur http://127.0.0.1:8019, par exemple une passe de pi :
#   MODEL=qwen3.8-flash-next PASSES=1 FROID=0 SERVER_URL=http://127.0.0.1:8019 \
#     docker compose -f bench-agentic/docker-compose.yml run --rm -T pi
#
# Les réponses en flux (SSE) passent au fil de l'eau. Corps en morceaux
# (Transfer-Encoding: chunked) recomposé avant transmission. Pour l'arrêter,
# passer par son port (ss -ltnp | grep :8019, puis kill du pid) : un pkill -f
# ou un pgrep -f sur son nom atteint aussi le shell ssh qui porte la commande.
import http.client, http.server, json, sys

SORTIE = sys.argv[1]
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8019
CIBLE = ("127.0.0.1", 8009)


class Relais(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def _relayer(self, corps=None):
        c = http.client.HTTPConnection(*CIBLE, timeout=3600)
        entetes = {k: v for k, v in self.headers.items() if k.lower() not in ("host", "connection")}
        c.request(self.command, self.path, body=corps, headers=entetes)
        r = c.getresponse()
        self.send_response(r.status)
        for k, v in r.getheaders():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Connection", "close")
        self.end_headers()
        while True:
            bloc = r.read1(65536)
            if not bloc:
                break
            self.wfile.write(bloc)
            self.wfile.flush()
        c.close()

    def do_GET(self):
        self._relayer()

    def do_POST(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            corps = b""
            while True:
                n = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if n == 0:
                    self.rfile.readline()
                    break
                corps += self.rfile.read(n)
                self.rfile.readline()
            del self.headers["Transfer-Encoding"]
            self.headers["Content-Length"] = str(len(corps))
        else:
            corps = self.rfile.read(int(self.headers.get("Content-Length", 0)))
        with open(SORTIE, "a") as f:
            f.write(json.dumps({"path": self.path, "body": json.loads(corps)}, ensure_ascii=False) + "\n")
        self._relayer(corps)

    def log_message(self, *a):
        pass


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Relais).serve_forever()
