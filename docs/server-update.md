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

管理端 UI 的构建产物不在 git 里，必须在服务器上构建：

- Node.js >= 18（缺失时脚本自动安装）
- 约 1.2 GB 空闲内存，脚本会自动挂临时 swap；仍失败（退出码 137）就手动加 2G swap 再跑
- 源文件比 `hiddifypanel/static/admin-v2/index.html` 新时才会重建，所以改了 `src`、`translations.i18n`、
  `package-lock.json`、`vite.config.ts` 的提交一定会触发重建

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
| `Cannot fast-forward` | 服务器上有未提交的改动：`git status` 查看后 `git stash` 再重跑 |
| 子模块报 `Failed to fetch` / `not our ref` | 面板 fork 拉不到，或外层记的指针还没推到 fork。按第 1 节顺序重推 |
| 构建退出码 137 | 内存不足，加 swap 或临时扩内存后重跑 `make build` |
| `update.sh` 提示 syntax error | 更新过程中脚本自身被替换，重跑一次即可（脚本已用私有副本执行来规避） |

## 8. 注意

- 升级会重启 `hiddify-panel`，服务会中断数分钟，在线连接会断开。
- 面板启动时会跑数据库迁移。判断某次升级是否涉及库结构，看
  `git -C services/panel/src diff --name-only <旧> <新> -- hiddifypanel/migrations` 是否为空。
