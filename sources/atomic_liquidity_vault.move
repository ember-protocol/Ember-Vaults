/*
  Copyright (c) 2026 Ember Protocol Inc.
  Proprietary Smart Contract License – All Rights Reserved.

  This source code is provided for transparency and verification only.
  Use, modification, reproduction, or redeployment of this code
  requires prior written permission from the Ember Protocol Inc.
*/

/// Atomic-liquidity vault — request-based redemption (mirrors `vault.move`)
/// plus three additional capabilities:
///
///   1. **Internal share accounting**: shares are non-transferable and tracked
///      in a `Table<address, u64>` instead of being a `Coin<R>` receipt token.
///      Mirrors the EVM AtomicLiquidity contract's `mapping(address=>uint256)`.
///
///   2. **External lending strategy**: idle vault assets can be supplied into
///      Suilend (supply-only). Strategy is selected via a
///      `u8` tag with state held in dynamic fields (see `strategy.move`).
///
///   3. **Cross-vault EmberShare swap**: admin whitelists other Ember vaults'
///      receipt tokens; users instantly exchange those shares for this vault's
///      collateral, paying a fee and accepting a deferred holdback. Held shares
///      are later redeemed via the source vault's normal queue.
module ember_vaults::atomic_liquidity_vault {

    // === Imports ===

    use std::string::String;
    use std::type_name;

    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::coin::{Self, Coin};
    use sui::dynamic_field;
    use sui::sui::SUI;
    use sui::table::{Self, Table};
    use sui::vec_set::{Self, VecSet};
    use sui::transfer::Receiving;
    use sui_system::sui_system::SuiSystemState;

    use ember_vaults::admin::{Self, AdminCap, ProtocolConfig};
    use ember_vaults::common;
    use ember_vaults::events;
    use ember_vaults::math;
    use ember_vaults::queue::{Self, Queue};
    use ember_vaults::strategy;
    use ember_vaults::vault::{Self, Vault};

    use suilend::lending_market::LendingMarket;

    // === Errors ===
    // Reserved range: 8000-8999.

    const EInvalidPermission: u64 = 8000;
    const EInvalidAccount: u64 = 8001;
    const EInvalidRate: u64 = 8002;
    const EInvalidFeePercentage: u64 = 8003;
    const EZeroAmount: u64 = 8004;
    const EInvalidStatus: u64 = 8005;
    const EOperationPaused: u64 = 8006;
    const EInsufficientBalance: u64 = 8007;
    const EBlacklistedAccount: u64 = 8008;
    const EInsufficientShares: u64 = 8009;
    const EInvalidInterval: u64 = 8010;
    const EInvalidAmount: u64 = 8011;
    const EInvalidRequest: u64 = 8012;
    const EUserDoesNotHaveAccount: u64 = 8013;
    const ESameValue: u64 = 8014;
    const EMaxTVLReached: u64 = 8015;
    const ESubAccount: u64 = 8016;
    const ESlippageToleranceExceeded: u64 = 8017;
    const EInstantWithdrawCapExceeded: u64 = 8018;
    const EInstantWithdrawFeeTooHigh: u64 = 8019;
    const EEmberShareNotWhitelisted: u64 = 8020;
    const EEmberShareCapExceeded: u64 = 8021;
    /// Swap would push held value of this source share above
    /// `EmberShareConfig.max_utilization_percentage` of the atomic vault's TVL.
    const EEmberShareUtilizationCapExceeded: u64 = 8022;
    /// Swap attempted while the atomic vault has zero share-derived TVL, so no
    /// meaningful utilization exists. Distinct from
    /// `EEmberShareUtilizationCapExceeded` because the condition has nothing to
    /// do with the source's config: a vault seeded only through
    /// `deposit_from_sub_account` (which adds balance without minting shares)
    /// has `total_shares == 0`, and reusing the cap code would point the
    /// operator at `set_ember_share_max_utilization` instead of at the vault
    /// having no shares.
    const EZeroVaultTVL: u64 = 8023;
    /// Multiplier curve insert with multiplier < 1e9 — fees cannot be
    /// reduced below the base via the curve.
    const EInvalidFeeMultiplier: u64 = 8024;
    const EInvalidPercentage: u64 = 8025;
    const EStrategyMismatch: u64 = 8026;
    const EInvalidPauseOperation: u64 = 8027;
    /// Depositor (`ctx.sender()`) is not on the operator-managed deposit
    /// allowlist hung off `DEPOSIT_USER_LIST_DYNAMIC_FIELD`.
    const EDepositNotAllowed: u64 = 8028;
    /// Swap gross-collateral value is below the source share's configured
    /// `min_swap_gross` dust floor. Prevents sub-unit swaps that would round
    /// the fee to zero (bypassing the fee disincentive) while still enqueuing
    /// a near-zero holdback entry, which bloats `release_users_holdback` and
    /// — at any `unwinding_percentage < 100%` — would produce a 0 payout that
    /// used to revert the whole release batch.
    const EEmberShareSwapAmountTooSmall: u64 = 8029;
    /// Post-swap held-value of the source share would exceed its configured
    /// `max_held_value_absolute` (a TVL-independent absolute ceiling that
    /// can't be gamed by transiently inflating the atomic vault's TVL).
    const EEmberShareHeldValueCapExceeded: u64 = 8030;
    /// A `receiver` parameter was passed as `@0x0`. Rejecting up-front avoids
    /// FIFO-head stalls (a queued request that would abort on
    /// `transfer::public_transfer(..., @0x0)` at processing time).
    const EInvalidReceiver: u64 = 8031;
    /// Source EmberVault has its withdrawals flag paused; swap refused to
    /// avoid AL accumulating shares it cannot subsequently redeem. Read-once
    /// at swap time — the vault admin can pause / unpause the source
    /// independently of AL's operator flow.
    const ESourceVaultWithdrawalsPaused: u64 = 8032;
    /// A strategy exit was attempted with an empty sub-account allowlist.
    ///
    /// Strategy rewards can only be forwarded to an allowlisted sub-account, so
    /// an empty list makes every reward claim abort for every address — the
    /// sweep is frozen. The exits then discard the `ObligationOwnerCap` /
    /// `PositionCap`, after which anything accrued is permanently unclaimable.
    /// This is the same hazard the exits are pause-gated against (L-1); routing
    /// rewards to a sub-account added a second way to freeze the sweep, so it
    /// needs the same guard. Admin allowlists a destination, sweeps, then exits.
    const ENoRewardDestination: u64 = 8033;

    // === Constants ===

    /// 1e9 — 100% in this protocol's fixed-point scheme.
    const PERCENT_MAX: u64 = 1_000_000_000;

    /// Protocol ceiling on withdrawal fees (5e8 = 50%). Caps `permanent_fee`
    /// and `time_based_fee` both individually and combined so a vault admin
    /// cannot set a near-total (e.g. 99%) confiscatory withdrawal fee — the
    /// prior joint `< PERCENT_MAX` guard only prevented underflow, not
    /// confiscation. The `vault::` withdrawal fees carry the same ceiling.
    const MAX_WITHDRAWAL_FEE_PERCENTAGE: u64 = 500_000_000;

    /// Absolute upper bound (in collateral base units) on a holdback entry that
    /// `release_users_holdback` will pay in FULL when its haircut payout floors
    /// to zero. This restricts the dust auto-lift to genuine sub-precision
    /// fragments (e.g. the `amount == 1` entries the swap path can seed from tiny
    /// share fractions) so it can never invert the operator's chosen
    /// `unwinding_percentage`: an entry above this bound whose payout merely
    /// rounds down is paid zero, not in full. Economically negligible (100 base
    /// units ≤ 1e-4 USDC / 1e-7 SUI). Tunable.
    const HOLDBACK_DUST_UNITS: u64 = 100;

    /// Absolute ceiling on a single EmberShare fee-multiplier tier (100x, in
    /// 1e9 fixed-point). Tiers are `>= PERCENT_MAX` (1x); this caps the top so a
    /// wild multiplier can't overflow the `base * multiplier` fee math or be
    /// set against a zero base and later brick swaps once a base is configured.
    const MAX_FEE_MULTIPLIER: u64 = 100_000_000_000;

    /// Max number of tiers in an EmberShare fee-multiplier curve. Bounds the
    /// O(n) `lookup_fee_multiplier` walk run on every swap.
    const MAX_FEE_MULTIPLIER_TIERS: u64 = 20;

    /// Length of the rolling capacity window for an EmberShare swap, in ms.
    const EMBER_SHARE_EPOCH_DURATION_MS: u64 = 24 * 60 * 60 * 1000;

    /// Strings used as the `operation` field in pause-status events.
    const OP_DEPOSITS: vector<u8> = b"deposits";
    const OP_WITHDRAWALS: vector<u8> = b"withdrawals";
    const OP_PRIVILEGED: vector<u8> = b"privileged_operations";

    /// Dynamic-field key for the optional `WithdrawalFee` struct hung off
    /// `vault.id`. Mirrors the same pattern in `vault.move` — created lazily
    /// the first time any of `set_permanent_fee_percentage`,
    /// `set_time_based_fee_percentage`, `set_time_based_fee_threshold`,
    /// `set_fee_exemption_list`, or `deposit` runs.
    const WITHDRAWAL_FEE_DYNAMIC_FIELD: vector<u8> = b"withdrawal_fee";

    /// Dynamic-field key for the optional `vector<address>` deposit allowlist
    /// hung off `vault.id`. Mirrors `vault.move`'s `DEPOSIT_USER_LIST_DYNAMIC_FIELD`:
    /// created lazily by `set_deposit_user_list` on first add and removed when
    /// the list becomes empty so vaults that don't gate deposits pay no
    /// extra storage. When the field is absent, deposits are open; when
    /// present, only listed addresses can deposit (withdrawals are never
    /// gated — a user who received shares before being de-listed can still
    /// redeem them).
    const DEPOSIT_USER_LIST_DYNAMIC_FIELD: vector<u8> = b"deposit_user_list";

    // === Structs ===

    /// A queued withdrawal request. Same shape as `vault::WithdrawalRequest`
    /// — duplicated here because the upstream type's constructor is private to
    /// `ember_vaults::vault`. Field order/layout intentionally identical for
    /// indexer convenience.
    public struct WithdrawalRequest has copy, drop, store {
        owner: address,
        receiver: address,
        shares: u64,
        estimated_withdraw_amount: u64,
        timestamp: u64,
        sequence_number: u128,
    }

    /// Per-account withdrawal-queue accounting.
    public struct Account has copy, drop, store {
        total_pending_withdrawal_shares: u64,
        pending_withdrawal_requests: vector<WithdrawalRequest>,
        cancel_withdraw_request: vector<u128>,
    }

    /// Accrued platform-fee state. Same shape as `vault::PlatformFee`.
    public struct PlatformFee has copy, drop, store {
        accrued: u64,
        last_charged_at: u64,
    }

    /// Vault-rate state. Same shape as `vault::Rate`.
    public struct Rate has copy, drop, store {
        value: u64,
        max_rate_change_per_update: u64,
        rate_update_interval: u64,
        last_updated_at: u64,
    }

    /// Per-EmberShare configuration for the cross-vault instant-swap. Keyed
    /// inside the vault by the source EmberVault's `ID`.
    public struct EmberShareConfig has copy, drop, store {
        whitelisted: bool,
        /// Base fee on gross collateral value. 1e9 = 100%. Effective fee at
        /// swap time is `base * curve_multiplier_at(utilization)`.
        fee_percentage: u64,
        /// 1e9 = 100% of the source vault's TVL allowed to be swapped per
        /// rolling 24-hour epoch.
        max_capacity_percentage: u64,
        /// 1e9 = 100% of gross retained in the holdback queue until released.
        holdback_percentage: u64,
        /// Start-of-epoch wall-clock time (ms). 0 == no swaps yet.
        epoch_started_at: u64,
        /// Volume swapped in the current epoch, in collateral units.
        epoch_used_amount: u64,
        /// Concentration cap: maximum fraction of the atomic vault's TVL
        /// that can be held in this source share. 1e9 = 100%. Checked
        /// against POST-swap utilization, so a swap that would push the
        /// held value above this cap aborts with `EEmberShareUtilizationCapExceeded`.
        ///
        /// Utilization = `value_of_held_receipt_token / atomic_vault_tvl`,
        /// where `value_of_held_receipt_token` is the collateral-denominated
        /// worth of the receipt tokens this vault currently holds.
        max_utilization_percentage: u64,
        /// Step-function curve of (utilization_threshold, multiplier) pairs,
        /// sorted ASCENDING by `threshold`. Lookup walks the vector and
        /// returns the multiplier of the highest threshold `<= utilization`.
        /// Multipliers are in 1e9 fixed-point where `1e9 = 1x`, `1.5e9 = 1.5x`,
        /// etc. If empty (or no tier matches), the multiplier is `1e9` (no
        /// scaling). Constrained on insert: `multiplier >= 1e9` (fees can
        /// only go UP with utilization) and `threshold <= 1e9`.
        fee_multiplier_curve: vector<FeeMultiplierTier>,
        /// Minimum gross collateral value a single swap must produce (in
        /// collateral units), enforced against
        /// `vault::calculate_amount_from_shares(source_vault, share_amount)`.
        /// Dust floor: blocks sub-unit swaps that round the fee to zero
        /// (bypassing the fee disincentive) while still queueing a near-zero
        /// `HoldbackEntry`, which bloats `release_users_holdback` gas and at
        /// any `unwinding_percentage < 100%` produces a 0 payout that the
        /// release loop used to reject wholesale. `0` disables the floor.
        min_swap_gross: u64,
        /// Absolute ceiling (in collateral units) on the post-swap held-value
        /// of this source share (`current_held_share_value_in_collateral`
        /// after adding the swap's gross). Unlike `max_utilization_percentage`,
        /// this is NOT a fraction of AL's TVL, so it cannot be gamed by
        /// transiently inflating `atomic_vault_tvl` (deposit → swap →
        /// withdraw) to slip a larger position past the percentage cap. `0`
        /// disables the absolute cap.
        max_held_value_absolute: u64,
    }

    /// One row in `EmberShareConfig.fee_multiplier_curve`.
    public struct FeeMultiplierTier has copy, drop, store {
        /// Utilization threshold at which this tier activates. 1e9 = 100%.
        threshold: u64,
        /// Fee multiplier in 1e9 fixed-point. 1e9 = 1x; 1.5e9 = 1.5x; etc.
        multiplier: u64,
    }

    /// One entry in a per-EmberShare holdback queue. Created by
    /// `swap_ember_shares` when `holdback_percentage > 0` and the user is not
    /// holdback-waived; consumed by `release_users_holdback`.
    public struct HoldbackEntry has copy, drop, store {
        share_vault_id: ID,
        receiver: address,
        /// Gross holdback amount queued (collateral units).
        amount: u64,
        created_at: u64,
        sequence_number: u128,
    }

    /// Optional withdrawal-fee config hung off the vault as a dynamic field
    /// under `WITHDRAWAL_FEE_DYNAMIC_FIELD`. Same shape as `vault::WithdrawalFee`.
    /// Created lazily on first deposit or first admin setter call so vaults
    /// with no withdrawal fees pay no extra storage cost.
    ///
    /// Fees are charged ONLY during request-based withdrawal processing
    /// (`process_request`). They do NOT apply to `instant_withdraw` (which
    /// has its own separate `instant_withdraw_fee_percentage`) nor to
    /// `swap_ember_shares` (which has its own per-share fee).
    public struct WithdrawalFee has store {
        /// Permanent fee charged on every (non-exempt) processed withdrawal.
        /// 1e9 = 100%. Capped at < 1e9 by the setter.
        permanent_fee_percentage: u64,

        /// Time-based fee charged when a withdrawal is processed within
        /// `time_based_fee_threshold` ms of the user's last deposit.
        /// 1e9 = 100%. Capped at < 1e9 by the setter.
        time_based_fee_percentage: u64,

        /// Threshold (ms) measured from the user's last deposit timestamp:
        /// if `last_deposit + threshold > current_time`, the time-based fee
        /// fires. Set to 0 to disable the time-based fee entirely (regardless
        /// of `time_based_fee_percentage`).
        time_based_fee_threshold: u64,

        /// Per-account waivers — addresses on this list pay zero withdrawal
        /// fees of either kind. Maintained by `set_fee_exemption_list`
        /// (operator-only).
        fee_exempt: vector<address>,

        /// Per-account last-deposit timestamp (ms), updated by `deposit`.
        /// The time-based fee uses this to determine whether the user is
        /// still inside their threshold window.
        last_deposit_ts: Table<address, u64>,
    }

    /// The atomic liquidity vault.
    ///
    /// Single generic `T` (the underlying collateral asset). `R` (receipt
    /// token type) is intentionally absent — atomic vaults do not mint a
    /// transferable receipt; user shares live in `shares: Table<address, u64>`.
    public struct AtomicLiquidityVault<phantom T> has key {
        id: UID,
        name: String,

        // === Roles ===
        admin: address,
        operator: address,
        rate_manager: address,
        sub_accounts: vector<address>,
        blacklisted: vector<address>,

        // === Per-operation pause flags (independent toggles) ===
        paused_deposits: bool,
        paused_withdrawals: bool,
        paused_privileged_operations: bool,

        // === Rate / fee ===
        rate: Rate,
        fee_percentage: u64,
        fee: PlatformFee,

        // === Internal share accounting ===
        /// Per-user share balances. Non-transferable.
        shares: Table<address, u64>,
        /// Sum of all `shares[u]` plus `pending_burn_shares`. Mirrors EVM
        /// `totalShares` semantics.
        total_shares: u64,
        /// Shares parked here while a withdrawal request is pending; on
        /// process they are burnt (out of `total_shares`); on cancel/skip
        /// they are returned to the owner via `shares[owner]`.
        pending_burn_shares: u64,

        // === Limits ===
        min_withdrawal_shares: u64,
        /// Cap on vault TVL, enforced against `get_vault_tvl_u128`, which is
        /// `floor(total_shares * 1e9 / rate)`.
        ///
        /// ACCEPTED TOLERANCE (I-08): because the comparison uses the floored
        /// value, the exact rational share claim may sit anywhere in
        /// `[max_tvl, max_tvl + 1)` and still pass — an overshoot of strictly
        /// less than one collateral base unit. This is deliberate. Enforcing
        /// the cap with ceiling division would reject deposits one base unit
        /// earlier for no observable benefit, and would put two different
        /// rounding conventions on the same quantity — the shape that produced
        /// the L-04 double-flooring defect. Every on-chain transfer is
        /// integer-denominated, so no realised amount ever exceeds `max_tvl`.
        max_tvl: u64,

        // === Underlying balance ===
        balance: Balance<T>,

        // === Withdrawal queue ===
        pending_withdrawals: Queue<WithdrawalRequest>,
        accounts: Table<address, Account>,

        // === Strategy ===
        /// 0 = none, 1 = suilend (see `strategy.move`).
        strategy_kind: u8,

        // === Instant withdraw ===
        /// Cumulative cap (in shares) over the vault's lifetime. Default 0 —
        /// admin must raise to enable instant withdrawals.
        max_instant_withdraw_shares: u64,
        /// Running total of shares ever burned via instant_withdraw.
        cumulative_instant_withdraw_shares: u64,
        /// Instant-withdraw fee in 1e9 fixed-point. Capped at PERCENT_MAX.
        instant_withdraw_fee_percentage: u64,

        // === EmberShare cross-vault swap ===
        /// Per-source-vault swap config. Keyed by source vault `ID`.
        ember_share_configs: Table<ID, EmberShareConfig>,
        /// Holdback FIFO queues per source share. One queue per source vault.
        holdback_queues: Table<ID, Queue<HoldbackEntry>>,
        /// Owners exempt from the EmberShare swap fee.
        fee_waived_addresses: vector<address>,
        /// Owners exempt from holdback queueing — paid full gross-net immediately.
        holdback_waived_addresses: vector<address>,

        /// Set of source vaults this atomic vault has redeemed at (via
        /// `redeem_collected_ember_shares`). Used as a per-source negative cache
        /// by `current_held_share_value_in_collateral`: only these sources can
        /// hold pending withdrawal requests attributed to this atomic vault, so
        /// the cross-module `vault::get_account_total_pending_withdrawal_shares`
        /// call is made only for a member source — never for one the vault has
        /// never redeemed at (A-12).
        ///
        /// The read short-circuits on `vec_set::is_empty` first, so a
        /// redemption-free vault (the common case) pays only that cheap check
        /// and never the per-source `contains` scan — keeping the swap-path
        /// utilization check within the scenario tests' per-test gas budget
        /// (an unconditional `contains`, or a per-source `dynamic_field::exists_`,
        /// blows it). Additive and never removed; a source whose pending has
        /// since settled to 0 simply yields a correct 0 from the read.
        redemption_active_sources: VecSet<ID>,

        sequence_number: u128,
    }

    // === Constructor ===

    /// Creates a new atomic liquidity vault. Returns the vault by value so the
    /// caller (typically `gateway::create_atomic_liquidity_vault`) can apply
    /// `share_atomic_vault` after final setup.
    ///
    /// `instant_withdraw_fee_percentage` and `max_instant_withdraw_shares`
    /// default to 0 — admin enables them later via the dedicated setters.
    /// Hot-potato witness issued by `create_atomic_liquidity_vault` and
    /// consumed by `share_atomic_vault`. No abilities — it cannot be stored,
    /// copied or dropped, so a creation transaction cannot succeed without
    /// sharing the vault it produced (I-13).
    public struct ShareVaultTicket {}

    public fun create_atomic_liquidity_vault<T>(
        config: &ProtocolConfig,
        _: &AdminCap,
        name: String,
        admin: address,
        operator: address,
        rate_manager: address,
        max_rate_change_per_update: u64,
        fee_percentage: u64,
        min_withdrawal_shares: u64,
        rate_update_interval: u64,
        max_tvl: u64,
        sub_accounts: vector<address>,
        ctx: &mut TxContext,
    ): (AtomicLiquidityVault<T>, ShareVaultTicket) {
        admin::verify_supported_package(config);

        assert!(
            rate_update_interval >= admin::get_min_rate_interval(config)
                && rate_update_interval <= admin::get_max_rate_interval(config),
            EInvalidInterval,
        );
        assert!(min_withdrawal_shares > 0, EInvalidAmount);
        assert!(max_tvl > 0, EInvalidAmount);
        assert!(max_rate_change_per_update > 0 && max_rate_change_per_update < PERCENT_MAX, EInvalidAmount);
        assert!(
            admin != @0
                && operator != @0
                && rate_manager != @0
                && admin != operator
                && admin != rate_manager
                && operator != rate_manager
                && !vector::contains(&sub_accounts, &admin)
                && !vector::contains(&sub_accounts, &operator)
                && !vector::contains(&sub_accounts, &rate_manager),
            EInvalidAccount,
        );
        assert!(
            fee_percentage <= admin::get_max_allowed_fee_percentage(config),
            EInvalidFeePercentage,
        );
        // I-04: the setters reject `@0` and duplicate sub-accounts, but
        // creation only checked role collisions. An allowlisted `@0` can
        // receive and orphan vault assets, and a duplicate may survive one
        // removal, so enforce the setter invariants at construction too.
        let mut i = 0;
        let n = vector::length(&sub_accounts);
        while (i < n) {
            let a = *vector::borrow(&sub_accounts, i);
            assert!(a != @0, EInvalidAccount);
            let mut j = i + 1;
            while (j < n) {
                assert!(a != *vector::borrow(&sub_accounts, j), EInvalidAccount);
                j = j + 1;
            };
            i = i + 1;
        };

        let id = object::new(ctx);
        let vault_id = object::uid_to_inner(&id);

        let rate = Rate {
            value: admin::get_default_rate(config),
            max_rate_change_per_update,
            rate_update_interval,
            last_updated_at: 0,
        };

        let vault = AtomicLiquidityVault<T> {
            id,
            name,
            admin,
            operator,
            rate_manager,
            sub_accounts,
            blacklisted: vector::empty(),
            paused_deposits: false,
            paused_withdrawals: false,
            paused_privileged_operations: false,
            rate,
            fee_percentage,
            fee: PlatformFee { accrued: 0, last_charged_at: 0 },
            shares: table::new<address, u64>(ctx),
            total_shares: 0,
            pending_burn_shares: 0,
            min_withdrawal_shares,
            max_tvl,
            balance: balance::zero<T>(),
            pending_withdrawals: queue::new<WithdrawalRequest>(ctx),
            accounts: table::new<address, Account>(ctx),
            strategy_kind: strategy::strategy_none(),
            max_instant_withdraw_shares: 0,
            cumulative_instant_withdraw_shares: 0,
            instant_withdraw_fee_percentage: 0,
            ember_share_configs: table::new<ID, EmberShareConfig>(ctx),
            holdback_queues: table::new<ID, Queue<HoldbackEntry>>(ctx),
            fee_waived_addresses: vector::empty(),
            holdback_waived_addresses: vector::empty(),
            redemption_active_sources: vec_set::empty(),
            sequence_number: 0,
        };

        events::emit_atomic_vault_created_event<T>(
            vault_id,
            name,
            admin,
            operator,
            rate_manager,
            sub_accounts,
            min_withdrawal_shares,
            fee_percentage,
            max_rate_change_per_update,
            rate_update_interval,
            rate.value,
            max_tvl,
        );

        (vault, ShareVaultTicket {})
    }

    /// Shares the vault publicly. Consumes the `ShareVaultTicket` issued by
    /// `create_atomic_liquidity_vault`, so a newly created vault provably
    /// passes through this step: the ticket has no abilities, cannot be stored
    /// or dropped, and only this function destructures it.
    public fun share_atomic_vault<T>(vault: AtomicLiquidityVault<T>, ticket: ShareVaultTicket) {
        let ShareVaultTicket {} = ticket;
        transfer::share_object(vault);
    }

    // === Internal Auth Helpers ===

    fun assert_admin<T>(vault: &AtomicLiquidityVault<T>, ctx: &TxContext) {
        assert!(ctx.sender() == vault.admin, EInvalidPermission);
    }

    fun assert_operator<T>(vault: &AtomicLiquidityVault<T>, ctx: &TxContext) {
        assert!(ctx.sender() == vault.operator, EInvalidPermission);
    }

    /// Either trusted role. Used where a flow spans both — e.g. collecting
    /// Suilend rewards (routine operator work) that the admin must also be
    /// able to run in the same PTB as the admin-gated strategy exit, so the
    /// documented collect-before-burn teardown needs only one signer.
    fun assert_admin_or_operator<T>(vault: &AtomicLiquidityVault<T>, ctx: &TxContext) {
        let sender = ctx.sender();
        assert!(sender == vault.admin || sender == vault.operator, EInvalidPermission);
    }

    fun assert_rate_manager<T>(vault: &AtomicLiquidityVault<T>, ctx: &TxContext) {
        assert!(ctx.sender() == vault.rate_manager, EInvalidPermission);
    }

    /// Sequence-number semantics (indexer note).
    ///
    /// One `bump_sequence` per entry function, plus one nested sub-bump inside
    /// `charge_accrued_platform_fees` on the fee>0 path. Every event emitted
    /// from an entry function — the main event AND any auxiliary emits from
    /// side-effect helpers (`ensure_liquidity_*` StrategyWithdrawn, batch-loop
    /// per-request events, `set_strategy_none_from_*` paired emits) — carries
    /// the entry function's sequence. The nested `VaultPlatformFeeCharged`
    /// emit is the only exception: it is stamped with its own sub-bumped seq
    /// so it does not collide with the outer entry's event.
    ///
    /// This mirrors EVM `AtomicLiquidity` / `EmberVault` / `EmberETHVault`,
    /// where each external function calls `_incrementSequence()` exactly once
    /// and `_chargeAccruedPlatformFees` does its own nested bump. Off-chain
    /// indexers that key on `(vault, sequence_number)` alone will see multi-
    /// event bundles under one seq for entry functions with side-effect emits;
    /// partition by event type if uniqueness per event is required.
    fun bump_sequence<T>(vault: &mut AtomicLiquidityVault<T>): u128 {
        vault.sequence_number = vault.sequence_number + 1;
        vault.sequence_number
    }

    // === Admin Setters ===
    // All admin-setter functions:
    //   - require sender == vault.admin (except change_admin which takes &AdminCap)
    //   - increment sequence_number
    //   - emit the relevant event keyed by vault.id
    // Mirrors vault.move's setter conventions.

    /// Renames the vault. Admin-only.
    public fun update_vault_name<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        name: String,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_admin(vault, ctx);
        assert!(name != vault.name, ESameValue);
        let previous = vault.name;
        vault.name = name;
        let seq = bump_sequence(vault);
        events::emit_vault_name_updated_event(object::uid_to_inner(&vault.id), previous, name, seq);
    }

    /// Raises (or lowers) the max TVL. Admin-only. New cap must be ≥ current TVL.
    public fun update_vault_max_tvl<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        max_tvl: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(max_tvl > 0, EInvalidAmount);
        assert!(max_tvl != vault.max_tvl, ESameValue);
        // Floored TVL — see the sub-unit tolerance documented on `max_tvl`.
        assert!(get_vault_tvl_u128(vault) <= (max_tvl as u128), EMaxTVLReached);

        let previous = vault.max_tvl;
        vault.max_tvl = max_tvl;
        let seq = bump_sequence(vault);
        events::emit_vault_max_tvl_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            max_tvl,
            seq,
        );
    }

    /// Updates the max-rate-change-per-update guardrail. Admin-only.
    public fun update_vault_max_rate_change_per_update<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        max_rate_change_per_update: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_admin(vault, ctx);
        assert!(
            max_rate_change_per_update > 0
                && max_rate_change_per_update < PERCENT_MAX
                && max_rate_change_per_update != vault.rate.max_rate_change_per_update,
            EInvalidAmount,
        );
        let previous = vault.rate.max_rate_change_per_update;
        vault.rate.max_rate_change_per_update = max_rate_change_per_update;
        let seq = bump_sequence(vault);
        events::emit_vault_max_rate_change_per_update_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            max_rate_change_per_update,
            seq,
        );
    }

    /// Changes how often the rate manager may update the rate. Admin-only.
    public fun change_vault_rate_update_interval<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        interval: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_admin(vault, ctx);
        assert!(
            interval >= admin::get_min_rate_interval(config)
                && interval <= admin::get_max_rate_interval(config),
            EInvalidInterval,
        );
        assert!(interval != vault.rate.rate_update_interval, ESameValue);
        let previous = vault.rate.rate_update_interval;
        vault.rate.rate_update_interval = interval;
        let seq = bump_sequence(vault);
        events::emit_vault_rate_update_interval_changed_event(
            object::uid_to_inner(&vault.id),
            previous,
            interval,
            seq,
        );
    }

    /// Rotates the vault admin to a new address. Requires the protocol-level
    /// `AdminCap` — matches the auth model of `vault::change_vault_admin`.
    public fun change_vault_admin<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        _: &AdminCap,
        new_admin: address,
    ) {
        admin::verify_supported_package(config);
        common::assert_role_candidate_valid(
            new_admin,
            vault.admin,
            vault.operator,
            vault.rate_manager,
            &vault.sub_accounts,
            &vault.blacklisted,
        );
        let previous = vault.admin;
        vault.admin = new_admin;
        let seq = bump_sequence(vault);
        events::emit_vault_admin_changed_event(
            object::uid_to_inner(&vault.id),
            previous,
            new_admin,
            seq,
        );
    }

    /// Rotates the operator. Vault-admin-only.
    public fun change_vault_operator<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_operator: address,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        common::assert_role_candidate_valid(
            new_operator,
            vault.admin,
            vault.operator,
            vault.rate_manager,
            &vault.sub_accounts,
            &vault.blacklisted,
        );
        let previous = vault.operator;
        vault.operator = new_operator;
        let seq = bump_sequence(vault);
        events::emit_vault_operator_changed_event(
            object::uid_to_inner(&vault.id),
            previous,
            new_operator,
            seq,
        );
    }

    /// Rotates the rate manager. Vault-admin-only. Mirrors EVM's
    /// `setRateManager` (a constructor arg, mutable thereafter).
    public fun update_vault_rate_manager<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_rate_manager: address,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        common::assert_role_candidate_valid(
            new_rate_manager,
            vault.admin,
            vault.operator,
            vault.rate_manager,
            &vault.sub_accounts,
            &vault.blacklisted,
        );
        let previous = vault.rate_manager;
        vault.rate_manager = new_rate_manager;
        let seq = bump_sequence(vault);
        events::emit_vault_rate_manager_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            new_rate_manager,
            seq,
        );
    }

    /// Updates the annualised platform fee percentage. Admin-only. Settles any
    /// accrued fee at the OLD rate before mutating to avoid retroactively
    /// re-pricing prior elapsed time.
    public fun update_vault_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        fee_percentage: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(
            fee_percentage <= admin::get_max_allowed_fee_percentage(config),
            EInvalidFeePercentage,
        );
        assert!(fee_percentage != vault.fee_percentage, ESameValue);

        charge_accrued_platform_fees(vault, clock);

        let previous = vault.fee_percentage;
        vault.fee_percentage = fee_percentage;
        // Bump for VaultFeePercentageUpdated. Distinct from any bump the charge
        // helper may have made for its own emit — EVM per-event semantics.
        let seq = bump_sequence(vault);
        events::emit_vault_fee_percentage_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            fee_percentage,
            seq,
        );
    }

    /// Sets the minimum number of shares any single redeem-shares request
    /// must specify. Admin-only.
    public fun set_min_withdrawal_shares<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        min_withdrawal_shares: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(min_withdrawal_shares > 0, EZeroAmount);
        assert!(min_withdrawal_shares != vault.min_withdrawal_shares, EInvalidAmount);
        let previous = vault.min_withdrawal_shares;
        vault.min_withdrawal_shares = min_withdrawal_shares;
        let seq = bump_sequence(vault);
        events::emit_min_withdrawal_shares_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            min_withdrawal_shares,
            seq,
        );
    }

    /// Whitelists or de-lists an address as a sub-account. Sub-accounts can
    /// receive direct operator deposits/withdrawals that bypass share minting.
    public fun set_sub_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(!status || !vector::contains(&vault.blacklisted, &account), EBlacklistedAccount);
        assert!(
            account != vault.admin
                && account != vault.operator
                && account != vault.rate_manager,
            EInvalidAccount,
        );
        let previous = vault.sub_accounts;
        common::update_accounts(&mut vault.sub_accounts, account, status);
        let seq = bump_sequence(vault);
        events::emit_vault_sub_account_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            vault.sub_accounts,
            account,
            status,
            seq,
        );
    }

    /// Toggles one of the three pause flags. `operation` must be one of
    /// `b"deposits"`, `b"withdrawals"`, `b"privileged_operations"`.
    public fun set_pause_status<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        operation: vector<u8>,
        paused: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        set_pause_status_internal(vault, operation, paused);
    }

    /// Guardian fast-path for {set_pause_status}. Same effect as the admin
    /// variant but callable directly by the protocol guardian for emergency
    /// response. Mirrors EVM's `EmberProtocolConfig.setVaultPausedStatus`.
    ///
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EUnauthorized (in admin module): If the sender is not the guardian
    ///   (also if the guardian is unset).
    /// - EInvalidPauseOperation: If `operation` is not one of the three known ops.
    /// - EInvalidStatus: If `paused` equals the current flag for that operation.
    public fun guardian_set_pause_status<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        operation: vector<u8>,
        paused: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_guardian(config, ctx);
        set_pause_status_internal(vault, operation, paused);
    }

    /// Shared implementation of pause-status flipping. Extracted so both the
    /// admin-gated and guardian-gated entry points call the same code.
    fun set_pause_status_internal<T>(
        vault: &mut AtomicLiquidityVault<T>,
        operation: vector<u8>,
        paused: bool,
    ) {
        let changed = if (operation == OP_DEPOSITS) {
            if (vault.paused_deposits == paused) { false }
            else { vault.paused_deposits = paused; true }
        } else if (operation == OP_WITHDRAWALS) {
            if (vault.paused_withdrawals == paused) { false }
            else { vault.paused_withdrawals = paused; true }
        } else if (operation == OP_PRIVILEGED) {
            if (vault.paused_privileged_operations == paused) { false }
            else { vault.paused_privileged_operations = paused; true }
        } else {
            abort EInvalidPauseOperation
        };

        assert!(changed, EInvalidStatus);
        let seq = bump_sequence(vault);
        events::emit_atomic_vault_pause_status_updated_event(
            object::uid_to_inner(&vault.id),
            std::string::utf8(operation),
            paused,
            seq,
        );
    }

    /// Sets the cumulative cap for instant-withdraw redemptions. Headroom for
    /// new withdrawals is `new_max - cumulative_instant_withdraw_shares`. Set
    /// below cumulative to halt instant withdrawals; raise to grant capacity.
    public fun set_max_instant_withdraw_shares<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_max: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(new_max != vault.max_instant_withdraw_shares, ESameValue);
        let previous = vault.max_instant_withdraw_shares;
        vault.max_instant_withdraw_shares = new_max;
        let seq = bump_sequence(vault);
        events::emit_instant_withdraw_limit_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            new_max,
            vault.cumulative_instant_withdraw_shares,
            seq,
        );
    }

    /// Sets the fee percentage charged on instant withdrawals (1e9 = 100%).
    public fun set_instant_withdraw_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        new_fee_percentage: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        // Strictly below 100% so an instant withdraw always returns a non-zero
        // payout (a 100% fee would burn the user's shares for nothing).
        assert!(new_fee_percentage < PERCENT_MAX, EInstantWithdrawFeeTooHigh);
        assert!(new_fee_percentage != vault.instant_withdraw_fee_percentage, ESameValue);
        let previous = vault.instant_withdraw_fee_percentage;
        vault.instant_withdraw_fee_percentage = new_fee_percentage;
        let seq = bump_sequence(vault);
        events::emit_instant_withdraw_fee_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            new_fee_percentage,
            seq,
        );
    }

    /// Whitelists (or de-lists) another Ember vault's receipt token for the
    /// cross-vault swap, also setting fee / capacity / holdback / utilization
    /// parameters, the per-swap dust floor, and the TVL-independent absolute
    /// held-value cap. Existing in-flight epoch state and the fee-multiplier
    /// curve are preserved across updates — the curve is administered
    /// separately via `set_ember_share_fee_multiplier_tier` /
    /// `remove_ember_share_fee_multiplier_tier`.
    ///
    /// `min_swap_gross` blocks sub-unit swaps that would round the fee to
    /// zero while still queueing a near-zero holdback entry — pass `0` to
    /// disable the floor. `max_held_value_absolute` is a TVL-independent
    /// ceiling on the post-swap held value of this source share — pass `0`
    /// to disable the absolute cap and rely only on `max_utilization_percentage`.
    public fun set_ember_share_whitelist<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        whitelisted: bool,
        fee_percentage: u64,
        max_capacity_percentage: u64,
        holdback_percentage: u64,
        max_utilization_percentage: u64,
        min_swap_gross: u64,
        max_held_value_absolute: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(
            // Strictly below 100% to match the swap's effective-fee guard: a
            // 100% base fee would make every swap for this source abort.
            fee_percentage < PERCENT_MAX
                && max_capacity_percentage <= PERCENT_MAX
                && holdback_percentage <= PERCENT_MAX
                && max_utilization_percentage <= PERCENT_MAX,
            EInvalidPercentage,
        );
        // fee + holdback cannot exceed 100% — would underflow net payout.
        assert!(fee_percentage + holdback_percentage <= PERCENT_MAX, EInvalidPercentage);

        if (table::contains(&vault.ember_share_configs, share_vault_id)) {
            let cfg = table::borrow_mut(&mut vault.ember_share_configs, share_vault_id);
            cfg.whitelisted = whitelisted;
            cfg.fee_percentage = fee_percentage;
            cfg.max_capacity_percentage = max_capacity_percentage;
            cfg.holdback_percentage = holdback_percentage;
            cfg.max_utilization_percentage = max_utilization_percentage;
            cfg.min_swap_gross = min_swap_gross;
            cfg.max_held_value_absolute = max_held_value_absolute;
            // fee_multiplier_curve intentionally preserved across updates.
            // Re-validate it against the new base + holdback: the curve is
            // monotonic, so its top tier carries the largest multiplier — if
            // that tier still leaves a positive payout, every tier does. Blocks
            // raising the base into a config that would brick high-utilization
            // swaps (the mirror of the check in set_ember_share_fee_multiplier_tier).
            let curve_len = vector::length(&cfg.fee_multiplier_curve);
            if (curve_len > 0) {
                let top = vector::borrow(&cfg.fee_multiplier_curve, curve_len - 1).multiplier;
                let effective_top = math::mul(fee_percentage, top);
                assert!(
                    effective_top < PERCENT_MAX
                        && effective_top + holdback_percentage <= PERCENT_MAX,
                    EInvalidFeeMultiplier,
                );
            };
        } else {
            table::add(&mut vault.ember_share_configs, share_vault_id, EmberShareConfig {
                whitelisted,
                fee_percentage,
                max_capacity_percentage,
                holdback_percentage,
                epoch_started_at: 0,
                epoch_used_amount: 0,
                max_utilization_percentage,
                fee_multiplier_curve: vector::empty(),
                min_swap_gross,
                max_held_value_absolute,
            });
        };

        let seq = bump_sequence(vault);
        events::emit_ember_share_whitelist_updated_event(
            object::uid_to_inner(&vault.id),
            share_vault_id,
            whitelisted,
            fee_percentage,
            max_capacity_percentage,
            holdback_percentage,
            max_utilization_percentage,
            min_swap_gross,
            max_held_value_absolute,
            seq,
        );
    }

    /// Sets per-account fee / holdback waivers for the EmberShare swap. The
    /// two waivers are independent — both may be set, neither, or one only.
    public fun set_swap_waiver<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        fee_waived: bool,
        holdback_waived: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(account != @0, EInvalidAccount);

        // Idempotent set on each list — ignore double-add / double-remove
        // here because both flags can change independently.
        toggle_address(&mut vault.fee_waived_addresses, account, fee_waived);
        toggle_address(&mut vault.holdback_waived_addresses, account, holdback_waived);

        let seq = bump_sequence(vault);
        events::emit_swap_waiver_updated_event(
            object::uid_to_inner(&vault.id),
            account,
            fee_waived,
            holdback_waived,
            seq,
        );
    }

    /// Idempotent vector toggle helper. Used by `set_swap_waiver` — unlike
    /// `common::update_accounts`, it does not abort on already-present /
    /// already-absent because the two waiver flags can change independently.
    fun toggle_address(list: &mut vector<address>, account: address, present: bool) {
        let (exists, idx) = vector::index_of(list, &account);
        if (present && !exists) {
            vector::push_back(list, account);
        } else if (!present && exists) {
            vector::remove(list, idx);
        }
    }

    // === EmberShare utilization + fee-multiplier curve setters ===

    /// Updates the maximum allowed utilization (concentration cap) for a
    /// whitelisted source share. Admin-only. 1e9 = 100%. Setting to 0
    /// effectively halts new swaps for this share until raised again.
    public fun set_ember_share_max_utilization<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        max_utilization_percentage: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(max_utilization_percentage <= PERCENT_MAX, EInvalidPercentage);
        assert!(
            table::contains(&vault.ember_share_configs, share_vault_id),
            EEmberShareNotWhitelisted,
        );

        let cfg = table::borrow_mut(&mut vault.ember_share_configs, share_vault_id);
        let previous = cfg.max_utilization_percentage;
        assert!(previous != max_utilization_percentage, ESameValue);
        cfg.max_utilization_percentage = max_utilization_percentage;

        let seq = bump_sequence(vault);
        events::emit_ember_share_utilization_updated_event(
            object::uid_to_inner(&vault.id),
            share_vault_id,
            previous,
            max_utilization_percentage,
            seq,
        );
    }

    /// Inserts a new fee-multiplier tier at `threshold` or updates the
    /// multiplier of an existing tier with the same threshold. Admin-only.
    /// The curve is kept sorted ascending by `threshold`. Constraints:
    ///   - `threshold <= 1e9` (utilization can't exceed 100%)
    ///   - `multiplier >= 1e9` (curve can only INCREASE fees vs the base)
    public fun set_ember_share_fee_multiplier_tier<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        threshold: u64,
        multiplier: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(threshold <= PERCENT_MAX, EInvalidPercentage);
        // Multiplier is in [1x, MAX_FEE_MULTIPLIER]: at least 1x (a tier never
        // discounts the base fee) and bounded above so the `base * multiplier`
        // math can't overflow and a curve can't be given an absurd tier.
        assert!(
            multiplier >= PERCENT_MAX && multiplier <= MAX_FEE_MULTIPLIER,
            EInvalidFeeMultiplier,
        );
        assert!(
            table::contains(&vault.ember_share_configs, share_vault_id),
            EEmberShareNotWhitelisted,
        );

        let cfg = table::borrow_mut(&mut vault.ember_share_configs, share_vault_id);
        // Reject a tier that would brick swaps at its utilization. Match BOTH
        // swap-time guards exactly: the effective fee (base * multiplier) alone
        // must be strictly below 100% (`< PERCENT_MAX`, as the swap asserts), and
        // effective + holdback must stay within 100%. Without this the
        // misconfiguration is silent until a swap hits that tier and aborts.
        let effective = math::mul(cfg.fee_percentage, multiplier);
        assert!(
            effective < PERCENT_MAX
                && effective + cfg.holdback_percentage <= PERCENT_MAX,
            EInvalidFeeMultiplier,
        );
        upsert_fee_multiplier_tier(&mut cfg.fee_multiplier_curve, threshold, multiplier);
        // Bound the curve length (lookup is O(n) per swap) and keep multipliers
        // non-decreasing with the utilization threshold — a higher-utilization
        // tier must not charge a lower fee than a lower one.
        assert!(
            vector::length(&cfg.fee_multiplier_curve) <= MAX_FEE_MULTIPLIER_TIERS,
            EInvalidFeeMultiplier,
        );
        assert_fee_curve_monotonic(&cfg.fee_multiplier_curve);

        let seq = bump_sequence(vault);
        events::emit_ember_share_fee_multiplier_tier_set_event(
            object::uid_to_inner(&vault.id),
            share_vault_id,
            threshold,
            multiplier,
            seq,
        );
    }

    /// Removes the tier at `threshold` from the curve. Admin-only. Aborts
    /// with `EInvalidRequest` if no tier exists at that threshold.
    public fun remove_ember_share_fee_multiplier_tier<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        threshold: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(
            table::contains(&vault.ember_share_configs, share_vault_id),
            EEmberShareNotWhitelisted,
        );

        let cfg = table::borrow_mut(&mut vault.ember_share_configs, share_vault_id);
        let removed = remove_fee_multiplier_tier(&mut cfg.fee_multiplier_curve, threshold);
        assert!(removed, EInvalidRequest);

        let seq = bump_sequence(vault);
        events::emit_ember_share_fee_multiplier_tier_removed_event(
            object::uid_to_inner(&vault.id),
            share_vault_id,
            threshold,
            seq,
        );
    }

    /// Upsert a tier in a sorted-ascending curve. If a tier exists at
    /// `threshold`, its multiplier is replaced. Otherwise, the new tier is
    /// inserted at the position that preserves the ascending invariant.
    fun upsert_fee_multiplier_tier(
        curve: &mut vector<FeeMultiplierTier>,
        threshold: u64,
        multiplier: u64,
    ) {
        let len = vector::length(curve);
        let mut i = 0;
        while (i < len) {
            let tier = vector::borrow(curve, i);
            if (tier.threshold == threshold) {
                let tier_mut = vector::borrow_mut(curve, i);
                tier_mut.multiplier = multiplier;
                return
            };
            if (tier.threshold > threshold) {
                vector::insert(curve, FeeMultiplierTier { threshold, multiplier }, i);
                return
            };
            i = i + 1;
        };
        // Largest threshold so far — append.
        vector::push_back(curve, FeeMultiplierTier { threshold, multiplier });
    }

    /// Asserts the curve's multipliers are non-decreasing across its (already
    /// ascending) thresholds — a higher-utilization tier can never charge a
    /// lower fee than a lower-utilization one.
    fun assert_fee_curve_monotonic(curve: &vector<FeeMultiplierTier>) {
        let len = vector::length(curve);
        let mut i = 1;
        while (i < len) {
            assert!(
                vector::borrow(curve, i).multiplier >= vector::borrow(curve, i - 1).multiplier,
                EInvalidFeeMultiplier,
            );
            i = i + 1;
        };
    }

    /// Remove a tier with matching `threshold`. Returns whether anything
    /// was removed.
    fun remove_fee_multiplier_tier(
        curve: &mut vector<FeeMultiplierTier>,
        threshold: u64,
    ): bool {
        let len = vector::length(curve);
        let mut i = 0;
        while (i < len) {
            let tier = vector::borrow(curve, i);
            if (tier.threshold == threshold) {
                vector::remove(curve, i);
                return true
            };
            i = i + 1;
        };
        false
    }

    /// Walk the sorted-ascending curve and return the multiplier of the
    /// highest threshold `<= utilization`. Returns `PERCENT_MAX` (1x) when
    /// the curve is empty or no tier matches.
    fun lookup_fee_multiplier(curve: &vector<FeeMultiplierTier>, utilization: u64): u64 {
        let len = vector::length(curve);
        let mut multiplier = PERCENT_MAX;
        let mut i = 0;
        while (i < len) {
            let tier = vector::borrow(curve, i);
            if (utilization >= tier.threshold) {
                multiplier = tier.multiplier;
                i = i + 1;
            } else {
                // Ascending curve — once we pass our utilization, we're done.
                break
            };
        };
        multiplier
    }

    // === Withdrawal-Fee Setters ===
    // Withdrawal fees are an OPTIONAL feature. The `WithdrawalFee` dynamic
    // field is created lazily the first time any of these setters runs (or
    // the first deposit happens) — vaults that don't configure them pay no
    // extra storage. Mirrors `vault.move`'s setter layout.

    /// Sets the permanent withdrawal-fee percentage. Admin-only. 1e9 = 100%.
    /// Capped at < 1e9. Charged on every non-exempt processed withdrawal.
    public fun set_permanent_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        permanent_fee_percentage: u64,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_admin(vault, ctx);

        ensure_withdrawal_fee_exists(vault, ctx);
        let wf = dynamic_field::borrow_mut<vector<u8>, WithdrawalFee>(
            &mut vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
        );
        let previous = wf.permanent_fee_percentage;
        assert!(permanent_fee_percentage <= MAX_WITHDRAWAL_FEE_PERCENTAGE, EInvalidFeePercentage);
        // Protocol ceiling on permanent + time-based, individually and combined
        // (MAX_WITHDRAWAL_FEE_PERCENTAGE = 50%). Prevents a confiscatory
        // withdrawal fee and — being < 100% — still keeps the process_request
        // subtraction chain from underflowing.
        assert!(
            permanent_fee_percentage + wf.time_based_fee_percentage <= MAX_WITHDRAWAL_FEE_PERCENTAGE,
            EInvalidFeePercentage,
        );
        assert!(previous != permanent_fee_percentage, ESameValue);

        wf.permanent_fee_percentage = permanent_fee_percentage;

        let seq = bump_sequence(vault);
        events::emit_vault_permanent_fee_percentage_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            permanent_fee_percentage,
            seq,
        );
    }

    /// Sets the time-based withdrawal-fee percentage. Admin-only. Only
    /// charged when `time_based_fee_threshold > 0` AND the user's last
    /// deposit was within the threshold window.
    public fun set_time_based_fee_percentage<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        time_based_fee_percentage: u64,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_admin(vault, ctx);

        ensure_withdrawal_fee_exists(vault, ctx);
        let wf = dynamic_field::borrow_mut<vector<u8>, WithdrawalFee>(
            &mut vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
        );
        let previous = wf.time_based_fee_percentage;
        assert!(time_based_fee_percentage <= MAX_WITHDRAWAL_FEE_PERCENTAGE, EInvalidFeePercentage);
        // Protocol ceiling, individually and combined — see
        // set_permanent_fee_percentage for rationale.
        assert!(
            time_based_fee_percentage + wf.permanent_fee_percentage <= MAX_WITHDRAWAL_FEE_PERCENTAGE,
            EInvalidFeePercentage,
        );
        assert!(previous != time_based_fee_percentage, ESameValue);

        wf.time_based_fee_percentage = time_based_fee_percentage;

        let seq = bump_sequence(vault);
        events::emit_vault_time_based_fee_percentage_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            time_based_fee_percentage,
            seq,
        );
    }

    /// Sets the time-based fee threshold (ms from last deposit). Admin-only.
    /// Set to 0 to disable the time-based fee.
    public fun set_time_based_fee_threshold<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        time_based_fee_threshold: u64,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_admin(vault, ctx);

        ensure_withdrawal_fee_exists(vault, ctx);
        let wf = dynamic_field::borrow_mut<vector<u8>, WithdrawalFee>(
            &mut vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
        );
        let previous = wf.time_based_fee_threshold;
        assert!(previous != time_based_fee_threshold, ESameValue);

        wf.time_based_fee_threshold = time_based_fee_threshold;

        let seq = bump_sequence(vault);
        events::emit_vault_time_based_fee_threshold_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            time_based_fee_threshold,
            seq,
        );
    }

    /// Adds (`status = true`) or removes (`status = false`) `user` from the
    /// withdrawal-fee exemption list. Operator-only.
    ///
    /// Aborts:
    /// - `EBlacklistedAccount` if adding a blacklisted user
    /// - `EInvalidAccount` if user is admin / operator / rate manager
    /// - `common::EAlreadyExists` if adding an already-listed user
    /// - `common::ENotFound` if removing a not-listed user
    public fun set_fee_exemption_list<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        user: address,
        status: bool,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_operator(vault, ctx);

        assert!(!status || !vector::contains(&vault.blacklisted, &user), EBlacklistedAccount);
        assert!(
            user != vault.admin
                && user != vault.operator
                && user != vault.rate_manager,
            EInvalidAccount,
        );

        ensure_withdrawal_fee_exists(vault, ctx);
        let wf = dynamic_field::borrow_mut<vector<u8>, WithdrawalFee>(
            &mut vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
        );
        let previous = wf.fee_exempt;
        common::update_accounts(&mut wf.fee_exempt, user, status);
        let new_list = wf.fee_exempt;

        let seq = bump_sequence(vault);
        events::emit_vault_fee_exempt_list_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            new_list,
            user,
            status,
            seq,
        );
    }

    // === Withdrawal-Fee Helpers (internal) ===

    fun init_withdrawal_fee(ctx: &mut TxContext): WithdrawalFee {
        WithdrawalFee {
            permanent_fee_percentage: 0,
            time_based_fee_percentage: 0,
            time_based_fee_threshold: 0,
            fee_exempt: vector::empty(),
            last_deposit_ts: table::new(ctx),
        }
    }

    fun ensure_withdrawal_fee_exists<T>(vault: &mut AtomicLiquidityVault<T>, ctx: &mut TxContext) {
        if (!dynamic_field::exists_with_type<vector<u8>, WithdrawalFee>(&vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD)) {
            let wf = init_withdrawal_fee(ctx);
            dynamic_field::add<vector<u8>, WithdrawalFee>(
                &mut vault.id,
                WITHDRAWAL_FEE_DYNAMIC_FIELD,
                wf,
            );
        }
    }

    // === Operator Setters ===

    /// Adds (`status = true`) or removes (`status = false`) `account` from
    /// the blacklist. Operator-only.
    public fun set_blacklisted_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_operator(vault, ctx);
        set_blacklisted_account_internal(vault, account, status);
    }

    /// Guardian fast-path for {set_blacklisted_account}. Deliberately bypasses
    /// the `verify_protocol_not_paused` check the operator variant enforces:
    /// the whole point of the guardian is emergency response, and the pause
    /// state must not lock out the guardian from adding a bad actor to the
    /// blacklist. Mirrors EVM's `EmberProtocolConfig.guardianSetBlacklistedAccount`.
    ///
    /// Aborts with:
    /// - EUnsupportedPackage: If the package is not supported.
    /// - EUnauthorized (in admin module): If the sender is not the guardian
    ///   (also if the guardian is unset).
    /// - EInvalidAccount: If `account` is a sub-account and `status == true`.
    public fun guardian_set_blacklisted_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        account: address,
        status: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_guardian(config, ctx);
        set_blacklisted_account_internal(vault, account, status);
    }

    /// Shared implementation of blacklist updates. Extracted so both the
    /// operator-gated and guardian-gated entry points call the same code.
    fun set_blacklisted_account_internal<T>(
        vault: &mut AtomicLiquidityVault<T>,
        account: address,
        status: bool,
    ) {
        assert!(!status || !vector::contains(&vault.sub_accounts, &account), EInvalidAccount);

        let previous = vault.blacklisted;
        common::update_accounts(&mut vault.blacklisted, account, status);
        let seq = bump_sequence(vault);
        events::emit_vault_blacklisted_account_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            vault.blacklisted,
            account,
            status,
            seq,
        );
    }

    /// Adds (`status = true`) or removes (`status = false`) `user` from the
    /// deposit allowlist. Operator-only. Mirrors `vault::set_deposit_user_list`:
    /// the `vector<address>` lives in a lazily-created dynamic field
    /// (`DEPOSIT_USER_LIST_DYNAMIC_FIELD`) and the field is removed once the
    /// list empties so vaults that don't gate deposits pay no extra storage.
    /// While the field exists, only listed addresses can deposit. Withdrawals
    /// are NEVER gated by this list — users who received shares before being
    /// de-listed can still redeem them.
    ///
    /// Aborts:
    /// - `EBlacklistedAccount` if adding a blacklisted user
    /// - `EInvalidAccount` if user is admin / operator / rate manager
    /// - `common::EAlreadyExists` if adding an already-listed user
    /// - `common::ENotFound` if removing a not-listed user
    public fun set_deposit_user_list<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        user: address,
        status: bool,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert_operator(vault, ctx);

        assert!(!status || !vector::contains(&vault.blacklisted, &user), EBlacklistedAccount);
        assert!(
            user != vault.admin
                && user != vault.operator
                && user != vault.rate_manager,
            EInvalidAccount,
        );

        if (!dynamic_field::exists_with_type<vector<u8>, vector<address>>(&vault.id, DEPOSIT_USER_LIST_DYNAMIC_FIELD)) {
            dynamic_field::add<vector<u8>, vector<address>>(
                &mut vault.id,
                DEPOSIT_USER_LIST_DYNAMIC_FIELD,
                vector::empty(),
            );
        };

        let list = dynamic_field::borrow_mut<vector<u8>, vector<address>>(
            &mut vault.id, DEPOSIT_USER_LIST_DYNAMIC_FIELD,
        );
        let previous = *list;
        common::update_accounts(list, user, status);
        let current = *list;

        let seq = bump_sequence(vault);
        events::emit_vault_deposit_user_list_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            current,
            user,
            status,
            seq,
        );

        // Reclaim storage when the list empties.
        if (vector::is_empty(&current)) {
            let _: vector<address> = dynamic_field::remove<vector<u8>, vector<address>>(
                &mut vault.id, DEPOSIT_USER_LIST_DYNAMIC_FIELD,
            );
        };
    }

    // === Rate Manager ===

    /// Updates the vault rate. Rate-manager-only. Validates the new rate is
    /// within the protocol's min/max bounds and that the percent change is
    /// within `max_rate_change_per_update`. Settles accrued platform fees at
    /// the OLD rate first.
    public fun update_vault_rate<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        rate: u64,
        clock: &Clock,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_rate_manager(vault, ctx);

        let current_time = clock::timestamp_ms(clock);
        assert!(
            current_time - vault.rate.last_updated_at >= vault.rate.rate_update_interval,
            EInvalidInterval,
        );

        let diff = math::percent_change_from(vault.rate.value, rate);
        assert!(
            rate >= admin::get_min_rate(config)
                && rate <= admin::get_max_rate(config)
                && diff <= vault.rate.max_rate_change_per_update,
            EInvalidRate,
        );
        assert!(rate != vault.rate.value, ESameValue);

        charge_accrued_platform_fees(vault, clock);

        let previous = vault.rate.value;
        vault.rate.value = rate;
        vault.rate.last_updated_at = current_time;
        // Bump for VaultRateUpdated. Distinct from any bump the charge helper
        // may have made for its own emit — EVM per-event semantics.
        let seq = bump_sequence(vault);
        events::emit_vault_rate_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            rate,
            seq,
        );
    }

    // === Operator: Sub-Account & Fee Collection ===

    /// Operator transfers idle collateral to a whitelisted sub-account
    /// without burning shares.
    public fun supply_to_sub_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        sub_account: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_operator(vault, ctx);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);
        assert!(amount > 0 && amount <= balance::value(&vault.balance), EInsufficientBalance);

        let previous_balance = balance::value(&vault.balance);
        let bal = balance::split(&mut vault.balance, amount);
        transfer::public_transfer(coin::from_balance(bal, ctx), sub_account);
        let new_balance = balance::value(&vault.balance);

        let seq = bump_sequence(vault);
        events::emit_vault_withdrawal_without_redeeming_shares_event<T>(
            object::uid_to_inner(&vault.id),
            sub_account,
            previous_balance,
            new_balance,
            amount,
            seq,
        );
    }

    /// Sub-account funds back into the vault — used to settle yield earned
    /// off-vault. Mirrors `vault::deposit_to_vault_without_minting_shares_v2`.
    /// Receives `Coin<T>` via TTO so funds previously sent to the vault's
    /// address (including settled withdrawals from a source EmberVault) can
    /// be ingested without minting shares.
    ///
    /// ATTRIBUTION IS OPERATOR-ASSERTED, NOT AUTHENTICATED (I-08 sibling, I-12).
    /// `sub_account` is only checked against the allowlist — it is NOT verified
    /// to be where the funds came from, and cannot be: a `Receiving<Coin<T>>` is
    /// already owned by the vault when received and carries no sender, and
    /// accumulator funds (`balance::send_funds`) create no coin object and no
    /// sender record at all. So a trusted operator can attribute funds that
    /// originated at one allowlisted sub-account to any other.
    ///
    /// This is accepted: the operator is fully trusted, the funds were already
    /// the vault's, and nothing currently consumes the field. Treat it as a
    /// descriptive label. If per-sub-account P&L, loss allocation or provenance
    /// reporting is ever built on it, authenticate the source first — a typed
    /// settlement receipt, capability or nonce issued by the originating
    /// sub-account — because the value is not trustworthy as provenance today.
    public fun deposit_from_sub_account<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        token: Receiving<Coin<T>>,
        sub_account: address,
        ctx: &TxContext,
    ) {
        assert_deposit_from_sub_account_allowed(vault, config, sub_account, ctx);

        let coin = transfer::public_receive(&mut vault.id, token);

        deposit_from_sub_account_internal(vault, coin::into_balance(coin), sub_account);
    }

    /// Same settlement as `deposit_from_sub_account`, but sourcing the funds
    /// from the vault's accumulator (address) balance instead of a coin object.
    /// Mirrors the classic vault's accumulator-balance deposit variant.
    /// Transfers made with `balance::send_funds` / `coin::send_funds` credit a
    /// per-address accumulator on the recipient and never create a `Coin<T>`
    /// object. Such funds are therefore unreachable via TTO — there is no
    /// `Receiving<Coin<T>>` to pass — and invisible to coin enumeration, so
    /// without this entry point they are stranded in the vault.
    ///
    /// `amount` is explicit because the accumulator has no redeem-all
    /// primitive, so callers must read the settled balance first.
    ///
    /// Aborts:
    /// - `EInvalidPermission` / `EInvalidAccount` / `EOperationPaused` from the
    ///   shared guards, before the accumulator is touched
    /// - `EZeroAmount` if `amount` is 0
    /// - `EObjectFundsWithdrawNotEnabled` (`sui::funds_accumulator`) if the
    ///   `enable_object_funds_withdraw` protocol feature is off on this network
    /// - natively, inside `balance::redeem_funds`, if `amount` exceeds the
    ///   settled accumulator balance. `withdraw_funds_from_object` itself does
    ///   NOT bound the amount — the framework defers that check to redemption —
    ///   so an over-withdraw is caught there, not at signing. The transaction
    ///   still aborts atomically, taking any batched deposits with it.
    public fun deposit_from_sub_account_v2<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        amount: u64,
        sub_account: address,
        ctx: &TxContext,
    ) {
        assert_deposit_from_sub_account_allowed(vault, config, sub_account, ctx);
        assert!(amount > 0, EZeroAmount);

        let withdrawal = balance::withdraw_funds_from_object<T>(&mut vault.id, amount);
        let funds = balance::redeem_funds(withdrawal);
        deposit_from_sub_account_internal(vault, funds, sub_account);
    }

    /// Shared guard set for the sub-account deposit entry points, so both
    /// sources of funds are gated identically.
    fun assert_deposit_from_sub_account_allowed<T>(
        vault: &AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        sub_account: address,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_operator(vault, ctx);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);
    }

    /// Joins settled funds into the vault balance and emits the deposit event.
    /// Callers are responsible for the guards.
    /// Emits `sub_account` verbatim as the deposit's attribution. See
    /// `deposit_from_sub_account` — the value is operator-asserted, not
    /// authenticated provenance.
    fun deposit_from_sub_account_internal<T>(
        vault: &mut AtomicLiquidityVault<T>,
        funds: Balance<T>,
        sub_account: address,
    ) {
        let amount = balance::value(&funds);
        assert!(amount > 0, EZeroAmount);

        let previous_balance = balance::value(&vault.balance);
        balance::join(&mut vault.balance, funds);
        let new_balance = balance::value(&vault.balance);

        let seq = bump_sequence(vault);
        events::emit_vault_deposit_without_minting_shares_event<T>(
            object::uid_to_inner(&vault.id),
            sub_account,
            previous_balance,
            new_balance,
            amount,
            seq,
        );
    }

    /// Settles accrued fees and forwards `vault.fee.accrued - loss` collateral
    /// to the protocol fee recipient. Operator-only.
    ///
    /// `loss` lets the operator absorb an off-vault shortfall (e.g. a strategy
    /// loss the vault has already booked into its receipt-token / position
    /// holdings) by netting it against unclaimed fees BEFORE the transfer.
    /// The full `vault.fee.accrued` is settled to zero; only `accrued - loss`
    /// actually leaves the vault. Passing `loss = 0` matches the previous
    /// transfer-everything behavior.
    ///
    /// Aborts:
    /// - `EZeroAmount` if no fees are accrued
    /// - `EInvalidAmount` if `loss > vault.fee.accrued`
    /// - `EInsufficientBalance` if the idle balance can't cover `accrued - loss`
    /// - `EInvalidAccount` if the protocol's platform-fee recipient is
    ///   currently `@0x0` (would silently sink the net collateral to the
    ///   zero address; matches EVM's `if (recipient == address(0)) revert
    ///   ZeroAddress` in `AtomicLiquidity.collectPlatformFee`).
    public fun collect_platform_fee<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        loss: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_operator(vault, ctx);

        charge_accrued_platform_fees(vault, clock);

        let accrued = vault.fee.accrued;
        assert!(accrued > 0, EZeroAmount);
        assert!(loss <= accrued, EInvalidAmount);

        let net_amount = accrued - loss;
        assert!(balance::value(&vault.balance) >= net_amount, EInsufficientBalance);

        vault.fee.accrued = 0;

        let recipient = admin::get_platform_fee_recipient(config);
        // Refuse to send collateral to the zero address — an unconfigured
        // (or reset) protocol recipient would otherwise burn the net payout.
        // The full accrued is still zeroed above so the loss branch can run
        // to completion; only the transfer is gated.
        assert!(recipient != @0x0, EInvalidAccount);
        if (net_amount > 0) {
            let bal = balance::split(&mut vault.balance, net_amount);
            transfer::public_transfer(coin::from_balance(bal, ctx), recipient);
        };

        // Bump for AtomicProtocolFeeCollected. Distinct from any bump the
        // charge helper may have made for its own emit — EVM per-event
        // semantics.
        let seq = bump_sequence(vault);
        events::emit_atomic_protocol_fee_collected_event<T>(
            object::uid_to_inner(&vault.id),
            net_amount,
            loss,
            balance::value(&vault.balance),
            recipient,
            seq,
        );
    }

    // === Deposit ===

    /// Deposits `coin` into the vault and credits internal shares to `receiver`.
    /// Shares are non-transferable — they live in the vault's `shares` table.
    /// `min_shares` provides slippage protection.
    public fun deposit<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        coin: Coin<T>,
        min_shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_deposits, EOperationPaused);

        charge_accrued_platform_fees(vault, clock);

        let depositor = ctx.sender();
        assert!(!vector::contains(&vault.blacklisted, &depositor), EBlacklistedAccount);
        assert!(!vector::contains(&vault.blacklisted, &receiver), EBlacklistedAccount);
        assert!(!vector::contains(&vault.sub_accounts, &depositor), ESubAccount);
        assert!(!vector::contains(&vault.sub_accounts, &receiver), ESubAccount);

        // If a deposit allowlist exists, only listed addresses may deposit.
        // Matches `vault::deposit_asset_v2` — gate is keyed by the sender
        // (the party funding the deposit), not the receiver. Withdrawals
        // remain ungated so users who received shares before being de-listed
        // can still redeem them.
        if (dynamic_field::exists_with_type<vector<u8>, vector<address>>(&vault.id, DEPOSIT_USER_LIST_DYNAMIC_FIELD)) {
            let list = dynamic_field::borrow<vector<u8>, vector<address>>(
                &vault.id, DEPOSIT_USER_LIST_DYNAMIC_FIELD,
            );
            assert!(vector::contains(list, &depositor), EDepositNotAllowed);
        };

        let amount = coin::value(&coin);
        assert!(amount > 0, EZeroAmount);

        balance::join(&mut vault.balance, coin::into_balance(coin));

        let shares_minted = math::mul(amount, vault.rate.value);
        assert!(shares_minted > 0, EZeroAmount);
        assert!(shares_minted >= min_shares, ESlippageToleranceExceeded);

        // Mint internal shares to receiver. The returned prior balance is the
        // weight for the receiver's existing deposit timestamp in the
        // amount-weighted update below (no extra `balance_of` lookup).
        let receiver_shares_before = increment_account_shares(&mut vault.shares, receiver, shares_minted);
        vault.total_shares = vault.total_shares + shares_minted;

        // Floored TVL — see the sub-unit tolerance documented on `max_tvl`.
        assert!(get_vault_tvl_u128(vault) <= (vault.max_tvl as u128), EMaxTVLReached);

        // Bump for VaultDeposit. Distinct from any bump the charge helper may
        // have made for its own emit — EVM per-event semantics.
        let seq = bump_sequence(vault);

        events::emit_vault_deposit_event<T>(
            object::uid_to_inner(&vault.id),
            receiver,
            amount,
            shares_minted,
            balance::value(&vault.balance) - amount,
            balance::value(&vault.balance),
            vault.total_shares,
            seq,
        );

        // Amount-weighted last-deposit timestamp for the time-based (anti-JIT)
        // withdrawal fee, keyed by the RECEIVER (the account that holds and later
        // redeems the shares). The new deposit's time is blended into the
        // receiver's existing timestamp by share weight:
        //   new_ts = (old_shares*old_ts + new_shares*now) / (old_shares + new_shares)
        // (with old_shares == 0 this reduces to `now`). This closes two gaps with
        // a single value:
        //   - A fresh top-up crediting an already-aged receiver pulls the
        //     timestamp toward `now` in proportion to its size, so new shares
        //     cannot inherit the old deposit's age to dodge the fee (M-3 follow-up).
        //   - A dust deposit naming a victim as receiver moves the weighted
        //     timestamp only negligibly, so it cannot reset the victim's clock;
        //     forcing a meaningful move requires gifting the victim proportional
        //     shares (which they keep), so it is not a viable grief (original M-3).
        //
        // The weight is the receiver's share balance BEFORE this deposit PLUS any
        // shares they have already queued for withdrawal. `redeem_shares` moves
        // queued shares out of `shares` into the pending-burn pool, so a receiver
        // mid-withdrawal would otherwise weigh in at ~0 and a dust deposit — even
        // one front-running `process_withdrawal_requests` — could reset the clock
        // that the still-queued request reads at processing time. Counting the
        // pending shares keeps the full weight, so the queued request stays aged.
        let receiver_pending = if (table::contains(&vault.accounts, receiver)) {
            table::borrow(&vault.accounts, receiver).total_pending_withdrawal_shares
        } else { 0 };
        let old_weight = (receiver_shares_before as u128) + (receiver_pending as u128);

        ensure_withdrawal_fee_exists(vault, ctx);
        let timestamp = clock::timestamp_ms(clock);
        let last_deposit_ts = &mut dynamic_field::borrow_mut<vector<u8>, WithdrawalFee>(
            &mut vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
        ).last_deposit_ts;
        // Absent entry weights as `now`; it only matters when old_weight is 0,
        // where the formula yields `now` regardless.
        let exists = table::contains(last_deposit_ts, receiver);
        let old_ts = if (exists) *table::borrow(last_deposit_ts, receiver) else timestamp;
        // denom > 0 since shares_minted > 0 (asserted above); weighted_ts lies in
        // [old_ts, timestamp] <= now, so the u64 narrowing cannot overflow.
        let denom = old_weight + (shares_minted as u128);
        let weighted_ts = (
            (old_weight * (old_ts as u128)
                + (shares_minted as u128) * (timestamp as u128)) / denom
        ) as u64;
        if (exists) {
            *table::borrow_mut(last_deposit_ts, receiver) = weighted_ts;
        } else {
            table::add(last_deposit_ts, receiver, weighted_ts);
        };

        shares_minted
    }

    // === Redeem (Request-Based) ===

    /// Queues a withdrawal request for `shares`. Shares move from the user's
    /// balance into `pending_burn_shares` and stay there until the operator
    /// processes the request (burning) or the user cancels (returning to user).
    public fun redeem_shares<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &TxContext,
    ): WithdrawalRequest {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_withdrawals, EOperationPaused);

        let owner = ctx.sender();
        assert!(!vector::contains(&vault.blacklisted, &owner), EBlacklistedAccount);
        assert!(!vector::contains(&vault.blacklisted, &receiver), EBlacklistedAccount);
        // Reject a null receiver up-front: such a request would be queued,
        // then abort at processing time on `transfer::public_transfer(coin,
        // @0x0)`, freezing the FIFO withdrawal queue at the head. Matches the
        // EVM fix in `AtomicLiquidity.sol:1355`.
        assert!(receiver != @0x0, EInvalidReceiver);
        assert!(shares >= vault.min_withdrawal_shares, EInsufficientShares);

        let owner_balance = if (table::contains(&vault.shares, owner)) {
            *table::borrow(&vault.shares, owner)
        } else { 0 };
        assert!(owner_balance >= shares, EInsufficientShares);

        // Move shares from owner into the pending-burn pool.
        decrement_account_shares(&mut vault.shares, owner, shares);
        vault.pending_burn_shares = vault.pending_burn_shares + shares;

        let estimated_withdraw_amount = math::div(shares, vault.rate.value);
        bump_sequence(vault);

        let request = WithdrawalRequest {
            owner,
            receiver,
            shares,
            estimated_withdraw_amount,
            timestamp: clock::timestamp_ms(clock),
            sequence_number: vault.sequence_number,
        };

        queue::enqueue(&mut vault.pending_withdrawals, request);
        update_account_state(vault, &request, true, option::none());

        events::emit_request_redeemed_event<T>(
            object::uid_to_inner(&vault.id),
            request.owner,
            request.receiver,
            request.shares,
            request.timestamp,
            vault.total_shares,
            vault.pending_burn_shares,
            vault.sequence_number,
        );

        request
    }

    /// Marks a queued withdrawal request as cancelled. The cancel is realised
    /// when the operator processes the request — at that point the shares are
    /// returned to the owner via the cancellation skip path.
    public fun cancel_pending_withdrawal_request<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        sequence_number: u128,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_withdrawals, EOperationPaused);

        let sender = ctx.sender();
        assert!(table::contains(&vault.accounts, sender), EUserDoesNotHaveAccount);

        let account_state = table::borrow_mut(&mut vault.accounts, sender);
        let (already_cancelled, _) = vector::index_of(
            &account_state.cancel_withdraw_request,
            &sequence_number,
        );
        assert!(!already_cancelled, EInvalidRequest);

        let index = account_state.pending_withdrawal_requests.find_index!(
            |r| r.sequence_number == sequence_number,
        );
        assert!(index.is_some(), EInvalidRequest);
        let request = vector::borrow(
            &account_state.pending_withdrawal_requests,
            *option::borrow(&index),
        );

        account_state.cancel_withdraw_request.push_back(sequence_number);

        events::emit_request_cancelled_event(
            object::uid_to_inner(&vault.id),
            request.owner,
            request.sequence_number,
            account_state.cancel_withdraw_request,
        );
    }

    /// Processes up to `num_requests` queued withdrawals. Each is burnt
    /// (paying out collateral to the receiver) or skipped (returning shares
    /// to the owner) depending on cancel/blacklist state.
    public fun process_withdrawal_requests<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        num_requests: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_withdrawals, EOperationPaused);
        assert_operator(vault, ctx);
        assert!(num_requests > 0, EZeroAmount);

        charge_accrued_platform_fees(vault, clock);

        // Bump ONCE before the loop — mirrors EVM AtomicLiquidity.
        // processWithdrawalRequests, where every per-request RequestProcessed
        // event AND the ProcessRequestsSummary share this same sequence number.
        bump_sequence(vault);

        let mut total_shares_burnt = 0u64;
        let mut total_processed = 0u64;
        let mut total_amount_withdrawn = 0u64;
        let mut requests_skipped = 0u64;
        let mut requests_cancelled = 0u64;
        let current_time = clock::timestamp_ms(clock);

        let queue_len = queue::len(&vault.pending_withdrawals);
        let to_process = if (num_requests < queue_len) num_requests else queue_len;

        let mut i = 0;
        while (i < to_process) {
            let request = queue::dequeue(&mut vault.pending_withdrawals);
            let (skipped, cancelled, withdraw_amount, shares_burnt) =
                process_request(vault, &request, current_time, ctx);
            total_processed = total_processed + 1;
            total_shares_burnt = total_shares_burnt + shares_burnt;
            total_amount_withdrawn = total_amount_withdrawn + withdraw_amount;
            if (skipped) requests_skipped = requests_skipped + 1;
            if (cancelled) requests_cancelled = requests_cancelled + 1;
            i = i + 1;
        };

        events::emit_process_requests_summary_event(
            object::uid_to_inner(&vault.id),
            total_processed,
            requests_skipped,
            requests_cancelled,
            total_shares_burnt,
            total_amount_withdrawn,
            vault.total_shares,
            vault.pending_burn_shares,
            vault.rate.value,
            vault.sequence_number,
        );
    }

    /// As `process_withdrawal_requests` but bounded by request timestamp instead
    /// of count.
    public fun process_withdrawal_requests_up_to_timestamp<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        timestamp: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_withdrawals, EOperationPaused);
        assert_operator(vault, ctx);

        charge_accrued_platform_fees(vault, clock);

        // Bump ONCE before the loop — mirrors EVM AtomicLiquidity.
        // processWithdrawalRequests, where every per-request RequestProcessed
        // event AND the ProcessRequestsSummary share this same sequence number.
        bump_sequence(vault);

        let mut total_shares_burnt = 0u64;
        let mut total_processed = 0u64;
        let mut total_amount_withdrawn = 0u64;
        let mut requests_skipped = 0u64;
        let mut requests_cancelled = 0u64;
        let current_time = clock::timestamp_ms(clock);

        while (!queue::is_empty(&vault.pending_withdrawals)) {
            let front = queue::peek(&vault.pending_withdrawals);
            if (front.timestamp > timestamp) break;
            let request = queue::dequeue(&mut vault.pending_withdrawals);
            let (skipped, cancelled, withdraw_amount, shares_burnt) =
                process_request(vault, &request, current_time, ctx);
            total_processed = total_processed + 1;
            total_shares_burnt = total_shares_burnt + shares_burnt;
            total_amount_withdrawn = total_amount_withdrawn + withdraw_amount;
            if (skipped) requests_skipped = requests_skipped + 1;
            if (cancelled) requests_cancelled = requests_cancelled + 1;
        };

        events::emit_process_requests_summary_event(
            object::uid_to_inner(&vault.id),
            total_processed,
            requests_skipped,
            requests_cancelled,
            total_shares_burnt,
            total_amount_withdrawn,
            vault.total_shares,
            vault.pending_burn_shares,
            vault.rate.value,
            vault.sequence_number,
        );
    }

    // === Internal Helpers ===

    /// Settles platform fees accrued since `vault.fee.last_charged_at`. Mirrors
    /// the same helper in `vault.move`; routes the math through
    /// `common::compute_platform_fee_delta` so both vaults use one source of
    /// truth.
    fun charge_accrued_platform_fees<T>(vault: &mut AtomicLiquidityVault<T>, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock);
        let last_charged_at = vault.fee.last_charged_at;

        if (current_time == last_charged_at) return;

        if (vault.fee_percentage == 0) {
            vault.fee.last_charged_at = current_time;
            return
        };

        // Compute fees against tvl net of already-accrued fees so the protocol
        // doesn't re-tax the pending-fee portion of TVL on each accrual round.
        // Mirrors EVM AtomicLiquidity._chargeAccruedPlatformFees' tvlForFeeCalc.
        // TVL is read as u128 so this exit-path accrual can't abort on an
        // over-u64 TVL (which would lock every exit — see get_vault_tvl_u128).
        let tvl = get_vault_tvl_u128(vault);
        let accrued = (vault.fee.accrued as u128);
        let tvl_for_fee_calc = if (tvl > accrued) tvl - accrued else 0;
        let fee_amount = common::compute_platform_fee_delta(
            tvl_for_fee_calc,
            vault.fee_percentage,
            last_charged_at,
            current_time,
        );

        vault.fee.last_charged_at = current_time;

        // Very small elapsed windows can u64-floor the computed fee to zero.
        // Skip the emit in that case so indexers don't see a stream of empty
        // VaultPlatformFeeCharged events with fee_amount == 0 — the write to
        // `last_charged_at` above is enough state advancement, and re-entering
        // this function later will pick up the missed window naturally.
        if (fee_amount == 0) {
            return
        };

        vault.fee.accrued = vault.fee.accrued + fee_amount;

        // Bump for VaultPlatformFeeCharged. Callers that emit their own main
        // event bump again for that emit — EVM per-event semantics, matching
        // AtomicLiquidity._chargeAccruedPlatformFees on the fee>0 branch.
        let seq = bump_sequence(vault);

        events::emit_vault_platform_fee_charged_event(
            object::uid_to_inner(&vault.id),
            fee_amount,
            vault.fee.accrued,
            vault.fee.last_charged_at,
            seq,
        );
    }

    /// Adds `amount` to `owner`'s share balance, lazily creating the table
    /// entry, and returns the balance BEFORE the increment (0 if the account was
    /// new). Callers that need the prior balance (e.g. the amount-weighted
    /// deposit-timestamp update) get it here instead of a second `balance_of`
    /// lookup on the same table.
    fun increment_account_shares(
        shares: &mut Table<address, u64>,
        owner: address,
        amount: u64,
    ): u64 {
        if (table::contains(shares, owner)) {
            let r = table::borrow_mut(shares, owner);
            let previous = *r;
            *r = *r + amount;
            previous
        } else {
            table::add(shares, owner, amount);
            0
        }
    }

    /// Decrements `shares[owner]` and removes the entry if it hits zero.
    fun decrement_account_shares(
        shares: &mut Table<address, u64>,
        owner: address,
        amount: u64,
    ) {
        let r = table::borrow_mut(shares, owner);
        assert!(*r >= amount, EInsufficientShares);
        *r = *r - amount;
        if (*r == 0) {
            let _: u64 = table::remove(shares, owner);
        }
    }

    /// Tracks a request in the per-account state. Mirrors vault.move's
    /// `update_account_state` — see that function for the cancel-index
    /// invariants this preserves.
    fun update_account_state<T>(
        vault: &mut AtomicLiquidityVault<T>,
        request: &WithdrawalRequest,
        add: bool,
        cancel_index: Option<u64>,
    ) {
        assert!(!(add && cancel_index.is_some()), EInvalidRequest);

        if (!table::contains(&vault.accounts, request.owner)) {
            table::add(&mut vault.accounts, request.owner, Account {
                total_pending_withdrawal_shares: 0,
                pending_withdrawal_requests: vector::empty(),
                cancel_withdraw_request: vector::empty(),
            });
        };

        let account_state = table::borrow_mut(&mut vault.accounts, request.owner);
        if (add) {
            account_state.total_pending_withdrawal_shares =
                account_state.total_pending_withdrawal_shares + request.shares;
            vector::push_back(&mut account_state.pending_withdrawal_requests, *request);
        } else {
            account_state.total_pending_withdrawal_shares =
                account_state.total_pending_withdrawal_shares - request.shares;
            // Requests dequeue in sequence order — the front of the vec is
            // always the request being settled.
            vector::remove(&mut account_state.pending_withdrawal_requests, 0);

            if (cancel_index.is_some()
                && *option::borrow(&cancel_index)
                    < vector::length(&account_state.cancel_withdraw_request)) {
                vector::remove(
                    &mut account_state.cancel_withdraw_request,
                    *option::borrow(&cancel_index),
                );
            }
        };

        if (account_state.total_pending_withdrawal_shares == 0) {
            table::remove(&mut vault.accounts, request.owner);
        }
    }

    /// Settles one queued request — burning shares and paying out collateral,
    /// or skipping & restoring shares to the owner. Returns
    /// `(skipped, cancelled, withdraw_amount, shares_burnt)`. `withdraw_amount`
    /// is the NET amount transferred to the receiver after withdrawal fees.
    ///
    /// Withdrawal fees (configured via the `WithdrawalFee` dynamic field) are
    /// applied only on the non-skip branch and only when the owner is not on
    /// the fee-exempt list. The fee amounts STAY in `vault.balance` rather
    /// than accruing into `platform_fee` — same as `vault.move`'s behavior.
    fun process_request<T>(
        vault: &mut AtomicLiquidityVault<T>,
        request: &WithdrawalRequest,
        current_time: u64,
        ctx: &mut TxContext,
    ): (bool, bool, u64, u64) {
        let mut withdraw_amount = math::div(request.shares, vault.rate.value);

        let account_state = table::borrow(&vault.accounts, request.owner);
        let num_cancelled = vector::length(&account_state.cancel_withdraw_request);
        let (cancelled, idx) = vector::index_of(
            &account_state.cancel_withdraw_request,
            &request.sequence_number,
        );
        let mut option_index = if (cancelled) option::some(idx) else option::none();

        let owner_blacklisted = vector::contains(&vault.blacklisted, &request.owner);
        let receiver_blacklisted = vector::contains(&vault.blacklisted, &request.receiver);
        let should_skip = owner_blacklisted
            || receiver_blacklisted
            || cancelled
            || withdraw_amount == 0;

        let mut shares_burnt: u64 = 0;
        let mut permanent_fee_charged: u64 = 0;
        let mut time_based_fee_charged: u64 = 0;

        if (should_skip) {
            if (!cancelled) {
                option_index = option::some(num_cancelled);
            };
            withdraw_amount = 0;
            // Return parked shares: pending_burn -= s, shares[owner] += s.
            // total_shares unchanged.
            vault.pending_burn_shares = vault.pending_burn_shares - request.shares;
            increment_account_shares(&mut vault.shares, request.owner, request.shares);
        } else {
            // Burn: pending_burn -= s, total_shares -= s.
            vault.pending_burn_shares = vault.pending_burn_shares - request.shares;
            vault.total_shares = vault.total_shares - request.shares;
            shares_burnt = request.shares;

            // Apply withdrawal fees if configured AND user is not exempt.
            // Both fees are computed on the ORIGINAL gross `withdraw_amount`
            // (not sequentially) — matches the EVM
            // `EmberVaultValidator.calculateWithdrawalFees` model where the
            // returned pair `(permanent, timeBased)` is derived from the same
            // gross input. Sequential deduction (computing time-based on
            // gross-minus-permanent) would under-charge the time-based fee
            // relative to EVM.
            if (dynamic_field::exists_with_type<vector<u8>, WithdrawalFee>(&vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD)) {
                let wf = dynamic_field::borrow<vector<u8>, WithdrawalFee>(
                    &vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
                );
                let is_exempt = vector::contains(&wf.fee_exempt, &request.owner);
                if (!is_exempt) {
                    let gross = withdraw_amount;
                    if (wf.permanent_fee_percentage > 0) {
                        permanent_fee_charged = math::mul(gross, wf.permanent_fee_percentage);
                    };
                    if (wf.time_based_fee_percentage > 0
                        && wf.time_based_fee_threshold > 0) {
                        let last_deposit = if (table::contains(&wf.last_deposit_ts, request.owner)) {
                            *table::borrow(&wf.last_deposit_ts, request.owner)
                        } else {
                            0
                        };
                        // Fire when user has no recorded deposit OR they are
                        // still inside the threshold window. Written to avoid the
                        // `last_deposit + threshold` overflow (a near-u64::MAX
                        // threshold would abort inside the withdrawal loop): the
                        // subtraction only runs once `current_time >= last_deposit`
                        // is known, and is exactly equivalent to
                        // `last_deposit + threshold > current_time`.
                        if (last_deposit == 0
                            || current_time < last_deposit
                            || wf.time_based_fee_threshold > (current_time - last_deposit)) {
                            time_based_fee_charged = math::mul(gross, wf.time_based_fee_percentage);
                        };
                    };
                    // Total fee cannot exceed gross — the setters cap
                    // `permanent + time_based <= MAX_WITHDRAWAL_FEE_PERCENTAGE`
                    // (50%), so this stays a defence in depth. Withdraw amount
                    // underflow here would signal a misconfiguration;
                    // `assert!(withdraw_amount > 0)` below catches the zero case.
                    let total_fee = permanent_fee_charged + time_based_fee_charged;
                    withdraw_amount = gross - total_fee;
                };
            };

            assert!(withdraw_amount > 0, EZeroAmount);
            assert!(balance::value(&vault.balance) >= withdraw_amount, EInsufficientBalance);
            let bal = balance::split(&mut vault.balance, withdraw_amount);
            transfer::public_transfer(coin::from_balance(bal, ctx), request.receiver);
        };

        update_account_state(vault, request, false, option_index);

        events::emit_request_processed_event<T>(
            object::uid_to_inner(&vault.id),
            request.owner,
            request.receiver,
            request.shares,
            withdraw_amount,
            request.timestamp,
            current_time,
            should_skip,
            cancelled,
            vault.total_shares,
            vault.pending_burn_shares,
            vault.sequence_number,
            request.sequence_number,
        );

        if (permanent_fee_charged > 0 || time_based_fee_charged > 0) {
            events::emit_withdrawal_fee_charged_event(
                object::uid_to_inner(&vault.id),
                request.owner,
                request.sequence_number,
                permanent_fee_charged,
                time_based_fee_charged,
            );
        };

        (should_skip, cancelled, withdraw_amount, shares_burnt)
    }

    // === Views ===

    public fun get_vault_id<T>(vault: &AtomicLiquidityVault<T>): ID {
        object::uid_to_inner(&vault.id)
    }
    public fun get_vault_name<T>(vault: &AtomicLiquidityVault<T>): String { vault.name }
    public fun get_vault_admin<T>(vault: &AtomicLiquidityVault<T>): address { vault.admin }
    public fun get_vault_operator<T>(vault: &AtomicLiquidityVault<T>): address { vault.operator }
    public fun get_vault_rate_manager<T>(vault: &AtomicLiquidityVault<T>): address { vault.rate_manager }
    public fun get_vault_sub_accounts<T>(vault: &AtomicLiquidityVault<T>): vector<address> { vault.sub_accounts }
    public fun get_vault_blacklisted<T>(vault: &AtomicLiquidityVault<T>): vector<address> { vault.blacklisted }
    public fun get_vault_rate<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.rate.value }
    public fun get_vault_rate_update_interval<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.rate.rate_update_interval }
    public fun get_vault_max_rate_change_per_update<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.rate.max_rate_change_per_update }
    public fun get_vault_last_updated_at<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.rate.last_updated_at }
    public fun get_vault_balance<T>(vault: &AtomicLiquidityVault<T>): u64 { balance::value(&vault.balance) }
    public fun get_vault_sequence_number<T>(vault: &AtomicLiquidityVault<T>): u128 { vault.sequence_number }
    public fun get_vault_fee_percentage<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.fee_percentage }
    public fun get_vault_min_withdrawal_shares<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.min_withdrawal_shares }
    public fun get_vault_max_tvl<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.max_tvl }
    public fun get_accrued_platform_fee<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.fee.accrued }
    public fun get_total_shares<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.total_shares }
    public fun get_pending_burn_shares<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.pending_burn_shares }
    public fun get_strategy_kind<T>(vault: &AtomicLiquidityVault<T>): u8 { vault.strategy_kind }

    /// Collateral currently deployed into the vault's SUILEND strategy,
    /// denominated in `T`.
    ///
    /// The Sui counterpart of EVM `AtomicLiquidity.getStrategyAssets()`. It
    /// exists for off-chain readers: `balance` alone is not what the vault can
    /// pay out, because the `*_with_suilend` exits call `ensure_liquidity_*` to
    /// redeem from the strategy inline. A reader that treats idle balance as
    /// the whole backing under-reports available liquidity for any vault that
    /// is doing its job.
    ///
    /// Unlike `get_vault_balance` this cannot be a pure object read — Suilend
    /// holds the position and its value moves with the reserve's interest, so
    /// the market must be passed in and the caller simulates the call.
    ///
    /// Returns 0 when the vault is not on the Suilend strategy or never opened
    /// an obligation. Read `get_strategy_kind` first to tell "no strategy" from
    /// "a strategy worth nothing".
    public fun get_suilend_strategy_assets<T, P>(
        vault: &AtomicLiquidityVault<T>,
        market: &LendingMarket<P>,
        clock: &Clock,
    ): u64 {
        if (vault.strategy_kind != strategy::strategy_suilend()) { return 0 };
        strategy::get_suilend_supplied_value<P, T>(&vault.id, market, clock)
    }

    /// Asserts this vault's strategy is the one the caller named, or that it has
    /// no strategy at all.
    ///
    /// The per-strategy getters above answer "how much is in THIS strategy", and
    /// 0 is a true answer for a vault deployed elsewhere. A TOTAL is different:
    /// returning `balance + 0` for a vault whose collateral sits in the other
    /// protocol is not a small answer, it is a wrong one, and it is wrong in the
    /// shape most likely to be believed — a plausible non-zero number that
    /// silently omits the deployed half.
    ///
    /// `STRATEGY_NONE` is allowed through deliberately: there the idle balance
    /// IS the whole backing, so the answer is complete.
    ///
    /// UNREACHABLE TODAY, KEPT ON PURPOSE. NONE and SUILEND are the only kinds
    /// and both are accepted here, so nothing can currently trip this assert and
    /// it has no negative test. It stays because the next strategy added would
    /// otherwise silently reintroduce exactly the defect it was written for: a
    /// total that reports `balance + 0` for a vault deployed somewhere this
    /// function cannot see.
    fun assert_backing_strategy<T>(vault: &AtomicLiquidityVault<T>, expected: u8) {
        assert!(
            vault.strategy_kind == expected || vault.strategy_kind == strategy::strategy_none(),
            EStrategyMismatch,
        );
    }

    /// Total assets backing the vault on the SUILEND strategy: idle balance plus
    /// deployed collateral.
    ///
    /// This is the figure a capacity or liquidity view wants, and computing it in
    /// one call keeps the two halves from being read at different times.
    /// Equivalent to EVM's `collateral.balanceOf(vault) + getStrategyAssets()`.
    ///
    /// GROSS, NOT NET — and deliberately so, matching the EVM figure. The idle
    /// side is the raw `Balance<T>`, which also holds two amounts already spoken
    /// for:
    ///   * the accrued platform fee, which `collect_platform_fee` later splits
    ///     out of this same balance — read it with `get_accrued_platform_fee`;
    ///   * queued swap holdbacks, which `release_users_holdback` pays out of this
    ///     same balance — walk them with `get_holdback_queue_length`.
    /// So this answers "what does the vault hold against its shares", not "what
    /// is free to pay out". A caller wanting the latter must subtract both; this
    /// function does not, because netting them here would bake one policy choice
    /// into a primitive that solvency, capacity and TVL views each read
    /// differently.
    ///
    /// Returns `u128` rather than `u64`. The sum is believed to be u64-bounded —
    /// both terms are amounts of the same coin `T` and are disjoint, so together
    /// they are bounded by `T`'s total supply, itself a `u64` on Sui — but that
    /// argument leans on an invariant of the external lending protocol, and the
    /// cost of being wrong is an aborting VIEW: a read that reverts takes the
    /// whole indexer snapshot with it rather than degrading. A wider return type
    /// removes the class outright.
    ///
    /// Aborts with `EStrategyMismatch` if the vault is deployed to the other
    /// strategy — see `assert_backing_strategy`.
    public fun get_total_backing_suilend<T, P>(
        vault: &AtomicLiquidityVault<T>,
        market: &LendingMarket<P>,
        clock: &Clock,
    ): u128 {
        assert_backing_strategy(vault, strategy::strategy_suilend());
        (balance::value(&vault.balance) as u128)
            + (get_suilend_strategy_assets<T, P>(vault, market, clock) as u128)
    }

    #[test_only]
    /// Forces `strategy_kind` without entering the lending protocol.
    ///
    /// Needed because the external lending stubs are `abort 0`, so no unit test
    /// can reach a strategy-active vault through the real activation path —
    /// which leaves the guards sitting downstream of the `strategy_kind` check
    /// untestable. The alternative was reordering those asserts so a bad
    /// recipient is caught before the strategy check, and that trades away a
    /// better diagnostic (`EStrategyMismatch` for calling the wrong collector)
    /// purely for test reachability.
    ///
    /// SCOPE: use only to reach a guard that sits behind the `strategy_kind`
    /// check. It writes the tag WITHOUT the obligation state a real activation
    /// creates, so it can manufacture states unreachable on chain — a Suilend
    /// tag with no obligation. Do not use it to fake activation for a test that then
    /// asserts on behaviour past that guard; such a test would pass against a
    /// vault that could not exist. The tag is validated so at least a
    /// nonsensical value cannot be planted.
    public fun set_strategy_kind_for_testing<T>(
        vault: &mut AtomicLiquidityVault<T>,
        kind: u8,
    ) {
        strategy::assert_valid_strategy(kind);
        vault.strategy_kind = kind;
    }

    /// Whether the Suilend obligation has been opened.
    ///
    /// `get_strategy_kind() == 1` only says `set_strategy_suilend` ran; Suilend
    /// activation is two calls and supply aborts until the second one has too
    /// (see `open_suilend_obligation`). This is the check that distinguishes
    /// them, so activation tooling can assert it rather than infer it from
    /// `SuilendObligationOpenedEvent`. False on a non-Suilend vault.
    public fun has_suilend_obligation<T>(vault: &AtomicLiquidityVault<T>): bool {
        strategy::has_suilend_obligation(&vault.id)
    }

    /// Object ID of the vault's Suilend obligation. The obligation lives in the
    /// lending market's `ObjectTable` and is not derivable from vault state, so
    /// this is the only on-chain way to resolve it — off-chain readers can also
    /// take it from `SuilendObligationOpenedEvent`.
    ///
    /// Aborts `strategy::ESuilendObligationMissing` if no obligation is open;
    /// pair with `has_suilend_obligation` when that is not already known.
    public fun get_suilend_obligation_id<T>(vault: &AtomicLiquidityVault<T>): ID {
        strategy::suilend_obligation_id(&vault.id)
    }
    public fun get_max_instant_withdraw_shares<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.max_instant_withdraw_shares }
    public fun get_cumulative_instant_withdraw_shares<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.cumulative_instant_withdraw_shares }
    public fun get_instant_withdraw_fee_percentage<T>(vault: &AtomicLiquidityVault<T>): u64 { vault.instant_withdraw_fee_percentage }
    public fun is_paused_deposits<T>(vault: &AtomicLiquidityVault<T>): bool { vault.paused_deposits }
    public fun is_paused_withdrawals<T>(vault: &AtomicLiquidityVault<T>): bool { vault.paused_withdrawals }
    public fun is_paused_privileged_operations<T>(vault: &AtomicLiquidityVault<T>): bool { vault.paused_privileged_operations }

    /// Per-user share balance. Returns 0 if user has no shares.
    public fun balance_of<T>(vault: &AtomicLiquidityVault<T>, account: address): u64 {
        if (table::contains(&vault.shares, account)) *table::borrow(&vault.shares, account) else 0
    }

    /// TVL in collateral units, computed as `total_shares / rate`. Mirrors
    /// `vault::get_vault_tvl`.
    public fun get_vault_tvl<T>(vault: &AtomicLiquidityVault<T>): u64 {
        if (vault.total_shares == 0) 0
        else math::div(vault.total_shares, vault.rate.value)
    }

    /// TVL as `u128`, without narrowing to `u64`. Use on paths that must not
    /// abort when TVL exceeds `u64::MAX` (large `total_shares` at a low rate) —
    /// chiefly fee accrual, which runs on every withdrawal / instant-withdraw /
    /// swap and whose abort would otherwise lock funds. Mirrors
    /// `vault::get_vault_tvl_u128`.
    public fun get_vault_tvl_u128<T>(vault: &AtomicLiquidityVault<T>): u128 {
        if (vault.total_shares == 0) 0
        else math::div_u128(vault.total_shares, vault.rate.value)
    }

    public fun calculate_shares_from_amount<T>(vault: &AtomicLiquidityVault<T>, amount: u64): u64 {
        math::mul(amount, vault.rate.value)
    }

    public fun calculate_amount_from_shares<T>(vault: &AtomicLiquidityVault<T>, shares: u64): u64 {
        math::div_ceil(shares, vault.rate.value)
    }

    /// Headroom for further instant withdrawals before the cumulative cap is
    /// hit. Clamped at 0 if the vault is currently over-cap.
    public fun available_instant_withdraw_shares<T>(vault: &AtomicLiquidityVault<T>): u64 {
        let max = vault.max_instant_withdraw_shares;
        let used = vault.cumulative_instant_withdraw_shares;
        if (max > used) max - used else 0
    }

    /// Read-only solvency signal for off-chain monitoring: the vault's
    /// collateral backing versus its modeled claims. Returned as
    /// `(backing, claims, is_solvent)` so consumers can decode the signed
    /// margin without a native `i128` type — `is_solvent == true` iff
    /// `backing >= claims`.
    ///
    /// - `backing` = idle collateral balance in this vault. External strategy
    ///   assets (Suilend cTokens) are NOT included here
    ///   because reading their present value requires a mutable reference to
    ///   the external protocol (unlike EVM ERC-4626's pure `convertToAssets`),
    ///   which can't be done from a `&AtomicLiquidityVault` view. Off-chain
    ///   monitors that care about strategy value should read the strategy
    ///   position separately and add it to `backing` themselves.
    /// - `claims` = `get_vault_tvl(vault) + vault.fee.accrued`. TVL is the
    ///   rate-based value owed to shareholders; accrued fee is a soft (junior)
    ///   claim against future yield that reconciles via `collect_platform_fee`.
    ///
    /// This is purely informational — there is NO on-chain enforcement. A
    /// transient `!is_solvent` is possible by design (soft fee claim + strategy
    /// value not counted here). Outstanding EmberShare-swap holdback
    /// liabilities are NOT subtracted from `backing` — they're tracked
    /// per-share in `holdback_queues` with no O(1) aggregate. Matches the
    /// modeling choice made by the EVM `solvencyMargin`.
    public fun solvency_margin<T>(
        vault: &AtomicLiquidityVault<T>,
    ): (u128, u128, bool) {
        // Widened to u128: the previous version narrowed share-derived TVL to
        // u64 and added the accrued fee in u64, so either step could abort
        // exactly in the extreme states a solvency monitor most needs to read.
        // A view that aborts removes the signal instead of reporting it.
        let backing = (balance::value(&vault.balance) as u128);
        let claims = get_vault_tvl_u128(vault) + (vault.fee.accrued as u128);
        (backing, claims, backing >= claims)
    }

    public fun is_blacklisted<T>(vault: &AtomicLiquidityVault<T>, account: address): bool {
        vector::contains(&vault.blacklisted, &account)
    }

    public fun get_account_total_pending_withdrawal_shares<T>(
        vault: &AtomicLiquidityVault<T>,
        account: address,
    ): u64 {
        if (!table::contains(&vault.accounts, account)) 0
        else table::borrow(&vault.accounts, account).total_pending_withdrawal_shares
    }

    public fun get_account_pending_withdrawal_requests<T>(
        vault: &AtomicLiquidityVault<T>,
        account: address,
    ): vector<WithdrawalRequest> {
        if (!table::contains(&vault.accounts, account)) vector::empty()
        else table::borrow(&vault.accounts, account).pending_withdrawal_requests
    }

    public fun get_account_cancelled_withdrawal_sequence_numbers<T>(
        vault: &AtomicLiquidityVault<T>,
        account: address,
    ): vector<u128> {
        if (!table::contains(&vault.accounts, account)) vector::empty()
        else table::borrow(&vault.accounts, account).cancel_withdraw_request
    }

    public fun decode_withdrawal_request(r: &WithdrawalRequest): (address, address, u64, u64, u64, u128) {
        (r.owner, r.receiver, r.shares, r.estimated_withdraw_amount, r.timestamp, r.sequence_number)
    }

    // === Strategy Management (Admin) ===
    //
    // The active strategy is selected via three setter functions, one per
    // tag. Switching strategies requires the previous strategy to be fully
    // unwound first — the setters call into `strategy::clear_*_state` which
    // aborts if any receipt-token / position-collateral remains.

    /// Switches the vault from Suilend strategy to STRATEGY_NONE. Auto-drains:
    /// redeems all held cTokens via Suilend's lending market and joins the
    /// resulting underlying balance into `vault.balance` before clearing the
    /// strategy tag. Operator does not need a separate
    /// `withdraw_from_suilend_strategy` call first.
    ///
    /// Aborts if the current strategy is not Suilend (`EStrategyMismatch`).
    public fun set_strategy_none_from_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        // Pause-gated to match the reward-collection path, for exactly the
        // reason the exit is gated (L-1): this now discards the
        // ObligationOwnerCap, and a paused vault must not burn it while
        // `claim_suilend_strategy_reward` is frozen — the documented
        // sweep-before-exit step would be impossible and every accrued reward
        // stranded. Harmless before the obligation change, when the Suilend
        // exit discarded nothing.
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_admin(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        // Rewards can only go to an allowlisted sub-account, so an empty list
        // freezes the sweep for every address — and this call discards the
        // capability, making anything accrued permanently unclaimable. Same
        // hazard as the pause gate above (L-1), different trigger.
        assert!(!vector::is_empty(&vault.sub_accounts), ENoRewardDestination);

        let drained = strategy::clear_suilend_state<P, T>(&mut vault.id, market, clock, ctx);
        let drained_amount = balance::value(&drained);
        balance::join(&mut vault.balance, drained);

        let previous = vault.strategy_kind;
        vault.strategy_kind = strategy::strategy_none();
        // One bump per entry function — mirrors EVM AtomicLiquidity.setStrategy
        // which calls `_incrementSequence()` once and emits only StrategyUpdated
        // (EVM's drain is silent). The Sui-only StrategyWithdrawn shares this
        // seq with StrategyUpdated so indexers can correlate them.
        let seq = bump_sequence(vault);
        if (drained_amount > 0) {
            events::emit_strategy_withdrawn_event<T>(
                object::uid_to_inner(&vault.id),
                previous,
                drained_amount,
                seq,
            );
        };
        events::emit_strategy_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            vault.strategy_kind,
            seq,
        );
    }

    /// SUI-vault counterpart of `set_strategy_none_from_suilend`. Identical
    /// bookkeeping, but drains via `strategy::clear_suilend_state_sui`, which
    /// threads `&mut SuiSystemState` through Suilend's
    /// request -> unstake -> fulfill path so an emergency evacuation cannot
    /// abort on staked reserve liquidity. Callable only on a `Vault<SUI>`.
    public fun set_strategy_none_from_suilend_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        // Pause-gated — see `set_strategy_none_from_suilend` (L-1).
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_admin(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        // Rewards can only go to an allowlisted sub-account, so an empty list
        // freezes the sweep for every address — and this call discards the
        // capability, making anything accrued permanently unclaimable. Same
        // hazard as the pause gate above (L-1), different trigger.
        assert!(!vector::is_empty(&vault.sub_accounts), ENoRewardDestination);

        let drained = strategy::clear_suilend_state_sui<P>(
            &mut vault.id, market, system_state, clock, ctx,
        );
        let drained_amount = balance::value(&drained);
        balance::join(&mut vault.balance, drained);

        let previous = vault.strategy_kind;
        vault.strategy_kind = strategy::strategy_none();
        // One bump per entry function — see `set_strategy_none_from_suilend`.
        let seq = bump_sequence(vault);
        if (drained_amount > 0) {
            events::emit_strategy_withdrawn_event<SUI>(
                object::uid_to_inner(&vault.id),
                previous,
                drained_amount,
                seq,
            );
        };
        events::emit_strategy_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            vault.strategy_kind,
            seq,
        );
    }

    /// Activates the Suilend strategy with `reserve_array_index`. The vault
    /// must currently be on `STRATEGY_NONE` (admin must clear any prior
    /// strategy first). The reserve index is looked up off-chain via
    /// `lending_market::reserve_array_index<P, T>` and passed in.
    ///
    /// Strategy switches are deliberately a two-step flow: first
    /// `set_strategy_none_from_suilend[_sui]` to drain the old
    /// position back into `vault.balance`, then `set_strategy_*` to activate
    /// the new one. This exists because the drain step needs the specific
    /// lending-market shared object
    /// that the destination strategy's setter doesn't take. Folding drain +
    /// activate into a single call would either require passing every shared
    /// object the vault might ever need to drain from, or would hide the
    /// transition inside a setter — the two-step keeps the state change
    /// visible on-chain and each call's shared-object requirements minimal.
    public fun set_strategy_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &LendingMarket<P>,
        reserve_array_index: u64,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        assert_admin(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_none(), EStrategyMismatch);

        strategy::init_suilend_state<P, T>(&mut vault.id, market, reserve_array_index);

        let previous = vault.strategy_kind;
        vault.strategy_kind = strategy::strategy_suilend();
        let seq = bump_sequence(vault);
        events::emit_strategy_updated_event(
            object::uid_to_inner(&vault.id),
            previous,
            vault.strategy_kind,
            seq,
        );
    }

    /// Opens the Suilend obligation the vault's supply is held in, completing
    /// Suilend activation. Must run after `set_strategy_suilend` and before the
    /// first `supply_to_suilend_strategy`, which aborts with
    /// `ESuilendObligationMissing` until it has.
    ///
    /// Holding the deposit inside an obligation is what makes it eligible for
    /// Suilend's deposit-side liquidity mining — raw cTokens accrue the
    /// reserve's base APR only, because reward share is tracked per obligation.
    ///
    /// Callable by EITHER the admin or the operator: it is a prerequisite for
    /// the operator's supply work, and it cannot clobber an existing obligation
    /// (`ESuilendObligationAlreadyExists`), so whichever role runs activation
    /// can finish it without a second signer. Same reasoning as the reward
    /// collection gate.
    ///
    /// Takes `&mut LendingMarket<P>` because Suilend's `create_obligation`
    /// inserts the new obligation into the market's `ObjectTable`.
    public fun open_suilend_obligation<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_admin_or_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);

        strategy::open_suilend_obligation<P, T>(&mut vault.id, market, ctx);

        let seq = bump_sequence(vault);
        events::emit_suilend_obligation_opened_event(
            object::uid_to_inner(&vault.id),
            strategy::suilend_market_id(&vault.id),
            strategy::suilend_obligation_id(&vault.id),
            strategy::suilend_reserve_index(&vault.id),
            seq,
        );
    }

    // === Strategy Supply / Withdraw (Operator) ===

    /// Operator deposits `amount` of idle vault collateral into Suilend.
    public fun supply_to_suilend_strategy<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        assert!(amount > 0, EZeroAmount);
        assert!(balance::value(&vault.balance) >= amount, EInsufficientBalance);

        let bal = balance::split(&mut vault.balance, amount);
        let supplied = strategy::supply_to_suilend<P, T>(
            &mut vault.id,
            market,
            clock,
            coin::from_balance(bal, ctx),
            ctx,
        );

        let seq = bump_sequence(vault);
        events::emit_strategy_supplied_event<T>(
            object::uid_to_inner(&vault.id),
            vault.strategy_kind,
            supplied,
            seq,
        );
        supplied
    }

    /// Operator pulls `amount` of underlying T back from Suilend into the
    /// vault's idle balance. May actually receive slightly more than `amount`
    /// due to cToken-ratio rounding — the surplus is simply joined into the
    /// vault balance.
    public fun withdraw_from_suilend_strategy<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        assert!(amount > 0, EZeroAmount);

        let received = strategy::withdraw_from_suilend<P, T>(
            &mut vault.id,
            market,
            clock,
            amount,
            ctx,
        );
        let received_amount = balance::value(&received);
        balance::join(&mut vault.balance, received);

        let seq = bump_sequence(vault);
        events::emit_strategy_withdrawn_event<T>(
            object::uid_to_inner(&vault.id),
            vault.strategy_kind,
            received_amount,
            seq,
        );
        received_amount
    }

    /// SUI-vault counterpart of `withdraw_from_suilend_strategy`. Drains
    /// through Suilend's request -> unstake -> fulfill path so the pull works
    /// even when the reserve holds its SUI staked. Callable only on a
    /// `Vault<SUI>`.
    public fun withdraw_from_suilend_strategy_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        assert!(amount > 0, EZeroAmount);

        let received = strategy::withdraw_from_suilend_sui<P>(
            &mut vault.id,
            market,
            system_state,
            clock,
            amount,
            ctx,
        );
        let received_amount = balance::value(&received);
        balance::join(&mut vault.balance, received);

        let seq = bump_sequence(vault);
        events::emit_strategy_withdrawn_event<SUI>(
            object::uid_to_inner(&vault.id),
            vault.strategy_kind,
            received_amount,
            seq,
        );
        received_amount
    }

    // === Strategy Reward Collection (Admin or Operator) ===

    /// Claims one accrued Suilend pool reward of coin type `RewardType` and
    /// forwards it to `sub_account`, which must be on the vault's sub-account
    /// allowlist. Returns the amount forwarded (0 is a valid no-op).
    ///
    /// Rewards are vault-earned value, so they go to a vault sub-account rather
    /// than the protocol fee recipient — see `forward_strategy_reward` for why
    /// that distinction has teeth.
    ///
    /// Suilend accounts rewards per `(reserve, reward slot, deposit-or-borrow)`
    /// triple, so a full sweep is one call per live triple — batch them in a
    /// single PTB. `reward_index` is a slot in the reserve's `pool_rewards`
    /// vector and a Suilend admin can vacate it, so the operator resolves it off
    /// chain per claim rather than the vault storing it. `is_deposit_reward`
    /// selects the reserve's deposit- or borrow-side reward manager; the vault
    /// only deposits, so it is `true` in practice.
    ///
    /// `RewardSourceType` names the reserve the reward accrues on. It is the
    /// vault's collateral for the strategy position itself, but NOT for rewards
    /// earned by secondary collateral a third party deposited into the
    /// obligation — those accrue on their own reserve (Q-02).
    ///
    /// Because `set_strategy_none_from_suilend` discards the
    /// `ObligationOwnerCap` and unclaimed rewards are unreachable afterwards,
    /// this MUST be called for each live reward triple before exiting, in the
    /// same PTB. Callable by EITHER the admin or the operator, so the admin who
    /// runs the (admin-gated) exit can also sweep in that same PTB without a
    /// second signer.
    ///
    /// No PTB price-refresh requirement:
    /// Suilend's `claim_rewards` gates only on bad debt, which a supply-only
    /// obligation cannot have.
    public fun claim_suilend_strategy_reward<T, P, RewardSourceType, RewardType>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        sub_account: address,
        reward_index: u64,
        is_deposit_reward: bool,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_admin_or_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);

        let reward = strategy::claim_suilend_reward<P, RewardSourceType, RewardType>(
            &vault.id,
            market,
            clock,
            reward_index,
            is_deposit_reward,
            ctx,
        );
        forward_strategy_reward<T, RewardType>(vault, sub_account, reward)
    }

    /// Withdraws a foreign collateral position of coin type `RewardType` from
    /// the vault's Suilend obligation and forwards it to `sub_account`.
    ///
    /// Q2. `claim_rewards_and_deposit` is permissionless — it takes an
    /// obligation id, not the owner cap — so anyone can claim this vault's
    /// rewards and deposit them into its obligation as collateral in a type the
    /// vault never chose. Teardown now refuses to discard the obligation cap
    /// while any deposit remains, which without this would let a third party
    /// block the exit indefinitely. This is the way out: the operator reads the
    /// foreign types off `obligation::deposits` and drains each one.
    ///
    /// The proceeds are reward-derived, so they take the same route as a claim
    /// — out to an allowlisted sub-account, converted off chain, returned via
    /// `deposit_from_sub_account`. Aborts if `RewardType` is the committed
    /// collateral type; that position exits through
    /// `withdraw_from_suilend_strategy`.
    public fun withdraw_suilend_secondary_collateral<T, P, RewardType>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        sub_account: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_admin_or_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);

        let recovered = strategy::withdraw_secondary_collateral<P, RewardType>(
            &vault.id, market, clock, ctx,
        );
        forward_strategy_reward<T, RewardType>(vault, sub_account, recovered)
    }

    /// SUI counterpart of `withdraw_suilend_secondary_collateral`, threading
    /// `&mut SuiSystemState` for Suilend's request -> unstake -> fulfill path.
    /// Needed because the generic redemption aborts once the reserve has moved
    /// its SUI into the staker (M-01), and a foreign SUI position is a likely
    /// case here rather than a corner one — SUI and sSUI are what these reserves
    /// actually pay out.
    ///
    /// Callable on any vault, not just `Vault<SUI>`: the SUI here is the foreign
    /// position's type, not the vault's collateral. Aborts if the vault's own
    /// collateral is SUI, since that position exits through
    /// `withdraw_from_suilend_strategy_sui`.
    public fun withdraw_suilend_secondary_collateral_sui<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        sub_account: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_privileged_operations, EOperationPaused);
        assert_admin_or_operator(vault, ctx);
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        assert!(vector::contains(&vault.sub_accounts, &sub_account), EInvalidAccount);

        let recovered = strategy::withdraw_secondary_collateral_sui<P>(
            &vault.id, market, system_state, clock, ctx,
        );
        forward_strategy_reward<T, SUI>(vault, sub_account, recovered)
    }

    /// Forwards a collected reward `Coin<C>` to `recipient` and emits
    /// `StrategyRewardCollectedEvent<C>`. Returns the forwarded amount (0 is a
    /// valid no-op — the coin is destroyed).
    ///
    /// PRECONDITION: `recipient` must already be checked against
    /// `vault.sub_accounts`. Every caller asserts it up front, before entering
    /// the lending protocol, so a bad address aborts without paying for the
    /// claim — and so the check is reachable in tests, which the external calls
    /// are not (`abort 0` stubs).
    ///
    /// Rewards go to a vault sub-account rather than the protocol platform-fee
    /// recipient because they are vault-earned value, and a sub-account has a
    /// route back: `deposit_from_sub_account` returns settled yield into
    /// `vault.balance` without minting shares, so it reaches depositors as a
    /// higher assets-per-share. The fee recipient has no such route — value sent
    /// there leaves the vault permanently.
    ///
    /// `C == T` IS POSSIBLE AND NOT SPECIAL-CASED. In practice reward tokens
    /// differ from the collateral — Suilend pays sSUI on the main pool's USDC
    /// reserve — so a swap is normally
    /// needed and the destination only decides who holds the proceeds until
    /// then. But nothing enforces `C != T`, and a reserve paying its own asset
    /// is legal. In that case this still routes vault-owned value
    /// out to a custodial sub-account and back through the operator-asserted
    /// `deposit_from_sub_account` (attribution unauthenticated, I-12) when it
    /// could have been joined straight into `vault.balance`. Deliberately left
    /// as one path rather than branching on type equality — a `C == T`
    /// fast-path is a worthwhile follow-up, not something to slip in here.
    fun forward_strategy_reward<T, C>(
        vault: &mut AtomicLiquidityVault<T>,
        recipient: address,
        reward: Coin<C>,
    ): u64 {
        let amount = coin::value(&reward);
        let seq = bump_sequence(vault);
        if (amount == 0) {
            coin::destroy_zero(reward);
        } else {
            transfer::public_transfer(reward, recipient);
        };
        events::emit_strategy_reward_collected_event<C>(
            object::uid_to_inner(&vault.id),
            vault.strategy_kind,
            amount,
            recipient,
            seq,
        );
        amount
    }

    // === Instant Withdraw ===
    //
    // Three variants — one per strategy kind. Each shares a private
    // `do_instant_withdraw_core` helper that handles the burn / fee / cap
    // bookkeeping. The auto-pull-from-strategy step varies per variant.

    /// Computes net payout, advances cap counters, burns shares, and accrues
    /// the instant-withdraw fee. Does NOT perform the collateral transfer —
    /// caller is responsible for ensuring liquidity (idle balance + optional
    /// strategy pull) and then transferring `net_amount` of T.
    /// Returns `net_amount`. Emits `InstantWithdrawnEvent` after caller
    /// completes the transfer (caller passes back via the wrapper variant).
    fun do_instant_withdraw_core<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &TxContext,
    ): (u64, u64, u64) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!vault.paused_withdrawals, EOperationPaused);

        let owner = ctx.sender();
        assert!(!vector::contains(&vault.blacklisted, &owner), EBlacklistedAccount);
        assert!(!vector::contains(&vault.blacklisted, &receiver), EBlacklistedAccount);
        // Reject null receiver: the wrapper variant would abort at
        // `transfer::public_transfer(coin, @0x0)` — cheaper and clearer to
        // fail up-front. Matches the EVM fix at `AtomicLiquidity.sol:1471`.
        assert!(receiver != @0x0, EInvalidReceiver);

        assert!(shares > 0, EZeroAmount);
        assert!(shares >= vault.min_withdrawal_shares, EInsufficientShares);

        let owner_balance = if (table::contains(&vault.shares, owner)) {
            *table::borrow(&vault.shares, owner)
        } else { 0 };
        assert!(owner_balance >= shares, EInsufficientShares);

        // Cumulative cap.
        let new_cumulative = vault.cumulative_instant_withdraw_shares + shares;
        assert!(new_cumulative <= vault.max_instant_withdraw_shares, EInstantWithdrawCapExceeded);

        // Settle time-based fees against OLD totalShares before we burn.
        charge_accrued_platform_fees(vault, clock);

        // One bump per entry function — mirrors EVM AtomicLiquidity.instantWithdraw
        // which calls `_incrementSequence()` immediately after
        // `_chargeAccruedPlatformFees()`. The subsequent InstantWithdrawn emit
        // (and any Sui-only auto-pull StrategyWithdrawn from ensure_liquidity_*)
        // share this seq.
        bump_sequence(vault);

        let gross_amount = math::div(shares, vault.rate.value);
        assert!(gross_amount > 0, EZeroAmount);

        let fee_amount = math::mul(gross_amount, vault.instant_withdraw_fee_percentage);
        let net_amount = gross_amount - fee_amount;

        // Burn user shares + advance cumulative.
        decrement_account_shares(&mut vault.shares, owner, shares);
        vault.total_shares = vault.total_shares - shares;
        vault.cumulative_instant_withdraw_shares = new_cumulative;

        // Accrue the fee (collected later via collect_platform_fee).
        if (fee_amount > 0) vault.fee.accrued = vault.fee.accrued + fee_amount;

        (gross_amount, fee_amount, net_amount)
    }

    /// Emits `InstantWithdrawnEvent` after the wrapper variant has completed
    /// the collateral transfer. Split out so the three variants share one
    /// event-emission path. Reads `vault.sequence_number` — the entry function
    /// bumped once earlier in `do_instant_withdraw_core`, and any interposing
    /// `StrategyWithdrawn` from `ensure_liquidity_*` shares that same seq (EVM
    /// AtomicLiquidity.instantWithdraw bumps once per call).
    fun emit_instant_withdraw<T>(
        vault: &AtomicLiquidityVault<T>,
        owner: address,
        receiver: address,
        shares: u64,
        gross_amount: u64,
        fee_amount: u64,
        net_amount: u64,
    ) {
        events::emit_instant_withdrawn_event<T>(
            object::uid_to_inner(&vault.id),
            owner,
            receiver,
            shares,
            gross_amount,
            fee_amount,
            net_amount,
            vault.cumulative_instant_withdraw_shares,
            vault.total_shares,
            vault.sequence_number,
        );
    }

    /// Variant for vaults with `strategy_kind == STRATEGY_NONE`. Reverts if
    /// idle balance is insufficient — there is no strategy to pull from.
    public fun instant_withdraw<T>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        let owner = ctx.sender();
        assert!(vault.strategy_kind == strategy::strategy_none(), EStrategyMismatch);
        let (gross, fee, net) = do_instant_withdraw_core(vault, config, shares, receiver, clock, ctx);
        assert!(balance::value(&vault.balance) >= net, EInsufficientBalance);
        if (net > 0) {
            let bal = balance::split(&mut vault.balance, net);
            transfer::public_transfer(coin::from_balance(bal, ctx), receiver);
        };
        emit_instant_withdraw(vault, owner, receiver, shares, gross, fee, net);
        net
    }

    /// Variant for Suilend-strategy vaults. Auto-pulls deficit from Suilend
    /// if `vault.balance < net_amount`.
    public fun instant_withdraw_with_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        let owner = ctx.sender();
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        let (gross, fee, net) = do_instant_withdraw_core(vault, config, shares, receiver, clock, ctx);
        ensure_liquidity_suilend<T, P>(vault, market, net, clock, ctx);
        if (net > 0) {
            let bal = balance::split(&mut vault.balance, net);
            transfer::public_transfer(coin::from_balance(bal, ctx), receiver);
        };
        emit_instant_withdraw(vault, owner, receiver, shares, gross, fee, net);
        net
    }

    /// SUI-vault counterpart of `instant_withdraw_with_suilend`. Auto-pull
    /// goes through `ensure_liquidity_suilend_sui`, which threads
    /// `&mut SuiSystemState`. Callable only on a `Vault<SUI>`.
    public fun instant_withdraw_with_suilend_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        shares: u64,
        receiver: address,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        let owner = ctx.sender();
        assert!(vault.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        let (gross, fee, net) = do_instant_withdraw_core(vault, config, shares, receiver, clock, ctx);
        ensure_liquidity_suilend_sui<P>(vault, market, system_state, net, clock, ctx);
        if (net > 0) {
            let bal = balance::split(&mut vault.balance, net);
            transfer::public_transfer(coin::from_balance(bal, ctx), receiver);
        };
        emit_instant_withdraw(vault, owner, receiver, shares, gross, fee, net);
        net
    }

    // === Liquidity Auto-Pull Helpers ===

    /// Pulls the `needed - balance` deficit from Suilend and joins it into
    /// `vault.balance`. No-op if `balance >= needed`.
    fun ensure_liquidity_suilend<T, P>(
        vault: &mut AtomicLiquidityVault<T>,
        market: &mut LendingMarket<P>,
        needed: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        if (needed == 0) return;
        let current = balance::value(&vault.balance);
        if (current >= needed) return;
        let deficit = needed - current;
        let received = strategy::withdraw_from_suilend<P, T>(
            &mut vault.id, market, clock, deficit, ctx,
        );
        let received_amount = balance::value(&received);
        balance::join(&mut vault.balance, received);
        // Shares seq with the calling entry function's main event — mirrors
        // EVM AtomicLiquidity, whose `_ensureLiquidity` is silent (no seq bump,
        // no emit). The Sui-only StrategyWithdrawn is stamped with the entry's
        // sequence so indexers can correlate it to that action.
        events::emit_strategy_withdrawn_event<T>(
            object::uid_to_inner(&vault.id),
            vault.strategy_kind,
            received_amount,
            vault.sequence_number,
        );
    }

    /// SUI-vault counterpart of `ensure_liquidity_suilend`. Threads
    /// `&mut SuiSystemState` into Suilend's request -> unstake -> fulfill path.
    fun ensure_liquidity_suilend_sui<P>(
        vault: &mut AtomicLiquidityVault<SUI>,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        needed: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        if (needed == 0) return;
        let current = balance::value(&vault.balance);
        if (current >= needed) return;
        let deficit = needed - current;
        let received = strategy::withdraw_from_suilend_sui<P>(
            &mut vault.id, market, system_state, clock, deficit, ctx,
        );
        let received_amount = balance::value(&received);
        balance::join(&mut vault.balance, received);
        // Shares seq with the calling entry function's main event — see
        // `ensure_liquidity_suilend`.
        events::emit_strategy_withdrawn_event<SUI>(
            object::uid_to_inner(&vault.id),
            vault.strategy_kind,
            received_amount,
            vault.sequence_number,
        );
    }

    /// Splits exactly `requested` from `bal` and sends it to `receiver`,
    /// aborting with `EInsufficientBalance` if the balance is short by any
    /// amount. Returns the amount paid, which is always `requested`.
    ///
    /// This used to tolerate a bounded shortfall. That tolerance existed for one
    /// reason: AlphaLend's amount ↔ xToken conversion double-floored, so a
    /// drain-to-empty request could come back a unit or two under what the
    /// position held on paper and `balance::split` would panic. It never applied
    /// to the STRATEGY_NONE or Suilend paths, which are never short here, and
    /// those are the only paths left. Keeping it would have left a silent
    /// 1000-base-unit shortfall allowance on a user-facing payout with nothing
    /// that needs it, so delivery is strict.
    ///
    /// The return value is kept rather than collapsed into the caller so the
    /// L-06 slippage assertion below still reads against what was actually
    /// transferred, not the nominal amount — the right shape if a future
    /// strategy ever reintroduces a short-delivery case.
    fun pay_exact<T>(
        bal: &mut Balance<T>,
        requested: u64,
        receiver: address,
        ctx: &mut TxContext,
    ): u64 {
        if (requested == 0) return 0;
        assert!(balance::value(bal) >= requested, EInsufficientBalance);
        let split = balance::split(bal, requested);
        transfer::public_transfer(coin::from_balance(split, ctx), receiver);
        requested
    }

    // === EmberShare Cross-Vault Swap ===
    //
    // Lets users instantly swap an Ember vault's receipt-token holding for
    // this atomic vault's underlying collateral. Three variants — one per
    // strategy kind. The collected receipt tokens are stored as a typed
    // dynamic field on `vault.id` (key: `CollectedEmberSharesKey`), and later
    // redeemed via `redeem_collected_ember_shares`.

    /// Typed dynamic-field key identifying a per-source-vault `Balance<R>` of
    /// collected Ember vault receipt tokens. Wrapping `ID` in a named struct
    /// keeps the dynamic-field namespace separate from any other ID-keyed
    /// fields the vault might use.
    public struct CollectedEmberSharesKey has copy, drop, store {
        source_vault_id: ID,
    }

    /// Read-only preview of the immediate collateral payout for a hypothetical
    /// `swap_ember_shares` call from `owner`. Used by the wrapper variants to
    /// compute `needed` before invoking auto-pull-from-strategy. Returns 0
    /// whenever the real swap would abort — the wrapper's strategy-pull then
    /// skips and the actual swap call surfaces the specific abort code. Reasons
    /// that return 0:
    ///   - source share not configured / not whitelisted;
    ///   - gross below the configured `min_swap_gross` dust floor;
    ///   - post-swap held value would exceed `max_held_value_absolute`;
    ///   - post-swap utilization would exceed `max_utilization_percentage`;
    ///   - misconfigured curve where `fee + holdback > gross`.
    /// Capacity (rolling 24h `max_capacity_percentage`) is intentionally NOT
    /// simulated here — it depends on `now` and produces state (`epoch_started
    /// _at` / `epoch_used_amount`) the read-only view can't advance; the
    /// swap-path re-check will surface a capacity failure cleanly.
    public fun preview_swap_ember_shares<T, R>(
        atomic: &AtomicLiquidityVault<T>,
        source_vault: &Vault<T, R>,
        share_amount: u64,
        owner: address,
    ): u64 {
        let source_id = vault::get_vault_id(source_vault);
        if (!table::contains(&atomic.ember_share_configs, source_id)) return 0;
        let cfg = table::borrow(&atomic.ember_share_configs, source_id);
        if (!cfg.whitelisted) return 0;
        // Mirror the core's source-exit guard (M-02) — a swap the core would
        // reject is not viable, so preview reports 0.
        if (vault::is_withdrawals_paused(source_vault)) return 0;
        // Mirrors the M-02 guard in `do_swap_ember_shares_core`. Without it the
        // preview quotes a swap the core would abort on: if the source has
        // blacklisted the atomic vault's own address, the atomic vault can never
        // redeem the shares it would take on. A quote that cannot be executed is
        // worse than a zero — callers size trades against it.
        if (vault::is_blacklisted(source_vault, object::uid_to_address(&atomic.id))) return 0;

        // Floor to match settlement rounding — `process_request` on the source
        // pays out via `math::div` (floor), so the swap's gross must round the
        // same way. Ceil here would over-report gross by up to one unit per
        // swap and drift utilization / fee / holdback math from what actually
        // settles at redemption time.
        let gross = vault::calculate_amount_from_shares_floor(source_vault, share_amount);
        if (gross == 0) return 0;

        // Dust floor: mirrors the on-chain `EEmberShareSwapAmountTooSmall`
        // abort so the wrapper doesn't pull strategy liquidity for a swap the
        // core will reject.
        if (cfg.min_swap_gross != 0 && gross < cfg.min_swap_gross) return 0;

        // Match the on-chain logic: compute post-swap utilization, look up
        // the multiplier, scale the base fee.
        // Aggregate-then-convert: `gross` stays the payout basis, but the
        // exposure figure that drives caps and the fee tier must convert the
        // combined share position once (L-04).
        let new_held_value = current_held_share_value_in_collateral<T, R>(
            atomic, source_vault, share_amount,
        );

        // Absolute held-value ceiling. Mirrors the on-chain
        // `EEmberShareHeldValueCapExceeded` abort.
        if (cfg.max_held_value_absolute != 0
            && new_held_value > cfg.max_held_value_absolute) return 0;

        let vault_tvl = get_vault_tvl(atomic);
        // Mirrors the core's fail-closed zero-TVL guard.
        if (vault_tvl == 0) return 0;
        let new_utilization = math::div(new_held_value, vault_tvl);

        // Per-share utilization cap. Mirrors the on-chain
        // `EEmberShareUtilizationCapExceeded` abort, including the zero-cap
        // hard stop.
        if (cfg.max_utilization_percentage == 0) return 0;
        if (new_utilization > cfg.max_utilization_percentage) return 0;

        let multiplier = lookup_fee_multiplier(&cfg.fee_multiplier_curve, new_utilization);
        let effective_fee_pct = math::mul(cfg.fee_percentage, multiplier);
        // Mirror the core's strict sub-100% effective-fee guard: a swap that
        // would be rejected there is not viable, so preview reports 0.
        if (effective_fee_pct >= PERCENT_MAX) return 0;

        let fee_waived = vector::contains(&atomic.fee_waived_addresses, &owner);
        let holdback_waived = vector::contains(&atomic.holdback_waived_addresses, &owner);
        let fee = if (fee_waived) 0 else math::mul(gross, effective_fee_pct);
        let holdback = math::mul(gross, cfg.holdback_percentage);
        if (fee + holdback > gross) return 0;  // misconfigured curve — abort-equivalent
        let net = gross - fee - holdback;
        if (holdback_waived) net + holdback else net
    }

    // === EmberShare utilization views ===

    /// Returns the CURRENT (pre-swap) utilization for `source_vault`'s
    /// receipt token. 1e9 = 100%. Computed as `held_collateral_value /
    /// atomic_vault_tvl`. Returns 0 if we hold nothing or TVL is zero.
    public fun get_ember_share_utilization<T, R>(
        atomic: &AtomicLiquidityVault<T>,
        source_vault: &Vault<T, R>,
    ): u64 {
        let held_value = current_held_share_value_in_collateral<T, R>(
            atomic, source_vault, 0,
        );
        if (held_value == 0) return 0;
        let vault_tvl = get_vault_tvl(atomic);
        if (vault_tvl == 0) return 0;
        math::div(held_value, vault_tvl)
    }

    /// Returns the multiplier the curve resolves to at `utilization` for
    /// `share_vault_id`. 1e9 = 1x (no scaling). Returns 1e9 when the
    /// config is missing OR the curve has no matching tier.
    public fun get_ember_share_fee_multiplier_at<T>(
        atomic: &AtomicLiquidityVault<T>,
        share_vault_id: ID,
        utilization: u64,
    ): u64 {
        if (!table::contains(&atomic.ember_share_configs, share_vault_id)) {
            return PERCENT_MAX
        };
        let cfg = table::borrow(&atomic.ember_share_configs, share_vault_id);
        lookup_fee_multiplier(&cfg.fee_multiplier_curve, utilization)
    }

    /// Returns `max_utilization_percentage` for a configured source share,
    /// or 0 if not configured.
    public fun get_ember_share_max_utilization<T>(
        atomic: &AtomicLiquidityVault<T>,
        share_vault_id: ID,
    ): u64 {
        if (!table::contains(&atomic.ember_share_configs, share_vault_id)) return 0;
        table::borrow(&atomic.ember_share_configs, share_vault_id).max_utilization_percentage
    }

    /// Number of tiers in the curve for a configured source share, or 0.
    public fun get_ember_share_fee_multiplier_curve_length<T>(
        atomic: &AtomicLiquidityVault<T>,
        share_vault_id: ID,
    ): u64 {
        if (!table::contains(&atomic.ember_share_configs, share_vault_id)) return 0;
        vector::length(
            &table::borrow(&atomic.ember_share_configs, share_vault_id).fee_multiplier_curve,
        )
    }

    /// Reads tier `index` from the curve, returning `(threshold, multiplier)`.
    /// Aborts if `share_vault_id` not configured or `index` out of bounds.
    public fun get_ember_share_fee_multiplier_tier_at<T>(
        atomic: &AtomicLiquidityVault<T>,
        share_vault_id: ID,
        index: u64,
    ): (u64, u64) {
        let cfg = table::borrow(&atomic.ember_share_configs, share_vault_id);
        let tier = vector::borrow(&cfg.fee_multiplier_curve, index);
        (tier.threshold, tier.multiplier)
    }

    /// Validates, computes amounts, takes the share coin into vault custody,
    /// pays the immediate collateral, accrues fee, and queues the holdback
    /// (if not waived). The wrapper variants ensure liquidity BEFORE invoking
    /// this so the immediate-payout split won't underflow.
    /// Returns `(gross_amount, fee_amount, queued_holdback, net_amount,
    /// actual_paid)`. Callers treat the LAST element as the payout — it is what
    /// `pay_exact` actually transferred. It equals `net_amount`, or
    /// `net_amount + holdback` for a holdback-waived receiver; `pay_exact` pays
    /// in full or aborts, so it is never less.
    /// `seq` is the action sequence the CALLING ENTRY FUNCTION reserved. The
    /// core does not bump: per the codebase-wide convention (and EVM's
    /// `AtomicLiquidity.swapEmberShares`, which does
    /// `_chargeAccruedPlatformFees(); _incrementSequence();` then passes
    /// `sequenceNumber` into the library) an entry function charges fees, bumps
    /// exactly once, and hands the sequence down to shared logic.
    ///
    /// Bumping here instead meant `ensure_liquidity_*` — which the strategy
    /// wrappers must call BEFORE the core, to fund the payout — emitted its
    /// child `StrategyWithdrawnEvent` one sequence behind the parent
    /// `EmberShareSwappedEvent` (I-07). Reserving in the entry makes the
    /// shared-sequence property hold by construction rather than by call order.
    fun do_swap_ember_shares_core<T, R>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        share_coin: Coin<R>,
        receiver: address,
        min_net_out: u64,
        seq: u128,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64, u64, u64, u64) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!atomic.paused_withdrawals, EOperationPaused);

        let owner = ctx.sender();
        assert!(!vector::contains(&atomic.blacklisted, &owner), EBlacklistedAccount);
        assert!(!vector::contains(&atomic.blacklisted, &receiver), EBlacklistedAccount);
        assert!(receiver != @0, EInvalidAccount);

        // Refuse the swap when the source can't be redeemed from. Must be
        // `is_withdrawals_paused` (legacy `paused` bit OR the granular
        // withdrawals flag), not `get_vault_paused` — a withdrawals-only
        // pause leaves the legacy bit false, so the swap would take source
        // shares the atomic vault cannot redeem.
        assert!(!vault::is_withdrawals_paused(source_vault), ESourceVaultWithdrawalsPaused);

        // M-02: the swap takes the user's source shares onto the ATOMIC VAULT's
        // books, so the atomic vault is the account that must later redeem them
        // from `source_vault`. If the source has blacklisted the atomic vault's
        // address, that redemption is refused and the shares are dead weight —
        // the swap would hand out atomic shares against collateral that can
        // never be recovered, and the loss lands on every atomic depositor
        // rather than the swapper.
        //
        // The checks above cover the wrong party for this: `atomic.blacklisted`
        // is the atomic vault's own list, and neither it nor the source's list
        // is consulted for the atomic vault itself.
        assert!(
            !vault::is_blacklisted(source_vault, object::uid_to_address(&atomic.id)),
            EBlacklistedAccount,
        );

        // NOTE: `charge_accrued_platform_fees` runs in the calling entry
        // function, before it reserves `seq`. It must precede the swap because
        // the time-based fee base is `tvl - accrued`, so booking the swap fee
        // first would retroactively shrink the fee base for the whole elapsed
        // window since `last_charged_at`. Charging in the entry also keeps the
        // charge helper's own exception bump ahead of the entry's, so emitted
        // sequences stay non-decreasing within the transaction.

        let share_amount = coin::value(&share_coin);
        assert!(share_amount > 0, EZeroAmount);

        let source_id = vault::get_vault_id(source_vault);
        assert!(
            table::contains(&atomic.ember_share_configs, source_id),
            EEmberShareNotWhitelisted,
        );

        let now = clock::timestamp_ms(clock);
        let source_tvl = vault::get_vault_tvl(source_vault);
        // Floor rounding — see `preview_swap_ember_shares` for the rationale.
        let gross_amount = vault::calculate_amount_from_shares_floor(source_vault, share_amount);
        assert!(gross_amount > 0, EZeroAmount);

        // POST-swap exposure for this source share, used for both the
        // utilization cap and the fee-multiplier lookup. Computed BEFORE the
        // share_coin is joined into custody: `incoming_shares` is folded into
        // the aggregate and the combined share position is converted to
        // collateral ONCE (L-04). Converting the existing and incoming
        // positions separately and summing understated exposure by up to one
        // base unit, because `floor(a/r) + floor(b/r) <= floor((a+b)/r)`.
        // `gross_amount` remains the basis for fee, holdback and payout.
        let new_held_value = current_held_share_value_in_collateral<T, R>(
            atomic, source_vault, share_amount,
        );
        let vault_tvl = get_vault_tvl(atomic);
        // Fail closed. `new_held_value >= gross_amount > 0` here, so a zero
        // TVL has no meaningful utilization; reporting 0 would let every
        // percentage control pass while `total_shares == 0`.
        assert!(vault_tvl > 0, EZeroVaultTVL);
        let new_utilization = math::div(new_held_value, vault_tvl);

        // Consolidated config-mutation block. Runs every config-derived check
        // in one `table::borrow_mut` — three checks share a single borrow to
        // keep the per-swap gas overhead of the new audit-fix checks bounded
        // (the utilization-scenario test walks 7 swaps under a tight per-test
        // gas budget). Order matters: dust floor → capacity → held-value
        // absolute cap → utilization percentage cap.
        let cfg_fee_pct;
        let cfg_holdback_pct;
        let epoch_used_after;
        let fee_multiplier;
        {
            let cfg = table::borrow_mut(&mut atomic.ember_share_configs, source_id);
            assert!(cfg.whitelisted, EEmberShareNotWhitelisted);

            // Dust floor. Reject swaps whose gross is small enough to round
            // the fee to zero while still queueing a near-zero `HoldbackEntry`
            // — such entries bloat `release_users_holdback` gas at any
            // `unwinding_percentage < 100%` (the release path settles only
            // sub-`HOLDBACK_DUST_UNITS` payouts in full, but the floor still
            // cuts the queue-bloat vector at source).
            assert!(
                cfg.min_swap_gross == 0 || gross_amount >= cfg.min_swap_gross,
                EEmberShareSwapAmountTooSmall,
            );

            // Reset the rolling 24h epoch if it has expired (or hasn't started).
            let epoch_used_now = if (cfg.epoch_started_at == 0
                || now >= cfg.epoch_started_at + EMBER_SHARE_EPOCH_DURATION_MS) {
                cfg.epoch_started_at = now;
                cfg.epoch_used_amount = 0;
                0
            } else {
                cfg.epoch_used_amount
            };
            let cap = math::mul(source_tvl, cfg.max_capacity_percentage);
            assert!(epoch_used_now + gross_amount <= cap, EEmberShareCapExceeded);
            cfg.epoch_used_amount = epoch_used_now + gross_amount;

            // Absolute held-value ceiling. Unlike the percentage cap below,
            // this is independent of `vault_tvl`, so it can't be gamed by
            // transiently inflating the atomic vault's TVL
            // (deposit → swap → withdraw) to dilute the utilization ratio.
            assert!(
                cfg.max_held_value_absolute == 0
                    || new_held_value <= cfg.max_held_value_absolute,
                EEmberShareHeldValueCapExceeded,
            );

            // Per-share concentration cap on POST-swap utilization. A cap of
            // 0 is a hard stop, not "unlimited" — floor division can round a
            // small positive exposure down to 0 utilization and slip through.
            assert!(cfg.max_utilization_percentage > 0, EEmberShareUtilizationCapExceeded);
            assert!(
                new_utilization <= cfg.max_utilization_percentage,
                EEmberShareUtilizationCapExceeded,
            );

            // Look up the multiplier from the curve at the POST-swap
            // utilization. Empty curve / no matching tier returns 1e9 (1x).
            fee_multiplier = lookup_fee_multiplier(&cfg.fee_multiplier_curve, new_utilization);

            cfg_fee_pct = cfg.fee_percentage;
            cfg_holdback_pct = cfg.holdback_percentage;
            epoch_used_after = cfg.epoch_used_amount;
        };

        // Effective fee percentage = base * multiplier (in 1e9 fixed-point).
        // multiplier == 1e9 leaves fee unchanged; > 1e9 scales it up.
        let effective_fee_pct = math::mul(cfg_fee_pct, fee_multiplier);
        // Strictly below 100% so the fee alone can never consume the entire
        // gross (a zero-payout swap that still takes the user's input). Holdback
        // may still defer part of the payout, but the immediate fee cannot be
        // the whole gross.
        assert!(effective_fee_pct < PERCENT_MAX, EInvalidPercentage);

        let fee_waived = vector::contains(&atomic.fee_waived_addresses, &owner);
        let holdback_waived = vector::contains(&atomic.holdback_waived_addresses, &owner);
        let fee_amount = if (fee_waived) 0 else math::mul(gross_amount, effective_fee_pct);
        let holdback_amount_raw = math::mul(gross_amount, cfg_holdback_pct);
        // Capped so fee + holdback can't exceed gross — protects against
        // misconfiguration where (base_fee * multiplier) + holdback > 100%.
        let fee_plus_holdback = fee_amount + holdback_amount_raw;
        assert!(fee_plus_holdback <= gross_amount, EInvalidPercentage);
        let net_amount = gross_amount - fee_plus_holdback;

        // Take share_coin into per-source-vault collected balance.
        let key = CollectedEmberSharesKey { source_vault_id: source_id };
        let new_share_bal = coin::into_balance(share_coin);
        if (dynamic_field::exists_with_type<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key)) {
            let existing = dynamic_field::borrow_mut<CollectedEmberSharesKey, Balance<R>>(
                &mut atomic.id,
                key,
            );
            balance::join(existing, new_share_bal);
        } else {
            dynamic_field::add(&mut atomic.id, key, new_share_bal);
        };

        // Pay immediate collateral. If the user is holdback-waived they
        // receive net + the would-be-held portion in one go.
        let immediate_payout = if (holdback_waived) {
            net_amount + holdback_amount_raw
        } else {
            net_amount
        };
        // Slippage guard: the immediate collateral actually transferred to the
        // receiver (net, or net + holdback for a holdback-waived receiver) must
        // meet the caller's minimum, protecting against a utilization-driven fee
        // spike between preview and execution.
        assert!(immediate_payout >= min_net_out, ESlippageToleranceExceeded);
        let queued_holdback = if (holdback_waived) 0 else holdback_amount_raw;

        // Pay the immediate collateral in full; a short balance aborts with
        // `EInsufficientBalance`.
        let actual_paid = pay_exact(
            &mut atomic.balance, immediate_payout, receiver, ctx,
        );
        // L-06: the slippage contract is against what the receiver actually
        // received, not the nominal amount. Redundant today — `pay_exact` pays in
        // full or aborts, so this cannot differ from the check above — and kept
        // as the place the contract is stated, so a future payout path that can
        // deliver short is caught here rather than silently breaking min_net_out.
        assert!(actual_paid >= min_net_out, ESlippageToleranceExceeded);

        if (fee_amount > 0) atomic.fee.accrued = atomic.fee.accrued + fee_amount;

        // `seq` was reserved by the entry function. Reused as the sequence
        // stamp on the queued HoldbackEntry so the holdback, the swap event and
        // any `ensure_liquidity_*` child event all point at the same action.

        // Queue a holdback entry FIFO under the source-vault key.
        if (queued_holdback > 0) {
            ensure_holdback_queue_exists(atomic, source_id, ctx);
            let q = table::borrow_mut(&mut atomic.holdback_queues, source_id);
            queue::enqueue(q, HoldbackEntry {
                share_vault_id: source_id,
                receiver,
                amount: queued_holdback,
                created_at: now,
                sequence_number: seq,
            });
        };

        events::emit_ember_share_swapped_event<T>(
            object::uid_to_inner(&atomic.id),
            source_id,
            owner,
            receiver,
            share_amount,
            gross_amount,
            fee_amount,
            queued_holdback,
            holdback_amount_raw,
            // Waived portion: the whole computed holdback when the receiver is
            // waived, otherwise nothing. `queued_holdback + waived` always
            // reconstructs `holdback_amount_raw`.
            if (holdback_waived) holdback_amount_raw else 0,
            actual_paid,
            epoch_used_after,
            new_utilization,
            fee_multiplier,
            seq,
        );

        (gross_amount, fee_amount, queued_holdback, net_amount, actual_paid)
    }

    /// Returns the collateral-denominated value of the receipt tokens this
    /// vault is exposed to for `source_id`. Pure read — no mutation.
    ///
    /// "Exposed to" combines two pools, both denominated in source-vault
    /// receipt shares and converted to collateral at the source's current
    /// rate:
    ///   1. The receipt-token balance still custodied here (the
    ///      `CollectedEmberSharesKey` dynamic field), and
    ///   2. shares currently queued in the source vault's withdrawal queue
    ///      under the atomic vault's address as `owner` (queued by
    ///      `redeem_collected_ember_shares`). These have left the dynamic
    ///      field but the atomic vault still bears the source-side exposure
    ///      until either the request is processed (collateral arrives, claimed
    ///      via `claim_received_collateral`) or skipped (shares return as
    ///      `Coin<R>`, re-ingested via `claim_returned_ember_shares`).
    ///
    /// Including (2) is what keeps the utilization view consistent across the
    /// in-flight window: without it, `redeem_collected_ember_shares` would
    /// instantly free up swap capacity that the atomic vault hasn't actually
    /// settled out of yet, letting a new swap push real exposure above the
    /// configured `max_utilization_percentage`.
    /// `incoming_shares` are added to the aggregate BEFORE the single
    /// share->collateral conversion. Converting the existing position and the
    /// incoming position separately and summing the two results understates
    /// exposure by up to one collateral base unit, because
    /// `floor(a/r) + floor(b/r) <= floor((a+b)/r)` (L-04). Pass 0 for a pure
    /// read of the current position.
    fun current_held_share_value_in_collateral<T, R>(
        atomic: &AtomicLiquidityVault<T>,
        source_vault: &Vault<T, R>,
        incoming_shares: u64,
    ): u64 {
        // Derived, not passed in — a caller-supplied id could disagree with
        // `source_vault` and read another source's custody/pending state.
        let source_id = vault::get_vault_id(source_vault);
        let key = CollectedEmberSharesKey { source_vault_id: source_id };
        let custodied_shares = if (dynamic_field::exists_with_type<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key)) {
            balance::value(
                dynamic_field::borrow<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key),
            )
        } else { 0 };

        // Only consult the source vault's per-account pending tracking for a
        // source this vault has actually redeemed at — the only sources that can
        // have pending shares queued under the atomic vault's address. Sources
        // never redeemed at (the common case, e.g. every source in a
        // redemption-free vault) skip the cross-module call entirely. The
        // in-struct `VecSet` membership check avoids the per-source dynamic-field
        // cost that would blow the scenario-test gas budget.
        let pending_shares = if (!vec_set::is_empty(&atomic.redemption_active_sources)
            && vec_set::contains(&atomic.redemption_active_sources, &source_id)) {
            let atomic_addr = object::uid_to_address(&atomic.id);
            vault::get_account_total_pending_withdrawal_shares<T, R>(
                source_vault, atomic_addr,
            )
        } else { 0 };

        let total_shares = custodied_shares + pending_shares + incoming_shares;
        if (total_shares == 0) return 0;
        // Floor rounding — utilization is compared against real settlement,
        // where the source vault pays via `math::div` (floor). Ceiling would
        // over-estimate concentration by up to one unit per swap and drift
        // from the value actually held.
        vault::calculate_amount_from_shares_floor(source_vault, total_shares)
    }

    fun ensure_holdback_queue_exists<T>(
        atomic: &mut AtomicLiquidityVault<T>,
        source_id: ID,
        ctx: &mut TxContext,
    ) {
        if (!table::contains(&atomic.holdback_queues, source_id)) {
            table::add(&mut atomic.holdback_queues, source_id, queue::new<HoldbackEntry>(ctx));
        }
    }

    /// Variant for vaults with `strategy_kind == STRATEGY_NONE`. Reverts if
    /// idle balance can't cover the immediate payout.
    ///
    /// Returns the immediate collateral actually transferred to `receiver` —
    /// `net`, or `net + holdback` for a holdback-waived receiver — matching
    /// `preview_swap_ember_shares`. Aborts `ESlippageToleranceExceeded` if that
    /// amount is below `min_net_out` (pass 0 to disable the guard).
    public fun swap_ember_shares<T, R>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        share_coin: Coin<R>,
        receiver: address,
        min_net_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        assert!(atomic.strategy_kind == strategy::strategy_none(), EStrategyMismatch);
        // Entry function: charge fees, then reserve this action's single
        // sequence, BEFORE any `ensure_liquidity_*` child event is emitted.
        charge_accrued_platform_fees(atomic, clock);
        let seq = bump_sequence(atomic);
        let (_g, _f, _h, _net, payout) = do_swap_ember_shares_core<T, R>(
            atomic, config, source_vault, share_coin, receiver, min_net_out, seq, clock, ctx,
        );
        payout
    }

    /// Variant for Suilend-strategy vaults. Auto-pulls deficit from Suilend.
    /// Returns the immediate collateral transferred; see `swap_ember_shares`
    /// for the `min_net_out` slippage guard and return semantics.
    public fun swap_ember_shares_with_suilend<T, R, P>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        market: &mut LendingMarket<P>,
        share_coin: Coin<R>,
        receiver: address,
        min_net_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        assert!(atomic.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        let owner = ctx.sender();
        let needed = preview_swap_ember_shares<T, R>(
            atomic, source_vault, coin::value(&share_coin), owner,
        );
        // Entry function: charge fees, then reserve this action's single
        // sequence, BEFORE any `ensure_liquidity_*` child event is emitted.
        charge_accrued_platform_fees(atomic, clock);
        let seq = bump_sequence(atomic);
        ensure_liquidity_suilend<T, P>(atomic, market, needed, clock, ctx);
        let (_g, _f, _h, _net, payout) = do_swap_ember_shares_core<T, R>(
            atomic, config, source_vault, share_coin, receiver, min_net_out, seq, clock, ctx,
        );
        payout
    }

    /// SUI-vault counterpart of `swap_ember_shares_with_suilend`. Auto-pull
    /// goes through `ensure_liquidity_suilend_sui`. Callable only on a
    /// `Vault<SUI>`.
    public fun swap_ember_shares_with_suilend_sui<R, P>(
        atomic: &mut AtomicLiquidityVault<SUI>,
        config: &ProtocolConfig,
        source_vault: &Vault<SUI, R>,
        market: &mut LendingMarket<P>,
        system_state: &mut SuiSystemState,
        share_coin: Coin<R>,
        receiver: address,
        min_net_out: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): u64 {
        assert!(atomic.strategy_kind == strategy::strategy_suilend(), EStrategyMismatch);
        let owner = ctx.sender();
        let needed = preview_swap_ember_shares<SUI, R>(
            atomic, source_vault, coin::value(&share_coin), owner,
        );
        // Entry function: charge fees, then reserve this action's single
        // sequence, BEFORE any `ensure_liquidity_*` child event is emitted.
        charge_accrued_platform_fees(atomic, clock);
        let seq = bump_sequence(atomic);
        ensure_liquidity_suilend_sui<P>(atomic, market, system_state, needed, clock, ctx);
        let (_g, _f, _h, _net, payout) = do_swap_ember_shares_core<SUI, R>(
            atomic, config, source_vault, share_coin, receiver, min_net_out, seq, clock, ctx,
        );
        payout
    }

    // === Holdback Release & Redemption ===

    /// Operator settles a FIFO batch of holdback entries for `share_vault_id`
    /// at `unwinding_percentage` (1e9 = pay full holdback, lower socializes
    /// loss). Visited entries are dequeued unconditionally — re-running on
    /// the same range is a no-op. Operator must have pre-pulled enough
    /// liquidity in the same PTB if vault.balance is insufficient.
    ///
    /// Two intentional semantics worth calling out:
    ///
    ///   * `unwinding_percentage == 0` is a valid operator tool: pays nothing,
    ///     entries are still dequeued, and the withheld collateral stays in
    ///     `vault.balance` to socialize across the remaining holders. Useful
    ///     when a source share is being written off entirely.
    ///
    ///   * No defer-and-escrow path exists on the failed-transfer branch,
    ///     because `public_transfer` has no code recipient that can revert.
    ///     Every payout either lands or the whole batch aborts before mutating
    ///     the queue head — no "delivered but bounced" state to escrow.
    ///
    ///     NOT true for a regulated `T`: `sui::deny_list` aborts the transfer
    ///     and wedges the head (M-03, deferred; interim fix is the skip below).
    public fun release_users_holdback<T>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        share_vault_id: ID,
        unwinding_percentage: u64,
        max_entries: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ): (u64, u64) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!atomic.paused_privileged_operations, EOperationPaused);
        assert_operator(atomic, ctx);
        assert!(unwinding_percentage <= PERCENT_MAX, EInvalidPercentage);
        assert!(max_entries > 0, EZeroAmount);

        // Nothing to release for this share — return before any state change so
        // an empty-queue call has no side effects (no sequence bump, no fee
        // settlement).
        if (!table::contains(&atomic.holdback_queues, share_vault_id)) return (0, 0);

        // Settle accrued platform fees against the OLD totalShares first to
        // keep the time-window math consistent with other operator paths.
        charge_accrued_platform_fees(atomic, clock);

        // Snapshot the blacklist off the &mut borrow so the release loop
        // (which mutably borrows `atomic.holdback_queues` and `atomic.balance`)
        // can consult it without borrow-checker conflicts.
        let blacklist_snapshot = atomic.blacklisted;

        let mut payout_receivers: vector<address> = vector::empty();
        let mut payout_amounts: vector<u64> = vector::empty();
        let mut total_released = 0u64;
        let mut entries_processed = 0u64;
        let mut entries_skipped = 0u64;
        // Sequence-number range of the entries settled this call (the contiguous
        // FIFO block consumed). Lets consumers mark exactly these entries without
        // relying on the queue index. Stay 0 when nothing is processed.
        let mut released_from_seq = 0u128;
        let mut released_to_seq = 0u128;
        // The queue head after this release — the absolute index the queue now
        // starts at, which is what `HoldbackReleasedEvent.new_queue_start_index`
        // promises (NOT the remaining-entry count `queue::len`, which the two
        // only coincide with on a full drain). See A-3.
        let new_queue_start_index;

        {
            let q = table::borrow_mut(&mut atomic.holdback_queues, share_vault_id);
            let queue_len = queue::len(q);
            let to_process = if (max_entries < queue_len) max_entries else queue_len;
            let mut i = 0;
            while (i < to_process) {
                let entry = queue::dequeue(q);
                if (i == 0) {
                    released_from_seq = entry.sequence_number;
                };
                released_to_seq = entry.sequence_number;
                entries_processed = entries_processed + 1;

                // Skip-on-blacklist: an entry whose recipient is on the
                // vault's blacklist at settle time forfeits its holdback
                // (collateral stays in the vault) and the head advances past
                // it. Mirrors `process_request`'s skip-on-blacklist and gives
                // the operator a resolution path when a recipient can no
                // longer legally receive collateral — without it, one stuck
                // recipient at the head would freeze every later release for
                // this share.
                if (vector::contains(&blacklist_snapshot, &entry.receiver)) {
                    entries_skipped = entries_skipped + 1;
                    i = i + 1;
                    continue
                };

                // `unwinding_percentage == 0` means "pay nothing / socialize the
                // full loss" — honour it exactly, with no dust auto-lift below.
                let mut payout = if (unwinding_percentage == 0) {
                    0
                } else {
                    math::mul(entry.amount, unwinding_percentage)
                };
                // Dust auto-lift, bounded by an ABSOLUTE amount. A genuine
                // sub-precision fragment (the `amount == 1` entries the swap path
                // can seed from tiny share fractions) whose haircut floors to
                // zero is paid in full rather than silently wiped. The absolute
                // `HOLDBACK_DUST_UNITS` bound is what keeps this from inverting
                // the operator's intent: a larger entry whose payout merely
                // rounds down at a low `unwinding_percentage` (e.g. 999 at
                // 0.001%) is paid zero, not in full. The head is dequeued
                // unconditionally either way, so a zero payout never stalls the
                // queue.
                if (unwinding_percentage != 0
                    && payout == 0
                    && entry.amount > 0
                    && entry.amount <= HOLDBACK_DUST_UNITS) {
                    payout = entry.amount;
                };

                if (payout > 0) {
                    vector::push_back(&mut payout_receivers, entry.receiver);
                    vector::push_back(&mut payout_amounts, payout);
                    total_released = total_released + payout;
                };
                i = i + 1;
            };
            new_queue_start_index = queue::head(q);
        };

        assert!(balance::value(&atomic.balance) >= total_released, EInsufficientBalance);

        let n = vector::length(&payout_receivers);
        let mut j = 0;
        while (j < n) {
            let amount = *vector::borrow(&payout_amounts, j);
            let bal = balance::split(&mut atomic.balance, amount);
            transfer::public_transfer(
                coin::from_balance(bal, ctx),
                *vector::borrow(&payout_receivers, j),
            );
            j = j + 1;
        };

        // Bump for HoldbackReleased. Distinct from any bump the charge helper
        // may have made for its own emit — EVM per-event semantics.
        let seq = bump_sequence(atomic);

        events::emit_holdback_released_event(
            object::uid_to_inner(&atomic.id),
            share_vault_id,
            unwinding_percentage,
            entries_processed,
            entries_skipped,
            total_released,
            new_queue_start_index,
            released_from_seq,
            released_to_seq,
            seq,
        );

        (entries_processed, total_released)
    }

    /// Operator submits `amount` of collected source-vault shares (collected
    /// via prior `swap_ember_shares` calls) into the source vault's normal
    /// redemption queue. The collateral flows back to this atomic vault's
    /// address as a TTO once the source operator processes the request, and
    /// must be ingested via `claim_received_collateral`.
    ///
    /// The atomic vault's address is used for BOTH `owner` and `receiver` on
    /// the resulting source-vault `WithdrawalRequest` — via
    /// `vault::redeem_shares_for_owner` rather than the public
    /// `vault::redeem_shares` (which would set `owner = ctx.sender()` i.e. the
    /// operator). This keeps the source vault's pending-share accounting
    /// attributed to the atomic vault itself, so:
    ///   - `current_held_share_value_in_collateral` can include in-flight
    ///     redemptions in the utilization view,
    ///   - operator rotations don't lose visibility of prior queued shares,
    ///   - skip-returns (cancelled / blacklisted-recipient / zero-amount
    ///     processing) flow back to the atomic vault as a `Coin<R>` TTO
    ///     instead of being deposited into the operator's wallet — the
    ///     operator must re-ingest them via `claim_returned_ember_shares`.
    ///
    /// Pre-conditions on the source vault:
    ///   - the atomic vault's address must not be blacklisted, and
    ///   - to avoid the source's time-based withdrawal fee firing on every
    ///     redemption (the atomic vault never deposited into the source so
    ///     its `last_deposit_ts` is always zero, which triggers the fee), the
    ///     source operator should place the atomic vault's address on the
    ///     source's fee-exempt list.
    public fun redeem_collected_ember_shares<T, R>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &mut Vault<T, R>,
        amount: u64,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!atomic.paused_privileged_operations, EOperationPaused);
        assert_operator(atomic, ctx);
        assert!(amount > 0, EZeroAmount);

        let source_id = vault::get_vault_id(source_vault);
        let key = CollectedEmberSharesKey { source_vault_id: source_id };
        assert!(dynamic_field::exists_with_type<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key), EInvalidRequest);

        let bal = dynamic_field::borrow_mut<CollectedEmberSharesKey, Balance<R>>(
            &mut atomic.id,
            key,
        );
        let held = balance::value(bal);
        assert!(held >= amount, EInsufficientBalance);
        let split_bal = balance::split(bal, amount);
        let remaining = balance::value(bal);

        let atomic_addr = object::uid_to_address(&atomic.id);
        vault::redeem_shares_for_owner<T, R>(
            source_vault,
            config,
            split_bal,
            atomic_addr,
            atomic_addr,
            clock,
        );

        // Mark this source as redemption-active so subsequent
        // `current_held_share_value_in_collateral` calls consult the source
        // vault's per-account pending tracking for it. Guard the insert —
        // `vec_set::insert` aborts on a duplicate and a source can be redeemed
        // at repeatedly. Additive; never removed.
        if (!vec_set::contains(&atomic.redemption_active_sources, &source_id)) {
            vec_set::insert(&mut atomic.redemption_active_sources, source_id);
        };

        let seq = bump_sequence(atomic);
        events::emit_ember_shares_redemption_initiated_event(
            object::uid_to_inner(&atomic.id),
            source_id,
            amount,
            remaining,
            seq,
        );
    }

    /// Operator ingests a TTO `Coin<T>` (typically collateral that flowed
    /// back to the atomic vault's address from a source EmberVault's
    /// redemption queue) into `vault.balance`. Mirrors the
    /// `deposit_from_sub_account` plumbing but uses the `@0` sentinel as
    /// `sub_account` to indicate "external source".
    public fun claim_received_collateral<T>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        token: Receiving<Coin<T>>,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!atomic.paused_privileged_operations, EOperationPaused);
        assert_operator(atomic, ctx);

        let coin = transfer::public_receive(&mut atomic.id, token);
        let amount = coin::value(&coin);
        assert!(amount > 0, EZeroAmount);

        let previous_balance = balance::value(&atomic.balance);
        balance::join(&mut atomic.balance, coin::into_balance(coin));
        let new_balance = balance::value(&atomic.balance);

        let seq = bump_sequence(atomic);
        events::emit_vault_deposit_without_minting_shares_event<T>(
            object::uid_to_inner(&atomic.id),
            @0,
            previous_balance,
            new_balance,
            amount,
            seq,
        );
    }

    /// Operator re-ingests source-vault receipt shares that the source
    /// returned to the atomic vault's address as a TTO `Coin<R>` because a
    /// queued request was skipped (owner/receiver blacklisted, request
    /// cancelled, or computed withdraw amount was zero). Joins the shares
    /// back into the per-source `CollectedEmberSharesKey` dynamic field so
    /// they're available for a subsequent `redeem_collected_ember_shares`
    /// retry. Operator-only.
    ///
    /// Takes the source `Vault<T, R>` (not a bare ID) so the receipt type `R`
    /// is authenticated against the real source vault: `R` can only be the
    /// source's actual receipt type, and the key is derived from its ID. This
    /// prevents a wrong-`R` claim against a never-swapped source from creating
    /// the per-source slot as the wrong `Balance<R'>` and permanently bricking
    /// every later swap for that source (L-3). Mirrors
    /// `redeem_collected_ember_shares`, which already takes the typed source.
    public fun claim_returned_ember_shares<T, R>(
        atomic: &mut AtomicLiquidityVault<T>,
        config: &ProtocolConfig,
        source_vault: &Vault<T, R>,
        token: Receiving<Coin<R>>,
        ctx: &TxContext,
    ) {
        admin::verify_supported_package(config);
        admin::verify_protocol_not_paused(config);
        assert!(!atomic.paused_privileged_operations, EOperationPaused);
        assert_operator(atomic, ctx);

        let source_vault_id = vault::get_vault_id(source_vault);
        let coin = transfer::public_receive(&mut atomic.id, token);
        let amount = coin::value(&coin);
        assert!(amount > 0, EZeroAmount);

        let key = CollectedEmberSharesKey { source_vault_id };
        let returned_balance = coin::into_balance(coin);
        let new_held = if (dynamic_field::exists_with_type<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key)) {
            let existing = dynamic_field::borrow_mut<CollectedEmberSharesKey, Balance<R>>(
                &mut atomic.id, key,
            );
            balance::join(existing, returned_balance);
            balance::value(existing)
        } else {
            let v = balance::value(&returned_balance);
            dynamic_field::add(&mut atomic.id, key, returned_balance);
            v
        };

        let seq = bump_sequence(atomic);
        events::emit_ember_shares_returned_event<R>(
            object::uid_to_inner(&atomic.id),
            source_vault_id,
            amount,
            new_held,
            seq,
        );
    }

    // === Misc Views (specific to atomic vault) ===

    public fun has_ember_share_config<T>(atomic: &AtomicLiquidityVault<T>, source_id: ID): bool {
        table::contains(&atomic.ember_share_configs, source_id)
    }

    public fun get_ember_share_config<T>(
        atomic: &AtomicLiquidityVault<T>,
        source_id: ID,
    ): (bool, u64, u64, u64, u64, u64) {
        let cfg = table::borrow(&atomic.ember_share_configs, source_id);
        (
            cfg.whitelisted,
            cfg.fee_percentage,
            cfg.max_capacity_percentage,
            cfg.holdback_percentage,
            cfg.epoch_started_at,
            cfg.epoch_used_amount,
        )
    }

    /// Returns the anti-abuse / anti-concentration knobs configured on a
    /// whitelisted source share: `(max_util_pct, min_swap_gross,
    /// max_held_value_absolute)`. Any of the three being `0` means the
    /// corresponding gate is disabled (for `max_util_pct`, `0` means "no
    /// swaps allowed at all"; for the other two, `0` means "unbounded").
    public fun get_ember_share_limits<T>(
        atomic: &AtomicLiquidityVault<T>,
        source_id: ID,
    ): (u64, u64, u64) {
        let cfg = table::borrow(&atomic.ember_share_configs, source_id);
        (cfg.max_utilization_percentage, cfg.min_swap_gross, cfg.max_held_value_absolute)
    }

    public fun get_holdback_queue_length<T>(
        atomic: &AtomicLiquidityVault<T>,
        source_id: ID,
    ): u64 {
        if (!table::contains(&atomic.holdback_queues, source_id)) 0
        else queue::len(table::borrow(&atomic.holdback_queues, source_id))
    }

    public fun get_collected_ember_share_balance<T, R>(
        atomic: &AtomicLiquidityVault<T>,
        source_id: ID,
    ): u64 {
        let key = CollectedEmberSharesKey { source_vault_id: source_id };
        if (!dynamic_field::exists_with_type<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key)) 0
        else balance::value(
            dynamic_field::borrow<CollectedEmberSharesKey, Balance<R>>(&atomic.id, key),
        )
    }

    public fun is_fee_waived<T>(atomic: &AtomicLiquidityVault<T>, account: address): bool {
        vector::contains(&atomic.fee_waived_addresses, &account)
    }

    public fun is_holdback_waived<T>(atomic: &AtomicLiquidityVault<T>, account: address): bool {
        vector::contains(&atomic.holdback_waived_addresses, &account)
    }

    // === Test-only helpers ===

    #[test_only]
    public fun test_fund_balance<T>(vault: &mut AtomicLiquidityVault<T>, amount: u64) {
        balance::join(&mut vault.balance, balance::create_for_testing<T>(amount));
    }

    /// Test-only: read the recorded last-deposit timestamp for `account`
    /// (0 if none). Lets tests assert exactly whose anti-JIT clock a deposit
    /// touched.
    #[test_only]
    public fun test_get_last_deposit_ts<T>(vault: &AtomicLiquidityVault<T>, account: address): u64 {
        if (!dynamic_field::exists_with_type<vector<u8>, WithdrawalFee>(&vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD)) return 0;
        let wf = dynamic_field::borrow<vector<u8>, WithdrawalFee>(
            &vault.id, WITHDRAWAL_FEE_DYNAMIC_FIELD,
        );
        if (!table::contains(&wf.last_deposit_ts, account)) return 0;
        *table::borrow(&wf.last_deposit_ts, account)
    }

    /// Test-only: enqueue a `HoldbackEntry` directly onto the FIFO queue for
    /// `source_id`, bypassing the swap path. Lets `release_users_holdback`
    /// tests seed entries of a chosen `amount` / `receiver` without standing up
    /// a full source vault + swap.
    #[test_only]
    public fun test_enqueue_holdback<T>(
        vault: &mut AtomicLiquidityVault<T>,
        source_id: ID,
        receiver: address,
        amount: u64,
        ctx: &mut TxContext,
    ) {
        ensure_holdback_queue_exists(vault, source_id, ctx);
        let q = table::borrow_mut(&mut vault.holdback_queues, source_id);
        queue::enqueue(q, HoldbackEntry {
            share_vault_id: source_id,
            receiver,
            amount,
            created_at: 0,
            sequence_number: 0,
        });
    }

    /// Test-only: the holdback queue's current head index for `source_id`
    /// (0 if no queue). This is the value `HoldbackReleasedEvent
    /// .new_queue_start_index` carries — distinct from the remaining count
    /// `get_holdback_queue_length` on a partial drain.
    #[test_only]
    public fun test_get_holdback_queue_head<T>(vault: &AtomicLiquidityVault<T>, source_id: ID): u64 {
        if (!table::contains(&vault.holdback_queues, source_id)) 0
        else queue::head(table::borrow(&vault.holdback_queues, source_id))
    }

    #[test_only]
    public fun test_set_rate<T>(vault: &mut AtomicLiquidityVault<T>, value: u64) {
        vault.rate.value = value;
    }

    #[test_only]
    public fun test_get_withdrawal_request_sequence(r: &WithdrawalRequest): u128 {
        r.sequence_number
    }

    /// Test-only shortcut for "the source vault processed the redemption
    /// and the collateral arrived at the atomic vault" — drops
    /// `shares_redeemed` of held receipt `R` and credits `usdc_credited`
    /// to the atomic vault's idle balance.
    ///
    /// The real flow (`redeem_collected_ember_shares` →
    /// `source.process_withdrawal_requests` → `claim_received_collateral`)
    /// is exercised by other tests; this helper exists so utilization
    /// scenario tests can simulate the post-settlement state in one tx
    /// instead of three. Without it the integration walk exceeds the
    /// default `sui move test` gas budget.
    #[test_only]
    public fun test_simulate_source_settlement<T, R>(
        vault: &mut AtomicLiquidityVault<T>,
        source_vault_id: ID,
        shares_redeemed: u64,
        usdc_credited: u64,
    ) {
        let key = CollectedEmberSharesKey { source_vault_id };
        let bal: &mut Balance<R> = dynamic_field::borrow_mut(&mut vault.id, key);
        let split = balance::split(bal, shares_redeemed);
        balance::destroy_for_testing(split);
        balance::join(&mut vault.balance, balance::create_for_testing<T>(usdc_credited));
    }
}
