#!/usr/bin/env python3
"""Подставной GPUStack: проверка монитора без корпоративной сети.

Живой шлюз для проверки не годится: он то есть, то нет, а поведение, которое надо
проверить, — редкое. Здесь оно задано нарочно, и каждый вид отвечает так, как отвечал
настоящий, включая три разные формы 404 и модель, которая молча думает.

  python3 Tests/mock_gpustack.py 8799
"""
import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MODELS = {
    "чат-быстрый":      "chat",
    "чат-медленный":    "chat",
    "эмбеддинги":       "embedding",
    "реранкер":         "rerank",
    "сломанный-шаблон": "refuse",     # отвечает и отказывает: HTTP 400
    "картинки":         "hang",       # принимает запрос и «рисует»
    "распознавание":    "other404",   # третья форма 404, как у whisper
}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a): pass

    def send(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self.send(200, {"object": "list", "data": [
                {"id": m, "object": "model", "created": 1770000000, "owned_by": "gpustack"}
                for m in MODELS]})
        if self.path.rstrip("/").endswith("/version"):
            return self.send(200, {"version": "v2.2.2-подстава"})
        self.send(404, {"detail": "Not Found"})

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        try:
            req = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            req = {}
        model = req.get("model", "")
        kind = MODELS.get(model)
        if kind is None:
            return self.send(404, {"error": {"message": "Model not found", "code": 404}})
        want = ("chat" if self.path.endswith("/chat/completions")
                else "embedding" if self.path.endswith("/embeddings")
                else "rerank" if self.path.endswith("/rerank") else "?")

        if kind == "hang":
            time.sleep(40)                      # держит соединение, как генератор картинок
            return self.send(200, {"ok": True})
        if kind == "other404":
            return self.send(404, {"message": "API endpoint not found"})
        if kind == "refuse":
            if want != "chat":
                return self.send(404, {"detail": "Not Found"})
            return self.send(400, {"error": {"message": "default chat template is no longer allowed"}})
        if kind != want:
            return self.send(404, {"detail": "Not Found"})
        if model == "чат-медленный":
            time.sleep(3)
        return self.send(200, {"object": "ok", "model": model,
                               "choices": [{"message": {"content": "."}}]})


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8799
    # Потоки обязательны: «картинки» держат соединение сорок секунд, и на
    # однопоточном сервере за ними встаёт очередь — остальные модели начинают
    # «молчать», хотя отвечают мгновенно. Первый же прогон так и соврал.
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
