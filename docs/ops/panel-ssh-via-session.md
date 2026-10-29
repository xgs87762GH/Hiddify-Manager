# 通过面板 Session 跳板 SSH 到 Linux 服务器

> fork 维护备忘。本机直连服务器 `22` / 高端口经常超时（运营商或路径问题），但浏览器能打开管理面板时，可用面板当跳板：浏览器 → 面板 → `asyncssh` → 目标机。
>
> 相关代码：`hiddifypanel/live/ssh.py`、`admin_v2/src/features/ssh/useSsh.ts`、`admin_v2/src/core/live/transports.ts`。

---

## 1. 链路是怎样的

```text
本机浏览器 / 脚本
    │  HTTPS 到面板域名（可走 CDN）
    │  Cookie: session=...
    ▼
Hiddify 面板 (super_admin)
    │  WebSocket:  …/api/v2/admin/ssh/
    │  或 Stream:   …/api/v2/admin/ssh/stream/  + POST …/ssh/<session>/
    │  面板本机用 asyncssh 再连目标
    ▼
目标 Linux（常填 127.0.0.1 = 面板同机；或填公网 IP）
```

页面文案「从你的服务器连接」指的是：**SSH 出口在跑面板的那台机器**，不是你的笔记本。

| 方式 | 何时用 |
| --- | --- |
| 面板 UI「SSH 终端」 | 人手排查，最省事 |
| 带 `session` 的脚本（下文） | 自动化查端口 / 日志 / 版本 |

仅 **super_admin** 可用 SSH 通道；普通 admin 会被拒。

---

## 2. 拿 Session（每次登录后可能变）

1. 浏览器打开管理面板并登录，例如：  
   `https://<面板域名>/<proxy_path>/admin/v2/ssh`
2. F12 → Network → 任意 `api/v2/admin/...` 请求 → Request Headers 里的 `Cookie`。
3. 只要 `session=<一长串>` 这一段（其它分析 Cookie 可省略）。

先验证是否仍有效：

```bash
# Windows 若开了坏掉的系统代理，务必 --noproxy "*"
curl.exe -sS --noproxy "*" \
  "https://<面板域名>/<proxy_path>/api/v2/admin/me/" \
  -H "accept: application/json" \
  -H "referer: https://<面板域名>/<proxy_path>/admin/v2/ssh" \
  -b "session=<SESSION>"
```

成功应返回 JSON，且 `"mode":"super_admin"`。`401` / 登录页 HTML = session 过期，重新登录再拷。

**不要把真实 session / root 密码写进仓库或聊天记录长期保存。**

---

## 3. 面板 UI 怎么连

| 字段 | 同机排查 | 面板能访问的另一台机 |
| --- | --- | --- |
| 服务器 | `127.0.0.1` | 目标 IP / 内网主机名 |
| 端口 | `22`（或你改过的 SSH 端口） | 同左 |
| 用户 | `root`（或有 sudo 的用户） | 同左 |
| 认证 | 密码或私钥 | 同左 |

点连接 → 若弹出 host key，点信任 → 在终端执行命令。

常见排查：

```bash
ss -lntup | grep -E ':(19708|28862|443|22)\b'
/opt/hiddify-manager/services/hiddify-core/hiddify-core version
journalctl -u hiddify-core -n 100 --no-pager
```

---

## 4. 脚本：WebSocket + session（推荐自动化）

依赖：`pip install websockets`  
本机走坏代理时：清空 `HTTP(S)_PROXY`，并设 `NO_PROXY=*`。

协议摘要（与前端一致）：

1. `wss://<面板域名>/<proxy_path>/api/v2/admin/ssh/`，Header 带 `Cookie: session=...` 与 `Origin`。
2. 发 `connect`（可先不带 `fingerprint`）→ 收到 `hostkey` → 再发带指纹的 `connect` → 收到 `ready`。
3. 发 `exec` `{ id, command }` → 收 `exec_data` / `exec_done`；结束发 `close`。

示例（占位符自行替换）：

```python
import asyncio, json, os
for k in ("HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy"):
    os.environ.pop(k, None)
os.environ["NO_PROXY"] = "*"

import websockets

WS = "wss://<面板域名>/<proxy_path>/api/v2/admin/ssh/"
COOKIE = "session=<SESSION>"
HOST, PORT, USER, PASSWORD = "127.0.0.1", 22, "root", "<PASSWORD>"

async def main():
    async with websockets.connect(
        WS,
        additional_headers={
            "Cookie": COOKIE,
            "Origin": "https://<面板域名>",
            "User-Agent": "Mozilla/5.0",
        },
        open_timeout=20,
        max_size=8_000_000,
    ) as ws:
        async def send(obj):
            await ws.send(json.dumps(obj))

        async def recv_types(*types):
            want = set(types)
            while True:
                m = json.loads(await asyncio.wait_for(ws.recv(), timeout=30))
                if m.get("type") in want:
                    return m

        await send({
            "type": "connect",
            "host": HOST, "port": PORT, "username": USER,
            "password": PASSWORD, "fingerprint": "",
            "cols": 120, "rows": 40,
        })
        m = await recv_types("hostkey", "ready", "error")
        if m["type"] == "error":
            raise SystemExit(m)
        if m["type"] == "hostkey":
            await send({
                "type": "connect",
                "host": HOST, "port": PORT, "username": USER,
                "password": PASSWORD, "fingerprint": m["fingerprint"],
                "cols": 120, "rows": 40,
            })
            m = await recv_types("ready", "error")
            if m.get("type") != "ready":
                raise SystemExit(m)

        eid = "job1"
        await send({"type": "exec", "id": eid, "command": "hostname; uptime"})
        while True:
            m = json.loads(await asyncio.wait_for(ws.recv(), timeout=60))
            if m.get("type") == "exec_data" and m.get("id") == eid:
                print(m.get("d") or "", end="")
            elif m.get("type") == "exec_done" and m.get("id") == eid:
                break
        await send({"type": "close"})

asyncio.run(main())
```

备选：**HTTP Stream**（CDN / 仅 HTTP2 时有时比 WS 稳）

1. `GET …/api/v2/admin/ssh/stream/`，`Accept: text/event-stream`，Cookie 同上 → SSE 事件 `session` 给出 id。  
2. `POST …/api/v2/admin/ssh/<session>/?seq=0`，body 为 JSON 字符串数组，例如 `["{\"type\":\"connect\",...}"]`。  
3. 下行仍走 SSE 的 `data:` 行（JSON）。

---

## 5. 本机直连失败时先想什么

| 现象 | 含义 |
| --- | --- |
| 本机对公网 IP 的 `22/443/高端口` 全超时 | 从你网络直达服务器不通；改用面板跳板 |
| `curl` 报连 `127.0.0.1:443` 失败 | 系统代理指向本机坏掉的代理；加 `--noproxy "*"` |
| `/me` 正常但 WS 失败 | 查 Cookie、是否 super_admin、面板路径是否抄错 |
| `connect` 报错 | 目标 SSH 端口、账号密码、或面板机器访问不到目标 |

---

## 6. 安全

- Session 等同管理员登录态，泄漏等于面板被接管。  
- 用完可在面板退出登录使 cookie 失效；root 密码勿长期放在脚本里。  
- 临时脚本用完删除；勿提交含真实 `session=` / 密码的文件。

---

## 7. 和本仓库其它文档

- 服务器升代码：[server-update.md](./server-update.md)  
- 部署：[部署](../deploy/README.md)  
- 面板里开 Snell 但 core 报 `unknown inbound type: snell`：当前正式 hiddify-core 内嵌 sing-box 1.13，无 Snell inbound；与「能否 SSH」无关，排查时别和跳板问题混在一起。
