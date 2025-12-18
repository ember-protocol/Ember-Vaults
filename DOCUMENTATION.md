# Ember Vaults - Technical Documentation

## Table of Contents
- [Overview](#overview)
- [Architecture](#architecture)
- [Modules](#modules)
- [Core Concepts](#core-concepts)
- [API Reference](#api-reference)
- [Security Features](#security-features)
- [Events System](#events-system)
- [Error Codes](#error-codes)

## Overview

Ember Vaults is a sophisticated DeFi vault system built on the Sui blockchain that enables secure asset management with advanced features including:

- **Single-asset vault support** with generic type parameters for both underlying assets (T) and receipt tokens (R)
- **Rate-based yield management** with configurable rates and automatic fee accrual
- **Withdrawal queue system** for managing withdrawal requests and liquidity
- **Role-based access control** with admin, operator, and sub-account permissions
- **Platform fee collection** with time-based accrual mechanisms
- **Emergency controls** including pause functionality and blacklisting

## Architecture

The system is built using a modular architecture with clear separation of concerns:

```
┌─────────────────┐    ┌─────────────────┐    ┌─────────────────┐
│    Gateway      │    │     Admin       │    │     Events      │
│  (Entry Points) │◄───┤  (Permissions)  │───►│  (Monitoring)   │
└─────────────────┘    └─────────────────┘    └─────────────────┘
         │                       │                       ▲
         ▼                       ▼                       │
┌─────────────────┐    ┌─────────────────┐              │
│      Vault      │    │      Queue      │              │
│  (Core Logic)   │◄───┤   (FIFO Data)   │              │
└─────────────────┘    └─────────────────┘              │
         │                       │                       │
         ▼                       ▼                       │
┌─────────────────┐              │                       │
│      Math       │              │                       │
│  (Calculations) │──────────────┴───────────────────────┘
└─────────────────┘
```

## Modules

### 1. `vault.move` - Core Vault Logic

The main module containing the vault implementation with deposit, withdrawal, and rate management functionality.

**Key Components:**
- `Vault<T, R>` - Main vault struct with dual type parameters
- `WithdrawalRequest` - Queued withdrawal requests
- `PlatformFee` - Fee tracking and accrual

**Primary Functions:**
- `create_vault()` - Initialize new vault instances
- `deposit()` - Add assets and mint receipt tokens
- `request_withdrawal()` - Queue withdrawal requests
- `process_withdrawal()` - Execute withdrawal processing
- `set_vault_rate()` - Update vault yield rates

### 2. `admin.move` - Administrative Controls

Manages protocol-wide configuration and administrative capabilities.

**Key Components:**
- `AdminCap` - Administrative capability object
- `ProtocolConfig` - Global protocol settings and limits

**Primary Functions:**
- `verify_supported_package()` - Version control validation
- `pause_non_admin_operations()` - Emergency pause controls
- Rate limit management (`update_min_rate()`, `update_max_rate()`)

### 3. `gateway.move` - Client Interface

Provides entry functions that external clients can call, acting as the public API layer.

**Entry Functions:**
- Administrative operations (rate updates, pausing)
- Vault operations (creation, deposits, withdrawals)
- Configuration management

### 4. `queue.move` - FIFO Queue Implementation

Generic FIFO queue implementation used for withdrawal request management.

**Key Features:**
- Generic type support: `Queue<T>`
- FIFO operations: `enqueue()`, `dequeue()`, `peek()`
- Empty queue validation

### 5. `math.move` - Mathematical Utilities

Provides safe mathematical operations with overflow protection.

**Functions:**
- `mul()` - Fixed-point multiplication with BASE=1,000,000,000
- `div()` - Fixed-point division with zero-check
- `diff_abs()` - Absolute difference calculation
- `percent_change_from()` - Percentage difference calculation

### 6. `events.move` - Event Definitions

Comprehensive event system for monitoring and analytics.

**Event Categories:**
- Administrative events (rate changes, pausing)
- Vault lifecycle events (creation, updates)
- User action events (deposits, withdrawals)

## Core Concepts

### Vault Structure

```move
public struct Vault<phantom T, phantom R> has key {
    id: UID,                           // Unique identifier
    name: String,                      // Human-readable name
    admin: address,                    // Administrative address
    operator: address,                 // Operational address
    blacklisted: vector<address>,      // Blocked addresses
    paused: bool,                      // Emergency pause state
    pending_withdrawals: Queue<WithdrawalRequest>, // Withdrawal queue
    pending_account_withdrawal_shares: Table<address,u64>, // Per-account pending
    sub_accounts: vector<address>,     // Authorized sub-accounts
    rate: u64,                         // Current yield rate
    fee_percentage: u64,               // Platform fee rate
    max_rate_change_per_update: u64,   // Rate change limits
    balance: Balance<T>,               // Asset balance
    fee: PlatformFee,                  // Fee tracking
    min_withdrawal_shares: u64,        // Minimum withdrawal amount
    receipt_token_treasury_cap: TreasuryCap<R>, // Receipt token control
    sequence_number: u128              // Operation counter
}
```

### Type Parameters

- **T**: The underlying asset type (e.g., USDC, SUI)
- **R**: The receipt token type representing vault shares

### Role-Based Access Control

1. **Protocol Admin** (`AdminCap`):
   - Create new vaults
   - Modify protocol-wide settings
   - Emergency pause functionality

2. **Vault Admin**:
   - Manage vault-specific settings
   - Control operator assignments
   - Manage sub-accounts

3. **Vault Operator**:
   - Execute deposits and withdrawals
   - Update vault rates (within limits)
   - Process withdrawal queues

4. **Sub-accounts**:
   - Authorized addresses for fund transfers
   - Restricted operational access

### Withdrawal Queue System

Withdrawals are processed through a FIFO queue mechanism:

1. **Request Phase**: Users submit withdrawal requests with share amounts
2. **Queue Phase**: Requests are queued with timestamps and sequence numbers
3. **Processing Phase**: Operators process requests based on vault liquidity

### Rate Management

Vault rates determine yield accrual and are subject to:
- Global min/max limits set in `ProtocolConfig`
- Per-vault maximum change limits
- Time-based fee accrual calculations

## API Reference

### Administrative Functions

```move
// Create new vault
public fun create_vault<T,R>(
    cap: &AdminCap,
    config: &ProtocolConfig,
    treasury_cap: TreasuryCap<R>,
    name: String,
    admin: address,
    operator: address,
    max_rate_change_per_update: u64,
    fee_percentage: u64,
    min_withdrawal_shares: u64,
    sub_accounts: vector<address>,
    ctx: &mut TxContext
): Vault<T,R>

// Update protocol configuration
public fun update_min_rate(cap: &AdminCap, config: &mut ProtocolConfig, min_rate: u64)
public fun update_max_rate(cap: &AdminCap, config: &mut ProtocolConfig, max_rate: u64)
public fun pause_non_admin_operations(cap: &AdminCap, config: &mut ProtocolConfig, status: bool)
```

### Vault Operations

```move
// Deposit assets and receive shares
public fun deposit<T, R>(
    vault: &mut Vault<T, R>,
    config: &ProtocolConfig,
    assets: Coin<T>,
    clock: &Clock,
    ctx: &mut TxContext
): Coin<R>

// Request withdrawal (queued)
public fun request_withdrawal<T, R>(
    vault: &mut Vault<T, R>,
    config: &ProtocolConfig,
    shares: Coin<R>,
    receiver: address,
    clock: &Clock,
    ctx: &mut TxContext
)

// Process withdrawal queue
public fun process_withdrawal<T, R>(
    vault: &mut Vault<T, R>,
    config: &ProtocolConfig,
    receiver: address,
    ctx: &TxContext
): Coin<T>
```

### Rate Management

```move
// Update vault rate
public fun set_vault_rate<T, R>(
    vault: &mut Vault<T, R>,
    config: &ProtocolConfig,
    new_rate: u64,
    clock: &Clock,
    ctx: &TxContext
)

// Charge platform fees
public fun charge_platform_fee<T, R>(
    vault: &mut Vault<T, R>,
    config: &ProtocolConfig,
    clock: &Clock,
    ctx: &mut TxContext
): Balance<T>
```

## Security Features

### Access Control
- Capability-based permissions prevent unauthorized access
- Role separation between admin, operator, and users
- Blacklist functionality for blocking malicious addresses

### Rate Limiting
- Maximum rate change per update prevents manipulation
- Global min/max rate bounds from protocol configuration
- Time-based fee accrual prevents gaming

### Emergency Controls
- Protocol-wide pause functionality
- Vault-specific pause controls
- Version checking prevents outdated package usage

### Input Validation
- Zero amount checks prevent dust attacks
- Balance sufficiency validation
- Rate bounds verification

## Events System

The Ember Vaults system emits comprehensive events for all operations, enabling real-time monitoring, analytics, and external integrations. Events are categorized into protocol-level, vault management, and user operation events.

### Event Categories

#### Protocol Administration Events

**PauseNonAdminOperationsEvent**
- **Emitted by**: `admin::pause_non_admin_operations()`
- **Purpose**: Signals when protocol-wide pause status changes
- **Fields**: `status: bool`

**SupportedVersionUpdateEvent**
- **Emitted by**: `admin::increase_supported_package_version()`
- **Purpose**: Tracks protocol version updates for compatibility
- **Fields**: `old_version: u64, new_version: u64`

**PlatformFeeRecipientUpdateEvent**
- **Emitted by**: `admin::update_platform_fee_recipient()`
- **Purpose**: Records changes to fee collection address
- **Fields**: `previous_recipient: address, new_recipient: address`

**MinRateUpdateEvent**
- **Emitted by**: `admin::update_min_rate()`
- **Purpose**: Tracks minimum rate limit changes
- **Fields**: `previous_min_rate: u64, new_min_rate: u64`

**MaxRateUpdateEvent**
- **Emitted by**: `admin::update_max_rate()`
- **Purpose**: Tracks maximum rate limit changes
- **Fields**: `previous_max_rate: u64, new_max_rate: u64`

**DefaultRateUpdateEvent**
- **Emitted by**: `admin::update_default_rate()`
- **Purpose**: Records default rate changes for new vaults
- **Fields**: `previous_default_rate: u64, new_default_rate: u64`

**MaxAllowedFeePercentageUpdatedEvent**
- **Emitted by**: `admin::update_max_fee_percentage()`
- **Purpose**: Tracks maximum allowed fee percentage changes
- **Fields**: `previous_max_fee_percentage: u64, new_max_fee_percentage: u64`

#### Vault Management Events

**VaultCreatedEvent<T, R>**
- **Emitted by**: `vault::create_vault()`
- **Purpose**: Records new vault creation with initial configuration
- **Fields**: `vault_id: ID, name: String, admin: address, operator: address, sub_accounts: vector<address>`

**VaultRateUpdatedEvent**
- **Emitted by**: `vault::set_vault_rate()`
- **Purpose**: Tracks yield rate changes for analytics and compliance
- **Fields**: `vault_id: ID, previous_rate: u64, new_rate: u64, sequence_number: u128`

**VaultAdminChangedEvent**
- **Emitted by**: `vault::change_vault_admin()`
- **Purpose**: Records administrative control transfers
- **Fields**: `vault_id: ID, previous_admin: address, new_admin: address, sequence_number: u128`

**VaultOperatorChangedEvent**
- **Emitted by**: `vault::change_vault_operator()`
- **Purpose**: Tracks operational control changes
- **Fields**: `vault_id: ID, previous_operator: address, new_operator: address, sequence_number: u128`

**VaultFeePercentageUpdatedEvent**
- **Emitted by**: `vault::update_vault_fee_percentage()`
- **Purpose**: Records fee structure changes
- **Fields**: `vault_id: ID, previous_fee_percentage: u64, new_fee_percentage: u64, sequence_number: u128`

**VaultPausedStatusUpdatedEvent**
- **Emitted by**: `vault::set_vault_paused_status()`
- **Purpose**: Signals vault pause/unpause for emergency controls
- **Fields**: `vault_id: ID, status: bool, sequence_number: u128`

**VaultSubAccountUpdatedEvent**
- **Emitted by**: `vault::set_sub_account()`
- **Purpose**: Tracks changes to authorized sub-accounts
- **Fields**: `vault_id: ID, previous_sub_accounts: vector<address>, new_sub_accounts: vector<address>, account: address, status: bool, sequence_number: u128`

**VaultBlacklistedAccountUpdatedEvent**
- **Emitted by**: `vault::blacklist_account()`, `vault::unblacklist_account()`
- **Purpose**: Records account blacklist changes for compliance
- **Fields**: `vault_id: ID, previous_blacklisted: vector<address>, new_blacklisted: vector<address>, account: address, status: bool, sequence_number: u128`

**MinWithdrawalSharesUpdatedEvent**
- **Emitted by**: `vault::update_vault_min_withdrawal_shares()`
- **Purpose**: Tracks minimum withdrawal threshold changes
- **Fields**: `vault_id: ID, previous_min_withdrawal_shares: u64, new_min_withdrawal_shares: u64, sequence_number: u128`

#### User Operation Events

**VaultDepositEvent<T>**
- **Emitted by**: `vault::deposit()`, `vault::mint()`
- **Purpose**: Records user deposits and share minting for accounting
- **Fields**: `vault_id: ID, owner: address, total_amount: u64, shares_minted: u64, previous_balance: u64, current_balance: u64, total_shares: u64, sequence_number: u128`

**RequestRedeemedEvent<T>**
- **Emitted by**: `vault::request_withdrawal()`
- **Purpose**: Records withdrawal requests submitted to queue
- **Fields**: `vault_id: ID, owner: address, receiver: address, shares: u64, timestamp: u64, total_shares_in_circulation: u64, total_shares_pending_to_burn: u64, sequence_number: u128`

**RequestProcessedEvent<T>**
- **Emitted by**: `vault::process_withdrawal()`
- **Purpose**: Records individual withdrawal processing from queue
- **Fields**: `vault_id: ID, owner: address, receiver: address, shares: u64, withdraw_amount: u64, request_timestamp: u64, processed_timestamp: u64, skipped: bool, sequence_number: u128`

**ProcessRequestsSummaryEvent**
- **Emitted by**: `vault::process_withdrawal()` (batch operations)
- **Purpose**: Provides summary of batch withdrawal processing
- **Fields**: `vault_id: ID, total_request_processed: u64, requests_skipped: u64, total_shares_burnt: u64, total_amount_withdrawn: u64, sequence_number: u128`

#### Operator Operation Events

**VaultWithdrawalWithoutRedeemingSharesEvent<T>**
- **Emitted by**: `vault::withdraw_from_vault()`
- **Purpose**: Records operator withdrawals for external strategies
- **Fields**: `vault_id: ID, sub_account: address, previous_balance: u64, new_balance: u64, amount: u64, sequence_number: u128`

**VaultDepositWithoutMintingSharesEvent<T>**
- **Emitted by**: `vault::deposit_to_vault()`
- **Purpose**: Records operator deposits from external sources
- **Fields**: `vault_id: ID, sub_account: address, previous_balance: u64, new_balance: u64, amount: u64, sequence_number: u128`

**VaultPlatformFeeChargedEvent**
- **Emitted by**: `vault::charge_platform_fee()`
- **Purpose**: Records fee accrual calculations
- **Fields**: `vault_id: ID, fee_amount: u64, total_fee_accrued: u64, last_charged_at: u64, sequence_number: u128`

**ProtocolFeeCollectedEvent<T>**
- **Emitted by**: `vault::charge_platform_fee()` (when collecting)
- **Purpose**: Records actual fee collection and transfer
- **Fields**: `vault_id: ID, collected_fee: u64, current_vault_balance: u64, recipient: address, sequence_number: u128`

### Event Monitoring Patterns

#### Real-time Vault Analytics

```typescript
// Monitor all vault deposit events
const depositFilter = {
    MoveEventType: `${PACKAGE_ID}::events::VaultDepositEvent`
};

suiClient.subscribeEvent({
    filter: depositFilter,
    onMessage: (event) => {
        const { vault_id, owner, total_amount, shares_minted } = event.parsedJson;
        // Update analytics dashboard
        updateVaultMetrics(vault_id, {
            totalDeposits: total_amount,
            activeUsers: owner,
            sharesMinted: shares_minted
        });
    }
});
```

#### Withdrawal Queue Monitoring

```typescript
// Track withdrawal request processing
const withdrawalEvents = [
    `${PACKAGE_ID}::events::RequestRedeemedEvent`,
    `${PACKAGE_ID}::events::RequestProcessedEvent`
];

withdrawalEvents.forEach(eventType => {
    suiClient.subscribeEvent({
        filter: { MoveEventType: eventType },
        onMessage: (event) => {
            if (eventType.includes('Redeemed')) {
                // New withdrawal request
                addToWithdrawalQueue(event.parsedJson);
            } else {
                // Withdrawal processed
                removeFromWithdrawalQueue(event.parsedJson);
            }
        }
    });
});
```

#### Risk Management Alerts

```typescript
// Monitor for emergency events
const riskEvents = [
    `${PACKAGE_ID}::events::VaultPausedStatusUpdatedEvent`,
    `${PACKAGE_ID}::events::VaultBlacklistedAccountUpdatedEvent`,
    `${PACKAGE_ID}::events::PauseNonAdminOperationsEvent`
];

riskEvents.forEach(eventType => {
    suiClient.subscribeEvent({
        filter: { MoveEventType: eventType },
        onMessage: (event) => {
            // Send immediate alerts to administrators
            sendRiskAlert({
                type: eventType,
                data: event.parsedJson,
                timestamp: event.timestampMs
            });
        }
    });
});
```

#### Fee Collection Tracking

```typescript
// Monitor fee accrual and collection
suiClient.subscribeEvent({
    filter: { MoveEventType: `${PACKAGE_ID}::events::ProtocolFeeCollectedEvent` },
    onMessage: (event) => {
        const { vault_id, collected_fee, recipient } = event.parsedJson;
        // Update fee collection records
        recordFeeCollection({
            vault: vault_id,
            amount: collected_fee,
            recipient: recipient,
            timestamp: event.timestampMs
        });
    }
});
```

### Event Sequence Numbers

All vault-related events include a `sequence_number` field that provides:
- **Ordering**: Events can be ordered chronologically within a vault
- **Completeness**: Missing sequence numbers indicate missed events
- **Replay**: Events can be replayed in order for state reconstruction

### Event-Driven Architecture Benefits

1. **Real-time Monitoring**: Track vault performance and user activity
2. **Compliance**: Audit trail for all operations and state changes
3. **Analytics**: Historical data for yield optimization and risk assessment
4. **Integration**: External systems can react to vault state changes
5. **Debugging**: Comprehensive event log for troubleshooting

### Error Codes

**Admin Module (1000-1999)**
- `1000`: Unsupported package version
- `1001`: Package already supported
- `1002`: Invalid recipient
- `1003`: Invalid rate
- `1004`: Invalid fee percentage
- `1005`: Protocol paused

**Vault Module (2000-2999)**
- `2000`: Invalid permission
- `2001`: Invalid account
- `2002`: Invalid rate
- `2003`: Invalid fee percentage
- `2004`: Zero amount
- `2005`: Invalid status
- `2006`: Vault paused
- `2007`: Insufficient balance
- `2008`: Blacklisted account
- `2009`: Insufficient shares
- `2010`: Invalid interval
- `2011`: Invalid amount

### Constants

- `ONE_DAY_MS`: 86,400,000 (24 hours in milliseconds)
- `BASE`: 1,000,000,000 (Fixed-point arithmetic base)
- `VERSION`: 1 (Current protocol version)

