# 安全与脱敏规则

## 本仓库的脱敏规则

| 原始信息 | 处理方式 |
|---|---|
| 公网 IP / 云主机地址 | 全部置空或 `<frps-host>` |
| 内网网段 | 统一 `192.168.1.0/24`（示例值，非真实拓扑细节） |
| 域名 | `example.com` |
| 数据库口令 / APP_KEY / token | 一律 `${VAR}`，仓库只有 `.env.example` 里的占位符 |
| TLS 私钥 / 证书 | **不提交**，仓库只放路径与脚本 |
| 具体服务名 | 只保留功能名，去掉与本机绑定的命名 |

## 凭据管理

1. `.env` 与 `*.pem` / `*.key` / `*.p12` 在 `.gitignore` 中；
2. compose 里只有 `${VAR}`，缺失变量时 `docker compose config` 会报错而不是用空值上线；
3. 每个服务独立口令，不复用；
4. 备份包（`scripts/backup_stacks.sh`）在本地加密存放，不进任何远端仓库。

## 暴露面原则

- 默认**不**给服务开公网端口；需要时在 frp 里单条加，用完注释掉；
- 管理类端口（SSH / DSM / 面板）即使穿透也换高位端口 + 强口令 + 失败锁定；
- 反代侧统一加安全响应头（HSTS / X-Frame-Options / X-Content-Type-Options）；
- 反向代理到容器只走内网 bridge IP，`proxy_pass` 目标不写宿主公网地址。

## 如果误提交了凭据

按"已泄露"处理，顺序不能反：

1. **先轮换**（改口令 / 重签 token / 换证书），再动 git 历史；
2. `git filter-repo --invert-paths --path .env` 清理历史并强推；
3. 检查 CI 日志、Actions artifacts、frok/PR 引用，确认无残留副本；
4. 复盘：为什么会走到 `git add -A`。
