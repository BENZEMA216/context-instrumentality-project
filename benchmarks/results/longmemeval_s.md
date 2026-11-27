# Raw Memory Benchmark Report — `longmemeval-s` (hub_retrieval+semantic)

- **Engine**: `raw-memory-v0.5.0-hybrid-bm25-semantic`
- **Questions**: `470` scored / `500` total (`30` abstention `_abs` tracked separately)
- **Latency**: p50=`5.84 ms`, p95=`8.81 ms`, wall=`60.72 s`

## Overall Metrics (Session-Level & Turn-Level Retrieval)

| Sess R@1 | Sess R@5 | Sess R@10 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn R@10 | Turn NDCG@5 | Ans-Cov@5 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 86.2% | 97.7% | 98.7% | 87.2% | 90.0% | 85.1% | 92.8% | 58.2% | 62.8% |

## Breakdown by Official LongMemEval Pillar

| Question Type | N | Sess R@1 | Sess R@5 | Sess All-R@5 | Sess NDCG@5 | Turn R@5 | Turn NDCG@5 | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `knowledge-update` | 72 | 94.4% | 100.0% | 98.6% | 97.0% | 91.7% | 61.1% | 80.6% |
| `multi-session` | 121 | 90.9% | 100.0% | 76.0% | 89.8% | 87.6% | 49.4% | 54.5% |
| `single-session-assistant` | 56 | 89.3% | 100.0% | 100.0% | 95.8% | 87.5% | 69.7% | 91.1% |
| `single-session-preference` | 30 | 76.7% | 90.0% | 90.0% | 84.3% | 70.0% | 47.1% | 6.7% |
| `single-session-user` | 64 | 79.7% | 100.0% | 100.0% | 91.9% | 87.5% | 74.9% | 93.8% |
| `temporal-reasoning` | 127 | 81.1% | 93.7% | 78.7% | 83.9% | 80.3% | 54.0% | 45.7% |

**Abstention (`_abs`, N=30)**: Refuting-session R@5=`100.0%`, R@10=`100.0%`, zero-hit rate=`0.0%`

## Sample Failure Cases (Top 8 for Debugging)

- **`[single-session-preference]` `75832dbd`** (`miss_at_5`): *Can you recommend some recent publications or conferences that I might find interesting?* (gold=['answer_d87a6ef8'], got=['c51583cd_1', 'ultrachat_533748', 'sharegpt_xni9yYO_6'])
- **`[single-session-preference]` `06f04340`** (`miss_at_5`): *What should I serve for dinner this weekend with my homegrown ingredients?* (gold=['answer_92d5f7cd'], got=['6e6fbb6b', '91223fd5_1', 'cf543226_2'])
- **`[single-session-preference]` `1c0ddc50`** (`miss_at_5`): *Can you suggest some activities I can do during my commute to work?* (gold=['answer_8da8c7e0'], got=['2aa70c9c_1', 'b33e89b5_1', 'a0aa5035'])
- **`[temporal-reasoning]` `gpt4_e061b84f`** (`miss_at_5`): *What is the order of the three sports events I participated in during the past month, from earliest to latest?* (gold=['answer_8c64ce25_1', 'answer_8c64ce25_2', 'answer_8c64ce25_3'], got=['9345f7dc_4', '0a6bf5e4_1', '4cc9270f'])
- **`[temporal-reasoning]` `gpt4_1e4a8aec`** (`miss_at_5`): *What gardening-related activity did I do two weeks ago?* (gold=['answer_16bd5ea6_1', 'answer_16bd5ea6_2'], got=['b34a52aa_3', '9f1f3bf4', '743b1fc3_2'])
- **`[temporal-reasoning]` `gpt4_59149c78`** (`miss_at_5`): *I mentioned that I participated in an art-related event two weeks ago. Where was that event held at?* (gold=['answer_d00ba6d1_1', 'answer_d00ba6d1_2'], got=['23754665', 'ultrachat_463998', 'b2341a22'])
- **`[temporal-reasoning]` `gpt4_4929293b`** (`miss_at_5`): *What was the the life event of one of my relatives that I participated in a week ago?* (gold=['answer_add9b013_1', 'answer_add9b013_2'], got=['bda611f6_3', 'sharegpt_rqvR1Ep_0', 'ultrachat_326769'])
- **`[temporal-reasoning]` `gpt4_468eb064`** (`miss_at_5`): *Who did I meet with during the lunch last Tuesday?* (gold=['answer_9b09d95b_1'], got=['1e5bd28d_2', '25e5b797_1', 'cc3c5fa9_1'])
