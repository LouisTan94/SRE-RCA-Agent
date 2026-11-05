import os
import logging
import httpx
from fastapi import FastAPI
from fastapi.responses import HTMLResponse

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s")
logger = logging.getLogger("ui")

app = FastAPI(title="Platform UI")

PRODUCT_SVC = os.getenv("PRODUCT_SERVICE_URL", "http://product-service.apps.svc.cluster.local:8000")
ORDER_SVC   = os.getenv("ORDER_SERVICE_URL",   "http://order-service.apps.svc.cluster.local:8000")


async def fetch(url: str):
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            r = await client.get(url)
            r.raise_for_status()
            return r.json(), None
    except Exception as e:
        return None, str(e)


@app.get("/healthz")
def healthz():
    return {"status": "ok", "service": "ui"}


@app.get("/", response_class=HTMLResponse)
async def dashboard():
    products, p_err = await fetch(f"{PRODUCT_SVC}/products")
    orders,   o_err = await fetch(f"{ORDER_SVC}/orders")

    def badge(err):
        return '<span style="color:#e74c3c">&#x2717; unreachable</span>' if err else \
               '<span style="color:#27ae60">&#x2713; healthy</span>'

    product_rows = ""
    if products:
        for p in products.get("products", []):
            product_rows += f"""
            <tr>
              <td>{p['id']}</td>
              <td>{p['name']}</td>
              <td>${p['price']:.2f}</td>
              <td>{p['stock']}</td>
            </tr>"""
    else:
        product_rows = f'<tr><td colspan="4" style="color:#e74c3c">{p_err}</td></tr>'

    order_rows = ""
    if orders:
        for o in orders.get("orders", []):
            order_rows += f"""
            <tr>
              <td>{o.get('id','—')}</td>
              <td>{o.get('product_id','—')}</td>
              <td>{o.get('quantity','—')}</td>
              <td>{o.get('status','—')}</td>
            </tr>"""
    else:
        order_rows = f'<tr><td colspan="4" style="color:#e74c3c">{o_err}</td></tr>'

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta http-equiv="refresh" content="15">
  <title>Platform Dashboard</title>
  <style>
    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif;
            background: #0f1117; color: #e0e0e0; padding: 2rem; }}
    h1   {{ font-size: 1.6rem; margin-bottom: 0.25rem; color: #fff; }}
    .sub {{ color: #888; font-size: 0.85rem; margin-bottom: 2rem; }}
    .grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 1.5rem; }}
    .card {{ background: #1a1d27; border-radius: 10px; padding: 1.5rem;
             border: 1px solid #2a2d3a; }}
    .card h2 {{ font-size: 1rem; margin-bottom: 0.4rem; color: #aaa; text-transform: uppercase;
                letter-spacing: .05em; }}
    .status {{ margin-bottom: 1rem; font-size: 0.9rem; }}
    table {{ width: 100%; border-collapse: collapse; font-size: 0.85rem; }}
    th    {{ text-align: left; padding: 0.5rem; background: #22263a; color: #aaa;
             border-bottom: 1px solid #2a2d3a; }}
    td    {{ padding: 0.5rem; border-bottom: 1px solid #1e2130; }}
    tr:hover td {{ background: #22263a; }}
    .links {{ margin-top: 2rem; font-size: 0.82rem; color: #666; }}
    .links a {{ color: #5b8af7; text-decoration: none; margin-right: 1.5rem; }}
    .links a:hover {{ text-decoration: underline; }}
  </style>
</head>
<body>
  <h1>&#127758; Platform Dashboard</h1>
  <p class="sub">Auto-refreshes every 15 s &nbsp;|&nbsp; Deployed via ArgoCD GitOps</p>

  <div class="grid">
    <div class="card">
      <h2>Product Service</h2>
      <div class="status">{badge(p_err)}</div>
      <table>
        <thead><tr><th>ID</th><th>Name</th><th>Price</th><th>Stock</th></tr></thead>
        <tbody>{product_rows}</tbody>
      </table>
    </div>

    <div class="card">
      <h2>Order Service</h2>
      <div class="status">{badge(o_err)}</div>
      <table>
        <thead><tr><th>ID</th><th>Product</th><th>Qty</th><th>Status</th></tr></thead>
        <tbody>{order_rows}</tbody>
      </table>
    </div>
  </div>

  <div class="links">
    <a href="/docs">API docs</a>
    <a href="http://localhost:8090" target="_blank">ArgoCD</a>
    <a href="http://localhost:3000" target="_blank">Gitea</a>
    <a href="http://localhost:8080/docs" target="_blank">SRE Agent</a>
    <a href="http://localhost:8025" target="_blank">Mailpit</a>
  </div>
</body>
</html>"""
