"""Unit tests for the Python API."""
import os
from unittest.mock import patch
from fastapi.testclient import TestClient
from src.main import app

client = TestClient(app)


def test_root_returns_service_info():
    resp = client.get("/")
    assert resp.status_code == 200
    body = resp.json()
    assert body["service"] == "python-api"
    assert body["message"] == "Hello from Python!"
    assert "host" in body
    assert "vault_injected" in body


def test_root_vault_injected_false_when_missing():
    resp = client.get("/")
    body = resp.json()
    assert body["vault_injected"] is False


def test_root_vault_injected_true_when_present(tmp_path):
    secret_file = tmp_path / "config"
    secret_file.write_text("key=value")
    with patch("src.main.os.path.exists", side_effect=lambda p: p == "/vault/secrets/config" or os.path.exists(p)):
        resp = client.get("/")
        # The mock makes os.path.exists return True for the vault path
    body = resp.json()
    assert body["vault_injected"] is True


def test_health_endpoint():
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json() == {"status": "healthy"}
