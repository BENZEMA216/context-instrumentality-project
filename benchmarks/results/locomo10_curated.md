# Raw Memory Benchmark Report — `locomo` (curated+semantic+rerank)

- **Engine**: `raw-memory-v0.7.0-calibrated-hierarchical-rerank`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`846.13 ms`, p95=`1050.60 ms`, wall=`1715.14 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 62.2% | 86.0% | 90.4% | 75.1% | 80.4% | 71.5% | 73.4% | 72.3% | 63.5% | 69.2% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 62.6% | 87.7% | 91.7% | 86.6% | 76.1% | 73.2% | 87.7% |
| `multi_hop` | 282 | 51.8% | 79.1% | 87.9% | 26.2% | 47.9% | 63.3% | 29.4% |
| `open_domain` | 92 | 33.7% | 55.4% | 64.1% | 33.7% | 37.6% | 42.2% | 8.7% |
| `single_hop` | 841 | 65.9% | 90.4% | 93.3% | 88.2% | 78.7% | 76.3% | 74.9% |
| `temporal` | 321 | 69.5% | 86.9% | 90.3% | 79.4% | 76.6% | 77.0% | 45.5% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D14:7', 'D8:6'])
- **`[multi_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D13:13', 'D3:3'])
- **`[multi_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D6:4', 'D8:6', 'D15:2'])
- **`[temporal]` `conv-26#q21`** (`miss_at_5`): *When did Caroline have a picnic?* (gold=['D6:11'], got=['D16:1', 'D8:19', 'D12:16'])
- **`[open_domain]` `conv-26#q27`** (`miss_at_5`): *Would Caroline pursue writing as a career option?* (gold=['D7:5', 'D7:9'], got=['D1:9', 'D4:11', 'D1:11'])
- **`[multi_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D15:11', 'D19:6', 'D9:6'])
- **`[open_domain]` `conv-26#q42`** (`miss_at_5`): *Would Melanie be more interested in going to a national park or a theme park?* (gold=['D10:12', 'D10:14'], got=['D15:2', 'D15:3', 'D15:4'])
- **`[multi_hop]` `conv-26#q43`** (`miss_at_5`): *What kind of art does Caroline make?* (gold=['D11:12', 'D11:8', 'D9:14'], got=['D16:7', 'D16:9', 'D11:10'])
