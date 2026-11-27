# Raw Memory Benchmark Report — `longmemeval-s` (hub_retrieval+semantic+rerank)

- **Engine**: `raw-memory-v0.6.0-maxsim-temporal-rerank`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`1824.15 ms`, p95=`3045.63 ms`, wall=`4255.80 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 93.8% | 98.5% | 98.9% | 90.8% | 94.3% | 91.9% | 96.2% | 68.7% | 64.0% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 97.2% | 100.0% | 98.6% | 98.4% | 95.8% | 75.9% | 86.1% |
| `multi-session` | 121 | 95.0% | 100.0% | 86.0% | 93.8% | 95.0% | 62.4% | 53.7% |
| `single-session-assistant` | 56 | 100.0% | 100.0% | 100.0% | 100.0% | 91.1% | 76.1% | 91.1% |
| `single-session-preference` | 30 | 80.0% | 90.0% | 90.0% | 85.6% | 83.3% | 54.6% | 3.3% |
| `single-session-user` | 64 | 95.3% | 100.0% | 100.0% | 98.1% | 96.9% | 88.5% | 96.9% |
| `temporal-reasoning` | 127 | 90.5% | 96.9% | 82.7% | 90.1% | 86.6% | 60.7% | 47.2% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`100.0%`, R@10=`100.0%`, zero-hit rate=`0.0%`

## Sample Failure Cases (Top 7 for Debugging)

- **`[single-session-preference]` `75832dbd`** (`miss_at_5`): *Can you recommend some recent publications or conferences that I might find interesting?* (gold=['answer_d87a6ef8'], got=['ultrachat_533748', 'sharegpt_FYqt26U_0', 'c51583cd_1'])
- **`[single-session-preference]` `06f04340`** (`miss_at_5`): *What should I serve for dinner this weekend with my homegrown ingredients?* (gold=['answer_92d5f7cd'], got=['91223fd5_1', '6e6fbb6b', '8b156015_2'])
- **`[single-session-preference]` `d6233ab6`** (`miss_at_5`): *I've been feeling nostalgic lately. Do you think it would be a good idea to attend my high school reunion?* (gold=['answer_b0fac439'], got=['ultrachat_329160', '0e726047', '94bc18df_3'])
- **`[temporal-reasoning]` `gpt4_468eb064`** (`miss_at_5`): *Who did I meet with during the lunch last Tuesday?* (gold=['answer_9b09d95b_1'], got=['25e5b797_1', '1e5bd28d_2', 'ultrachat_59629'])
- **`[temporal-reasoning]` `9a707b82`** (`miss_at_5`): *I mentioned cooking something for my friend a couple of days ago. What was it?* (gold=['answer_dba89488_1', 'answer_dba89488_2'], got=['990f3ef9_2', '68d35085_1', 'ultrachat_466884'])
- **`[temporal-reasoning]` `eac54add`** (`miss_at_5`): *What was the significant buisiness milestone I mentioned four weeks ago?* (gold=['answer_0d4d0348_1', 'answer_0d4d0348_2'], got=['369695b4_2', 'sharegpt_5YtukCb_0', '7bb01253'])
- **`[temporal-reasoning]` `gpt4_8279ba03`** (`miss_at_5`): *What kitchen appliance did I buy 10 days ago?* (gold=['answer_56521e66_1'], got=['bb107057_2', 'b357fb8b_2', '652c0717_3'])
