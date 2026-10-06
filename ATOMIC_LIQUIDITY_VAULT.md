# Atomic Liquidity Vault — Technical Documentation

A companion to [DOCUMENTATION.md](DOCUMENTATION.md). The latter covers the
original `vault.move` (request-based redemption, ERC-20-style receipt token).
This document focuses on `atomic_liquidity_vault.move` — the variant that
adds internal share accounting, external lending strategies, instant
withdrawals, and cross-vault EmberShare swapping.

## Table of Contents

- [Overview](#overview)
- [What's different from `vault.move`](#whats-different-from-vaultmove)
- [Architecture](#architecture)
- [State model](#state-model)
- [Roles and permissions](#roles-and-permissions)
- [Lifecycle](#lifecycle)
- [Core deposit / redeem flow](#core-deposit--redeem-flow)
- [Instant withdraw](#instant-withdraw)
- [External strategies (Suilend)](#external-strategies-suilend)
- [Cross-vault EmberShare swap](#cross-vault-embershare-swap)
- [Withdrawal fees](#withdrawal-fees)
- [Pause flags](#pause-flags)
- [Public API reference](#public-api-reference)
- [Events](#events)
- [Error codes](#error-codes)
- [Operations runbook](#operations-runbook)
- [Security considerations](#security-considerations)
- [Differences from EVM `AtomicLiquidity.sol`](#differences-from-evm-atomicliquiditysol)

---

## Overview

The atomic liquidity vault is a request-based, rate-priced collateral vault
that adds three capabilities on top of the standard Ember vault:

1. **Non-transferable internal shares.** User balances live in a
   `Table<address, u64>` instead of a `Coin<R>` receipt token. The vault is
   `AtomicLiquidityVault<phantom T>` — single generic, no `R`. Mirrors the
   EVM `AtomicLiquidity.sol`'s `mapping(address => uint256)` design.

2. **External supply-only lending strategy.** Idle vault assets can be
   parked in Suilend. The active strategy is identified
   by a `u8` tag; protocol-specific state (cTokens, position cap, market
   IDs) lives in dynamic fields hung off `vault.id`. Adding a third strategy
   later is forward-compatible because there's no enum to widen.

3. **Cross-vault EmberShare swap.** Admin whitelists other Ember vaults'
   receipt-token types (`Coin<R>` for any `R`); users can atomically
   exchange those shares for this vault's underlying collateral, paying a
   per-share fee and accepting a deferred holdback queue. The collected
   shares are later submitted into the source vault's normal redemption
   queue by the operator.

Plus: per-vault withdrawal fees (permanent + time-based) using the same
dynamic-field pattern as `vault.move`.

## What's different from `vault.move`

| Concern | `vault.move` | `atomic_liquidity_vault.move` |
|---|---|---|
| Type parameters | `Vault<phantom T, phantom R>` | `AtomicLiquidityVault<phantom T>` |
| Receipt | `Coin<R>` minted via `TreasuryCap<R>` | None — `shares: Table<address, u64>` |
| Rate manager | Stored in dynamic field, set post-create | Stored in struct field, set at create-time |
| Pause flag | Single `paused: bool` | Three independent flags: `paused_deposits`, `paused_withdrawals`, `paused_privileged_operations` |
| Strategy | None | `u8` tag + dynamic fields, supply into Suilend |
| Instant withdraw | None | Cumulative-capped, per-share fee, auto-pulls from strategy |
| EmberShare swap | None | Cross-vault swap with epoch-rate-limited holdback queue |
| Withdrawal fees | Optional dynamic-field pattern | Same — see [Withdrawal fees](#withdrawal-fees) |

## Architecture

```
sources/
├── admin.move                  Protocol config, AdminCap, version gate (shared)
├── common.move                 Pure helpers shared across both vault flavours
├── events.move                 Event types (atomic vault adds 13 new types)
├── math.move                   1e9 fixed-point math (shared)
├── queue.move                  FIFO Queue<T> generic (shared)
├── vault.move                  Original receipt-token vault (unchanged behavior)
├── atomic_liquidity_vault.move CORE — this doc covers it
├── strategy.move               Suilend supply-only adapter
└── gateway.move                Entry-function wrappers (atomic_* prefix)

external_stubs/
├── suilend/                    Local interface stubs for Suilend's mainnet pkg
```

Module dependency graph (atomic-vault subset):

```
                    admin ── events ── math ── queue
                      ▲       ▲       ▲       ▲
                      │       │       │       │
                      └───────┴───────┴───────┘
                              │
                           common (FEE_DENOMINATOR, update_accounts,
                                   compute_platform_fee_delta,
                                   assert_role_candidate_valid)
                              │
                              ▼
                   atomic_liquidity_vault ◄── strategy ◄── suilend / alpha_lending stubs
                              ▲
                              │
                          gateway (entry fun atomic_*)
```

`vault.move` and `atomic_liquidity_vault.move` are independent peers — they
share `common.move` for primitive helpers but otherwise have no dependency
on each other. The `atomic_liquidity_vault` module imports `vault::Vault`
and `vault::redeem_shares` only for the cross-vault EmberShare swap path
where it acts as a client of an Ember vault.

## State model

```move
public struct AtomicLiquidityVault<phantom T> has key {
    id: UID,
    name: String,

    // Roles (mutable post-create via admin setters)
    admin: address,
    operator: address,
    rate_manager: address,
    sub_accounts: vector<address>,
    blacklisted: vector<address>,

    // Three independent pause flags
    paused_deposits: bool,
    paused_withdrawals: bool,
    paused_privileged_operations: bool,

    // Pricing & fee accrual
    rate: Rate,                         // value, max_change, interval, last_updated_at
    fee_percentage: u64,                // 1e9 = 100%/year
    fee: PlatformFee,                   // accrued, last_charged_at

    // INTERNAL share accounting (no Coin<R>)
    shares: Table<address, u64>,        // per-user balance
    total_shares: u64,                  // sum of shares + pending_burn_shares
    pending_burn_shares: u64,           // shares parked for in-flight withdrawals

    // Limits
    min_withdrawal_shares: u64,
    max_tvl: u64,

    // Underlying-T balance held idle in the vault
    balance: Balance<T>,

    // Withdrawal queue + per-account state
    pending_withdrawals: Queue<WithdrawalRequest>,
    accounts: Table<address, Account>,

    // Active strategy (0=NONE, 1=SUILEND)
    strategy_kind: u8,

    // Instant-withdraw state (initialized to 0 on create)
    max_instant_withdraw_shares: u64,
    cumulative_instant_withdraw_shares: u64,
    instant_withdraw_fee_percentage: u64,

    // Cross-vault EmberShare swap state
    ember_share_configs: Table<ID, EmberShareConfig>,   // keyed by source vault ID
    holdback_queues: Table<ID, Queue<HoldbackEntry>>,   // FIFO per source share
    fee_waived_addresses: vector<address>,
    holdback_waived_addresses: vector<address>,

    sequence_number: u128,
}
```

### Dynamic fields hung off `vault.id`

| Key | Value type | Set by | Purpose |
|---|---|---|---|
| `b"withdrawal_fee"` | `WithdrawalFee` | `set_permanent_fee_percentage` etc, lazy on first `deposit` | Permanent + time-based withdrawal fee config + last-deposit timestamps |
| `b"al_strategy_suilend_reserve_idx"` | `u64` | `strategy::init_suilend_state` | Suilend reserve array index |
| `b"al_strategy_suilend_market_id"` | `ID` | `strategy::init_suilend_state` | Committed `LendingMarket<P>` object ID |
| `b"al_strategy_suilend_coin_type"` | `TypeName` | `strategy::init_suilend_state` | Committed collateral type `T` |
| `b"al_strategy_suilend_obligation_cap"` | `ObligationOwnerCap<P>` | `strategy::open_suilend_obligation` | Obligation capability (also pins `P`) |
| `b"al_strategy_suilend_obligation_id"` | `ID` | `strategy::open_suilend_obligation` | Obligation object ID |
| `CollectedEmberSharesKey { source_vault_id }` | `Balance<R>` | `swap_ember_shares` | Per-source-vault collected receipt tokens |

The dynamic-field schema means adding a new strategy in a future package
upgrade only requires adding new key constants and new functions — no
struct migration needed.

### Share accounting invariant

At any moment:

```
total_shares  ==  Σ shares[u]  +  pending_burn_shares
```

- `deposit`: `shares[receiver] += s`, `total_shares += s`
- `redeem_shares`: `shares[owner] -= s`, `pending_burn_shares += s`,
  `total_shares` UNCHANGED (matches EVM)
- `process_request` (success): `pending_burn_shares -= s`, `total_shares -= s`
- `process_request` (skip/cancel): `pending_burn_shares -= s`,
  `shares[owner] += s`, `total_shares` UNCHANGED
- `instant_withdraw`: `shares[owner] -= s`, `total_shares -= s`,
  `cumulative_instant_withdraw_shares += s`

## Roles and permissions

Same role taxonomy as `vault.move`:

| Role | Capability source | What they can do |
|---|---|---|
| Protocol admin | Holds `AdminCap` (created at `admin::init`) | Rotate vault admin, bump package version, configure protocol-wide rate/fee bounds |
| Vault admin | `vault.admin` address (mutable via protocol admin) | All admin setters: name, max_tvl, max_rate_change, rate update interval, operator, rate_manager, fee_percentage, min_withdrawal_shares, sub_accounts, pause flags, instant-withdraw cap & fee, ember-share whitelist, swap waivers, **strategy selection**, **withdrawal-fee config** |
| Operator | `vault.operator` address (mutable by admin) | Blacklist accounts, settle withdrawal queue, supply/withdraw strategy, supply to/from sub-accounts, collect platform fees, release holdback queue, redeem collected ember shares, claim received collateral, **fee exemption list** |
| Rate manager | `vault.rate_manager` address (mutable by admin) | `update_vault_rate` (only this) |
| Sub-account | Address on `vault.sub_accounts` | Receive operator-initiated transfers without share-mint or share-burn |

The five role addresses must be distinct from each other AND must not
appear on the sub-account or blacklist lists. `common::assert_role_candidate_valid`
enforces this on every role-rotation call.

## Lifecycle

### 1. Vault creation

```
gateway::create_atomic_vault<T>(
    config, AdminCap, name,
    admin, operator, rate_manager,
    max_rate_change_per_update, fee_percentage, min_withdrawal_shares,
    rate_update_interval, max_tvl, sub_accounts,
    ctx,
)
```

Constructs the vault, emits `AtomicVaultCreatedEvent<T>`, and `share_object`s
it. Protocol-admin-only (requires `&AdminCap`). Initial state:

- `total_shares = 0`, `pending_burn_shares = 0`, `balance = 0`
- `strategy_kind = STRATEGY_NONE`
- `max_instant_withdraw_shares = 0`, `instant_withdraw_fee_percentage = 0`
  (admin enables instant withdraw later via dedicated setters)
- All three pause flags = false
- `sequence_number = 0`

### 2. Optional admin setup

Before opening to users, admin typically:

- Sets withdrawal fees (`set_permanent_fee_percentage`,
  `set_time_based_fee_percentage`, `set_time_based_fee_threshold`) if needed
- Activates a strategy (`set_strategy_suilend`)
- Raises `max_instant_withdraw_shares` and sets
  `instant_withdraw_fee_percentage` if instant withdraw should be enabled
- Whitelists EmberShares for cross-vault swap
  (`set_ember_share_whitelist`)

### 3. Steady state

- Users `deposit`, `redeem_shares`, optionally `instant_withdraw` or
  `swap_ember_shares`
- Operator periodically calls `process_withdrawal_requests` to settle the
  queue, `supply_to_*_strategy` / `withdraw_from_*_strategy` to manage
  yield, `release_users_holdback` to settle the EmberShare holdback queue,
  `collect_platform_fee` to forward accrued fees to the protocol fee
  recipient
- Rate manager calls `update_vault_rate` at most once per
  `rate_update_interval`

## Core deposit / redeem flow

### Deposit

```move
gateway::atomic_deposit<T>(
    vault, config, coin: Coin<T>, min_shares: u64,
    receiver: Option<address>, clock, ctx,
)
```

Steps:

1. Verify package version + protocol not paused + deposits not paused
2. `bump_sequence(vault)`, `charge_accrued_platform_fees(vault, clock)`
3. Check depositor + receiver are not blacklisted, not sub-accounts
4. Join `coin` into `vault.balance`
5. Compute `shares_minted = math::mul(amount, vault.rate.value)` and assert
   `shares_minted >= min_shares` (slippage protection)
6. `shares[receiver] += shares_minted`, `total_shares += shares_minted`
7. Assert `get_vault_tvl(vault) <= max_tvl`
8. Emit `VaultDepositEvent<T>`
9. Record `last_deposit_ts[depositor] = clock.timestamp_ms()` for the
   time-based withdrawal-fee calculation (creates the `WithdrawalFee`
   dynamic field on first call)

### Redeem (request-based)

```move
gateway::atomic_redeem_shares<T>(
    vault, config, shares: u64,
    receiver: Option<address>, clock, ctx,
)
```

User signals "I want to convert these shares to underlying"; settlement
happens later when operator calls `process_withdrawal_requests`. Steps:

1. Verify version + protocol pause + withdrawals pause
2. Check owner + receiver not blacklisted
3. Assert `shares >= min_withdrawal_shares` and
   `shares[owner] >= shares`
4. Move shares: `shares[owner] -= s`, `pending_burn_shares += s`
5. Build `WithdrawalRequest` and enqueue into `pending_withdrawals`
6. Update per-account `Account.pending_withdrawal_requests`
7. Emit `RequestRedeemedEvent<T>`

### Cancellation

```move
gateway::atomic_cancel_pending_withdrawal_request<T>(vault, config, sequence_number, ctx)
```

Owner-only. Marks a queued request for cancellation; the cancel becomes
visible only when the operator processes the request — at that point the
request is "skipped" and shares return to `shares[owner]`.

### Settlement (operator)

```move
gateway::atomic_process_withdrawal_requests<T>(vault, config, max_requests, clock, ctx)
gateway::atomic_process_withdrawal_requests_up_to_timestamp<T>(vault, config, timestamp, clock, ctx)
```

Loops over the queue. For each request:

- **Skip path** (owner/receiver blacklisted, or cancelled, or
  `withdraw_amount == 0`):
  - `pending_burn_shares -= s`, `shares[owner] += s`
  - Withdraw amount reported as 0
- **Settle path**:
  - `pending_burn_shares -= s`, `total_shares -= s`
  - **Apply withdrawal fees** (see [Withdrawal fees](#withdrawal-fees))
  - Transfer `(withdraw_amount - fees)` of T to `request.receiver`
  - The fee amounts STAY in `vault.balance` (improving TVL/share for
    remaining holders, mirrors `vault.move`)

Emits `RequestProcessedEvent<T>` per request, then a single
`ProcessRequestsSummaryEvent` at the end. Fees emit a separate
`WithdrawalFeeChargedEvent` per request when non-zero.

## Instant withdraw

Allows a user to burn shares immediately and receive collateral in the same
transaction, subject to a cumulative cap and a per-burn fee. Mirrors EVM's
`instantWithdraw` exactly.

### Setup (admin)

```move
gateway::atomic_set_max_instant_withdraw_shares<T>(vault, config, new_max, ctx)
gateway::atomic_set_instant_withdraw_fee_percentage<T>(vault, config, fee_pct, ctx)
```

Both default to 0 — instant withdraw is disabled at vault creation. Admin
explicitly opts in by raising `max_instant_withdraw_shares` and (optionally)
setting a fee. The cap is **cumulative over the vault's lifetime**, not a
rate limit: setting `new_max < cumulative_instant_withdraw_shares` halts
further instant withdrawals until raised again.

### Three variants (one per strategy)

```move
// Strategy = NONE — fails if vault.balance < net_amount
gateway::atomic_instant_withdraw<T>(vault, config, shares, receiver, clock, ctx)

// Strategy = SUILEND — auto-pulls deficit from Suilend
gateway::atomic_instant_withdraw_with_suilend<T, P>(
    vault, config, market: &mut LendingMarket<P>,
    shares, receiver, clock, ctx,
)

```

The right variant is determined by the vault's `strategy_kind`. Calling the
wrong one aborts with `EStrategyMismatch`. Sui Move has no dynamic dispatch
so this is the cleanest approach — see [Architecture](#architecture).

### Flow (`do_instant_withdraw_core` + variant wrapper)

1. Verify version + protocol pause + withdrawals pause
2. Verify the wrapper's strategy variant matches `vault.strategy_kind`
3. Verify owner + receiver not blacklisted
4. Assert `shares >= min_withdrawal_shares` and
   `shares[owner] >= shares`
5. Assert `cumulative + shares <= max_instant_withdraw_shares`
6. Settle accrued time-based platform fees (against OLD `total_shares`)
7. Compute `gross = math::div(shares, rate)`,
   `fee = gross * instant_withdraw_fee_percentage`,
   `net = gross - fee`
8. Burn shares: `shares[owner] -= s`, `total_shares -= s`,
   `cumulative_instant_withdraw_shares += s`
9. **Accrue fee into `platform_fee.accrued`** (different from withdrawal
   fees — this fee IS routed into platform_fee, matching EVM)
10. **Auto-pull from strategy if needed** (variant-specific):
    deficit = max(0, net - vault.balance); pull deficit from strategy
11. Split `net` from `vault.balance` and transfer to receiver
12. Emit `InstantWithdrawnEvent<T>`

## External strategies (Suilend)

The strategy module (`strategy.move`) is supply-only — no borrow flows.
Each strategy stores its state as dynamic fields on the vault's UID.

### Strategy tag

```move
const STRATEGY_NONE: u8     = 0;
const STRATEGY_SUILEND: u8  = 1;
```

`vault.strategy_kind` holds the active value. Switching is done via the
setter functions; the previous strategy must be fully unwound first.

### Activating Suilend

Two calls. The first is a pure ember-side state commitment that never enters
Suilend; the second opens the obligation the supply will live in.

```move
// 1. Commit reserve index, market object, and collateral type T.
gateway::atomic_set_strategy_suilend<T, P>(
    vault, config,
    market: &LendingMarket<P>,
    reserve_array_index: u64,    // looked up off-chain via lending_market::reserve_array_index<P, T>
    ctx,
)                                // admin only

// 2. Open the obligation. Required before the first supply.
gateway::atomic_open_suilend_obligation<T, P>(
    vault, config,
    market: &mut LendingMarket<P>,
    ctx,
)                                // admin OR operator
```

Step 1 aborts if `vault.strategy_kind != STRATEGY_NONE`. Step 2 aborts with
`EStrategyMismatch` unless the strategy is SUILEND, and with
`strategy::ESuilendObligationAlreadyExists` if one is already open.

**Half-activated is a reachable state, so assert against it.**
`get_strategy_kind() == 1` says step 1 ran, not that the vault can supply. Two
public views distinguish them:

```move
atomic_liquidity_vault::has_suilend_obligation<T>(vault): bool   // false on a non-Suilend vault
atomic_liquidity_vault::get_suilend_obligation_id<T>(vault): ID  // aborts ESuilendObligationMissing if not enrolled
```

**A reward destination must exist before activation.** All four strategy exits
assert `!vector::is_empty(vault.sub_accounts)` (`ENoRewardDestination`). Rewards
can only be forwarded to an allowlisted sub-account, so an empty list freezes the
sweep for every address — and the exits discard the capability, permanently
stranding anything accrued. Same hazard as the L-1 pause gate, reachable through
configuration instead of pausing: `create_atomic_liquidity_vault` permits an
empty allowlist, and `set_sub_account(_, false)` removes without a floor. Fix is
to allowlist a destination, sweep, then exit.

Activation tooling should check `has_suilend_obligation` before reporting
success. `get_suilend_obligation_id` is the only on-chain way to resolve the
obligation object — it lives in the lending market's `ObjectTable` and is not
derivable from vault state; off-chain readers can equally take it from
`SuilendObligationOpenedEvent`.

**Step 2 is not optional.** Suilend accounts liquidity-mining rewards against
an `Obligation` — reward share is its `deposited_ctoken_amount`, updated on
every deposit and withdraw — so cTokens held outside one earn the reserve's
base APR through the cToken ratio and no rewards at all. Supplying before the
obligation is open aborts with `strategy::ESuilendObligationMissing` rather
than silently falling back to raw cTokens, which would be indistinguishable
on chain from a reserve that pays nothing.

Enrolment costs no oracle dependency, which is why the whole deposit can live
inside the obligation rather than needing a raw-cToken buffer to serve users:
`withdraw_ctokens` takes no `PriceInfoObject`, calls `obligation::refresh`
itself, and `obligation::withdraw` discards the resulting stale-oracle signal
without asserting **when the obligation has no borrows**. The vault is
supply-only by construction — `strategy.move` exposes no borrow adapter — so
that holds permanently, and the user-facing instant-withdraw path stays
Pyth-free. Adding a borrow adapter would invalidate this and is the first
thing to re-examine if one is ever proposed.

### Returning to no-strategy

```move
gateway::atomic_set_strategy_none<T, P, OldT>(vault, config, ctx)
```

The two extra type parameters describe the *previous* strategy's typed
state so the dynamic-field cleanup can run with correct types. For previous
= SUILEND pass `<P, OldT>` matching the cTokens held; for previous = NONE the
placeholders are unused but must be supplied.

⚠️ **Suilend caveat**: `clear_suilend_state` auto-drains the obligation, then
discards the `ObligationOwnerCap` to `@0x0` (Suilend exposes no way to destroy
an obligation). It asserts the obligation reports zero deposited before doing
so — `strategy::ESuilendResidualDeposit` otherwise — so collateral cannot be
orphaned. **Rewards can be.** Sweep every live reward triple via
`atomic_claim_suilend_strategy_reward` before exiting, in the same PTB; once
the cap is gone the obligation is unreachable and anything unclaimed is lost.

Because that sweep is mandatory, both Suilend exits are pause-gated on
`verify_protocol_not_paused` + `!paused_privileged_operations` (L-1). A paused vault must not burn the cap while
`claim_suilend_strategy_reward` is frozen, since the sweep would be impossible
and every accrued reward stranded.

The teardown is also where the committed collateral type earns its keep:
`obligation::deposited_ctoken_amount<P, T>` selects the deposit by coin type
and returns 0 when it finds none, so a `clear` invoked with the wrong `T`
would read an empty position, skip the drain, and discard the cap over a live
deposit. `strategy::assert_suilend_coin_type` turns that into
`ESuilendCoinTypeMismatch`.

### Claiming Suilend rewards (admin or operator)

```move
gateway::atomic_claim_suilend_strategy_reward<T, P, RewardType>(
    vault, config,
    market: &mut LendingMarket<P>,
    sub_account: address,      // must be on the vault's sub-account allowlist
    reward_index: u64,
    is_deposit_reward: bool,
    clock, ctx,
)
```

Rewards are accounted per `(reserve, reward slot, deposit-or-borrow)` triple,
so a full sweep is one call per live triple — batch them in a single PTB. Old
slots stay occupied while they still hold `UserReward` entries, so a sweep must
scan **every** occupied slot, not just the live campaign; ended campaigns still
hold claimable `earned_rewards`.

### Where strategy rewards go

Both strategies' rewards go to a **whitelisted vault sub-account**, not the
protocol platform-fee recipient. One rule, no per-protocol exception:
`atomic_claim_suilend_strategy_reward`
and its `_sui` variant all take a `sub_account: address` checked against
`vault.sub_accounts` (`EInvalidAccount`), asserted before entering the lending
protocol so a bad address cannot cost a claim. Each emits
`StrategyRewardCollectedEvent<RewardType>` carrying the amount and recipient.

The destination matters because a sub-account has a route back and the fee
recipient does not: `deposit_from_sub_account` returns settled yield into
`vault.balance` **without minting shares**, so it reaches depositors as a higher
assets-per-share. Value sent to the fee recipient leaves the vault permanently.

Reward tokens are never the collateral type — Suilend pays sSUI on the main
pool's USDC reserve — so the swap leg is off chain. The full round trip is: claim → sub-account → swap to `T` off chain
→ `deposit_from_sub_account`. Nothing on chain links a claim to its return
deposit, so completeness is an ops-monitoring concern; note also that
`deposit_from_sub_account` attribution is operator-asserted, not authenticated
(I-12).

`reward_index` is a slot in the reserve's `pool_rewards` vector that a Suilend
admin can vacate, so the operator resolves it off chain per claim from the
reserve's `deposits_pool_reward_manager` rather than the vault storing it.
`is_deposit_reward` is `true` in practice — the vault only ever deposits — but
it is threaded through rather than hardcoded.

There is **no PTB price-refresh requirement**:
`claim_rewards` gates only on bad debt, which a supply-only obligation cannot
have. Callable by either trusted role so the admin running the admin-gated
exit can also sweep in that same PTB.

### Supply / withdraw (operator)

```move
// Suilend
gateway::atomic_supply_to_suilend_strategy<T, P>(vault, config, market, amount, clock, ctx)
gateway::atomic_withdraw_from_suilend_strategy<T, P>(vault, config, market, amount, clock, ctx)

```

Mechanics:

- **Suilend**: `deposit_liquidity_and_mint_ctokens<P, T>` returns
  `Coin<CToken<P, T>>`, which goes straight into the obligation via
  `deposit_ctokens_into_obligation<P, T>`. The vault retains no cTokens of
  its own. On withdraw, we compute `ctoken_amount = ceil(target /
  simulated_ctoken_ratio)`, pull exactly that many back out with
  `withdraw_ctokens<P, T>`, and redeem them via
  `redeem_ctokens_and_withdraw_liquidity<P, T>`. The actual received amount
  may be slightly more than requested due to ratio rounding — surplus is
  joined into vault.balance. Holding less than the computed minimum aborts
  `EStrategyInsufficientCTokens` (M-04).

  The withdraw always passes an explicit cToken amount, never Suilend's
  `u64::MAX` sentinel: the sentinel routes through `max_withdraw_amount`,
  which clamps to the market's rate limiter and would silently under-deliver.

### Auto-pull from strategy

`instant_withdraw_with_*` and `swap_ember_shares_with_*` automatically pull
liquidity from the strategy if `vault.balance` is insufficient. The deficit
is computed as `needed - balance`; the pull receives at least that amount
(possibly more due to Suilend ratio rounding) and joins the surplus into
`vault.balance`.

`process_withdrawal_requests` does **not** auto-pull — operator must ensure
adequate idle balance before settlement. Same as EVM behavior.

`release_users_holdback` also does not auto-pull; operator can call
`atomic_withdraw_from_*_strategy` and `atomic_release_users_holdback` in
the same PTB if needed.

## Cross-vault EmberShare swap

Lets a user atomically exchange another Ember vault's receipt token
(`Coin<R>`) for this atomic vault's underlying collateral, paying a fee
and accepting that part of the gross is held back until the operator
settles a batch later. The atomic vault collects the receipt tokens and
later forwards them into the source vault's normal redemption queue.

### Setup (admin)

```move
gateway::atomic_set_ember_share_whitelist<T>(
    vault, config,
    share_vault_id: ID,           // source vault's object ID
    whitelisted: bool,
    fee_percentage: u64,          // 1e9 = 100%
    max_capacity_percentage: u64, // 1e9 = 100% — fraction of source TVL allowed per epoch
    holdback_percentage: u64,     // 1e9 = 100% — held back for batch release
    ctx,
)
```

Constraints: `fee_percentage <= 1e9`, `holdback_percentage <= 1e9`,
`fee + holdback <= 1e9` (otherwise net payout would underflow).

De-listing (`whitelisted = false`) preserves any in-flight epoch state and
the holdback queue — a previously-active share remains rate-limited for
the rest of its current 24h window, and pending holdback entries continue
to be claimable via `release_users_holdback`.

### Per-account waivers (admin)

```move
gateway::atomic_set_swap_waiver<T>(
    vault, config, account, fee_waived: bool, holdback_waived: bool, ctx,
)
```

The two waivers are independent. A holdback-waived account receives the
held portion immediately as part of the net payout; no holdback queue
entry is created.

### Three swap variants (one per strategy)

```move
// Strategy = NONE — vault.balance must cover the immediate payout
gateway::atomic_swap_ember_shares<T, R>(
    vault, config, source_vault: &Vault<T, R>,
    share_coin: Coin<R>, receiver: Option<address>, clock, ctx,
)

// Strategy = SUILEND — auto-pulls deficit from Suilend
gateway::atomic_swap_ember_shares_with_suilend<T, R, P>(
    vault, config, source_vault, market, share_coin, receiver, clock, ctx,
)

```

### Flow (`do_swap_ember_shares_core` + variant wrapper)

1. Verify version + protocol pause + withdrawals pause
2. Verify wrapper's strategy variant matches `vault.strategy_kind`
3. Verify owner + receiver not blacklisted, receiver != @0
4. Validate source share is whitelisted (config exists and `whitelisted = true`)
5. Compute `gross = vault::calculate_amount_from_shares(source_vault, share_amount)`
6. **Epoch capacity check**: if `epoch_started_at == 0` or `now >= epoch_started_at + 24h`,
   reset epoch (set `epoch_started_at = now`, `epoch_used_amount = 0`).
   Then assert `epoch_used + gross <= source_tvl * max_capacity_percentage`.
   Increment `epoch_used_amount += gross`.
7. Compute fees:
   - `fee = fee_waived ? 0 : gross * fee_percentage`
   - `holdback_raw = gross * holdback_percentage`
   - `net = gross - fee - holdback_raw`
   - `immediate_payout = holdback_waived ? net + holdback_raw : net`
   - `queued_holdback = holdback_waived ? 0 : holdback_raw`
8. **Take share_coin into per-source collected balance** (dynamic field
   keyed by `CollectedEmberSharesKey { source_vault_id }` — value is
   `Balance<R>`)
9. Pay `immediate_payout` of T from `vault.balance` to receiver (variant
   wrapper has already auto-pulled liquidity if needed)
10. Accrue `fee` into `platform_fee.accrued`
11. If `queued_holdback > 0`, enqueue a `HoldbackEntry` into the per-source
    `Queue<HoldbackEntry>` (lazily creates the queue on first entry)
12. Emit `EmberShareSwappedEvent<T>` with all the fee/holdback/net amounts
    and `epoch_used_after`

### Holdback release (operator)

```move
gateway::atomic_release_users_holdback<T>(
    vault, config,
    share_vault_id: ID,
    unwinding_percentage: u64,    // 1e9 = pay full holdback; less = socialize loss
    max_entries: u64,             // gas guard
    clock, ctx,
)
```

Settles a FIFO batch. Each visited entry is closed unconditionally
(re-running on the same range is a no-op); the per-entry payout is
`entry.amount * unwinding_percentage`. Use `unwinding_percentage = 1e9`
for the normal path; lower values are reserved for black-swan scenarios
where the vault must socialize bad debt.

Operator must ensure `vault.balance >= sum(payouts)` before calling — the
function aborts with `EInsufficientBalance` if not. Auto-pull from
strategy is NOT done here; operator should pre-pull in the same PTB if
needed.

Emits `HoldbackReleasedEvent` with `entries_processed`, `total_released`,
and the post-batch queue depth.

### Redeeming collected EmberShares (operator)

```move
gateway::atomic_redeem_collected_ember_shares<T, R>(
    vault, config, source_vault: &mut Vault<T, R>,
    amount: u64, clock, ctx,
)
```

Submits `amount` of collected source-vault receipt tokens into the source
vault's standard redemption queue, with `receiver = atomic_vault_address`.
The source operator processes the request later; the underlying T flows
back to this vault's address as a TTO.

Note: `ctx.sender()` (the operator) becomes the on-chain `owner` of the
resulting `WithdrawalRequest` on the source vault. The atomic vault's
address is the `receiver`. Both must not be blacklisted on the source
vault — see [Security considerations](#security-considerations).

### Claiming the received collateral (operator)

```move
gateway::atomic_claim_received_collateral<T>(
    vault, config, token: Receiving<Coin<T>>, ctx,
)
```

Once the source vault has settled the redemption, the T arrives at the
atomic vault's address as a TTO. This call uses `transfer::public_receive`
to ingest the `Coin<T>` into `vault.balance`. Emits
`VaultDepositWithoutMintingSharesEvent<T>` with `sub_account = @0x0`
sentinel to indicate "from external source".

### EmberShare swap end-to-end timeline

```
t=0     User holds 100 of source-vault receipt token R
        (worth 100 USDC at source.rate)

t=1     User calls atomic_swap_ember_shares
        → atomic vault takes 100 R from user
        → atomic vault pays user 95 USDC (5% fee+holdback split, e.g.)
          - 1 USDC fee accrues to platform_fee
          - 4 USDC enters holdback queue under source_id
        → user receives 95 USDC immediately

t=2..N  Operator periodically calls atomic_release_users_holdback
        for source_id. Each call pays a FIFO batch of entries at
        the unwinding_percentage rate (typically 100%).

t=M     Operator calls atomic_redeem_collected_ember_shares
        with the 100 R held in the dynamic field
        → 100 R submitted to source vault's normal redemption queue
        → source vault eventually settles, sending USDC to atomic vault's
          address (TTO).

t=M+1   Operator calls atomic_claim_received_collateral
        → ingests the TTO'd USDC into vault.balance
        → atomic vault is back to net-flat on this swap
          (it earned the 1 USDC fee and held 4 USDC across the batch)
```

## Withdrawal fees

Optional. Created lazily as a `WithdrawalFee` dynamic field
(`b"withdrawal_fee"`) the first time any setter or `deposit` runs.

```move
public struct WithdrawalFee has store {
    permanent_fee_percentage: u64,        // 1e9 = 100%
    time_based_fee_percentage: u64,       // 1e9 = 100%
    time_based_fee_threshold: u64,        // ms
    fee_exempt: vector<address>,
    last_deposit_ts: Table<address, u64>,
}
```

### Setters

```move
gateway::atomic_set_permanent_fee_percentage<T>(vault, config, pct, ctx)        // admin
gateway::atomic_set_time_based_fee_percentage<T>(vault, config, pct, ctx)       // admin
gateway::atomic_set_time_based_fee_threshold<T>(vault, config, threshold, ctx)  // admin
gateway::atomic_set_fee_exemption_list<T>(vault, config, user, status, ctx)     // operator
```

Both percentage setters cap at `< 1e9` (i.e., < 100%). The threshold
setter accepts any `u64`; setting to 0 disables the time-based fee
entirely regardless of `time_based_fee_percentage`.

### Charging logic (in `process_request`)

Applied only on the non-skip branch (i.e., not blacklisted/cancelled).
Order:

1. If owner is `fee_exempt`, no fees applied — done.
2. **Permanent fee**: if `permanent_fee_percentage > 0`, deduct
   `withdraw_amount * permanent_fee_percentage` from withdraw_amount.
3. **Time-based fee**: if `time_based_fee_percentage > 0` AND
   `time_based_fee_threshold > 0`:
   - Look up `last_deposit_ts[owner]` (defaults to 0 if absent)
   - If `last_deposit == 0` OR
     `last_deposit + threshold > current_time` → deduct
     `withdraw_amount * time_based_fee_percentage` from the (already
     possibly reduced) withdraw_amount
4. Assert `withdraw_amount > 0` (aborts the entire `process_request` if
   fees take 100% — admin should never set this combination)
5. Transfer `withdraw_amount` of T to receiver

### Fee disposition

Withdrawal-fee amounts STAY in `vault.balance`. They are NOT routed into
`platform_fee.accrued`. This effectively rewards remaining shareholders by
improving the TVL/share ratio. Mirrors `vault.move`'s behavior exactly.

### `last_deposit_ts` tracking

`deposit` records `last_deposit_ts[depositor] = clock.timestamp_ms()`,
keyed by the **depositor** (`ctx.sender()`), not the receiver. If
depositor != receiver, the receiver inherits `last_deposit == 0` and
always pays the time-based fee until they make their own deposit. Same
quirk as `vault.move`.

### Application boundaries

Withdrawal fees apply ONLY in `process_request`. They do NOT apply to:

- `instant_withdraw` — uses its own `instant_withdraw_fee_percentage`
- `swap_ember_shares` — uses the per-source `EmberShareConfig.fee_percentage`

This matches EVM `AtomicLiquidity.sol`, which routes the standard request
flow through `vaultValidator.calculateWithdrawalFees` but applies a
separate `instantWithdrawFeePercentage` for instant withdraws and
per-share fees for ember-share swaps.

## Pause flags

Three independent toggles, each settable via:

```move
gateway::atomic_set_pause_status<T>(vault, config, operation: vector<u8>, paused: bool, ctx)
```

`operation` must be one of `b"deposits"`, `b"withdrawals"`, or
`b"privileged_operations"`. Any other value aborts with
`EInvalidPauseOperation`.

| Flag | Blocks |
|---|---|
| `paused_deposits` | `deposit` |
| `paused_withdrawals` | `redeem_shares`, `cancel_pending_withdrawal_request`, `process_withdrawal_requests`, `process_withdrawal_requests_up_to_timestamp`, `instant_withdraw*`, `swap_ember_shares*` |
| `paused_privileged_operations` | `update_vault_rate`, `collect_platform_fee`, `supply_to_sub_account`, `deposit_from_sub_account`, `deposit_from_sub_account_v2`, `supply_to_*_strategy`, `withdraw_from_*_strategy`, `release_users_holdback`, `redeem_collected_ember_shares`, `claim_received_collateral` |

Note that admin setters (e.g. `set_max_tvl`, `set_pause_status` itself)
are NOT gated by pause flags — admin can always reconfigure even when the
vault is fully paused. This matches EVM behavior.

## Public API reference

All public functions live on `ember_vaults::atomic_liquidity_vault`. Every
gateway entry function (`atomic_*`) wraps a single underlying public fn —
the table below shows the underlying name + caller role.

### Construction & sharing

| Fn | Caller | Notes |
|---|---|---|
| `create_atomic_liquidity_vault<T>` | Protocol admin (AdminCap) | Returns the vault by value |
| `share_atomic_vault<T>` | — | Wraps `transfer::share_object` |

### Admin setters

| Fn | Notes |
|---|---|
| `change_vault_admin<T>` | **Protocol admin** (AdminCap) — rotates `vault.admin` |
| `change_vault_operator<T>` | Vault admin |
| `update_vault_rate_manager<T>` | Vault admin |
| `update_vault_name<T>` | Vault admin |
| `update_vault_max_tvl<T>` | Vault admin (must be ≥ current TVL) |
| `update_vault_max_rate_change_per_update<T>` | Vault admin (must be `< 1e9`) |
| `change_vault_rate_update_interval<T>` | Vault admin (must be in protocol min/max) |
| `update_vault_fee_percentage<T>` | Vault admin (settles fees first) |
| `set_min_withdrawal_shares<T>` | Vault admin |
| `set_sub_account<T>` | Vault admin |
| `set_pause_status<T>` | Vault admin (3 ops) |
| `set_max_instant_withdraw_shares<T>` | Vault admin |
| `set_instant_withdraw_fee_percentage<T>` | Vault admin (capped at `1e9`) |
| `set_ember_share_whitelist<T>` | Vault admin |
| `set_swap_waiver<T>` | Vault admin |
| `set_permanent_fee_percentage<T>` | Vault admin (capped at `< 1e9`) |
| `set_time_based_fee_percentage<T>` | Vault admin (capped at `< 1e9`) |
| `set_time_based_fee_threshold<T>` | Vault admin |

### Strategy management

| Fn | Caller | Notes |
|---|---|---|
| `set_strategy_none<T, P, OldT>` | Vault admin | Clears prior strategy state |
| `set_strategy_suilend<T>` | Vault admin | Reserve index passed in |
| `supply_to_suilend_strategy<T, P>` | Operator | Returns assets supplied |
| `withdraw_from_suilend_strategy<T, P>` | Operator | Returns assets withdrawn (may be > requested) |

### Operator setters & flows

| Fn | Notes |
|---|---|
| `set_blacklisted_account<T>` | Toggles a single account on/off the blacklist |
| `set_fee_exemption_list<T>` | Toggles a single account on/off the withdrawal-fee exemption list |
| `supply_to_sub_account<T>` | Send vault collateral to a whitelisted sub-account without burning shares |
| `deposit_from_sub_account<T>` | Receive `Coin<T>` from a sub-account via TTO |
| `deposit_from_sub_account_v2<T>` | Same, but redeems `amount` from the vault's accumulator (address) balance — the only way to ingest funds sent via `send_funds`, which never create a coin object |
| `collect_platform_fee<T>` | Forward `fee.accrued` to the protocol fee recipient |
| `process_withdrawal_requests<T>` | Settle up to N requests |
| `process_withdrawal_requests_up_to_timestamp<T>` | Settle requests with `request.timestamp <= timestamp` |
| `release_users_holdback<T>` | Settle FIFO batch of holdback entries |
| `redeem_collected_ember_shares<T, R>` | Forward collected shares into source vault's queue |
| `claim_received_collateral<T>` | Receive TTO'd collateral into `vault.balance` |

### Rate manager

| Fn | Notes |
|---|---|
| `update_vault_rate<T>` | Subject to `max_rate_change_per_update`, `rate_update_interval`, and protocol min/max bounds |

### User-callable

| Fn | Notes |
|---|---|
| `deposit<T>` | Mints internal shares; obeys `min_shares` slippage |
| `redeem_shares<T>` | Queues a withdrawal request; returns `WithdrawalRequest` |
| `cancel_pending_withdrawal_request<T>` | Marks a queued request for skip-on-process |
| `instant_withdraw<T>` | Strategy = NONE variant |
| `instant_withdraw_with_suilend<T, P>` | Strategy = SUILEND variant |
| `swap_ember_shares<T, R>` | Strategy = NONE variant |
| `swap_ember_shares_with_suilend<T, R, P>` | Strategy = SUILEND variant |

### Views

All `get_*`, `is_*`, `balance_of`, `available_instant_withdraw_shares`,
`preview_swap_ember_shares`, `get_holdback_queue_length`,
`get_collected_ember_share_balance`, `get_ember_share_config` etc. are
read-only and require no special permissions.

## Events

Atomic-vault-specific events declared in
[events.move](sources/events.move) (13 new types):

| Event | Trigger |
|---|---|
| `AtomicVaultCreatedEvent<T>` | `create_atomic_liquidity_vault` |
| `AtomicVaultPauseStatusUpdatedEvent` | `set_pause_status` (per-flag) |
| `StrategyUpdatedEvent` | `set_strategy_*` |
| `StrategySuppliedEvent<T>` | `supply_to_*_strategy` |
| `StrategyWithdrawnEvent<T>` | `withdraw_from_*_strategy` (operator path), `ensure_liquidity_*` (auto-pull from instant_withdraw / swap_ember_shares) |
| `InstantWithdrawnEvent<T>` | `instant_withdraw*` |
| `InstantWithdrawLimitUpdatedEvent` | `set_max_instant_withdraw_shares` |
| `InstantWithdrawFeeUpdatedEvent` | `set_instant_withdraw_fee_percentage` |
| `EmberShareWhitelistUpdatedEvent` | `set_ember_share_whitelist` |
| `SwapWaiverUpdatedEvent` | `set_swap_waiver` |
| `EmberShareSwappedEvent<T>` | `swap_ember_shares*` |
| `HoldbackReleasedEvent` | `release_users_holdback` |
| `EmberSharesRedemptionInitiatedEvent` | `redeem_collected_ember_shares` |

Reused from `vault.move`'s event surface (no new types — same semantics
keyed by `vault_id`):

- `VaultRateUpdatedEvent`, `VaultAdminChangedEvent`,
  `VaultOperatorChangedEvent`, `VaultRateManagerUpdatedEvent`,
  `VaultMaxTVLUpdatedEvent`, `VaultRateUpdateIntervalChangedEvent`,
  `VaultMaxRateChangePerUpdateUpdatedEvent`,
  `VaultFeePercentageUpdatedEvent`, `VaultNameUpdatedEvent`,
  `VaultSubAccountUpdatedEvent`, `VaultBlacklistedAccountUpdatedEvent`,
  `VaultPlatformFeeChargedEvent`, `ProtocolFeeCollectedEvent<T>`,
  `MinWithdrawalSharesUpdatedEvent`, `VaultDepositEvent<T>`,
  `RequestRedeemedEvent<T>`, `RequestProcessedEvent<T>`,
  `ProcessRequestsSummaryEvent`, `RequestCancelledEvent`,
  `WithdrawalFeeChargedEvent`,
  `VaultDepositWithoutMintingSharesEvent<T>`,
  `VaultWithdrawalWithoutRedeemingSharesEvent<T>`,
  `VaultPermanentFeePercentageUpdatedEvent`,
  `VaultTimeBasedFeePercentageUpdatedEvent`,
  `VaultTimeBasedFeeThresholdUpdatedEvent`,
  `VaultFeeExemptListUpdatedEvent`

Indexers should disambiguate by event type AND `vault_id` — both vault
flavours emit the shared events under their respective vault IDs.

## Error codes

Atomic vault errors are reserved in the **8000-8999** range to keep them
out of `vault.move`'s 2000-series:

| Code | Name | Meaning |
|---|---|---|
| 8000 | `EInvalidPermission` | EInvalidPermission |
| 8001 | `EInvalidAccount` | EInvalidAccount |
| 8002 | `EInvalidRate` | EInvalidRate |
| 8003 | `EInvalidFeePercentage` | EInvalidFeePercentage |
| 8004 | `EZeroAmount` | EZeroAmount |
| 8005 | `EInvalidStatus` | EInvalidStatus |
| 8006 | `EOperationPaused` | EOperationPaused |
| 8007 | `EInsufficientBalance` | EInsufficientBalance |
| 8008 | `EBlacklistedAccount` | EBlacklistedAccount |
| 8009 | `EInsufficientShares` | EInsufficientShares |
| 8010 | `EInvalidInterval` | EInvalidInterval |
| 8011 | `EInvalidAmount` | EInvalidAmount |
| 8012 | `EInvalidRequest` | EInvalidRequest |
| 8013 | `EUserDoesNotHaveAccount` | EUserDoesNotHaveAccount |
| 8014 | `ESameValue` | ESameValue |
| 8015 | `EMaxTVLReached` | EMaxTVLReached |
| 8016 | `ESubAccount` | ESubAccount |
| 8017 | `ESlippageToleranceExceeded` | ESlippageToleranceExceeded |
| 8018 | `EInstantWithdrawCapExceeded` | EInstantWithdrawCapExceeded |
| 8019 | `EInstantWithdrawFeeTooHigh` | EInstantWithdrawFeeTooHigh |
| 8020 | `EEmberShareNotWhitelisted` | EEmberShareNotWhitelisted |
| 8021 | `EEmberShareCapExceeded` | EEmberShareCapExceeded |
| 8022 | `EEmberShareUtilizationCapExceeded` | Swap would push held value of this source share above `EmberShareConfig.max_utilization_percentage` of the atomic… |
| 8023 | `EZeroVaultTVL` | Swap attempted while the atomic vault has zero share-derived TVL, so no meaningful utilization exists |
| 8024 | `EInvalidFeeMultiplier` | Multiplier curve insert with multiplier < 1e9 — fees cannot be reduced below the base via the curve |
| 8025 | `EInvalidPercentage` | EInvalidPercentage |
| 8026 | `EStrategyMismatch` | EStrategyMismatch |
| 8027 | `EInvalidPauseOperation` | EInvalidPauseOperation |
| 8028 | `EDepositNotAllowed` | Depositor (`ctx.sender()`) is not on the operator-managed deposit allowlist hung off `DEPOSIT_USER_LIST_DYNAMIC_FIELD` |
| 8029 | `EEmberShareSwapAmountTooSmall` | Swap gross-collateral value is below the source share's configured `min_swap_gross` dust floor |
| 8030 | `EEmberShareHeldValueCapExceeded` | Post-swap held-value of the source share would exceed its configured `max_held_value_absolute` (a TVL-independent… |
| 8031 | `EInvalidReceiver` | A `receiver` parameter was passed as `@0x0` |
| 8032 | `ESourceVaultWithdrawalsPaused` | Source EmberVault has its withdrawals flag paused; swap refused to avoid AL accumulating shares it cannot… |
| 8033 | `ENoRewardDestination` | A strategy exit was attempted with an empty sub-account allowlist |

Strategy-module errors (in 7000-series, declared in `strategy.move`):

| Code | Name | Meaning |
|---|---|---|
| 7000 | `EInvalidStrategy` | Strategy tag is not one of the recognised values |
| 7001 | `ESuilendStateMissing` | Suilend state has not been initialised on this vault |
| 7002 | `EZeroAmount` | Operation called with zero amount |
| 7003 | `ESuilendStateAlreadyExists` | Suilend state already exists — refusing to overwrite reserve index |
| 7004 | `EStrategyShortDelivery` | Strategy withdrew less than the requested deficit |
| 7005 | `EStrategyInsufficientCTokens` | The Suilend obligation holds fewer cTokens than are needed to cover the requested underlying amount |
| 7006 | `ESuilendSuiRequiresSuiPath` | A GENERIC Suilend redemption path (`withdraw_from_suilend<P, T>` or `clear_suilend_state<P, T>`) was invoked with `T… |
| 7007 | `ESuilendMarketMismatch` | The `LendingMarket<P>` supplied does not match the market committed at activation |
| 7008 | `ESuilendObligationMissing` | No Suilend obligation has been opened on this vault |
| 7009 | `ESuilendObligationAlreadyExists` | An obligation already exists — refusing to clobber the only capability that can reach the deposit inside it |
| 7010 | `ESuilendResidualDeposit` | A Suilend clear finished with cTokens still deposited in the obligation |
| 7011 | `ESuilendCoinTypeMismatch` | `T` does not match the collateral type committed at activation |
| 7012 | `ESuilendReserveIndexMismatch` | The committed reserve index is not the index `market` uses for `T` |
| 7013 | `ESuilendSecondaryIsCommittedType` | `withdraw_secondary_collateral` was called with the vault's committed collateral type |

Common-module errors (in 6000-series, declared in `common.move`):

| Code | Name | Meaning |
|---|---|---|
| 6000 | `EZeroAddress` | `update_accounts` called with `@0` |
| 6001 | `EAlreadyExists` | `update_accounts` add of already-listed address |
| 6002 | `ENotFound` | `update_accounts` remove of not-listed address |
| 6003 | `ERoleConflict` | `assert_role_candidate_valid` collision |

## Operations runbook

### Initial deployment

1. Publish the package — package version constant is `VERSION = 6` in
   `admin.move`.
2. Submit `gateway::increase_supported_package_version` from the
   `AdminCap` holder to advance `ProtocolConfig.version` from 5 → 6.
3. **Until step 2 runs, every public fn on `vault.move` AND
   `atomic_liquidity_vault.move` aborts with `EUnsupportedPackage`** —
   both modules call `admin::verify_supported_package` at the top of
   every public path. This is the standard cutover pattern from prior
   upgrades.

### Creating an atomic vault

```bash
# Protocol admin signs:
sui client call \
  --package $PKG \
  --module gateway \
  --function create_atomic_vault \
  --type-args $T \
  --args $CONFIG_ID $ADMIN_CAP_ID \
         "Atomic USDC Vault" \
         $ADMIN $OPERATOR $RATE_MANAGER \
         50000000 1000000 1 86400000 1000000000000 \
         "[]"
```

### Activating a strategy (pre-deposit)

**Suilend** — first look up the reserve index:

```typescript
// off-chain
const reserveIdx = await suilendClient.reserveArrayIndex({ market: MAIN_POOL, asset: USDC });
```

```bash
sui client call \
  --package $PKG --module gateway \
  --function atomic_set_strategy_suilend \
  --type-args USDC \
  --args $VAULT_ID $CONFIG_ID $reserveIdx
```

### Switching strategies

Always 3-step:

1. Operator: `atomic_withdraw_from_<X>_strategy` until balance == 0
2. Admin: `atomic_set_strategy_none<T, P, OldT>(...)` (where `P, OldT`
   match the typed cTokens for previous=Suilend; placeholders for
   previous=NONE)
3. Admin: `atomic_set_strategy_<Y>(...)`

### Updating the Suilend stub address on protocol upgrades

`external_stubs/suilend/Move.toml` and
`external_stubs/alpha_lending/Move.toml` each have a `published-at = ...`
field pointing at the live protocol's package address. When Suilend or
Suilend ships an upgrade to mainnet, update only the `published-at`
field — the named addresses (`suilend = 0xf95b06...`,
`alpha_lending = 0xd631cd66...`) stay stable across upgrades because
those are the protocols' original publish IDs (i.e. type-identity anchors).

After updating, run `sui move build` in the ember-vaults root and ship a
new package upgrade with the updated stubs.

## Security considerations

### Strategy switching

- Suilend cToken cleanup IS checked: `clear_suilend_state` aborts if
  `Balance<CToken<P, T>>` is non-zero.

### Cross-vault redemption

`redeem_collected_ember_shares` calls into `vault::redeem_shares` on
the source vault with `receiver = atomic_vault_address` and
`owner = ctx.sender()` (the operator). The source vault's
`process_request` will skip and return shares to the OWNER if either
owner or receiver is blacklisted on the source vault. So:

- **Operator must not be blacklisted on any source vault** the atomic
  vault has whitelisted, or operator-submitted redemptions will silently
  return shares back to the operator (not the atomic vault). This is a
  fund-loss path.
- **Atomic vault address must not be blacklisted on any source vault**,
  or settled redemptions will route back to the operator instead of the
  atomic vault.

Operationally: monitor source vault blacklist events via
`VaultBlacklistedAccountUpdatedEvent` and pause cross-vault swap (via
`paused_withdrawals`) if the operator or atomic vault is added.

### Holdback queue starvation

If the operator never calls `release_users_holdback`, queued holdbacks
sit indefinitely. Users have no on-chain way to claim. Mitigation: a
keeper bot that runs `release_users_holdback` on a schedule. The
`HoldbackEntry.created_at` field is exposed via
`get_holdback_queue_length` + an off-chain queue inspection helper if
you need to alert on stale entries.

### Cumulative instant-withdraw cap

The cap is **lifetime, not rate-based**. Once
`cumulative_instant_withdraw_shares` hits `max_instant_withdraw_shares`,
further instant withdrawals abort until admin raises the cap. There is
no automatic reset.

### Fee accumulation paths (different from EVM)

| Fee source | Disposition |
|---|---|
| Time-based platform fee (annualised on TVL) | `platform_fee.accrued`, collected via `collect_platform_fee` |
| `instant_withdraw_fee_percentage` | `platform_fee.accrued` |
| `swap_ember_shares` per-share fee | `platform_fee.accrued` |
| `permanent_fee_percentage` (request-based withdrawal) | **Stays in `vault.balance`** — improves TVL/share |
| `time_based_fee_percentage` (request-based withdrawal) | **Stays in `vault.balance`** |
| Holdback unwinding-percentage residual | **Stays in `vault.balance`** when `unwinding_percentage < 1e9` |

Three different disposition paths. The first three flow to the protocol
fee recipient via `collect_platform_fee`. The last three stay in the
vault and benefit remaining shareholders. This is intentional and matches
`vault.move`'s established convention.

### `set_strategy_none` with three type parameters

The `<T, P, OldT>` signature is awkward — frontends must pass
placeholder phantom types when the previous strategy is NONE.
Suggested convention: define a local empty struct in your script
(`public struct NoSuilendMarket {}`) and use it as the placeholder.

### Receipt-token blacklist on cross-vault swap

The atomic vault accepts `Coin<R>` from any source. If the source vault
operator decides to blacklist users post-swap, the atomic vault still
holds the R coin — it can still redeem these via
`redeem_collected_ember_shares` because the redemption uses
`atomic_vault_address` as the on-chain owner-of-receiver tuple, not the
original swapper's address. So historical swaps remain redeemable even
if the original user is later blacklisted. Intentional.

## Differences from EVM `AtomicLiquidity.sol`

| Aspect | EVM | Sui Move |
|---|---|---|
| Share storage | `mapping(address => uint256)` | `Table<address, u64>` (semantically identical) |
| Shares are non-transferable | Yes (no ERC-20) | Yes (just numbers in a Table) |
| Strategy abstraction | `IERC4626` interface — runtime polymorphic | `u8` tag + per-strategy adapter functions, statically dispatched. Two variants per liquidity-pulling user fn (`*_with_suilend`, no-strategy) |
| Auto-pull from strategy | `_ensureLiquidity` inside `instantWithdraw` / `releaseUsersHoldback` / `swapEmberShares` | Same semantic, but implemented in the variant wrapper before calling the core helper. `release_users_holdback` does NOT auto-pull (operator pre-pulls) |
| Withdrawal fees | Via `IEmberVaultValidator.calculateWithdrawalFees` (external contract) | Via `WithdrawalFee` dynamic field, same shape as `vault.move` |
| Cross-vault swap | `swapEmberShares` calls source `EmberVault.redeemShares` and stores share-token via ERC-20 `safeTransferFrom` | `swap_ember_shares*` consumes `Coin<R>` directly; redeems later via `redeem_collected_ember_shares` |
| Settlement of redeemed source shares | ERC-20 transfer arrives in `address(this)` automatically | Source vault's `process_request` does `transfer::public_transfer` to `atomic_vault_address` (TTO); operator must call `claim_received_collateral` to ingest into `vault.balance` |
| Pause flags | 3 separate booleans | 3 separate booleans (`paused_deposits`, `paused_withdrawals`, `paused_privileged_operations`) |
| EmberShare epoch length | 24 hours (`EMBER_SHARE_EPOCH_DURATION`) | 24 hours (`EMBER_SHARE_EPOCH_DURATION_MS`) |
| Fee precision | 1e18 fixed-point | 1e9 fixed-point (`PERCENT_MAX = 1_000_000_000`) |
| Rate manager assignment | Constructor arg, mutable | Constructor arg, mutable (DIFFERENT from `vault.move` which uses dynamic field) |
| Withdrawal fee disposition | Accrues into `platformFee.accrued` (DIFFERENT from Sui!) | Stays in `vault.balance` (matches `vault.move`'s existing behavior) |
| `setStrategy` migration | Not auto-migrate; admin must withdraw first | Same — admin must withdraw first; Suilend cleanup is enforced |
| `withdraw` rate-limit exemption | `Option<RateLimiterExemption<P, T>>` for Suilend redemptions | We always pass `option::none()` — atomic vault never has an exemption |
| SUI as collateral | Supported | Supported on Suilend. Withdraw / clear / instant-withdraw / swap go through monomorphic `*_sui` entry variants that thread `&mut SuiSystemState`, because Suilend serves SUI redemptions through its staker. The generic entries abort for `T = SUI` (`ESuilendSuiRequiresSuiPath`) to force callers onto the `*_sui` paths. |

### Notable behavioural matches

- Withdrawal fees applied only on request-based processing, not on
  instant withdraw or ember-share swap
- Withdrawal fee 100% sum aborts the entire `process_request` call
- `swapEmberShares` uses a rolling 24h epoch capacity check
- Holdback queue is FIFO with operator-controlled unwinding percentage
- `processWithdrawalRequests` does not auto-pull from strategy
- `instantWithdrawFeePercentage` accrues to `platform_fee.accrued`
  (separate from withdrawal-fee disposition path)
- Cumulative instant-withdraw cap is lifetime, not rate-limited

### Notable behavioural divergences

- **Rate manager**: stored on-struct, set at create-time on atomic vault;
  set via dynamic field post-create on `vault.move`. The atomic vault
  matches EVM more closely.
- **Source vault cross-vault redemption settlement**: requires explicit
  `claim_received_collateral` call (no automatic ERC-20 inbound balance
  on Sui).
