# 自定义代理与出站

> 三件事：**给单个用户单独一条订阅链接**、**让某个用户走指定出站（如 WARP）**、
> **让服务器出口整体走另一个代理（如 SOCKS）**。
> 图解与波斯语原版见 [i18n/fa/help_customize_proxies.md](../i18n/fa/help_customize_proxies.md)。

---

## 1. 给单个用户一条专属订阅链接

适合把某个用户导到另一台服务器 / 另一条线路：

1. 管理端 → **用户（Users）** → 打开该用户
2. 在 *Custom proxies / 自定义代理* 里填一条订阅链接或节点链接
3. 保存 → **Apply**

该用户拿到的订阅里就只含这条自定义配置。

---

## 2. 让某个用户走指定出站（例如 WARP）

1. 管理端 → **出站（Outbounds）** 确认 WARP 出站已存在
2. 打开该用户 → *自定义出站* 选 WARP
3. 保存 → **Apply**

验证：客户端连上看出口 IP。

```bash
curl -s https://api.ipify.org       # 客户端侧执行，应为 WARP 的出口
```

---

## 3. 让服务器出口整体走 SOCKS

适合"服务器本身要先经过一层代理再出网"：

1. 管理端 → **设置** → 出站里加一条 SOCKS 出站（填写目标 SOCKS 地址与端口）
2. 把它设为默认出站
3. **Apply**

> 改完整体出站会影响所有用户，先在低峰改，改完立刻验证。

---

## 4. 应用与回滚

| 操作 | 位置 / 命令 |
| --- | --- |
| 应用配置 | 面板 *Apply* 按钮，或 `make apply` |
| 看生成结果 | `hiddify-panel-cli dump-server-configs /tmp/out` |
| 出问题回滚 | 删掉刚加的自定义项再 *Apply*，配置由面板重新生成 |

> 不要手改 `generated/`：下次应用就会被覆盖。

---

## 5. 相关

- [升级与切版本](server-update.md)
- [外部数据库](external-database.md)
- [部署总览](../deploy/README.md)
