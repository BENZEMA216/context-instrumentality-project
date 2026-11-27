# Raw Memory Benchmark Report — `locomo` (curated+semantic+rerank)

- **Engine**: `raw-memory-v0.6.0-maxsim-temporal-rerank`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`308.04 ms`, p95=`373.84 ms`, wall=`723.13 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 56.7% | 82.2% | 87.8% | 71.4% | 77.2% | 67.1% | 69.3% | 67.6% | 61.3% | 67.3% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 53.8% | 82.3% | 88.8% | 81.2% | 69.0% | 65.9% | 82.3% |
| `multi_hop` | 841 | 61.1% | 86.8% | 91.0% | 84.1% | 74.3% | 71.9% | 72.1% |
| `open_domain` | 92 | 29.3% | 52.2% | 63.0% | 30.4% | 34.8% | 39.5% | 7.6% |
| `single_hop` | 282 | 47.5% | 75.5% | 84.8% | 24.5% | 45.6% | 60.0% | 29.8% |
| `temporal` | 321 | 65.1% | 84.7% | 88.2% | 77.9% | 73.8% | 73.6% | 46.7% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D8:6', 'D14:7'])
- **`[single_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D13:13', 'D3:3'])
- **`[single_hop]` `conv-26#q13`** (`miss_at_5`): *What career path has Caroline decided to persue?* (gold=['D1:11', 'D4:13'], got=['D4:11', 'D1:9', 'D5:3'])
- **`[single_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D16:4', 'D6:4', 'D15:2'])
- **`[temporal]` `conv-26#q21`** (`miss_at_5`): *When did Caroline have a picnic?* (gold=['D6:11'], got=['D16:1', 'D12:1', 'D4:9'])
- **`[single_hop]` `conv-26#q24`** (`miss_at_5`): *What does Melanie do to destress?* (gold=['D5:4', 'D7:22'], got=['D7:20', 'D2:5', 'D7:24'])
- **`[open_domain]` `conv-26#q27`** (`miss_at_5`): *Would Caroline pursue writing as a career option?* (gold=['D7:5', 'D7:9'], got=['D1:9', 'D4:11', 'D7:8'])
- **`[single_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D19:6', 'D15:11', 'D10:7'])
