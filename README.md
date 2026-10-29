# Hiddify-Manager（二开版 / fork）

[![License: AGPL v3](https://img.shields.io/badge/License-AGPL%20v3-blue.svg)](LICENSE)

本仓库是 [Hiddify/Hiddify-Manager](https://github.com/Hiddify/Hiddify-Manager) 的**二次开发 fork**，
不是官方仓库。上游只作为 `upstream` 远程同步源（**只读**），日常开发与发版都在本仓库的
`dev-custom` 分支；面板是独立子模块 `services/panel/src`（fork 自 `hiddify/hiddifypanel`，推到
`xgs87762GH/hiddifypanel`）。

| 项 | 值 |
| --- | --- |
| 上游 | `Hiddify/Hiddify-Manager`（只读同步） |
| 本 fork | `xgs87762GH/Hiddify-Manager`，维护分支 `dev-custom` |
| 面板子模块 | `xgs87762GH/hiddifypanel`，分支 `dev-custom` |
| 当前版本 | `14.2.5`（见 `VERSION`） |
| 文档语言 | **中文为主语言** |
| 许可证 | AGPL-3.0 |

> 分支模型、remote 约定与提交纪律见 [AGENTS.md](AGENTS.md) 与 [DEVELOPMENT.md](DEVELOPMENT.md)。

---

## 快速上手

**一条命令安装**（不用先 clone、不用 `cd`）：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) install
```

存成变量，后续所有操作都复用它：

```bash
OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh

bash <(curl -fsSL "$OK") install             # 全新安装
bash <(curl -fsSL "$OK") update              # 升级（会先备份）
bash <(curl -fsSL "$OK") reinstall           # 按当前代码重装服务
bash <(curl -fsSL "$OK") version v14.2.4 -y  # 切到指定版本（git 检出：强制换代码留数据）
bash <(curl -fsSL "$OK") switch              # 官方安装 → 转本 fork（只跑一次）
```

> `onekey.sh` 每次都是**从 GitHub 现取**的：老机器也能立刻拿到最新修复。
> `/bin/sh`、cloud-init 的 `runcmd` 没有 `<( )`，改写成
> `curl -fsSL "$OK" -o /tmp/ok.sh && bash /tmp/ok.sh install`。
> 切版本时**不要**用 `git clean -fdx` 手动清理，它会连 `data/` 一起删掉。

**不要用官方一键脚本 `bash <(curl https://i.hiddify.com/beta)`**：它装的是官方代码，
之后升级会去拉官方仓库。

---

## 文档导航

总目录：[docs/README.md](docs/README.md)

| 角色 | 入口 | 内容 |
| --- | --- | --- |
| **部署** | [docs/deploy/](docs/deploy/README.md) | [一键部署](docs/deploy/onekey.md)、[git 拉取开发](docs/deploy/git-checkout.md)、[服务器手动部署](docs/deploy/manual.md)、[Docker（实验性）](docs/deploy/docker.md) |
| **开发** | [docs/dev/](docs/dev/README.md) | [构建与安装依赖](docs/dev/build-requirements.md)、[测试与验证](docs/dev/testing.md) |
| **运维** | [docs/ops/](docs/ops/README.md) | [升级与切版本](docs/ops/server-update.md)、[域名](docs/ops/create_domain.md)、[自定义代理](docs/ops/customize_proxies.md)、[外部数据库](docs/ops/external-database.md)、[面板 SSH](docs/ops/panel-ssh-via-session.md) |
| **发版** | [docs/release/](docs/release/README.md) | [打包发布流程](docs/release/release.md) |
| 其它语言 | [docs/i18n/](docs/i18n/README.md) | en / fa / ru（原语言留存，中文为准） |

自动化示例：[docs/cloud-init.yml](docs/cloud-init.yml)（云主机开机自动安装）。

---

## 支持的协议

Reality（XTLS / gRPC）、VLESS、VMess、Trojan、Shadowsocks、Hysteria2、TUICv5、
WireGuard、SSH（ssh-liberty）、Telegram 代理（telemt）、DNS over HTTPS、CDN / 域名前置。

---

## 主要特性

- 多协议、多端口统一入口（HAProxy + 代理核心）
- 用户与流量管理、订阅链接、每用户自定义配置
- 自动签发与续期证书
- 备份 / 恢复、父子面板、多域名与 CDN 模式
- 管理端 V2（Vue 3）与用户界面 `user_front`

---

## 运行环境

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 或更新的 Debian 系 |
| 权限 | root |
| Python | ≥ 3.13 |
| 内存 | ≥ 1 GB（构建 UI 约需 1.2 GB，脚本会自动挂临时 swap） |
| 磁盘 | 建议 ≥ 10 GB |
| 端口 | 80、443 必须先空出来；9000 为面板（在 HAProxy 后，不直接暴露） |
| 依赖 | MySQL / MariaDB 与 Redis **不可替换**（面板用 `SHOW COLUMNS` 读 enum，且依赖真实 Redis） |

---

## 与上游的差异

| 方面 | 本 fork 的行为 |
| --- | --- |
| 更新来源 | 只读 `xgs87762GH/Hiddify-Manager`（`dev-custom`），官方仓库仅作为 `upstream` 同步源 |
| 面板安装 | 从 `xgs87762GH/hiddifypanel` 源码构建安装，不再从官方 PyPI 拉 `hiddifypanel` |
| 版本查询 | GitHub API 查询目标为本 fork（release / pre-release / commit） |
| 回退 | 只能回退到本 fork 的 tag，`custom` 安装菜单只列本 fork 的 tag |
| 文档 | 中文为主，按部署 / 开发 / 运维 / 发版组织 |

> 上面每一条都在脚本里落实过：涉及 `scripts/update.sh`、
> `scripts/common/{utils,download,hiddify_installer,downgrade,docker-installer}.sh`。

---

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `scripts/` | 安装、升级、切换 fork、打包下载等脚本 |
| `scripts/common/` | 公共库 `utils.sh`、依赖清单 `packages.lock`、安装器与下载器 |
| `services/` | 各服务（haproxy / xray / singbox / hiddify-core / panel …）的 install/run 脚本 |
| `services/panel/src/` | 面板子模块（Flask + Vue 管理端） |
| `docs/` | 中文文档（deploy / dev / ops / release / i18n） |
| `data/`、`generated/` | 运行时状态与生成物，**不进 git** |

---

## 许可证

AGPL-3.0。上游项目同为 AGPL-3.0。
