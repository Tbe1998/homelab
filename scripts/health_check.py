#!/usr/bin/env python3
"""服务探活：只做判定，不做动作。

用法:
    python3 health_check.py -c checks.json            # 逐项检查，打印结果
    python3 health_check.py -c checks.json --quiet    # 只返回退出码（cron 用）
    python3 health_check.py --selftest                # 自检，不依赖网络

退出码: 0 全部正常 / 1 有失败 / 2 配置错误

设计要点:
  * 只用标准库，NAS 上没有 pip 也能跑
  * 状态文件记录连续失败次数，供 watchdog 判断"是否真的坏了"
  * 失败才会发 webhook，恢复时也发一条（避免静默恢复被忽视）
"""
import argparse
import json
import os
import socket
import sys
import time
import urllib.error
import urllib.request

STATE_PATH = os.environ.get("HC_STATE", "/tmp/health_check_state.json")
TIMEOUT = float(os.environ.get("HC_TIMEOUT", "8"))


def load_state():
    try:
        with open(STATE_PATH, encoding="utf-8") as fp:
            return json.load(fp)
    except (OSError, ValueError):
        return {}


def save_state(state):
    tmp = STATE_PATH + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as fp:
            json.dump(state, fp, ensure_ascii=False)
        os.replace(tmp, STATE_PATH)
    except OSError:
        pass  # 状态文件写不了不影响判定


def http_check(url, expect=None, timeout=TIMEOUT):
    """返回 (ok, 说明)。expect 为 None 时接受 2xx/3xx。"""
    req = urllib.request.Request(url, headers={"User-Agent": "health-check/1.0"})
    started = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            body = resp.read(2048).decode("utf-8", "replace")
            code = resp.getcode()
    except urllib.error.HTTPError as exc:
        return False, "HTTP %s" % exc.code
    except Exception as exc:  # 连接/超时/DNS 统一视为失败
        return False, "%s: %s" % (type(exc).__name__, exc)
    elapsed = int((time.time() - started) * 1000)
    if expect is not None and expect not in body:
        return False, "内容不匹配(期望包含 %r)" % expect
    if not 200 <= code < 400:
        return False, "HTTP %s" % code
    return True, "HTTP %s %dms" % (code, elapsed)


def tcp_check(host, port, timeout=TIMEOUT):
    started = time.time()
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            pass
    except OSError as exc:
        return False, "%s: %s" % (type(exc).__name__, exc)
    elapsed = int((time.time() - started) * 1000)
    return True, "TCP 通 %dms" % elapsed


def run_check(item):
    if item.get("type", "http") == "tcp":
        return tcp_check(item["host"], item["port"])
    return http_check(item["url"], item.get("expect"))


def notify(text, webhook):
    if not webhook:
        return
    payload = json.dumps({"msg_type": "text", "content": {"text": text}},
                         ensure_ascii=False).encode()
    req = urllib.request.Request(webhook, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        urllib.request.urlopen(req, timeout=TIMEOUT).read()
    except Exception as exc:
        print("[warn] 通知发送失败: %s" % exc, file=sys.stderr)


def selftest():
    """不依赖外部网络的冒烟测试。"""
    ok1, _ = http_check("http://127.0.0.1:1/", timeout=1)
    assert ok1 is False, "关闭的端口必须判失败"
    ls = socket.socket()
    ls.bind(("127.0.0.1", 0))
    ls.listen(1)
    port = ls.getsockname()[1]
    ok2, msg2 = tcp_check("127.0.0.1", port, timeout=1)
    assert ok2 is True, "监听中的端口必须判通过: %s" % msg2
    assert run_check({"type": "tcp", "host": "127.0.0.1", "port": port})[0] is True
    ls.close()
    # 关闭后必须判失败（负向用例，防止探活永远返回 True）
    assert run_check({"type": "tcp", "host": "127.0.0.1", "port": port})[0] is False
    print("selftest 通过")
    return 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("-c", "--config")
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()

    if args.selftest:
        return selftest()
    if not args.config:
        print("缺少 -c 配置文件", file=sys.stderr)
        return 2
    try:
        with open(args.config, encoding="utf-8") as fp:
            cfg = json.load(fp)
    except (OSError, ValueError) as exc:
        print("配置文件读取失败: %s" % exc, file=sys.stderr)
        return 2

    state = load_state()
    failed, messages = [], []
    for item in cfg.get("checks", []):
        name = item.get("name") or item.get("url") or item.get("host")
        ok, detail = run_check(item)
        rec = state.get(name, {"fails": 0})
        was_failing = rec.get("fails", 0) >= int(cfg.get("flap_threshold", 3))
        rec["fails"] = 0 if ok else rec.get("fails", 0) + 1
        rec["last"] = time.strftime("%Y-%m-%d %H:%M:%S")
        rec["detail"] = detail
        state[name] = rec
        line = "  %s %-24s %s" % ("OK  " if ok else "FAIL", name, detail)
        if not args.quiet:
            print(line)
        if not ok:
            failed.append(name)
            messages.append(line.strip())
        elif was_failing:
            messages.append("RECOVERED %s" % name)

    save_state(state)

    if messages:
        text = "[巡检] %s\n%s" % ("异常" if failed else "恢复", "\n".join(messages))
        notify(text, cfg.get("webhook") or os.environ.get("ALERT_WEBHOOK"))

    if not args.quiet:
        print("\n%d 项检查，%d 项失败" % (len(state), len(failed)))
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
