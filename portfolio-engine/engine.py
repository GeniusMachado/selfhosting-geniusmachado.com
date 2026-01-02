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

@app.get("/messages")
async def get_messages():
    async with AsyncSessionLocal() as session:
        result = await session.execute(messages.select().order_by(messages.c.created_at.desc()))
        rows = result.fetchall()
        return [
            {"id": r.id, "name": r.name, "email": r.email, "message": r.message, "date": str(r.created_at)}
            for r in rows
        ]
