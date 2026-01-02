import os
from fastapi import FastAPI, Request, Form
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from fastapi.templating import Jinja2Templates
import httpx
from dotenv import load_dotenv

load_dotenv()
ENGINE_URL = os.getenv("ENGINE_URL", "http://localhost:8002")

app = FastAPI(title="Genius Portfolio Gateway")
os.makedirs("frontend/static", exist_ok=True)
app.mount("/static", StaticFiles(directory="frontend/static"), name="static")
templates = Jinja2Templates(directory="frontend/templates")

@app.get("/", response_class=HTMLResponse)
async def index(request: Request):
    # Fetch live stats from backend to show "System Health"
    system_status = {"status": "Offline", "db": "Unknown"}
    try:
        async with httpx.AsyncClient(timeout=2.0) as client:
            resp = await client.get(f"{ENGINE_URL}/health")
            if resp.status_code == 200:
                system_status = resp.json()
    except:
        pass

    return templates.TemplateResponse("index.html", {
        "request": request,
        "system": system_status
    })

@app.post("/contact")
async def contact_form(request: Request, name: str = Form(...), email: str = Form(...), message: str = Form(...)):
    try:
        async with httpx.AsyncClient() as client:
            await client.post(f"{ENGINE_URL}/contact", json={"name": name, "email": email, "message": message})
        return templates.TemplateResponse("index.html", {
            "request": request,
            "success": True,
            "system": {"status": "Online", "db": "Connected"}
        })
    except:
        return templates.TemplateResponse("index.html", {
            "request": request,
            "error": "Backend Service Unavailable",
            "system": {"status": "Degraded"}
        })

@app.get("/admin", response_class=HTMLResponse)
async def admin_panel(request: Request):
    # In a real app, add @auth_required here
    messages = []
    try:
        async with httpx.AsyncClient() as client:
            resp = await client.get(f"{ENGINE_URL}/messages")
            if resp.status_code == 200:
                messages = resp.json()
    except:
        pass

    return templates.TemplateResponse("admin.html", {
        "request": request,
        "messages": messages,
        "viewer_count": 124  # Mock count, or fetch from Redis if implemented
    })
