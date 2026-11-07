"""Cliente Python pequeno para a API Overcode Hub v1."""
from __future__ import annotations
import json
import urllib.request
import urllib.error


class OvercodeError(RuntimeError):
    pass


class Overcode:
    def __init__(self, base_url="http://127.0.0.1:8765", token=None, timeout=30):
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.timeout = timeout

    def request(self, path, data=None):
        headers = {"Accept": "application/json"}
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(data).encode("utf-8")
        if self.token:
            headers["Authorization"] = "Bearer " + self.token
        req = urllib.request.Request(self.base_url + path, data=body, headers=headers,
                                     method="POST" if data is not None else "GET")
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as response:
                return json.loads(response.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            detail = exc.read(2000).decode("utf-8", "replace")
            raise OvercodeError(f"HTTP {exc.code}: {detail}") from exc
        except (urllib.error.URLError, TimeoutError) as exc:
            raise OvercodeError(f"Não foi possível alcançar o Overcode Hub: {exc}") from exc

    def health(self):
        return self.request("/api/v1/health")

    def state(self):
        return self.request("/api/v1/state")

    def models(self):
        return self.request("/api/v1/models")

    def capabilities(self):
        return self.request("/api/v1/capabilities")

    def chat(self, message, session_id=None):
        payload = {"message": message}
        if session_id:
            payload["session_id"] = session_id
        return self.request("/api/v1/chat", payload)

    def sessions(self):
        return self.request("/api/v1/sessions")

    def terminal(self, command):
        return self.request("/api/v1/terminal", {"command": command})

    def set_mode(self, mode, custom_plan=None):
        payload = {"mode": mode}
        if custom_plan is not None:
            payload["custom_plan"] = custom_plan
        return self.request("/api/v1/mode", payload)