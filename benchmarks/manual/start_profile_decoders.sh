#!/usr/bin/env bash
exec python3 - <<'PY'
import asyncio
import sys

ACTION = "start"
HOSTS = ("7.150.6.80", "7.150.7.206")
# Each decoder host uses the same eight ports: 8000 through 8007.
PORTS = range(8000, 8008)
TARGETS = tuple((host, port) for host in HOSTS for port in PORTS)


async def post(host: str, port: int) -> None:
    """Send the profile request without waiting for an HTTP response."""
    _, writer = await asyncio.wait_for(asyncio.open_connection(host, port), timeout=3)
    try:
        writer.write(
            f"POST /{ACTION}_profile HTTP/1.1\r\n"
            f"Host: {host}:{port}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".encode()
        )
        await writer.drain()
    finally:
        writer.close()
        await writer.wait_closed()


async def main() -> int:
    """Send to all targets concurrently and report connection/send errors."""
    results = await asyncio.gather(
        *(post(host, port) for host, port in TARGETS),
        return_exceptions=True,
    )
    failed = False
    for (host, port), result in zip(TARGETS, results):
        if isinstance(result, Exception):
            failed = True
            print(f"{ACTION}_profile {host}:{port}: {result!r}", file=sys.stderr)
    return int(failed)


sys.exit(asyncio.run(main()))
PY
