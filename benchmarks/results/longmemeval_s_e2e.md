# Raw Memory Academic E2E LLM-as-a-Judge Report — `longmemeval-s`

- **Memory Engine**: `raw-memory-v0.8.0-graph-multihop-rerank` (100% Local SQLite + ONNX Embeddings + Cross-Encoder + Entity Graph)
- **Blind Reader LLM**: `gemini-flash (Antigravity blind worker)` (zero gold visibility)
- **Independent Judge LLM**: `gemini-flash (ICLR-2025 official judge prompt)` (official academic prompt)
- **Evaluated Questions**: `500` (`470` positive + `30` abstention/adversarial)
- **Overall E2E Accuracy (`J-Score`)**: **84.4%** (Positive: **83.4%** · Abstention: **100.0%**)
- **Retrieval Grounding**: `R@5 = 99.2%` · `R@10 = 99.2%`
- **Context Efficiency**: Avg **8490 tokens** vs `127940` full history (**-93.4%** prompt tokens)

## Per-Category Breakdown

| Official Pillar | N | E2E Accuracy | Retrieval R@5 | Retrieval R@10 |
| :--- | ---: | ---: | ---: | ---: |
| `abstention` | 30 | **100.0%** | 100.0% | 100.0% |
| `knowledge-update` | 72 | **90.3%** | 100.0% | 100.0% |
| `multi-session` | 121 | **74.4%** | 100.0% | 100.0% |
| `single-session-assistant` | 56 | **76.8%** | 100.0% | 100.0% |
| `single-session-preference` | 30 | **93.3%** | 93.3% | 93.3% |
| `single-session-user` | 64 | **95.3%** | 100.0% | 100.0% |
| `temporal-reasoning` | 127 | **82.7%** | 98.4% | 98.4% |

## Sample E2E Errors (for Failure Audit)

- **`e47becba` (`single-session-user`, ret_hit@5=True)**: What degree did I graduate with?
  - Gold: `Business Administration`
  - Pred: `Your past conversations do not mention what degree you graduated with, so this cannot be answered from the provided history.`
  - Judge: The model abstained and failed to provide the correct answer (Business Administration).
- **`51a45a95` (`single-session-user`, ret_hit@5=True)**: Where did I redeem a $5 coupon on coffee creamer?
  - Gold: `Target`
  - Pred: `The excerpts do not explicitly state which store you redeemed the $5 coffee creamer coupon at. In the May 29, 2023 session, you only mentioned finding the coupo`
  - Judge: The model claimed the excerpts do not state which store the coupon was redeemed at instead of answering Target.
- **`8a137a7f` (`single-session-user`, ret_hit@5=True)**: What type of bulb did I replace in my bedside lamp?
  - Gold: `Philips LED bulb`
  - Pred: `The memory excerpts do not mention replacing a bulb in your bedside lamp or what type of bulb was replaced. They only state that you currently have and use a wa`
  - Judge: Model response explicitly abstains/denies knowing what bulb was replaced ('do not mention replacing a bulb in your bedside lamp or what type of bulb was replace
- **`0a995998` (`multi-session`, ret_hit@5=True)**: How many items of clothing do I need to pick up or return from a store?
  - Gold: `3`
  - Pred: `You have 1 item to pick up from a store: the replacement pair of boots at Zara that you exchanged on February 5th (mentioned on 2023/02/15 at 11:13 and 16:19; w`
  - Judge: Model response states 1 item (and mentions a dry cleaner item already being picked up), whereas the correct answer is 3.
- **`6d550036` (`multi-session`, ret_hit@5=True)**: How many projects have I led or am currently leading?
  - Gold: `2`
  - Pred: `You have led or are currently leading 3 clearly stated projects: (1) your Marketing Research class project, where you led the data analysis team (2023/05/21), (`
  - Judge: Model response states 3 projects, whereas the correct answer is 2.
- **`gpt4_59c863d7` (`multi-session`, ret_hit@5=True)**: How many model kits have I worked on or bought?
  - Gold: `I have worked on or bought five model kits. The scales of the models are: Revell F-15 Eagle (scale not mentioned), Tamiya 1/48 scale Spitfire Mk.V, 1/16 scale G`
  - Pred: `You have specifically mentioned 4 model kits that you bought or worked on: (1) a Revell F-15 Eagle kit bought in late April and finished (2023/05/27), (2) a 1/7`
  - Judge: Model response states 4 model kits and misses the Tamiya 1/48 scale Spitfire Mk.V, whereas the correct answer is 5.
- **`3a704032` (`multi-session`, ret_hit@5=True)**: How many plants did I acquire in the last month?
  - Gold: `3`
  - Pred: `You acquired 2 plants in the last month as of May 30, 2023: a peace lily and a succulent, which you got from the nursery two weeks before your May 20, 2023 sess`
  - Judge: Model response states 2 plants and excludes the snake plant, whereas the correct answer is 3.
- **`dd2973ad` (`multi-session`, ret_hit@5=True)**: What time did I go to bed on the day before I had a doctor's appointment?
  - Gold: `2 AM`
  - Pred: `This cannot be answered from your conversation history. Although your May 24, 2023 session notes that you had a doctor's appointment at 10:00 AM on Thursday, Ma`
  - Judge: Model response incorrectly claims the question cannot be answered, whereas the correct answer is 2 AM.
- **`28dc39ac` (`multi-session`, ret_hit@5=True)**: How many hours have I spent playing games in total?
  - Gold: `140 hours`
  - Pred: `You have spent a total of 115 hours playing games based on your stated playtimes: ~70 hours on Assassin's Creed Odyssey (2023/05/20), 5 hours on Hyper Light Dri`
  - Judge: The model response states 115 hours instead of the correct answer of 140 hours.
- **`gpt4_2f8be40d` (`multi-session`, ret_hit@5=True)**: How many weddings have I attended in this year?
  - Gold: `I attended three weddings. The couples were Rachel and Mike, Emily and Sarah, and Jen and Tom.`
  - Pred: `You have attended 4 weddings in 2023: your cousin Rachel's vineyard wedding in August (2023/10/15 05:48); your sister's wedding, where you were maid of honor (2`
  - Judge: The model response states 4 weddings instead of the correct answer of 3 weddings.
