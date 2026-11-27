# Raw Memory Benchmark Report — `locomo` (raw+semantic)

- **Engine**: `raw-memory-v0.5.0-hybrid-bm25-semantic`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`19.04 ms`, p95=`91.48 ms`, wall=`363.21 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 33.7% | 64.1% | 76.5% | 54.3% | 66.8% | 46.9% | 51.2% | 46.9% | 47.2% | 59.3% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 20.2% | 51.8% | 72.2% | 50.4% | 36.7% | 34.8% | 51.8% |
| `multi_hop` | 841 | 39.2% | 71.3% | 81.5% | 68.7% | 55.5% | 52.6% | 60.5% |
| `open_domain` | 92 | 16.3% | 37.0% | 53.3% | 21.7% | 22.7% | 26.2% | 7.6% |
| `single_hop` | 282 | 29.1% | 59.2% | 72.7% | 13.5% | 30.6% | 42.5% | 18.1% |
| `temporal` | 321 | 47.0% | 74.1% | 79.4% | 67.3% | 59.7% | 58.4% | 43.0% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D14:30', 'D14:7'])
- **`[single_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D17:19', 'D10:15'])
- **`[single_hop]` `conv-26#q13`** (`miss_at_5`): *What career path has Caroline decided to persue?* (gold=['D1:11', 'D4:13'], got=['D1:9', 'D4:11', 'D7:7'])
- **`[single_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D2:9', 'D1:2', 'D2:15'])
- **`[single_hop]` `conv-26#q24`** (`miss_at_5`): *What does Melanie do to destress?* (gold=['D5:4', 'D7:22'], got=['D7:20', 'D13:18', 'D7:6'])
- **`[open_domain]` `conv-26#q27`** (`miss_at_5`): *Would Caroline pursue writing as a career option?* (gold=['D7:5', 'D7:9'], got=['D1:9', 'D4:11', 'D4:14'])
- **`[single_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D10:6', 'D7:27', 'D8:9'])
- **`[single_hop]` `conv-26#q37`** (`miss_at_5`): *What did Melanie paint recently?* (gold=['D8:6', 'D9:17'], got=['D16:12', 'D9:15', 'D1:6'])
