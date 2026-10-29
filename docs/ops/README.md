# 运维

> 返回 [文档总目录](../README.md)。首次部署见 [deploy/](../deploy/README.md)。

---

## 本目录

| 文档 | 内容 |
| --- | --- |
| [server-update.md](server-update.md) | **升级与切版本**：一条命令速查、日常升级、官方转 fork、回滚 |
| [create_domain.md](create_domain.md) | 域名：DNS、面板添加、证书、验证 |
| [customize_proxies.md](customize_proxies.md) | 自定义代理与出站：单用户订阅、指定出站、整体 SOCKS |
| [external-database.md](external-database.md) | 外部 MySQL / Redis 怎么接 |
| [panel-ssh-via-session.md](panel-ssh-via-session.md) | 通过面板 Session 开 SSH 跳板 |
| [i18n/fa/help_customize_proxies.md](../i18n/fa/help_customize_proxies.md) | 自定义代理图解（波斯语原版） |

---

## 一条命令速查

```bash
OK=https://raw.githubusercontent.com/xgs87762GH/Hiddify-Manager/dev-custom/scripts/onekey.sh

sudo -i
bash <(curl -fsSL "$OK") update              # 升级（会先备份）
bash <(curl -fsSL "$OK") reinstall           # 按当前代码重装服务
bash <(curl -fsSL "$OK") version v14.2.4 -y  # 切到指定版本（git 检出：强制换代码留数据）
bash <(curl -fsSL "$OK") switch              # 官方安装 → 转本 fork（只跑一次）
```

---

## 版本升降级要点

| 场景 | 结果 |
| --- | --- |
| 升级（如 v14.2.4 → v14.2.5） | ✅ 一条命令；老版本若被 `.j2` 渲染产物挡住，`onekey.sh` 会自动还原 |
| 同线降级（v14.2.5 → v14.2.4） | ✅ 代码可降，数据不受影响 |
| 跨大版本降级（→ v13.x） | ❌ **数据库迁移不可逆**：代码能装上但面板会因 `db_version` 过高而 502，必须回滚对应版本的数据库备份 |

> 切版本时**不要**用 `git clean -fdx` 手动清理：它会连 `data/` 一起删掉。
> `onekey.sh version <tag>` 保留 `data/`、`generated/` 与虚拟环境。

---

## 备份与回滚

| 备份什么 | 在哪 / 怎么来 |
| --- | --- |
| 面板数据与配置 | 面板"备份"页，或 `services/panel/backup.sh` |
| 服务器状态 | `data/`（含 `data/cert` 证书、`data/backup`） |
| 安装前全量快照 | `/opt/hiddify-manager.bak.<时间戳>` |

代码和数据要**分开回滚**：代码用 `onekey.sh version <tag>`，数据用备份文件。

---

## 日常

```bash
systemctl status hiddify-panel --no-pager          # 面板
journalctl -u hiddify-panel -n 100 --no-pager      # 面板日志
journalctl -u haproxy -n 50 --no-pager             # 入口
tail -n 50 /opt/hiddify-manager/data/log/*          # 安装与应用日志
bash /opt/hiddify-manager/scripts/status.sh         # 一键体检
```
