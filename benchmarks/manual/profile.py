#!/usr/bin/env python3
"""Continuously replay JSONL requests; profiling is controlled manually."""

import asyncio
import itertools
import json
import os
from pathlib import Path
import sys
import time

import aiohttp

# 只需修改这一区域；BASE_URL 不带 /v1，MODEL 对应 --served-model-name。
BASE_URL = "http://127.0.0.1:8000"  # PD 部署填写 Proxy 地址。
MODEL = "glm53"
INPUT = Path(__file__).with_name("requests-16k.jsonl")
CONCURRENCY = 1
OUTPUT_TOKENS = 1024
DURATION_SECONDS = 0  # 0：持续发送直到 Ctrl+C；正数：到时不再发新请求。
# 每个并发任务收到完整响应后立即发下一条，不额外 sleep。
IGNORE_EOS = True  # vLLM：忽略 EOS，生成到 OUTPUT_TOKENS 上限。
REQUEST_TIMEOUT_SECONDS = 600
API_KEY = os.environ.get("OPENAI_API_KEY", "")


def load_payloads():
    if CONCURRENCY < 1 or OUTPUT_TOKENS < 1 or REQUEST_TIMEOUT_SECONDS <= 0:
        raise ValueError("并发、输出长度、超时必须大于 0")
    if DURATION_SECONDS < 0:
        raise ValueError("持续时间不能为负数；0 表示持续发送直到 Ctrl+C")
    if not BASE_URL.startswith(("http://", "https://")):
        raise ValueError(f"需要完整 HTTP 地址：{BASE_URL}")
    if BASE_URL.rstrip("/").endswith("/v1"):
        raise ValueError(f"地址不要带 /v1：{BASE_URL}")
    payloads = []
    for number, line in enumerate(Path(INPUT).read_text(encoding="utf-8-sig").splitlines(), 1):
        if not line.strip():
            continue
        payload = json.loads(line)
        if not isinstance(payload, dict) or not isinstance(payload.get("messages"), list) or not payload["messages"]:
            raise ValueError(f"第 {number} 行必须是包含非空 messages 的请求对象")
        payload.pop("max_completion_tokens", None)
        payload.update(model=MODEL, max_tokens=OUTPUT_TOKENS, stream=True,
                       stream_options={"include_usage": True}, ignore_eos=IGNORE_EOS)
        payloads.append(payload)
    if not payloads:
        raise ValueError("数据集没有请求")
    return payloads


async def send_request(session, payload):
    started = time.monotonic()
    done = False
    usage = None
    async with session.post(BASE_URL.rstrip("/") + "/v1/chat/completions", json=payload) as response:
        if response.status != 200:
            raise RuntimeError(f"HTTP {response.status}: {(await response.text())[:1000]}")
        # aiohttp 按行读取 SSE，不把网络分块当成完整 JSON。
        async for line in response.content:
            line = line.decode("utf-8").strip()
            if not line.startswith("data:"):
                continue
            data = line[5:].strip()
            if data == "[DONE]":
                done = True
                break
            chunk = json.loads(data)
            if "error" in chunk:
                raise RuntimeError(str(chunk["error"]))
            if chunk.get("usage"):
                usage = chunk["usage"]
    if not done:
        raise RuntimeError("响应提前结束，未收到 SSE [DONE]")
    return time.monotonic() - started, usage


async def run(payloads):
    headers = {"Authorization": f"Bearer {API_KEY}"} if API_KEY else {}
    timeout = aiohttp.ClientTimeout(total=REQUEST_TIMEOUT_SECONDS)
    completed = 0
    connector = aiohttp.TCPConnector(limit=CONCURRENCY)
    async with aiohttp.ClientSession(headers=headers, timeout=timeout,
                                     connector=connector, trust_env=True) as session:
        requests = itertools.cycle(payloads)
        deadline = time.monotonic() + DURATION_SECONDS if DURATION_SECONDS else float("inf")

        async def worker():
            nonlocal completed
            while time.monotonic() < deadline:
                latency, usage = await send_request(session, next(requests))
                completed += 1
                print(f"完成 {completed} 条 | 耗时 {latency:.2f}s | usage={usage}", flush=True)

        workers = [asyncio.create_task(worker()) for _ in range(CONCURRENCY)]
        try:
            await asyncio.gather(*workers)
        finally:
            # Ctrl+C / 请求失败时回收客户端任务；不操作服务端 profiler。
            for task in workers:
                task.cancel()
            await asyncio.gather(*workers, return_exceptions=True)
            print(f"结束，完成 {completed} 条请求。", flush=True)


if __name__ == "__main__":
    try:
        payloads = load_payloads()
        duration = f"{DURATION_SECONDS}s" if DURATION_SECONDS else "持续发送直到 Ctrl+C"
        print(f"数据集：{INPUT}，{len(payloads)} 条循环回放，不修改文件\n"
              f"服务：{BASE_URL}，模型：{MODEL}，并发：{CONCURRENCY}\n"
              f"发压时间：{duration}，输出上限：{OUTPUT_TOKENS}\n"
              "请求完成后立即发送下一条；Profile 由你手动控制。", flush=True)
        if sys.argv[1:] == ["--dry-run"]:
            print("配置与 JSONL 检查通过，未发送请求。")
        elif sys.argv[1:]:
            raise ValueError("只支持 --dry-run；其他参数请修改脚本开头")
        else:
            asyncio.run(run(payloads))
    except KeyboardInterrupt:
        print("已中断。", file=sys.stderr)
        sys.exit(130)
    except Exception as exc:
        print(f"错误：{exc}", file=sys.stderr)
        sys.exit(1)
