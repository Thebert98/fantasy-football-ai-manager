from fastapi import FastAPI
from app.api.v1 import draft, users
from fastapi.middleware.cors import CORSMiddleware

app = FastAPI(title="Fantasy Football AI Manager API")

#enable CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_method=["*"],
    allow_headers=["*"],
)

#API routes
app.include_router(users.router, prefix="/api/v1/users")
app.include_router(draft.router, prefix="/api/v1/draft" )