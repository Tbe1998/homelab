# homelab — 单机自建服务运维实践

一台群晖 NAS（DSM 7.2 / Docker）上长期稳定运行的 11 个容器、1 条公网入口、
若干自研服务的**配置模板 + 运维文档 + 巡检脚本**。

这不是一份"部署教程"，是**真在跑的东西**的抽象版本：所有域名、IP、凭据、
证书已被占位符替换（见 [docs/security.md](docs/security.md) 的脱敏说明），
保留的是架构决策、故障处理路径和自动化逻辑。

## 架构

```
        公网                     边界                   内网 (192.168.1.0/24)
 ┌──────────────┐        ┌─────────────────┐      ┌──────────────────────────────┐
 │  Let's Encrypt│        │  云主机 (frps)   │      │   NAS  192.168.1.6           │
 │  DNS / DDNS   │        │  仅做端口转发     │      │  ├─ nginx 反代 (443)         │
 └──────┬───────┘        │  7000/7001      │      │  │   ├─ /wavelog  → bridge:80 │
        │                └────────┬────────┘      │  │   ├─ /download → 静态       │
        │  证书签发/续期           │ frpc 隧道      │  │   └─ /  → 各容器 upstream  │
        ▼                         ▼              │  ├─ Docker (11 containers)    │
 ┌──────────────────────────────────────┐        │  │   snipeit / wavelog / HA  │
 │  scripts/renew_cert.sh → 分发到 NAS   │        │  │   camofox / mcs / frpc …  │
 └──────────────────────────────────────┘        │  └─ 独立 SDR 主机 192.168.1.13 │
                                                  │      WebSDR (RTL-SDR ×2)     │
                                                  └──────────────────────────────┘
       巡检：scripts/health_check.py ← cron(*/2) ── watchdog_service.sh ── 重启/通知
```

## 目录

| 路径 | 内容 |
|---|---|
| [`stacks/`](stacks/) | 4 个典型服务的 `docker-compose.yml`（凭据全部走 `.env`） |
| [`proxy/nginx/`](proxy/nginx/) | 反向代理模板：HTTPS、WebSocket、大文件、超时、安全响应头 |
| [`proxy/frp/`](proxy/frp/) | 内网穿透客户端模板（**只暴露必要端口**的写法） |
| [`scripts/`](scripts/) | 探活巡检、失败自愈、证书续期、配置备份 |
| [`docs/architecture.md`](docs/architecture.md) | 端口/服务/依赖关系的完整清单与取舍理由 |
| [`docs/runbook.md`](docs/runbook.md) | 4 个真实故障案例的定位与处理过程 |
| [`docs/security.md`](docs/security.md) | 暴露面最小化、凭据管理、脱敏规则 |

## 关键设计取舍

1. **凭据一律不进 git**：compose 只引用 `${VAR}`，`.env` 在 `.gitignore` 里，
   仓库只提交 `.env.example`。原始配置里出现明文口令是常见事故，本体已修正。
2. **公网入口收敛到 frp 单条隧道**：不开放 DSM 路由器的端口映射，暴露面只有
   云主机那一个 IP，且每个服务单独控制是否上穿透。清单见 `proxy/frp/frpc.ini.example`。
3. **反代承担 TLS 终止**：容器内一律明文 HTTP，证书只在 nginx 一处维护，
   续期后只需 reload 一个进程。
4. **探活与自愈分离**：`health_check.py` 只负责判定（退出码 + 状态文件），
   `watchdog_service.sh` 负责动作（连续 N 次失败才重启，防抖动）。
5. **故障处理写成 runbook**：不是"应该怎么做"，是"上次怎么做的"，含误判记录。

## 验证方式

这个仓库里的配置不是纸面示例，提交前做过端到端验证：

| 项目 | 验证方式 | 结果 |
|---|---|---|
| 4 个 compose | 在真实 NAS 上 `docker compose config -q`（Compose v2.20.1） | 全部通过 |
| `health_check.py` | `--selftest` 正向+负向用例；对线上 4 个真实端口跑一遍 | 通过，能正确区分 200/拒绝连接 |
| `watchdog_service.sh` | `--check-only` 对活服务与死端口各跑一次 | 退出码 0 / 1 符合预期 |
| bash 脚本 | `bash -n` 语法检查 | 3 个全过 |
| 凭据泄露 | CI 里的正则扫描 + 人工复核 | 无硬编码口令 |
| 运行环境 | NAS 自带 Python 3.8.15，未装任何第三方包 | 可直接运行 |

> 目标环境兼容 Python 3.8+（NAS 上的实际版本），脚本刻意不用 f-string 之外的新语法特性，
> 也不依赖 pip 安装任何东西。

## 用到的东西

Synology DSM 7.2 · Docker / Compose · nginx（反代 + TLS）· frp · 
Python 3.8+（stdlib，无第三方依赖）· bash · GitHub Actions（配置校验）· Let's Encrypt

## License

MIT
