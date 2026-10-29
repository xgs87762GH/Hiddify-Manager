# Hiddify-Manager（二开版）

[Hiddify-Manager](https://github.com/hiddify/Hiddify-Manager) 的个人二开版本维护仓库。
面板、脚本、更新链路已全部指向本 fork，**不会再被官方版本覆盖**。

| 项 | 值 |
| --- | --- |
| 上游 | `hiddify/Hiddify-Manager`（只读同步） |
| 本仓库（fork） | `xgs87762GH/Hiddify-Manager` |
| 维护分支 | `dev-custom`（自定义代码只写这里） |
| 面板子模块 | `services/panel/src` → `xgs87762GH/hiddifypanel` |
| 当前版本 | 见 [VERSION](VERSION)，tag 形如 `v14.1.0b3` |
| 许可证 | AGPL-3.0（沿用上游） |

---

## 文档索引

| 我要… | 看这里 |
| --- | --- |
| **第一次装服务器** | [docs/deployment.md](docs/deployment.md) |
| **升级已装好的服务器** | [docs/server-update.md](docs/server-update.md) |
| **查构建/安装脚本依赖哪些外部资源** | [docs/build-requirements.md](docs/build-requirements.md) |
| **打一个新版本（tag + release 包）** | [docs/release.md](docs/release.md) |
| **这个版本相对官方改了什么** | [docs/release-notes/v14.1.0b3.md](docs/release-notes/v14.1.0b3.md) |
| **跑测试、验证面板是否正常** | [docs/testing.md](docs/testing.md) |
| **改代码（开发环境、目录、提交顺序）** | [DEVELOPMENT.md](DEVELOPMENT.md) |
| **分支模型与硬性禁令** | [AGENTS.md](AGENTS.md) |
| **Docker 部署** | [docs/DOCKER.md](docs/DOCKER.md) |
| **官方英文原版 README** | [docs/README_upstream_en.md](docs/README_upstream_en.md) |

---

## 快速开始

> 下面每条都是**一条命令**：不用先 clone、不用 cd、不用记路径。
> 装好之后也可以直接跑 `bash /opt/hiddify-manager/scripts/onekey.sh <子命令>`，省掉 curl。

### 全新部署

```bash
sudo -i
ONEKEY=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh
bash <(curl -fsSL "$ONEKEY") install
```

脚本会 `git clone --recurse-submodules` 本 fork 到 `/opt/hiddify-manager`（含面板子模块），
再装好 HAProxy、代理核心、MySQL、Redis 和面板。全程无交互，10–30 分钟。

### 其它日常操作

同一个脚本的其它子命令：

| 子命令 | 作用 |
| --- | --- |
| `update` | 升级（备份 → ff-only 快进 fork → 子模块 → `make build`） |
| `reinstall` | 按当前代码重装全部服务（不拉新代码） |
| `version v14.2.4 -y` | 切到指定发布版本（**git 检出同样可用**：强制换代码，保留 `data/`、`generated/` 与虚拟环境） |
| `switch` | 机器上已是官方版本 → 转成本 fork 的 git 检出 |

用法就是把 `install` 换掉，例如：

```bash
bash <(curl -fsSL "$ONEKEY") update
bash <(curl -fsSL "$ONEKEY") reinstall
bash <(curl -fsSL "$ONEKEY") version v14.2.4 -y
```

> `onekey.sh` 每次都是**从 GitHub 现取**的：老机器也能立刻拿到最新修复。
> 切版本时**不要**用 `git clean -fdx` 手动清理，它会连 `data/` 一起删掉。

### 手动部署（与 `install` 等价）

```bash
sudo -i
git clone --recurse-submodules -b dev-custom \
    https://github.com/xgs87762GH/Hiddify-Manager.git /opt/hiddify-manager
cd /opt/hiddify-manager
bash scripts/install.sh --no-gui
```

面板里点"更新"效果相同：git checkout 部署时只快进 fork，**从不下载官方包**。

---

## 与上游的差异

| 方面 | 本 fork 的行为 |
| --- | --- |
| 更新来源 | 只读 `xgs87762GH/Hiddify-Manager`（`dev-custom`），官方仓库仅作为 `upstream` 同步源 |
| 面板安装 | 从 `xgs87762GH/hiddifypanel` 源码构建安装，不再从官方 PyPI 拉 `hiddifypanel` |
| 版本查询 | GitHub API 查询目标为本 fork（release / pre-release / commit） |
| 回退 | 只能回退到本 fork 的 tag，`custom` 安装菜单只列本 fork 的 tag |
| 文档 | 中文，按部署 / 升级 / 构建依赖 / 发布 / 测试组织 |

> 上面每一条都在脚本里落实过：涉及 `scripts/update.sh`、`scripts/common/{utils,download,hiddify_installer,downgrade,docker-installer}.sh`。

---

## 支持的协议（摘要）

Reality（XTLS / gRPC）、VLESS、VMess、Trojan、Shadowsocks、Hysteria2、TUICv5、
WireGuard、SSH、Telegram 代理、DNS over HTTPS、CDN / 域名前置。
完整清单见 [docs/README_cn.md](docs/README_cn.md)。

---

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `scripts/` | 安装、升级、切换 fork、打包下载等脚本 |
| `scripts/common/` | 公共库 `utils.sh`、依赖清单 `packages.lock`、安装器与下载器 |
| `services/` | 各服务（haproxy / xray / singbox / hiddify-core / panel …）的 install/run 脚本 |
| `services/panel/src/` | 面板子模块（Flask + Vue 管理端） |
| `docs/` | 中文文档 |
| `data/`、`generated/` | 运行时状态与生成物，**不进 git** |

---

## 常用命令

| 命令 | 作用 |
| --- | --- |
| `make build` | 构建 UI 并完整安装 / 重装 |
| `make ui` | 只构建管理端 + 用户端 UI |
| `make apply` | 只应用配置（不重装服务） |
| `bash scripts/onekey.sh <install\|update\|reinstall\|version\|switch>` | 统一入口；上面那些操作的安全包装，可 `bash <(curl …)` 直接跑 |
| `bash scripts/update.sh` | 升级（备份 + 快进 + 重建） |
| `bash scripts/switch_to_fork.sh` | 官方安装 → fork checkout（幂等） |

---

## 致谢

上游项目及其依赖：[Hiddify-Manager](https://github.com/hiddify/Hiddify-Manager)、
[Xray-core](https://github.com/XTLS/Xray-core)、[sing-box](https://github.com/SagerNet/sing-box)、
[mihomo](https://github.com/MetaCubeX/mihomo)、[Hiddify-core](https://github.com/hiddify/hiddify-core)。
