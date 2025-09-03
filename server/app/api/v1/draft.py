from fastapi import APIRouter

router = APIRouter()

@router.get("/status")
def get_draft_status():
    return {"status": "draft live"}