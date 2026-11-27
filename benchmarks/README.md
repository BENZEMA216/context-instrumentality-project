# Raw Memory Benchmark Suite

This directory integrates a **3-Tier Fixed Regression & Public Academic Benchmark** system for Raw Memory:

1. **Tier 1 · Frozen `RawMemory-Bench v1.0`** ([suites/rawmemory_bench_v1.json](suites/rawmemory_bench_v1.json), SHA-256 locked in [manifest.json](manifest.json)): 32 deterministic tests across 9 core Agent-memory pillars (Cold-Start, Correction Avoidance, 3-Step Supersession, Cross-Channel Fusion, Cross-Project Isolation, Prompt-Injection Memory Poisoning Defense & Cascade Deletion, Ephemeral TTL & Non-Overgeneralization, Privacy/Vault Boundary, and Prompt-Cache Stable Prefix Determinism).
2. **Tier 2 · Private `Personal Golden Set`** (`~/.local/share/context-hub-v2/eval/personal_bench_v1.json`, strictly outside Git): read-only regression suite run live against the owner's local `HubStore`, checking real-world recall, zero stale leakage, and zero raw PII exposure.
3. **Tier 3 · Public Academic & Reflexive Suites**: **LongMemEval-S** (ICLR 2025), **LongMemEval-Oracle** (ICLR 2025), **LoCoMo** (ACL 2024), **ConvoMem** + 5-Stage **MemoryBench E2E Judge (`MemScore`)**, and **Reflexive Meta Benchmark (RFC-0003)**.

All evaluations run deterministically against genuine `HubStore` SQLite FTS5 + local `fastembed` ONNX (`BAAI/bge-small-en-v1.5`, 384-d) + local ONNX Cross-Encoder (`Xenova/ms-marco-MiniLM-L-6-v2`, 82 MB)—**100% local on CPU, zero cloud LLM / embedding APIs, zero GPU, zero mocked stores**.

---

## 1. Reproducible 4-Generation Progression (`v0.2.0` → `v0.3.0` → `v0.5.0` → `v0.6.0`)

- **`v0.2.0`**: Strict-AND FTS5 baseline.
- **`v0.3.0`**: Stopword-aware two-stage `AND → BM25 OR` + Cross-tier Episode↔Turn RRF (`~2 ms`).
- **`v0.5.0`**: Hybrid BM25 + Local `fastembed` ONNX single-vector Semantic RRF (`~6–9 ms` warm).
- **`v0.6.0`**: **Multi-Chunk Topic-Preserving Episode MaxSim** + **Bilingual (EN/ZH) Temporal Window Parser & Soft Gaussian RRF** + **Deduplicated Cross-Tier Fusion** + **Contextualized `±1` Dialogue Turn Windows** + **Local ONNX Cross-Encoder Reranking**.

### A. LongMemEval-S (ICLR 2025 · 470 scored + 30 `_abs`, ~115k tokens / ~48 sessions / 246,750 turns)

| Engine | Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | `_abs` R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 3.2% | 1.7% | 2.6% | 0.0% | 0.0% | 0.0% | 3.3% |
| `v0.3.0` (BM25 + RRF) | 80.6% | 96.6% | 98.5% | 85.3% | 86.1% | 77.0% | 86.2% | 55.4% | 96.7% |
| `v0.5.0` (BM25 + Semantic RRF) | 86.2% | 97.7% | 98.7% | 87.2% | 90.0% | 85.1% | 92.8% | 58.2% | 100.0% |
| **`v0.6.0` (MaxSim + Temporal + Rerank)** | **93.8%** (+7.6) | **98.5%** (463/470) | **98.9%** | **90.8%** (+3.6) | **94.3%** (+4.3) | **91.9%** (+6.8) | **96.2%** (+3.4) | **68.7%** (+10.5) | **100.0%** |

Per-pillar breakdown (`v0.6.0`, full report: [longmemeval_s.md](results/longmemeval_s.md)):

| Official Pillar | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `single-session-assistant` | 56 | **100.0%** | **100.0%** | **100.0%** | **100.0%** | 91.1% | 76.1% |
| `single-session-user` | 64 | **95.3%** | **100.0%** | **100.0%** | **98.1%** | **96.9%** | **88.5%** |
| `knowledge-update` | 72 | **97.2%** | **100.0%** | 98.6% | **98.4%** | **95.8%** | 75.9% |
| `multi-session` | 121 | **95.0%** | **100.0%** | **86.0%** (+10.0) | **93.8%** | **95.0%** | 62.4% |
| `temporal-reasoning` | 127 | **90.5%** (+9.4) | **96.9%** (+3.2) | **82.7%** (+4.0) | **90.1%** (+6.2) | **86.6%** (+6.3) | 60.7% |
| `single-session-preference` | 30 | **80.0%** | **90.0%** | **90.0%** | **85.6%** | **83.3%** (+13.3) | 54.6% |

### B. LongMemEval-Oracle (ICLR 2025 · 470 scored + 30 `_abs`, evidence sessions only)

| Engine | Sess R@1 | Sess R@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | `preference` Turn R@5 | `knowledge-update` Turn R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% |
| `v0.3.0` (BM25 + RRF) | 100.0% | 100.0% | 84.3% | 93.0% | 61.4% | 53.3% | 88.9% |
| `v0.5.0` (BM25 + Semantic RRF) | 100.0% | 100.0% | 91.3% | 97.2% | 64.2% | 86.7% | 93.1% |
| **`v0.6.0` (MaxSim + Temporal + Rerank)** | **100.0%** | **100.0%** | **94.0%** (+2.7) | **98.3%** | **73.0%** (+8.8) | **96.7%** (+10.0) | **100.0%** (+6.9) |

Full report: [longmemeval_oracle.md](results/longmemeval_oracle.md).

### C. LoCoMo (ACL 2024 · 10 dialogues, 5,882 turns, 1,982 scored QA pairs)

| Engine & Mode | R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | MRR | Ans-Cov@5 | Ans-Cov@10 | `open_domain` R@10 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` Raw / Curated | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.0% |
| `v0.3.0` Curated (BM25) | 34.2% | 61.3% | 72.5% | 50.9% | 61.5% | 45.4% | 46.2% | 45.2% | 56.1% | 47.8% |
| `v0.5.0` Curated + Semantic | 35.5% | 67.1% | 77.0% | 56.5% | 66.1% | 49.2% | 49.3% | 50.2% | 59.9% | 58.7% |
| `v0.6.0` Raw + Context + Rerank | 47.4% | 80.3% | 86.9% | 69.6% | 76.5% | 61.7% | 61.1% | 61.2% | **67.8%** | 57.6% |
| **`v0.6.0` Curated + Context + Rerank** | **56.7%** (+21.2) | **82.2%** (+15.1) | **87.8%** (+10.8) | **71.4%** (+14.9) | **77.2%** (+11.1) | **67.1%** (+17.9) | **67.6%** (+18.3) | **61.3%** (+11.1) | 67.3% | **63.0%** (+15.2 vs v0.3) |

Full reports: [locomo10_curated.md](results/locomo10_curated.md), [locomo10_raw.md](results/locomo10_raw.md).

### D. Tier 1 Frozen `RawMemory-Bench v1.0` & Tier 3 ConvoMem / Reflexive Meta

- **`RawMemory-Bench v1.0`** (SHA-256 locked, 32 cases × 9 pillars): **`32/32 (100.0%)`** — Stale Leakage `0.0%`, Cross-Project Bleed `0`, Privacy/Vault Leaks `0`, Poisoning Block `100.0%`, Ephemeral TTL Pass `100.0%`, Prompt-Cache Stable Prefix `68.7%` ([rawmemory_bench_v1.md](results/rawmemory_bench_v1.md)).
- **`ConvoMem Smoke` + 5-Stage E2E `MemScore`**: `Sess R@5 = 100.0%`, `Ans-Cov@5 = 100.0%`, `Abstention = 100.0%`, Offline E2E Accuracy `83.3%` ([convomem_smoke.md](results/convomem_smoke.md), [convomem_e2e_memscore.json](results/convomem_e2e_memscore.json)).
- **`Reflexive Meta Benchmark (RFC-0003)`**: `hub_v2_curated` `100.0%` Fact Recall, `100.0%` Truth Accuracy, `0.0%` Stale Leakage (vs `flat_memory_md` `83.3%` stale), `PASS` 5-gen Anti-Echo ([reflexive_meta.md](results/reflexive_meta.md)).

---

## 2. Reproduce Locally

```bash
uv sync --extra dev --extra semantic

# Tier 1 Frozen Regression (SHA-256 verified)
uv run raw-memory-eval bench-frozen

# Tier 2 Private Local Personal Golden Set (outside Git)
uv run raw-memory-eval bench-personal

# Tier 3 Public Academic Benchmarks (v0.6: --semantic --rerank)
uv run raw-memory-eval bench download --suite all
uv run raw-memory-eval bench run --suite locomo --mode curated --semantic --rerank
uv run raw-memory-eval bench run --suite longmemeval-oracle --semantic --rerank
uv run raw-memory-eval bench run --suite longmemeval-s --semantic --rerank
uv run raw-memory-eval bench run --suite convomem-smoke --semantic
uv run raw-memory-eval bench-e2e --semantic

# Localhost Interactive Debug & Benchmark Workbench
uv run raw-memory-eval workbench --port 8765
```
