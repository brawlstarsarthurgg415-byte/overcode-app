"""Smoke tests for a running Overcode Hub API."""
import json
import os
import urllib.request

BASE = os.environ.get("OVERCODE_URL", "http://127.0.0.1:8765").rstrip("/")


def get(path):
    req = urllib.request.Request(BASE + path, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=8) as response:
        assert response.status == 200
        return json.loads(response.read().decode("utf-8"))


def test_health():
    data = get("/api/v1/health")
    assert data["ok"] is True
    assert data["version"].startswith("2.")


def test_models_do_not_expose_secrets():
    data = get("/api/v1/models")
    assert isinstance(data["providers"], list)
    for provider in data["providers"]:
        assert "key" not in provider
        assert "chave" not in provider


def test_capabilities():
    data = get("/api/v1/capabilities")
    assert data["api_version"] == "v1"
    assert data["security"]["lan_requires_bearer_token"] is True


def test_openapi():
    data = get("/api/v1/openapi.json")
    assert data["openapi"].startswith("3.")
    assert "/api/v1/chat" in data["paths"]