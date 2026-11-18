"""服务端「传输侧」取证：TLS ALPN 协商与 xhttp path 首行响应（仅标准库）。

配合 ``tools/client_matrix.py`` 做责任分层：客户端逐节点实测失败时，先确认服务端
到底有没有协商出 ``http/1.1`` / ``h2``，避免把服务端路由问题误判为客户端解析问题。

用法::

    python tools/alpn_probe.py --host 192.168.138.129 ^
        --sni 117.147.55.70,117.147.55.70.sslip.io,192.168.138.129 ^
        --path /JDhOfmmmkAhgA1OtkghzaWNT --path /8Y8riba1uhKoIN9pImhie5BaQnkZ

输出两部分：

1. 每个 SNI × ALPN offer 的真实协商结果与 TLS 版本；
2. 每个 SNI × path 的裸 HTTP/1.1 GET 响应首行。裸 GET 缺少 xhttp 握手头，返回
   404 属预期，只用于确认该 SNI 是否落到同一个默认后端。
"""
from __future__ import annotations

import argparse
import socket
import ssl
import sys

OFFERS = (["http/1.1"], ["h2"], ["h2", "http/1.1"], ["h3"])


def context_for(protos: list[str]) -> ssl.SSLContext:
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    ctx.set_alpn_protocols(protos)
    return ctx


def probe(host: str, port: int, snis: list[str], paths: list[str], timeout: float) -> int:
    print("=== TLS ALPN negotiation ===")
    for sni in snis:
        for protos in OFFERS:
            offer = ",".join(protos)
            try:
                with socket.create_connection((host, port), timeout) as raw:
                    with context_for(protos).wrap_socket(raw, server_hostname=sni) as tls:
                        print(f"{sni:<30} offer={offer:<16} -> {tls.selected_alpn_protocol()} {tls.version()}")
            except (OSError, ssl.SSLError) as exc:
                print(f"{sni:<30} offer={offer:<16} -> ERR {type(exc).__name__}: {exc}")

    if not paths:
        return 0
    print("\n=== HTTP/1.1 GET on xhttp paths (first response line) ===")
    for sni in snis:
        for path in paths:
            try:
                with socket.create_connection((host, port), timeout) as raw:
                    with context_for(["http/1.1"]).wrap_socket(raw, server_hostname=sni) as tls:
                        tls.settimeout(timeout)
                        req = f"GET {path} HTTP/1.1\r\nHost: {sni}\r\nConnection: close\r\n\r\n"
                        tls.sendall(req.encode())
                        data = tls.recv(256)
                        first = data.splitlines()[0].decode("ascii", "replace") if data else "<empty>"
                        print(f"{sni:<30} {path:<34} -> {first[:80]}")
            except (OSError, ssl.SSLError) as exc:
                print(f"{sni:<30} {path:<34} -> ERR {type(exc).__name__}: {exc}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--host", required=True, help="服务端 IP / 域名")
    ap.add_argument("--port", type=int, default=443)
    ap.add_argument("--sni", required=True, help="逗号分隔的 SNI 列表")
    ap.add_argument("--path", action="append", default=[], help="xhttp path，可重复")
    ap.add_argument("--timeout", type=float, default=5.0)
    args = ap.parse_args()
    return probe(args.host, args.port, [s for s in args.sni.split(",") if s], args.path, args.timeout)


if __name__ == "__main__":
    sys.exit(main())
