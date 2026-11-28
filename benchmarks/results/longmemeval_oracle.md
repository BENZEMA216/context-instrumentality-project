# Raw Memory Benchmark Report — `longmemeval-oracle` (hub_retrieval+semantic+rerank)

- **Engine**: `raw-memory-v0.8.1-graph-multihop-rerank`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`676.32 ms`, p95=`1143.04 ms`, wall=`323.81 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100.0% | 100.0% | 100.0% | 99.4% | 100.0% | 96.2% | 98.7% | 81.0% | 65.5% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 100.0% | 100.0% | 100.0% | 100.0% | 98.6% | 85.1% | 91.7% |
| `multi-session` | 121 | 100.0% | 100.0% | 100.0% | 100.0% | 98.4% | 77.9% | 50.4% |
| `single-session-assistant` | 56 | 100.0% | 100.0% | 100.0% | 100.0% | 89.3% | 78.6% | 92.9% |
| `single-session-preference` | 30 | 100.0% | 100.0% | 100.0% | 100.0% | 93.3% | 77.2% | 0.0% |
| `single-session-user` | 64 | 100.0% | 100.0% | 100.0% | 100.0% | 96.9% | 92.1% | 96.9% |
| `temporal-reasoning` | 127 | 100.0% | 100.0% | 97.6% | 100.0% | 96.1% | 78.1% | 52.8% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`100.0%`, R@10=`100.0%`, zero-hit rate=`0.0%`
