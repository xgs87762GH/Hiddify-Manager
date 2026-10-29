# 部署

> 本目录讲**首次部署**。已装好的机器要升级看 [运维 → 升级](../ops/server-update.md)，
> 怎么验证看 [开发 → 测试与验证](../dev/testing.md)。
> 返回 [文档总目录](../README.md)。

---

## 1. 四种方式怎么选

| 方式 | 适合谁 | 教程 | 说明 |
| --- | --- | --- | --- |
| **一键部署**（推荐） | 新机器、想最少步骤 | [onekey.md](onekey.md) | 一条命令，自动 clone 并安装 |
| **git 拉取开发** | 要改代码 / 参与二开 | [git-checkout.md](git-checkout.md) | 开发机与服务器同一份代码树 |
| **服务器手动部署** | 想看清每一步、要自定义 | [manual.md](manual.md) | 手动 clone + `install.sh` |
| **Docker（实验性）** | 只要隔离、能接受限制 | [docker.md](docker.md) | 进程模型仍是 shim，**生产不建议** |

额外的自动化入口：

| 场景 | 用什么 |
| --- | --- |
| 云主机开机自动装 | [`cloud-init.yml`](../cloud-init.yml) |
| 官方版本 → 转本 fork | `bash <(curl -fsSL "$OK") switch`（见 [升级](../ops/server-update.md)） |

> **不要用官方一键脚本 `bash <(curl https://i.hiddify.com/beta)`**：它装的是官方代码，
> 后续升级会去拉官方仓库。本 fork 的安装入口只有 `onekey.sh install` 与它等价的手动步骤。

### 一条命令速查

```bash
OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh

sudo -i
bash <(curl -fsSL "$OK") install             # 全新安装
bash <(curl -fsSL "$OK") update              # 升级（会先备份）
bash <(curl -fsSL "$OK") reinstall           # 按当前代码重装服务
bash <(curl -fsSL "$OK") version v14.2.4 -y  # 切到指定版本（git 检出：强制换代码留数据）
bash <(curl -fsSL "$OK") switch              # 官方安装 → 转本 fork（只跑一次）
```

> `/bin/sh`、`dash`、cloud-init 的 `runcmd` 没有 bash 的 `<( )` 进程替换，改写成：
> `curl -fsSL "$OK" -o /tmp/ok.sh && bash /tmp/ok.sh install`

---

## 2. 装之前的共同前置

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 或更新的 Debian 系 |
| 权限 | **必须 root**（`install.sh` 开头就检查） |
| Python | ≥ 3.13 |
| 内存 | ≥ 1 GB；**构建 UI 要 ~1.2 GB**，脚本会自动挂临时 swap |
| 磁盘 | 建议 ≥ 10 GB（含备份、证书、日志） |
| 网络 | 要能出网（签证书、下载核心二进制都要） |

### 端口必须先空出来

| 端口 | 用途 |
| --- | --- |
| 80 | HTTP，同时用于 ACME 验证 |
| 443 | HTTPS 与代理入口（TCP + UDP） |
| 9000 | 面板（跑在 HAProxy 后面，**不直接暴露**） |
| 9001 | Vite 开发服务器，仅开发用 |
| 动态 | 各协议自己的端口，由面板分配 |

```bash
ss -lntp | grep -E ':80 |:443 '     # 有输出说明被占，先停掉 nginx / Apache
```

### 两个硬依赖：MySQL 和 Redis

这两样**不能省也不能替**：

- **MySQL / MariaDB**：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...` 读 enum 列，SQLite 不支持。
- **真 Redis**：缓存、session、`evalsha` 都用它，`fakeredis` 跑不通。

一键安装会自动装；手动部署要确认两者在跑：

```bash
systemctl status mariadb mysql redis-server 2>&1 | head
```

连接串在 `/opt/hiddify-manager/data/hiddify-panel/app.cfg`：

```ini
SQLALCHEMY_DATABASE_URI=mysql+pymysql://<user>:<pass>@localhost/hiddifypanel?charset=utf8mb4
REDIS_URI_MAIN=redis://localhost:6379/0
REDIS_URI_OTHER=redis://localhost:6379/1
```

> `mysqlclient` 需要编译；装不上可换 `pymysql`，把 URI 驱动改成 `mysql+pymysql://`。
> 想用外部数据库见 [运维 → 外部数据库](../ops/external-database.md)。

---

## 3. 装完怎么验

| 检查 | 命令 / 期望 |
| --- | --- |
| 面板服务 | `systemctl status hiddify-panel --no-pager` |
| 面板日志 | `journalctl -u hiddify-panel -n 50 --no-pager` |
| 数据库版本 | `mysql -uroot -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';"` |
| HTTP | `curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:9000/$PP/"`（`PP` 从库里读 `proxy_path`） |
| 全部服务 | `bash /opt/hiddify-manager/scripts/status.sh` |

浏览器打开管理端，确认：界面文字正常、侧边栏导航齐全（仪表盘 / 用户 / 管理员 / 节点 / 设置 / 域名 /
协议 / 备份 / 出站）、订阅链接可用。

> 未登录访问 `/<proxy_path>/admin/` 返回 **302 跳登录页是正常的**，不是故障。

---

## 4. 出问题看这里

| 现象 | 原因与处理 |
| --- | --- |
| `must be run by root` | 用 `sudo -i` 再跑 |
| 80/443 被占 | 停掉 nginx / Apache |
| 构建退出码 137 | 内存不足被 OOM kill，加 swap 后重跑 |
| 日志报 `base_template` | `flask-admin` 装成了 2.x，必须 `1.6.1`（见 [测试与验证](../dev/testing.md)） |
| 日志报 `REDIS_URI_MAIN` | `app.cfg` 缺 Redis 配置 |
| 日志报 `near "SHOW": syntax error` | 用了 SQLite，面板硬依赖 MySQL |
| 界面白屏、文字变成 key | 译文件 JSON 语法错误导致构建失败 |
| 订阅链接打不开 | 看 HAProxy 是否在跑、证书是否签发成功（`data/cert`） |
| `admin/live/` 404 | 用 WSGI 开发服务器跑的，生产是 granian ASGI |

日志入口：

```bash
journalctl -u hiddify-panel -n 100 --no-pager      # 面板
journalctl -u haproxy -n 50 --no-pager             # 入口
tail -n 50 /opt/hiddify-manager/data/log/*          # 安装与应用日志
```

---

## 5. 维护提醒

- **别手改 `data/` 和 `generated/`**，它们会被重新生成。
- 改管理端 UI 动 `admin_v2`，改用户界面动 `user_front`；旧 Flask-Admin 页面是遗留代码，不要改。
- 生产环境不要开 `make debug-panel`（Flask 开发服务器 + `--reload`，且绑定 `0.0.0.0`）。
- 升级会重启面板、中断服务数分钟，见 [运维 → 升级](../ops/server-update.md)。
