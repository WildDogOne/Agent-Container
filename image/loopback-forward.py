"""Forward 127.0.0.1:PORT inside the container to a bind-mounted Unix socket.

Started by entrypoint.sh (as dev, after the UID remap) for each `run.sh --loopback-socket
PORT:SOCKET`. Tools inside the sandbox that insist on talking TCP to a fixed loopback port
(e.g. an orchestrator's status hooks) reach a service on the host side through the socket,
without the sandbox getting any new network route: the listener is loopback-only, the
nftables egress firewall is untouched, and the far end decides what it accepts.

Bytes are copied verbatim in both directions; one Unix connection per TCP connection.
"""

import asyncio
import sys

BUF = 65536


async def pump(reader: asyncio.StreamReader, writer: asyncio.StreamWriter) -> None:
    try:
        while True:
            data = await reader.read(BUF)
            if not data:
                break
            writer.write(data)
            await writer.drain()
    except (ConnectionError, OSError):
        pass
    finally:
        try:
            if writer.can_write_eof():
                writer.write_eof()
        except (ConnectionError, OSError):
            pass


async def handle(sock_path: str, tcp_r: asyncio.StreamReader, tcp_w: asyncio.StreamWriter) -> None:
    try:
        unix_r, unix_w = await asyncio.open_unix_connection(sock_path)
    except OSError:
        tcp_w.close()
        return
    try:
        await asyncio.gather(pump(tcp_r, unix_w), pump(unix_r, tcp_w))
    finally:
        for w in (unix_w, tcp_w):
            try:
                w.close()
            except OSError:
                pass


async def main(port: int, sock_path: str) -> None:
    server = await asyncio.start_server(lambda r, w: handle(sock_path, r, w), "127.0.0.1", port)
    async with server:
        await server.serve_forever()


if __name__ == "__main__":
    if len(sys.argv) != 3 or not sys.argv[1].isdigit():
        sys.exit("usage: loopback-forward.py PORT SOCKET")
    asyncio.run(main(int(sys.argv[1]), sys.argv[2]))
