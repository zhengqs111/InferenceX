#!/usr/bin/env bash
exec python3 - <<'PY'
import asyncio
import sys

HOSTS = ("7.150.5.150", "7.150.4.253", "7.150.6.122", "7.150.3.165")


async def post(host, port, action):
    _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=3)
    try:
        writer.write(
            f"POST /{action}_profile HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode()
        )
        await writer.drain()  # Only wait until the request is sent; never read the response.
    finally:
        writer.close()
        await writer.wait_closed()


async def send_all(action):
    results = await asyncio.gather(
        *(post(HOSTS[i // 16], 9100 + i, action) for i in range(64)),
        return_exceptions=True,
    )
    for i, result in enumerate(results):
        if isinstance(result, Exception):
            print(f"{action}_profile {HOSTS[i // 16]}:{9100 + i}: {result}", file=sys.stderr)
    return any(isinstance(result, Exception) for result in results)


async def main():
    start_failed = await send_all("start")
    await asyncio.sleep(0.9)
    stop_failed = await send_all("stop")
    return int(start_failed or stop_failed)


sys.exit(asyncio.run(main()))
PY
