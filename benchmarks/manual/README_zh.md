# 已有服务压测与 Profile

[English](README.md) | **中文**

在 Linux 压测机或容器的仓库根目录执行，模型服务需提前启动。

| 脚本 | 用途 |
|---|---|
| `dump.sh` | 按并发档位回放数据，统计吞吐、TTFT 等指标 |
| `profile.py` | 按指定并发持续循环发送原始数据；Profile 由你手动控制 |
| `profile_ab.sh A\|B` | 向 GLM-5 PD Proxy 循环发送 greedy 或 JSON schema 请求 |

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

### 8K 输入 / 200K 输出

`8k200k` 场景配置为 `isl: 8192`、`osl: 200000`（不是 204800）、`conc-list: [128]`。在 `dump.sh` 中设置 `CONCURRENCIES=(128)`、`NUM_WARMUPS=0`，避免正式发压前先等待一条 200K 输出的预热请求完成。然后指定你准备好的数据集：

```bash
export INPUT="/你的数据集路径/data.jsonl"
export SEQ_LENS="8k200k"
bash benchmarks/manual/dump.sh
```

按上面的示例设置 `BASE_URL` 和 `MODEL`。客户端发送 `max_tokens=200000`，保留原始输入，不会裁剪或补齐到 8192 tokens。若要生成到输出上限，每条 JSONL 请求需包含 `"ignore_eos": true`，并移除其他停止条件。服务端必须支持实际输入长度加 200000 tokens。文件至少需要 128 条有效请求才可能达到 128 并发；dump 不会自动重复数据。新增场景沿用 `8k1k` 的拓扑，请按实际部署修改 P/D 元数据。

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

## GLM-5 grammar A/B 采集

```bash
bash benchmarks/manual/profile_ab.sh A --dry-run
bash benchmarks/manual/profile_ab.sh B --dry-run
bash benchmarks/manual/profile_ab.sh A  # 持续发送，Ctrl+C 退出。
# 完成 A 组后，再单独运行 B 组：
bash benchmarks/manual/profile_ab.sh B
```

默认地址 `http://7.150.1.10:12901`，模型 `glm-5`，并发 128，不限时循环回放。每份 JSONL 保存一条原始请求，循环发送，不生成重复数据。两组均为 `temperature=0`、`max_tokens=1024`、`ignore_eos=true`、`stream=false`，仅 B 组带 `response_format.json_schema`。读取响应但不保存正文；HTTP/API 错误会结束压测。两组提示词不同，因此用于定位执行路径，不应仅凭耗时差异归因于 grammar。

调整并发：`CONCURRENCY=64 bash benchmarks/manual/profile_ab.sh A`。共用客户端也支持通过环境变量设置 `BASE_URL`、`MODEL`、`INPUT`、`OUTPUT_TOKENS`、`DURATION_SECONDS`、`STREAM`；A/B 入口会自行选择 `INPUT` 并固定 `STREAM=0`。客户端并发不保证各 DP rank 均匀分配。

请求持续执行后，在另一个终端只采集一个短窗口：

```bash
bash benchmarks/manual/start_profile_decoders.sh
sleep 1
bash benchmarks/manual/stop_profile_decoders.sh
```

先核对两个脚本中的主机和端口列表。它们只发送控制请求、不读取 HTTP 响应，需要通过服务日志确认采集生效。也可以直接运行 `bash benchmarks/manual/profile_decoders.sh`，采集约 0.9 秒。文件大小主要由采集窗口、rank 数和 profiler 选项决定，不由客户端持续运行时长决定。先停止采集，再停止发压；切换 A/B 前等待前一组服务端在途请求结束，分别保留两组 profile。客户端取消不保证服务端立即取消。检查实际接收请求的 rank，不要求必须是 rank30。

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
