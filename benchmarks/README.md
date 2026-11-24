# Raw Memory Benchmark Suite

This directory integrates widely adopted public LLM/Agent memory benchmarks alongside Raw Memory's own **Reflexive Meta Memory Benchmark (RFC-0003)** and **Human-in-the-Loop Debug Workbench**.

All evaluations run deterministically against genuine `HubStore` SQLite FTS5 instances (zero mocked stores, zero cloud embedding APIs, zero GPU required) so every retrieval or curation change can be verified reproducibly in under one minute.

---

## 1. Integrated Suites

| Suite | Source & Venue | Scale | What It Tests |
| :--- | :--- | :--- | :--- |
| **[LongMemEval-S](https://github.com/xiaowu0162/LongMemEval)** | ICLR 2025 (UCLA / Tencent AI Lab) | 500 Qs × ~48 sessions (~494 turns/Q, 246,750 turns total) | Haystack retrieval across 6 pillars (`single-session-user`, `single-session-assistant`, `single-session-preference`, `multi-session`, `temporal-reasoning`, `knowledge-update`) + 30 `abstention` (`_abs`) traps |
| **[LongMemEval-Oracle](https://github.com/xiaowu0162/LongMemEval)** | ICLR 2025 (Cleaned) | 500 Qs (evidence sessions only) | Turn-level pinpointing precision without distractor sessions |
| **[LoCoMo](https://github.com/snap-research/locomo)** | ACL 2024 (Snap Research / UNC) | 10 multi-session dialogues, 5,882 turns, 1,986 QA pairs | Multi-session dialogue recall across `single_hop`, `temporal`, `open_domain`, `multi_hop`, and `adversarial`; compares **L1 Raw** vs **L1+L2+L3 Curated Observations** |
| **[Reflexive Meta Benchmark](../docs/rfc/0003-meta-memory-benchmark.md)** | Raw Memory (Bundled) | 18 causal $H_{<t}$ cases + 5-gen anti-echo stress test | Causal time-travel isolation, bi-temporal decision supersession, cross-channel anchors, privacy tiers, and multi-generation hallucination/echo resistance |

---

## 2. Reproducible Scorecard (v0.2.0 Strict-AND Baseline → v0.3.0 Hybrid BM25 + RRF)

Running public natural-language benchmarks immediately caught a critical v0.2.0 retrieval defect: `fts_match_query()` originally joined all words (including stopwords like `when`, `did`, `the`) with strict `AND`, collapsing natural-language recall to `0.1%–3.2%`.

Upgrading [tokenizer.py](../packages/hub/src/context_hub/tokenizer.py) and [store.py](../packages/hub/src/context_hub/store.py) with stopword-aware query planning, lightweight English stemming, two-stage `AND → BM25 OR` retrieval, and cross-tier Episode↔Turn Reciprocal Rank Fusion (RRF) produced the following verified jump across all 4 suites:

### A. LongMemEval-S (470 scored + 30 `_abs` abstention, ~115k tokens / ~48 sessions per question)

| Engine | Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | p50 Latency |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 3.2% | 1.7% | 2.6% | 0.0% | 0.0% | 0.0% | 0.45 ms |
| **`v0.3.0` (Hybrid BM25 + RRF)** | **80.6%** | **96.6%** | **98.5%** | **85.3%** | **86.1%** | **77.0%** | **86.2%** | **55.4%** | **1.93 ms** |

Per-pillar breakdown (`v0.3.0`, full report: [longmemeval_s.md](results/longmemeval_s.md)):

| Official Pillar | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 94.4% | **100.0%** | 98.6% | 96.0% | 88.9% | 86.1% |
| `single-session-assistant` | 56 | 87.5% | **100.0%** | 100.0% | 94.7% | 87.5% | 91.1% |
| `single-session-user` | 64 | 75.0% | **100.0%** | 100.0% | 89.6% | 82.8% | 90.6% |
| `multi-session` | 121 | 85.1% | 98.4% | 73.6% | 85.5% | 76.9% | 50.4% |
| `temporal-reasoning` | 127 | 77.2% | 92.9% | 75.6% | 80.7% | 71.7% | 43.3% |
| `single-session-preference` | 30 | 43.3% | 83.3% | 83.3% | 63.6% | 40.0% | 0.0% |

*Abstention (`_abs`, N=30)*: Refuting-session R@5 = `96.7%`, R@10 = `96.7%`.

### B. LongMemEval-Oracle (470 scored + 30 `_abs`, evidence sessions only)

| Engine | Sess R@1 | Sess R@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 | p50 Latency |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` (Strict-AND FTS) | 3.2% | 3.2% | 0.0% | 0.0% | 0.0% | 0.0% | 0.23 ms |
| **`v0.3.0` (Hybrid BM25)** | **100.0%** | **100.0%** | **84.3%** | **93.0%** | **61.4%** | **65.5%** | **0.64 ms** |

Full report: [longmemeval_oracle.md](results/longmemeval_oracle.md).

### C. LoCoMo (10 conversations, 1,982 scored / 1,986 total QA pairs)

| Engine & Mode | R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | MRR | Ans-Cov@10 | p50 Latency |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `v0.2.0` Raw / Curated | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.1% | 0.06 ms |
| `v0.3.0` L1 Raw Only | **37.0%** | **61.7%** | 69.6% | **52.7%** | 60.0% | **47.3%** | **47.5%** | 54.3% | 0.96 ms |
| **`v0.3.0` L1+L2+L3 Curated** | 34.2% | 61.3% | **72.5%** | 50.9% | **61.5%** | 45.4% | 46.2% | **56.1%** | 2.04 ms |

Key insight: Adding curated L3 observations lifts `single_hop` R@5 by **+9.9 pts** (`47.2% → 57.1%`), `temporal` R@10 by **+5.0 pts** (`73.5% → 78.5%`), and `open_domain` R@10 by **+6.5 pts** (`41.3% → 47.8%`). Full reports: [locomo10_raw.md](results/locomo10_raw.md), [locomo10_curated.md](results/locomo10_curated.md).

### D. Reflexive Meta Memory Benchmark (RFC-0003, Bundled)

| Baseline | Overall Recall | Cold-Start | Correction Avoidance | Bi-Temporal Truth | Stale Leakage ↓ | 5-Gen Anti-Echo |
| :--- | ---: | ---: | ---: | ---: | ---: | :---: |
| `no_memory` | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | — |
| `raw_fts` | 88.9% | 100.0% | 66.7% | 100.0% | 83.3% | — |
| `flat_memory_md` | 94.4% | 83.3% | 100.0% | 100.0% | 83.3% | — |
| **`hub_v2_curated`** | **100.0%** | **100.0%** | **100.0%** | **100.0%** | **0.0%** | **PASS (0% drift)** |

Full report: [reflexive_meta.md](results/reflexive_meta.md).

---

## 3. Honest Failure Analysis & Next Frontier

1. **Zero-overlap Preference & Paraphrase Queries**: On LongMemEval-S `single-session-preference` (`Turn R@5 = 40.0%`, e.g. *"What activities should I do in the evening?"*) and LoCoMo `open_domain` (`R@5 = 39.1%`), pure lexical BM25 hits its natural ceiling because the query shares almost no literal words with the stored memory. This directly validates Raw Memory's two-pronged roadmap:
   - Always injecting compact, high-signal curated `preference` memories into `get_context_pack()` (no lexical match needed).
   - Adding an optional local dense/hybrid semantic reranker over top BM25 + episode candidates.
2. **Multi-Entity Multi-Session Decomposition**: On LongMemEval-S `multi-session` (`Sess All-R@5 = 73.6%`) and `temporal-reasoning` (`Sess All-R@5 = 75.6%`), questions comparing 3–4 separate past events benefit from decomposing sub-queries or retrieving curated episode timelines.
3. **Curated Compression Fidelity**: On live personal sessions, `raw-memory-eval inspect-fidelity` verifies claim-to-evidence support and omitted high-signal user turns so compression never hallucinates unconfirmed assistant proposals.

---

## 4. Reproduce Locally & Interactive Debugging

```bash
# 1. Download official academic datasets (cached outside git at ~/.local/share/context-hub-v2/benchmarks)
uv run raw-memory-eval bench download --suite all

# 2. Run public benchmarks
uv run raw-memory-eval bench run --suite locomo --mode raw
uv run raw-memory-eval bench run --suite locomo --mode curated
uv run raw-memory-eval bench run --suite longmemeval-oracle
uv run raw-memory-eval bench run --suite longmemeval-s

# 3. Run bundled Reflexive Meta Benchmark (H_<t + 5-gen anti-echo)
uv run raw-memory-eval run

# 4. Run live personal Raw Data / Memory / Compression Fidelity audits
uv run raw-memory-eval audit-raw
uv run raw-memory-eval audit-memory
uv run raw-memory-eval inspect-fidelity

# 5. Launch the Human-in-the-Loop Debug Workbench (localhost only)
uv run raw-memory-eval workbench --port 8765
```
