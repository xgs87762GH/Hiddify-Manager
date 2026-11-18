"""Windows 客户端逐节点协议矩阵联测（用客户端自带的 hiddify-core CLI）。

两种输入模式：

* ``--links``（判定 xhttp H1/H2/H3 的推荐入口）：直接读面板 ``all.txt`` 的明文分享
  链接，用 ``HiddifyCli.exe parse`` 逐条转成 sing-box outbound。URI 层完整保留
  ``alpn=http/1.1|h2|h3`` 语义；面板给 sing-box 客户端的 ``full-singbox.json``
  会把同一条腿渲染成 ``transport.type=http``，无法还原 H1/H2/H3。
* ``--config``：读 ``full-singbox.json``，按 ALPN 分组做全协议回归。

每条节点的链路：``parse`` → ``build``（补本地 mixed inbound）→ 把 ``route.final``
指向唯一真实 outbound → ``srun`` 启动核心 → ``curl.exe -x http://127.0.0.1:<port>``
访问 ``https://www.gstatic.com/generate_204``，断言 204。

为什么支持覆盖 ``server``：自建测试机在 NAT 后，订阅里的节点可能指向不可回连的公网
IP。把连接地址改到 VM 内网 IP、同时**保留原来的 SNI / path / alpn / pinned cert**，
haproxy 仍按原 path/SNI 路由，因此能真实复现「xhttp + ALPN http/1.1 的 H1 腿」行为。
不传 ``--server`` 即使用订阅原始地址。

用法::

    python tools/client_matrix.py --links _artifacts/sub-all.txt ^
        --cli hiddify-app/build/windows/x64/runner/Release/HiddifyCli.exe ^
        --server 192.168.138.129 --out _artifacts/client-matrix-uri.json

只测重点分组时可加 ``--group xhttp`` / ``--per-group 3``。串行执行，端口从
``--port-base`` 递增；每次结束都会 terminate 核心，不留后台进程。
"""
from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
import time
from collections import defaultdict
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlparse

TARGET = "https://www.gstatic.com/generate_204"
REAL_TYPES = {
    "vless", "trojan", "vmess", "shadowsocks", "hysteria2", "tuic", "anytls",
    "shadowsocksr", "ssh", "http", "socks",
}
LOG_HINTS = ("FATAL", "error", "failed", "timeout", "TLS", "handshake", "malformed", "404")


def alpn_group(alpn: str | list | None) -> str:
    """把 ALPN 归一成 xhttp/H1|H2|H3|plain；同时接受字符串与数组两种 sing-box 写法。"""
    if isinstance(alpn, (list, tuple)):
        vals = [str(v).strip() for v in alpn if str(v).strip()]
    else:
        vals = [v.strip() for v in str(alpn or "").split(",") if v.strip()]
    if "h3" in vals:
        return "xhttp/H3"
    if "http/1.1" in vals and "h2" not in vals:
        return "xhttp/H1"
    if "h2" in vals and "http/1.1" not in vals:
        return "xhttp/H2"
    if vals:
        return "xhttp/" + "+".join(sorted(vals))
    return "xhttp/plain"


def group_of(outbound: dict) -> str:
    """``full-singbox.json`` 里的分组：把 ``transport.type=http`` 按 ALPN 还原 H1/H2/H3。"""
    transport = outbound.get("transport") or {}
    kind = transport.get("type") or "tcp"
    alpn = (outbound.get("tls") or {}).get("alpn")
    if kind in ("http", "xhttp"):
        return alpn_group(alpn)
    if kind == "httpupgrade":
        return f"httpupgrade/{alpn_group(alpn).split('/')[-1]}"
    return f"{kind}/{','.join(alpn) if isinstance(alpn, list) else (alpn or '-')}"


def real_outbounds(config: dict) -> list[dict]:
    return [o for o in config.get("outbounds", []) if o.get("type") in REAL_TYPES and "server" in o]


def link_meta(link: str, only_type: str = "xhttp") -> dict | None:
    """从 vless:// / vmess:// 分享链接提取 xhttp 元数据；非目标传输返回 None。"""
    link = link.strip()
    try:
        if link.startswith("vless://"):
            url = urlparse(link)
            query = {k: v[0] for k, v in parse_qs(url.query, keep_blank_values=True).items()}
            if only_type and query.get("type") != only_type:
                return None
            return {
                "proto": "vless",
                "group": alpn_group(query.get("alpn")),
                "alpn": query.get("alpn", ""),
                "path": query.get("path", ""),
                "host": url.hostname,
                "port": url.port,
                "sni": query.get("sni", ""),
                "label": unquote(url.fragment),
                "link": link,
            }
        if link.startswith("vmess://"):
            raw = link[len("vmess://"):]
            raw += "=" * (-len(raw) % 4)
            obj = json.loads(base64.urlsafe_b64decode(raw).decode("utf-8"))
            if only_type and obj.get("net") != only_type:
                return None
            return {
                "proto": "vmess",
                "group": alpn_group(obj.get("alpn")),
                "alpn": obj.get("alpn", ""),
                "path": obj.get("path", ""),
                "host": obj.get("add"),
                "port": obj.get("port"),
                "sni": obj.get("sni", ""),
                "label": obj.get("ps", ""),
                "link": link,
            }
    except (ValueError, KeyError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        print(f"  WARN bad link: {type(exc).__name__}: {exc}", flush=True)
    return None


def parse_link(cli: Path, work: Path, index: int, link: str) -> tuple[dict | None, str]:
    """调用客户端自带的转换器，把单条分享链接转成 sing-box outbound。"""
    link_file = work / f"link-{index}.txt"
    parsed = work / f"parsed-{index}.json"
    link_file.write_text(link.strip() + "\n", encoding="utf-8")
    proc = subprocess.run(
        [str(cli), "parse", str(link_file), "-o", str(parsed)],
        capture_output=True, text=True, timeout=60,
    )
    if proc.returncode != 0 or not parsed.exists():
        return None, f"parse rc={proc.returncode}: {(proc.stderr or proc.stdout)[-300:]}"
    try:
        data = json.loads(parsed.read_text(encoding="utf-8"))
        outs = data.get("outbounds", []) if isinstance(data, dict) else data
        for outbound in outs:
            if outbound.get("type") in REAL_TYPES and "server" in outbound:
                return outbound, ""
    except (OSError, ValueError, json.JSONDecodeError) as exc:
        return None, f"parse output: {exc}"
    return None, "parse output has no real outbound"


def run_one(
    cli: Path, work: Path, outbound: dict, index: int, port: int,
    timeout: int, server: str | None, group: str, meta: dict,
    log_level: str = "warn", exit_ip_url: str = "",
) -> dict:
    tag = outbound.get("tag") or f"out-{index}"
    item = json.loads(json.dumps(outbound))  # deep copy, never mutate the subscription
    original = item.get("server")
    if server:
        item["server"] = server
    item["tag"] = "probe"

    proxy_in = work / f"in-{index}.json"
    full_cfg = work / f"cfg-{index}.json"
    core_log = work / f"core-{index}.log"
    core_file = work / f"core-{index}.core.log"
    proxy_in.write_text(json.dumps({"outbounds": [item]}, ensure_ascii=False), encoding="utf-8")

    result = {
        "index": index,
        "tag": tag.encode("ascii", "replace").decode(),
        "label": meta.get("label", ""),
        "proto": meta.get("proto", ""),
        "group": group,
        "type": item.get("type"),
        "original_server": original,
        "connect_server": item.get("server"),
        "port": item.get("server_port"),
        "alpn": (item.get("tls") or {}).get("alpn"),
        "path": (item.get("transport") or {}).get("path"),
        "transport": (item.get("transport") or {}).get("type"),
        "ok": False,
    }

    build = subprocess.run(
        [str(cli), "build", "-c", str(proxy_in), "--in-proxy-port", str(port), "-o", str(full_cfg)],
        capture_output=True, text=True, timeout=60,
    )
    if build.returncode != 0 or not full_cfg.exists():
        result["error"] = f"build rc={build.returncode}: {(build.stderr or build.stdout)[-300:]}"
        return result

    # 单节点输入会被 build 补上 selector；把 route.final 直接指向唯一真实 outbound
    cfg = json.loads(full_cfg.read_text(encoding="utf-8"))
    cfg.setdefault("route", {})["final"] = "probe"
    cfg["route"]["rules"] = []
    cfg.setdefault("log", {})["level"] = log_level
    # build 把结构化日志固定写到 data/box.log（所有节点共享，无法归因）；改成每条独立文件
    cfg["log"]["output"] = core_file.name
    core_file.write_text("", encoding="utf-8")
    # build 把 dns-in 固定写死在 12337、clash_api 固定写死在 6756。桌面端 Hiddify.exe
    # 若正在运行就会占用 12337，导致核心 FATAL 退出；这里按节点序号改成唯一端口。
    for inbound in cfg.get("inbounds", []):
        if str(inbound.get("tag", "")).startswith("dns-in"):
            inbound["listen_port"] = port + 1000
    clash_api = (cfg.get("experimental") or {}).get("clash_api")
    if isinstance(clash_api, dict) and "external_controller" in clash_api:
        host = clash_api["external_controller"].rsplit(":", 1)[0]
        clash_api["external_controller"] = f"{host}:{port + 2000}"
    full_cfg.write_text(json.dumps(cfg, ensure_ascii=False), encoding="utf-8")

    with core_log.open("w", encoding="utf-8", errors="replace") as log_fh:
        proc = subprocess.Popen(
            [str(cli), "srun", "-c", str(full_cfg)],
            stdout=log_fh, stderr=subprocess.STDOUT, cwd=str(work),
            creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
        )
        try:
            time.sleep(1.5)
            if proc.poll() is not None:
                result["error"] = f"core exited early rc={proc.returncode}"
            else:
                t0 = time.perf_counter()
                try:
                    curl = subprocess.run(
                        ["curl.exe", "-s", "-o", "NUL", "-w", "%{http_code}",
                         "--max-time", str(timeout), "-x", f"http://127.0.0.1:{port}", TARGET],
                        capture_output=True, text=True, timeout=timeout + 5,
                    )
                    code = (curl.stdout or "").strip()[-3:]
                    result["http"] = code
                    result["latency_ms"] = round((time.perf_counter() - t0) * 1000)
                    result["ok"] = code == "204"
                    if result["ok"] and exit_ip_url:
                        try:
                            ip = subprocess.run(
                                ["curl.exe", "-s", "--max-time", str(min(timeout, 5)),
                                 "-x", f"http://127.0.0.1:{port}", exit_ip_url],
                                capture_output=True, text=True, timeout=min(timeout, 5) + 3,
                            )
                            result["exit_ip"] = (ip.stdout or "").strip()[:64] or "<empty>"
                        except subprocess.TimeoutExpired:
                            result["exit_ip"] = "<timeout>"
                except subprocess.TimeoutExpired:
                    result["error"] = "curl timeout"
        finally:
            if proc.poll() is None:
                subprocess.run(["taskkill", "/F", "/T", "/PID", str(proc.pid)],
                               capture_output=True, text=True)
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass

    # 核心退出后再读日志：进程运行期间缓冲区未 flush，之前只能读到一条 WARN
    try:
        source = core_file if core_file.exists() else core_log
        lines = [re.sub(r"\x1b\[[0-9;]*m", "", ln)
                 for ln in source.read_text(encoding="utf-8", errors="replace").splitlines()]
        result["malformed_http"] = any("malformed http" in ln.lower() for ln in lines)
        result["log_hits"] = [
            ln.strip() for ln in lines if any(h.lower() in ln.lower() for h in LOG_HINTS)
        ][-8:]
        result["core_log_tail"] = [ln.strip() for ln in lines][-12:]
    except OSError:
        pass
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--links", help="面板 all.txt 明文分享链接")
    src.add_argument("--config", help="面板 full-singbox.json")
    ap.add_argument("--cli", required=True, help="HiddifyCli.exe 路径")
    ap.add_argument("--server", default="", help="覆盖连接地址（保留 SNI/path/alpn）；省略则不覆盖")
    ap.add_argument("--link-type", default="xhttp", help="--links 模式只取该传输；空串=全部")
    ap.add_argument("--port-base", type=int, default=21000)
    ap.add_argument("--timeout", type=int, default=8)
    ap.add_argument("--log-level", default="warn", help="核心日志级别；失败取证用 debug")
    ap.add_argument("--exit-ip-url", default="https://ipinfo.io/ip",
                    help="连通成功后取的出口 IP 端点")
    ap.add_argument("--no-exit-ip", action="store_true",
                    help="跳过出口 IP 校验（PowerShell 无法可靠传空字符串参数）")
    ap.add_argument("--per-group", type=int, default=0, help="每组最多测几条；0=全部")
    ap.add_argument("--group", default="", help="只测名字含该子串的分组，如 xhttp")
    ap.add_argument("--out", default="", help="报告 JSON 路径")
    args = ap.parse_args()

    cli = Path(args.cli).resolve()
    if not cli.exists():
        print(f"CLI not found: {cli}")
        return 2
    work = Path("_artifacts/client-matrix-work").resolve()
    work.mkdir(parents=True, exist_ok=True)
    # build 生成的配置里 log.output = data/box.log；核心不会自己建目录，缺了就 FATAL 退出
    (work / "data").mkdir(exist_ok=True)

    buckets: dict[str, list[tuple[dict, dict]]] = defaultdict(list)
    hosts: dict[str, int] = defaultdict(int)
    mode = "links"

    if args.links:
        lines = Path(args.links).read_text(encoding="utf-8", errors="replace").splitlines()
        for line in lines:
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            meta = link_meta(line, args.link_type)
            if not meta:
                continue
            hosts[str(meta.get("host"))] += 1
            buckets[meta["group"]].append(({}, meta))
    else:
        mode = "config"
        config = json.loads(Path(args.config).read_text(encoding="utf-8"))
        for outbound in real_outbounds(config):
            group = group_of(outbound)
            hosts[str(outbound.get("server"))] += 1
            buckets[group].append((outbound, {"label": outbound.get("tag", ""), "proto": outbound.get("type", "")}))

    print(f"mode={mode} groups={ {g: len(v) for g, v in sorted(buckets.items())} }")
    print(f"hosts={dict(sorted(hosts.items()))}")
    selected: list[tuple[str, dict, dict]] = []
    for group in sorted(buckets):
        if args.group and args.group not in group:
            continue
        items = buckets[group]
        if args.per_group:
            items = items[: args.per_group]
        selected.extend((group, outbound, meta) for outbound, meta in items)
    print(f"selected={len(selected)} target={TARGET} server_override={args.server or '<none>'}", flush=True)

    results = []
    for i, (group, outbound, meta) in enumerate(selected):
        port = args.port_base + i
        if mode == "links":
            outbound, err = parse_link(cli, work, i, meta["link"])
            if not outbound:
                results.append({"index": i, "group": group, "label": meta.get("label", ""),
                                "proto": meta.get("proto", ""), "ok": False, "error": err})
                print(f"  FAIL [{group:<22}] parse: {err[:90]}", flush=True)
                continue
        res = run_one(cli, work, outbound, i, port, args.timeout, args.server or None,
                      group, meta, args.log_level,
                      "" if args.no_exit_ip else args.exit_ip_url)
        results.append(res)
        label = (meta.get("label") or "").encode("ascii", "replace").decode()[:42]
        status = "PASS" if res["ok"] else "FAIL"
        print(f"  {status} [{res['group']:<18}] {res.get('http', '-'):>3} "
              f"{res.get('latency_ms', 0):>6}ms  {label:<42} {res.get('exit_ip', '')[:16]:<16} "
              f"{res.get('error', '')[:60]}", flush=True)
        time.sleep(0.4)

    summary: dict[str, dict] = {}
    for group in sorted({r["group"] for r in results}):
        rows = [r for r in results if r["group"] == group]
        summary[group] = {
            "total": len(rows),
            "ok": sum(1 for r in rows if r["ok"]),
            "fail": sum(1 for r in rows if not r["ok"]),
            "malformed_http": sum(1 for r in rows if r.get("malformed_http")),
        }
    report = {
        "mode": mode, "target": TARGET, "server_override": args.server, "cli": str(cli),
        "group_counts": {g: len(v) for g, v in sorted(buckets.items())},
        "hosts": dict(sorted(hosts.items())),
        "exit_ips": sorted({r["exit_ip"] for r in results if r.get("exit_ip")}),
        "summary": summary, "results": results,
    }
    out = Path(args.out) if args.out else work / "report.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print("\nBY GROUP (ok/fail/malformed):")
    for group, row in summary.items():
        print(f"  {group:<24} {row['ok']:>2}/{row['fail']:<2}/{row['malformed_http']}")
    print(f"TOTAL ok={sum(1 for r in results if r['ok'])} fail={sum(1 for r in results if not r['ok'])}")
    print(f"report={out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
