# 部署

> fork 维护文档，讲**首次部署**。
> 已装好的机器要升级看 [升级](server-update.md)，怎么验证看 [测试与验证](testing.md)。

---

## 1. 先选方式

| 方式 | 什么时候用 | 命令 |
| --- | --- | --- |
| **一键安装（推荐）** | 新机器，不想记步骤 | 第 3 节的一条命令 |
| **手动 git 安装** | 想自己控制 clone 与分支 | 第 3 节末尾（与一键等价） |
| **官方装过 → 转 fork** | 机器上已经是官方版本 | `onekey.sh switch` |
| Docker | 要隔离（**仍属实验性**） | 见 [DOCKER.md](DOCKER.md) |

> **不要用官方一键脚本 `bash <(curl https://i.hiddify.com/beta)`**：它装的是官方代码，
> 后续升级会去拉官方仓库。本 fork 的安装入口只有两个：`scripts/onekey.sh install`，
> 或等价的 `git clone --recurse-submodules` + `scripts/install.sh`。
> Docker 支持还没稳定：进程模型仍是 python-systemctl shim，默认 profile 要 privileged + host network。

---

## 2. 装之前

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 或更新的 Debian 系 |
| 权限 | **必须 root**（`install.sh` 开头就检查） |
| Python | ≥ 3.13 |
| 内存 | ≥ 1 GB；但**构建 UI 要 ~1.2 GB**，脚本会自动挂临时 swap |
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

---

## 3. 全新部署

一条命令，不用先 clone、不用 cd：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) install
```

它做的就是下面的手动流程，外加前置检查：

- 目录不存在 → `git clone --recurse-submodules -b dev-custom` 到 `/opt/hiddify-manager`（含面板子模块）
- 随后执行 `scripts/install.sh --no-gui --no-log`
- 目录已存在但不是 git 检出（官方 zip 安装）→ **拒绝覆盖**，并提示改用 `onekey.sh switch`
- 已经是 git 检出 → 自动转为 `onekey.sh update`，不会重复 clone

装的是本 fork 的 `dev-custom` 与面板 fork，之后升级只快进这条分支，不会被官方版本覆盖。

### 手动安装（与一键等价）

```bash
sudo -i
git clone --recurse-submodules -b dev-custom \
    https://github.com/xgs87762GH/Hiddify-Manager.git /opt/hiddify-manager
cd /opt/hiddify-manager
bash scripts/install.sh --no-gui
```
脚本要从 GitHub 拉核心二进制、面板源码和 Node 工具链，依赖清单见
[构建与安装依赖](build-requirements.md)。

会装上：HAProxy（入口与路由）、xray / sing-box / hiddify-core（代理核心）、
MySQL（面板库）、Redis（缓存与 session）、面板本身，
以及 telemt、ssh-liberty、warp、wireguard、ssfaketls 等可选组件。

装完目录是 `/opt/hiddify-manager`。历史路径 `/opt/hiddify-server`、`/opt/hiddify-config`
会自动改名并留软链，不用手动处理。

---

## 4. 开发机（也是服务器）

开发机和服务器是**同一份代码树**，没有"本地改完拷贝过去"这一步。与第 3 节的区别只是用 `make build`（含 UI 构建）。

```bash
sudo -i
git clone --recurse-submodules -b dev-custom https://github.com/xgs87762GH/Hiddify-Manager.git /opt/hiddify-manager
cd /opt/hiddify-manager
make build
git -C services/panel/src checkout dev-custom    # 子模块也有自己的 dev-custom 分支
```

分支模型与提交顺序见 [AGENTS.md](../AGENTS.md) 与 [DEVELOPMENT.md](../DEVELOPMENT.md)。

`make build` = 构建管理端 UI + `scripts/install.sh --no-gui`（装全部服务并应用配置）。

### 日常命令

| 要做什么 | 命令 |
| --- | --- |
| 只重建 UI | `make ui` |
| 应用配置（改了模板或设置） | `make apply`，或面板里的 *Apply* 按钮 |
| 重启面板 | `systemctl restart hiddify-panel` |
| 拉代码并重新构建 | `git pull --recurse-submodules && make build` |
| 看生成的配置 | `hiddify-panel-cli dump-server-configs /tmp/out` |

> **重启面板会跑数据库迁移。** 在别人正在用的服务器上重启前要打招呼。

### 目录结构

```
/opt/hiddify-manager/                      外层仓库：安装脚本、systemd unit
├── services/panel/src/                    面板子模块
│   ├── hiddifypanel/admin_v2/             管理端 UI（Vue 3）
│   ├── hiddifypanel/panel/init_db.py      _vNNN 迁移链
│   └── tests/                             单元测试
├── data/                                  服务器状态：库配置、证书、备份、日志（勿提交）
├── generated/                             面板渲染出的 haproxy.cfg / xray.json 等
└── .venv313/                              面板 Python 环境
```

---

## 5. 两个硬依赖：MySQL 和 Redis

这两样**不能省也不能替**：

- **MySQL / MariaDB**：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...` 读 enum 列，SQLite 不支持。
- **真 Redis**：缓存、session、`evalsha` 都用它，`fakeredis` 跑不通。

一键安装会自动装。手动部署要确认两者在跑：

```bash
systemctl status mariadb mysql redis-server 2>&1 | head
```

连接串在面板配置里（`/opt/hiddify-manager/data/hiddify-panel/app.cfg`）：

```ini
SQLALCHEMY_DATABASE_URI=mysql+pymysql://<user>:<pass>@localhost/hiddifypanel?charset=utf8mb4
REDIS_URI_MAIN=redis://localhost:6379/0
REDIS_URI_OTHER=redis://localhost:6379/1
```

> `mysqlclient` 需要编译；装不上可换 `pymysql`，把 URI 驱动改成 `mysql+pymysql://`。

---

## 6. 装完怎么验

### 服务

```bash
systemctl status hiddify-panel --no-pager
journalctl -u hiddify-panel -n 50 --no-pager
```

### 数据库

```bash
mysql -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';"
```

应为 **184**。全新库会从 `_v1` 跑到 `_v184`，建出 **21 张表**。

### HTTP

路由都挂在 `/<proxy_path>/` 前缀下，`proxy_path` 从库里读：

```bash
PP=$(mysql -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='proxy_path';")
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:9000/$PP/"
```

> 未登录访问 `/<proxy_path>/admin/` 返回 **302 跳登录页是正常的**，不是故障。

### 浏览器

打开管理端 V2，确认：

- 界面文字正常（译文件语法错误会让整包翻译加载失败）
- 侧边栏导航齐全：仪表盘 / 用户 / 管理员 / 节点 / 设置 / 域名 / 协议 / 备份 / 出站
- 列表页空状态、搜索无结果提示正常
- 订阅链接可用

完整启动后的基线数字：**445 条路由、31 个蓝图、调度器 9 个任务**。

---

## 7. 备份与回滚

| 备份什么 | 在哪 / 怎么来 |
| --- | --- |
| 面板数据与配置 | 面板"备份"页，或 `services/panel/backup.sh` |
| 服务器状态 | `data/`（含 `data/cert` 证书、`data/backup`） |
| 首次转换前的全量快照 | `/opt/hiddify-manager.bak.<时间戳>` |

代码和数据要**分开回滚**：

- 代码：`git reset --hard <上一个提交>` + `git submodule update --init --recursive` + `make build`
- 数据：用 `backup.sh` 生成的那份备份

> 改迁移前务必先备份：面板启动时自动执行 `_vNNN`，跑坏了只能靠备份救。

---

## 8. 出问题看这里

| 现象 | 原因与处理 |
| --- | --- |
| `must be run by root` | 用 `sudo -i` 再跑 |
| 80/443 被占 | 停掉 nginx / Apache（见第 2 节） |
| 构建退出码 137 | 内存不足被 OOM kill，加 swap 后重跑 `make build` |
| 日志报 `base_template` | `flask-admin` 装成了 2.x，必须 `1.6.1`（见 [测试与验证](testing.md)） |
| 日志报 `REDIS_URI_MAIN` | `app.cfg` 缺 Redis 配置 |
| 日志报 `near "SHOW": syntax error` | 用了 SQLite，面板硬依赖 MySQL（见第 5 节） |
| 迁移卡住 / `Waiting for table metadata lock` | 有残留数据库连接没关（见 [测试与验证](testing.md)） |
| 界面白屏、文字变成 key | 译文件 JSON 语法错误导致构建失败，见 [升级](server-update.md) |
| 订阅链接打不开 | 看 HAProxy 是否在跑、证书是否签发成功（`data/cert`） |
| `admin/live/` 404 | 用 WSGI 开发服务器跑的，生产是 granian ASGI |

日志入口：

```bash
journalctl -u hiddify-panel -n 100 --no-pager      # 面板
journalctl -u haproxy -n 50 --no-pager             # 入口
tail -n 50 /opt/hiddify-manager/data/log/*          # 安装与应用日志
```

---

## 9. 维护提醒

- **别手改 `data/` 和 `generated/`**，它们会被重新生成。
- 改管理端 UI 动 `admin_v2`，改用户界面动 `user_front`；旧 Flask-Admin 页面是遗留代码，不要改。
- 生产环境不要开 `make debug-panel`（Flask 开发服务器 + `--reload`，且绑定 `0.0.0.0`）。
- 升级会重启面板、中断服务数分钟，见 [升级](server-update.md)。
