# DeepSeek-V4.1-Flash A3 1P1D 压测

[English](README.md) | **中文**

两个脚本调用 `utils/manual_benchmark_existing_service.py`，仅测试已部署的服务，不启动模型。

## 部署与配置对应

配置依据：[vLLM Ascend 部署文档第 5.2 节](https://docs.vllm.ai/projects/ascend/zh-cn/latest/tutorials/models/DeepSeek-V4.1-Flash.html)。以下参数假设实际部署与该示例一致；若部署有改动，请同步修改 YAML 的镜像、精度和拓扑。

| 项目 | P 侧 | D 侧 |
|---|---|---|
| 物理服务器数 | 1 | 1 |
| DP 引擎数 / `num-worker` | 4 | 8 |
| 每个引擎的 `tp` | 4 | 2 |
| `ep` | 16 | 16 |
| `dp-attn` | true | true |
| 逻辑设备数 | 16 | 16 |

EP 按 DP×TP 计算，见 [vLLM EP 文档](https://docs.vllm.ai/en/latest/serving/expert_parallel_deployment/)。`existing-service.yaml` 使用 W8A8、MooncakeHybridConnector。当前 schema 没有 dspark 枚举，因此将其记为通用 `spec-decoding: draft_model`；实际 DSpark 参数由服务端控制。

**1P1D 指物理节点；结果中的 `4P/8D` 指 DP 引擎，不是 12 台机器。** 文档每台 A3 是 8 个物理 NPU、暴露 16 个逻辑设备。本配置自动统计 P=16、D=16，`/GPU` 字段实际按逻辑设备归一化：总吞吐量除以 32，输出吞吐量除以 16，不是每物理 NPU 性能。

## 配置并运行 random

在 Linux、仓库根目录执行。建议使用部署所用的 Python 环境：必须有支持 `deepseek_v41` 的 vLLM，以及 `pydantic>=2 PyYAML aiohttp numpy tqdm transformers huggingface_hub` 等客户端依赖。random 在客户端加载分词器，不加载模型权重。

```bash
export BASE_URL="http://你的Proxy_IP:端口"  # 不带 /v1，不要填单个 P/D 引擎端口
export MODEL="dsv41"                    # 对应 --served-model-name
export MODEL_PATH="/你的模型目录"        # 客户端可访问，含 V4.1 配套 tokenizer 文件

# 服务开启鉴权时才需要设置；未开启时不要保留其他服务的旧 key
# read -rsp 'API key: ' OPENAI_API_KEY; export OPENAI_API_KEY

bash benchmarks/manual/random.sh
```

也可直接修改 `random.sh` 开头对应变量。`TOKENIZER` 默认等于 `MODEL_PATH`，分词器单独存放时用 `export TOKENIZER=/分词器目录`。文档服务名为 `dsv41`；若部署时改过，填写实际名称。

脚本中其余参数：

- `SEQ_LENS=1k1k`：输入目标 1024、输出上限 1024；改为 `8k1k` 则为 8192/1024。服务端聊天封装可能增加实际输入 token。
- `CONCURRENCIES=(1 2 5)`：每档同时在途请求数上限；新增档位也要更新 YAML 两处 `conc-list`。
- `NUM_PROMPTS=10`：每档 10 条正式请求；`NUM_WARMUPS=1`：额外 1 条预热。这是小规模测试，不能代表服务的饱和吞吐量。
- `REQUEST_RATE=inf`：不额外限速；`COOLDOWN_SECONDS=0`：默认不等待，有限流时自行增加。

仅检查命令、不调用服务：

```bash
bash benchmarks/manual/random.sh --skip-health-check --dry-run
```

## dump

沿用 BASE_URL、MODEL；不需要本地 tokenizer。JSONL 每行一个请求体（见 `requests.example.jsonl`），包含 `messages` 和 `stream_options.include_usage=true`；去掉日志外壳及冲突的 `max_completion_tokens`。每档回放所有有效行，10 条请求就准备 10 行；默认只有 2 条示例。

```bash
export INPUT="/你的数据/requests.jsonl"
bash benchmarks/manual/dump.sh
```

dump 的输入取文件实际内容，输出上限取 SEQ_LENS 对应的 OSL。两个脚本依次运行。

## 结果

仓库根目录 `manual_results/random-时间-后缀/` 或 `manual_results/dump-时间-后缀/`：

- `random_c1.log` / `dump_c1.log`：日志和自动汇总表，其他档位对应 c2、c5。
- `manual_*conc1*.json`：原始结果，先看 completed、num_prompts、errors，再看 output_throughput、mean_ttft_ms、mean_e2el_ms。
- `agg_manual_*conc1*.json`：自动汇总结果，无需另写脚本。

dry-run 只有命令日志，不生成统计 JSON。结果目录已被 Git 忽略。
