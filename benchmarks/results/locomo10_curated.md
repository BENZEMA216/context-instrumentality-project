# Raw Memory Benchmark Report — `locomo` (curated)

- **Engine**: `raw-memory-v0.3.0-hybrid-bm25`
- **Questions**: `1982` scored / `1986` total
- **Latency**: p50=`2.04 ms`, p95=`2.74 ms`, wall=`4.47 s`

## Overall Metrics

| R@1 | R@5 | R@10 | All-R@5 | All-R@10 | NDCG@5 | NDCG@10 | MRR | Ans-Cov@5 | Ans-Cov@10 |
| ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 34.2% | 61.3% | 72.5% | 50.9% | 61.5% | 45.4% | 49.1% | 46.2% | 46.4% | 56.1% |

## Breakdown by Category

| Category | N | R@1 | R@5 | R@10 | All-R@5 | NDCG@5 | MRR | Ans-Cov@5 |
| :--- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 446 | 33.2% | 62.3% | 73.5% | 60.8% | 48.6% | 45.9% | 62.3% |
| `multi_hop` | 841 | 33.1% | 61.5% | 73.5% | 58.6% | 47.8% | 45.8% | 54.5% |
| `open_domain` | 92 | 20.6% | 39.1% | 47.8% | 17.4% | 22.4% | 28.1% | 2.2% |
| `single_hop` | 282 | 29.8% | 57.1% | 69.2% | 9.9% | 27.8% | 41.7% | 15.6% |
| `temporal` | 321 | 46.4% | 69.2% | 78.5% | 62.6% | 56.8% | 57.0% | 43.0% |

## Sample Failure Cases (Top 8 for Debugging)

- **`[temporal]` `conv-26#q1`** (`miss_at_5`): *When did Melanie paint a sunrise?* (gold=['D1:12'], got=['D1:14', 'D14:30', 'D8:6'])
- **`[open_domain]` `conv-26#q2`** (`miss_at_5`): *What fields would Caroline be likely to pursue in her educaton?* (gold=['D1:11', 'D1:9'], got=['D7:8', 'D13:7', 'D13:3'])
- **`[single_hop]` `conv-26#q4`** (`miss_at_5`): *What is Caroline's identity?* (gold=['D1:5'], got=['D13:13', 'D11:12', 'D16:9'])
- **`[single_hop]` `conv-26#q7`** (`miss_at_5`): *What is Caroline's relationship status?* (gold=['D2:14', 'D3:13'], got=['D16:15', 'D13:3', 'D3:1'])
- **`[temporal]` `conv-26#q10`** (`miss_at_5`): *How long has Caroline had her current group of friends for?* (gold=['D3:13'], got=['D6:11', 'D12:15', 'D16:15'])
- **`[single_hop]` `conv-26#q13`** (`miss_at_5`): *What career path has Caroline decided to persue?* (gold=['D1:11', 'D4:13'], got=['D1:9', 'D4:11', 'D5:3'])
- **`[single_hop]` `conv-26#q19`** (`miss_at_5`): *What do Melanie's kids like?* (gold=['D4:8', 'D6:6'], got=['D1:2', 'D6:4', 'D1:18'])
- **`[temporal]` `conv-26#q21`** (`miss_at_5`): *When did Caroline have a picnic?* (gold=['D6:11'], got=['D13:3', 'D3:1', 'D5:5'])
