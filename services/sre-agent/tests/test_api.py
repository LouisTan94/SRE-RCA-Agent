import pytest
from fastapi.testclient import TestClient

import agent
import app

client = TestClient(app.app)


@pytest.fixture
def oomkilled_pod(monkeypatch):
    """Pretend the cluster has one OOMKilled product-service pod."""
    monkeypatch.setattr(agent, "scan_cluster_for_issues",
                        lambda: [{"namespace": "apps", "pod": "product-service-7d9f-abcde"}])
    monkeypatch.setattr(agent, "describe_pod",
                        lambda ns, pod: {"containers": [{"last_terminated": {"reason": "OOMKilled", "exit_code": 137}}]})
    monkeypatch.setattr(agent, "get_events", lambda ns, limit=20: [])
    monkeypatch.setattr(agent, "get_pod_logs", lambda ns, pod, tail_lines=50, previous=False: "allocating...")


def test_healthz():
    assert client.get("/healthz").json()["status"] == "ok"


def test_rca_requires_api_key():
    assert client.post("/rca", json={"question": "x"}).status_code == 401
    assert client.post("/rca", headers={"x-api-key": "wrong"}, json={"question": "x"}).status_code == 401


def test_rule_based_rca_is_labelled_and_not_overconfident(oomkilled_pod):
    r = client.post("/rca", headers={"x-api-key": "test-key"}, json={"question": "why"})
    assert r.status_code == 200
    rca = r.json()["rca"]
    assert rca["title"].startswith("[Rule-based]")
    assert "OOMKilled" in rca["title"]
    assert rca["confidence"] != "high"
    assert rca["affected_services"] == ["product-service"]


def test_latest_report_renders(oomkilled_pod):
    client.post("/rca", headers={"x-api-key": "test-key"}, json={"question": "why"})
    assert "<html" in client.get("/rca/latest").text.lower()
