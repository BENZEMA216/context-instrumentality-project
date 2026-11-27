# Raw Memory Benchmark Report — `locomo` (raw+semantic+rerank)

- **Engine**: `raw-memory-v0.6.0-maxsim-temporal-rerank`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`179.56 ms`, p95=`224.88 ms`, wall=`357.76 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 47.4% | 80.3% | 86.9% | 69.6% | 76.5% | 61.7% | 64.2% | 61.1% | 61.2% | 67.8% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 44.0% | 84.1% | 91.7% | 82.7% | 65.5% | 60.8% | 84.1% |
| `multi_hop` | 841 | 52.8% | 86.1% | 91.6% | 83.7% | 70.0% | 66.5% | 73.6% |
| `open_domain` | 92 | 25.0% | 43.5% | 57.6% | 27.2% | 29.6% | 33.0% | 9.8% |
| `single_hop` | 282 | 36.5% | 69.2% | 78.7% | 17.0% | 37.2% | 50.8% | 23.4% |
| `temporal` | 321 | 54.2% | 80.1% | 83.8% | 72.9% | 65.4% | 64.5% | 44.5% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D1:15', 'D14:7'])
- **`[single_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D17:19', 'D3:3'])
- **`[single_hop]` `conv-26#q13`** (`miss_at_5`): *What career path has Caroline decided to persue?* (gold=['D1:11', 'D4:13'], got=['D4:12', 'D4:11', 'D7:7'])
- **`[single_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D19:4', 'D18:7', 'D18:8'])
- **`[single_hop]` `conv-26#q24`** (`miss_at_5`): *What does Melanie do to destress?* (gold=['D5:4', 'D7:22'], got=['D7:20', 'D2:5', 'D12:12'])
- **`[open_domain]` `conv-26#q27`** (`miss_at_5`): *Would Caroline pursue writing as a career option?* (gold=['D7:5', 'D7:9'], got=['D1:9', 'D7:7', 'D4:11'])
- **`[temporal]` `conv-26#q33`** (`miss_at_5`): *When did Caroline go to a pride parade during the summer?* (gold=['D5:1'], got=['D8:17', 'D12:16', 'D8:18'])
- **`[single_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D11:2', 'D6:4', 'D8:32'])
