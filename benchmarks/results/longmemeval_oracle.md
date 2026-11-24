# Raw Memory Benchmark Report — `longmemeval-oracle` (hub_retrieval)

- **Engine**: `raw-memory-v0.3.0-hybrid-bm25`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`0.64 ms`, p95=`0.97 ms`, wall=`3.26 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 100.0% | 100.0% | 100.0% | 97.2% | 99.3% | 84.3% | 93.0% | 61.4% | 65.5% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 100.0% | 100.0% | 98.6% | 99.5% | 88.9% | 67.5% | 88.9% |
| `multi-session` | 121 | 100.0% | 100.0% | 95.0% | 98.5% | 80.2% | 49.4% | 52.9% |
| `single-session-assistant` | 56 | 100.0% | 100.0% | 100.0% | 100.0% | 92.9% | 80.8% | 94.6% |
| `single-session-preference` | 30 | 100.0% | 100.0% | 100.0% | 100.0% | 63.3% | 39.8% | 3.3% |
| `single-session-user` | 64 | 100.0% | 100.0% | 100.0% | 100.0% | 87.5% | 73.0% | 95.3% |
| `temporal-reasoning` | 127 | 100.0% | 100.0% | 95.3% | 99.1% | 85.0% | 60.2% | 51.2% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`96.7%`, R@10=`96.7%`, zero-hit rate=`3.3%`
