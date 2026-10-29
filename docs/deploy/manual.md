# 服务器手动部署

> 适合：想看清每一步、要自定义目录或参数。
> 想省事就用 [一键部署](onekey.md)；要改代码看 [git 拉取开发](git-checkout.md)。
> 前置条件见 [部署总览 → 装之前的共同前置](README.md#2-装之前的共同前置)。

---

## 1. 手动步骤（与一键等价）

```bash
sudo -i
git clone --recurse-submodules -b dev-custom \
    https://github.com/xgs87762GH/Hiddify-Manager.git /opt/hiddify-manager
cd /opt/hiddify-manager
bash scripts/install.sh --no-gui
```

`install.sh` 的常用参数：

| 参数 | 作用 |
| --- | --- |
| `--no-gui` | 非交互，按当前配置直接装 |
| `--no-log` | 不额外落安装日志（配合 `--no-gui` 用于自动化） |

装之前先确认端口没被占：

```bash
ss -lntp | grep -E ':80 |:443 '     # 有输出说明被占，先停掉 nginx / Apache
```

---

## 2. 会装上什么

HAProxy（入口与路由）、xray / sing-box / hiddify-core（代理核心）、MySQL（面板库）、
Redis（缓存与 session）、面板本身（granian ASGI，9000 端口），
以及 telemt、ssh-liberty、warp、wireguard、ssfaketls 等可选组件。

需要从 GitHub 拉核心二进制、面板源码和 Node 工具链，依赖清单见
[开发 → 构建与安装依赖](../dev/build-requirements.md)。

历史路径 `/opt/hiddify-server`、`/opt/hiddify-config` 会自动改名并留软链。

---

## 3. 装完怎么验

```bash
# 服务
systemctl status hiddify-panel --no-pager
bash /opt/hiddify-manager/scripts/status.sh

# 数据库
mysql -uroot -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='db_version';"

# HTTP（PP 从库里读 proxy_path）
PP=$(mysql -uroot -N -e "SELECT value FROM hiddifypanel.str_config WHERE \`key\`='proxy_path';")
curl -s -o /dev/null -w "%{http_code}\n" "http://127.0.0.1:9000/$PP/"
```

完整验收清单见 [部署总览 → 装完怎么验](README.md#3-装完怎么验)。

---

## 4. 目录结构

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

> **别手改 `data/` 和 `generated/`**，它们会被重新生成。

---

## 5. 常见问题

| 现象 | 处理 |
| --- | --- |
| `must be run by root` | 用 `sudo -i` 再跑 |
| 构建退出码 137 | 内存不足被 OOM kill，加 swap 后重跑 |
| 日志报 `near "SHOW": syntax error` | 用了 SQLite，面板硬依赖 MySQL |
| 迁移卡住 / `Waiting for table metadata lock` | 有残留数据库连接没关，见 [测试与验证](../dev/testing.md) |
| 80/443 被占 | 停掉 nginx / Apache |

更多见 [部署总览 → 出问题看这里](README.md#4-出问题看这里)。

---

## 6. 接下来

升级与切版本同样可以回到一条命令（`onekey.sh` 对 git 检出也能用）：

```bash
OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh
bash <(curl -fsSL "$OK") update
```

细节见 [运维 → 升级](../ops/server-update.md)。
