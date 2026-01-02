#!/usr/bin/env bash
set -euo pipefail

REPO=geniusmachado
rm -rf "$REPO"
mkdir -p "$REPO"

echo "🚀 Building Genius Machado V27.2 (Fixes & Content)..."

cat > "$REPO/README.md" <<'MD'
# Genius Machado — Full Stack Portfolio

## 👨‍💻 About This System
This website is not just a static page. It is a live demonstration of my engineering capabilities.
- **Architecture**: Microservices (FastAPI Gateway + Logic Engine).
- **Infrastructure**: Docker Containers, Nginx (via Gateway), Cloudflare Tunnel.
- **Database**: MySQL (Persistent storage for contact submissions).
- **Frontend**: Server-Side Rendered Jinja2 with Tailwind CSS.

## 🛠 Tech Stack Displayed
- Python (FastAPI, Django, Flask)
- Cloud (AWS: EC2, Lambda, S3, DynamoDB, Redshift | Azure)
- DevOps (Docker, Kubernetes, Terraform, Jenkins, GitHub Actions)
- Data Engineering (Airflow, Spark, Kafka, Snowflake)

## ⚡ Setup
1. Add Cloudflare Token to `docker-compose.yml`.
2. Add `profile.jpg` to `frontend/static/images/`.
3. Run `docker compose up --build`.
MD

# -------------------------
# Docker Compose
# -------------------------
cat > "$REPO/docker-compose.yml" <<'YML'
version: '3.8'
services:
  db:
    image: mysql:8.0
    environment:
      MYSQL_ROOT_PASSWORD: rootpass
      MYSQL_DATABASE: portfolio
      MYSQL_USER: genius
      MYSQL_PASSWORD: geniuspass
    volumes:
      - db_data:/var/lib/mysql
    ports:
      - "3306:3306"
    healthcheck:
      test: ["CMD", "mysqladmin", "ping", "-h", "localhost"]
      timeout: 20s
      retries: 10

  api-gateway:
    build: ./api-gateway
    restart: on-failure
    environment:
      GATEWAY_HOST: api-gateway
      ENGINE_URL: http://portfolio-engine:8002
    volumes:
      - ./api-gateway:/app
      - ./frontend:/app/frontend:ro
    depends_on:
      - portfolio-engine
    ports:
      - "8000:8000"

  portfolio-engine:
    build: ./portfolio-engine
    volumes:
      - ./portfolio-engine:/app
    environment:
      DATABASE_URL: mysql+aiomysql://genius:geniuspass@db:3306/portfolio
    depends_on:
      db:
        condition: service_healthy
    ports:
      - "8002:8002"

  tunnel:
    image: cloudflare/cloudflared:latest
    restart: always
    command: tunnel run
    environment:
      - TUNNEL_TOKEN=PASTE_YOUR_DOCKER_CLOUDFLARE_TUNNEL_TOKEN_HERE
    depends_on:
      - api-gateway

volumes:
  db_data:
YML

# -------------------------
# API GATEWAY (Frontend Handler)
# -------------------------
mkdir -p "$REPO/api-gateway"

cat > "$REPO/api-gateway/pyproject.toml" <<'TOML'
[project]
name = "api-gateway"
version = "0.27.2"
requires-python = ">=3.11"
dependencies = [
    "fastapi>=0.109.0",
    "uvicorn[standard]>=0.27.0",
    "jinja2>=3.1.3",
    "httpx>=0.26.0",
    "python-dotenv>=1.0.0",
    "python-multipart>=0.0.7"
]
TOML

cat > "$REPO/api-gateway/Dockerfile" <<'DF'
FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8000
CMD ["uv", "run", "uvicorn", "gateway:app", "--host", "0.0.0.0", "--port", "8000", "--reload"]
DF

cat > "$REPO/api-gateway/gateway.py" <<'PY'
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
PY

# -------------------------
# PORTFOLIO ENGINE (Logic & DB)
# -------------------------
mkdir -p "$REPO/portfolio-engine"
cat > "$REPO/portfolio-engine/pyproject.toml" <<'TOML'
[project]
name = "portfolio-engine"
version = "0.27.2"
requires-python = ">=3.11"
dependencies = [
    "fastapi", "uvicorn[standard]", "sqlalchemy", "aiomysql", "pydantic", "python-dotenv", "cryptography"
]
TOML

cat > "$REPO/portfolio-engine/Dockerfile" <<'DF'
FROM python:3.11-slim
COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /bin/
WORKDIR /app
COPY pyproject.toml .
RUN uv pip install --system --no-cache -r pyproject.toml
COPY . .
EXPOSE 8002
CMD ["uv", "run", "uvicorn", "engine:app", "--host", "0.0.0.0", "--port", "8002", "--reload"]
DF

cat > "$REPO/portfolio-engine/engine.py" <<'PY'
from fastapi import FastAPI
from pydantic import BaseModel
from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
from sqlalchemy import MetaData, Table, Column, Integer, String, Text, DateTime, insert
from sqlalchemy.sql import func
from sqlalchemy.orm import sessionmaker
import os
from dotenv import load_dotenv

load_dotenv()
DATABASE_URL = os.getenv("DATABASE_URL")
# Add connect_args to handle cryptic auth issues if needed, but cryptography pkg is usually enough
engine = create_async_engine(DATABASE_URL, echo=False)
AsyncSessionLocal = sessionmaker(engine, expire_on_commit=False, class_=AsyncSession)
metadata = MetaData()

messages = Table("messages", metadata,
    Column("id", Integer, primary_key=True),
    Column("name", String(255)),
    Column("email", String(255)),
    Column("message", Text),
    Column("created_at", DateTime, server_default=func.now())
)

app = FastAPI()

@app.on_event("startup")
async def startup():
    async with engine.begin() as conn: await conn.run_sync(metadata.create_all)

class ContactReq(BaseModel):
    name: str
    email: str
    message: str

@app.get("/health")
async def health():
    try:
        async with AsyncSessionLocal() as session:
            await session.execute(messages.select().limit(1))
        return {"status": "Operational", "db": "Connected", "version": "v27.2.0"}
    except:
        return {"status": "Degraded", "db": "Disconnected", "version": "v27.2.0"}

@app.post("/contact")
async def contact(req: ContactReq):
    async with AsyncSessionLocal() as session:
        stmt = insert(messages).values(name=req.name, email=req.email, message=req.message)
        await session.execute(stmt)
        await session.commit()
    return {"status": "Received"}
PY

# -------------------------
# FRONTEND TEMPLATES
# -------------------------
mkdir -p "$REPO/frontend/templates"
mkdir -p "$REPO/frontend/static/css"
mkdir -p "$REPO/frontend/static/images"

cat > "$REPO/frontend/templates/base.html" <<'HTML'
<!doctype html>
<html lang="en" class="dark scroll-smooth">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>Genius Machado | Full Stack Engineer</title>
  <script src="https://cdn.tailwindcss.com"></script>
  <script>
    tailwind.config = {
      darkMode: 'class',
      theme: {
        extend: {
          colors: {
            slate: { 850: '#151e2e', 900: '#0f172a' },
            brand: { DEFAULT: '#3B82F6', dark: '#1D4ED8' }
          },
          fontFamily: { sans: ['Inter', 'sans-serif'] }
        }
      }
    }
  </script>
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@300;400;600;800&display=swap" rel="stylesheet">
  <link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/font-awesome/6.4.0/css/all.min.css">
  <style> body { font-family: 'Inter', sans-serif; background: #0F172A; color: #F8FAFC; } </style>
</head>
<body class="flex flex-col min-h-screen">
  <header class="fixed w-full z-50 bg-slate-900/80 backdrop-blur-md border-b border-slate-800">
    <div class="container mx-auto px-6 py-4 flex justify-between items-center">
      <a href="/" class="text-xl font-bold tracking-tight">Genius<span class="text-blue-500">Machado</span></a>
      <div class="hidden md:flex items-center gap-8 text-sm font-medium text-slate-300">
        <a href="#about" class="hover:text-white transition">About</a>
        <a href="#skills" class="hover:text-white transition">Stack</a>
        <a href="#experience" class="hover:text-white transition">Experience</a>
        <a href="#contact" class="px-4 py-2 bg-blue-600 text-white rounded-lg hover:bg-blue-500 transition shadow-lg shadow-blue-500/20">Hire Me</a>
      </div>
      <div class="flex items-center gap-4">
          <a href="https://x.com/DRxICT" class="text-gray-400 hover:text-white transition"><i class="fab fa-twitter"></i></a>
          <a href="https://www.youtube.com/@GeniusMachado" class="text-gray-400 hover:text-white transition"><i class="fab fa-youtube"></i></a>
          <a href="https://www.instagram.com/geniusmachado/" class="text-gray-400 hover:text-white transition"><i class="fab fa-instagram"></i></a>
          <a href="https://www.snapchat.com/add/geniusmachado?share_id=clvFLRAE1h0&locale=en-US" class="text-gray-400 hover:text-white transition"><i class="fab fa-snapchat"></i></a>
      </div>
    </div>
  </header>
  <main class="flex-grow pt-0">
    {% block content %}{% endblock %}
  </main>
  <footer class="bg-slate-950 border-t border-slate-800 py-8 text-center text-slate-500 text-sm">
    <div class="flex justify-center gap-6 mb-4 text-xl">
        <a href="https://x.com/DRxICT" class="hover:text-white transition"><i class="fab fa-twitter"></i></a>
        <a href="https://www.youtube.com/@GeniusMachado" class="hover:text-white transition"><i class="fab fa-youtube"></i></a>
        <a href="https://www.instagram.com/geniusmachado/" class="hover:text-white transition"><i class="fab fa-instagram"></i></a>
        <a href="https://www.snapchat.com/add/geniusmachado?share_id=clvFLRAE1h0&locale=en-US" class="hover:text-white transition"><i class="fab fa-snapchat"></i></a>
    </div>
    <p>&copy; 2026 Genius Machado. Built with Python, Docker, & Cloudflare.</p>
  </footer>
</body>
</html>
HTML

cat > "$REPO/frontend/templates/index.html" <<'HTML'
{% extends "base.html" %}
{% block content %}

<!-- HERO SECTION -->
<div class="relative min-h-screen flex items-center pt-20 overflow-hidden" id="about">
  <!-- Dynamic Background -->
  <canvas id="bgCanvas" class="absolute inset-0 z-0 opacity-40"></canvas>
  <div class="absolute inset-0 bg-gradient-to-b from-transparent via-slate-900/60 to-slate-900 z-10"></div>
  
  <div class="container mx-auto px-6 relative z-20 grid lg:grid-cols-2 gap-12 items-center">
    <!-- Text -->
    <div class="space-y-6">
      <div class="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-blue-500/10 border border-blue-500/30 text-blue-400 text-xs font-bold uppercase tracking-wider">
        <span class="w-2 h-2 rounded-full bg-blue-500 animate-pulse"></span> Open to Work
      </div>
      <h1 class="text-5xl md:text-7xl font-black text-white leading-tight">
        Building Scalable <br>
        <span class="text-transparent bg-clip-text bg-gradient-to-r from-blue-400 to-cyan-400">Cloud Systems.</span>
      </h1>
      <p class="text-lg text-slate-400 max-w-xl leading-relaxed">
        Full Stack Python Developer with <strong>7+ years</strong> of experience designing asynchronous, event-driven microservices.
        <br><br>
        Specializing in <strong>FastAPI, Django, AWS, Docker</strong>, and large-scale data pipelines using <strong>Kafka & Spark</strong>.
      </p>
      <div class="flex flex-wrap gap-4 pt-4">
        <a href="https://github.com/GeniusMachado" target="_blank" class="px-6 py-3 bg-white text-slate-900 font-bold rounded-lg hover:bg-gray-200 transition flex items-center gap-2">
          <i class="fab fa-github"></i> GitHub
        </a>
        <a href="https://www.linkedin.com/in/geniusmachado" target="_blank" class="px-6 py-3 border border-slate-700 text-white font-bold rounded-lg hover:bg-slate-800 transition flex items-center gap-2">
          <i class="fab fa-linkedin"></i> LinkedIn
        </a>
      </div>
    </div>

    <!-- Live System Demo Panel -->
    <div class="relative group">
       <div class="absolute -inset-1 bg-gradient-to-r from-blue-600 to-cyan-600 rounded-2xl blur opacity-20 group-hover:opacity-40 transition duration-1000"></div>
       <div class="relative bg-slate-900 border border-slate-800 rounded-2xl p-8 shadow-2xl">
         <div class="flex items-center justify-between mb-6">
            <h3 class="text-white font-bold flex items-center gap-2">
              <span class="w-2 h-2 rounded-full {{ 'bg-green-500' if system.status == 'Operational' else 'bg-yellow-500' }}"></span>
              Live System Status
            </h3>
            <span class="text-xs font-mono text-slate-500">v27.2.0</span>
         </div>
         
         <div class="space-y-3 font-mono text-xs md:text-sm">
            <div class="flex justify-between p-3 bg-slate-950 rounded border border-slate-800/50">
              <span class="text-slate-400">Infrastructure</span>
              <span class="text-blue-400">Docker + Cloudflare</span>
            </div>
            <div class="flex justify-between p-3 bg-slate-950 rounded border border-slate-800/50">
              <span class="text-slate-400">Backend API</span>
              <span class="text-emerald-400">FastAPI (Python 3.11)</span>
            </div>
            <div class="flex justify-between p-3 bg-slate-950 rounded border border-slate-800/50">
              <span class="text-slate-400">Database</span>
              <span class="{{ 'text-green-400' if system.db == 'Connected' else 'text-red-400' }}">{{ system.db }}</span>
            </div>
            <div class="flex justify-between p-3 bg-slate-950 rounded border border-slate-800/50">
              <span class="text-slate-400">CI/CD</span>
              <span class="text-purple-400">GitHub Actions</span>
            </div>
         </div>
         
         <div class="mt-6 pt-4 border-t border-slate-800 text-center">
            <p class="text-[10px] text-slate-500 uppercase tracking-widest">This website IS the project</p>
         </div>
       </div>
    </div>
  </div>
</div>

<!-- SKILLS MARQUEE -->
<div class="py-12 border-y border-slate-800 bg-slate-950 overflow-hidden relative" id="skills">
  <div class="container mx-auto px-6">
    <div class="flex flex-wrap justify-center gap-6 md:gap-10 opacity-70 hover:opacity-100 transition duration-500">
       <div class="flex items-center gap-2"><i class="fab fa-python text-2xl text-yellow-400"></i> <span class="font-bold">Python</span></div>
       <div class="flex items-center gap-2"><i class="fab fa-aws text-2xl text-orange-400"></i> <span class="font-bold">AWS</span></div>
       <div class="flex items-center gap-2"><i class="fab fa-docker text-2xl text-blue-500"></i> <span class="font-bold">Docker</span></div>
       <div class="flex items-center gap-2"><i class="fas fa-database text-2xl text-blue-300"></i> <span class="font-bold">PostgreSQL</span></div>
       <div class="flex items-center gap-2"><i class="fas fa-wind text-2xl text-teal-400"></i> <span class="font-bold">Airflow</span></div>
       <div class="flex items-center gap-2"><i class="fas fa-network-wired text-2xl text-purple-400"></i> <span class="font-bold">Kafka</span></div>
       <div class="flex items-center gap-2"><i class="fas fa-bolt text-2xl text-orange-500"></i> <span class="font-bold">Spark</span></div>
       <div class="flex items-center gap-2"><i class="fas fa-snowflake text-2xl text-cyan-300"></i> <span class="font-bold">Snowflake</span></div>
       <div class="flex items-center gap-2"><i class="fas fa-code text-2xl text-purple-300"></i> <span class="font-bold">Terraform</span></div>
    </div>
  </div>
</div>

<!-- EXPERIENCE -->
<section id="experience" class="py-24 bg-slate-900">
  <div class="container mx-auto px-6 grid md:grid-cols-3 gap-12">
    <!-- Profile Card -->
    <div class="md:col-span-1">
       <div class="sticky top-24">
         <div class="rounded-2xl overflow-hidden border border-slate-700 shadow-xl mb-6">
            <img src="/static/images/profile.jpg" alt="Genius Machado" class="w-full object-cover">
         </div>
         <h3 class="text-2xl font-bold text-white mb-2">Genius Machado</h3>
         <p class="text-blue-400 font-medium mb-4">MS Computer Science</p>
         <p class="text-slate-400 text-sm leading-relaxed mb-6">
           Passionate about solving complex problems with clean code. I thrive in high-impact environments where collaboration and innovation meet.
         </p>
         <a href="/static/resume.pdf" target="_blank" class="block w-full py-3 bg-slate-800 text-white text-center font-bold rounded-lg hover:bg-slate-700 transition border border-slate-700">
           <i class="fas fa-download mr-2"></i> Download Resume
         </a>
       </div>
    </div>

    <!-- Experience Timeline -->
    <div class="md:col-span-2 space-y-16">
       <h2 class="text-3xl font-bold text-white border-b border-slate-800 pb-4">Professional Experience</h2>

       <!-- Job 1: Mass General Brigham -->
       <div class="relative pl-8 border-l-2 border-slate-700">
         <div class="absolute -left-[9px] top-0 w-4 h-4 rounded-full bg-blue-500 border-4 border-slate-900"></div>
         <h4 class="text-xl font-bold text-white">Software Engineer, API Development</h4>
         <div class="flex justify-between items-center mb-2">
            <span class="text-slate-300">Mass General Brigham</span>
            <span class="text-xs text-slate-500 font-mono">Aug 2025 – Present</span>
         </div>
         <ul class="list-disc pl-5 text-slate-400 text-sm space-y-2 mb-4">
            <li>Develop, maintain, and optimize RESTful APIs using FastAPI to enable secure transfer of pathology data.</li>
            <li>Design API endpoints for data ingestion, retrieval, and transformation to support clinical workflows.</li>
            <li>Write and refine SQL queries in Snowflake and PostgreSQL to handle large imaging datasets efficiently.</li>
            <li>Implement stored procedures and query optimizations to reduce response time for high-volume requests.</li>
            <li>Collaborate with cross-functional teams, including pathologists and data scientists, to align API functionality.</li>
            <li>Integrate Epic Beaker with multiple legacy laboratory systems to ensure compatibility.</li>
            <li>Provide technical support for Legacy Viewer interfaces by troubleshooting data flow and connectivity issues.</li>
            <li>Resolve performance bottlenecks to improve reliability, scalability, and uptime of data pipelines.</li>
            <li>Enhance API infrastructure through route refactoring, code modularization, and secure design.</li>
         </ul>
         <div class="flex flex-wrap gap-2">
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">FastAPI</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Snowflake</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">PostgreSQL</span>
         </div>
       </div>

       <!-- Job 2: Fitch Ratings -->
       <div class="relative pl-8 border-l-2 border-slate-700">
         <div class="absolute -left-[9px] top-0 w-4 h-4 rounded-full bg-slate-700 border-4 border-slate-900"></div>
         <h4 class="text-xl font-bold text-white">Python Developer</h4>
         <div class="flex justify-between items-center mb-2">
            <span class="text-slate-300">Fitch Ratings</span>
            <span class="text-xs text-slate-500 font-mono">Oct 2023 – July 2025</span>
         </div>
         <ul class="list-disc pl-5 text-slate-400 text-sm space-y-2 mb-4">
            <li>Developed scalable backend services using Python and Django, integrating FastAPI endpoints.</li>
            <li>Built frontend dashboards using React.js with Redux and TypeScript for real-time visualization.</li>
            <li>Designed ETL pipelines using Apache Airflow, AWS Glue, and Kafka for data ingestion.</li>
            <li>Integrated AWS Glue with S3, RDS, and Glue Catalog to automate schema discovery.</li>
            <li>Implemented LLM-based GenAI services using OpenAI and Bedrock for semantic search.</li>
            <li>Integrated Quartz engines for real-time fixed income analytics into backend workflows.</li>
            <li>Used Redis for caching frequent queries to optimize API latency.</li>
            <li>Maintained CI/CD pipelines using GitHub Actions and Jenkins with Pytest and SonarQube.</li>
            <li>Deployed containerized applications on EKS with Helm and Terraform.</li>
            <li>Created monitoring dashboards with CloudWatch, Prometheus, and Grafana.</li>
         </ul>
         <div class="flex flex-wrap gap-2">
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Django</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">React</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Airflow</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">AWS</span>
         </div>
       </div>

       <!-- Job 3: American Express -->
       <div class="relative pl-8 border-l-2 border-slate-700">
         <div class="absolute -left-[9px] top-0 w-4 h-4 rounded-full bg-slate-700 border-4 border-slate-900"></div>
         <h4 class="text-xl font-bold text-white">Python Developer</h4>
         <div class="flex justify-between items-center mb-2">
            <span class="text-slate-300">American Express</span>
            <span class="text-xs text-slate-500 font-mono">Jan 2023 – Sep 2023</span>
         </div>
         <ul class="list-disc pl-5 text-slate-400 text-sm space-y-2 mb-4">
            <li>Designed backend microservices using Python, FastAPI, and Flask with OAuth2 and JWT.</li>
            <li>Built reusable UI components using React.js and Next.js for customer dashboards.</li>
            <li>Deployed containerized services to Kubernetes (EKS) using Helm charts.</li>
            <li>Engineered ETL workflows using Apache Airflow for data transformation into Snowflake.</li>
            <li>Optimized Redis integration for caching session tokens and financial metadata.</li>
            <li>Assisted in infrastructure provisioning using Terraform and AWS CDK.</li>
            <li>Contributed to infrastructure configuration using Ansible for repeatable deployments.</li>
            <li>Built CI/CD pipelines using GitHub Actions and Jenkins with automated testing.</li>
            <li>Supported A/B experimentation using feature flags and statistical evaluation.</li>
         </ul>
         <div class="flex flex-wrap gap-2">
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">FastAPI</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">React</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Kubernetes</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Terraform</span>
         </div>
       </div>
       
       <!-- Job 4: UnitedHealth Group -->
       <div class="relative pl-8 border-l-2 border-slate-700">
         <div class="absolute -left-[9px] top-0 w-4 h-4 rounded-full bg-slate-700 border-4 border-slate-900"></div>
         <h4 class="text-xl font-bold text-white">Software Engineer</h4>
         <div class="flex justify-between items-center mb-2">
            <span class="text-slate-300">UnitedHealth Group</span>
            <span class="text-xs text-slate-500 font-mono">Jan 2020 – Dec 2021</span>
         </div>
         <ul class="list-disc pl-5 text-slate-400 text-sm space-y-2 mb-4">
            <li>Designed and developed backend microservices using Python, FastAPI, and Flask.</li>
            <li>Developed reusable, interactive UI components using React.js, Next.js, and Vue.js.</li>
            <li>Containerized microservices using Docker and deployed to Kubernetes (EKS).</li>
            <li>Engineered ETL workflows using Apache Airflow for batch loading into Snowflake.</li>
            <li>Integrated Redis for caching authentication tokens and user session data.</li>
            <li>Supported infrastructure provisioning using Terraform and AWS CDK.</li>
            <li>Configured repeatable local development environments using Ansible.</li>
            <li>Developed CI/CD pipelines with GitHub Actions, Jenkins, and SonarQube.</li>
         </ul>
         <div class="flex flex-wrap gap-2">
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Microservices</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Docker</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">ETL</span>
         </div>
       </div>

       <!-- Job 5: Barclays -->
       <div class="relative pl-8 border-l-2 border-slate-700">
         <div class="absolute -left-[9px] top-0 w-4 h-4 rounded-full bg-slate-700 border-4 border-slate-900"></div>
         <h4 class="text-xl font-bold text-white">Software Developer</h4>
         <div class="flex justify-between items-center mb-2">
            <span class="text-slate-300">Barclays</span>
            <span class="text-xs text-slate-500 font-mono">Jul 2018 – Dec 2019</span>
         </div>
         <ul class="list-disc pl-5 text-slate-400 text-sm space-y-2 mb-4">
            <li>Developed and optimized backend services using Python and Django.</li>
            <li>Built data processing workflows and dynamic reporting modules.</li>
            <li>Designed responsive frontend components using HTML5, CSS3, and JavaScript.</li>
            <li>Created and integrated custom Highcharts-based dashboards for data visualization.</li>
            <li>Conducted unit testing and integration testing using Pytest and Django's framework.</li>
            <li>Refactored legacy Django views and serializers to improve performance.</li>
            <li>Deployed Django applications on Linux environments using Apache and WSGI.</li>
         </ul>
         <div class="flex flex-wrap gap-2">
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Django</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">MySQL</span>
            <span class="px-2 py-1 bg-slate-800 rounded text-xs text-slate-400">Linux</span>
         </div>
       </div>
       
       <!-- Education -->
       <h2 class="text-3xl font-bold text-white border-b border-slate-800 pb-4 pt-8">Education</h2>
       <div class="space-y-6">
          <div>
            <h4 class="text-lg font-bold text-white">Master of Science, Computer Science</h4>
            <p class="text-slate-400">Pace University - Seidenberg School of CS & IS <span class="text-slate-600 text-xs ml-2">(2022 - Dec 2023)</span></p>
          </div>
          <div>
            <h4 class="text-lg font-bold text-white">Bachelor of Science, Computer Engineering</h4>
            <p class="text-slate-400">St. Francis Institute of Technology</p>
          </div>
       </div>

    </div>
  </div>
</section>

<!-- CONTACT -->
<section id="contact" class="py-24 bg-slate-950 relative overflow-hidden">
  <div class="absolute top-0 left-1/2 -translate-x-1/2 w-full max-w-3xl h-full bg-blue-500/5 blur-3xl rounded-full pointer-events-none"></div>
  
  <div class="container mx-auto px-6 relative z-10 text-center max-w-2xl">
    <h2 class="text-3xl font-bold text-white mb-6">Let's Build Something Scalable</h2>
    <p class="text-slate-400 mb-8">
      Open to Full Stack, Backend, and DevOps opportunities.
    </p>

    {% if success %}
    <div class="bg-green-500/10 border border-green-500/30 text-green-400 p-4 rounded-lg mb-8">
      ✅ Message Received. I'll get back to you shortly.
    </div>
    {% endif %}

    <form action="/contact" method="post" class="text-left space-y-4">
       <div class="grid md:grid-cols-2 gap-4">
         <input name="name" type="text" placeholder="Name" required class="w-full bg-slate-900 border border-slate-800 rounded-lg px-4 py-3 text-white focus:border-blue-500 outline-none transition">
         <input name="email" type="email" placeholder="Email" required class="w-full bg-slate-900 border border-slate-800 rounded-lg px-4 py-3 text-white focus:border-blue-500 outline-none transition">
       </div>
       <textarea name="message" rows="4" placeholder="Message / Job Opportunity..." required class="w-full bg-slate-900 border border-slate-800 rounded-lg px-4 py-3 text-white focus:border-blue-500 outline-none transition"></textarea>
       <button class="w-full bg-blue-600 text-white font-bold py-4 rounded-lg hover:bg-blue-500 transition shadow-lg shadow-blue-500/20">
         Send Message
       </button>
    </form>
  </div>
</section>

<script>
// Tech Network Animation (Improved Visibility)
const canvas = document.getElementById('bgCanvas');
const ctx = canvas.getContext('2d');
let w, h, nodes = [];

// High-visibility Tech Colors
const colors = ['#3B82F6', '#00FFFF', '#FFFFFF', '#10B981'];

function resize() { w = canvas.width = window.innerWidth; h = canvas.height = window.innerHeight; }
window.addEventListener('resize', resize);
resize();

class Node {
  constructor() { this.reset(); }
  reset() {
    this.x = Math.random() * w; this.y = Math.random() * h;
    // Faster speed
    this.vx = (Math.random() - 0.5) * 1.5; this.vy = (Math.random() - 0.5) * 1.5;
    this.color = colors[Math.floor(Math.random() * colors.length)];
  }
  update() {
    this.x += this.vx; this.y += this.vy;
    if(this.x<0||this.x>w||this.y<0||this.y>h) this.reset();
  }
  draw() {
    ctx.fillStyle = this.color; ctx.globalAlpha = 0.8;
    ctx.beginPath(); ctx.arc(this.x, this.y, 2, 0, Math.PI*2); ctx.fill();
    ctx.shadowBlur = 10; ctx.shadowColor = this.color;
  }
}

for(let i=0; i<100; i++) nodes.push(new Node());

function animate() {
  ctx.clearRect(0, 0, w, h);
  ctx.shadowBlur = 0; // Reset for lines
  for(let i=0; i<nodes.length; i++) {
    const n1 = nodes[i]; n1.update(); n1.draw();
    for(let j=i+1; j<nodes.length; j++) {
      const n2 = nodes[j];
      const d = Math.hypot(n1.x-n2.x, n1.y-n2.y);
      if(d < 120) {
        ctx.strokeStyle = n1.color; ctx.lineWidth = 0.5; ctx.globalAlpha = (1 - d/120) * 0.5;
        ctx.beginPath(); ctx.moveTo(n1.x, n1.y); ctx.lineTo(n2.x, n2.y); ctx.stroke();
      }
    }
  }
  requestAnimationFrame(animate);
}
animate();
</script>

{% endblock %}
HTML

# -------------------------
# DB SQL (New Messages Table)
# -------------------------
mkdir -p "$REPO/db"
cat > "$REPO/db/init.sql" <<'SQL'
CREATE DATABASE IF NOT EXISTS portfolio;
USE portfolio;
CREATE TABLE IF NOT EXISTS messages (
  id INT AUTO_INCREMENT PRIMARY KEY,
  name VARCHAR(255),
  email VARCHAR(255),
  message TEXT,
  created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
SQL

# -------------------------
# Env
# -------------------------
cat > "$REPO/.env.example" <<'ENV'
MYSQL_ROOT_PASSWORD=rootpass
DATABASE_URL=mysql+aiomysql://genius:geniuspass@db:3306/portfolio
ENGINE_URL=http://portfolio-engine:8002
ENV

echo "✅ V27.2 Comprehensive Portfolio Ready!"
echo "-----------------------------------------------------"
echo "👉 1. Edit docker-compose.yml (Add Cloudflare Token)"
echo "👉 2. Add profile.jpg to frontend/static/images/"
echo "👉 3. Add resume.pdf to frontend/static/ (Optional)"
echo "👉 4. Run: cd geniusmachado && docker compose up --build"
echo "-----------------------------------------------------"
