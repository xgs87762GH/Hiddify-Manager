"""订阅 / API 压力测试驱动（零第三方依赖，Python 3.10+）。

仓库内入口契约::

    async def run(targets, concurrency=200, duration_s=300, timeout_s=30.0) -> dict

返回 ``{'p50','p95','p99','errors','error_rate','samples', ...}``，采样含 granian RSS
与每分钟请求数。命令行用法::

    python3 tools/load/load_driver.py --concurrency 200 --duration 300 \
        --url http://127.0.0.1:9000/<proxy_path>/api/v2/admin/me/ \
        --auth 'Basic xxx' \
        --url http://127.0.0.1:9000/<proxy_path>/<uuid>/auto/

为什么不用 httpx：VM 上是离线环境，连 pytest 都要侧载；纯标准库（asyncio +
ThreadPoolExecutor + urllib）在两轮回归里可直接运行，不必往服务器装依赖。
``targets`` 既可以是 URL 字符串列表，也可以是 ``{'url': ..., 'headers': {...}}``。
"""
from __future__ import annotations

import argparse
import asyncio
import json
import random
import re
import ssl
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

_LAT: list[float] = []
_ERR: dict[str, int] = {}
_LOCK = threading.Lock()
_STOP = threading.Event()
_MINUTE: dict[int, int] = {}


def _hit(url: str, headers: dict[str, str], timeout: float, ctx: ssl.SSLContext | None, started: float) -> None:
    req = urllib.request.Request(url, headers=headers)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
            resp.read(4096)
            code: int | str = resp.status
    except urllib.error.HTTPError as exc:
        code = exc.code
    except Exception as exc:  # noqa: BLE001 - 压测要记录任何失败类型
        code = type(exc).__name__
    dt = (time.perf_counter() - t0) * 1000
    if not (isinstance(code, int) and 200 <= code < 400):
        # 目标不可达时别空转：5 秒能打出 7 万次 URLError，先把压测机自己打满
        time.sleep(0.01)
    minute = int((t0 - started) // 60)
    with _LOCK:
        _LAT.append(dt)
        _MINUTE[minute] = _MINUTE.get(minute, 0) + 1
        if not (isinstance(code, int) and 200 <= code < 400):
            key = str(code)
            _ERR[key] = _ERR.get(key, 0) + 1


def _worker(targets: list[tuple[str, dict[str, str]]], timeout: float, ctx, started: float) -> None:
    while not _STOP.is_set():
        url, headers = random.choice(targets)
        _hit(url, headers, timeout, ctx, started)


def _pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    k = max(0, min(len(ordered) - 1, int(round((p / 100) * len(ordered) + 0.5)) - 1))
    return ordered[k]


def granian_rss_mb() -> float:
    """面板 worker 的 RSS 合计；接近 500MB 会触发 granian 的 worker 回收。"""
    try:
        out = subprocess.run(["pgrep", "-af", "granian"], capture_output=True, text=True).stdout
    except OSError:
        return -1.0
    total = 0.0
    for line in out.splitlines():
        pid = line.split()[0]
        try:
            with open(f"/proc/{pid}/status") as fh:
                match = re.search(r"VmRSS:\s+(\d+) kB", fh.read())
                if match:
                    total += int(match.group(1)) / 1024
        except OSError:
            continue
    return total


def _sample_rss(interval: float, samples: list[float]) -> None:
    while not _STOP.is_set():
        samples.append(granian_rss_mb())
        _STOP.wait(interval)


def _normalize(targets, auth: list[str], ua: str) -> list[tuple[str, dict[str, str]]]:
    result: list[tuple[str, dict[str, str]]] = []
    for index, target in enumerate(targets):
        if isinstance(target, str):
            url, headers = target, {"User-Agent": ua}
        else:
            url = target["url"]
            headers = {"User-Agent": ua, **target.get("headers", {})}
        if index < len(auth) and auth[index]:
            value = auth[index]
            headers["Authorization"] = value if value.lower().startswith("basic ") else f"Basic {value}"
        result.append((url, headers))
    return result


async def run(
    targets: list[str] | list[dict],
    concurrency: int = 200,
    duration_s: int = 300,
    timeout_s: float = 30.0,
    *,
    auth: list[str] | None = None,
    ua: str = "v2rayN/6.31",
    insecure: bool = False,
    rss_interval: float = 5.0,
) -> dict:
    """并发压测；允许降级，返回值供调用方做「压测后是否自恢复」的断言。

    `samples` 里的 RSS 采样与 `per_minute` 的分钟计数用于定位降级窗口。
    不用 ``with ThreadPoolExecutor``：其 ``__exit__`` 会 join 所有线程，而阻塞在
    30s 超时上的 200 个线程足以把收尾拖成几十分钟。
    """
    _LAT.clear()
    _ERR.clear()
    _MINUTE.clear()
    _STOP.clear()

    ctx = ssl._create_unverified_context() if insecure else None
    pairs = _normalize(targets, auth or [], ua)
    if not pairs:
        raise ValueError("at least one --url is required")

    rss: list[float] = []
    threading.Thread(target=_sample_rss, args=(rss_interval, rss), daemon=True).start()

    pool = ThreadPoolExecutor(max_workers=concurrency)
    started = time.perf_counter()
    loop = asyncio.get_running_loop()
    futures = [loop.run_in_executor(pool, _worker, pairs, timeout_s, ctx, started) for _ in range(concurrency)]
    try:
        await asyncio.sleep(duration_s)
    finally:
        _STOP.set()
        # 不等线程：它们各自会在自己的 socket 超时后自然结束
        for future in futures:
            future.cancel()
        pool.shutdown(wait=False, cancel_futures=True)
    elapsed = time.perf_counter() - started

    # STOP 之后仍可能有在途请求写进来，取一次快照保证 requests / per_minute / 分位数一致
    with _LOCK:
        lat = list(_LAT)
        errors = dict(_ERR)
        per_minute = dict(sorted(_MINUTE.items()))
    total = len(lat)
    error_count = sum(errors.values())
    return {
        "elapsed_s": round(elapsed, 1),
        "concurrency": concurrency,
        "requests": total,
        "rps": round(total / elapsed, 1) if elapsed else 0,
        "error_rate": round(error_count / total, 4) if total else 0,
        "errors": errors,
        "p50": round(_pct(lat, 50), 1),
        "p95": round(_pct(lat, 95), 1),
        "p99": round(_pct(lat, 99), 1),
        "max_ms": round(max(lat), 1) if lat else 0,
        "rss_mb_max": round(max(rss), 1) if rss else -1,
        "per_minute": per_minute,
        "samples": [round(value, 1) for value in rss],
    }


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--url", action="append", required=True, help="目标 URL，可重复；与 --auth 按顺序对应")
    ap.add_argument("--auth", action="append", default=[], help="Basic 值（可省略 'Basic ' 前缀）")
    ap.add_argument("--ua", default="v2rayN/6.31")
    ap.add_argument("--concurrency", type=int, default=200)
    ap.add_argument("--duration", type=int, default=300, dest="duration_s")
    ap.add_argument("--timeout", type=float, default=30.0, dest="timeout_s")
    ap.add_argument("--insecure", action="store_true", help="跳过自签证书校验")
    ap.add_argument("--output", help="把结果 JSON 写到文件（也打印到 stdout）")
    args = ap.parse_args()

    result = asyncio.run(
        run(
            args.url,
            concurrency=args.concurrency,
            duration_s=args.duration_s,
            timeout_s=args.timeout_s,
            auth=args.auth,
            ua=args.ua,
            insecure=args.insecure,
        )
    )
    text = json.dumps(result, ensure_ascii=False, indent=2)
    print(text, flush=True)
    if args.output:
        with open(args.output, "w", encoding="utf-8") as fh:
            fh.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
