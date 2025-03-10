// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// This code follows the tutorial atrium acadamy:
// https://uniswap.atrium.academy/lessons/building-your-first-hook/

// Our goal is to incentivize swappers and liquidity providers.
// This incentivization happens through the hook issuing a second POINTS token when desired actions occur.
// https://github.com/Uniswap/v4-periphery/blob/main/src/base/hooks/BaseHook.sol

// To reliably figure out how much ETH they are spending - the beforeSwap hook doesn't really give us that information.
// The additional BalanceDelta delta value present in afterSwap though,
// that has the exact amounts of how much ETH is being spent for how much TOKEN since at that point it has already done those calculations.

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";

import {CurrencyLibrary, Currency} from "v4-core/types/Currency.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";
import {BalanceDeltaLibrary, BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";

import {Hooks} from "v4-core/libraries/Hooks.sol";

contract PointsHook is BaseHook, ERC20 {
    // Use CurrencyLibrary and BalanceDeltaLibrary
    // to add some helper functions over the Currency and BalanceDelta
    // data types
    using CurrencyLibrary for Currency;
    using BalanceDeltaLibrary for BalanceDelta;

    // Initialize BaseHook and ERC20
    constructor(IPoolManager _manager, string memory _name, string memory _symbol)
        BaseHook(_manager)
        ERC20(_name, _symbol, 18)
    {}

    // Set up hook permissions to return `true`
    // for the two hook functions we are using
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: false,
            beforeAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterAddLiquidity: true,
            afterRemoveLiquidity: false,
            beforeSwap: false,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // Stub implementation of `afterSwap`
    function afterSwap(
        address,
        PoolKey calldata key, // Identifies the pool being interacted with (e.g., its tokens and fee tier).
        IPoolManager.SwapParams calldata swapParams, // Contains swap details,
        BalanceDelta delta, // Tracks changes in token balances as a result of the swap.
        bytes calldata hookData // Encoded data passed to the hook for custom logic or context (e.g., tracking points here).
    ) external override onlyPoolManager returns (bytes4, int128) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        // checks if currency0 is the zero address
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, 0);

        // We only mint points if user is buying TOKEN with ETH
        // Ensures the swap direction is ETH → TOKEN (zeroForOne is true for this).
        // zeroForOne is boolean in Struct swapParams
        if (!swapParams.zeroForOne) return (this.afterSwap.selector, 0);

        // Mint points equal to 20% of the amount of ETH they spent
        // Since its a zeroForOne swap:
        // if amountSpecified < 0:
        //      this is an "exact input for output" swap
        //      amount of ETH they spent is equal to |amountSpecified|
        // if amountSpecified > 0:
        //      this is an "exact output for input" swap
        //      amount of ETH they spent is equal to BalanceDelta.amount0()

        // 2 scenarios:
        // Scenario 1: Exact Input for Output Swap (amountSpecified < 0)
        // User specifies the exact amount of ETH (Token 0) they are spending.
        // delta.amount0 is negative because the pool loses ETH
        // ethSpendAmount = uint256(int256(-delta.amount0())) gives the positive amount of ETH spent.

        // Scenario 2: Exact Output for Input Swap (amountSpecified > 0)
        // User specifies the exact amount of TOKEN (Token 1) they want to receive.
        // The pool calculates how much ETH (Token 0) is required.
        // delta.amount0 is still negative, and the formula works the same way to compute a positive ethSpendAmount.

        // ethSpendAmount will always be positive because:
        // delta.amount0 is negative when the pool’s ETH balance decreases
        uint256 ethSpendAmount = uint256(int256(-delta.amount0()));
        uint256 pointsForSwap = ethSpendAmount / 5;

        // Mint the points
        _assignPoints(hookData, pointsForSwap);

        return (this.afterSwap.selector, 0);
    }

    // Stub implementation for `afterAddLiquidity`
    function afterAddLiquidity(
        address,
        PoolKey calldata key,
        IPoolManager.ModifyLiquidityParams calldata,
        BalanceDelta delta,
        BalanceDelta,
        bytes calldata hookData
    ) external override onlyPoolManager returns (bytes4, BalanceDelta) {
        // If this is not an ETH-TOKEN pool with this hook attached, ignore
        if (!key.currency0.isAddressZero()) return (this.afterSwap.selector, delta);

        // Mint points equivalent to how much ETH they're adding in liquidity
        uint256 pointsForAddingLiquidity = uint256(int256(-delta.amount0()));

        // Mint the points
        _assignPoints(hookData, pointsForAddingLiquidity);

        return (this.afterAddLiquidity.selector, delta);
    }

    function _assignPoints(bytes calldata hookData, uint256 points) internal {
        // If no hookData is passed in, no points will be assigned to anyone
        if (hookData.length == 0) return;

        // Extract user address from hookData
        address user = abi.decode(hookData, (address));

        // If there is hookData but not in the format we're expecting and user address is zero
        // nobody gets any points
        if (user == address(0)) return;

        // Mint points to the user
        _mint(user, points);
    }
}
