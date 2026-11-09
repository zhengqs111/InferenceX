# Existing-service benchmarks and profiling

**English** | [中文](README_zh.md)

Run from the repository root on a Linux benchmark host or container, with the model service already running.

| Script | Purpose |
|---|---|
| `dump.sh` | Replay data at selected concurrency levels; measure throughput, TTFT, and other metrics |
| `profile.py` | Continuously repeat original requests at fixed concurrency; control profiling manually |
| `profile_ab.sh A\|B` | Repeat greedy or JSON-schema requests against the GLM-5 PD proxy |

## dump.sh: replay and measure

Use the existing benchmark environment. Client dependencies include `pydantic>=2 PyYAML aiohttp numpy tqdm transformers huggingface_hub`.

```bash
export BASE_URL="http://YOUR_SERVICE_OR_PROXY_IP:PORT"  # No /v1
export MODEL="glm53"                                  # --served-model-name
export INPUT="$PWD/benchmarks/manual/requests-16k.jsonl"
export SEQ_LENS="16k1k"
bash benchmarks/manual/dump.sh
```

- Edit `CONCURRENCIES=(1 2 5)` at the top of the script. Values must appear in the YAML scenario's `conc-list`.
- Each point replays the file once, plus warmup. One record means one measured request; `--num-prompts` does not increase dump replay counts.
- `SEQ_LENS` selects a YAML scenario; `16k1k` caps output at 1024 tokens and leaves input text unchanged.
- Match the model, precision, and P/D topology in `existing-service.yaml` to the deployment. They affect labels and per-device metrics, not the deployed service.
- Results: `manual_results/dump-time-suffix/`, containing logs, raw JSON, and `agg_*.json` summaries.

### 8K input / 200K output

The `8k200k` scenario sets `isl: 8192`, `osl: 200000` (not 204800), and `conc-list: [128]`. In `dump.sh`, set `CONCURRENCIES=(128)` and `NUM_WARMUPS=0` to avoid waiting for a 200K-token warmup before measured requests start. Then use your prepared dataset:

```bash
export INPUT="/path/to/your/data.jsonl"
export SEQ_LENS="8k200k"
bash benchmarks/manual/dump.sh
```

Set `BASE_URL` and `MODEL` as above. The client sends `max_tokens=200000` and preserves the original input; it does not truncate or pad prompts to 8192 tokens. To generate to the limit, include `"ignore_eos": true` in each JSONL request and remove other stop conditions. The server must support actual input length plus 200000 tokens. The file needs at least 128 valid requests to reach 128 concurrent requests; dump does not repeat records automatically. The new scenario copies the `8k1k` topology; update its P/D metadata to match your deployment.

Check commands without contacting the service:

```bash
bash benchmarks/manual/dump.sh --skip-health-check --dry-run
```

## profile.py: continuous request replay

Requires Python 3.10+ and `aiohttp`; no tokenizer or YAML:

```bash
python3 -m pip install aiohttp
```

Edit the settings at the top of `profile.py`:

```python
BASE_URL = "http://YOUR_PROXY_IP:PORT"
MODEL = "glm53"
INPUT = Path(__file__).with_name("requests-16k.jsonl")  # Or Path("/absolute/path/data.jsonl")
CONCURRENCY = 1
OUTPUT_TOKENS = 1024
DURATION_SECONDS = 0  # Run until Ctrl+C; for example, 60 dispatches for 60 seconds
```

Set `BASE_URL` to the model service for a single instance or the proxy for PD. The script only sends inference requests: it does not call `/start_profile` or `/stop_profile`, and has no separate warmup stage. Start traffic first and manually enable profiling once load stabilizes.

```bash
python3 benchmarks/manual/profile.py --dry-run  # Validate settings/JSONL without network calls
python3 benchmarks/manual/profile.py            # Repeat continuously; Ctrl+C stops traffic
```

One record repeats continuously; multiple records cycle in order. **The original file is unchanged and no repeated dataset is generated.** Runtime is unlimited by default. With a positive `DURATION_SECONDS`, dispatch stops at the deadline and in-flight requests finish before exit, so total runtime can exceed that value.

Each worker sends its next request immediately after receiving the complete response, with no added sleep. There is no need to configure a sub-millisecond interval. This does not guarantee sub-millisecond dispatch or send one request every millisecond; increase `CONCURRENCY` for more in-flight requests. Concurrency 1 is serial, while 4 allows up to four simultaneous requests.

Ctrl+C cancels client requests and exits; request failures also terminate the run. Exiting does not stop manually enabled profiling. Client cancellation does not guarantee immediate server-side inference cancellation.

Terminal output includes completion counts, per-request latency, and server token usage; it does not produce dump's metric summaries. `IGNORE_EOS=True` asks vLLM to generate to the output limit; use `False` for natural completion.

## GLM-5 grammar A/B profiling

```bash
bash benchmarks/manual/profile_ab.sh A --dry-run
bash benchmarks/manual/profile_ab.sh B --dry-run
bash benchmarks/manual/profile_ab.sh A  # Keep running; Ctrl+C exits.
# Run B separately after finishing A:
bash benchmarks/manual/profile_ab.sh B
```

Defaults: `http://7.150.1.10:12901`, model `glm-5`, concurrency 128, unlimited replay. Each JSONL file contains one original request, repeated without generating duplicate data. Both use `temperature=0`, `max_tokens=1024`, `ignore_eos=true`, and `stream=false`; only B includes `response_format.json_schema`. Responses are consumed but not saved. HTTP/API errors stop the run. The prompts differ, so use this experiment to locate execution paths, not to attribute latency differences solely to grammar.

Override concurrency as needed: `CONCURRENCY=64 bash benchmarks/manual/profile_ab.sh A`. The shared client also accepts `BASE_URL`, `MODEL`, `INPUT`, `OUTPUT_TOKENS`, `DURATION_SECONDS`, and `STREAM` through environment variables; the A/B wrapper selects `INPUT` and forces `STREAM=0`. Client concurrency does not guarantee equal load across DP ranks.

Once traffic is flowing, capture only a short window in another terminal:

```bash
bash benchmarks/manual/start_profile_decoders.sh
sleep 1
bash benchmarks/manual/stop_profile_decoders.sh
```

Check the host/port list in those scripts first. They send control requests without reading HTTP responses; confirm activation in service logs. Alternatively, `bash benchmarks/manual/profile_decoders.sh` captures approximately 0.9 seconds. Trace size depends mainly on the capture window, ranks and profiler options, not how long the client keeps running. Stop profiling before stopping traffic. Before switching A/B, wait for the previous group's server-side requests to finish and retain the profiles separately. Client cancellation does not guarantee immediate server-side cancellation. Inspect the rank that actually receives the requests; it need not be rank30.

## Manual profiling reference

Start and stop profiling yourself, independently of the request loop.

Add this option when starting every vLLM instance to profile:

```bash
--profiler-config '{"profiler":"torch","torch_profiler_dir":"/profiles/prefill","torch_profiler_with_stack":false}'
```

D can use `/profiles/decode`. After stopping, locate `trace_view.json` under the configured directory and open it in MindStudio Insight. Files are on the server/in its container; mount `/profiles` for convenient retrieval. [Official guide](https://docs.vllm.ai/projects/ascend/en/main/developer_guide/performance_and_debug/service_profiling_guide.html)

- Use `--no-enable-prefix-caching` when measuring full prefill to avoid cache hits from repeated input.
- `max-model-len` must fit actual input plus output; “16k” in a filename does not guarantee exactly 16384 tokenizer tokens.
- Concurrency caps client in-flight requests, not per-device batch size. Server `max-num-seqs` and DP routing also affect load.
- Authentication: set `OPENAI_API_KEY`; the script uses it for inference requests.
