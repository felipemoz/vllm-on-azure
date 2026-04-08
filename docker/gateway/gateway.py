"""
vLLM Gateway - Resilient reverse proxy for Spot instance eviction handling.

Runs on system nodes (non-Spot). Routes requests to vLLM when healthy,
returns a friendly maintenance message during eviction/recovery.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time

from aiohttp import web, ClientSession, ClientTimeout, ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
log = logging.getLogger("gateway")

# ── Config ──────────────────────────────────────────────────────
VLLM_UPSTREAM = os.getenv("VLLM_UPSTREAM", "http://vllm:8000")
HEALTH_INTERVAL = int(os.getenv("HEALTH_INTERVAL", "3"))
PORT = int(os.getenv("GATEWAY_PORT", "8080"))

MAINTENANCE_MSG = os.getenv(
    "MAINTENANCE_MSG",
    "Perae que estamos trocando o pneu do aviao voando. "
    "O modelo esta sendo recarregado em uma nova instancia. "
    "Tente novamente em alguns instantes.",
)


# ── State ───────────────────────────────────────────────────────
class BackendState:
    def __init__(self):
        self.healthy = False
        self.last_check: float = 0
        self.evicted_at: float | None = None
        self.recovered_at: float | None = None
        self.eviction_count: int = 0


state = BackendState()


# ── Health checker (background) ─────────────────────────────────
async def health_checker(app: web.Application):
    """Background task that continuously checks vLLM health."""
    async with ClientSession(timeout=ClientTimeout(total=5)) as session:
        while True:
            try:
                async with session.get(f"{VLLM_UPSTREAM}/health") as resp:
                    now = time.time()
                    was_healthy = state.healthy
                    state.healthy = resp.status == 200
                    state.last_check = now

                    if state.healthy and not was_healthy:
                        state.recovered_at = now
                        downtime = ""
                        if state.evicted_at:
                            dt = now - state.evicted_at
                            downtime = f" (downtime: {dt:.0f}s)"
                        log.info("vLLM is BACK online%s", downtime)

            except (ClientError, asyncio.TimeoutError, OSError):
                now = time.time()
                if state.healthy:
                    state.healthy = False
                    state.evicted_at = now
                    state.eviction_count += 1
                    log.warning(
                        "vLLM is DOWN (eviction #%d). "
                        "Returning maintenance response to clients.",
                        state.eviction_count,
                    )
                state.last_check = now

            await asyncio.sleep(HEALTH_INTERVAL)


async def start_health_checker(app: web.Application):
    app["health_checker"] = asyncio.create_task(health_checker(app))


async def stop_health_checker(app: web.Application):
    app["health_checker"].cancel()
    try:
        await app["health_checker"]
    except asyncio.CancelledError:
        pass


# ── Maintenance response builder ────────────────────────────────
def maintenance_response(request: web.Request) -> web.Response:
    """Return a friendly JSON response during eviction."""
    is_chat = "/chat/" in request.path
    is_completions = "/completions" in request.path

    # If it's an API call, mimic OpenAI error format
    if is_completions or is_chat:
        body = {
            "error": {
                "message": MAINTENANCE_MSG,
                "type": "server_error",
                "code": "model_reloading",
            },
            "status": {
                "eviction_count": state.eviction_count,
                "down_since": state.evicted_at,
                "message": MAINTENANCE_MSG,
            },
        }
        return web.json_response(body, status=503)

    # For health checks
    if request.path == "/health":
        return web.json_response(
            {
                "status": "maintenance",
                "backend": "down",
                "message": MAINTENANCE_MSG,
                "eviction_count": state.eviction_count,
            },
            status=503,
        )

    # Generic
    return web.json_response(
        {"message": MAINTENANCE_MSG, "status": "maintenance"},
        status=503,
    )


# ── Reverse proxy handler ───────────────────────────────────────
async def proxy_handler(request: web.Request) -> web.Response:
    """Proxy requests to vLLM or return maintenance message."""

    if not state.healthy:
        return maintenance_response(request)

    upstream_url = f"{VLLM_UPSTREAM}{request.path_qs}"
    body = await request.read()

    headers = dict(request.headers)
    headers.pop("Host", None)
    headers.pop("host", None)

    try:
        async with ClientSession(
            timeout=ClientTimeout(total=600)
        ) as session:
            async with session.request(
                method=request.method,
                url=upstream_url,
                headers=headers,
                data=body,
            ) as upstream_resp:

                # Check if this is a streaming response
                content_type = upstream_resp.headers.get("Content-Type", "")
                is_streaming = "text/event-stream" in content_type

                if is_streaming:
                    response = web.StreamResponse(
                        status=upstream_resp.status,
                        headers={
                            "Content-Type": content_type,
                            "Cache-Control": "no-cache",
                            "Connection": "keep-alive",
                        },
                    )
                    await response.prepare(request)

                    try:
                        async for chunk in upstream_resp.content.iter_any():
                            await response.write(chunk)
                    except (ClientError, ConnectionError):
                        # vLLM died mid-stream (eviction during response)
                        error_event = (
                            'data: {"error": {"message": "'
                            + MAINTENANCE_MSG
                            + '", "type": "server_error", '
                            '"code": "model_reloading"}}\n\n'
                            "data: [DONE]\n\n"
                        )
                        await response.write(error_event.encode())

                    await response.write_eof()
                    return response

                else:
                    resp_body = await upstream_resp.read()
                    return web.Response(
                        status=upstream_resp.status,
                        body=resp_body,
                        content_type=content_type,
                    )

    except (ClientError, asyncio.TimeoutError, OSError):
        # vLLM went down between health check and this request
        state.healthy = False
        state.evicted_at = time.time()
        state.eviction_count += 1
        log.warning("vLLM went down during request proxying (eviction #%d)", state.eviction_count)
        return maintenance_response(request)


# ── Gateway status endpoint ─────────────────────────────────────
async def gateway_status(request: web.Request) -> web.Response:
    """Gateway's own status endpoint."""
    return web.json_response({
        "gateway": "ok",
        "backend_healthy": state.healthy,
        "eviction_count": state.eviction_count,
        "last_check": state.last_check,
        "evicted_at": state.evicted_at,
        "recovered_at": state.recovered_at,
        "upstream": VLLM_UPSTREAM,
    })


# ── App setup ───────────────────────────────────────────────────
def create_app() -> web.Application:
    app = web.Application()
    app.on_startup.append(start_health_checker)
    app.on_cleanup.append(stop_health_checker)

    # Gateway-specific endpoints
    app.router.add_get("/gateway/status", gateway_status)

    # Proxy everything else to vLLM
    app.router.add_route("*", "/{path:.*}", proxy_handler)

    return app


if __name__ == "__main__":
    log.info("Starting vLLM Gateway on port %d -> %s", PORT, VLLM_UPSTREAM)
    web.run_app(create_app(), host="0.0.0.0", port=PORT, print=None)
