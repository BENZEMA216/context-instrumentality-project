# Reflexive Meta Memory Benchmark — Baseline Scorecard

- **Dataset**: `synthetic_reflexive_v1` (`v1.0.0`, 18 synthetic cases)
- **Generated**: `2026-11-24 17:24:13 UTC`
- **Causal Isolation**: Strict $H_{<t}$ ephemeral `HubStore` replay + leak-check guard

## 1. Overall A/B Baseline Comparison

| Baseline | Overall Recall ↑ | Cold-Start Recall ↑ | Correction Avoidance ↑ | Bi-Temporal Truth ↑ | Stale Leakage ↓ | Future Leaks | Avg Tokens | Tok Eff (↑) | p50 / p95 ms |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `no_memory` | 0.0% | 0.0% | 0.0% | 0.0% | 0.0% | 0 | 0.0 | 0.00 | 0.00 / 0.00 |
| `raw_fts` | 88.9% | 100.0% | 66.7% | 100.0% | 83.3% | 0 | 74.0 | 8.83 | 1.32 / 1.74 |
| `flat_memory_md` | 94.4% | 83.3% | 100.0% | 100.0% | 83.3% | 0 | 48.7 | 9.44 | 1.24 / 1.72 |
| `hub_v2_curated` | 100.0% | 100.0% | 100.0% | 100.0% | 0.0% | 0 | 212.1 | 4.91 | 3.45 / 4.23 |

## 2. Per-Dimension Breakdown

| Dimension | Baseline | Cases | Fact Recall ↑ | Primary Metric ↑ | Stale Leakage ↓ | Avg Tokens | Tok Eff (↑) | p50 / p95 ms |
| :--- | :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `cold_start_continuation` | `no_memory` | 6 | 0.0% | 0.0% | 0.0% | 0.0 | 0.00 | 0.00 / 0.00 |
| `cold_start_continuation` | `raw_fts` | 6 | 100.0% | 100.0% | 0.0% | 72.5 | 10.00 | 1.27 / 1.39 |
| `cold_start_continuation` | `flat_memory_md` | 6 | 83.3% | 83.3% | 0.0% | 40.7 | 8.33 | 1.30 / 1.33 |
| `cold_start_continuation` | `hub_v2_curated` | 6 | 100.0% | 100.0% | 0.0% | 220.5 | 4.64 | 3.77 / 4.79 |
| `correction_avoidance` | `no_memory` | 6 | 0.0% | 0.0% | 0.0% | 0.0 | 0.00 | 0.00 / 0.00 |
| `correction_avoidance` | `raw_fts` | 6 | 66.7% | 66.7% | 0.0% | 75.7 | 6.65 | 1.45 / 1.69 |
| `correction_avoidance` | `flat_memory_md` | 6 | 100.0% | 100.0% | 0.0% | 46.8 | 10.00 | 1.23 / 1.73 |
| `correction_avoidance` | `hub_v2_curated` | 6 | 100.0% | 100.0% | 0.0% | 246.5 | 4.06 | 3.24 / 3.60 |
| `bitemporal_supersession` | `no_memory` | 6 | 0.0% | 0.0% | 0.0% | 0.0 | 0.00 | 0.00 / 0.00 |
| `bitemporal_supersession` | `raw_fts` | 6 | 100.0% | 100.0% | 83.3% | 73.8 | 9.83 | 1.36 / 1.77 |
| `bitemporal_supersession` | `flat_memory_md` | 6 | 100.0% | 100.0% | 83.3% | 58.5 | 10.00 | 1.22 / 1.59 |
| `bitemporal_supersession` | `hub_v2_curated` | 6 | 100.0% | 100.0% | 0.0% | 169.3 | 6.04 | 3.46 / 3.86 |

## 3. Reflexive Anti-Echo Closed-Loop Stress Test (5 Generations · PASS)

| Metric | Value | Target | Status |
| :--- | ---: | ---: | :---: |
| `hallucination_amplification_rate` | 0.0% | 0.0% | PASS |
| `authority_drift_rate` | 0.0% | 0.0% | PASS |
| `injection_compromise_rate` | 0.0% | 0.0% | PASS |
| `memory_bloat_ratio` | 1.00x (3/3) | <= 1.10x | PASS |
| `fabricated_evidence_gate_passed` | True | True | PASS |
