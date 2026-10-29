# 发版

> 返回 [文档总目录](../README.md)。

---

## 本目录

| 文档 | 内容 |
| --- | --- |
| [release.md](release.md) | **打包发布全流程**：版本号规则、发布前检查、打 tag、Actions 产物、校验、回滚 |

`make dev` / `make release` 生成的上游 changelog 会写到本目录的 `HISTORY.md`（不进导航）。

---

## 顺序（先面板，后 Manager）

1. **面板**：在 `services/panel/src` 里改版本号、提交、推 `fork/dev-custom`、打 tag `vX.Y.Z`
2. **Manager**：改 `VERSION`、更新子模块指针、提交
   ```bash
   git add VERSION services/panel/src
   git commit -m "release: vX.Y.Z"
   git tag vX.Y.Z
   git push origin dev-custom && git push --tags
   ```
3. **验收**：GitHub Actions 用 `v*` tag 触发，产物含 `hiddify-manager.zip`（另有
   `hiddify-config.zip`、`hiddify-server.zip` 兼容旧脚本）

版本号三处必须一致：Manager `VERSION`、面板 `hiddifypanel/VERSION.py`、tag。

---

## 校验产物

```bash
curl -sL -o hm.zip https://github.com/xgs87762GH/Hiddify-Manager/releases/download/vX.Y.Z/hiddify-manager.zip
sha256sum hm.zip
python3 -c "import zipfile;z=zipfile.ZipFile('hm.zip');print(z.read('VERSION').decode().strip())"
```

---

## 回滚

- 代码：`bash <(curl -fsSL "$OK") version <上一个 tag> -y`
- 已发布的 tag 若要重打：先删本地与远端 tag，再在含全部修复的 commit 上重打并 `git push --tags`
- **数据库迁移不可逆**：发版前的备份必须保留

---

## 相关

- [dev/build-requirements.md](../dev/build-requirements.md)：release 依赖哪些外部资源
- [ops/server-update.md](../ops/server-update.md)：服务器侧怎么吃到新版本
- [AGENTS.md](../../AGENTS.md)：分支与 tag 的禁令
