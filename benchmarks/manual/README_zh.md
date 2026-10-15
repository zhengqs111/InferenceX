# 已有服务压测与 Profile

[English](README.md) | **中文**

在 Linux 压测机或容器的仓库根目录执行，模型服务需提前启动。

| 脚本 | 用途 |
|---|---|
| `dump.sh` | 按并发档位回放数据，统计吞吐、TTFT 等指标 |
| `profile.py` | 按指定并发持续循环发送原始数据；Profile 由你手动控制 |

## dump.sh：回放并统计

使用已有压测环境，客户端依赖包括 `pydantic>=2 PyYAML aiohttp numpy tqdm transformers huggingface_hub`。

```bash
export BASE_URL="http://你的服务或Proxy_IP:端口"  # 不带 /v1
export MODEL="glm53"                          # --served-model-name
export INPUT="$PWD/benchmarks/manual/requests-16k.jsonl"
export SEQ_LENS="16k1k"
bash benchmarks/manual/dump.sh
```

- 并发：修改脚本开头的 `CONCURRENCIES=(1 2 5)`，对应档位必须在 YAML 的 `conc-list` 中。
- 每档回放文件一遍，另加预热；一行数据只正式发送一次。`--num-prompts` 不增加 dump 回放次数。
- `SEQ_LENS` 选择 YAML 场景；`16k1k` 输出上限为 1024，输入原文不裁剪。
- `existing-service.yaml` 的模型、精度、P/D 拓扑应与实际服务一致，影响标签和每卡统计，不改变部署。
- 结果：`manual_results/dump-时间-后缀/`，包含日志、原始 JSON、`agg_*.json` 汇总。

只检查命令、不请求服务：

```bash
bash benchmarks/manual/dump.sh --skip-health-check --dry-run
```

## profile.py：持续循环压测

需要 Python 3.10+ 和 `aiohttp`，不需要 tokenizer 或 YAML：

```bash
python3 -m pip install aiohttp
```

修改 `profile.py` 开头的配置：

```python
BASE_URL = "http://你的Proxy_IP:端口"
MODEL = "glm53"
INPUT = Path(__file__).with_name("requests-16k.jsonl")  # 或 Path("/绝对路径/data.jsonl")
CONCURRENCY = 1
OUTPUT_TOKENS = 1024
DURATION_SECONDS = 0  # 持续发送直到 Ctrl+C；例如 60 表示发压 60 秒
```

单机的 `BASE_URL` 填模型服务地址；PD 填 Proxy 地址。脚本只发送推理请求，不调用 `/start_profile` 或 `/stop_profile`，也没有单独的预热阶段。你可以先运行脚本，待负载稳定后自行开始采集。

```bash
python3 benchmarks/manual/profile.py --dry-run  # 检查配置和 JSONL，不请求服务
python3 benchmarks/manual/profile.py            # 持续循环发压，Ctrl+C 停止
```

一条数据就重复这一条，多条就按顺序循环；**不改原文件，不生成重复数据集**。默认不限时。将 `DURATION_SECONDS` 设为正数时，到时不再发新请求，等待在途请求结束，因此总时长可能超过设置值。

每个并发任务在收到完整响应后立即发下一条，不额外等待，无需设置小于 1ms 的间隔。这不保证实际发送间隔小于 1ms，也不是每毫秒发一条；需要更多在途请求就提高 `CONCURRENCY`。例如并发为 1 时始终串行，为 4 时最多同时 4 条。

Ctrl+C 取消客户端请求并退出；请求失败也会结束本次压测。脚本退出不会停止你手动开启的采集。客户端取消不保证服务端立即停止推理。

终端输出完成数、单请求耗时和服务端 token usage；不生成 dump 的统计汇总。`IGNORE_EOS=True` 让 vLLM 跑到输出上限；需要自然结束则改为 `False`。

## 手动采集参考

采集的启动、停止由你操作，与循环压测脚本独立。

每个需要采集的 vLLM 实例在启动时添加：

```bash
--profiler-config '{"profiler":"torch","torch_profiler_dir":"/profiles/prefill","torch_profiler_with_stack":false}'
```

D 节点可用 `/profiles/decode`。停止采集后在对应目录寻找 `trace_view.json`，用 MindStudio Insight 打开。数据位于服务端/容器内，容器可挂载 `/profiles` 方便取出。[官方说明](https://docs.vllm.ai/projects/ascend/en/main/developer_guide/performance_and_debug/service_profiling_guide.html)

- 测完整 Prefill 时使用 `--no-enable-prefix-caching`，避免重复输入命中缓存。
- `max-model-len` 要容纳实际输入加输出；文件名“16k”不保证分词后恰好 16384 tokens。
- 并发是客户端在途请求上限，不等于每卡 batch；服务端 `max-num-seqs`、DP 路由也影响实际负载。
- 鉴权：提前设置 `OPENAI_API_KEY`，脚本将其用于推理请求。
