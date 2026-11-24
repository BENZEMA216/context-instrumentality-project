# Raw Memory Benchmark Report — `locomo` (raw)

- **Engine**: `raw-memory-v0.3.0-hybrid-bm25`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`0.96 ms`, p95=`1.45 ms`, wall=`2.33 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 37.0% | 61.7% | 69.6% | 52.7% | 60.0% | 47.3% | 50.0% | 47.5% | 46.7% | 54.3% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 37.4% | 63.9% | 73.1% | 62.8% | 51.4% | 48.9% | 63.9% |
| `multi_hop` | 841 | 38.9% | 65.5% | 72.3% | 62.8% | 52.4% | 50.1% | 55.2% |
| `open_domain` | 92 | 17.4% | 34.8% | 41.3% | 16.3% | 21.9% | 25.9% | 2.2% |
| `single_hop` | 282 | 24.1% | 47.2% | 60.6% | 7.1% | 22.8% | 34.2% | 13.5% |
| `temporal` | 321 | 48.3% | 69.2% | 73.5% | 62.6% | 57.3% | 56.7% | 42.4% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D14:30', 'D11:8'])
- **`[open_domain]` `conv-26#q2`** (`miss_at_5`): *What fields would Caroline be likely to pursue in her educaton?* (gold=['D1:11', 'D1:9'], got=['D13:7', 'D4:14', 'D8:8'])
- **`[single_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D13:13', 'D11:12', 'D17:19'])
- **`[single_hop]` `conv-26#q7`** (`miss_at_5`): *What is Caroline's relationship status?* (gold=['D2:14', 'D3:13'], got=['D16:14', 'D16:15', 'D19:13'])
- **`[temporal]` `conv-26#q10`** (`miss_at_5`): *How long has Caroline had her current group of friends for?* (gold=['D3:13'], got=['D6:11', 'D12:15', 'D6:12'])
- **`[single_hop]` `conv-26#q13`** (`miss_at_5`): *What career path has Caroline decided to persue?* (gold=['D1:11', 'D4:13'], got=['D4:12', 'D15:23', 'D1:9'])
- **`[single_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D19:4', 'D19:6', 'D1:2'])
- **`[single_hop]` `conv-26#q24`** (`miss_at_5`): *What does Melanie do to destress?* (gold=['D5:4', 'D7:22'], got=['D7:20', 'D19:14', 'D15:18'])
