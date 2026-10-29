# 通过 git 拉取开发

> 适合：要改本 fork 的代码、参与二开。
> 只想装一台服务器 → [一键部署](onekey.md) 或 [服务器手动部署](manual.md)。
> 分支模型与提交纪律以 [AGENTS.md](../../AGENTS.md)、[DEVELOPMENT.md](../../DEVELOPMENT.md) 为准。

---

## 1. 拉取代码

```bash
sudo -i
git clone --recurse-submodules -b dev-custom \
    https://github.com/xgs87762GH/Hiddify-Manager.git /opt/hiddify-manager
cd /opt/hiddify-manager
make build
git -C services/panel/src checkout dev-custom    # 子模块也有自己的 dev-custom 分支
```

**开发机和服务器是同一份代码树**，没有"本地改完拷贝过去"这一步。与纯部署的区别只是用
`make build`（额外构建管理端 UI）。

`make build` = 构建管理端 UI + `scripts/install.sh --no-gui`（装全部服务并应用配置）。

> 子模块 `git submodule update` 之后默认是 **detached HEAD**，改代码前必须先
> `git -C services/panel/src checkout dev-custom`，否则提交会丢。

---

## 2. 分支与 remote

| 名称 | 类型 | 指向 | 约束 |
| --- | --- | --- | --- |
| `upstream` | remote | `Hiddify/Hiddify-Manager` | 只读，禁止 push |
| `origin` | remote | `xgs87762GH/Hiddify-Manager` | 个人 fork，可 push |
| `dev` | 官方镜像分支 | 跟踪 `upstream/dev` | **禁止**任何自定义提交，只允许 fast-forward |
| `dev-custom` | 日常开发分支 | 从 `dev` 切出 | 所有自定义改动只写这里 |

面板子模块同理（`services/panel/src`，官方 `hiddify/hiddifypanel`）：

| 名称 | 指向 | 约束 |
| --- | --- | --- |
| `upstream` | `hiddify/hiddifypanel` | 只读 |
| `fork` | `xgs87762GH/hiddifypanel` | 面板改动推这里 |
| `dev` | 跟踪官方 `dev` | 禁止提交 |
| `dev-custom` | 跟踪 `fork/dev-custom` | 面板代码只写这里 |

**.gitmodules 在 `dev-custom` 上指向 fork 的 HTTPS 地址**，服务器匿名克隆子模块不需要部署 ssh key；
推送仍在子模块内走 ssh，互不影响。

---

## 3. 提交顺序（最容易踩的坑）

面板逻辑的改动**必须提交到子模块**，改 Manager 仓库没用。而 Manager 只记录一个 commit 指针：

```bash
# 1) 先在子模块里提交并推送
cd services/panel/src
git checkout dev-custom
git add -A && git commit -m "fix(panel): ..."
git push fork dev-custom

# 2) 再回到外层，更新指针并提交
cd /opt/hiddify-manager
git add services/panel/src
git commit -m "bump panel submodule"
git push origin dev-custom
```

> **顺序不能反**：外层指针指向一个还没推送的子模块 commit 时，别人 clone 会报 `Failed to fetch`。

---

## 4. 日常命令

| 要做什么 | 命令 |
| --- | --- |
| 只重建 UI | `make ui` |
| 应用配置（改了模板或设置） | `make apply`，或面板里的 *Apply* 按钮 |
| 重启面板 | `systemctl restart hiddify-panel` |
| 拉代码并重新构建 | `git pull --recurse-submodules && make build` |
| 看生成的配置 | `hiddify-panel-cli dump-server-configs /tmp/out` |

> **重启面板会跑数据库迁移。** 在别人正在用的服务器上重启前要打招呼。

---

## 5. 测试

```bash
bash scripts/tests/smoke_package_manager.sh     # 包管理器
bash scripts/tests/smoke_publish_admin_ui.sh    # 管理端 UI 构建
bash scripts/tests/smoke_version_switch.sh      # 按 tag 切版本（离线 fixture）
```

`smoke_update.sh` 是**破坏性**的（会清空 `/opt/hiddify-manager`），只在能重建的机器上跑。
完整清单见 [开发 → 测试与验证](../dev/testing.md)。

---

## 6. 目录结构

```
/opt/hiddify-manager/                      外层仓库：安装脚本、systemd unit
├── services/panel/src/                    面板子模块
│   ├── hiddifypanel/admin_v2/             管理端 UI（Vue 3）
│   ├── hiddifypanel/panel/init_db.py      _vNNN 迁移链
│   └── tests/                             单元测试
├── data/                                  服务器状态（勿提交、勿手改）
├── generated/                             渲染出的 haproxy.cfg / xray.json 等
└── .venv313/                              面板 Python 环境
```

- 改管理端 UI 动 `admin_v2`，改用户界面动 `user_front`；旧 Flask-Admin 页面是遗留代码，不要改。
- **禁止编辑 `data/` 与 `generated/`**（运行时状态与生成物）。
- 生产环境不要开 `make debug-panel`。
