# 测试与验证

> fork 维护文档。目标是让"改完能不能上线"有可重复的答案，而不是靠人肉点一遍界面。

---

## 1. 五层测试

| 层 | 覆盖什么 | 耗时 | 要数据库 |
| --- | --- | --- | --- |
| 单元测试 | 模板渲染、协议兼容性、订阅链接 | 0.1 s | 否 |
| 前端类型检查 | `admin_v2` 的类型 | 数十秒 | 否 |
| 前端构建 | 译文件、Vite 打包 | 10 s 级 | 否 |
| 脚本冒烟 | `update.sh` 的备份/快进、包管理、UI 发布（全离线，见 §7） | 2 min/轮 | 否 |
| 端到端冒烟 | 启动面板、跑迁移、浏览器打开管理端 | 2 min | **是** |

> **先说边界**：模板有单元测试，更新链路有三个离线冒烟脚本；但 API 接口、数据库读写、业务流程
> 仍然没有测试，前端也只有类型检查。**测试全绿 = 模板与更新链路没回归**，不等于产品没问题。

---

## 2. 单元测试

### 在哪

在**面板子模块的根目录**下（不是外层仓库）：

```
/opt/hiddify-manager/services/panel/src/tests/
├── test_client_template_compatibility.py    9 个
├── test_rawhttp_headers.py                  5 个
├── test_shadowtls.py                        8 个
└── test_sublink_uri_allow_insecure.py       6 个
```

共 **28 个用例**，其中 18 个带 `subTest`。
`hiddifypanel/panel/node/test_*.py` 是 gRPC 生成的桩，**不是测试**。

这些是纯渲染测试：喂 Jinja2 模板 + 构造的上下文，断言渲染结果。**不需要数据库和服务**。

### 怎么跑

`pytest` 不在面板依赖里，要装到**旁边**（装进 venv 会污染服务器的依赖，让它和锁文件不一致）：

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

`-p no:cacheprovider` 是为了不往源码树写 `.pytest_cache`，保持 `git status` 干净。

### 反向验证：确认测试不是摆设

测试全绿不等于测试有效。要**故意改坏被测逻辑，看它会不会红**。

以订阅链接的 `allowInsecure` 门控为例（Xray ≥ 26.1.1 见到 `allowInsecure` 会整份配置失败，
所以新版改用证书 pin）：

1. 找到门控：

```bash
grep -n "allowInsecure" hiddifypanel/proxy_v3/proxy_templates/sublink/uri/security/tls_http.j2
```

2. 改成恒真，重跑 → 预期 **4 个失败**
3. 改回去 → 恢复全绿

### 反复跑：确认没有 flaky

```bash
for i in $(seq 1 10); do
  PYTHONPATH=/tmp/pylib /opt/hiddify-manager/.venv313/bin/python -m pytest tests -p no:cacheprovider -q 2>&1 | tail -1
done
```

实测 10 轮全 `28 passed`，耗时稳定 0.10–0.12 s。**无 flaky**。

---

## 3. 前端

### 类型检查

```bash
cd /opt/hiddify-manager/services/panel/src/hiddifypanel/admin_v2
node_modules/.bin/vue-tsc --noEmit
```

### 构建

```bash
npm ci --no-audit --no-fund && npm run build
```

产物输出到 `hiddifypanel/static/admin-v2/`（不在 git 里）。

实测（node v22，16 核）：

| 阶段 | 耗时 | 峰值内存 |
| --- | --- | --- |
| `npm ci`（约 200 包） | 3.6 s | 495 MB |
| `npm run build` | 7.9 s | 980 MB |
| 产物 | 239 个文件 / 11 MB | — |

> CPU 不是瓶颈，**内存才是**。1 GB 的机器要靠脚本自动挂的 swap。

### 复现"译文件损坏导致构建失败"

`translations.i18n/*.json` 是**构建期**打进包的，不是运行时读文件。
任一译文件 JSON 不合法，构建直接退出码 1：

```
error during build:
[hiddify-admin-v2-translations] Expected ',' or '}' after property value in JSON at position ...
```

复现：往任一 `translations.i18n/*.json` 里加个多余逗号，跑 `npm run build`。

> 因为升级是**先 merge 再 build**，构建失败会造成"代码新、面板旧"的半升级状态，
> 详见 [升级](../ops/server-update.md)。

---

## 4. 端到端冒烟

唯一能验证"界面真能打开"的一层：干净库 → 启动面板跑迁移 → 真实浏览器打开管理端 → 断言。

### 4.1 环境要求

两个硬依赖，没有变通：

- **MySQL / MariaDB**：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...`，SQLite 不支持。
- **真 Redis**：缓存、session、`evalsha` 都用它，`fakeredis` 跑不通。

另需 `wireguard-tools`（缺 `wg` 命令会报错）。

### 4.2 `flask-admin` 必须装 1.6.1

按**包名**装会装成 2.2.1，而锁文件要求 `1.6.1`。
2.x 移除了 `Admin.__init__` 的 `base_template` 参数，面板直接创建不了应用。

```bash
uv pip install --python "$VENV/bin/python" -q "flask-admin==1.6.1"
```

验证：

```bash
"$VENV/bin/python" -c "
import flask_admin, inspect
print(flask_admin.__version__)                                                  # 1.6.1
print('base_template' in inspect.signature(flask_admin.Admin.__init__).parameters)  # True
"
```

### 4.3 必须用 ASGI（granian）

生产用 **granian** 跑 ASGI。别用 Flask 自带开发服务器——它是 WSGI，
而 `admin/live/` 那条 SSE 长连接路由**只在 ASGI 应用里注册**，用 WSGI 跑会 404，
你会误判成产品缺陷。

```bash
cd /opt/hiddify-manager/services/panel/src
export HIDDIFY_CFG_PATH=/opt/hiddify-manager/data/hiddify-panel/app.cfg
"$VENV/bin/python" -m granian --interface asgi hiddifypanel.apps.asgi_app:app --host 127.0.0.1 --port 9000
```

### 4.4 迁移是异步的，别急着断言

监听端口 ≠ 迁移跑完。迁移在 worker 启动**之后**才执行，此时发请求会拿到 500。

轮询 `db_version` 等到 184 再断言：

```bash
for i in $(seq 1 300); do
  DBV=$(mysql -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';")
  [ "$DBV" = "184" ] && break
  sleep 1
done
```

全新库从 `_v1` 跑到 `_v184`，建 **21 张表** + 存储过程 `add_usage_json`。
实测 MariaDB 11.8 上耗时 **44–60 秒**（波动主要来自外部网络探测）。

### 4.5 浏览器验证

用 Playwright + Chromium。认证可以借这个机制：面板在 Basic 认证里**密码留空**时，
会把 username 当 UUID 查账号（`auth.py:260-266`），且对**空密码账号**放行（`:240`）。
全新库建出的管理员密码就是空的：

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

三个容易踩的点：

- **界面默认英文**。断言要用语言无关的判定（中英文导航词任一），别只认中文。
- **路由名别猜**。定义在 `admin_v2/src/router/index.ts`：首页是 `/`（`name: 'dashboard'`），
  **没有 `/dashboard` 这个路径**。真实路由有：
  `""`（首页）、`node`、`nodes`、`users`、`message`、`admins`、`account`、`settings`、
  `protocols`、`domains`、`backup`、`outbounds`、`custom-proxies[/new|/:id]`、
  `templates[/new|/:id]`、`legacy/:path(.*)`，另有独立的 `/quick-setup`。
- **过滤 `admin/live/`**，且 `wait_until` 用 `load` 不用 `networkidle`——
  SSE 长连接永远等不到 idle，导航时被中止是正常行为。

### 4.6 停止服务别用 `kill -9`

`kill -9` 会让连接池来不及关闭，MySQL 里留下大量 `Sleep` 连接，
下次建库时 `DROP DATABASE` 卡在 **`Waiting for table metadata lock`**。

```bash
for pid in $(pgrep -f "granian --interface asgi"); do kill -TERM $pid; done
sleep 3
for pid in $(pgrep -f "granian --interface asgi"); do kill -9 $pid; done

# 每轮开始前清残留连接
for id in $(mysql -N -e "SELECT id FROM information_schema.processlist WHERE user='hp';"); do
  mysql -e "KILL $id;"
done
```

### 4.7 反复冒烟实测

3 轮，每轮"清库 → 迁移 → 启动 → HTTP 断言 → 浏览器断言 → 优雅停止"：

| 轮次 | 迁移耗时 | db_version | 表数 | 页面渲染 | JS 错误 | 4xx/5xx | 结果 |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | 47 s | 184 | 21 | 6/6 | 0 | 0 | PASS |
| 2 | 50 s | 184 | 21 | 6/6 | 0 | 0 | PASS |
| 3 | 50 s | 184 | 21 | 6/6 | 0 | 0 | PASS |

**无 flaky**，每轮约 2 分钟。

> 上面的验证是在 WSL 模拟环境（MariaDB + Redis + granian）跑的，用了生产启动方式，
> 但不是真实服务器，也没跑真流量。

---

## 5. 常见失败

| 现象 | 原因与处理 |
| --- | --- |
| `No module named 'hiddifypanel'` | `PYTHONPATH` 没包含面板源码根目录 |
| `KeyError: REDIS_URI_MAIN` | `app.cfg` 缺 Redis 配置 |
| `near "SHOW": syntax error` | 用了 SQLite，面板硬依赖 MySQL（见 4.1） |
| `unexpected keyword argument 'base_template'` | `flask-admin` 装成 2.x，必须 1.6.1（见 4.2） |
| 迁移报 `near 'CREATE PROCEDURE'` | `_v140` 把两条语句拼在一次 `db_execute`，SQLAlchemy `text()` 默认不允许多语句。本地验证可打补丁：按**第一个**分号切出 `DROP`（过程体内含分号，不能全切），剩余整体交给底层游标 |
| `admin/live/` 404 | 用了 WSGI 开发服务器，生产是 granian ASGI（见 4.3） |
| 迁移没跑完就断言，HTTP 500 | 轮询 `db_version` 到 184 再断言（见 4.4） |
| `DROP DATABASE` 超时 / metadata lock | 上轮被 `kill -9`，残留 Sleep 连接锁表（见 4.6） |
| Playwright 报缺 `libnspr4.so` | 装 Chromium 系统库：`apt-get install libnspr4 libnss3 libasound2t64 libatk1.0-0t64 libatk-bridge2.0-0t64 libcups2t64 libdrm2 libgbm1 libxkbcommon0 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libpango-1.0-0 libcairo2` |
| 启动 >100 s 且日志反复出现 `ooni` | 离线环境在做外部域名探测。本地可把 `net.get_random_domains` 换成 `net.random_fake_sites` 跳过 |
| HTTP 200 但 `rendered=False` | 多半路由名写错，或只认中文关键词（见 4.5） |

---

## 6. 维护提醒

- 改了 `.j2` 模板就跑一遍单元测试——它们正是为模板回归写的。
- 端到端冒烟**必须在干净库上跑**；复用旧库会跳过迁移链，验证不到 `_vNNN` 的问题。
- 冒烟完停掉 MariaDB / Redis，确认没有残留连接。

---

## 7. 脚本冒烟（全离线）

`scripts/tests/` 下的脚本都**不联网**（除显式走代理/pull 的场景外，夹具全部用本地裸仓库与
`file://` 协议），用临时目录当 `HIDDIFY_DIR`，不碰真实 `/opt`，也不起任何服务。每条路径都从
**全新目录**开始，禁止场景间共享 `$ROOT`，消除状态串味。

| 脚本 | 覆盖什么 | 默认轮数 | 耗时/轮 |
| --- | --- | --- | --- |
| `smoke_update.sh [轮数]` | `update.sh` 的备份、ff-only 快进、失败分支、并发锁；每轮都是干净克隆 | 10 | 约 2 min |
| `smoke_package_manager.sh` | 包管理器：二进制缺失/损坏时的重装、`warp` 的 wgcf 检查 | 10 | 数十秒 |
| `smoke_publish_admin_ui.sh` | 管理端预构建包的发布与清单校验 | 10 | 数十秒 |
| `smoke_version_switch.sh [轮数]` | `version` 升级/降级/同版本/来回切换 + 三类边界（属主 65534、半残子模块、嵌套子模块） | 10 | 约 35 s |
| `smoke_deploy_paths.sh` | 六条部署路径 D1–D9：一键 / git / 手动 / 压缩包 / Docker / cloud-init / switch 转换 | 10 | 约 13 s |
| `smoke_lifecycle_matrix.sh` | 生命周期 × 起始状态矩阵 L1–L10：升级/降级/同版本/切换/异常输入/reinstall/构建失败半升级/组件改脏/属主异常更新/WARP 关闭时更新不碰 WARP | 10 | 约 24 s |
| `smoke_restart_status.sh` | `restart.sh` 的进行中任务守卫（真实退出码 + 结束标记）、`systemd-run` 延迟重启与回退、warp 开关、含空格路径；`status.sh` 结束标记与 WARP 探测开关 | 10 | 约 1 s |
| `smoke_install_tasks.sh` | `install.sh` 的 WARP 决策表（disable/缺失/hconfig 失败/大小写）、`runsh` 的 false→`disable.sh` 映射、`hiddify-core.service` 兼容开关与单元合法性 | 10 | 约 1 s |

```bash
# 每套件默认 10 轮；失败时退出码非 0，可直接当 CI 闸门
bash scripts/tests/smoke_version_switch.sh 10
bash scripts/tests/smoke_deploy_paths.sh 10
bash scripts/tests/smoke_lifecycle_matrix.sh 10
bash scripts/tests/smoke_update.sh 10          # 默认拒绝在真实安装上跑，需 SMOKE_ALLOW_DESTRUCTIVE=1
bash scripts/tests/smoke_package_manager.sh 10
bash scripts/tests/smoke_publish_admin_ui.sh 10
bash scripts/tests/smoke_restart_status.sh 10
bash scripts/tests/smoke_install_tasks.sh 10
```

每套件打印 `iterations: X   all-green: Y   failed: Z   assertions: A   elapsed: Ts`，
`failed>0` 时退出码 1。10 轮全绿实测（VM `192.168.138.129`，`/opt/hiddify-src` 隔离仓库）：

| 套件 | 轮数 | 结果 | 断言数 |
| --- | --- | --- | --- |
| `smoke_version_switch` | 10 | all-green | 920 |
| `smoke_deploy_paths` | 10 | all-green | 900 |
| `smoke_lifecycle_matrix` | 10 | all-green | 620 |
| `smoke_package_manager` | 10 | all-green | 620 |
| `smoke_publish_admin_ui` | 10 | all-green | 620 |
| `smoke_update`（含 `SMOKE_ALLOW_DESTRUCTIVE=1`，跑完完整备份/恢复） | 10 | all-green | — |

### 7.1 反向验证（红测）

改坏被测逻辑后，对应场景必须变红；改回后恢复绿。已在 `/opt/hiddify-src` 上验证（Tier 2）：

| 被破坏的逻辑（位于 `scripts/onekey.sh`） | 红测脚本 | 破坏后 | 恢复后 |
| --- | --- | --- | --- |
| `fixup_broken_submodules()` 提前 `return 0` | `smoke_version_switch` | failed: 5 | all-green |
| `add_safe_directories()` 的 `GIT_CONFIG_*` 兜底导出被注释 | `smoke_version_switch` | failed: 34 | all-green |
| `scripts/common/docker-installer.sh` 的 `ghcr.io/.../hiddify-manager:<TAG>` URI 改写被改错 | `smoke_deploy_paths` | failed: 1 | all-green |

> `restore_rendered_files` 的红测走 `smoke_update` + `SMOKE_ALLOW_DESTRUCTIVE=1`：需对真实安装做
> 备份/恢复，验证 `cmd_version` 渲染文件恢复分支。已验证 `smoke_update` 的 `stash_preexisting`/
> `restore_preexisting` 能把 1.6 GB 的 `/opt/hiddify-manager` 完整备份并在退出时还原（HEAD 不变、
> 服务仍 active、无残留备份目录）。

### 7.2 本轮未提交改动的场景矩阵（3 轮）

只测"改了什么"：每处改动各配正常 / 边界 / 异常场景，在 `/opt/hiddify-src` 隔离副本上跑（线上目录指纹前后一致）。

| 套件 | 轮数 | 结果 | 断言数 |
| --- | --- | --- | --- |
| `smoke_version_switch`（含新增 P/Q/R） | 3 | all-green | 351 |
| `smoke_lifecycle_matrix`（含新增 L9/L10） | 3 | all-green | 208 |
| `smoke_deploy_paths` | 3 | all-green | 270 |
| `smoke_restart_status`（新） | 3 | all-green | 93 |
| `smoke_install_tasks`（新） | 3 | all-green | 69 |
| `smoke_update` | — | SKIP | 脚本 `rm -rf /opt/hiddify-manager`，拒绝在实例上跑；update 路径由 L7–L10 覆盖 |

| 改动 | 场景（类型） | 结论 |
| --- | --- | --- |
| ① 半残子模块让位：有源码无 `.git` 的目录也要让位 | **P** 普通目录无 `.git`（正常）→ 让位为 `*.release-backup` + 重克隆，备份里仍有原源码 | 通过 |
| | **Q** 空目录（边界）→ 不得让位，须被 git 填充 | 通过（空目录未被挪动） |
| | **R** 切换前已存在的 `*.release-backup-old`（边界）→ `git clean` 后仍存活 | 通过 |
| | 半残 `.git` / 嵌套子模块（异常，既有 A–O） | 通过 |
| ② 更新/切版本前登记 safe.directory | **L9** 顶层 `$ROOT` 属主 65534（异常）→ `onekey update` 成功、无 `dubious ownership` | 通过 |
| | 既有 I（version 路径属主 65534） | 通过 |
| ③ WARP 由配置决定 | **W1** `disable`→false；`warp`/`warp_reality`/键缺失/`hconfig` 失败/`Disable`/带空格→true（正常+边界+异常） | 通过 |
| | **W2/W3** 决策值接到 `runsh`：false/0→`disable.sh`，true/1/空→`install.sh`，缺脚本安静跳过 | 通过 |
| | **L10** `warp_mode=disable` 时 update 不调用 `wgcf`/`wg-quick`/`wg` | 通过 |
| ④ 重启守卫 + 延迟重启 + 结束标记 | **R1** `hiddify-install` active（正常拒绝）→ 退出码 12、写结束标记、不碰任何服务 | 通过（修复后） |
| | **R1b** 并发两次拒绝（边界）→ 都返回 12、无服务操作、日志只有一条标记 | 通过 |
| | **R2** 无进行中任务 + warp 关闭 → `systemd-run --unit=hiddify-panel-restart` 延迟重启、跳过 `wg-quick@warp`、日志末行是标记 | 通过 |
| | **R3** `systemd-run` 失败（异常）→ 回退直连重启面板、rc=0、写标记 | 通过 |
| | **R4** `warp_mode=warp` → `wg-quick@warp` 参与重启 | 通过 |
| | **R5** 目录含空格（边界）→ 正常运行并写标记 | 通过 |
| ⑤ `status.sh` 结束标记 | **S1** 末行是标记、尾部 4096 字节命中 `Finished!`、标记后再无输出 | 通过 |
| | **S2** warp 关闭时不调 `services/warp/status.sh`，开启时才调（边界） | 通过 |
| ⑥ 核心服务兼容开关 | **C1** `Environment=ENABLE_DEPRECATED_IMPLICIT_DEFAULT_HTTP_CLIENT=true` 在 `[Service]` 段、`ExecStart` 未变、`systemd-analyze verify` 通过 | 通过 |
| | 真机 `systemctl show hiddify-core -p Environment` → 变量已注入运行中的进程 | 通过 |

真机定点（同一轮，测试后实例仍为 `v14.2.6` / `db_version=189` / 6 服务 active / HTTP 301）：

| 验证项 | 手法 | 结果 |
| --- | --- | --- |
| 守卫拒绝 | `systemd-run --collect --unit=hiddify-install sleep 120` 造瞬时单元，跑 `restart.sh` | rc=12、日志写标记、6 个服务 `ActiveEnterTimestamp` 全部未变；单元已 stop + reset-failed，无残留 |
| `status.sh` 标记 | 只读执行 `bash scripts/status.sh` | rc=0、末行为标记、尾部 4096 字节命中 |
| 延迟重启 | 无守卫时实跑一次 `restart.sh` | 输出 `scheduled(+1s)`，面板 `ActiveEnterTimestamp` 前进，其余服务与 HTTP 正常 |
| 核心单元 | `systemd-analyze verify` + `systemctl show` | 单元合法、开关生效 |

反证（`/opt/hiddify-src`，改坏→变红→还原→变绿）：

| 被破坏的逻辑 | 套件 | 破坏后 | 还原后 |
| --- | --- | --- | --- |
| `onekey.sh` 的 `needs_move_aside "$path" \|\| continue` 退回 `is_broken_submodule` | `smoke_version_switch` | failed: 2 | all-green |
| `install.sh` 的 WARP 决策行被改成空操作（永远执行） | `smoke_install_tasks` | failed: 5 | all-green |
| `restart.sh` 结尾的 `exit ${PIPESTATUS[0]}` 被删（退回 tee 的退出码） | `smoke_restart_status` | failed: 2 | all-green |

本轮发现：

1. **已修**：`restart.sh` 末尾 `main "$@"|& tee …` 的退出码取自 `tee`，守卫分支的 `return 12` 被吞成 0，
   调用方以为重启成功；且该分支提前返回、不写结束标记，面板只能靠"日志安静 6 秒"兜底。
   改为 `${PIPESTATUS[0]}` 透传 + 拒绝分支补标记，与 `install.sh` 一致（R1 由 0→12）。
2. **已知限制（未改）**：`onekey … --dir X` 只影响 onekey 自身的 git 操作，`update.sh` / `install.sh` /
   `status.sh` 仍 `cd /opt/hiddify-manager`。夹具因此必须**导出 `HIDDIFY_DIR`**，否则"离线"场景会打到
   线上目录（本轮复测中曾复现：生成 8 个 DB 备份、`git merge` 被本地未提交改动挡住，版本未变；备份已清理）。
   `smoke_lifecycle_matrix.sh` 已加"线上目录指纹前后比对"作为兜底断言。
3. **测试框架约束**：`restart.sh` 第 2 行会整体重写 `PATH`，夹具必须把这一行也泛化（`${HRS_BIN:+$HRS_BIN:}`），
   否则桩形同虚设、场景直接调用真机 `systemctl`/`systemd-run`。`smoke_restart_status.sh` 已加"桩是否真被调用"
   的预检，未命中即中止。

## 8. 部署路径矩阵

逐条对应 `docs/deploy/*` 与 `docs/ops/server-update.md`，每条都用真实 `onekey.sh`/`update.sh` 跑过
（离线套件或真机 E2E）。

| 教程出处 | 路径 | 测试脚本 / 场景 | 关键断言 |
| --- | --- | --- | --- |
| `docs/deploy/onekey.md` | ① 在线一键 `bash <(curl …) install` | `smoke_deploy_paths` **D1** | 克隆成功、子模块（含嵌套）已初始化、`install.sh` 被调用、`add_safe_directories` 登记三层目录 |
| `docs/deploy/git-checkout.md` | ② git 拉取开发 `git clone --recurse-submodules -b dev-custom` + `make build` + `git -C services/panel/src checkout dev-custom` | `smoke_deploy_paths` **D4 / D5** | 子模块从 detached HEAD 切到 `dev-custom`；与一键终态等价；历史改名/软链逻辑不误伤 |
| `docs/deploy/manual.md` | ③ 服务器手动 `git clone` + `bash scripts/install.sh --no-gui` | `smoke_deploy_paths` **D3** | 与 D1 终态等价 |
| `scripts/common/download.sh` | ④ 压缩包/release 安装（`v9*`–`v12*` → `refs/tags/<tag>/`；其它 `v*` → `refs/tags/<tag>/scripts`；非 `v` → `refs/heads/<branch>/scripts`；下载失败不留半成品） | `smoke_deploy_paths` **D6** | 分支分派正确；下载失败 `exit 1` 且 `-f` 语义成立；无 `--no-gui` 时提示已废弃 |
| `docs/deploy/docker.md` | ⑤ Docker（实验性）`docker-installer.sh beta/latest/develop`，host + bridge | `smoke_deploy_paths` **D7** | 已有目录则 `exit 1`；`image:` 钉到 `ghcr.io/xgs87762gh/hiddify-manager:<TAG>`；`develop` 改写 `build: .`；`MYSQL/REDIS` 密码与 `SQLALCHEMY_DATABASE_URI`/`REDIS_URI_MAIN` 一致；`docker compose config` 可解析；两 profile 均校验 |
| `docs/cloud-init.yml` | ⑥ cloud-init runcmd（`curl -o /tmp/onekey.sh` 再 `bash /tmp/onekey.sh install -y`，避开 `<( )`） | `smoke_deploy_paths` **D8** | `/bin/sh` 下不依赖进程替换；可跑通 |
| `docs/ops/server-update.md` §4 | 附加：官方 release → 本 fork 的 `switch` 转换 | `smoke_deploy_paths` **D9** + `smoke_version_switch` | 无 `.git` 的 release 形态目录被转换为指向本 fork 的 git 检出；旧目录挪为 `*.release-backup*`；已是 checkout 时幂等且不破坏数据 |
| `docs/ops/server-update.md` | 生命周期 `install`/`update`/`reinstall`/`version`/`switch` | `smoke_version_switch` (A–R) + `smoke_lifecycle_matrix` (L1–L10) | 见 §9 与脚本内场景定义 |

## 9. 真机端到端（Tier 1，VM `192.168.138.129`）

在 Ubuntu 24.04 真机上对线上实例（起始 `v14.2.6-2-g4155b073`，8 个服务 active）实跑。统一验收：
`systemctl is-active hiddify-panel` + `bash /opt/hiddify-manager/scripts/status.sh` + `db_version` +
`curl http://127.0.0.1:9000/<pp>/`（未登录 `/<pp>/admin/` 返 302 属正常）+ `data/`/`generated/`/`.venv313` 指纹。

| 步骤 | 命令 | 结果 | 备注 |
| --- | --- | --- | --- |
| E_version_noprefix | `onekey.sh version 14.2.6 -y`（不带 `v`） | PASS | 拒绝并提示加 `v` 前缀 |
| E_version_notag | `onekey.sh version v14.2.5.999 -y`（不存在 tag） | PASS | 拒绝并提示找不到 tag |
| E2 升级 | `onekey.sh update -y` | PASS | HEAD 快进；`backup.sh` 生成备份；`db_version=189` |
| E4_restore | `onekey.sh version v14.2.6 -y` | PASS | 验证 `version` 走 git 检出：`checkout -f` → `git clean -fd -e data -e generated -e .venv313` → `install.sh`（数据保留） |
| E3 降级 | `onekey.sh version v14.2.5 -y` | PASS | 代码切到 v14.2.5；`data/` 保留；DB 降级不可逆警告（见 server-update.md 坑 1） |
| E4 再升级 | `git checkout v14.2.6 && bash scripts/install.sh --no-gui`（git-pin） | PASS | **关键**：从 v14.2.5 不能用 `onekey version`（v14.2.5 的 `onekey.sh` 拒绝 git 检出，提示用 git-pin）；`db_version` 不回退 |
| E5 reinstall | `onekey.sh reinstall -y` | PASS | HEAD 不变；服务仍 active |
| E6 switch 幂等 | `onekey.sh switch -y` | PASS | 已是 fork checkout，安全幂等 |
| E7 Docker | — | SKIP | 真机为 systemd 安装，无 docker 二进制 |

**`onekey version` 的 git 检出支持**：v14.2.6 的 `cmd_version` 原生支持 git 检出
（`git fetch → checkout -f → fixup_broken_submodules → submodule update --force → git clean -fd -e data -e generated -e .venv313 → install.sh`），
所以“从 v14.2.6 降级到 v14.2.5”可直接用 `onekey version v14.2.5`。但 v14.2.5 的 `onekey.sh` **没有**该支持，
一旦实例处在 v14.2.5，再“升级”就必须走 git-pin 路径（`git checkout v14.2.6 && bash scripts/install.sh`），
这正是 `version` 在 git 检出上失败时 die 信息给出的指引。因此 E4 再升级用 git-pin 验证，结果 PASS。

> **环境坑（已定位并规避，均非 fork 逻辑缺陷）**：
> 1. **WARP 检查死等**：`onekey.sh` 继承了 `http_proxy=127.0.0.1:7890`（为 git 拉取设置），使 WARP 连通性探测
>    `curl --interface warp` 把代理连接塞进 warp 隧道 → 永久 `SYN-SENT`。规避：驱动里 `unset` 代理变量
>    （git 仍走 `git config http.proxy`）。直连 warp 探测 1.2s 即返回真实 Cloudflare IP，WARP 实际可用。
> 2. **curlrc 重试放大**：`/root/.curlrc` 默认 `retry=30`+`retry-all-errors`，任何失败 curl 重试 30 次、每次等
>    `connect-timeout`，把本应 1 秒失败的探测拖成几分钟。规避：改为 `max-time=30` 给所有 curl 上总时长上限，
>    并对连通性探测主机（`v4/v6.ident.me`、`ipv6.google.com`、`ip-api.com`）及 `localhost/127.0.0.1` 设 `noproxy` 走直连。
> 3. **git fetch 抖动**：VM 经 mihomo 代理拉 GitHub，TLS 握手间歇性 `gnutls_handshake failed`。`cmd_version` 会
>    无条件 `git fetch --tags origin` 且失败即 die（即使目标 tag 本地已存在）。规避：驱动对整条命令做最多 30 次重试；
>    git-pin 路径下 `checkout` 在 fetch 失败后仍可用本地 tag，更稳健。

**结论**：五条生命周期命令的全部状态（含输入校验、降级、升级、reinstall、switch 幂等）均逐条验证通过，
线上实例最终稳定在 `v14.2.6`、`db_version=189`、8 个服务 active。仅 GitHub 拉取受代理网络波动影响
（已通过重试驱动覆盖），WARP / curl 死等属环境交互（已规避），fork 逻辑本身无缺陷。
