# Raw Memory Benchmark Report — `longmemeval-s` (hub_retrieval+semantic+rerank)

- **Engine**: `raw-memory-v0.7.0-calibrated-hierarchical-rerank`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`1336.20 ms`, p95=`2152.08 ms`, wall=`789.25 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 94.5% | 98.9% | 99.4% | 92.5% | 95.0% | 93.4% | 96.2% | 76.6% | 64.0% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 97.2% | 100.0% | 98.6% | 98.5% | 98.6% | 84.4% | 90.3% |
| `multi-session` | 121 | 95.0% | 100.0% | 91.7% | 94.9% | 97.5% | 74.2% | 50.4% |
| `single-session-assistant` | 56 | 100.0% | 100.0% | 100.0% | 100.0% | 89.3% | 78.9% | 92.9% |
| `single-session-preference` | 30 | 76.7% | 93.3% | 93.3% | 85.5% | 83.3% | 58.8% | 6.7% |
| `single-session-user` | 64 | 98.4% | 100.0% | 100.0% | 99.4% | 96.9% | 90.8% | 96.9% |
| `temporal-reasoning` | 127 | 92.1% | 97.6% | 82.7% | 90.9% | 89.0% | 70.8% | 46.5% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`100.0%`, R@10=`100.0%`, zero-hit rate=`0.0%`

## Sample Failure Cases (Top 5 for Debugging)

- **`[single-session-preference]` `75832dbd`** (`miss_at_5`): *Can you recommend some recent publications or conferences that I might find interesting?* (gold=['answer_d87a6ef8'], got=['ultrachat_533748', 'c51583cd_1', 'c884b67a_1'])
- **`[single-session-preference]` `06f04340`** (`miss_at_5`): *What should I serve for dinner this weekend with my homegrown ingredients?* (gold=['answer_92d5f7cd'], got=['91223fd5_1', '6e6fbb6b', '8b156015_2'])
- **`[temporal-reasoning]` `gpt4_468eb064`** (`miss_at_5`): *Who did I meet with during the lunch last Tuesday?* (gold=['answer_9b09d95b_1'], got=['1e5bd28d_2', 'ultrachat_323709', 'sharegpt_C2Qfdn8_0'])
- **`[temporal-reasoning]` `eac54add`** (`miss_at_5`): *What was the significant buisiness milestone I mentioned four weeks ago?* (gold=['answer_0d4d0348_1', 'answer_0d4d0348_2'], got=['369695b4_2', 'ultrachat_133409', 'ultrachat_91693'])
- **`[temporal-reasoning]` `gpt4_8279ba03`** (`miss_at_5`): *What kitchen appliance did I buy 10 days ago?* (gold=['answer_56521e66_1'], got=['bb107057_2', 'ultrachat_526748', '652c0717_3'])
