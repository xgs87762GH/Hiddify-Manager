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

### 硬性禁令

1. 禁止在 `dev` 上 commit、rebase 或 force push。
2. 禁止 push 到 `upstream`；报权限错误时不要改 remote URL 或换 key 绕过。
3. 禁止以"清理无用代码 / 简化结构"为由删除文件或目录；确需删除先在 `dev-custom` 说明理由并等待维护者确认。
4. 禁止用 `--ours` / `--theirs` 整侧丢弃合并冲突，必须逐处判断。
5. 禁止编辑 `data/` 与 `generated/`（运行时状态与生成物，官方约定）。
6. 禁止重启服务或执行迁移脚本；面板重启会迁移服务器数据库。
7. 禁止把口令、私钥、token 写进仓库文件（`docker.env` 等配置只放占位值）。

### 同步官方新功能

```bash
git checkout dev
git pull --ff-only upstream dev     # 镜像只接受 fast-forward，报错即说明 dev 被污染
git checkout dev-custom
git merge dev                       # 冲突逐处处理
git push origin dev dev-custom      # 同步推回 fork，保持远端镜像一致
```

### 其它

- 许可证为 AGPL-3.0；对外提供修改后的网络服务时，分发义务由维护者自行评估，AI 不要主动"合规化"改写头部声明。
- 本节描述的是仓库约定，不是代码行为；改动分支模型或 remote 前需维护者明确同意。
