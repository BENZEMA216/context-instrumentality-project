# Raw Memory Benchmark Report — `longmemeval-oracle` (hub_retrieval+semantic)

- **Engine**: `raw-memory-v0.5.0-hybrid-bm25-semantic`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`1.52 ms`, p95=`3.50 ms`, wall=`4.86 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100.0% | 100.0% | 100.0% | 99.4% | 100.0% | 91.3% | 97.2% | 64.2% | 64.7% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 100.0% | 100.0% | 100.0% | 100.0% | 93.1% | 63.8% | 81.9% |
| `multi-session` | 121 | 100.0% | 100.0% | 100.0% | 100.0% | 93.4% | 56.0% | 52.9% |
| `single-session-assistant` | 56 | 100.0% | 100.0% | 100.0% | 100.0% | 92.9% | 70.3% | 92.9% |
| `single-session-preference` | 30 | 100.0% | 100.0% | 100.0% | 100.0% | 86.7% | 61.6% | 3.3% |
| `single-session-user` | 64 | 100.0% | 100.0% | 100.0% | 100.0% | 92.2% | 76.4% | 96.9% |
| `temporal-reasoning` | 127 | 100.0% | 100.0% | 97.6% | 100.0% | 88.2% | 64.0% | 52.0% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`100.0%`, R@10=`100.0%`, zero-hit rate=`0.0%`
