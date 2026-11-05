from unittest.mock import MagicMock, patch

from fastapi.testclient import TestClient

import main

client = TestClient(main.app)


def _product(stock):
    resp = MagicMock(status_code=200)
    resp.json.return_value = {"id": "prod-1", "stock": stock}
    return resp


def test_healthz():
    assert client.get("/healthz").json()["status"] == "ok"


def test_list_orders():
    assert client.get("/orders").json()["count"] >= 1


def test_create_order_checks_stock():
    with patch.object(main.requests, "get", return_value=_product(stock=10)):
        r = client.post("/orders", json={"product_id": "prod-1", "quantity": 2, "customer": "a@b.c"})
    assert r.status_code == 201
    assert r.json()["status"] == "CONFIRMED"


def test_create_order_rejects_insufficient_stock():
    with patch.object(main.requests, "get", return_value=_product(stock=1)):
        r = client.post("/orders", json={"product_id": "prod-1", "quantity": 5, "customer": "a@b.c"})
    assert r.status_code == 400


def test_product_service_down_returns_503():
    with patch.object(main.requests, "get", side_effect=main.requests.exceptions.ConnectionError("down")):
        r = client.post("/orders", json={"product_id": "prod-1", "quantity": 1, "customer": "a@b.c"})
    assert r.status_code == 503
