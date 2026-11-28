# Raw Memory Benchmark Suite

This directory integrates a **3-Tier Fixed Regression & Public Academic Benchmark** system for Raw Memory:

1. **Tier 1 · Frozen `RawMemory-Bench v1.0`** ([suites/rawmemory_bench_v1.json](suites/rawmemory_bench_v1.json), SHA-256 locked in [manifest.json](manifest.json)): 32 deterministic tests across 9 core Agent-memory pillars (Cold-Start, Correction Avoidance, 3-Step Supersession, Cross-Channel Fusion, Cross-Project Isolation, Prompt-Injection Memory Poisoning Defense & Cascade Deletion, Ephemeral TTL & Non-Overgeneralization, Privacy/Vault Boundary, and Prompt-Cache Stable Prefix Determinism).
2. **Tier 2 · Private `Personal Golden Set`** (`~/.local/share/context-hub-v2/eval/personal_bench_v1.json`, strictly outside Git): read-only regression suite run live against the owner's local `HubStore`, checking real-world recall, zero stale leakage, and zero raw PII exposure.
3. **Tier 3 · Public Academic & Reflexive Suites**: **LongMemEval-S** (ICLR 2025), **LongMemEval-Oracle** (ICLR 2025), **LoCoMo** (ACL 2024), **ConvoMem** + 5-Stage **MemoryBench E2E Judge (`MemScore`)**, and **Reflexive Meta Benchmark (RFC-0003)**.

All evaluations run deterministically against genuine `HubStore` SQLite FTS5 + local `fastembed` ONNX (`BAAI/bge-small-en-v1.5`, 384-d) + local ONNX Cross-Encoder (`Xenova/ms-marco-MiniLM-L-12-v2`, 134 MB for Latin queries; automatic CJK routing to `BAAI/bge-reranker-v2-m3-int8`, 588 MB)—**100% local on CPU, zero cloud LLM / embedding APIs, zero GPU, zero mocked stores**.

---

## 1. Reproducible 5-Generation Progression (`v0.2.0` → `v0.3.0` → `v0.5.0` → `v0.6.0` → `v0.7.0`)

- **`v0.2.0`**: Strict-AND FTS5 baseline.
- **`v0.3.0`**: Stopword-aware two-stage `AND → BM25 OR` + Cross-tier Episode↔Turn RRF (`~2 ms`).
- **`v0.5.0`**: Hybrid BM25 + Local `fastembed` ONNX single-vector Semantic RRF (`~6–9 ms` warm).
- **`v0.6.0`**: Multi-Chunk Topic-Preserving Episode MaxSim + Bilingual (EN/ZH) Temporal Window Parser & Soft Gaussian RRF + Deduplicated Cross-Tier Fusion + Contextualized `±1` Turn Windows + Local ONNX `MiniLM-L-6` Cross-Encoder.
- **`v0.7.0`**: **Confidence-Adaptive Calibrated Logit Fusion (`calibrate_rerank_blend`)** + **`MiniLM-L-12-v2` (EN) & auto-CJK `bge-reranker-v2-m3-int8` Cross-Encoder** + **Session-Best-Chunk Hierarchical CE** + **RFC-0003 First-Person Authority Prior & Past-Tense Assistant-Recall Routing (`query_targets_assistant`)** + **`±2` Same-Speaker Context Window Expansion** + **Curated Observation CE**.

### A. LongMemEval-S (ICLR 2025 · 470 scored + 30 `_abs`, ~115k tokens / ~48 sessions / 246,750 turns)

| Engine | Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@1 | Turn R@5 | Turn R@10 | Turn NDCG@5 | `_abs` R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 3.2% | 1.7% | 2.6% | 0.0% | 0.0% | 0.0% | 0.0% | 3.3% |
| `v0.3.0` (BM25 + RRF) | 80.6% | 96.6% | 98.5% | 85.3% | 86.1% | 48.1% | 77.0% | 86.2% | 55.4% | 96.7% |
| `v0.5.0` (BM25 + Semantic RRF) | 86.2% | 97.7% | 98.7% | 87.2% | 90.0% | 47.4% | 85.1% | 92.8% | 58.2% | 100.0% |
| `v0.6.0` (MaxSim + Temporal + L-6 CE) | 93.8% | 98.5% | 98.9% | 90.8% | 94.3% | 58.9% | 91.9% | 96.2% | 68.7% | 100.0% |
| **`v0.7.0` (Calibrated Hierarchical CE)** | **94.5%** (+0.7) | **98.9%** (465/470) | **99.4%** (467/470) | **92.6%** (+1.8) | **95.0%** (+0.7) | **69.8%** (+10.9) | **93.4%** (+1.5) | **96.2%** | **76.6%** (+7.9) | **100.0%** |

> Only **5 session misses out of 470** at `Sess R@5` (`465/470 = 98.9%`) and **3 misses** at `Sess R@10` (`467/470 = 99.4%`).

Per-pillar breakdown (`v0.7.0`, full report: [longmemeval_s.md](results/longmemeval_s.md)):

| Official Pillar | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@1 | Turn R@5 | Turn NDCG@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `single-session-assistant` | 56 | **100.0%** | **100.0%** | **100.0%** | **100.0%** | 66.1% | 89.3% | **78.9%** (+2.8) |
| `single-session-user` | 64 | **98.4%** (+3.1) | **100.0%** | **100.0%** | **99.4%** | **82.8%** | **96.9%** | **90.8%** (+2.3) |
| `knowledge-update` | 72 | **97.2%** | **100.0%** | 98.6% | **98.5%** | 68.1% | **98.6%** (+2.8) | **84.4%** (+8.5) |
| `multi-session` | 121 | **95.0%** | **100.0%** | **91.7%** (+5.7) | **94.9%** | **76.9%** | **97.5%** (+2.5) | **74.2%** (+11.8) |
| `temporal-reasoning` | 127 | **92.1%** (+1.6) | **97.6%** (+0.7) | 82.7% | **90.9%** | 65.4% | **89.0%** (+2.4) | **70.8%** (+10.1) |
| `single-session-preference` | 30 | 76.7% | **93.3%** (+3.3, 28/30) | **93.3%** (+3.3) | 85.6% | 43.3% | **83.3%** | **58.8%** (+4.2) |

### B. LongMemEval-Oracle (ICLR 2025 · 470 scored + 30 `_abs`, evidence sessions only)

| Engine | Sess R@1 | Sess R@5 | Turn R@1 | Turn R@5 | Turn R@10 | Turn NDCG@5 | `knowledge-update` Turn NDCG@5 | `single-session-user` Turn NDCG@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% |
| `v0.3.0` (BM25 + RRF) | 100.0% | 100.0% | 53.0% | 84.3% | 93.0% | 61.4% | 68.7% | 72.1% |
| `v0.5.0` (BM25 + Semantic RRF) | 100.0% | 100.0% | 51.3% | 91.3% | 97.2% | 64.2% | 70.1% | 77.6% |
| `v0.6.0` (MaxSim + Temporal + L-6 CE) | 100.0% | 100.0% | 63.0% | 94.0% | 98.3% | 73.0% | 77.4% | 88.8% |
| **`v0.7.0` (Calibrated Hierarchical CE)** | **100.0%** | **100.0%** | **74.0%** (+11.0) | **96.0%** (+2.0) | **98.9%** (465/470) | **80.9%** (+7.9) | **85.1%** (+7.7) | **92.1%** (+3.3) |

Full report: [longmemeval_oracle.md](results/longmemeval_oracle.md).

### C. LoCoMo (ACL 2024 · 10 dialogues, 5,882 turns, 1,982 scored QA pairs)

| Engine & Mode | R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | MRR | Ans-Cov@5 | Ans-Cov@10 | `open_domain` R@10 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` Raw / Curated | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.0% |
| `v0.3.0` Curated (BM25) | 34.2% | 61.3% | 72.5% | 50.9% | 61.5% | 45.4% | 46.2% | 45.2% | 56.1% | 47.8% |
| `v0.5.0` Curated + Semantic | 35.5% | 67.1% | 77.0% | 56.5% | 66.1% | 49.2% | 49.3% | 50.2% | 59.9% | 58.7% |
| `v0.6.0` Raw + Context + L-6 CE | 47.4% | 80.3% | 86.9% | 69.6% | 76.5% | 61.7% | 61.1% | 61.2% | 67.8% | 57.6% |
| `v0.6.0` Curated + Context + L-6 CE | 56.7% | 82.2% | 87.8% | 71.4% | 77.2% | 67.1% | 67.6% | 61.3% | 67.3% | 63.0% |
| `v0.7.0` Raw + `±2` + Calibrated L-12 CE | 53.2% (+5.8) | 83.5% (+3.2) | 89.5% (+2.6) | 72.7% (+3.1) | 79.6% (+3.1) | 66.2% (+4.5) | 66.0% (+4.9) | **64.4%** (+3.2) | **70.6%** (+2.8) | 58.7% |
| **`v0.7.0` Curated + `±2` + Calibrated L-12 CE** | **62.2%** (+5.5) | **86.0%** (+3.8) | **90.4%** (+2.6) | **75.1%** (+3.7) | **80.4%** (+3.2) | **71.5%** (+4.4) | **72.3%** (+4.7) | 63.5% (+2.2) | 69.2% (+1.9) | **64.1%** (+16.3 vs v0.3) |

Per-category breakdown (`v0.7.0` Curated, official LoCoMo taxonomy fixed in v0.7: `cat 1 = multi_hop`, `cat 4 = single_hop`):

| Official Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `single_hop` (cat 4) | 841 | **65.9%** | **90.4%** | **93.3%** | **88.2%** | **78.7%** | **76.3%** |
| `adversarial` (cat 5) | 446 | **62.6%** | **87.7%** | **91.7%** | **86.6%** | **76.1%** | **73.2%** |
| `temporal` (cat 2) | 321 | **69.5%** | **86.9%** | **90.3%** | **79.4%** | **76.6%** | **77.0%** |
| `multi_hop` (cat 1) | 282 | 51.8% | 79.1% | **87.9%** | 26.2% | 47.9% | 63.3% |
| `open_domain` (cat 3) | 92 | 33.7% | 55.4% | 64.1% | 33.7% | 37.6% | 42.2% |

Full reports: [locomo10_curated.md](results/locomo10_curated.md), [locomo10_raw.md](results/locomo10_raw.md).

### D. Tier 1 Frozen `RawMemory-Bench v1.0` & Tier 3 ConvoMem / Reflexive Meta

- **`RawMemory-Bench v1.0`** (SHA-256 locked, 32 cases × 9 pillars): **`32/32 (100.0%)`** — Stale Leakage `0.0%`, Cross-Project Bleed `0`, Privacy/Vault Leaks `0`, Poisoning Block `100.0%`, Ephemeral TTL Pass `100.0%`, Prompt-Cache Stable Prefix `68.7%`, p50 `0.85 ms` ([rawmemory_bench_v1.md](results/rawmemory_bench_v1.md)).
- **`Personal Golden Set v1.0`** (private local regression, 16 real-world cases): **`16/16 (100.0%)`** — `0` Raw PII Leaks, `0` Stale Leaks.
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

# Tier 3 Public Academic Benchmarks (v0.7: --semantic --rerank)
uv run raw-memory-eval bench download --suite all
uv run raw-memory-eval bench run --suite locomo --mode curated --semantic --rerank
uv run raw-memory-eval bench run --suite locomo --mode raw --semantic --rerank
uv run raw-memory-eval bench run --suite longmemeval-oracle --semantic --rerank
uv run raw-memory-eval bench run --suite longmemeval-s --semantic --rerank
uv run raw-memory-eval bench run --suite convomem-smoke --semantic
uv run raw-memory-eval bench-e2e --semantic

# Localhost Interactive Debug & Benchmark Workbench
uv run raw-memory-eval workbench --port 8765
```
