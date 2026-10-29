# 开发

> 返回 [文档总目录](../README.md)。部署方式见 [deploy/](../deploy/README.md)。

---

## 本目录

| 文档 | 内容 |
| --- | --- |
| [build-requirements.md](build-requirements.md) | 构建与安装依赖：GitHub 构建物清单（`packages.lock`）、非 GitHub 源、可覆盖变量、限流与排查 |
| [testing.md](testing.md) | 测试与验证：五层测试怎么跑、端到端冒烟怎么复现、踩过的坑 |

---

## 先读这两个

| 文档 | 讲什么 |
| --- | --- |
| [DEVELOPMENT.md](../../DEVELOPMENT.md) | 环境怎么起、代码在哪、怎么提交 |
| [AGENTS.md](../../AGENTS.md) | 分支与 remote 模型、面板子模块、硬性禁令 |

要点：

- 开发机与服务器是**同一份代码树**（`/opt/hiddify-manager`），没有"本地改完拷贝过去"。
- 面板逻辑在子模块 `services/panel/src`，改 Manager 仓库没用。
- 提交顺序：先在子模块提交并推 `fork`，再回外层更新指针。
- 子模块 `git submodule update` 后是 detached HEAD，改代码前先 `git -C services/panel/src checkout dev-custom`。

---

## 常用命令

| 要做什么 | 命令 |
| --- | --- |
| 拉代码并重新构建 | `git pull --recurse-submodules && make build` |
| 只重建 UI | `make ui` |
| 应用配置 | `make apply`，或面板 *Apply* 按钮 |
| 看生成的配置 | `hiddify-panel-cli dump-server-configs /tmp/out` |
| 重启面板 | `systemctl restart hiddify-panel` |

> 重启面板会跑数据库迁移，别在别人正在用的机器上随手重启。

---

## 冒烟

```bash
bash scripts/tests/smoke_package_manager.sh     # 包管理器
bash scripts/tests/smoke_publish_admin_ui.sh    # 管理端 UI 构建
bash scripts/tests/smoke_version_switch.sh      # 按 tag 切版本（离线 fixture，安全）
bash scripts/tests/smoke_update.sh 1            # 破坏性：会清空 /opt/hiddify-manager
```

`smoke_update.sh` 只在能重建的机器上跑（跑完需要 purge → install → 恢复备份）。
