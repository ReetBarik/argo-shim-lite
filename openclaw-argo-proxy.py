#!/usr/bin/env python3
import os
import aiohttp
import aiohttp.web

LISTEN_PORT = 8084
TARGET_HOST = "apps.inside.anl.gov"
TUNNEL_HOST = "127.0.0.1"
TARGET_PORT = 8085


async def proxy_request(request):
    session = request.app["session"]
    print(f"[proxy] {request.method} {request.path_qs}", flush=True)

    url = f"https://{TUNNEL_HOST}:{TARGET_PORT}{request.path_qs}"

    headers = dict(request.headers)
    headers["Host"] = TARGET_HOST
    headers.pop("Content-Length", None)

    argo_id = os.environ.get("ARGO_USER") or os.environ.get("USER", "")
    if argo_id:
        headers["Authorization"] = f"Bearer {argo_id}"
        headers.pop("x-api-key", None)

    body = await request.read()

    try:
        async with session.request(
            method=request.method,
            url=url,
            headers=headers,
            data=body if body else None,
            ssl=False,
            allow_redirects=False,
        ) as resp:

            # Preserve streaming + encoding
            filtered_headers = {
                k: v for k, v in resp.headers.items()
                if k.lower() not in ("content-length")
            }

            # HEAD → no body
            if request.method == "HEAD":
                return aiohttp.web.Response(
                    status=resp.status,
                    headers=filtered_headers,
                )

            response = aiohttp.web.StreamResponse(
                status=resp.status,
                headers=filtered_headers,
            )

            await response.prepare(request)

            async for chunk in resp.content.iter_any():
                await response.write(chunk)

            await response.write_eof()
            return response

    except Exception as e:
        return aiohttp.web.Response(status=500, text=str(e))


async def on_startup(app):
    timeout = aiohttp.ClientTimeout(total=None)
    app["session"] = aiohttp.ClientSession(
        auto_decompress=False,
        timeout=timeout
    )


async def on_cleanup(app):
    await app["session"].close()


app = aiohttp.web.Application(client_max_size=8 * 1024**2)
app.router.add_route("*", "/{path_info:.*}", proxy_request)

app.on_startup.append(on_startup)
app.on_cleanup.append(on_cleanup)


if __name__ == "__main__":
    print(f"Argo proxy (OpenClaw) listening on http://127.0.0.1:{LISTEN_PORT}")
    aiohttp.web.run_app(app, host="127.0.0.1", port=LISTEN_PORT, print=None)
