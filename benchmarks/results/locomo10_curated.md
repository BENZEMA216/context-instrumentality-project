# Raw Memory Benchmark Report — `locomo` (curated+semantic+rerank)

- **Engine**: `raw-memory-v0.8.1-graph-multihop-rerank`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`1080.02 ms`, p95=`1380.16 ms`, wall=`2195.49 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 62.5% | 86.2% | 90.9% | 75.3% | 81.0% | 71.6% | 73.7% | 72.4% | 63.9% | 69.5% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 62.8% | 87.9% | 92.6% | 87.0% | 76.1% | 73.2% | 87.9% |
| `multi_hop` | 282 | 52.8% | 80.5% | 89.0% | 25.2% | 47.8% | 63.9% | 30.1% |
| `open_domain` | 92 | 33.7% | 54.4% | 65.2% | 34.8% | 37.2% | 41.7% | 8.7% |
| `single_hop` | 841 | 65.6% | 90.6% | 93.6% | 88.9% | 78.8% | 76.2% | 75.6% |
| `temporal` | 321 | 70.4% | 86.3% | 90.3% | 79.1% | 76.9% | 77.5% | 45.2% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D14:7', 'D8:6'])
- **`[multi_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D13:13', 'D3:3'])
- **`[multi_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D6:4', 'D15:2', 'D8:6'])
- **`[temporal]` `conv-26#q21`** (`miss_at_5`): *When did Caroline have a picnic?* (gold=['D6:11'], got=['D8:19', 'D16:1', 'D12:16'])
- **`[open_domain]` `conv-26#q27`** (`miss_at_5`): *Would Caroline pursue writing as a career option?* (gold=['D7:5', 'D7:9'], got=['D1:9', 'D1:11', 'D4:11'])
- **`[multi_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D15:11', 'D19:6', 'D13:1'])
- **`[open_domain]` `conv-26#q42`** (`miss_at_5`): *Would Melanie be more interested in going to a national park or a theme park?* (gold=['D10:12', 'D10:14'], got=['D15:2', 'D15:3', 'D16:2'])
- **`[multi_hop]` `conv-26#q43`** (`miss_at_5`): *What kind of art does Caroline make?* (gold=['D11:12', 'D11:8', 'D9:14'], got=['D16:7', 'D16:9', 'D11:10'])
