from fastapi import APIRouter

router = APIRouter()

@router.get("/status")
def get_user_status():
    return {"status": "user is live"}