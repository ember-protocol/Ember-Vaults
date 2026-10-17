# Ember Vaults v10 — Frontier-AI Security Review (Claude Opus 5.5)

## Review details

| | |
|---|---|
| Model | Claude Opus 5.5 (`claude-opus-5-5`), Anthropic |
| Date | 2026-10-17 |
| Run by | Bluefin security team |
| Timing | After deployment. v10 has been live on mainnet since 2026-09-28. |
| Scope | The v9 → v10 upgrade: every production-code change, reviewed together with the code that calls it and the code it calls. The new modules (`atomic_liquidity_vault`, `strategy`, `common`) are in scope in full. |

## Release

| | |
|---|---|
| Package (v10) | `0xb82df65c5bae83c2f4c5eb4ec2fc57cc124b228cd9aef7a60ddb7d89c4e2b88e` |
| Upgrade transaction | `4ui3Q18hRTyAaL3sRM1Ko8ps7ZQeGbBBcWe96yqBwpTB` (2026-09-28 22:27:18 UTC) |
| Target commit | [`dedb4103200b81d276a62a4db6791a5e133446f6`](https://github.com/ember-protocol/Ember-Vaults/commit/dedb4103200b81d276a62a4db6791a5e133446f6) (this repository) |
| Baseline (v9) | Package `0xca7d744fc2fd0282b11d5a1362712dc2a1f8f8e6104040e0dd54e1b3970e4d97`, commit `e186028` (private development repository) |

Both versions were rebuilt and match the on-chain packages byte-for-byte: v10 with Sui CLI `mainnet-v1.80.1`, v9 with `mainnet-v1.76.1`.

The new atomic liquidity vault was also audited by OtterSec. Issues that report already lists are not repeated here, except where noted.

## Results

No Critical, High or Medium vulnerabilities found.

| ID | Severity | Title |
|---|---|---|
| AI-01 | Low | The swap capacity limit can be exceeded twofold at the window boundary |

### AI-01 — Swap capacity limit can be doubled

**Where:** `atomic_liquidity_vault.move` epoch capacity check

The comment describes a rolling 24h epoch, but the code resets `epoch_used_amount` to 0 once 24h have passed since `epoch_started_at`. Filling the cap just before the reset and again just after gives twice the configured intake in a short span. Anyone can set the window's start with a small first swap. The utilization and absolute caps still apply.

**Fix:** use a decaying or true rolling window, or size the cap for twice its intended value.
