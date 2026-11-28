# Raw Memory Academic E2E LLM-as-a-Judge Report — `locomo-curated`

- **Memory Engine**: `raw-memory-v0.8.1-graph-multihop-rerank` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)
- **Blind Reader LLM**: `gemini-flash (Antigravity blind worker)` (zero gold visibility)
- **Independent Judge LLM**: `gemini-flash (ACL-2024 / Mem0 official judge prompt)` (official academic prompt)
- **Evaluated Questions**: `492` (`392` positive + `100` abstention/adversarial)
- **Overall E2E Accuracy (`J-Score`)**: **75.0%** (Positive: **70.2%** · Abstention: **94.0%**)
- **Retrieval Grounding**: `R@5 = 76.8%` · `R@10 = 84.2%`
- **Context Efficiency**: Avg **1395 tokens** vs `26537` full history (**-94.7%** prompt tokens)
- **Official Normalized Token F1 (cat 1–4)**: **16.3%**

## Per-Category Breakdown

| Category | N | E2E Accuracy (`J-Score`) | Token F1 | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 100 | **94.0%** | — | 91.0% | 95.0% |
| `multi_hop` | 100 | **57.0%** | 14.9% | 81.0% | 88.0% |
| `open_domain` | 92 | **47.8%** | 9.6% | 54.4% | 65.2% |
| `single_hop` | 100 | **95.0%** | 25.7% | 86.0% | 92.0% |
| `temporal` | 100 | **79.0%** | 14.5% | 84.0% | 90.0% |

## Sample E2E Errors (for Failure Audit)

- **`conv-26#q15` (`multi_hop`, ret_hit@5=True)**: What activities does Melanie partake in?
  - Gold: `pottery, camping, painting, swimming`
  - Pred: `Melanie partakes in running, reading, playing the violin, pottery, and nature-inspired painting with her kids. She also goes camping with her family—hiking, exp`
  - Judge: Covers pottery, camping, and painting, but omits 'swimming' from the Gold multi-item list.
- **`conv-26#q23` (`multi_hop`, ret_hit@5=True)**: What books has Melanie read?
  - Gold: `"Nothing is Impossible", "Charlotte's Web"`
  - Pred: `Melanie read "Charlotte's Web" as a kid, read an unnamed book with a gold coin on the cover in 2022 ("last year" as of 12 July 2023), and as of 13 October 2023 `
  - Judge: Includes 'Charlotte's Web' but omits the book title 'Nothing is Impossible' (referring to it only as an unnamed book).
- **`conv-26#q39` (`multi_hop`, ret_hit@5=True)**: In what ways is Caroline participating in the LGBTQ community?
  - Gold: `Joining activist group, going to pride parades, participating in an art show, mentoring program`
  - Pred: `Caroline participates in the LGBTQ community by attending support groups, pride parades, and an LGBTQ conference; speaking at a school event; mentoring LGBTQ yo`
  - Judge: Covers activist group, pride parades, and mentoring program, but omits 'participating in an art show'.
- **`conv-26#q43` (`multi_hop`, ret_hit@5=False)**: What kind of art does Caroline make?
  - Gold: `abstract art`
  - Pred: `Caroline creates paintings and drawings—primarily paintings—focused on expressing her feelings, gender identity, and journey as a trans woman, featuring themes `
  - Judge: Describes paintings and themes but omits 'abstract art', which is the Gold answer.
- **`conv-26#q51` (`multi_hop`, ret_hit@5=True)**: What has Melanie painted?
  - Gold: `Horse, sunset, sunrise`
  - Pred: `Melanie has painted a lake sunrise (in 2022), a sunflower on canvas, and nature-inspired paintings with her kids—including a sunset with a palm tree. She also p`
  - Judge: Missing a key item from Gold ('Horse'): generated answer covers sunrise and sunset, but omits horse.
- **`conv-26#q56` (`multi_hop`, ret_hit@5=True)**: What symbols are important to Caroline?
  - Gold: `Rainbow flag, transgender symbol`
  - Pred: `Important symbols to Caroline include the rainbow flag and rainbow designs (representing the courage, strength, and togetherness of the trans community), the ea`
  - Judge: Missing a key item from Gold ('transgender symbol'): generated answer mentions the rainbow flag and other symbols, but omits the transgender symbol.
- **`conv-26#q59` (`open_domain`, ret_hit@5=True)**: Would Caroline be considered religious?
  - Gold: `Somewhat, but not extremely religious`
  - Pred: `The excerpts do not explicitly state whether Caroline is religious, so it cannot be definitively determined from the history. While she treasures a childhood ne`
  - Judge: Fails to match Gold ('Somewhat, but not extremely religious'): generated answer declines to answer, stating it cannot be definitively determined.
- **`conv-26#q69` (`open_domain`, ret_hit@5=False)**: What personality traits might Melanie say Caroline has?
  - Gold: `Thoughtful, authentic, driven`
  - Pred: `Melanie would likely describe Caroline as strong, brave, and inspiring for sharing her journey and speaking up for the trans community. She also views Caroline `
  - Judge: Does not cover the key traits in Gold ('Thoughtful, authentic, driven'): generated answer lists different traits (strong, brave, inspiring, supportive, dependab
- **`conv-26#q77` (`open_domain`, ret_hit@5=True)**: Would Melanie go on another roadtrip soon?
  - Gold: `Likely no; since this one went badly`
  - Pred: `It is not mentioned in the excerpts whether Melanie plans to go on another roadtrip soon. However, on 20 October 2023, she described her recent weekend roadtrip`
  - Judge: Fails to match Gold ('Likely no; since this one went badly'): generated answer abstains by saying it is not mentioned whether she plans to go on another roadtri
- **`conv-26#q78` (`multi_hop`, ret_hit@5=True)**: What items has Melanie bought?
  - Gold: `Figurines, shoes`
  - Pred: `According to the excerpts, Melanie bought figurines (shown as wooden dolls) on 21 October 2023 ("yesterday" in her 22 October 2023 message) that remind her of f`
  - Judge: Missing a key item from Gold ('shoes'): generated answer mentions figurines, but omits shoes.
