# 构建与安装依赖

> 讲清楚**安装 / 升级 / 打包时脚本会从外面下载什么**。这些外部资源取不到，安装就会失败。
> 部署流程看 [部署](deployment.md)，升级看 [升级](server-update.md)，打版本看 [打包发布](release.md)。

脚本本身不含任何二进制和前端产物，全部运行时下载，**以 GitHub 构建物为主**。

---

## 1. GitHub 构建物（核心依赖）

### 1.1 代理核心与组件

版本、下载地址、sha256 全部固定在 [scripts/common/packages.lock](../scripts/common/packages.lock)，
由 `scripts/common/package_manager.sh` 下载并**强制校验 sha256**，不匹配即删除重下。

| 组件 | 来源仓库 | 用途 |
| --- | --- | --- |
| `xray` | `XTLS/Xray-core` releases | 主代理核心 |
| `singbox` | `hiddify/hiddify-sing-box` releases | sing-box 核心 |
| `hiddify-core` | `hiddify/hiddify-core` releases | Hiddify 专用核心 |
| `clash` | `MetaCubeX/mihomo` releases | Clash 订阅支持 |
| `wgcf` | `ViRb3/wgcf` releases | Cloudflare WARP 注册 |
| `telemt` | `telemt/telemt` releases | Telegram MTProxy |
| `rpxy-l4` | `junkurihara/rust-rpxy-l4` releases | 四层反代 |
| `dnstm` / `dnstt` / `masterdns` / `vaydns` | `hiddify/*` 等 releases | DNS 隧道 |
| `slipstream` | releases | TCP over DNS |
| `mtproxygo` | releases | MTProxy |
| `v2ray-plugin` | releases | Shadowsocks 插件 |
| `ssh-liberty-bridge` | `hiddify/ssh-liberty-bridge` releases | SSH 加速 |

- 架构：仅 `amd64` / `arm64`。
- 升级某个组件：改 `packages.lock` 对应行（或用 `package_manager.sh add` 自动补 hash）。

### 1.2 面板与前端

| 产物 | 来源 | 说明 |
| --- | --- | --- |
| 面板源码 | `xgs87762GH/hiddifypanel`（`HIDDIFY_PANEL_REPO`） | `install_panel_from_git` 克隆 → 构建 UI → 安装，**不走官方 PyPI** |
| 管理端 UI（预构建） | `xgs87762GH/hiddifypanel` 的 `prebuilt` 分支 | 默认优先；清单在 `scripts/admin-ui-prebuilt.tsv`（带 sha256），按面板 commit 取包 |
| 管理端 UI（源码，兜底） | 上述仓库的 `hiddifypanel/admin_v2` | 没有对应预构建包时在服务器上 npm 构建（约 1.2 GB 内存），产物不入 git |
| 用户端 UI（预构建） | `hiddify/hiddify-user-front` 的 `gh-pages` 分支 | 低内存方案，`install_prebuilt.sh` 直接克隆静态产物 |
| 用户端 UI（源码） | 面板子模块内的 `user_front` | 仅当 `HIDDIFY_USER_FRONT_FROM_SOURCE=1` 时编译 |

### 1.3 Manager 自身

| 产物 | 来源 | 使用场景 |
| --- | --- | --- |
| `hiddify-manager.zip` | `xgs87762GH/Hiddify-Manager` releases | **非 git checkout** 的服务器升级 / 指定 tag 安装 |
| `download.sh` / `utils.sh` | fork 的 `dev-custom` 分支 raw 地址 | 安装与更新的引导脚本 |

> fork 的 release 由 [.github/workflows/release.yml](../.github/workflows/release.yml) 在推 `v*` tag 时自动生成。

### 1.4 其它 GitHub 资源

| 资源 | 地址 | 时机 |
| --- | --- | --- |
| GeoLite2 ASN / Country 库 | `P3TERX/GeoLite.mmdb` raw | 面板安装时（失败可容忍，缺失则无地理位置） |
| warp-go | `fscarmen/warp` raw + GitLab `ProjectWARP/warp-go` releases | 启用 WARP（sing-box 模式） |

---

## 2. 非 GitHub 依赖

| 资源 | 地址 | 备注 |
| --- | --- | --- |
| Node.js `22.23.3` | `nodejs.org/dist` → 失败回退 `npmmirror.com` | 带 `SHASUMS256.txt` 校验 |
| npm `12.1.0` | Node 官方包 / npm registry | 构建管理端 UI |
| Python 依赖 | PyPI（`uv pip`） | venv 为 3.13 |
| 系统包 | Ubuntu 官方 apt 源 | 见 `scripts/install.sh` |
| HAProxy | `pks.haproxy.com` apt 源 | 安装 HAProxy |
| Docker 镜像 | Docker Hub（mariadb/redis）+ `ghcr.io/hiddify/hiddify-manager` | 仅 Docker 模式 |
| GeoIP / 证书 | Let's Encrypt / ZeroSSL | 运行时，非构建 |

---

## 3. 可配置项

| 变量 | 默认值 | 作用 |
| --- | --- | --- |
| `HIDDIFY_GITHUB_USER` | `xgs87762GH` | 所有 fork 仓库的所有者 |
| `HIDDIFY_MANAGER_REPO` | `${HIDDIFY_GITHUB_USER}/Hiddify-Manager` | Manager 下载源 |
| `HIDDIFY_PANEL_REPO` | `${HIDDIFY_GITHUB_USER}/hiddifypanel` | 面板源码源 |
| `HIDDIFY_MANAGER_BRANCH` | `dev-custom` | 下载脚本 / 引导脚本所用分支 |
| `HIDDIFY_GIT_REMOTE` / `HIDDIFY_GIT_BRANCH` | `origin` / 当前分支 | git checkout 升级源 |
| `HIDDIFY_NODE_VERSION` / `HIDDIFY_NPM_VERSION` | `22.23.3` / `12.1.0` | UI 构建工具链版本 |
| `HIDDIFY_NODE_MIRRORS` | `nodejs.org/dist` + `npmmirror` | Node 下载镜像，空格分隔 |
| `HIDDIFY_USER_FRONT_FROM_SOURCE` | 空（用预构建） | 设为 `1` 编译用户端 |
| `HIDDIFY_ADMIN_UI_PREBUILT` | `1` | 设为 `0` 强制在服务器编译管理端 UI |
| `HIDDIFY_ADMIN_UI_PREBUILT_REPO` / `_BRANCH` | `xgs87762GH/hiddifypanel` / `prebuilt` | 预构建管理端 UI 的来源 |
| `HIDDIFY_DISABLE_UPDATE` | 空 | 设为 `1` 彻底禁用更新 |
| `http_proxy` / `https_proxy` | 空 | curl / git / pip 都读，受限网络必配 |

---

## 4. 网络与限流

安装 / 升级机器必须能出网访问：`github.com`、`raw.githubusercontent.com`、`api.github.com`、
`objects.githubusercontent.com`（release 附件）、`nodejs.org`、`pypi.org`、Ubuntu apt 源。

- **GitHub API 未认证限流 60 次/小时**（按出口 IP）。版本查询走 API，频繁重试或多人共用 IP 会拿到空值：
  表现为"最新版本为空"，此时按下文第 5 节处理。
- git 克隆子模块走 HTTPS（fork 公开），不需要部署 SSH key。
- 只有 HTTP 代理时：`export https_proxy=http://127.0.0.1:12334` 后重跑；大文件建议走 SSH（`ssh.github.com:443`）。

---

## 5. 常见失败

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| `Hash mismatch for ...` | 下载到残缺文件或代理篡改 | 直接重跑；连续失败换网络 |
| `Could not get Node.js ...` | 两个镜像都不可达 | 设 `HIDDIFY_NODE_MIRRORS` 指向可用镜像 |
| 构建退出码 `137` | 内存不足（UI 构建约需 1.2 GB） | 加 2 GB swap 或扩内存后 `make ui` |
| `Could not download the panel source` | 面板 fork 不可达 / 分支不存在 | 确认 `HIDDIFY_PANEL_REPO` 与网络 |
| `Failed to fetch` / `not our ref`（子模块） | 子模块指针指向未推送的 commit | 先推面板 fork，再在外层记指针 |
| 版本查询结果为空 | GitHub API 限流或不通 | 等一小时，或直接用 `update.sh` 强制更新 |
| `releases/latest` 404 | fork 还没有任何 release | 按 [打包发布](release.md) 打第一个 tag |

---

## 6. 内网 / 离线能做到什么

**完全离线装不了**：核心二进制、面板源码、Node 工具链都来自网络。可以做的：

1. 把 `packages.lock` 里的 GitHub URL 换成本地镜像地址（hash 不变）。
2. 预置 `.cache/nodejs/` 下的 Node 包，避免重复下载。
3. 用 `HIDDIFY_MANAGER_REPO` / `HIDDIFY_PANEL_REPO` 指到内网 Git 服务。
4. 首次安装后保留 `data/` 备份，后续升级可回滚数据。
