# Raw Memory Benchmark Report — `locomo` (curated+semantic)

- **Engine**: `raw-memory-v0.5.0-hybrid-bm25-semantic`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`8.44 ms`, p95=`23.49 ms`, wall=`111.40 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 35.5% | 67.1% | 77.0% | 56.5% | 66.1% | 49.2% | 52.7% | 49.3% | 50.2% | 59.9% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 27.4% | 59.9% | 71.5% | 59.2% | 44.5% | 41.2% | 59.9% |
| `multi_hop` | 841 | 34.6% | 68.5% | 79.2% | 66.2% | 52.5% | 49.4% | 61.1% |
| `open_domain` | 92 | 27.2% | 45.6% | 58.7% | 25.0% | 29.7% | 35.1% | 7.6% |
| `single_hop` | 282 | 39.4% | 69.5% | 79.1% | 16.7% | 38.4% | 52.7% | 20.9% |
| `temporal` | 321 | 48.3% | 77.6% | 82.5% | 71.3% | 62.4% | 61.1% | 46.1% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D8:6', 'D14:30'])
- **`[single_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D11:12', 'D17:23', 'D16:9'])
- **`[single_hop]` `conv-26#q13`** (`miss_at_5`): *What career path has Caroline decided to persue?* (gold=['D1:11', 'D4:13'], got=['D4:11', 'D1:9', 'D7:5'])
- **`[single_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D6:4', 'D1:2', 'D9:1'])
- **`[temporal]` `conv-26#q21`** (`miss_at_5`): *When did Caroline have a picnic?* (gold=['D6:11'], got=['D13:7', 'D16:1', 'D14:7'])
- **`[single_hop]` `conv-26#q24`** (`miss_at_5`): *What does Melanie do to destress?* (gold=['D5:4', 'D7:22'], got=['D7:20', 'D7:24', 'D18:21'])
- **`[single_hop]` `conv-26#q34`** (`miss_at_5`): *What events has Caroline participated in to help children?* (gold=['D3:3', 'D9:2'], got=['D10:5', 'D3:5', 'D5:3'])
- **`[open_domain]` `conv-26#q42`** (`miss_at_5`): *Would Melanie be more interested in going to a national park or a theme park?* (gold=['D10:12', 'D10:14'], got=['D15:2', 'D9:1', 'D11:13'])
