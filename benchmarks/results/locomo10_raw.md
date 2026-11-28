# Raw Memory Benchmark Report — `locomo` (raw+semantic+rerank)

- **Engine**: `raw-memory-v0.7.0-calibrated-hierarchical-rerank`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`716.96 ms`, p95=`1096.05 ms`, wall=`1516.91 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 53.2% | 83.5% | 89.5% | 72.7% | 79.6% | 66.2% | 68.6% | 66.0% | 64.4% | 70.6% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 52.7% | 88.8% | 95.5% | 87.9% | 72.5% | 68.2% | 88.8% |
| `multi_hop` | 282 | 41.1% | 71.3% | 80.1% | 16.3% | 39.1% | 54.1% | 24.8% |
| `open_domain` | 92 | 25.0% | 47.8% | 58.7% | 30.4% | 31.1% | 34.7% | 12.0% |
| `single_hop` | 841 | 59.1% | 89.7% | 94.2% | 87.3% | 75.2% | 72.0% | 77.8% |
| `temporal` | 321 | 57.0% | 81.0% | 86.0% | 75.1% | 67.6% | 66.9% | 45.2% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D1:15', 'D14:7'])
- **`[multi_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D11:14', 'D11:13'])
- **`[multi_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D18:7', 'D19:6', 'D19:4'])
- **`[open_domain]` `conv-26#q27`** (`miss_at_5`): *Would Caroline pursue writing as a career option?* (gold=['D7:5', 'D7:9'], got=['D1:9', 'D1:11', 'D1:10'])
- **`[multi_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D11:2', 'D6:4', 'D10:9'])
- **`[temporal]` `conv-26#q35`** (`miss_at_5`): *When did Melanie go camping in July?* (gold=['D9:1'], got=['D10:12', 'D10:14', 'D8:32'])
- **`[multi_hop]` `conv-26#q38`** (`miss_at_5`): *What activities has Melanie done with her family?* (gold=['D1:18', 'D3:14', 'D6:4', 'D8:4', 'D8:6', 'D9:1'], got=['D8:34', 'D3:22', 'D4:10'])
- **`[open_domain]` `conv-26#q42`** (`miss_at_5`): *Would Melanie be more interested in going to a national park or a theme park?* (gold=['D10:12', 'D10:14'], got=['D15:2', 'D15:3', 'D15:4'])
