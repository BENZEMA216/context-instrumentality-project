# Raw Memory Academic E2E LLM-as-a-Judge Report — `longmemeval-s`

- **Memory Engine**: `raw-memory-v0.9.0-top10-agentic-2turn` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)
- **Blind Reader LLM**: `openai/gpt-4o-mini` (zero gold visibility)
- **Independent Judge LLM**: `openai/gpt-4o (ICLR-2025 official judge)` (official academic prompt)
- **Evaluated Questions**: `500` (`470` positive + `30` abstention/adversarial)
- **Overall E2E Accuracy (`J-Score`)**: **68.2%** (Positive: **68.5%** · Abstention: **63.3%**)
- **Retrieval Grounding**: `R@5 = 99.2%` · `R@10 = 99.2%`
- **Context Efficiency**: Avg **9630 tokens** vs `124792` full history (**-92.3%** prompt tokens)

## Per-Category Breakdown

| Official Pillar | N | E2E Accuracy | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: |
| `abstention` | 30 | **63.3%** | 100.0% | 100.0% |
| `knowledge-update` | 72 | **80.6%** | 100.0% | 100.0% |
| `multi-session` | 121 | **56.2%** | 100.0% | 100.0% |
| `single-session-assistant` | 56 | **96.4%** | 100.0% | 100.0% |
| `single-session-preference` | 30 | **40.0%** | 93.3% | 93.3% |
| `single-session-user` | 64 | **98.4%** | 100.0% | 100.0% |
| `temporal-reasoning` | 127 | **52.8%** | 98.4% | 98.4% |

## Sample E2E Errors (for Failure Audit)

- **`b86304ba` (`single-session-user`, ret_hit@5=True)**: How much is the painting of a sunset worth in terms of the amount I paid for it?
  - Gold: `The painting is worth triple what I paid for it.`
  - Pred: `The value of the painting of a sunset is not mentioned in the provided memory excerpts, so I cannot determine how much it is worth in relation to the amount you`
  - Judge: The model response does not provide the correct answer or any equivalent information.
- **`f4f1d8a4_abs` (`abstention`, ret_hit@5=True)**: What did my dad gave me as a birthday gift?
  - Gold: `You did not mention this information. You mentioned receiving a birthday gift from your sister, but not your dad.`
  - Pred: `Your dad gave you a new stand mixer as a birthday gift last month.`
  - Judge: The model incorrectly provided a specific answer instead of identifying the question as unanswerable due to missing information.
- **`0a995998` (`multi-session`, ret_hit@5=True)**: How many items of clothing do I need to pick up or return from a store?
  - Gold: `3`
  - Pred: `You need to pick up one pair of boots from Zara that you exchanged.`
  - Judge: The response mentions only one item, a pair of boots, which does not match the correct answer of 3 items.
- **`6d550036` (`multi-session`, ret_hit@5=True)**: How many projects have I led or am currently leading?
  - Gold: `2`
  - Pred: `You have led one project as a senior software engineer, and you are currently leading that project with your team of five engineers.`
  - Judge: The response indicates only one project being led, not two as required by the correct answer.
- **`b5ef892d` (`multi-session`, ret_hit@5=True)**: How many days did I spend on camping trips in the United States this year?
  - Gold: `8 days.`
  - Pred: `6 days`
  - Judge: The model response states 6 days, which does not match the correct answer of 8 days.
- **`3a704032` (`multi-session`, ret_hit@5=True)**: How many plants did I acquire in the last month?
  - Gold: `3`
  - Pred: `You acquired two plants in the last month: a peace lily and a succulent, both from the nursery two weeks ago.`
  - Judge: The model response states that only two plants were acquired, not three as required by the correct answer.
- **`gpt4_d84a3211` (`multi-session`, ret_hit@5=True)**: How much total money have I spent on bike-related expenses since the start of the year?
  - Gold: `$185`
  - Pred: `You have spent a total of $65 on bike-related expenses since the start of the year, which includes $25 for a chain replacement and $40 for a new set of bike lig`
  - Judge: The model response states $65, which does not match the correct answer of $185.
- **`aae3761f` (`multi-session`, ret_hit@5=True)**: How many hours in total did I spend driving to my three road trip destinations combined?
  - Gold: `15 hours for getting to the three destinations (or 30 hours for the round trip)`
  - Pred: `You spent a total of 18 hours driving to your three road trip destinations combined: 4 hours to the Outer Banks, 7-8 hours to Tybee Island, and 6 hours to Washi`
  - Judge: The model response states 18 hours, which does not match the correct answer of 15 hours.
- **`c4a1ceb8` (`multi-session`, ret_hit@5=True)**: How many different types of citrus fruits have I used in my cocktail recipes?
  - Gold: `3`
  - Pred: `You have mentioned using orange and lemon in your cocktail recipes, specifically in the Sangria. Therefore, you have used 2 types of citrus fruits.`
  - Judge: The model response only mentions 2 types of citrus fruits, while the correct answer is 3.
- **`gpt4_a56e767c` (`multi-session`, ret_hit@5=True)**: How many movie festivals that I attended?
  - Gold: `I attended four movie festivals.`
  - Pred: `You attended two film festivals: the Austin Film Festival and AFI Fest.`
  - Judge: The model response states two film festivals, while the correct answer is four.
