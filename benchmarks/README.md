# Raw Memory Benchmark Suite

This directory integrates a **3-Tier Fixed Regression, Public Academic Retrieval, and Official-Protocol End-to-End LLM-as-a-Judge** evaluation system for Raw Memory:

1. **Tier 1 · Frozen `RawMemory-Bench v1.0`** ([suites/rawmemory_bench_v1.json](suites/rawmemory_bench_v1.json), SHA-256 locked in [manifest.json](manifest.json)): 32 deterministic tests across 9 core Agent-memory pillars (Cold-Start, Correction Avoidance, 3-Step Supersession, Cross-Channel Fusion, Cross-Project Isolation, Prompt-Injection Memory Poisoning Defense & Cascade Deletion, Ephemeral TTL & Non-Overgeneralization, Privacy/Vault Boundary, and Prompt-Cache Stable Prefix Determinism).
2. **Tier 2 · Private `Personal Golden Set`** (`~/.local/share/context-hub-v2/eval/personal_bench_v1.json`, strictly outside Git): read-only regression suite run live against the owner's local `HubStore`, checking real-world recall, zero stale leakage, and zero raw PII exposure.
3. **Tier 3 · Public Academic Retrieval & E2E LLM-as-a-Judge Suites**: **LongMemEval-S** (ICLR 2025), **LongMemEval-Oracle** (ICLR 2025), **LoCoMo** (ACL 2024), **ConvoMem** + 5-Stage **MemoryBench E2E Judge (`MemScore`)**, and **Reflexive Meta Benchmark (RFC-0003)**.

All retrieval indexing and search run deterministically against genuine `HubStore` SQLite FTS5 + SQLite `entity_edges` Bipartite Graph + local `fastembed` ONNX (`BAAI/bge-small-en-v1.5`, 384-d) + local ONNX Cross-Encoder (`Xenova/ms-marco-MiniLM-L-12-v2`, 134 MB for Latin queries; automatic CJK routing to `BAAI/bge-reranker-v2-m3-int8`, 588 MB)—**100% local on CPU, zero cloud LLM ingestion, zero cloud embedding/rerank APIs, zero GPU, zero mocked stores**.

---

## 1. Official-Protocol End-to-End LLM-as-a-Judge Benchmarks (Track B · `v0.8.1`)

To measure real downstream QA accuracy on an apples-to-apples footing with published memory systems, [academic_e2e.py](../packages/eval/src/context_eval/academic_e2e.py) enforces strict blind separation:
- **Stage 1–3 (100% Local CPU Retrieval)**: `HubStore v0.8.1` retrieves compact timestamped memory excerpts and writes `reader_inputs.jsonl` (zero gold answers or labels) separately from `gold_key.json`.
- **Stage 4 (Blind Reader LLM)**: Generates answers strictly from `reader_inputs.jsonl` (zero gold visibility).
- **Stage 5 (Independent Official Judge LLM)**: Grades `(question, gold_answer, model_response)` using verbatim **LongMemEval (ICLR 2025)** task-specific rubrics and the **LoCoMo (ACL 2024 / Mem0 / Supermemory)** judge prompt (+ deterministic normalized Token F1).

### A. LongMemEval-S E2E (ICLR 2025 · ALL 500 Questions: 470 positive + 30 `_abs`)

- **Full Report**: [longmemeval_s_e2e.md](results/longmemeval_s_e2e.md) ([JSON](results/longmemeval_s_e2e.json))
- **Memory Engine**: `raw-memory-v0.8.0-graph-multihop-rerank` (`Sess R@5 = 99.2%`, 100% local CPU, zero LLM ingestion)
- **Blind Reader / Independent Judge**: `gemini-flash` (Antigravity blind Reader + separate ICLR-2025 Judge)
- **Context Efficiency**: Avg **8,490 tokens** vs `127,940` full history (**-93.4%** prompt tokens)
- **Overall E2E Accuracy (`J-Score`)**: **`84.4%` (`422 / 500`)** (Positive: `83.4%` · Abstention: **`100.0%`**)

| Official Pillar | N | E2E Accuracy | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: |
| `abstention` (`_abs`) | 30 | **100.0%** | 100.0% | 100.0% |
| `single-session-user` | 64 | **95.3%** | 100.0% | 100.0% |
| `single-session-preference` | 30 | **93.3%** | 93.3% | 93.3% |
| `knowledge-update` | 72 | **90.3%** | 100.0% | 100.0% |
| `temporal-reasoning` | 127 | **82.7%** | 98.4% | 98.4% |
| `single-session-assistant` | 56 | **76.8%** | 100.0% | 100.0% |
| `multi-session` | 121 | **74.4%** | 100.0% | 100.0% |
| **Overall (All 500 Questions)** | **500** | **84.4%** | **99.2%** | **99.2%** |

> **Industry Context (Published LongMemEval-S Literature, noting Reader/Judge model differences)**: Full-Context `GPT-4o` (115k tokens) ~`60.6%–64.0%`, `Zep / Graphiti` (`GPT-4o`) `71.2%`, `Supermemory v4` (`GPT-4o` / `Gemini`, cloud LLM extraction) `81.6%`, **Raw Memory v0.8.1** (100% local CPU retrieval + blind `gemini-flash`, `-93.4%` tokens) **`84.4%`**. Users with `OPENAI_API_KEY` can also re-run the exact same CLI with `gpt-4o` as Reader & Judge.

### B. LoCoMo Curated E2E (ACL 2024 · Stratified 492 QAs across all 10 conversations)

- **Full Report**: [locomo10_curated_e2e.md](results/locomo10_curated_e2e.md) ([JSON](results/locomo10_curated_e2e.json))
- **Sample Design**: Uniform deterministic stride across all 10 conversations — **100%** of all 92 `open_domain` questions + 100 each of `single_hop`, `temporal`, `multi_hop`, `adversarial` (`N = 492`)
- **Context Efficiency**: Avg **1,395 tokens** vs `26,537` full history (**-94.7%** prompt tokens)
- **Population-Weighted LoCoMo `J-Score`**:
  - **All 5 Official Categories (1,982 weights)**: **`84.6%`**
  - **4 Non-Adversarial Categories (1,536 Mem0/Zep standard weights)**: **`81.9%`**
  - **Unweighted Stratified Macro (`N = 492`)**: **`75.0%`** (`369/492`, over-weighting `open_domain` 4x) · Raw Verbose Token F1 (cat 1–4): `16.3%`

| Official Category | N (Sample / Full) | E2E `J-Score` | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: |
| `single_hop` (cat 4) | 100 / 841 | **95.0%** | 86.0% | 92.0% |
| `adversarial` (cat 5) | 100 / 446 | **94.0%** | 91.0% | 95.0% |
| `temporal` (cat 2) | 100 / 321 | **79.0%** | 84.0% | 90.0% |
| `multi_hop` (cat 1) | 100 / 282 | **57.0%** | 81.0% | 88.0% |
| `open_domain` (cat 3) | 92 / 92 | **47.8%** | 54.4% | 65.2% |

> **Industry Context (Published LoCoMo 4-Category `J-Score`, noting Reader/Judge model differences)**: `Mem0` `66.9%`, `Mem0g` `68.4%`, Full-Context `GPT-4o` `72.9%`, `Zep` `75.1%`, `Supermemory` ~`81.6%`, **Raw Memory v0.8.1** (100% local CPU retrieval + blind `gemini-flash`, `-94.7%` tokens) **`81.9%`** (4-cat weighted) / **`84.6%`** (all 5 cats weighted).

---

## 2. Reproducible 6-Generation Retrieval Progression (`v0.2.0` → `v0.8.1`)

- **`v0.2.0`**: Strict-AND FTS5 baseline.
- **`v0.3.0`**: Stopword-aware two-stage `AND → BM25 OR` + Cross-tier Episode↔Turn RRF (`~2 ms`).
- **`v0.5.0`**: Hybrid BM25 + Local `fastembed` ONNX single-vector Semantic RRF (`~6–9 ms` warm).
- **`v0.6.0`**: Multi-Chunk Topic-Preserving Episode MaxSim + Bilingual (EN/ZH) Temporal Window Parser & Soft Gaussian RRF + Deduplicated Cross-Tier Fusion + Contextualized `±1` Turn Windows + Local ONNX `MiniLM-L-6` Cross-Encoder.
- **`v0.7.0`**: Confidence-Adaptive Calibrated Logit Fusion (`calibrate_rerank_blend`) + `MiniLM-L-12-v2` (EN) & auto-CJK `bge-reranker-v2-m3-int8` Cross-Encoder + Session-Best-Chunk Hierarchical CE + RFC-0003 First-Person Authority Prior & Past-Tense Assistant-Recall Routing (`query_targets_assistant`) + `±2` Same-Speaker Context Window + Curated Observation CE.
- **`v0.8.1`**: **SQLite `entity_edges` Bipartite Graph (`index_entity_graph` + `graph_bridge_search`)** + **Syntactic Multi-Hop / Dual-Entity / Choice Sub-Query Planner (`graph.py`)** + **Bidirectional `[Next reply]` Image Context Cue** + **Point-in-Time Exact-Date Candidate Rescue**.

### A. LongMemEval-S Retrieval (ICLR 2025 · 470 scored + 30 `_abs`, ~115k tokens / ~48 sessions / 246,750 turns)

| Engine | Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Turn R@1 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Turn MRR | `_abs` R@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 3.2% | 1.7% | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 3.3% |
| `v0.3.0` (BM25 + RRF) | 80.6% | 96.6% | 98.5% | 85.3% | 48.1% | 77.0% | 86.2% | 55.4% | 60.5% | 96.7% |
| `v0.5.0` (BM25 + Semantic RRF) | 86.2% | 97.7% | 98.7% | 87.2% | 47.4% | 85.1% | 92.8% | 58.2% | 63.3% | 100.0% |
| `v0.6.0` (MaxSim + Temp + L-6 CE) | 93.8% | 98.5% | 98.9% | 90.8% | 58.9% | 91.9% | 96.2% | 68.7% | 72.9% | 100.0% |
| `v0.7.0` (Calibrated Hierarchical CE) | 94.5% | 98.9% | **99.4%** | **92.6%** | 69.8% | 93.4% | 96.2% | 76.6% | 80.0% | 100.0% |
| **`v0.8.1` (+ Entity Graph & Temporal Rescue)** | **94.7%** | **99.2%** (466/470) | 99.2% | 92.3% | **70.0%** | **93.4%** | **96.8%** | **76.8%** | **80.2%** | **100.0%** |

> Full report: [longmemeval_s.md](results/longmemeval_s.md) — **Only 4 session misses out of 470 (`466/470 = 99.2%`)**.

### B. LongMemEval-Oracle Retrieval (ICLR 2025 · 470 scored + 30 `_abs`)

| Engine | Sess R@1 / R@5 | Turn R@1 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Turn MRR |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.3.0` (BM25 + RRF) | 100.0% / 100.0% | 53.0% | 84.3% | 93.0% | 61.4% | 66.2% |
| `v0.5.0` (BM25 + Semantic RRF) | 100.0% / 100.0% | 51.3% | 91.3% | 97.2% | 64.2% | 68.1% |
| `v0.6.0` (MaxSim + Temp + L-6 CE) | 100.0% / 100.0% | 63.0% | 94.0% | 98.3% | 73.0% | 76.3% |
| `v0.7.0` (Calibrated Hierarchical CE) | 100.0% / 100.0% | 74.0% | 96.0% | **98.9%** | 80.9% | 84.0% |
| **`v0.8.1` (+ Entity Graph & Temporal Rescue)** | **100.0% / 100.0%** | **74.0%** | **96.2%** | 98.7% | **81.0%** | **84.1%** |

Full report: [longmemeval_oracle.md](results/longmemeval_oracle.md).

### C. LoCoMo Retrieval (ACL 2024 · 10 dialogues, 5,882 turns, 1,982 scored QA pairs)

| Engine & Mode | R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | MRR | Ans-Cov@10 | `multi_hop` R@5 / R@10 | `open_domain` R@10 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` Raw / Curated | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.0% / 0.0% | 0.0% |
| `v0.3.0` Curated (BM25) | 34.2% | 61.3% | 72.5% | 50.9% | 61.5% | 45.4% | 46.2% | 56.1% | — | 47.8% |
| `v0.5.0` Curated + Semantic | 35.5% | 67.1% | 77.0% | 56.5% | 66.1% | 49.2% | 49.3% | 59.9% | — | 58.7% |
| `v0.6.0` Curated + L-6 CE | 56.7% | 82.2% | 87.8% | 71.4% | 77.2% | 67.1% | 67.6% | 67.3% | — | 63.0% |
| `v0.7.0` Raw + Calibrated L-12 | 53.2% | 83.5% | 89.5% | 72.7% | 79.6% | 66.2% | 66.0% | **70.6%** | 71.3% / 80.1% | 58.7% |
| `v0.7.0` Curated + Calibrated L-12 | 62.2% | 86.0% | 90.4% | 75.1% | 80.4% | 71.5% | 72.3% | 69.2% | 79.1% / 87.9% | 64.1% |
| **`v0.8.1` Curated + Entity Graph + Sub-Query** | **62.5%** | **86.2%** | **90.9%** | **75.3%** | **81.0%** | **71.6%** | **72.4%** | 69.5% | **80.5% / 89.0%** | **65.2%** |

Full reports: [locomo10_curated.md](results/locomo10_curated.md), [locomo10_raw.md](results/locomo10_raw.md).

### D. Tier 1 Frozen `RawMemory-Bench v1.0` & Tier 2/3 Guardrails

- **`RawMemory-Bench v1.0`** (SHA-256 locked, 32 cases × 9 pillars): **`32/32 (100.0%)`** — Stale Leakage `0.0%`, Cross-Project Bleed `0`, Privacy/Vault Leaks `0`, Poisoning Block `100.0%`, Ephemeral TTL Pass `100.0%`, Prompt-Cache Stable Prefix `68.7%`, p50 `0.88 ms` ([rawmemory_bench_v1.md](results/rawmemory_bench_v1.md)).
- **`Personal Golden Set v1.0`** (private local regression, 16 real-world cases): **`16/16 (100.0%)`** — `0` Raw PII Leaks, `0` Stale Leaks.
- **`ConvoMem Smoke` + 5-Stage E2E `MemScore`**: `Sess R@5 = 100.0%`, `Ans-Cov@5 = 100.0%`, `Abstention = 100.0%`, Offline E2E Accuracy `83.3%` ([convomem_smoke.md](results/convomem_smoke.md), [convomem_e2e_memscore.json](results/convomem_e2e_memscore.json)).
- **`Reflexive Meta Benchmark (RFC-0003)`**: `hub_v2_curated` `100.0%` Fact Recall, `100.0%` Truth Accuracy, `0.0%` Stale Leakage (vs `flat_memory_md` `83.3%` stale), `PASS` 5-gen Anti-Echo ([reflexive_meta.md](results/reflexive_meta.md)).

---

## 3. Reproduce Locally

```bash
uv sync --extra dev --extra semantic

# Tier 1 Frozen Regression (SHA-256 verified)
uv run raw-memory-eval bench-frozen

# Tier 2 Private Local Personal Golden Set (outside Git)
uv run raw-memory-eval bench-personal

# Tier 3 Public Academic Retrieval (100% Local CPU: --semantic --rerank)
uv run raw-memory-eval bench download --suite all
uv run raw-memory-eval bench run --suite locomo --mode curated --semantic --rerank
uv run raw-memory-eval bench run --suite longmemeval-oracle --semantic --rerank
uv run raw-memory-eval bench run --suite longmemeval-s --semantic --rerank

# Track B Official-Protocol E2E LLM-as-a-Judge (supports OPENAI_API_KEY / GEMINI_API_KEY / Ollama)
uv run raw-memory-eval bench-e2e-academic prepare --suite longmemeval-s --out-dir /tmp/lme_pack
OPENAI_API_KEY=... uv run raw-memory-eval bench-e2e-academic run \
  --pack-dir /tmp/lme_pack --suite longmemeval-s --reader-model gpt-4o --judge-model gpt-4o

# Localhost Interactive Debug & Benchmark Workbench
uv run raw-memory-eval workbench --port 8765
```
