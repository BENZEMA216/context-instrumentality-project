# Raw Memory Academic E2E LLM-as-a-Judge Report — `locomo-curated`

- **Memory Engine**: `raw-memory-v0.9.0-agentic-2turn-graph` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)
- **Blind Reader LLM**: `openai/gpt-4o-mini` (zero gold visibility)
- **Independent Judge LLM**: `openai/gpt-4o (ACL-2024 / Mem0 official judge)` (official academic prompt)
- **Evaluated Questions**: `492` (`392` positive + `100` abstention/adversarial)
- **Overall E2E Accuracy (`J-Score`)**: **64.2%** (Positive: **65.3%** · Abstention: **60.0%**)
- **Retrieval Grounding**: `R@5 = 76.8%` · `R@10 = 84.2%`
- **Context Efficiency**: Avg **1395 tokens** vs `26537` full history (**-94.7%** prompt tokens)
- **Official Normalized Token F1 (cat 1–4)**: **21.8%**

## Per-Category Breakdown

| Category | N | E2E Accuracy (`J-Score`) | Token F1 | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: | ---: |
| `adversarial` | 100 | **60.0%** | — | 91.0% | 95.0% |
| `multi_hop` | 100 | **46.0%** | 20.8% | 81.0% | 88.0% |
| `open_domain` | 92 | **51.1%** | 12.0% | 54.4% | 65.2% |
| `single_hop` | 100 | **90.0%** | 29.8% | 86.0% | 92.0% |
| `temporal` | 100 | **73.0%** | 23.9% | 84.0% | 90.0% |

## Sample E2E Errors (for Failure Audit)

- **`conv-26#q3` (`multi_hop`, ret_hit@5=True)**: What did Caroline research?
  - Gold: `Adoption agencies`
  - Pred: `Caroline is researching adoption agencies to fulfill her dream of having a family and providing a loving home to children in need. Additionally, she is looking `
  - Judge: The generated answer includes additional topics (counseling and mental health work) not mentioned in the gold answer.
- **`conv-26#q7` (`multi_hop`, ret_hit@5=True)**: What is Caroline's relationship status?
  - Gold: `Single`
  - Pred: `Caroline's relationship status is not explicitly mentioned in the excerpts. However, she has experienced changes in her relationships, particularly after a toug`
  - Judge: The generated answer does not explicitly state that Caroline is single, which is the core factual content of the gold answer.
- **`conv-26#q15` (`multi_hop`, ret_hit@5=True)**: What activities does Melanie partake in?
  - Gold: `pottery, camping, painting, swimming`
  - Pred: `Melanie partakes in running, reading, playing the violin, pottery, camping, hiking, exploring nature, and nature-inspired painting projects with her kids.`
  - Judge: The generated answer includes pottery, camping, and painting, but it does not mention swimming, which is a key activity in the gold answer.
- **`conv-26#q23` (`multi_hop`, ret_hit@5=True)**: What books has Melanie read?
  - Gold: `"Nothing is Impossible", "Charlotte's Web"`
  - Pred: `Melanie has mentioned reading "Charlotte's Web" as a favorite from her childhood. Additionally, she referred to a book she read last year that inspired her to p`
  - Judge: The generated answer does not mention 'Nothing is Impossible', which is part of the gold answer.
- **`conv-26#q34` (`multi_hop`, ret_hit@5=False)**: What events has Caroline participated in to help children?
  - Gold: `Mentoring program, school speech`
  - Pred: `Caroline has participated in organizing a talent show for kids at a youth center, volunteered at an LGBTQ+ youth center, mentored a transgender teen, and gave a`
  - Judge: The generated answer includes events not mentioned in the gold answer and does not mention the mentoring program or school speech.
- **`conv-26#q39` (`multi_hop`, ret_hit@5=True)**: In what ways is Caroline participating in the LGBTQ community?
  - Gold: `Joining activist group, going to pride parades, participating in an art show, mentoring program`
  - Pred: `Caroline participates in the LGBTQ community by joining the 'Connected LGBTQ Activists' group, giving talks about her transgender journey to inspire students, a`
  - Judge: The generated answer includes additional activities not mentioned in the gold answer, such as giving talks and attending LGBTQ conferences, which are not part o
- **`conv-26#q43` (`multi_hop`, ret_hit@5=False)**: What kind of art does Caroline make?
  - Gold: `abstract art`
  - Pred: `Caroline creates art primarily through painting, focusing on expressing her trans experience, exploring her gender identity, and promoting self-acceptance and l`
  - Judge: The generated answer does not specify the type of art as 'abstract art'.
- **`conv-26#q51` (`multi_hop`, ret_hit@5=True)**: What has Melanie painted?
  - Gold: `Horse, sunset, sunrise`
  - Pred: `Melanie has painted landscapes, still life, a lake sunrise, nature-inspired projects with her kids, and abstract art inspired by sunsets. Recently, she created `
  - Judge: The generated answer does not mention 'horse' and only indirectly references 'sunset' and 'sunrise' without clearly stating them as subjects of Melanie's painti
- **`conv-26#q56` (`multi_hop`, ret_hit@5=True)**: What symbols are important to Caroline?
  - Gold: `Rainbow flag, transgender symbol`
  - Pred: `Important symbols to Caroline include the rainbow flag, which represents courage and strength of the trans community; an eagle, symbolizing freedom and pride; a`
  - Judge: The generated answer does not mention the transgender symbol, which is a key item in the gold answer.
- **`conv-26#q59` (`open_domain`, ret_hit@5=True)**: Would Caroline be considered religious?
  - Gold: `Somewhat, but not extremely religious`
  - Pred: `Caroline's experiences suggest she may not identify as religious, especially given her negative encounter with religious conservatives and her focus on LGBTQ ri`
  - Judge: The generated answer suggests Caroline may not identify as religious, which contradicts the gold answer indicating she is somewhat religious.
