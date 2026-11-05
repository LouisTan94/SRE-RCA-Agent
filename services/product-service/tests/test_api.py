from fastapi.testclient import TestClient

from main import app

client = TestClient(app)


def test_healthz():
    assert client.get("/healthz").json()["status"] == "ok"


def test_list_products():
    body = client.get("/products").json()
    assert len(body["products"]) >= 1


def test_get_product():
    assert client.get("/products/prod-1").json()["id"] == "prod-1"


def test_unknown_product_is_404():
    assert client.get("/products/nope").status_code == 404
