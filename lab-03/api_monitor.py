#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import socket
import ssl
import sys
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone
from typing import Any


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="api_monitor.py",
        description="Check configured API endpoints, classify failure types, log results, and send alerts.",
        epilog=(
            "Exit codes:\n"
            "  0  All targets healthy\n"
            "  1  CLI arguments or configuration file error\n"
            "  2  One or more targets failed or degraded\n\n"
            "Example:\n"
            "  python3 api_monitor.py --config config/endpoints.json"
        ),
        formatter_class=argparse.RawTextHelpFormatter,
    )
    parser.add_argument("--config", required=True, help="Path to JSON configuration file")
    return parser


def utc_now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def classify_exception(exc: BaseException) -> str:
    if isinstance(exc, (ssl.SSLCertVerificationError, ssl.SSLError)):
        return "CERTIFICATE_ERROR"
    if isinstance(exc, socket.gaierror):
        return "DNS_ERROR"
    if isinstance(exc, (TimeoutError, socket.timeout)):
        return "TIMEOUT"
    if isinstance(exc, urllib.error.URLError):
        reason = exc.reason
        if isinstance(reason, (ssl.SSLCertVerificationError, ssl.SSLError)):
            return "CERTIFICATE_ERROR"
        if isinstance(reason, socket.gaierror):
            return "DNS_ERROR"
        if isinstance(reason, (TimeoutError, socket.timeout)):
            return "TIMEOUT"
        if isinstance(reason, ConnectionRefusedError):
            return "CONNECTION_REFUSED"
        if reason is not None:
            text = str(reason).lower()
            if "name or service not known" in text or "nodename nor servname provided" in text or "getaddrinfo" in text:
                return "DNS_ERROR"
            if "connection refused" in text or "actively refused" in text or "winerror 10061" in text:
                return "CONNECTION_REFUSED"
            if "timed out" in text or "timeout" in text:
                return "TIMEOUT"
            if "certificate" in text or "ssl" in text:
                return "CERTIFICATE_ERROR"
    if isinstance(exc, ConnectionRefusedError):
        return "CONNECTION_REFUSED"
    text = str(exc).lower()
    if "connection refused" in text or "actively refused" in text or "winerror 10061" in text:
        return "CONNECTION_REFUSED"
    if "timed out" in text or "timeout" in text:
        return "TIMEOUT"
    if "certificate" in text or "ssl" in text:
        return "CERTIFICATE_ERROR"
    return "NETWORK_ERROR"


def single_request(url: str, timeout_sec: float) -> tuple[int, float]:
    start = time.perf_counter()
    req = urllib.request.Request(url=url, method="GET", headers={"User-Agent": "DevOps-API-Monitor/1.0"})
    try:
        with urllib.request.urlopen(req, timeout=timeout_sec) as resp:
            elapsed_ms = (time.perf_counter() - start) * 1000.0
            status = getattr(resp, "status", None) or resp.getcode() or 200
            return int(status), round(elapsed_ms, 2)
    except urllib.error.HTTPError as http_err:
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        return int(http_err.code), round(elapsed_ms, 2)


def check_target(target: dict[str, Any]) -> dict[str, Any]:
    name = str(target.get("name", "unnamed"))
    url = str(target.get("url", ""))
    expected_status = int(target.get("expected_status", 200))
    timeout_sec = float(target.get("timeout_sec", 5.0))
    max_response_ms = float(target.get("max_response_ms", 3000.0))

    checked_at = utc_now_iso()
    attempts = 0
    last_error_type: str | None = None
    last_error_msg: str | None = None

    while attempts < 2:
        attempts += 1
        try:
            status_code, elapsed_ms = single_request(url, timeout_sec)
            if status_code != expected_status:
                return {
                    "timestamp": checked_at,
                    "target": name,
                    "url": url,
                    "status": "FAILED",
                    "http_status": status_code,
                    "response_time_ms": elapsed_ms,
                    "failure_type": "UNEXPECTED_STATUS",
                    "detail": f"Expected HTTP {expected_status}, got {status_code}",
                    "attempts": attempts,
                }
            if elapsed_ms > max_response_ms:
                return {
                    "timestamp": checked_at,
                    "target": name,
                    "url": url,
                    "status": "DEGRADED",
                    "http_status": status_code,
                    "response_time_ms": elapsed_ms,
                    "failure_type": "SLOW_RESPONSE",
                    "detail": f"Response time {elapsed_ms} ms exceeded threshold {max_response_ms} ms",
                    "attempts": attempts,
                }
            return {
                "timestamp": checked_at,
                "target": name,
                "url": url,
                "status": "OK",
                "http_status": status_code,
                "response_time_ms": elapsed_ms,
                "failure_type": None,
                "detail": "Healthy",
                "attempts": attempts,
            }
        except Exception as exc:  # noqa: BLE001
            failure_type = classify_exception(exc)
            last_error_type = failure_type
            last_error_msg = str(exc)
            if attempts < 2 and failure_type in {"DNS_ERROR", "CONNECTION_REFUSED", "TIMEOUT", "NETWORK_ERROR"}:
                time.sleep(0.2)
                continue
            break

    return {
        "timestamp": checked_at,
        "target": name,
        "url": url,
        "status": "FAILED",
        "http_status": None,
        "response_time_ms": None,
        "failure_type": last_error_type or "NETWORK_ERROR",
        "detail": last_error_msg or "Request failed",
        "attempts": attempts,
    }


def send_alert(record: dict[str, Any], alerts_cfg: dict[str, Any]) -> str:
    webhook_env = str(alerts_cfg.get("webhook_env", "ALERT_WEBHOOK_URL"))
    webhook_url = os.environ.get(webhook_env, "").strip()
    tg_token_env = str(alerts_cfg.get("telegram_token_env", "TELEGRAM_BOT_TOKEN"))
    tg_chat_env = str(alerts_cfg.get("telegram_chat_env", "TELEGRAM_CHAT_ID"))
    tg_token = os.environ.get(tg_token_env, "").strip()
    tg_chat = os.environ.get(tg_chat_env, "").strip()

    message = (
        f"[API MONITOR ALERT] Target: {record['target']} ({record['url']}) | "
        f"Failure type: {record['failure_type']} | Detail: {record['detail']}"
    )

    if webhook_url:
        payload = json.dumps({"text": message, "content": message}).encode("utf-8")
        req = urllib.request.Request(
            url=webhook_url,
            data=payload,
            method="POST",
            headers={"Content-Type": "application/json", "User-Agent": "DevOps-API-Monitor/1.0"},
        )
        try:
            with urllib.request.urlopen(req, timeout=5.0):
                return "sent_webhook"
        except Exception as exc:  # noqa: BLE001
            return f"webhook_failed:{exc}"

    if tg_token and tg_chat:
        tg_url = f"https://api.telegram.org/bot{tg_token}/sendMessage"
        payload = json.dumps({"chat_id": tg_chat, "text": message}).encode("utf-8")
        req = urllib.request.Request(
            url=tg_url,
            data=payload,
            method="POST",
            headers={"Content-Type": "application/json", "User-Agent": "DevOps-API-Monitor/1.0"},
        )
        try:
            with urllib.request.urlopen(req, timeout=5.0):
                return "sent_telegram"
        except Exception as exc:  # noqa: BLE001
            return f"telegram_failed:{exc}"

    return "skipped_no_env_secret"


def write_structured_log(log_path: str, records: list[dict[str, Any]]) -> None:
    parent = os.path.dirname(log_path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(log_path, "a", encoding="utf-8", newline="\n") as fh:
        for rec in records:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()

    if not os.path.isfile(args.config):
        print(f"ERROR: Config file not found: '{args.config}'", file=sys.stderr)
        return 1

    try:
        with open(args.config, "r", encoding="utf-8") as fh:
            cfg = json.load(fh)
    except Exception as exc:  # noqa: BLE001
        print(f"ERROR: Cannot read valid JSON config '{args.config}': {exc}", file=sys.stderr)
        return 1

    targets = cfg.get("targets")
    if not isinstance(targets, list) or len(targets) == 0:
        print("ERROR: Config must contain a non-empty 'targets' list.", file=sys.stderr)
        return 1

    log_file = str(cfg.get("log_file", "lab-03/monitor_results.jsonl"))
    alerts_cfg = cfg.get("alerts") if isinstance(cfg.get("alerts"), dict) else {}

    results: list[dict[str, Any]] = []
    has_problems = False

    for target in targets:
        if not isinstance(target, dict) or not target.get("url"):
            print("ERROR: Each target must be an object with a non-empty 'url'.", file=sys.stderr)
            return 1
        record = check_target(target)
        alert_status = "none"
        if record["status"] != "OK":
            has_problems = True
            alert_status = send_alert(record, alerts_cfg)
        record["alert_status"] = alert_status
        results.append(record)
        print(
            f"[{record['timestamp']}] target={record['target']} status={record['status']} "
            f"failure_type={record['failure_type']} time_ms={record['response_time_ms']} "
            f"alert={alert_status} detail=\"{record['detail']}\""
        )

    try:
        write_structured_log(log_file, results)
    except OSError as exc:
        print(f"ERROR: Failed to write log file '{log_file}': {exc}", file=sys.stderr)
        return 1

    return 2 if has_problems else 0


if __name__ == "__main__":
    sys.exit(main())