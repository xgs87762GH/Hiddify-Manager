# 打包与发布

> 讲怎么把当前代码打成**一个可被服务器识别和升级的版本**：改版本号 → 打 tag → GitHub 自动出包 → 服务器升级。
> 服务器侧怎么升级看 [升级](server-update.md)，依赖哪些外部资源看 [构建与安装依赖](build-requirements.md)。

---

## 1. 版本号规则

三个地方必须一致：`VERSION`（Manager）、面板子模块的 `VERSION.py`、git tag。

| 类型 | tag 形式 | 例 | GitHub 上标记为 |
| --- | --- | --- | --- |
| 正式版 | `vX.Y.Z` | `v14.1.0` | Release |
| 预发布 | `vX.Y.ZbN` | `v14.1.0b3` | Pre-release |

- 面板的模式（`package_mode`）决定查哪类 tag：`release` 查正式版，`beta` 查预发布。
- 因此**发布预发布版必须带 `b`**，否则会被当成正式版被所有 `release` 服务器拉到。
- tag 只能是 `^v[0-9]+\.[0-9]+\.[0-9]+(b[0-9]+)?$`，其它形式 Actions 不认。

---

## 2. 发布前检查

```bash
# 1. 两个仓库都在 dev-custom 且干净
cd /opt/hiddify-manager && git status -sb && git -C services/panel/src status -sb

# 2. 面板改动已推到 fork（顺序不能反，否则别人 clone 报 Failed to fetch）
cd services/panel/src && git push origin dev-custom && cd ../..

# 3. 脚本语法
bash -n scripts/update.sh scripts/common/*.sh

# 4. 版本号
cat VERSION && grep __version__ services/panel/src/hiddifypanel/VERSION.py

# 5. UI 能构建（内存 ≥ 1.2 GB）
make ui
```

清单：

- [ ] `dev-custom` 上无未提交改动，子模块指针已推送
- [ ] `VERSION` 与面板 `VERSION.py` 一致
- [ ] `bash -n` 通过、`make ui` 通过
- [ ] 更新相关脚本仍只指向本 fork（见 [构建与安装依赖 §3](build-requirements.md)）
- [ ] 文档已同步（行为改了就要改文档）

---

## 3. 打 tag 并推送

```bash
# --- 面板子模块先打 ---
cd services/panel/src
echo "14.1.0b3" > VERSION                     # 若无此文件，以 VERSION.py 为准
sed -i "s/__version__ = '.*'/__version__ = '14.1.0b3'/" hiddifypanel/VERSION.py
git add -A && git commit -m "release: 14.1.0b3"
git tag v14.1.0b3
git push origin dev-custom --tags

# --- Manager 再打 ---
cd ../..
echo "14.1.0b3" > VERSION
git add VERSION services/panel/src
git commit -m "release: 14.1.0b3"
git tag v14.1.0b3
git push origin dev-custom --tags
```

> 不要用 `make release`：它依赖 `VIRTUAL_ENV` 和 `gitchangelog`，且会把 tag 同步到 `main`/`beta` 分支，
> 与本 fork 的分支模型（`dev` 只做官方镜像）冲突。

---

## 4. GitHub Actions 出包

推 `v*` tag 后，[.github/workflows/release.yml](../.github/workflows/release.yml) 会自动：

1. `checkout`（含子模块，保证 zip 里有面板源码）
2. 打包 `hiddify-manager.zip`（排除 `.git*`，同时复制一份 `hiddify-config.zip` / `hiddify-server.zip` 兼容旧脚本）
3. 用 `.github/release_message.sh` 生成 changelog
4. 创建 Release（tag 含 `b` → Pre-release），上传 zip

**前提**：fork 仓库必须在 `Settings → Actions → General` 里允许 Actions 运行；否则 tag 推上去了也不会出包。

### 发布说明（release 正文）

仓库里的 `.github/release_notes/<tag>.md` 会**覆盖**自动生成的 changelog。新版本请从
[`.github/release_notes/TEMPLATE.md`](../.github/release_notes/TEMPLATE.md) 复制改写。

**目录别弄花**：GitHub Releases 右侧「On this page」会把正文里**单独成行的 `# …`** 当成一级标题
（包括写在 \`\`\`bash 代码块里的 shell 注释）。说明写在代码块外面；块内只留可执行命令。

没有 curated 文件时，正文仍是 `.github/release_message.sh` 生成的内容。
客户端（`hiddify-app`）另有一个轻量工作流 `release-notes.yml`：即使官方那套需要签名密钥的
构建流程失败，也会先建出带说明的 Release 条目。

检查结果：仓库 `Releases` 页能看到对应 tag 和 `hiddify-manager.zip`。

---

## 5. 校验产物

```bash
curl -L -o /tmp/hm.zip \
  https://github.com/xgs87762GH/Hiddify-Manager/releases/download/v14.1.0b3/hiddify-manager.zip
sha256sum /tmp/hm.zip
unzip -l /tmp/hm.zip | head -20
unzip -p /tmp/hm.zip VERSION          # 应输出 14.1.0b3
unzip -l /tmp/hm.zip | grep services/panel/src/hiddifypanel/VERSION.py   # 应有内容
```

记录 sha256，需要时写进发布说明。

---

## 6. 服务器怎么吃到这个版本

| 服务器状态 | 行为 |
| --- | --- |
| 任意状态，一条命令 | `onekey.sh update`（已装）/ `onekey.sh version v14.1.0b3`（指定版本） |
| git checkout（`dev-custom`） | 面板点"更新"或 `bash scripts/update.sh` → `git fetch` + `merge --ff-only` fork，随后 `make build` |
| 非 git（官方 zip 安装） | 面板点"更新" → 按 `package_mode` 查 fork 的 release → 下载本 fork 的 `hiddify-manager.zip` 覆盖，面板源码再从 fork 克隆 |
| 指定版本安装 | `bash scripts/common/download.sh v14.1.0b3`（tag 必须存在于本 fork） |

非 git 安装想长期稳，建议一次性转成 checkout：见 [升级 §4](server-update.md)。

---

## 7. 回滚

```bash
# 代码回滚到本 fork 的某个 tag（不动数据）
cd /opt/hiddify-manager
git fetch --tags origin
git checkout v14.1.0b2
git submodule update --init --recursive
make build

# 数据回滚
# 用面板"备份"页的备份，或 /opt/hiddify-manager.bak.<时间戳> 全量快照
```

**只能回滚到本 fork 的 tag**：`download.sh`、`custom` 安装菜单、版本查询都已指向 fork，
不会出现官方版本可选。数据库迁移不可逆，回滚代码前先确认 `init_db.py` 的 `_vNNN` 变化。
