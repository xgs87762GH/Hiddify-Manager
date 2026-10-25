# 部署（fork 维护）

本文档由 fork 维护者添加，讲**首次部署**怎么装、装完怎么确认它是好的、以及出问题往哪看。
已经装好的机器要升级请看 [server-update.md](server-update.md)，
验证方法请看 [testing.md](testing.md)。

---

## 1. 选一种部署方式

| 方式 | 适用 | 命令 |
| --- | --- | --- |
| 一键安装 | 生产服务器，不打算改代码 | `bash <(curl https://i.hiddify.com/beta)` |
| Git checkout | 开发机 / 要改代码的服务器 | `git clone --recurse-submodules` + `make build` |
| Docker | 隔离需求，但**仍是 experimental** | `docs/DOCKER.md` |

**生产环境优先一键安装。** Docker 支持还没稳定（`DOCKER.md` 自己标注了 experimental，
进程模型还在用 python-systemctl shim，默认 profile 要 privileged + host network）。

一键安装后目录是 `/opt/hiddify-manager`。历史上用过 `/opt/hiddify-server`、
`/opt/hiddify-config` 的机器会被自动改名并留软链接，不用手动处理。

---

## 2. 系统要求

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 或更新的 Debian 系（`install.sh` 用 `DEBIAN_FRONTEND=noninteractive` 跑 apt） |
| 权限 | **必须 root**。`install.sh` 开头就检查 `id -u`，非 root 直接退出 |
| Python | ≥ 3.13（面板 `pyproject.toml` 的 `requires-python`） |
| 内存 | ≥ 1 GB，但**管理端 UI 构建要 ~1.2 GB**；`make build` 会自动挂临时 swap，1 GB 机器靠它 |
| 磁盘 | 建议 ≥ 10 GB（含备份、证书、日志） |
| 网络 | 能出网。ACME 签发证书、下载 xray / hiddify-core 等二进制都要联网 |

### 端口

| 端口 | 用途 |
| --- | --- |
| 80 / TCP | HTTP，同时用于 ACME HTTP-01 挑战 |
| 443 / TCP+UDP | HTTPS 与代理入口 |
| 9000 | 面板后端（HAProxy 的 panel backend），**不该直接暴露** |
| 9001 | Vite 开发服务器，仅开发用 |
| 动态端口 | 各协议自己的监听端口，由面板分配 |

80/443 必须空闲。装之前先确认没有 nginx、Apache 之类占着：

```bash
ss -lntp | grep -E ':80 |:443 '
```

---

## 3. 一键安装

```bash
sudo -i
bash <(curl https://i.hiddify.com/beta)
```

安装脚本按 `/opt/hiddify-manager/scripts/install.sh` 执行，依次装：
HAProxy（流量入口与路由）、xray / sing-box / hiddify-core（代理核心）、
MySQL（面板数据库）、Redis（缓存与 session）、面板本身，以及 telemt、ssh-liberty、
warp、wireguard、ssfaketls 等可选组件。

装完用 HAProxy 做入口，面板跑在 9000 后面，不直接对外。

---

## 4. Git checkout（开发机也是服务器）

开发机和服务器是**同一份代码树**，没有"本地改完拷贝过去"这一步：

```bash
sudo -i
git clone --recurse-submodules -b dev https://github.com/hiddify/Hiddify-Manager.git /opt/hiddify-manager
cd /opt/hiddify-manager
make build
git -C services/panel/src checkout dev      # 子模块有自己的分支
```

`make build` = `make ui`（构建管理端 UI）+ `scripts/install.sh --no-gui`（装全部服务并应用配置）。

日常命令：

| 任务 | 命令 |
| --- | --- |
| 只重建 UI | `make ui` |
| 应用配置（改了模板或设置） | `make apply`，或面板里的 *Apply* 按钮 |
| 重启面板 | `systemctl restart hiddify-panel` |
| 拉代码并重新构建 | `git pull --recurse-submodules && make build` |
| 看生成的配置 | `hiddify-panel-cli dump-server-configs /tmp/out` |

**注意**：重启面板会跑数据库迁移。在别人正在用的服务器上重启前要打招呼
（`DEVELOPMENT.md` 的 *Notes for AI assistants* 也写了这条）。

路径说明：

```
/opt/hiddify-manager/                      外层仓库：安装脚本、systemd unit
├── services/panel/src/                    面板子模块（hiddifypanel）
│   ├── hiddifypanel/admin_v2/             管理端 UI（Vue 3）
│   ├── hiddifypanel/panel/init_db.py      _vNNN 迁移链
│   └── tests/                             单元测试（见 testing.md）
├── data/                                  服务器状态：库配置、证书、备份、日志（勿提交）
├── generated/                             面板渲染出的 haproxy.cfg / xray.json 等
└── .venv313/                              面板 Python 环境
```

---

## 5. 硬依赖：MySQL 与 Redis

这两样**不能省也不能替**：

- **MySQL / MariaDB**：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...` 读 enum 列定义，
  SQLite 等后端不支持。
- **真 Redis**：缓存、session、`evalsha` 都用它，`fakeredis` 跑不通。

一键安装会自动装；手动部署要确保两者都在跑且面板能连上：

```bash
systemctl status mariadb mysql redis-server 2>&1 | head
```

连接串写在面板配置里（开发机：`/opt/hiddify-manager/data/hiddify-panel/app.cfg`）：

```ini
SQLALCHEMY_DATABASE_URI=mysql+pymysql://<user>:<pass>@localhost/hiddifypanel?charset=utf8mb4
REDIS_URI_MAIN=redis://localhost:6379/0
REDIS_URI_OTHER=redis://localhost:6379/1
```

`mysqlclient` 需要编译；装不上可以换 `pymysql`，把 URI 的驱动改成 `mysql+pymysql://`。

---

## 6. 部署后验证

按 [testing.md](testing.md) 跑一遍，至少确认：

### 服务状态

```bash
systemctl status hiddify-panel --no-pager
journalctl -u hiddify-panel -n 50 --no-pager
```

### 数据库

```bash
mysql -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';"
# 应为 184；全新库会从 _v1 跑到 _v184，建出 21 张表
mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='hiddifypanel';"
```

### HTTP

面板的路由都挂在 `/<proxy_path>/` 前缀下，`proxy_path` 从库里读：

```bash
PP=$(mysql -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='proxy_path';")
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:9000/$PP/"
```

未登录访问 `/<proxy_path>/admin/` 返回 **302 跳登录页是正常的**，不是故障。

### 浏览器

打开管理端 V2，确认：

- 界面文字正常（译文件语法错误会让整包翻译加载失败，见 `server-update.md` 第 4 节）
- 侧边栏导航齐全：仪表盘 / 用户 / 管理员 / 节点 / 设置 / 域名 / 协议 / 备份 / 出站等
- 列表页的空状态、搜索无结果提示正常
- 订阅链接可用

实测基线（面板完整启动后）：**445 条路由、31 个蓝图、调度器 9 个任务**。

---

## 7. 备份与恢复

| 备份什么 | 在哪 / 怎么来 |
| --- | --- |
| 面板数据与配置 | 面板"备份"页，或 `services/panel/backup.sh` |
| 服务器状态 | `data/`（含 `data/cert` 证书、`data/backup`） |
| 首次转换前的全量快照 | `/opt/hiddify-manager.bak.<时间戳>` |

恢复时**代码和数据要分开看**：

- 代码回滚：`git reset --hard <上一个提交>` + `git submodule update --init --recursive` + `make build`
- 数据回滚：用 `backup.sh` 生成的那份备份

改迁移时务必先备份（`DEVELOPMENT.md` 第 61 行也这么要求）：面板启动时自动执行 `_vNNN`，
跑坏了只能靠备份救。

---

## 8. 故障排查

| 现象 | 往哪看 |
| --- | --- |
| `install.sh` 报 `must be run by root` | 用 `sudo -i` 再跑 |
| 80/443 被占 | `ss -lntp \| grep -E ':80 \|:443 '`，停掉 nginx / Apache |
| 构建退出码 137 | 内存不足被 OOM kill。加 swap 或临时扩内存后重跑 `make build` |
| 面板起不来，日志报 `base_template` | `flask-admin` 装成了 2.x，必须 `1.6.1`。见 `testing.md` 4.2 |
| 面板起不来，日志报 `REDIS_URI_MAIN` | `app.cfg` 缺 Redis 配置 |
| 日志报 `near "SHOW": syntax error` | 用了 SQLite。面板硬依赖 MySQL，见第 5 节 |
| 迁移卡住或报 `Waiting for table metadata lock` | 有残留数据库连接没关。见 `testing.md` 4.6 |
| 界面白屏 / 文字变成 key | 译文件 JSON 语法错误导致构建期失败，`git log` 与面板版本可能已不一致。见 `server-update.md` 第 4 节 |
| 订阅链接打不开 | 先看 HAProxy 是否在跑、证书是否签发成功（`data/cert`） |
| `admin/live/` 404 | 用 WSGI 开发服务器跑的。生产是 granian ASGI。见 `testing.md` 4.3 |

看日志的几个入口：

```bash
journalctl -u hiddify-panel -n 100 --no-pager      # 面板
journalctl -u haproxy -n 50 --no-pager             # 入口
tail -n 50 /opt/hiddify-manager/data/log/*          # 安装与应用日志
```

---

## 9. 维护提醒

- **别手改 `data/` 和 `generated/`**，它们会被重新生成。
- 改管理端 UI 动 `admin_v2`，改用户界面动 `user_front`；旧的 Flask-Admin 页面是遗留代码，不要改。
- 生产环境不要开 `make debug-panel`（Flask 开发服务器 + `--reload`，且绑定 `0.0.0.0`）。
- 升级会重启面板、中断服务数分钟，见 `server-update.md` 第 8 节。
