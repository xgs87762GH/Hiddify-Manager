# Docker 部署（实验性）

> **Docker 支持还没稳定，生产请用裸机安装**：[一键部署](onekey.md) 或 [服务器手动部署](manual.md)。
> 未完成项见第 4 节。

---

## 1. 一条命令

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/common/docker-installer.sh) beta
```

> 不要用官方那条 `hiddify/Hiddify-Manager/main/...`：它拉的是官方脚本和官方镜像。
> 本 fork 镜像由 `docker.yaml` 发布到 `ghcr.io/xgs87762gh/hiddify-manager`，
> tag 为版本号（如 `v14.2.5`），预发布版本额外打 `beta`。

安装脚本做的事：

1. 从本 fork 下载 `docker-compose.yml` + `docker.env`（**不需要本地 Dockerfile**）
2. 用 `image: ghcr.io/xgs87762gh/hiddify-manager:<tag>`，而不是 `build: .`
3. 随机生成 `MYSQL_PASSWORD` / `REDIS_PASSWORD`，并**改写** `SQLALCHEMY_DATABASE_URI` / `REDIS_URI_MAIN`

---

## 2. 两种 profile

| Profile | 文件 | 网络 | Privileged | 端口 | 什么时候用 |
| --- | --- | --- | --- | --- | --- |
| **Host（默认）** | `docker-compose.yml` | `network_mode: host` | 是 | 全部主机端口（80/443 + 代理端口） | 这台机器主要跑 Hiddify |
| **Bridge** | `docker-compose.bridge.yml` | bridge | 否 | 仅 80/TCP、443/TCP+UDP | 主机端口已被别的栈占用 |

Bridge 模式要用 Compose 的 DNS 名做连接串：

```env
SQLALCHEMY_DATABASE_URI="mysql+mysqldb://hiddifypanel:PASS@mariadb:3306/hiddifypanel?charset=utf8mb4"
REDIS_URI_MAIN="redis://:PASS@redis:6379/1"
```

Host 模式保持 `127.0.0.1`（MariaDB / Redis 只发布到 localhost）。

想用远程 MySQL / Redis 代替内置容器，见
[运维 → 外部数据库](../ops/external-database.md)（override 文件：`docker-compose.external-db.yml`）。

---

## 3. 挂载面板做开发

```bash
docker compose -f docker-compose.yml -f docker-compose.override.yaml up -d
# 在主机上改完 UI 后：
make ui
```

镜像入口在启动时会跑一次 apply/start；`uv pip install -e` 只在面板源码被 bind-mount
或 `HIDDIFY_PANEL_EDITABLE=1` 时执行。

---

## 4. 已知限制（所以才是实验性）

- 进程模型仍是 **python-systemctl** shim，不是真正的容器 PID 1 / supervisor。
- 默认 profile 需要 **privileged + host network**（HAProxy / Xray / hiddify-core 要开很多监听端口）。
- Bridge profile **不会**发布完整的动态代理端口，要完整代理能力请用 host profile。
- 端口数量与内存占用偏高：[#4737](https://github.com/hiddify/Hiddify-Manager/issues/4737)
- Docker 下的 systemd bus / 稳定安装：[#5134](https://github.com/hiddify/Hiddify-Manager/issues/5134)

---

## 5. 出问题看这里

| 现象 | 处理 |
| --- | --- |
| 端口冲突 | 换 bridge profile，或停掉占用 80/443 的服务 |
| 面板起不来 | `docker compose logs hiddify-manager --tail 100`，多半是 `app.cfg` 里的连接串 |
| 连不上数据库 | host 模式用 `127.0.0.1`，bridge 模式用服务名 `mariadb` / `redis` |
| 代理端口不通 | bridge profile 不发布动态端口，改用 host |

通用排错见 [部署总览 → 出问题看这里](README.md#4-出问题看这里)。
