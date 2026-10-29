# 一键部署（推荐）

> 适合：新机器、想最少步骤。
> 部署方式对比见 [部署总览](README.md)，装完之后的升级见 [运维 → 升级](../ops/server-update.md)。

---

## 1. 一条命令

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) install
```

存成变量更短（同一条命令，后续所有子命令都复用它）：

```bash
OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh
bash <(curl -fsSL "$OK") install
```

前置条件（root、端口、内存等）见 [部署总览 → 装之前的共同前置](README.md#2-装之前的共同前置)。

---

## 2. 它做了什么

`onekey.sh install` 等价于下面的手动流程，外加前置检查：

1. 目录不存在 → `git clone --recurse-submodules -b dev-custom` 到 `/opt/hiddify-manager`（含面板子模块）
2. 执行 `scripts/install.sh --no-gui --no-log`
3. 目录已存在但**不是** git 检出（官方 zip 安装）→ **拒绝覆盖**，提示改用 `onekey.sh switch`
4. 已经是 git 检出 → 自动转为 `onekey.sh update`，不会重复 clone

装的是本 fork 的 `dev-custom` 与面板 fork，之后升级只快进这条分支，不会被官方版本覆盖。

---

## 3. 会装上什么

- **HAProxy**：入口与路由
- **xray / sing-box / hiddify-core**：代理核心
- **MySQL / MariaDB**：面板库
- **Redis**：缓存与 session
- **面板本身**：granian ASGI，跑在 9000 端口、HAProxy 后面
- 可选组件：telemt、ssh-liberty、warp、wireguard、ssfaketls

装完目录是 `/opt/hiddify-manager`。历史路径 `/opt/hiddify-server`、`/opt/hiddify-config`
会自动改名并留软链，不用手动处理。

需要从 GitHub 拉核心二进制、面板源码和 Node 工具链，依赖清单见
[开发 → 构建与安装依赖](../dev/build-requirements.md)。

---

## 4. 装完怎么验

```bash
systemctl status hiddify-panel --no-pager
bash /opt/hiddify-manager/scripts/status.sh
mysql -uroot -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';"
```

完整验收清单见 [部署总览 → 装完怎么验](README.md#3-装完怎么验)。

浏览器打开 `https://<你的域名>/<proxy_path_admin>/<uuid>/admin/`（凭据在安装结尾会打印，
也能从 `data/current.json` 里读）。

---

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| `must be run by root` | 用 `sudo -i` 再跑 |
| 提示"已经是 zip 安装，拒绝覆盖" | 改用 `bash <(curl -fsSL "$OK") switch` |
| `/bin/sh` 下报语法错误 | `runcmd`、cloud-init 没有 `<( )`，改 `curl -fsSL "$OK" -o /tmp/ok.sh && bash /tmp/ok.sh install` |
| 装到一半失败 | 看 `/opt/hiddify-manager/data/log/`，修完重跑同一条命令（幂等） |

更多见 [部署总览 → 出问题看这里](README.md#4-出问题看这里)。

---

## 6. 接下来

| 要做什么 | 命令 |
| --- | --- |
| 升级 | `bash <(curl -fsSL "$OK") update` |
| 换版本 | `bash <(curl -fsSL "$OK") version v14.2.4 -y` |
| 重装服务 | `bash <(curl -fsSL "$OK") reinstall` |
| 加域名 | [运维 → 域名](../ops/create_domain.md) |
| 改代理 | [运维 → 自定义代理](../ops/help_customize_proxies.md) |
