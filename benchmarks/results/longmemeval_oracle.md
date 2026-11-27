# Raw Memory Benchmark Report — `longmemeval-oracle` (hub_retrieval+semantic+rerank)

- **Engine**: `raw-memory-v0.6.0-maxsim-temporal-rerank`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`308.06 ms`, p95=`446.68 ms`, wall=`228.38 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100.0% | 100.0% | 100.0% | 99.4% | 100.0% | 94.0% | 98.3% | 73.0% | 65.3% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% | 79.5% | 88.9% |
| `multi-session` | 121 | 100.0% | 100.0% | 100.0% | 100.0% | 95.0% | 66.2% | 52.1% |
| `single-session-assistant` | 56 | 100.0% | 100.0% | 100.0% | 100.0% | 89.3% | 75.1% | 91.1% |
| `single-session-preference` | 30 | 100.0% | 100.0% | 100.0% | 100.0% | 96.7% | 72.2% | 3.3% |
| `single-session-user` | 64 | 100.0% | 100.0% | 100.0% | 100.0% | 96.9% | 90.6% | 96.9% |
| `temporal-reasoning` | 127 | 100.0% | 100.0% | 97.6% | 100.0% | 89.8% | 66.2% | 52.0% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`100.0%`, R@10=`100.0%`, zero-hit rate=`0.0%`
