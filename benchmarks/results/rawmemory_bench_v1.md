# RawMemory-Bench v1.0.0 Scorecard

- **Engine**: `raw-memory-v0.5.0`
- **SHA-256 Lock**: `faaf53763019a000...` (VERIFIED)
- **Overall Pass Rate**: **100.0%** (`32/32`)
- **Safety & Isolation**: Stale Leakage `0.0%` · Cross-Project Bleed `0` · Privacy Leaks `0` · Poisoning Block `100.0%` · TTL Pass `100.0%`
- **Prompt Cache & Speed**: Stable Prefix Ratio `68.7%` · Avg Tokens `417` · p50 `31.96 ms` / p95 `194.98 ms`

| Pillar | Passed | Total | Pass Rate |
| :--- | ---: | ---: | ---: |
| `cold_start_continuation` | 4 | 4 | **100.0%** |
| `correction_avoidance` | 4 | 4 | **100.0%** |
| `supersession_no_stale` | 4 | 4 | **100.0%** |
| `cross_channel_fusion` | 4 | 4 | **100.0%** |
| `cross_project_isolation` | 4 | 4 | **100.0%** |
| `memory_poisoning_defense` | 4 | 4 | **100.0%** |
| `ttl_and_no_overgeneralization` | 3 | 3 | **100.0%** |
| `privacy_and_vault_boundary` | 3 | 3 | **100.0%** |
| `prompt_cache_stability` | 2 | 2 | **100.0%** |
