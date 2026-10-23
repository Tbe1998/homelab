# 故障 Runbook

真实发生过的 4 个案例。格式统一为：**现象 → 定位过程 → 根因 → 处置 → 防复发**。
误判也保留，因为排查思路比结论有用。

---

## 案例 1：SDR 接收机数据流中断（USB 直通失效）

**现象** 频谱停止刷新，WebSDR 页面能打开但无信号；容器 `Up`，进程活着。

**定位**
1. `dmesg | tail` → 见 `usb 1-1: device descriptor read/64, error -71`
2. 宿主 `lsusb` 仍能列出 RTL-SDR → 设备"在"，但应用层打不开（`LIBUSB_ERROR_IO`）
3. 判定：内核枚举状态和用户态句柄失配，**不是驱动问题**，重新枚举即恢复

**根因** USB 直通在长时间运行后偶发失配（宿主机内核 4.4 上的已知行为）。

**处置** 对设备做授权位复位（不拔插）：

```bash
for d in /sys/bus/usb/devices/*/idVendor; do
  [ "$(cat "$d")" = "0bda" ] || continue
  dev=$(dirname "$d")
  echo 0 | sudo tee "$dev/authorized" >/dev/null
  sleep 2
  echo 1 | sudo tee "$dev/authorized" >/dev/null
done
```
随后 `docker restart <sdr>`。见 [`scripts/watchdog_service.sh`](../scripts/watchdog_service.sh)
的 `--usb-reset` 分支，已做成自动流程。

**防复发** cron 每 2 分钟探活一次，连续 3 次失败触发"重新枚举 → 重启容器"，
仍失败才告警。人工介入率从每天数次降到月级。

---

## 案例 2：证书续期后 HTTPS 立刻失效

**现象** `renew_cert.sh` 返回成功，新证书文件时间戳是新的，但浏览器报
`ERR_CERT_DATE_INVALID` / 证书仍是旧的。

**定位** `openssl s_client -connect <host>:443 -servername <host> | openssl x509 -noout -dates`
→ 服务端仍在用旧证书 ⇒ 进程没有重新加载。

**根因** DSM 的 Web 服务是套件（synopkg）而非 systemd 单元，**只 replace 文件不会生效**，
且部分套件 reload 不读新证书。

**处置**
```bash
synopkg stop  <pkg>
cp new.crt /path/to/cert.pem && cp new.key /path/to/cert.key
synopkg start <pkg>
```
顺序必须是 stop → 换文件 → start。已固化进脚本。

**防复发** 续期脚本里加"生效校验"：取服务端实际证书指纹与磁盘文件比对，
不一致直接返回非 0 并告警，而不是默默成功。

---

## 案例 3：反代后子路径 404/502

**现象** 打开 `https://<host>/app` 502；直连容器端口正常。

**定位顺序**（此顺序本身就是结论）
1. 容器内 `curl -sI http://127.0.0.1:PORT` → 200 ⇒ 服务本身没问题
2. 宿主机 `curl -sI http://<bridge-ip>:PORT` → 200 ⇒ 网络通
3. 容器日志显示请求路径是 `/app/xxx` ⇒ **应用不认子路径前缀**

**根因** 两件事叠加：upstream 需要 `trailing slash` 才能剥离前缀；
应用自身生成的静态资源用绝对路径 `/static/...`。

**处置** `proxy_pass http://upstream/;`（带尾斜杠）+ 应用侧配置 base URL；
必要时对静态路径再补一条 `location`。

**防复发** 反代模板里把这个坑写成注释，见
[`proxy/nginx/reverse-proxy.conf`](../proxy/nginx/reverse-proxy.conf)。

---

## 案例 4：一次误判 —— 服务"掉线"其实是磁盘满

**现象** 某容器反复重启，`docker logs` 里是连接数据库失败。
第一反应是 DB 挂了，重启 DB 容器 —— 无效果。

**定位** `df -h` → 系统分区 100%。日志文件把分区写满后，DB 无法写入临时文件，
于是应用层表现为"连不上 DB"。

**教训** 报错文案指向的是**最近一层的下层失败**，不一定是根因。
容器反复重启时，先看 `docker inspect` 的退出码 + 宿主机 `df -h` / `dmesg`，
再怀疑服务本身。

**防复发** 巡检脚本加磁盘水位检查（>85% 告警），并给容器日志配 `max-size`。
