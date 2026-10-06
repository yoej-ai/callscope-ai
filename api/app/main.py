import logging

from fastapi import FastAPI, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app.auth import SupabaseJwtVerifier, TokenVerifier
from app.config import Settings, get_settings
from app.logging_config import configure_logging
from app.routers.health import router as health_router
from app.routers.identity import router as identity_router
from app.routers.workspaces import WorkspaceReader
from app.routers.workspaces import router as workspaces_router
from app.supabase_data import SupabaseWorkspaceClient

logger = logging.getLogger(__name__)


def create_app(
    *,
    settings: Settings | None = None,
    jwt_verifier: TokenVerifier | None = None,
    workspace_client: WorkspaceReader | None = None,
) -> FastAPI:
    settings = settings or get_settings()
    configure_logging(settings.app_env)

    app = FastAPI(title="CallScope AI API", version="0.1.0")
    app.state.jwt_verifier = jwt_verifier or SupabaseJwtVerifier(settings)
    app.state.workspace_client = workspace_client or SupabaseWorkspaceClient(settings)
    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.allowed_origins,
        allow_credentials=True,
        allow_methods=["GET", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"],
        allow_headers=["Authorization", "Content-Type"],
    )
    app.include_router(health_router)
    app.include_router(identity_router)
    app.include_router(workspaces_router)

    @app.exception_handler(Exception)
    async def unhandled_exception_handler(
        request: Request, exc: Exception
    ) -> JSONResponse:
        logger.exception(
            "Unhandled API exception",
            extra={"method": request.method, "path": request.url.path},
        )
        return JSONResponse(
            status_code=500,
            content={"detail": "An unexpected server error occurred."},
        )

    return app


app = create_app()
