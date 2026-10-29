# 域名

> 面板入口、订阅链接、证书都挂在域名上。装完服务器后第一件事就是加域名。
> 更详细的波斯语原版见 [i18n/fa/create_domain.md](../i18n/fa/create_domain.md)。

---

## 1. 准备一条 DNS 记录

在域名服务商处加一条 **A 记录**指向服务器公网 IP（不要用 CNAME，面板要签证书）。

```bash
dig +short <你的域名>        # 应返回服务器 IP
```

想用免费子域，可以用 [freedns.afraid.org](https://freedns.afraid.org/) 这类服务。

---

## 2. 在面板里添加

管理端 → **域名（Domains）** → 添加：

| 字段 | 说明 |
| --- | --- |
| Domain | 填完整域名，如 `sub.example.com` |
| Mode | `direct`（直连）/ `cdn`（前面挂 CDN）/ `relay` |
| 端口 | 一般留默认，由面板分配 |

保存后点 **Apply（应用配置）**。

---

## 3. 证书

面板会自动向 Let's Encrypt 申请证书，签好的证书在：

```bash
ls /opt/hiddify-manager/data/cert
```

申请失败的常见原因：

- 80 端口没放行（ACME 的 HTTP-01 验证要用到）
- DNS 还没生效（`dig` 查不到 IP）
- 短时间反复申请触发了限流

---

## 4. 验证

```bash
curl -sI https://<你的域名>/        # 应返回 200/301，而不是证书错误
```

面板入口地址形如：

```
https://<你的域名>/<proxy_path_admin>/<uuid>/admin/
```

凭据可从 `data/current.json` 读（`proxy_path_admin` 与 `api_key`）。

---

## 5. 相关

- [升级与切版本](server-update.md)：换域名后要重新应用配置
- [外部数据库](external-database.md)
- [面板 Session 跳板](panel-ssh-via-session.md)
