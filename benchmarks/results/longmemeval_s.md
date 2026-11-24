# Raw Memory Benchmark Report — `longmemeval-s` (hub_retrieval)

- **Engine**: `raw-memory-v0.3.0-hybrid-bm25`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`1.93 ms`, p95=`3.26 ms`, wall=`49.36 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 80.6% | 96.6% | 98.5% | 85.3% | 86.1% | 77.0% | 86.2% | 55.4% | 61.1% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 94.4% | 100.0% | 98.6% | 96.0% | 88.9% | 65.3% | 86.1% |
| `multi-session` | 121 | 85.1% | 98.4% | 73.6% | 85.5% | 76.9% | 42.5% | 50.4% |
| `single-session-assistant` | 56 | 87.5% | 100.0% | 100.0% | 94.7% | 87.5% | 79.8% | 91.1% |
| `single-session-preference` | 30 | 43.3% | 83.3% | 83.3% | 63.6% | 40.0% | 20.0% | 0.0% |
| `single-session-user` | 64 | 75.0% | 100.0% | 100.0% | 89.6% | 82.8% | 69.6% | 90.6% |
| `temporal-reasoning` | 127 | 77.2% | 92.9% | 75.6% | 80.7% | 71.7% | 52.3% | 43.3% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`96.7%`, R@10=`96.7%`, zero-hit rate=`3.3%`

## Sample Failure Cases (Top 8 for Debugging)

- **`[multi-session]` `gpt4_d84a3211`** (`miss_at_5`): *How much total money have I spent on bike-related expenses since the start of the year?* (gold=['answer_2880eb6c_1', 'answer_2880eb6c_2', 'answer_2880eb6c_3', 'answer_2880eb6c_4'], got=['sharegpt_OHd1RQ7_37', '8f6b938d_4', '4a32d58c_2'])
- **`[single-session-preference]` `75832dbd`** (`miss_at_5`): *Can you recommend some recent publications or conferences that I might find interesting?* (gold=['answer_d87a6ef8'], got=['sharegpt_xni9yYO_6', '2bac8799_3', 'ultrachat_533748'])
- **`[single-session-preference]` `195a1a1b`** (`miss_at_5`): *Can you suggest some activities that I can do in the evening?* (gold=['answer_6dc4305e'], got=['87fff4b4_1', 'sharegpt_DwfIyV9_0', '9f12daa1_1'])
- **`[single-session-preference]` `06f04340`** (`miss_at_5`): *What should I serve for dinner this weekend with my homegrown ingredients?* (gold=['answer_92d5f7cd'], got=['6e6fbb6b', 'cf543226_2', 'b459f888_3'])
- **`[single-session-preference]` `d6233ab6`** (`miss_at_5`): *I've been feeling nostalgic lately. Do you think it would be a good idea to attend my high school reunion?* (gold=['answer_b0fac439'], got=['f916c63a_2', '87cfeb28_2', 'ultrachat_125013'])
- **`[single-session-preference]` `1c0ddc50`** (`miss_at_5`): *Can you suggest some activities I can do during my commute to work?* (gold=['answer_8da8c7e0'], got=['b33e89b5_1', '2aa70c9c_1', 'a0aa5035'])
- **`[multi-session]` `8e91e7d9`** (`miss_at_5`): *What is the total number of siblings I have?* (gold=['answer_477ae455_1', 'answer_477ae455_2'], got=['sharegpt_8lpX5R7_19', 'sharegpt_PZrBCF2_0', '2f980ae0_2'])
- **`[temporal-reasoning]` `gpt4_7f6b06db`** (`miss_at_5`): *What is the order of the three trips I took in the past three months, from earliest to latest?* (gold=['answer_5d8c99d3_1', 'answer_5d8c99d3_2', 'answer_5d8c99d3_3'], got=['252715f8_2', 'd9ca4aca', '39c1bf6a'])
