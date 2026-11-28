# Raw Memory Academic E2E LLM-as-a-Judge Report — `longmemeval-s`

- **Memory Engine**: `raw-memory-v0.9.0-top10-rankfirst` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)
- **Blind Reader LLM**: `gemini-flash (Antigravity blind worker)` (zero gold visibility)
- **Independent Judge LLM**: `openai/gpt-4o (ICLR-2025 official judge)` (official academic prompt)
- **Evaluated Questions**: `500` (`470` positive + `30` abstention/adversarial)
- **Overall E2E Accuracy (`J-Score`)**: **89.6%** (Positive: **88.9%** · Abstention: **100.0%**)
- **Retrieval Grounding**: `R@5 = 99.2%` · `R@10 = 99.2%`
- **Context Efficiency**: Avg **9630 tokens** vs `124792` full history (**-92.3%** prompt tokens)

## Per-Category Breakdown

| Official Pillar | N | E2E Accuracy | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: |
| `abstention` | 30 | **100.0%** | 100.0% | 100.0% |
| `knowledge-update` | 72 | **95.8%** | 100.0% | 100.0% |
| `multi-session` | 121 | **79.3%** | 100.0% | 100.0% |
| `single-session-assistant` | 56 | **96.4%** | 100.0% | 100.0% |
| `single-session-preference` | 30 | **80.0%** | 93.3% | 93.3% |
| `single-session-user` | 64 | **95.3%** | 100.0% | 100.0% |
| `temporal-reasoning` | 127 | **89.8%** | 98.4% | 98.4% |

## Sample E2E Errors (for Failure Audit)

- **`51a45a95` (`single-session-user`, ret_hit@5=True)**: Where did I redeem a $5 coupon on coffee creamer?
  - Gold: `Target`
  - Pred: `The conversation history does not mention where you redeemed the $5 coupon on coffee creamer. You only stated that you found it in your email inbox and redeemed`
  - Judge: The model response does not explicitly state that the coupon was redeemed at Target.
- **`ec81a493` (`single-session-user`, ret_hit@5=True)**: How many copies of my favorite artist's debut album were released worldwide?
  - Gold: `500`
  - Pred: `The conversation history does not mention how many copies of your favorite artist's debut album were released worldwide; it only states that the signed poster f`
  - Judge: The model response does not provide the number of copies released worldwide; it only mentions the number of signed posters.
- **`8a137a7f` (`single-session-user`, ret_hit@5=True)**: What type of bulb did I replace in my bedside lamp?
  - Gold: `Philips LED bulb`
  - Pred: `In the visible excerpts from May 22, 2023, you mentioned using a Philips LED bulb in your bedside lamp (while discussing replacing harsh overhead lighting in yo`
  - Judge: The response does not confirm the replacement of a bulb in the bedside lamp with a Philips LED bulb.
- **`0a995998` (`multi-session`, ret_hit@5=True)**: How many items of clothing do I need to pick up or return from a store?
  - Gold: `3`
  - Pred: `You have 1 item of clothing to pick up from a store: the new pair of boots from Zara after exchanging the pair you bought on February 5 (mentioned in the 2023/0`
  - Judge: The model response only mentions 1 item to pick up, while the correct answer is 3 items.
- **`3a704032` (`multi-session`, ret_hit@5=True)**: How many plants did I acquire in the last month?
  - Gold: `3`
  - Pred: `You acquired 2 plants in the past month (relative to May 30, 2023): a peace lily and a succulent, which you mentioned on May 20, 2023 as having gotten from the `
  - Judge: The model response states that 2 plants were acquired in the past month, which does not match the correct answer of 3 plants.
- **`dd2973ad` (`multi-session`, ret_hit@5=True)**: What time did I go to bed on the day before I had a doctor's appointment?
  - Gold: `2 AM`
  - Pred: `The excerpts do not state what time you went to bed on the day before your doctor's appointment. On May 24, 2023 (Wed), you mentioned having a 10 AM doctor's ap`
  - Judge: The model response does not state the correct bedtime of 2 AM for the day before the doctor's appointment.
- **`36b9f61e` (`multi-session`, ret_hit@5=True)**: What is the total amount I spent on luxury items in the past few months?
  - Gold: `$2,500`
  - Pred: `Based on the visible excerpts, you spent a total of $2,000 on luxury items: $800 on a luxury evening gown for a wedding (2023/05/24) and $1,200 on a Gucci desig`
  - Judge: The model response only accounts for $2,000 in luxury spending, which is less than the correct answer of $2,500.
- **`gpt4_2f8be40d` (`multi-session`, ret_hit@5=True)**: How many weddings have I attended in this year?
  - Gold: `I attended three weddings. The couples were Rachel and Mike, Emily and Sarah, and Jen and Tom.`
  - Pred: `In 2023 (up to October 15, 2023), you attended 4 distinct named weddings: Emily and Sarah's city rooftop garden wedding (referred to as both your friend/college`
  - Judge: The model response lists four weddings, which is inconsistent with the correct answer of three weddings.
- **`gpt4_15e38248` (`multi-session`, ret_hit@5=True)**: How many pieces of furniture did I buy, assemble, sell, or fix in the past few months?
  - Gold: `4`
  - Pred: `You bought, assembled, or fixed 3 pieces of furniture in the past few months: you assembled an IKEA bookshelf for your home office (about two months before May `
  - Judge: The model response lists only 3 pieces of furniture, not 4 as required by the correct answer.
- **`7024f17c` (`multi-session`, ret_hit@5=True)**: How many hours of jogging and yoga did I do last week?
  - Gold: `0.5 hours`
  - Pred: `It is not mentioned in the conversation history how many hours of jogging or yoga you actually did last week (the week prior to May 30, 2023). The only logged w`
  - Judge: The response does not provide the correct answer of 0.5 hours.
