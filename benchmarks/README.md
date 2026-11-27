# Raw Memory Benchmark Suite

This directory integrates a **3-Tier Fixed Regression & Public Academic Benchmark** system for Raw Memory:

1. **Tier 1 · Frozen `RawMemory-Bench v1.0`** ([suites/rawmemory_bench_v1.json](suites/rawmemory_bench_v1.json), SHA-256 locked in [manifest.json](manifest.json)): 32 deterministic tests across 9 core Agent-memory pillars (Cold-Start, Correction Avoidance, 3-Step Supersession, Cross-Channel Fusion, Cross-Project Isolation, Prompt-Injection Memory Poisoning Defense & Cascade Deletion, Ephemeral TTL & Non-Overgeneralization, Privacy/Vault Boundary, and Prompt-Cache Stable Prefix Determinism).
2. **Tier 2 · Private `Personal Golden Set`** (`~/.local/share/context-hub-v2/eval/personal_bench_v1.json`, strictly outside Git): read-only regression suite run live against the owner's local `HubStore`, checking real-world recall, zero stale leakage, and zero raw PII exposure.
3. **Tier 3 · Public Academic & Reflexive Suites**: **LongMemEval-S** (ICLR 2025), **LongMemEval-Oracle** (ICLR 2025), **LoCoMo** (ACL 2024), **ConvoMem** + 5-Stage **MemoryBench E2E Judge (`MemScore`)**, and **Reflexive Meta Benchmark (RFC-0003)**.

All evaluations run deterministically against genuine `HubStore` SQLite FTS5 + optional local `fastembed` ONNX (`BAAI/bge-small-en-v1.5`, 384-d) vector indices—**zero cloud embedding APIs, zero GPU required, zero mocked stores**.

---

## 1. Integrated Suites

| Tier & Suite | Source & Venue | Scale | What It Tests |
| :--- | :--- | :--- | :--- |
| **Tier 1 · `RawMemory-Bench v1.0`** | Frozen Bundled (`SHA-256` locked) | 32 cases × 9 pillars | Isolation, poisoning trust gate, cascade delete, TTL expiry, Vault boundary, Prompt-Cache stability |
| **Tier 2 · `Personal Golden Set`** | Local Private (Outside Git) | Owner-maintained queries | Live personal recall, anti-stale, zero raw PII leakage |
| **Tier 3 · [LongMemEval-S](https://github.com/xiaowu0162/LongMemEval)** | ICLR 2025 (UCLA / Tencent AI Lab) | 500 Qs × ~48 sessions (246,750 turns) | Full haystack retrieval across 6 pillars + 30 `_abs` abstention traps |
| **Tier 3 · [LongMemEval-Oracle](https://github.com/xiaowu0162/LongMemEval)** | ICLR 2025 (Cleaned) | 500 Qs (evidence sessions only) | Turn-level pinpointing precision across all 6 memory pillars |
| **Tier 3 · [LoCoMo](https://github.com/snap-research/locomo)** | ACL 2024 (Snap Research / UNC) | 10 dialogues, 5,882 turns, 1,986 QAs | Multi-session recall (`single_hop`, `temporal`, `open_domain`, `multi_hop`, `adversarial`); **L1 Raw** vs **L1+L2+L3 Curated** |
| **Tier 3 · `ConvoMem` + 5-Stage E2E** | ConvoMem / MemoryBench schema | 12 bundled smoke cases × 6 categories | `user_facts`, `assistant_facts`, `changing_facts`, `preferences`, `implicit_connections`, `abstention` + `MemScore` |
| **Tier 3 · [Reflexive Meta](../docs/rfc/0003-meta-memory-benchmark.md)** | Raw Memory (Bundled) | 18 causal $H_{<t}$ cases + 5-gen anti-echo | Causal time-travel isolation, bi-temporal truth, 5-generation hallucination/echo resistance |

---

## 2. Reproducible Progression: `v0.2.0` → `v0.3.0` (BM25+RRF) → `v0.5.0` (Hybrid BM25 + Local Semantic RRF)

### A. LongMemEval-S (470 scored + 30 `_abs`, ~115k tokens / ~48 sessions per question)

| Engine | Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | `_abs` R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 3.2% | 1.7% | 2.6% | 0.0% | 0.0% | 0.0% | 3.3% |
| `v0.3.0` (Hybrid BM25 + RRF) | 80.6% | 96.6% | 98.5% | 85.3% | 86.1% | 77.0% | 86.2% | 55.4% | 96.7% |
| **`v0.5.0` (BM25 + Local Semantic RRF)** | **86.2%** (+5.6) | **97.7%** (+1.1) | **98.7%** | **87.2%** (+1.9) | **90.0%** (+3.9) | **85.1%** (+8.1) | **92.8%** (+6.6) | **58.2%** (+2.8) | **100.0%** |

Per-pillar jump on LongMemEval-S (`v0.3.0 BM25` → `v0.5.0 Hybrid BM25 + Semantic`, full report: [longmemeval_s.md](results/longmemeval_s.md)):

| Official Pillar | N | Sess R@1 | Sess R@5 | Sess NDCG@5 | Turn R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `single-session-preference` | 30 | `43.3%` → **76.7%** (**+33.4**) | `83.3%` → **90.0%** (+6.7) | `63.6%` → **84.3%** (**+20.7**) | `40.0%` → **70.0%** (**+30.0**) |
| `multi-session` | 121 | `85.1%` → **90.9%** (+5.8) | `98.4%` → **100.0%** (+1.6) | `85.5%` → **89.8%** (+4.3) | `76.9%` → **87.6%** (+10.7) |
| `temporal-reasoning` | 127 | `77.2%` → **81.1%** (+3.9) | `92.9%` → **93.7%** (+0.8) | `80.7%` → **83.9%** (+3.2) | `71.7%` → **80.3%** (+8.6) |
| `single-session-user` | 64 | `75.0%` → **79.7%** (+4.7) | **100.0%** | `89.6%` → **91.9%** (+2.3) | `82.8%` → **87.5%** (+4.7) |
| `single-session-assistant` | 56 | `87.5%` → **89.3%** (+1.8) | **100.0%** | `94.7%` → **95.8%** (+1.1) | **87.5%** |
| `knowledge-update` | 72 | **94.4%** | **100.0%** | `96.0%` → **97.0%** (+1.0) | `88.9%` → **91.7%** (+2.8) |

### B. LongMemEval-Oracle (470 scored + 30 `_abs`, evidence sessions only)

| Engine | Sess R@1 | Sess R@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | `preference` Turn R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 0.0% | 0.0% | 0.0% | 0.0% |
| `v0.3.0` (Hybrid BM25) | 100.0% | 100.0% | 84.3% | 93.0% | 61.4% | 53.3% |
| **`v0.5.0` (BM25 + Local Semantic RRF)** | **100.0%** | **100.0%** | **91.3%** (+7.0) | **97.2%** (+4.2) | **64.2%** (+2.8) | **86.7%** (+33.4) |

Full report: [longmemeval_oracle.md](results/longmemeval_oracle.md).

### C. LoCoMo (10 conversations, 1,982 scored / 1,986 total QA pairs)

| Engine & Mode | R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | MRR | Ans-Cov@10 | `open_domain` R@10 | p50 Latency |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` Raw / Curated | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.0% | 0.06 ms |
| `v0.3.0` L1 Raw (BM25) | 37.0% | 61.7% | 69.6% | 52.7% | 60.0% | 47.3% | 47.5% | 54.3% | 41.3% | 0.96 ms |
| `v0.3.0` Curated (BM25) | 34.2% | 61.3% | 72.5% | 50.9% | 61.5% | 45.4% | 46.2% | 56.1% | 47.8% | 2.04 ms |
| `v0.5.0` L1 Raw + Semantic | 33.7% | 64.1% | 76.5% | 54.3% | **66.8%** | 46.9% | 46.9% | 59.3% | 53.3% | 19.04 ms |
| **`v0.5.0` Curated + Semantic** | **35.5%** | **67.1%** | **77.0%** | **56.5%** | 66.1% | **49.2%** | **49.3%** | **59.9%** | **58.7%** (+10.9) | **8.44 ms** |

Full reports: [locomo10_raw.md](results/locomo10_raw.md), [locomo10_curated.md](results/locomo10_curated.md).

### D. Tier 1 Frozen `RawMemory-Bench v1.0` (32 Cases × 9 Pillars, SHA-256 Locked)

| Metric | `v0.5.0` Score |
| :--- | ---: |
| Overall Pass Rate (all 9 pillars) | **100.0%** (`32/32`) |
| Stale Leakage Rate | **0.0%** |
| Cross-Project Bleed Count | **0** |
| Privacy / Vault Raw Leak Count | **0** |
| Prompt-Injection Poisoning Block Rate | **100.0%** |
| Ephemeral TTL Expiry Pass Rate | **100.0%** |
| Prompt-Cache Stable Prefix Ratio | **68.7%** (byte-identical across queries) |

Full report: [rawmemory_bench_v1.md](results/rawmemory_bench_v1.md).

### E. ConvoMem Smoke + 5-Stage E2E `MemScore` & Reflexive Meta Benchmark

- **ConvoMem Smoke (Hybrid Semantic)**: `Sess R@5 = 100.0%`, `Ans-Cov@5 = 100.0%`, `Sess R@1 = 90.0%`, `Sess NDCG@5 = 96.3%` ([convomem_smoke.md](results/convomem_smoke.md)).
- **5-Stage E2E `MemScore` (Offline Extractive Judge)**: `retrieval_recall@5 = 100.0%`, `abstention_accuracy = 100.0%`, `evidence_grounding = 100.0%`, `answer_accuracy = 83.3%` ([convomem_e2e_memscore.json](results/convomem_e2e_memscore.json)). Set `OPENAI_API_KEY` (or `RAW_MEMORY_JUDGE_API_KEY` + `RAW_MEMORY_JUDGE_BASE_URL`) to enable LLM-as-a-Judge.
- **Reflexive Meta Benchmark (RFC-0003)**: `hub_v2_curated` **100.0%** Fact Recall, **100.0%** Truth Accuracy, **0.0%** Stale Leakage (vs `flat_memory_md` 83.3% stale), **PASS** 5-gen Anti-Echo ([reflexive_meta.md](results/reflexive_meta.md)).

---

## 3. Reproduce Locally & Interactive Workbench

```bash
# Install with optional local semantic embedding extra (ONNX fastembed, no PyTorch/GPU)
uv sync --extra dev --extra semantic

# 1. Run Tier 1 Frozen RawMemory-Bench v1.0 (SHA-256 verified)
uv run raw-memory-eval bench-frozen

# 2. Run Tier 2 Private Personal Golden Set (~/.local/share/context-hub-v2/eval/personal_bench_v1.json)
uv run raw-memory-eval bench-personal

# 3. Run Tier 3 Public Academic Benchmarks (add --semantic for Hybrid BM25+Semantic RRF)
uv run raw-memory-eval bench download --suite all
uv run raw-memory-eval bench run --suite locomo --mode curated --semantic
uv run raw-memory-eval bench run --suite longmemeval-oracle --semantic
uv run raw-memory-eval bench run --suite longmemeval-s --semantic
uv run raw-memory-eval bench run --suite convomem-smoke --semantic
uv run raw-memory-eval bench-e2e --semantic

# 4. Run Reflexive Meta Benchmark (H_<t + 5-gen anti-echo)
uv run raw-memory-eval run

# 5. Launch Localhost Workbench (with one-click Frozen & Personal regression buttons)
uv run raw-memory-eval workbench --port 8765
```
