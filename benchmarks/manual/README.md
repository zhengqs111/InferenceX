# DeepSeek-V4.1-Flash A3 1P1D benchmarks

**English** | [中文](README_zh.md)

Both scripts call `utils/manual_benchmark_existing_service.py` against an existing service; they do not launch models.

## Deployment mapping

Based on [section 5.2 of the Ascend deployment guide](https://docs.vllm.ai/projects/ascend/zh-cn/latest/tutorials/models/DeepSeek-V4.1-Flash.html). These settings assume the documented deployment; update YAML image, precision, and topology if your deployment differs.

| Setting | Prefill | Decode |
|---|---|---|
| Physical servers | 1 | 1 |
| DP engines / num-worker | 4 | 8 |
| TP per engine | 4 | 2 |
| EP | 16 | 16 |
| dp-attn | true | true |
| Logical devices | 16 | 16 |

EP follows DP×TP; see [vLLM EP documentation](https://docs.vllm.ai/en/latest/serving/expert_parallel_deployment/). The YAML records W8A8 and MooncakeHybridConnector. The schema lacks a dspark enum, so DSpark uses the generic `spec-decoding: draft_model` category; actual speculation remains server-controlled.

**1P1D counts physical nodes; the summary's 4P/8D counts DP engines, not 12 servers.** The guide exposes 16 logical devices from 8 physical NPUs per A3. This configuration counts P=16 and D=16. `/GPU` fields are per logical device: total throughput divided by 32, output throughput divided by 16, not per physical NPU.

## Configure and run random

Run from the repository root in Linux. Use the deployment's Python environment with vLLM supporting `deepseek_v41`, plus client dependencies including `pydantic>=2 PyYAML aiohttp numpy tqdm transformers huggingface_hub`. Random generation loads the tokenizer, not model weights.

```bash
export BASE_URL="http://YOUR_PROXY_IP:PORT"  # No /v1; not an individual P/D engine
export MODEL="dsv41"                      # Matches --served-model-name
export MODEL_PATH="/your/model/directory"  # Client-accessible V4.1 tokenizer files

# Only if authentication is enabled; avoid an old key from another service
# read -rsp 'API key: ' OPENAI_API_KEY; export OPENAI_API_KEY

bash benchmarks/manual/random.sh
```

Alternatively edit the variables at the top of random.sh. TOKENIZER defaults to MODEL_PATH; override with `export TOKENIZER=/tokenizer/directory` if stored separately. The guide uses dsv41; change MODEL if your served name differs.

Other script parameters:

- `SEQ_LENS=1k1k`: 1024 target input / 1024 output limit; `8k1k` selects 8192/1024. Server chat formatting may add input tokens.
- `CONCURRENCIES=(1 2 5)`: maximum in-flight requests per point. Add new points to both YAML conc-list entries too.
- `NUM_PROMPTS=10`: measured requests per point; `NUM_WARMUPS=1`: one additional warmup. This small test does not establish saturation throughput.
- `REQUEST_RATE=inf`: no extra arrival-rate limit; `COOLDOWN_SECONDS=0`: no wait by default; increase for rate-limited services.

Validate commands without calling the service:

```bash
bash benchmarks/manual/random.sh --skip-health-check --dry-run
```

## Dump

Reuse BASE_URL and MODEL; no local tokenizer is needed. Each JSONL line is one request body, as in requests.example.jsonl, including messages and stream_options.include_usage=true. Remove logging wrappers and conflicting max_completion_tokens. Every valid line is replayed per point: use 10 lines for 10 requests; the default sample has only 2.

```bash
export INPUT="/your/data/requests.jsonl"
bash benchmarks/manual/dump.sh
```

Dump keeps actual input content and takes the output limit from SEQ_LENS. Run the two scripts sequentially.

## Results

Under repository-root manual_results/random-time-suffix/ or manual_results/dump-time-suffix/:

- random_c1.log / dump_c1.log: logs and automatic summary; other points use c2 and c5.
- manual_*conc1*.json: raw results. Check completed, num_prompts, errors, then output_throughput, mean_ttft_ms, mean_e2el_ms.
- agg_manual_*conc1*.json: automatic aggregation; no separate script needed.

Dry runs produce command logs, not statistics JSON. Git ignores the results directory.
