# Instructions for AI coding assistants

Read [DEVELOPMENT.md](DEVELOPMENT.md) first: the setup, where things are, how to test and commit.

- The repository is checked out at `/opt/hiddify-manager`; the panel is the submodule `services/panel/src`.
- Never edit `data/` or `generated/`: they are state and generated output.
- Admin UI changes go in `services/panel/src/hiddifypanel/admin_v2` only (the Flask-Admin pages are legacy).
- User UI changes go in `services/panel/src/hiddifypanel/user_front` (builds to `static/user-front/`, same model as admin_v2).
- Ask before restarting services: a panel restart migrates the server's database.

---

## Fork 约定（本地维护，非官方内容）

本节由 fork 维护者 `xgs87762GH` 添加，不属于上游 `Hiddify/Hiddify-Manager`。
上游同步时若本节产生冲突，处理口径固定为：**保留上游正文原样，把本节整体贴回文件末尾**，不要用上方的官方内容替换掉本节，也不要删节。

### 分支与 remote 模型

| 名称 | 类型 | 指向 | 约束 |
| --- | --- | --- | --- |
| `upstream` | remote | `git@github.com:Hiddify/Hiddify-Manager.git` | 只读，禁止 push |
| `origin` | remote | `git@github.com:xgs87762GH/Hiddify-Manager.git` | 个人 fork，可 push |
| `dev` | 官方镜像分支 | 跟踪 `upstream/dev` | 禁止任何自定义提交，只允许 fast-forward |
| `dev-custom` | 日常开发分支 | 从 `dev` 切出 | 所有自定义代码、配置、文档改动只写在这里 |

判断当前该不该提交：只要改动会进 `dev`，就停下来确认。镜像分支一旦混入自定义代码，后续同步官方就会分叉，这是本仓库最不希望出现的状态。

### 面板子模块（真正的 Python 代码在这里）

`services/panel/src` 是独立仓库（官方 `hiddify/hiddifypanel`），Manager 仓库只记录一个 commit 指针，不含它的代码。**面板逻辑的改动必须提交到子模块，改 Manager 仓库没用。**

| 名称 | 类型 | 指向 | 约束 |
| --- | --- | --- | --- |
| `upstream` | 子模块 remote | `git@github.com:hiddify/hiddifypanel.git` | 只读，官方 panel |
| `fork` | 子模块 remote | `git@github.com:xgs87762GH/hiddifypanel.git` | 个人 fork，panel 改动推这里 |
| `dev` | 子模块镜像分支 | 跟踪 `upstream/dev` | 禁止提交 |
| `dev-custom` | 子模块开发分支 | 跟踪 `fork/dev-custom` | panel 代码只写这里 |

分支模型与外层一致：子模块 `dev` 也是官方镜像。外层 `dev` 记录的子模块 SHA 来自官方，外层 `dev-custom` 记录的 SHA 来自 fork。

`.gitmodules` 在 `dev-custom` 上指向 fork 的 HTTPS 地址 `https://github.com/xgs87762GH/hiddifypanel.git`：服务器匿名克隆子模块不需要部署 ssh key（fork 是公开的），推送仍在子模块内走 ssh，互不影响。官方值 `https://github.com/hiddify/Hiddify-Panel.git` 不适用于本 fork；`dev` 分支上的 `.gitmodules` 保持官方原样，同步冲突时按官方为准。

### 硬性禁令

1. 禁止在 `dev` 上 commit、rebase 或 force push。
2. 禁止 push 到 `upstream`；报权限错误时不要改 remote URL 或换 key 绕过。
3. 禁止以"清理无用代码 / 简化结构"为由删除文件或目录；确需删除先在 `dev-custom` 说明理由并等待维护者确认。
4. 禁止用 `--ours` / `--theirs` 整侧丢弃合并冲突，必须逐处判断。
5. 禁止编辑 `data/` 与 `generated/`（运行时状态与生成物，官方约定）。
6. 禁止重启服务或执行迁移脚本；面板重启会迁移服务器数据库。
7. 禁止把口令、私钥、token 写进仓库文件（`docker.env` 等配置只放占位值）。
8. 禁止在子模块的游离 HEAD 上提交。`git submodule update` 之后子模块默认是 detached，必须 `git checkout dev-custom` 再改代码。
9. 禁止让 Manager 的指针指向子模块里尚未推送的 commit：先推 `fork`，再在外层 commit 指针，顺序反了别人 clone 就会报 `Failed to fetch`。

### 同步官方新功能

外层 Manager：

```bash
git checkout dev
git pull --ff-only upstream dev     # 镜像只接受 fast-forward，报错即说明 dev 被污染
git checkout dev-custom
git merge dev                       # 冲突逐处处理
git push origin dev dev-custom      # 同步推回 fork，保持远端镜像一致
```

子模块 panel（改了 panel 代码时才需要）：

```bash
cd services/panel/src
git checkout dev && git pull --ff-only upstream dev
git checkout dev-custom && git merge dev        # 官方新代码合进自定义分支
git push fork dev-custom                        # 先推子模块
cd ../.. && git add services/panel/src && git commit   # 后记指针
```

### 维护文档索引（`docs/` 下由 fork 维护者添加）

| 文档 | 内容 |
| --- | --- |
| [README.md](README.md) | 中文主入口：fork 说明、文档索引、快速开始、常用命令 |
| [docs/deployment.md](docs/deployment.md) | 首次部署：三种方式、系统要求、端口、装完怎么验证、备份恢复、故障排查 |
| [docs/server-update.md](docs/server-update.md) | 服务器升级：日常升级、首次转换、构建要求、回滚 |
| [docs/build-requirements.md](docs/build-requirements.md) | 构建与安装依赖：GitHub 构建物清单、非 GitHub 源、可覆盖变量、限流与排查 |
| [docs/release.md](docs/release.md) | 打包发布：版本号规则、发布前检查、打 tag、Actions 产物、校验、回滚 |
| [docs/release-notes/v14.1.0b3.md](docs/release-notes/v14.1.0b3.md) | 本版本发布说明：三端改了什么、与官方逐项对比、已知限制 |
| [docs/testing.md](docs/testing.md) | 测试与验证：四层测试怎么跑、端到端冒烟怎么复现、踩过的坑 |

这些文档互相引用。改部署 / 升级 / 依赖 / 发布 / 测试相关的行为时，同步更新对应文档。
官方英文 README 归档在 [docs/README_upstream_en.md](docs/README_upstream_en.md)，不再作为入口。

### 其它

- 许可证为 AGPL-3.0；对外提供修改后的网络服务时，分发义务由维护者自行评估，AI 不要主动"合规化"改写头部声明。
- 本节描述的是仓库约定，不是代码行为；改动分支模型或 remote 前需维护者明确同意。
