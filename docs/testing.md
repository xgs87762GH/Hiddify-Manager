# 测试与验证（fork 维护）

本文档由 fork 维护者添加，记录怎么跑测试、怎么复现一次完整验证，以及踩过的坑。
目标是让"改完代码能不能上线"这个问题有可重复的答案，而不是靠人肉点一遍界面。

测试分四层，从快到慢：

| 层 | 覆盖什么 | 耗时 | 需要数据库 |
| --- | --- | --- | --- |
| 单元测试 | 模板渲染、协议兼容性、订阅链接 | 0.1 s | 否 |
| 前端类型检查 | `admin_v2` 的 TypeScript / Vue 类型 | 数十秒 | 否 |
| 前端构建 | 译文件、Vite 打包 | 10 s 级 | 否 |
| 端到端冒烟 | 启动面板、跑迁移、浏览器打开管理端 | 2 min | **是** |

---

## 1. 单元测试

### 位置

测试在**面板子模块的根目录**下，不是外层仓库：

```
/opt/hiddify-manager/services/panel/src/tests/
├── test_client_template_compatibility.py    # 9 个
├── test_rawhttp_headers.py                  # 5 个
├── test_shadowtls.py                        # 8 个
└── test_sublink_uri_allow_insecure.py       # 6 个
```

共 **28 个测试方法**，其中 18 个带 `subTest`（同一用例跑多组输入）。
`hiddifypanel/panel/node/test_*.py` 是 gRPC 生成的桩，**不是**测试，别被名字骗了。

这几个文件都是纯渲染测试：直接喂 Jinja2 模板和构造出的上下文对象，断言渲染结果。
**不需要数据库，也不需要起服务**，所以跑得极快。

### 怎么跑

`pytest` 不在面板的依赖里（`pyproject.toml` 的 `dev` 只有 ruff / ty / mkdocs 等），
所以要装到**旁边**，不要装进面板的 venv——装进去会污染 `/opt/hiddify-manager/.venv313`，
让服务器上的依赖和锁文件不一致。

```bash
sudo -i
uv pip install --python /opt/hiddify-manager/.venv313/bin/python --target /tmp/pylib pytest

cd /opt/hiddify-manager/services/panel/src
PYTHONPATH=/tmp/pylib /opt/hiddify-manager/.venv313/bin/python -m pytest tests -p no:cacheprovider -q
```

正常输出：

```
28 passed, 18 subtests passed in 0.11s
```

`-p no:cacheprovider` 是避免往源码树里写 `.pytest_cache`，让 `git status` 保持干净。

### 反向验证：确认测试真的在守护逻辑

测试全绿不等于测试有效。验证方式是**故意改坏被测逻辑，看它会不会红**。

以订阅链接的 `allowInsecure` 门控为例（`hiddify/Hiddify-Manager#5438`：Xray ≥ 26.1.1 见到
`allowInsecure` 会整份配置加载失败，所以新版改用固定证书 pin）：

1. 找到模板里的门控，改成恒真：

```bash
cd /opt/hiddify-manager/services/panel/src
grep -n "allowInsecure" hiddifypanel/proxy_v3/proxy_templates/sublink/uri/security/tls_http.j2
```

2. 把门控条件改成恒真，重跑：

```bash
PYTHONPATH=/tmp/pylib /opt/hiddify-manager/.venv313/bin/python -m pytest tests -p no:cacheprovider -q
```

预期 **4 个失败**（`10 errors` 量级，取决于改动方式）。

3. 改回去，确认恢复全绿。

这一步的意义：如果改坏了逻辑测试还是全绿，说明测试是摆设。实测这 4 个文件确实能抓到回归。

### 反复跑：确认没有 flaky

```bash
for i in $(seq 1 10); do
  PYTHONPATH=/tmp/pylib /opt/hiddify-manager/.venv313/bin/python -m pytest tests -p no:cacheprovider -q 2>&1 | tail -1
done
```

实测 10 轮全部 `28 passed`，耗时稳定在 0.10–0.12 s。**单元测试无 flaky**。

---

## 2. 前端类型检查

```bash
cd /opt/hiddify-manager/services/panel/src/hiddifypanel/admin_v2
node_modules/.bin/vue-tsc --noEmit
```

---

## 3. 前端构建

```bash
cd /opt/hiddify-manager/services/panel/src/hiddifypanel/admin_v2
npm ci --no-audit --no-fund
npm run build
```

产物直接输出到 `hiddifypanel/static/admin-v2/`（不在 git 里，被 `.gitignore` 忽略）。

实测（node v22，16 核）：

| 阶段 | 耗时 | 峰值内存 |
| --- | --- | --- |
| `npm ci`（约 200 包） | 3.6 s | 495 MB |
| `npm run build` | 7.9 s | 980 MB |
| 产物 | 239 个文件 / 11 MB | — |

CPU 不是瓶颈，内存才是；1 GB 内存的机器要靠 `update.sh` 自动挂的 swap。

### 复现"译文件损坏导致构建失败"

`translations.i18n/*.json` 通过 `import.meta.glob` 在**构建期**打进包，不是运行时读文件。
任一译文件 JSON 不合法，`npm run build` 直接以退出码 1 结束：

```
error during build:
[hiddify-admin-v2-translations] Expected ',' or '}' after property value in JSON at position ...
```

复现方法：往任一 `translations.i18n/*.json` 里加一个多余逗号，跑 `npm run build`。

因为 `update.sh` 是**先 `git merge --ff-only` 再 `make build`**，构建失败时 git 已指向新版、
`install.sh` 却没执行，结果是"代码是新的、面板还跑着旧的"的半升级状态。详见
[server-update.md](server-update.md) 第 4 节。

---

## 4. 端到端冒烟

这是唯一能验证"界面真的能打开"的一层。它要做的事：
起一个干净库 → 启动面板跑迁移 → 用真实浏览器打开管理端 V2 → 断言渲染。

### 4.1 环境要求

面板有**两个硬依赖**，没有变通办法：

- **MySQL / MariaDB**：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...` 读 enum 列定义，
  SQLite 等后端不支持。本地想跑起来验证**必须**装 MariaDB，不能图省事用 SQLite。
- **真 Redis**：缓存、session、`evalsha` 都用它，`fakeredis` 之类替身跑不通。

另外需要 `wireguard-tools`（缺 `wg` 命令会报错）。

### 4.2 依赖版本：一个必须注意的坑

按**包名**装依赖会把 `flask-admin` 装成 2.2.1，而锁文件要求 `1.6.1`。
2.x 移除了 `Admin.__init__` 的 `base_template` 参数，面板直接创建不了应用。

必须按 `uv.lock` 的**精确版本**装：

```bash
uv pip install --python "$VENV/bin/python" -q "flask-admin==1.6.1"
```

验证装对了：

```bash
"$VENV/bin/python" -c "
import flask_admin, inspect
print(flask_admin.__version__)   # 应为 1.6.1
print('base_template' in inspect.signature(flask_admin.Admin.__init__).parameters)  # 应为 True
"
```

`mysqlclient` 需要编译，本地验证可以换成 `pymysql`（把 URI 的驱动改成 `mysql+pymysql://`）。

### 4.3 启动方式：必须用 ASGI

生产用 **granian** 跑 ASGI（`hiddifypanel.apps.asgi_app:app`，端口 9000）。
不要用 Flask 自带的开发服务器——它是 WSGI，`admin/live/` 那条 SSE 长连接路由
**只在 ASGI 应用里注册**，用 WSGI 跑会 404，你会误判成产品缺陷。

```bash
cd /opt/hiddify-manager/services/panel/src
export HIDDIFY_CFG_PATH=/opt/hiddify-manager/data/hiddify-panel/app.cfg
"$VENV/bin/python" -m granian --interface asgi hiddifypanel.apps.asgi_app:app --host 127.0.0.1 --port 9000
```

### 4.4 断言时机：迁移是异步的

监听端口 ≠ 迁移已经跑完。迁移是在 worker 启动**之后**才执行的，
所以在监听后立刻发请求会拿到 500。

正确做法是**轮询 `db_version`**，等到 184 再断言：

```bash
for i in $(seq 1 300); do
  DBV=$(mysql -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';")
  [ "$DBV" = "184" ] && break
  sleep 1
done
```

全新库会从 `_v1` 一路跑到 `_v184`，建出 **21 张表** + 存储过程 `add_usage_json`。
实测在 MariaDB 11.8 上耗时 **44–60 秒**（波动主要来自外部网络探测）。

### 4.5 浏览器验证

用 Playwright + Chromium。未登录访问 admin 会 302 跳登录页，所以要先拿到认证。

冒烟时可以利用这个机制：面板在 Basic 认证里**密码留空**时，会把 username 当作 UUID 去查账号
（`hiddifypanel/auth.py:260-266`），且对**空密码的账号**放行（`:240` 的 `account.password != ""` 才踢出）。
全新库建出的管理员密码就是空的，所以 `Authorization: Basic base64("<uuid>:")` 可以直接进：

```python
import base64
from playwright.sync_api import sync_playwright

PP   = "<从 str_config 读 proxy_path>"
UUID = "<admin_user 的 uuid>"
BASE = f"http://127.0.0.1:9000/{PP}"
AUTH = "Basic " + base64.b64encode(f"{UUID}:".encode()).decode()

errs, bad = [], []
with sync_playwright() as p:
    b = p.chromium.launch(args=["--no-sandbox"])
    ctx = b.new_context(viewport={"width": 1440, "height": 900},
                        extra_http_headers={"Authorization": AUTH})
    pg = ctx.new_page()
    pg.on("pageerror", lambda e: errs.append(str(e)[:200]))
    pg.on("response", lambda r: bad.append(f"{r.status} {r.url[:90]}")
          if r.status >= 400 and "/admin/live/" not in r.url else None)

    for route in ["", "users", "settings", "domains", "admins", "nodes"]:
        r = pg.goto(f"{BASE}/admin/v2/{route}", wait_until="load", timeout=60000)
        # 等 SPA 挂载：文本长度 > 100，超时重试一次
        for _ in range(2):
            try:
                pg.wait_for_function(
                    "() => document.body && document.body.innerText.length > 100",
                    timeout=20000)
                break
            except Exception:
                pg.wait_for_timeout(3000)
        pg.wait_for_timeout(2000)
        t = pg.inner_text("body")
        nav = ("Dashboard", "Users", "Settings", "Domains", "仪表盘", "用户", "设置", "域名")
        rendered = len(t.strip()) > 100 and any(k in t for k in nav)
        print(f"{route or '/'}: {r.status} rendered={rendered} len={len(t.strip())}")

    b.close()
print(f"JS错误={len(errs)} 4xx/5xx={len(bad)}")
```

几个要点：

- **安静默认英文**。断言要用语言无关的判定（中英文导航词任一），不要只认中文。
- **路由名别猜**。V2 的路由定义在 `admin_v2/src/router/index.ts`，首页是 `/`（`name: 'dashboard'`），
  **没有 `/dashboard` 这个路径**。真实路由：
  `""`（首页）、`node`、`nodes`、`users`、`message`、`admins`、`account`、`settings`、
  `protocols`、`domains`、`backup`、`outbounds`、`custom-proxies[/new|/:id]`、
  `templates[/new|/:id]`、`legacy/:path(.*)`，另有独立的 `/quick-setup`。
- **过滤 `admin/live/`**。SSE 长连接在页面导航时会被浏览器主动中止（404 / `ERR_ABORTED`），
  这是正常行为，不是缺陷。
- **`wait_until` 用 `load` 不要用 `networkidle`**。live 通道是长连接，永远等不到 idle。

### 4.6 停止服务：别用 `kill -9`

`kill -9` 会让连接池来不及关闭，MySQL 里留下大量 `Sleep` 连接，
下一次建库时 `DROP DATABASE` 卡在 **`Waiting for table metadata lock`**。

正确做法：先 `SIGTERM` 优雅停止，再清理残留连接。

```bash
for pid in $(pgrep -f "granian --interface asgi"); do kill -TERM $pid; done
sleep 3
for pid in $(pgrep -f "granian --interface asgi"); do kill -9 $pid; done

# 每轮开始前清掉残留连接
for id in $(mysql -N -e "SELECT id FROM information_schema.processlist WHERE user='hp';"); do
  mysql -e "KILL $id;"
done
```

### 4.7 反复冒烟的实测结果

按上面的方法跑 3 轮，每轮完整走一遍"清库 → 迁移 → 启动 → HTTP 断言 → 浏览器断言 → 优雅停止"：

| 轮次 | 迁移耗时 | db_version | 表数 | 页面渲染 | JS 错误 | 4xx/5xx | 结果 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 47 s | 184 | 21 | 6/6 | 0 | 0 | PASS |
| 2 | 50 s | 184 | 21 | 6/6 | 0 | 0 | PASS |
| 3 | 50 s | 184 | 21 | 6/6 | 0 | 0 | PASS |

**端到端冒烟无 flaky**，每轮约 2 分钟。

面板完整启动后另有几个可用于断言的基线数字：
**445 条路由、31 个蓝图、调度器 9 个任务**。

---

## 5. 常见失败与处理

| 现象 | 原因与处理 |
| --- | --- |
| `ModuleNotFoundError: No module named 'hiddifypanel'` | `PYTHONPATH` 没包含面板源码根目录 |
| `KeyError: REDIS_URI_MAIN` | `app.cfg` 缺 Redis 配置项 |
| `near "SHOW": syntax error` | 用了 SQLite。面板硬依赖 MySQL，见 4.1 |
| `Admin.__init__() got an unexpected keyword argument 'base_template'` | `flask-admin` 装成了 2.x，必须装 1.6.1，见 4.2 |
| 迁移报 `near 'CREATE PROCEDURE'` | `_v140` 把 `DROP PROCEDURE` 和 `CREATE PROCEDURE` 拼在一次 `db_execute`，SQLAlchemy `text()` 默认不允许多语句。本地验证可打补丁：按**第一个**分号切出 `DROP`（存储过程体内含分号，不能按全部分号切），剩余部分整体交给底层游标执行 |
| `admin/live/` 404 | 用了 WSGI 开发服务器。生产是 granian ASGI，见 4.3 |
| 迁移还没跑完就断言，HTTP 500 | 迁移是异步的，轮询 `db_version` 到 184 再断言，见 4.4 |
| `DROP DATABASE` 超时 / `Waiting for table metadata lock` | 上轮被 `kill -9`，残留 Sleep 连接锁表。见 4.6 |
| Playwright 报缺 `libnspr4.so` 之类 | Chromium 系统库缺失，`apt-get install libnspr4 libnss3 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libgbm1 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 libcairo2` |
| 启动慢（>100 s）且日志里反复出现 `ooni` | 离线环境下启动会做外部域名探测并重试。本地验证可把 `net.get_random_domains` 替换成 `net.random_fake_sites` 跳过 |
| 浏览器断言 `rendered=False` 但 HTTP 200 | 多半是路由名写错或只认中文关键词。见 4.5 的两条要点 |

---

## 6. 维护提醒

- 单元测试跑在**源码目录**下，会往里写 `__pycache__`；用 `-p no:cacheprovider` 只挡住
  `.pytest_cache`，`__pycache__` 仍需靠 `.gitignore`。
- 每次改模板（`.j2`）后跑一遍单元测试，它们正是为模板回归写的。
- 端到端冒烟**一定要在干净库上跑**；复用旧库会跳过迁移链，就验证不到 `_vNNN` 的问题。
- 冒烟完记得把 MariaDB / Redis 停掉并确认没有残留连接，别占着服务器资源。
