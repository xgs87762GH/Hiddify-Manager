# 升级

> fork 维护文档，讲怎么把服务器 `/opt/hiddify-manager` 升到 `dev-custom` 最新代码。
> 官方 release 安装的常规升级不适用（那种直接在面板里点"更新"即可）。
> 首次部署看 [部署](deployment.md)，验证方法看 [测试与验证](testing.md)。

---

## 1. 先看自己是哪种状态

```bash
sudo -i
cd /opt/hiddify-manager

git status -sb                  # 有输出 = 已是 git checkout
git branch --show-current       # 应为 dev-custom
free -h                         # 构建 UI 需要 ~1.2G 空闲内存或 swap
```

| 服务器状态 | 走哪节 / 命令 |
| --- | --- |
| `git status` 正常，分支 `dev-custom` | 第 3 / 4 节：`bash scripts/update.sh` |
| `git status` 正常，分支是别的名字 | 先 `git checkout dev-custom`，再 `bash scripts/update.sh` |
| 没有 `.git`（官方 release 安装） | 第 4 节：`switch_to_fork.sh`（只跑一次） |

---

## 2. 升级前先推代码

本地改完必须先推到 fork，服务器只负责拉。**顺序不能反**（`AGENTS.md` 禁令 9）：

```bash
# 改了面板代码：先推子模块
cd services/panel/src && git push origin dev-custom
# 再在外层记指针
cd ../.. && git add services/panel/src && git commit -m "chore(submodules): bump the panel to <sha>"
git push origin dev-custom
```

---

## 3. 日常升级（已是 checkout）

不用先 cd，一条命令：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh) update
```

在服务器上也可以直接跑本机副本（不联网下载引导脚本）：

```bash
bash /opt/hiddify-manager/scripts/onekey.sh update
```

等价的传统写法：

```bash
cd /opt/hiddify-manager
bash scripts/update.sh
```

脚本检测到 git checkout 时走 `update_from_git`，依次：

1. `git fetch --prune origin dev-custom`
2. 若远端 `scripts/update.sh` 比正在跑的这份新，**交接给新版本**重跑（脚本会自我修复，不必手动操作服务器）
3. `services/panel/backup.sh` —— 备份面板数据库与配置
4. `git merge --ff-only origin/dev-custom` —— 只快进，绝不覆盖服务器上的本地改动
5. `git submodule update --init --recursive` —— 把面板拉到 `.gitmodules` 指向的 fork
6. `make build` —— 重建管理端 UI，然后 `scripts/install.sh --no-gui` 重启面板

> 第 2 步是这一版加的：`update.sh` 从 `/tmp` 的副本里运行，所以它自己的修复要下一次才生效。
> 现在会先把远端那份取出来替换自己，**面板点一下「更新」就能修好脚本本身**。

可用环境变量覆盖：`HIDDIFY_GIT_REMOTE`（默认 `origin`）、`HIDDIFY_GIT_BRANCH`（默认当前分支）。

### 改完更新脚本先自测

```bash
bash scripts/tests/smoke_update.sh      # 默认跑 10 轮
bash scripts/tests/smoke_update.sh 3    # 或指定轮数
```

纯离线（仓库/clone 都建在临时目录），每轮重放四个场景：

| 场景 | 覆盖的情况 |
| --- | --- |
| A | 全新更新，没有任何 `safe.directory` 例外，且面板子模块属于别的用户 |
| B | 外层已经 up to date，但面板落后 → 必须仍然补同步 |
| C | 只有面板指针变化的一次提交 |
| D | 服务器上的 `update.sh` 还是修好之前的版本：第一次运行只能更新代码，**第二次跑完** |

每轮都会断言「HEAD 在 `origin/dev-custom` 上」和「面板 checkout 等于指针指向的提交」。改 `update.sh` / `switch_to_fork.sh` / `common/utils.sh` 之后必须全绿。

---

## 4. 官方安装 ↔ fork：两条命令

| 你现在的状态 | 用哪条 |
| --- | --- |
| 还是官方 release（没有 `.git`）——**首次**转 fork | `switch_to_fork.sh`（只跑一次） |
| **已经是** fork / `dev-custom` checkout——日常升级 | `scripts/update.sh`（以后都用它） |

### 首次转换（官方 → fork）

```bash
bash <(curl -sSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/refs/heads/dev-custom/scripts/switch_to_fork.sh)
```

等价写法（`<( )` 是 bash 特性，`sh` / `dash` 下不成立）：

```bash
curl -fsSL https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/refs/heads/dev-custom/scripts/switch_to_fork.sh -o /tmp/sw.sh
bash /tmp/sw.sh
```

### 不是首次（已转过 fork，日常升级）

```bash
cd /opt/hiddify-manager
bash scripts/update.sh
```

面板里点「更新」也可以，git checkout 时同样会走 `update.sh` 这条链路。细节见第 3 节。

### 为什么日常别再用 `switch_to_fork.sh`

脚本幂等：已有 `.git` 时会跳过转换，只做 fetch + 快进 + 子模块 + `make build`——**能跑，但不该日常用**。

| | `switch_to_fork.sh`（已是 checkout 时） | `update.sh` |
| --- | --- | --- |
| fetch + `merge --ff-only` | ✓ | ✓ |
| 子模块更新 | ✓ | ✓ |
| `make build` | ✓ | ✓ |
| **跑 `backup.sh` 备份** | **✗** | **✓** |
| 锁保护（防并发） | ✗ | ✓ |
| 远程 / 分支可覆盖 | ✗（固定 `origin/dev-custom`） | ✓（`HIDDIFY_GIT_REMOTE` / `HIDDIFY_GIT_BRANCH`） |

> 关键差别是**备份**：`switch_to_fork.sh` 不跑 `services/panel/backup.sh`，`update.sh` 会跑。
> 面板启动会执行不可回滚的 `_vNNN` 迁移，没新鲜备份就升级，出事只能靠旧备份。

---

## 5. 构建要求（失败多半出在这）

完整的外部依赖清单（GitHub 构建物、Node 镜像、可覆盖变量、限流说明）见
[构建与安装依赖](build-requirements.md)；发新版本见 [打包发布](release.md)。

管理端 UI 产物不在 git 里（`.gitignore` 忽略 `hiddifypanel/static/admin-v2/`），**必须在服务器上构建**：

- Node.js ≥ 18（缺失时脚本自动安装）
- 约 1.2 GB 空闲内存，脚本会自动挂临时 swap；仍失败（退出码 137）就手动加 2G swap 再跑
- 源文件比 `hiddifypanel/static/admin-v2/index.html` 新时才会重建

实测（node v22 / npm 9，16 核）：

| 阶段 | 耗时 | 峰值内存 |
| --- | --- | --- |
| `npm ci`（200 包） | 3.6 s | 495 MB |
| `npm run build` | 7.9 s | 980 MB |
| 产物 | 151 个文件 / 11 MB | — |

### 坑 1：译文件在构建期编译，语法错误会让构建直接失败

`hiddifypanel/translations.i18n/*.json` 通过 `import.meta.glob` 在**构建期**打进包，不是运行时读文件。
任一译文件 JSON 不合法，`npm run build` 直接退出码 1：

```
error during build:
[hiddify-admin-v2-translations] Expected ',' or '}' after property value in JSON at position ...
```

> **这是最需要盯的一条**：`update.sh` 是**先 merge 再 build**，
> 构建失败时 git 已指向新版、`install.sh` 却没执行 → **代码是新的、面板还跑着旧的**半升级状态。
> 遇到构建失败**不要反复重跑**，先修代码或回滚（第 7 节）。

### 坑 2：构建会改脏 `components.d.ts`

构建后 `hiddifypanel/admin_v2/components.d.ts` 会被 `unplugin-vue-components` 重写，
而它是被 git 跟踪的 → 工作区出现 `M` → **下一次**升级的 `--ff-only` 报 `Cannot fast-forward`。

升级后看到这个 `M` 直接丢弃：

```bash
cd /opt/hiddify-manager/services/panel/src
git checkout -- hiddifypanel/admin_v2/components.d.ts
```

### 坑 3：目录让位

release 安装的 `services/panel/src` 是普通目录，git 需要那里是子模块，
脚本会把它挪成 `services/panel/src.release-backup`。确认一切正常后可删：

```bash
rm -rf /opt/hiddify-manager/services/panel/src.release-backup
```

---

## 6. 升级后验证

```bash
systemctl status hiddify-panel --no-pager
journalctl -u hiddify-panel -n 50 --no-pager
cd /opt/hiddify-manager && git log --oneline -1
git -C services/panel/src log --oneline -1
```

> **必须确认代码版本和面板实际在跑的版本一致**，这是发现"半升级"的唯一方法。

浏览器打开管理面板，确认：

- 界面文字正常显示（译文件语法错误会让整包翻译加载失败）
- 列表页的空状态 / 搜索无结果提示正常
- 升级后订阅链接仍可用

---

## 7. 回滚

代码回滚（不动数据）：

```bash
cd /opt/hiddify-manager
git log --oneline -5            # 找上一个提交
git reset --hard <上一个提交>
git submodule update --init --recursive
make build
```

数据回滚用面板"备份"页里 `backup.sh` 生成的那份，或首次转换时的
`/opt/hiddify-manager.bak.<时间戳>` 全量快照。

---

## 8. 常见失败

| 现象 | 原因与处理 |
| --- | --- |
| `Cannot fast-forward` | 先看 `git status`：只有 `M components.d.ts` 就是上次构建造成的，丢弃即可（坑 2）；有其他改动先确认再 `git stash` 重跑 |
| 子模块 `Failed to fetch` / `not our ref` | 面板 fork 拉不到，或外层指针还没推到 fork。按第 2 节顺序重推 |
| 构建退出码 137 | 内存不足，加 swap 或临时扩内存后重跑 `make build` |
| 构建报 `[hiddify-admin-v2-translations] Expected ...` | 译文件 JSON 语法错误。修文件或回滚，**别反复重跑**（坑 1） |
| `update.sh` 提示 syntax error | 更新过程中脚本自身被替换，重跑一次即可 |
| `fatal: detected dubious ownership in repository at '.../services/panel/src'` | 子模块是独立仓库，root 跑 git 需要 `safe.directory` 例外。现版本会自动把主目录与各级子模块加进去并重试一次。**若线上跑的还是修好之前的脚本，第一次点击只会把代码（含脚本本身）更新过来，并可能在这一步报错——直接再点一次「更新」就会跑完**，不需要手动改服务器。手动兜底：`git config --global --add safe.directory <目录>`
| `git submodule update failed` / `Unable to find current revision in submodule path` | 同上（ownership）；除此之外检查面板 fork 是否真的推了该提交（第 2 节） |

---

## 9. 注意

- 升级会重启 `hiddify-panel`，**服务中断数分钟，在线连接会断开**。
- 面板启动时跑数据库迁移。判断某次升级是否涉及库结构：

  ```bash
  git -C services/panel/src diff --name-only <旧> <新> -- hiddifypanel/panel/init_db.py
  ```

  面板**没有** Alembic 迁移目录（`hiddifypanel/migrations` 不存在），库结构由 `init_db.py`
  里的 `_vNNN` 函数链维护，启动时按版本号顺序执行。列/枚举的同步是每次启动都做的通用逻辑，
  不能只看 diff 判断。
- **面板硬依赖 MySQL**：`init_db.py` 用 `SHOW COLUMNS FROM ... LIKE ...` 读 enum 列，
  SQLite 不支持。本地验证必须准备 MariaDB/MySQL。
- **面板硬依赖 Redis**：缓存、session、`evalsha` 都用它，`fakeredis` 之类替身跑不通。
- 全新库初始化从 `_v1` 跑到 `_v184`，实测 MariaDB 11.8 上建出 21 张表 + 存储过程
  `add_usage_json`，耗时约 0.5 秒。
- `_v140` 里那条 `DROP PROCEDURE ...; CREATE PROCEDURE ...` 是**两条语句拼在一次 `db_execute`**，
  SQLAlchemy `text()` 默认不允许多语句。若这步报
  `You have an error in your SQL syntax ... near 'CREATE PROCEDURE'`，先确认面板与数据库版本是否匹配再重试。
- 面板完整启动后实测：**445 条路由、31 个蓝图、调度器 9 个任务**；
  `/<proxy_path>/` 正常返回，未登录访问 `/<proxy_path>/admin/` 返回 302 跳登录属正常。
