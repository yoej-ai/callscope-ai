import asyncio
from collections.abc import Mapping
from dataclasses import dataclass, field
from time import monotonic
from typing import Annotated, Any, Protocol
from uuid import UUID

import httpx2 as httpx
import jwt
from fastapi import Depends, Header, HTTPException, Request, status

from app.config import Settings

ALLOWED_JWT_ALGORITHMS = frozenset({"ES256", "RS256"})
EXPECTED_JWK_TYPES = {"ES256": "EC", "RS256": "RSA"}
AUTHENTICATED_AUDIENCE = "authenticated"
AUTHENTICATED_ROLE = "authenticated"
BEARER_CHALLENGE = {"WWW-Authenticate": "Bearer"}


class InvalidAccessToken(Exception):
    """The submitted credential is not a valid Supabase user access token."""


class AuthenticationServiceUnavailable(Exception):
    """Token verification could not reach or parse the configured JWKS service."""


@dataclass(frozen=True, slots=True)
class CurrentUser:
    user_id: UUID
    role: str
    access_token: str = field(repr=False)


class TokenVerifier(Protocol):
    async def verify(self, access_token: str) -> CurrentUser: ...


class JwksCache:
    """Small async JWKS cache with a forced refresh path for signing-key rotation."""

    def __init__(
        self,
        jwks_url: str,
        *,
        cache_ttl_seconds: float = 600.0,
        timeout_seconds: float = 5.0,
        transport: httpx.AsyncBaseTransport | None = None,
    ) -> None:
        self._jwks_url = jwks_url
        self._cache_ttl_seconds = cache_ttl_seconds
        self._timeout = httpx.Timeout(timeout_seconds)
        self._transport = transport
        self._keys: dict[str, Mapping[str, Any]] = {}
        self._expires_at = 0.0
        self._lock = asyncio.Lock()

    async def get_key(self, kid: str, algorithm: str) -> Any:
        key_data = await self._get_cached_key(kid)
        if key_data is None:
            await self._refresh(force=True)
            key_data = self._keys.get(kid)
        if key_data is None:
            raise InvalidAccessToken("Unknown signing key")

        key_algorithm = key_data.get("alg")
        if key_algorithm is not None and key_algorithm != algorithm:
            raise InvalidAccessToken("Signing key algorithm mismatch")
        if key_data.get("kty") != EXPECTED_JWK_TYPES[algorithm]:
            raise InvalidAccessToken("Signing key type mismatch")
        if key_data.get("use") not in {None, "sig"}:
            raise InvalidAccessToken("Signing key is not valid for signatures")

        try:
            return jwt.PyJWK.from_dict(dict(key_data), algorithm=algorithm).key
        except (jwt.PyJWKError, ValueError, TypeError) as exc:
            raise InvalidAccessToken("Invalid signing key") from exc

    async def _get_cached_key(self, kid: str) -> Mapping[str, Any] | None:
        if monotonic() >= self._expires_at:
            await self._refresh(force=False)
        return self._keys.get(kid)

    async def _refresh(self, *, force: bool) -> None:
        async with self._lock:
            if not force and self._keys and monotonic() < self._expires_at:
                return

            try:
                async with httpx.AsyncClient(
                    timeout=self._timeout,
                    transport=self._transport,
                ) as client:
                    response = await client.get(self._jwks_url)
                    response.raise_for_status()
                    payload = response.json()
            except (httpx.HTTPError, ValueError, TypeError) as exc:
                raise AuthenticationServiceUnavailable from exc

            keys = payload.get("keys") if isinstance(payload, dict) else None
            if not isinstance(keys, list):
                raise AuthenticationServiceUnavailable

            parsed_keys: dict[str, Mapping[str, Any]] = {}
            for key in keys:
                if not isinstance(key, dict):
                    continue
                kid = key.get("kid")
                algorithm = key.get("alg")
                if (
                    isinstance(kid, str)
                    and kid
                    and key.get("kty") in {"EC", "RSA"}
                    and algorithm in ALLOWED_JWT_ALGORITHMS
                ):
                    parsed_keys[kid] = key

            if not parsed_keys:
                raise AuthenticationServiceUnavailable

            self._keys = parsed_keys
            self._expires_at = monotonic() + self._cache_ttl_seconds


class SupabaseJwtVerifier:
    def __init__(self, settings: Settings, jwks_cache: JwksCache | None = None) -> None:
        self._settings = settings
        self._jwks_cache = jwks_cache

    async def verify(self, access_token: str) -> CurrentUser:
        try:
            issuer = self._settings.supabase_issuer
        except RuntimeError as exc:
            raise AuthenticationServiceUnavailable from exc

        jwks_cache = self._jwks_cache
        if jwks_cache is None:
            jwks_cache = JwksCache(self._settings.supabase_jwks_url)
            self._jwks_cache = jwks_cache

        try:
            header = jwt.get_unverified_header(access_token)
        except jwt.PyJWTError as exc:
            raise InvalidAccessToken("Malformed JWT") from exc

        algorithm = header.get("alg")
        kid = header.get("kid")
        if (
            algorithm not in ALLOWED_JWT_ALGORITHMS
            or not isinstance(kid, str)
            or not kid
        ):
            raise InvalidAccessToken("Unsupported token header")
        if header.get("crit") is not None:
            raise InvalidAccessToken("Unsupported critical token header")

        key = await jwks_cache.get_key(kid, algorithm)
        try:
            claims = jwt.decode(
                access_token,
                key=key,
                algorithms=[algorithm],
                audience=AUTHENTICATED_AUDIENCE,
                issuer=issuer,
                options={"require": ["aud", "exp", "iss", "role", "sub"]},
            )
        except jwt.PyJWTError as exc:
            raise InvalidAccessToken("JWT validation failed") from exc

        role = claims.get("role")
        subject = claims.get("sub")
        if role != AUTHENTICATED_ROLE or not isinstance(subject, str):
            raise InvalidAccessToken("Token is not an authenticated user token")

        try:
            user_id = UUID(subject)
        except (ValueError, AttributeError) as exc:
            raise InvalidAccessToken("Token subject is not a UUID") from exc

        return CurrentUser(
            user_id=user_id,
            role=role,
            access_token=access_token,
        )


def get_token_verifier(request: Request) -> TokenVerifier:
    return request.app.state.jwt_verifier


async def get_current_user(
    verifier: Annotated[TokenVerifier, Depends(get_token_verifier)],
    authorization: Annotated[str | None, Header()] = None,
) -> CurrentUser:
    if authorization is None:
        raise _unauthorized()

    scheme, separator, token = authorization.partition(" ")
    if (
        not separator
        or scheme.lower() != "bearer"
        or not token
        or token != token.strip()
        or any(character.isspace() for character in token)
    ):
        raise _unauthorized()

    try:
        return await verifier.verify(token)
    except InvalidAccessToken as exc:
        raise _unauthorized() from exc
    except AuthenticationServiceUnavailable as exc:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Authentication service is unavailable.",
        ) from exc


def _unauthorized() -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or missing bearer token.",
        headers=BEARER_CHALLENGE,
    )
