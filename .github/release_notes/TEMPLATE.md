# vX.Y.ZbN

一句话说明相对上一版改了什么。

## 修复

- **主题**：细节。

## 面板（子模块）

- 指向 `vX.Y.ZbN`。

## 升级

已是 fork（git checkout）：

```bash
cd /opt/hiddify-manager && bash scripts/update.sh
```

非 git / 吃 Release（`package_mode=beta`）：面板点「更新」，或：

```bash
bash scripts/common/download.sh vX.Y.ZbN
```

升级后请在面板 Apply，并让客户端更新订阅。

---

写法注意（避免 GitHub Releases 右侧「On this page」目录变乱）：

- 代码块里**不要**单独成行写 `# 说明`（会被当成一级标题扫进目录）。
- 说明写在代码块**外面**的正文里。
- 全文只保留一个一级标题：本文件开头的 `# v…`。
