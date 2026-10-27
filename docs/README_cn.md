# Hiddify-Manager 中文说明

> 本页是本 fork 维护的中文说明，已经被 [根目录 README](../README.md) 取代为主入口。
> 官方英文原版见 [README_upstream_en.md](README_upstream_en.md)。

Hiddify-Manager 是支持多用户的面板，面向**网络审查环境**优化（中国 / 俄罗斯 / 伊朗），
集成 Xray、sing-box、hiddify-core 等核心，支持 20 余种协议与 Telegram 代理。

---

## 文档

| 我要… | 看这里 |
| --- | --- |
| 部署一台新服务器 | [deployment.md](deployment.md) |
| 升级已装的服务器 | [server-update.md](server-update.md) |
| 本机 SSH 不通时用面板 Session 跳板 | [panel-ssh-via-session.md](panel-ssh-via-session.md) |
| 查构建依赖（GitHub 构建物等） | [build-requirements.md](build-requirements.md) |
| 打版本 / 出 release 包 | [release.md](release.md) |
| 跑测试与验证 | [testing.md](testing.md) |
| Docker | [DOCKER.md](DOCKER.md) |
| 开发环境与提交顺序 | [../DEVELOPMENT.md](../DEVELOPMENT.md) |
| 分支模型与硬性禁令 | [../AGENTS.md](../AGENTS.md) |

---

## 支持的协议

| 类别 | 内容 |
| --- | --- |
| Reality | VLESS + Reality（XTLS / gRPC） |
| TLS / CDN | VLESS、VMess、Trojan（WS / gRPC / H2，支持 CDN、域名前置） |
| 其它 | Shadowsocks（ShadowTLS）、Hysteria2、TUICv5、WireGuard、SSH |
| 特色 | Telegram 代理（MTProxy）、DNS over HTTPS、WARP、Redirector |

---

## 主要特性

- 一键安装、面板内"更新"，全部指向本 fork（不会回退官方版本）
- Xray / sing-box / hiddify-core 多核心，可在线切换
- 智能分流（直连 / 代理 / 全部代理，适配 Hiddify 与 Clash 客户端）
- 用户管理、流量与时长限制、独立用户页与订阅
- 自动备份（默认每 6 小时）、多域名、自动 CDN IP、Cloudflare 联动
- Telegram Bot 管理用户
- 管理端（Vue 3 + PrimeVue）与用户端（React）现代 UI

---

## 运行环境

- Ubuntu 22.04 或更新的 Debian 系，**必须 root**
- Python ≥ 3.13，MySQL + Redis（面板硬依赖）
- 端口 80 / 443 空闲（ACME 与代理入口）
- 构建 UI 需 ~1.2 GB 空闲内存（脚本会尝试自动挂临时 swap）

---

## 许可证

AGPL-3.0，沿用上游 [hiddify/Hiddify-Manager](https://github.com/hiddify/Hiddify-Manager)。
对外提供基于本项目的网络服务时，分发义务请自行评估。
