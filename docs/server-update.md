# 服务器升级流程（fork 维护）

本文档由 fork 维护者添加，描述如何把服务器 `/opt/hiddify-manager` 升级到 `dev-custom` 的最新代码。
不适用于官方 release 安装的常规升级（那种直接跑面板里的"更新"即可）。

## 0. 前提检查

```bash
sudo -i
cd /opt/hiddify-manager

git status -sb                  # 有输出 = 已是 git checkout
git branch --show-current       # 应为 dev-custom
free -h                         # 管理端 UI 构建需要 ~1.2G 空闲内存或 swap
```

三种状态对应三条路径：

| 服务器状态 | 用什么 |
| --- | --- |
| `git status` 正常工作，分支 `dev-custom` | 第二节，`scripts/update.sh` |
| `git status` 正常工作，分支是别的名字 | 先 `git checkout dev-custom`，再走第二节 |
| 没有 `.git`（官方 release 安装） | 第三节，`switch_to_fork.sh` 一次性转换 |

## 1. 升级前先推代码

本地改完必须先推到 fork，服务器只负责拉。顺序不能反（`AGENTS.md` 禁令 9）：

```bash
# 改了面板代码：先推子模块
cd services/panel/src && git push origin dev-custom
# 再在外层记指针
cd ../.. && git add services/panel/src && git commit -m "chore(submodules): bump the panel to <sha>"
git push origin dev-custom
```

## 2. 日常升级（服务器已是 checkout）

```bash
cd /opt/hiddify-manager
bash scripts/update.sh
```

这个脚本检测到 git checkout 时走 `update_from_git`，依次执行：

1. `./services/panel/backup.sh` —— 备份面板数据库与配置
2. `git fetch --prune origin dev-custom`
3. `git merge --ff-only origin/dev-custom` —— 只快进，绝不覆盖服务器上的本地改动
4. `git submodule update --init --recursive` —— 把面板拉到 `.gitmodules` 指向的 fork
5. `make build` —— 重建管理端 UI，然后 `scripts/install.sh --no-gui` 重启面板

可用环境变量覆盖：`HIDDIFY_GIT_REMOTE`（默认 `origin`）、`HIDDIFY_GIT_BRANCH`（默认当前分支）。

## 3. 首次转换（服务器还是官方 release 安装）

```bash
bash <(curl -sSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/refs/heads/dev-custom/scripts/switch_to_fork.sh)
```

等价写法（`<( )` 是 bash 特性，`sh`/`dash` 下不成立）：

```bash
curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/refs/heads/dev-custom/scripts/switch_to_fork.sh -o /tmp/sw.sh
bash /tmp/sw.sh
```

脚本是幂等的：已经是 checkout 时，它只做 fetch + 快进 + 子模块 + `make build`。
注意这条路径**不会**跑 `services/panel/backup.sh`（备份只在首次转换做全量快照时发生），
日常升级请用第二节的 `scripts/update.sh`。

## 4. 构建要求

管理端 UI 的构建产物不在 git 里（`.gitignore` 忽略了 `hiddifypanel/static/admin-v2/`），必须在服务器上构建：

- Node.js >= 18（缺失时脚本自动安装）
- 约 1.2 GB 空闲内存，脚本会自动挂临时 swap；仍失败（退出码 137）就手动加 2G swap 再跑
- 源文件比 `hiddifypanel/static/admin-v2/index.html` 新时才会重建，所以改了 `src`、`translations.i18n`、
  `package-lock.json`、`vite.config.ts` 的提交一定会触发重建

实测数据（node v22 / npm 9，16 核）：

| 阶段 | 耗时 | 峰值内存 |
| --- | --- | --- |
| `npm ci`（200 包） | 3.6 s | 495 MB |
| `npm run build` | 7.9 s | 980 MB |
| 产物 | 151 个文件 / 11 MB，入口 `assets/index-*.js` | — |

CPU 不是瓶颈，1 核也能在分钟级完成；内存才是。1 GB 内存的机器必须依赖脚本自动挂的 swap。

### 译文件在构建期编译，语法错误会让构建直接失败

`hiddifypanel/translations.i18n/*.json` 是通过 `import.meta.glob` 在**构建期**打进包的
（`admin_v2/src/core/i18n/index.ts`），不是运行时读文件。任一译文件 JSON 不合法，`npm run build` 会以退出码 1 结束：

```
error during build:
[hiddify-admin-v2-translations] Expected ',' or '}' after property value in JSON at position ...
```

因为 `update.sh` 是**先 `git merge --ff-only` 再 `make build`**，构建失败时 git 已经指向新版本、`install.sh` 却没执行，
结果是"代码是新的、面板还跑着旧的"这种半升级状态。遇到构建失败不要反复重跑，先修代码或回滚（第 6 节），
再用 `git log --oneline -1` 与 `systemctl status hiddify-panel` 确认两边版本一致。

### 构建会改脏 `components.d.ts`

构建后 `services/panel/src/hiddifypanel/admin_v2/components.d.ts` 会被 `unplugin-vue-components` 重写，
而它是被 git 跟踪的，于是工作区出现 `M`。这会让**下一次**升级的 `--ff-only` 报 `Cannot fast-forward`。
升级后看到这个 `M` 直接丢弃即可：

```bash
cd /opt/hiddify-manager/services/panel/src
git checkout -- hiddifypanel/admin_v2/components.d.ts
```

## 5. 升级后验证

```bash
systemctl status hiddify-panel --no-pager
journalctl -u hiddify-panel -n 50 --no-pager
cd /opt/hiddify-manager && git log --oneline -1
git -C services/panel/src log --oneline -1
```

浏览器打开管理面板，确认：

- 界面文字正常显示（译文件语法错误会让整包翻译加载失败）
- 列表页的空状态 / 搜索无结果提示正常
- 升级后订阅链接仍可用

## 6. 回滚

代码回滚（不动数据）：

```bash
cd /opt/hiddify-manager
git log --oneline -5            # 找到上一个提交
git reset --hard <上一个提交>
git submodule update --init --recursive
make build
```

数据回滚用面板"备份"页里 `backup.sh` 生成的那份，或首次转换时的 `/opt/hiddify-manager.bak.<时间戳>` 全量快照。

## 7. 常见失败

| 现象 | 原因与处理 |
| --- | --- |
| `Cannot fast-forward` | 先看 `git status`：若只有 `M components.d.ts`，是上次构建造成的，`git checkout --` 丢弃即可（见第 4 节）；若有其他改动，确认后再 `git stash` 重跑 |
| 子模块报 `Failed to fetch` / `not our ref` | 面板 fork 拉不到，或外层记的指针还没推到 fork。按第 1 节顺序重推 |
| 构建退出码 137 | 内存不足，加 swap 或临时扩内存后重跑 `make build` |
| 构建报 `[hiddify-admin-v2-translations] Expected ...` | 译文件 JSON 语法错误，构建期就会失败。修文件或回滚（第 6 节），别反复重跑 |
| `update.sh` 提示 syntax error | 更新过程中脚本自身被替换，重跑一次即可（脚本已用私有副本执行来规避） |

## 8. 注意

- 升级会重启 `hiddify-panel`，服务会中断数分钟，在线连接会断开。
- 面板启动时会跑数据库迁移。判断某次升级是否涉及库结构，看
  `git -C services/panel/src diff --name-only <旧> <新> -- hiddifypanel/panel/init_db.py` 是否为空。

  面板**没有** Alembic 迁移目录（`hiddifypanel/migrations` 不存在），库结构由 `init_db.py` 里的
  `_vNNN` 函数链维护，启动时按版本号顺序执行。所以只改 `models/` 而不改 `init_db.py` 的提交
  通常不会动库结构，但列/枚举的同步是每次启动都做的通用逻辑，不能只看 diff 判断。
- 面板硬依赖 MySQL：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...` 读 enum 列定义，
  SQLite 等其它后端不支持。本地想跑起来验证必须准备 MariaDB/MySQL，不能用 SQLite 图省事。
- 面板硬依赖 Redis：缓存、session、`evalsha` 都用它，`fakeredis` 之类替身跑不通，必须起真 Redis。
- 全新库初始化会从 `_v1` 一路跑到 `_v184`，实测在 MariaDB 11.8 上建出 21 张表 + 存储过程
  `add_usage_json`，耗时约 0.5 秒。`_v140` 里那条 `DROP PROCEDURE ...; CREATE PROCEDURE ...`
  是**两条语句拼在一次 `db_execute`** 里，SQLAlchemy `text()` 默认不允许多语句。若某次升级在这步
  报 `You have an error in your SQL syntax ... near 'CREATE PROCEDURE'`，说明环境里驱动开了多语句
  才过得去；这不是升级脚本的问题，先确认面板版本与数据库版本是否匹配再重试。
- 面板完整启动后实测：445 条路由、31 个蓝图、调度器 9 个任务；`/<proxy_path>/` 正常返回，
  未登录访问 `/<proxy_path>/admin/` 返回 302 跳登录，属正常。
