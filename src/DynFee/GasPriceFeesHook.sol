// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";
import {LPFeeLibrary} from "v4-core/libraries/LPFeeLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/types/BeforeSwapDelta.sol";

// Tutorial: https://uniswap.atrium.academy/courses/uniswap-hook-incubator/dynamic-fees-gas-price-fee/
// We will design a hook that keeps track of the moving average gas price over time onchain.
// When gas price is roughly equal to the average, we will charge a certain amount of fees.
// If gas price is over 10% higher than the average, we will charge lower fees.
// If gas price is at least 10% lower than the average, we will charge higher fees.

// Our hook contract basically then just needs to do two things:
// Keep track of the moving average gas price
// For each swap, dynamically adjust the swap fees being charged

// The fees charged on each swap are represented by the lpFee property.

contract GasPriceFeesHook is BaseHook {
    using LPFeeLibrary for uint24;

    // Keeping track of the moving average gas price
    uint128 public movingAverageGasPrice;
    // How many times has the moving average been updated?
    // Needed as the denominator to update it the next time based on the moving average formula
    uint104 public movingAverageGasPriceCount;

    // The default base fees we will charge
    uint24 public constant BASE_FEE = 5000; // denominated in pips (one-hundredth bps) 0.5%

    error MustUseDynamicFee();

    // Initialize BaseHook parent contract in the constructor
    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {
        updateMovingAverage();
    }

    // Required override function for BaseHook to let the PoolManager know which hooks are implemented
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // We enable three hook functions here - beforeInitialize, beforeSwap, and afterSwap.
    // Verify the pool has dynamic fee enabled, else revert!
    function beforeInitialize(address, PoolKey calldata key, uint160) external pure override returns (bytes4) {
        // `.isDynamicFee()` function comes from using
        // the `SwapFeeLibrary` for `uint24`
        if (!key.fee.isDynamicFee()) revert MustUseDynamicFee();
        return this.beforeInitialize.selector;
    }

    // We charge different fees for each swap depending on gas price
    // We will return an override fee inside beforeSwap - so the fee has been updated before the swap is executed
    // returns (bytes4, BeforeSwapDelta, uint24)
    // bytes4: The function selector for beforeSwap, signaling successful execution.
    // BeforeSwapDelta: Adjustments to the pool’s token balances before the swap. Here, no changes are applied (ZERO_DELTA).
    // uint24: The dynamic fee for the swap, encoded with a special flag.
    function beforeSwap(address, PoolKey calldata key, IPoolManager.SwapParams calldata, bytes calldata)
        external
        override
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        uint24 fee = getFee();
        // poolManager.updateDynamicLPFee(key, fee);
        // LPFeeLibrary.OVERRIDE_FEE_FLAG is a constant defined in LPFeeLibrary.
        // It is a special bitmask added to the fee value to indicate that this fee overrides the default fee.
        // The bitwise OR operator (|) combines the fee with the flag, ensuring that this
        // dynamic fee is recognized by the Pool Manager as an override.
        // Example:
        // If fee = 5000 (0.5%) and OVERRIDE_FEE_FLAG = 1 << 23 (highest bit in uint24), the feeWithFlag becomes 5000 | OVERRIDE_FEE_FLAG.

        uint24 feeWithFlag = fee | LPFeeLibrary.OVERRIDE_FEE_FLAG;
        return (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, feeWithFlag);
    }

    // IMPORTANT - for more accurate tracking, you ideally want to enable
    // every single hook function and track gas prices the most amount of times you can.
    // But for our simple example showcase - this is good enough to test out our logic.

    function afterSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, BalanceDelta, bytes calldata)
        external
        override
        returns (bytes4, int128)
    {
        updateMovingAverage();
        return (this.afterSwap.selector, 0);
    }

    function getFee() internal view returns (uint24) {
        uint128 gasPrice = uint128(tx.gasprice);

        // if gasPrice > movingAverageGasPrice * 1.1, then half the fees
        if (gasPrice > (movingAverageGasPrice * 11) / 10) {
            return BASE_FEE / 2;
        }

        // if gasPrice < movingAverageGasPrice * 0.9, then double the fees
        if (gasPrice < (movingAverageGasPrice * 9) / 10) {
            return BASE_FEE * 2;
        }

        return BASE_FEE;
    }

    // Update our moving average gas price
    function updateMovingAverage() internal {
        uint128 gasPrice = uint128(tx.gasprice);

        // New Average = ((Old Average * # of Txns Tracked) + Current Gas Price) / (# of Txns Tracked + 1)
        movingAverageGasPrice =
            ((movingAverageGasPrice * movingAverageGasPriceCount) + gasPrice) / (movingAverageGasPriceCount + 1);

        movingAverageGasPriceCount++;
    }
}
