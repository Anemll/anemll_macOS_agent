#!/usr/bin/env python3
"""Run non-destructive REST/MCP security and functionality smoke tests."""

from __future__ import annotations

import argparse
import json
import urllib.error
import urllib.request
from typing import Any


def request(
    base_url: str,
    path: str,
    token: str | None,
    method: str = "GET",
    body: Any | None = None,
    extra_headers: dict[str, str] | None = None,
) -> tuple[int, Any]:
    headers = dict(extra_headers or {})
    if token:
        headers["Authorization"] = f"Bearer {token}"
    data = None
    if body is not None:
        data = json.dumps(body, separators=(",", ":")).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(base_url.rstrip("/") + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            status = response.status
            raw = response.read()
    except urllib.error.HTTPError as error:
        status = error.code
        raw = error.read()
    try:
        return status, json.loads(raw) if raw else None
    except json.JSONDecodeError:
        return status, raw.decode(errors="replace")


def expect(name: str, actual: Any, expected: Any) -> None:
    if actual != expected:
        raise AssertionError(f"{name}: expected {expected!r}, got {actual!r}")
    print(f"ok - {name}")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="http://127.0.0.1:8765")
    parser.add_argument("--token", required=True)
    parser.add_argument("--capture", action="store_true", help="Also time a no-file/no-base64 screenshot.")
    args = parser.parse_args()

    status, health = request(args.url, "/health", args.token)
    expect("authenticated health status", status, 200)
    expect("app version", health.get("version"), "0.2.1")

    status, _ = request(args.url, "/health", None)
    expect("missing token rejected", status, 401)
    status, _ = request(args.url, f"/health?token={args.token}", None)
    expect("query token rejected", status, 401)

    status, _ = request(args.url, "/mcp", args.token)
    expect("MCP GET rejected", status, 405)
    status, _ = request(
        args.url,
        "/mcp",
        args.token,
        method="POST",
        body={"jsonrpc": "2.0", "id": 1, "method": "ping"},
        extra_headers={"Origin": "http://localhost.evil.example"},
    )
    expect("DNS-rebinding origin rejected", status, 403)

    status, invalid_burst = request(
        args.url, "/burst", args.token, method="POST", body={"count": -1, "interval_ms": 100}
    )
    expect("negative burst rejected", status, 400)
    if "count must be between" not in invalid_burst.get("detail", ""):
        raise AssertionError("negative burst returned the wrong validation detail")

    mcp_headers = {"MCP-Protocol-Version": "2025-11-25"}
    status, tools_response = request(
        args.url,
        "/mcp",
        args.token,
        method="POST",
        body={"jsonrpc": "2.0", "id": 2, "method": "tools/list", "params": {}},
        extra_headers=mcp_headers,
    )
    expect("MCP tools/list status", status, 200)
    tool_names = {tool["name"] for tool in tools_response["result"]["tools"]}
    expected_tools = {
        "anemll_accessibility_tree",
        "anemll_accessibility_action",
        "anemll_accessibility_wait",
        "anemll_activate",
        "anemll_paste",
        "anemll_hotkey",
        "anemll_drag",
        "anemll_batch",
    }
    missing = expected_tools - tool_names
    if missing:
        raise AssertionError(f"missing MCP tools: {sorted(missing)}")
    print("ok - modern MCP tool surface")

    status, batch = request(
        args.url,
        "/batch",
        args.token,
        method="POST",
        body={"actions": [{"type": "wait", "duration_ms": 1}]},
    )
    expect("bounded batch status", status, 200)
    expect("bounded batch result", batch.get("ok"), True)

    if args.capture:
        status, capture = request(
            args.url,
            "/screenshot",
            args.token,
            method="POST",
            body={
                "cursor": False,
                "max_dimension": 1120,
                "resize_mode": "scale",
                "return_base64": False,
                "save_to_file": False,
            },
        )
        expect("ScreenCaptureKit screenshot status", status, 200)
        if capture.get("screen_scale", 0) < 1 or capture.get("total_ms", 0) <= 0:
            raise AssertionError(f"invalid screenshot metrics: {capture}")
        print(
            "ok - screenshot metrics: "
            f"capture={capture['capture_ms']} ms encode={capture['encode_ms']} ms total={capture['total_ms']} ms"
        )

    print("all harness smoke tests passed")


if __name__ == "__main__":
    main()
