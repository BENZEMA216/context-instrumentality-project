# Raw Memory Academic E2E LLM-as-a-Judge Report — `locomo-curated`

- **Memory Engine**: `raw-memory-v0.9.0-agentic-2turn-graph` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)
- **Blind Reader LLM**: `google/gemini-2.5-flash` (zero gold visibility)
- **Independent Judge LLM**: `openai/gpt-4o (ACL-2024 / Mem0 official judge)` (official academic prompt)
- **Evaluated Questions**: `492` (`392` positive + `100` abstention/adversarial)
- **Overall E2E Accuracy (`J-Score`)**: **73.8%** (Positive: **68.9%** · Abstention: **93.0%**)
- **Retrieval Grounding**: `R@5 = 76.8%` · `R@10 = 84.2%`
- **Context Efficiency**: Avg **1395 tokens** vs `26537` full history (**-94.7%** prompt tokens)
- **Official Normalized Token F1 (cat 1–4)**: **19.9%**

## Per-Category Breakdown

| Category | N | E2E Accuracy (`J-Score`) | Token F1 | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 100 | **93.0%** | — | 91.0% | 95.0% |
| `multi_hop` | 100 | **48.0%** | 20.4% | 81.0% | 88.0% |
| `open_domain` | 92 | **60.9%** | 10.6% | 54.4% | 65.2% |
| `single_hop` | 100 | **88.0%** | 27.9% | 86.0% | 92.0% |
| `temporal` | 100 | **78.0%** | 19.9% | 84.0% | 90.0% |

## Sample E2E Errors (for Failure Audit)

- **`conv-26#q7` (`multi_hop`, ret_hit@5=True)**: What is Caroline's relationship status?
  - Gold: `Single`
  - Pred: `Caroline experienced a tough breakup in the past and has since focused on having genuine relationships with friends who accept and love her. She is also looking`
  - Judge: The generated answer does not directly address Caroline's current relationship status as 'Single'.
- **`conv-26#q15` (`multi_hop`, ret_hit@5=True)**: What activities does Melanie partake in?
  - Gold: `pottery, camping, painting, swimming`
  - Pred: `Melanie partakes in running, reading, playing the violin, pottery, camping, hiking, exploring forests, visiting museums, going to parks, attending concerts, and`
  - Judge: The generated answer includes pottery, camping, and painting, but it does not mention swimming, which is a key activity in the gold answer.
- **`conv-26#q17` (`temporal`, ret_hit@5=True)**: When is Caroline going to the transgender conference?
  - Gold: `July 2023`
  - Pred: `Caroline attended an LGBTQ conference two days before July 12, 2023, which would be July 10, 2023. She had previously mentioned looking forward to a transgender`
  - Judge: The generated answer provides a specific date in July 2023, but it does not clearly state that Caroline is going to the transgender conference in July 2023. It 
- **`conv-26#q23` (`multi_hop`, ret_hit@5=True)**: What books has Melanie read?
  - Gold: `"Nothing is Impossible", "Charlotte's Web"`
  - Pred: `Melanie loved reading "Charlotte's Web" as a child and mentioned reading a book last year that reminded her to pursue her dreams. She also stated she was readin`
  - Judge: The generated answer does not mention 'Nothing is Impossible', which is part of the gold answer.
- **`conv-26#q34` (`multi_hop`, ret_hit@5=False)**: What events has Caroline participated in to help children?
  - Gold: `Mentoring program, school speech`
  - Pred: `Caroline has participated in several events to help children, including organizing a talent show for kids at an LGBTQ+ youth center, mentoring a transgender tee`
  - Judge: The generated answer includes additional events not mentioned in the gold answer, such as organizing a talent show and adoption-related activities, which are no
- **`conv-26#q39` (`multi_hop`, ret_hit@5=True)**: In what ways is Caroline participating in the LGBTQ community?
  - Gold: `Joining activist group, going to pride parades, participating in an art show, mentoring program`
  - Pred: `Caroline participates in the LGBTQ community by attending support groups and conferences, joining an activist group called 'Connected LGBTQ Activists', voluntee`
  - Judge: The generated answer includes attending support groups, conferences, and giving talks, which are not mentioned in the gold answer. It also omits attending pride
- **`conv-26#q43` (`multi_hop`, ret_hit@5=False)**: What kind of art does Caroline make?
  - Gold: `abstract art`
  - Pred: `Caroline primarily creates paintings and drawings. Her art focuses on expressing her trans experience, exploring her gender identity, and educating others about`
  - Judge: The generated answer does not specify the type of art as 'abstract art', which is the key factual content of the gold answer.
- **`conv-26#q45` (`temporal`, ret_hit@5=True)**: When did Caroline attend a pride parade in August?
  - Gold: `The Friday before 14 August 2023`
  - Pred: `Caroline attended a pride parade on Friday, August 9th, 2023, as mentioned on August 14th, 2023.`
  - Judge: The generated answer states August 9th, 2023, which is incorrect as August 9th, 2023, is a Wednesday. The correct date should be the Friday before August 14th, 
- **`conv-26#q51` (`multi_hop`, ret_hit@5=True)**: What has Melanie painted?
  - Gold: `Horse, sunset, sunrise`
  - Pred: `Melanie has painted a sunflower, a lake sunrise, a sunset with a palm tree (with her kids), another painting similar to the sunset with a palm tree (with her ki`
  - Judge: The generated answer does not mention a horse, which is a key item in the gold answer.
- **`conv-26#q56` (`multi_hop`, ret_hit@5=True)**: What symbols are important to Caroline?
  - Gold: `Rainbow flag, transgender symbol`
  - Pred: `The rainbow flag mural symbolizes the courage and strength of the trans community, and the eagle represents freedom and pride. A necklace from her grandmother s`
  - Judge: The generated answer does not mention the rainbow flag or transgender symbol, which are the key symbols in the gold answer.
