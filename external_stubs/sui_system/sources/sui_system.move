/// Stub of `sui_system::sui_system` — declares only the `SuiSystemState`
/// handle that ember_vaults threads into Suilend's SUI unstake path
/// (`unstake_sui_from_staker`, reached when a reserve has moved physical SUI
/// into its staker). The real
/// type lives in the Sui system framework package at `0x3`; pinning the
/// `sui_system` named address to `0x3` gives this stub the same type identity
/// (`0x3::sui_system::SuiSystemState`) so PTB calls that pass the on-chain
/// `0x5` system-state object type-check here and dispatch to the real package
/// at runtime. Field layout is irrelevant to that dispatch — do NOT publish
/// this stub.
module sui_system::sui_system {

    public struct SuiSystemState has key {
        id: UID,
        version: u64,
    }
}
