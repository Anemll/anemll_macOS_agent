#!/usr/bin/env python3
"""Benchmark an OpenAI-compatible no-image model against AnemllAgentHost's text tools."""

from __future__ import annotations

import argparse
import json
import math
import statistics
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any


DEFAULT_BASE_URL = "http://192.168.1.68:8888/v1"
DEFAULT_MODEL = "deepseek-v4-flash-dspark-abliterated"
MCP_VERSION = "2025-11-25"

SCENARIOS = (
    {
        "name": "window_metadata",
        "request": "Inspect visible windows using text metadata. Do not request or use an image.",
        "expected": "anemll_windows",
        "arguments": {"on_screen": True},
    },
    {
        "name": "accessibility_tree",
        "request": "Inspect the AnemllAgentHost accessibility tree without using a screenshot.",
        "expected": "anemll_accessibility_tree",
        "arguments": {"app": "AnemllAgentHost", "max_depth": 4, "max_elements": 100},
    },
    {
        "name": "bounded_batch",
        "request": "Use one batch request to wait exactly 1 millisecond. Do not perform any other action.",
        "expected": "anemll_batch",
        "arguments": {"actions": [{"type": "wait", "duration_ms": 1}]},
    },
)

SYSTEM_PROMPT = """You are testing a local macOS automation harness in no-image mode.
Return exactly one JSON object and no prose or markdown:
{"tool":"<tool name>","arguments":{...}}

Available text-only tools:
- anemll_windows({on_screen:boolean}): visible window metadata
- anemll_accessibility_tree({app,max_depth,max_elements}): semantic UI elements
- anemll_batch({actions:[...]}): bounded low-round-trip actions

Choose the single tool that directly satisfies the request. Keep arguments minimal and deterministic."""


class RequestFailure(RuntimeError):
    pass


def request_json(
    url: str,
    payload: dict[str, Any] | None,
    headers: dict[str, str],
    timeout: float,
) -> tuple[Any, float]:
    data = None if payload is None else json.dumps(payload, separators=(",", ":")).encode()
    request = urllib.request.Request(url, data=data, headers=headers, method="GET" if data is None else "POST")
    started = time.perf_counter()
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            body = response.read()
    except (urllib.error.URLError, TimeoutError) as error:
        raise RequestFailure(str(error)) from error
    elapsed_ms = (time.perf_counter() - started) * 1_000
    try:
        return json.loads(body), elapsed_ms
    except json.JSONDecodeError as error:
        raise RequestFailure(f"invalid JSON response: {body[:200]!r}") from error


def stream_completion(
    base_url: str,
    model: str,
    api_key: str,
    scenario: dict[str, Any],
    timeout: float,
    max_tokens: int,
) -> dict[str, Any]:
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": SYSTEM_PROMPT},
            {
                "role": "user",
                "content": f"Request: {scenario['request']}\nUse these exact arguments when applicable: {json.dumps(scenario['arguments'])}",
            },
        ],
        "temperature": 0,
        "max_tokens": max_tokens,
        "stream": True,
        "stream_options": {"include_usage": True},
        "chat_template_kwargs": {"enable_thinking": False},
    }
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
        "Accept": "text/event-stream",
    }
    request = urllib.request.Request(
        f"{base_url.rstrip('/')}/chat/completions",
        data=json.dumps(payload, separators=(",", ":")).encode(),
        headers=headers,
        method="POST",
    )

    started = time.perf_counter()
    first_token_ms: float | None = None
    first_content_ms: float | None = None
    content_parts: list[str] = []
    reasoning_parts: list[str] = []
    usage: dict[str, Any] = {}
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            for raw_line in response:
                line = raw_line.decode("utf-8", errors="replace").strip()
                if not line.startswith("data:"):
                    continue
                raw_data = line[5:].strip()
                if not raw_data or raw_data == "[DONE]":
                    continue
                event = json.loads(raw_data)
                if event.get("usage"):
                    usage = event["usage"]
                choices = event.get("choices") or []
                if not choices:
                    continue
                delta = choices[0].get("delta") or {}
                reasoning = delta.get("reasoning_content") or delta.get("reasoning") or ""
                content = delta.get("content") or ""
                if (reasoning or content) and first_token_ms is None:
                    first_token_ms = (time.perf_counter() - started) * 1_000
                if content and first_content_ms is None:
                    first_content_ms = (time.perf_counter() - started) * 1_000
                if reasoning:
                    reasoning_parts.append(reasoning)
                if content:
                    content_parts.append(content)
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError) as error:
        raise RequestFailure(str(error)) from error

    return {
        "content": "".join(content_parts),
        "reasoning_characters": sum(map(len, reasoning_parts)),
        "first_token_ms": first_token_ms,
        "first_content_ms": first_content_ms,
        "total_ms": (time.perf_counter() - started) * 1_000,
        "usage": usage,
    }


def extract_json_object(text: str) -> dict[str, Any]:
    decoder = json.JSONDecoder()
    for index, character in enumerate(text):
        if character != "{":
            continue
        try:
            value, _ = decoder.raw_decode(text[index:])
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            return value
    raise ValueError("no JSON object in model output")


class HarnessClient:
    def __init__(self, base_url: str, token: str, timeout: float) -> None:
        self.base_url = base_url.rstrip("/")
        self.timeout = timeout
        self.headers = {
            "Authorization": f"Bearer {token}",
            "Content-Type": "application/json",
            "MCP-Protocol-Version": MCP_VERSION,
        }
        self.next_id = 1

    def call(self, method: str, params: dict[str, Any] | None = None) -> tuple[dict[str, Any], float]:
        request_id = self.next_id
        self.next_id += 1
        payload: dict[str, Any] = {"jsonrpc": "2.0", "id": request_id, "method": method}
        if params is not None:
            payload["params"] = params
        response, latency = request_json(f"{self.base_url}/mcp", payload, self.headers, self.timeout)
        if not isinstance(response, dict) or response.get("id") != request_id:
            raise RequestFailure("mismatched MCP response")
        if "error" in response:
            raise RequestFailure(f"MCP error: {response['error']}")
        return response, latency

    def initialize(self) -> dict[str, Any]:
        response, latency = self.call(
            "initialize",
            {"protocolVersion": MCP_VERSION, "capabilities": {}, "clientInfo": {"name": "model-benchmark", "version": "1"}},
        )
        tools_response, tools_latency = self.call("tools/list", {})
        tools = tools_response.get("result", {}).get("tools", [])
        return {
            "initialize_ms": round(latency, 2),
            "tools_list_ms": round(tools_latency, 2),
            "tool_names": [tool.get("name") for tool in tools if isinstance(tool, dict)],
        }

    def execute_safe(self, plan: dict[str, Any]) -> dict[str, Any]:
        tool = plan.get("tool")
        arguments = plan.get("arguments")
        if tool not in {"anemll_windows", "anemll_accessibility_tree", "anemll_batch"} or not isinstance(arguments, dict):
            raise RequestFailure("model selected a tool outside the read-only acceptance-test allowlist")
        if tool == "anemll_batch":
            actions = arguments.get("actions")
            if (
                not isinstance(actions, list)
                or not actions
                or any(not isinstance(action, dict) or action.get("type") != "wait" for action in actions)
            ):
                raise RequestFailure("model batch contained a non-wait action")
        response, latency = self.call("tools/call", {"name": tool, "arguments": arguments})
        result = response.get("result", {})
        return {
            "latency_ms": round(latency, 2),
            "is_error": bool(result.get("isError")),
        }


def percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(math.ceil(fraction * len(ordered)) - 1, len(ordered) - 1)
    return round(ordered[max(index, 0)], 2)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--model", default=DEFAULT_MODEL)
    parser.add_argument("--api-key", default="not-needed")
    parser.add_argument("--iterations", type=int, default=6)
    parser.add_argument("--retries", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=120)
    parser.add_argument("--max-tokens", type=int, default=256)
    parser.add_argument("--harness-url", default="http://127.0.0.1:8765")
    parser.add_argument("--harness-token")
    parser.add_argument("--report", type=Path, default=Path("/tmp/anemll_deepseek_benchmark.json"))
    args = parser.parse_args()

    if args.iterations < 1 or args.iterations > 100:
        parser.error("--iterations must be between 1 and 100")

    report: dict[str, Any] = {
        "model": args.model,
        "base_url": args.base_url,
        "iterations": args.iterations,
        "started_at": int(time.time()),
        "harness": None,
        "runs": [],
    }
    harness: HarnessClient | None = None
    if args.harness_token:
        harness = HarnessClient(args.harness_url, args.harness_token, args.timeout)
        report["harness"] = harness.initialize()
        missing = sorted({scenario["expected"] for scenario in SCENARIOS} - set(report["harness"]["tool_names"]))
        if missing:
            raise RequestFailure(f"harness is missing expected tools: {missing}")

    for index in range(args.iterations):
        scenario = SCENARIOS[index % len(SCENARIOS)]
        run: dict[str, Any] = {"index": index, "scenario": scenario["name"], "expected_tool": scenario["expected"]}
        for attempt in range(args.retries + 1):
            try:
                completion = stream_completion(
                    args.base_url, args.model, args.api_key, scenario, args.timeout, args.max_tokens
                )
                plan = extract_json_object(completion["content"])
                run.update(completion)
                run["plan"] = plan
                run["json_valid"] = True
                run["tool_correct"] = plan.get("tool") == scenario["expected"]
                run["attempts"] = attempt + 1
                if harness and run["tool_correct"]:
                    run["harness_execution"] = harness.execute_safe(plan)
                break
            except (RequestFailure, ValueError) as error:
                run["error"] = str(error)
                run["attempts"] = attempt + 1
                if attempt < args.retries:
                    time.sleep(0.5 * (2**attempt))
        report["runs"].append(run)
        status = "ok" if run.get("json_valid") and run.get("tool_correct") else "failed"
        print(f"[{index + 1}/{args.iterations}] {scenario['name']}: {status}, {run.get('total_ms', 0):.0f} ms")

    total_times = [float(run["total_ms"]) for run in report["runs"] if "total_ms" in run]
    first_content = [float(run["first_content_ms"]) for run in report["runs"] if run.get("first_content_ms") is not None]
    successful = [run for run in report["runs"] if run.get("json_valid") and run.get("tool_correct")]
    harness_runs = [run["harness_execution"] for run in successful if "harness_execution" in run]
    report["summary"] = {
        "successful": len(successful),
        "failed": args.iterations - len(successful),
        "reliability_percent": round(100 * len(successful) / args.iterations, 2),
        "total_ms_p50": round(statistics.median(total_times), 2) if total_times else None,
        "total_ms_p95": percentile(total_times, 0.95),
        "first_content_ms_p50": round(statistics.median(first_content), 2) if first_content else None,
        "first_content_ms_p95": percentile(first_content, 0.95),
        "harness_execution_ms_p50": (
            round(statistics.median(run["latency_ms"] for run in harness_runs), 2) if harness_runs else None
        ),
        "harness_transport_errors": sum(bool(run.get("is_error")) for run in harness_runs),
    }
    report["finished_at"] = int(time.time())
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report["summary"], indent=2, sort_keys=True))
    print(f"Report: {args.report}")
    return 0 if len(successful) == args.iterations else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RequestFailure, KeyboardInterrupt) as error:
        print(f"benchmark failed: {error}", file=sys.stderr)
        raise SystemExit(2)
