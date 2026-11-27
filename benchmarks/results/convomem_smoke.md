# Raw Memory Benchmark Report — `convomem-smoke` (hub_retrieval+semantic)

- **Engine**: `raw-memory-v0.5.0-hybrid-bm25-semantic`
- **Questions**: `10` scored / `12` total (`2` abstention `_abs` tracked separately)
- **Latency**: p50=`0.77 ms`, p95=`1.09 ms`, wall=`0.36 s`

## Overall Metrics (ConvoMem 6-Category Retrieval)

| Sess R@1 | Sess R@5 | Sess NDCG@5 | Sess MRR | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: |
| 90.0% | 100.0% | 96.3% | 95.0% | 100.0% |

## Breakdown by ConvoMem Evidence Category

| Category | N | Sess R@1 | Sess R@5 | Sess NDCG@5 | Sess MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: |
| `assistant_facts` | 2 | 50.0% | 100.0% | 81.5% | 75.0% | 100.0% |
| `changing_facts` | 2 | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% |
| `implicit_connections` | 2 | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% |
| `preferences` | 2 | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% |
| `user_facts` | 2 | 100.0% | 100.0% | 100.0% | 100.0% | 100.0% |
