# 文档总目录（中文为主语言）

本仓库是 `Hiddify/Hiddify-Manager` 的**二开 fork**（`xgs87762GH/Hiddify-Manager`）。
**中文是主要语言**，所有导航与教程都用中文；其它语言只在 [`i18n/`](i18n/README.md) 下按原语言留存。

- 仓库总入口：[根目录 README.md](../README.md)
- 分支模型与提交纪律：[AGENTS.md](../AGENTS.md)、[DEVELOPMENT.md](../DEVELOPMENT.md)

---

## 按角色找文档

| 目录 | 解决什么问题 |
| --- | --- |
| [deploy/](deploy/README.md) | **首次部署**：一键部署、git 拉取开发、Docker、服务器手动部署 |
| [dev/](dev/README.md) | **开发**：构建与安装依赖、测试与验证 |
| [ops/](ops/README.md) | **运维**：升级与切版本、域名、外部数据库、自定义代理、面板 Session 跳板 |
| [release/](release/README.md) | **发版**：版本号、发布前检查、打 tag、Actions 产物、校验、回滚 |
| [i18n/](i18n/README.md) | **其它语言**（en / fa / ru），内容保持原语言 |

单个文件索引：

| 文档 | 内容 |
| --- | --- |
| [deploy/onekey.md](deploy/onekey.md) | 一键部署（推荐） |
| [deploy/git-checkout.md](deploy/git-checkout.md) | 通过 git 拉取开发 |
| [deploy/manual.md](deploy/manual.md) | 服务器手动部署 |
| [deploy/docker.md](deploy/docker.md) | Docker 部署（实验性） |
| [dev/build-requirements.md](dev/build-requirements.md) | 构建与安装依赖 |
| [dev/testing.md](dev/testing.md) | 测试与验证 |
| [ops/server-update.md](ops/server-update.md) | 升级与切版本 |
| [ops/create_domain.md](ops/create_domain.md) | 域名 |
| [ops/customize_proxies.md](ops/customize_proxies.md) | 自定义代理与出站 |
| [ops/external-database.md](ops/external-database.md) | 外部数据库 |
| [ops/panel-ssh-via-session.md](ops/panel-ssh-via-session.md) | 面板 Session 跳板 |
| [release/release.md](release/release.md) | 打包发布流程 |
| [cloud-init.yml](cloud-init.yml) | 云主机开机自动安装示例 |

---

## 快速上手

```bash
OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh

sudo -i
bash <(curl -fsSL "$OK") install             # 全新安装
bash <(curl -fsSL "$OK") update              # 升级（会先备份）
bash <(curl -fsSL "$OK") reinstall           # 按当前代码重装服务
bash <(curl -fsSL "$OK") version v14.2.4 -y  # 切到指定版本
bash <(curl -fsSL "$OK") switch              # 官方安装 → 转本 fork
```

`/bin/sh`（cloud-init 的 `runcmd`）没有 `<( )`，改写成
`curl -fsSL "$OK" -o /tmp/ok.sh && bash /tmp/ok.sh install`。

---

## 支持的协议

| 协议 | 说明 |
| --- | --- |
| VLESS / VMess | 含 REALITY、gRPC、WebSocket、HTTPUpgrade 等传输 |
| Trojan | TCP / gRPC / WebSocket |
| Shadowsocks | 含 2022 系列 |
| Hysteria2 / TUIC | 基于 QUIC |
| WireGuard | 面板可配 |
| SSH (ssh-liberty) | 可选组件 |
| Telegram proxy (telemt) | 可选组件，默认关闭 |

---

## 运行环境

| 项 | 要求 |
| --- | --- |
| 系统 | Ubuntu 22.04 或更新的 Debian 系 |
| 权限 | root |
| Python | ≥ 3.13 |
| 内存 | ≥ 1 GB（构建 UI 约需 1.2 GB，脚本会自动挂临时 swap） |
| 磁盘 | 建议 ≥ 10 GB |
| 端口 | 80、443 必须先空出来；9000 为面板（在 HAProxy 后） |
| 依赖 | MySQL / MariaDB 与 Redis **不可替换**（详见 [deploy/README.md](deploy/README.md#2-装之前的共同前置)） |

---

## 维护提醒

- **别手改 `data/` 和 `generated/`**：前者是运行时状态，后者是生成物。
- 重启面板会跑数据库迁移，生产环境操作前先打招呼。
- 改面板逻辑要提交到子模块 `services/panel/src`，且**先推子模块再推外层指针**。

许可证：AGPL-3.0。
