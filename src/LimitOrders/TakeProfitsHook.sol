// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

// HOOK TO SET LIMIT ORDERS
// Tutorial: https://uniswap.atrium.academy/courses/uniswap-hook-incubator/liquidity-operator-limit-orders-part-1/
//           https://uniswap.atrium.academy/courses/uniswap-hook-incubator/liquidity-operator-limit-orders-part-2/
// Github: https://github.com/haardikk21/take-profits-hook

// Two types of "take profit" orders possible here:
// 1. Sell some amount of A when price of A goes up further
// 2. Sell some amount of B when the price of B goes up
// So keep track of how the tick value is changing

// To keep things relatively simple, we'll make some assumptions
// and skip over certain cases (which should be resolved in a production-ready hook!!

import {BaseHook} from "v4-periphery/src/base/hooks/BaseHook.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IPoolManager} from "v4-core/interfaces/IPoolManager.sol";
import {Hooks} from "v4-core/libraries/Hooks.sol";

import {PoolId, PoolIdLibrary} from "v4-core/types/PoolId.sol";
import {PoolKey} from "v4-core/types/PoolKey.sol";

import {Currency, CurrencyLibrary} from "v4-core/types/Currency.sol";
import {StateLibrary} from "v4-core/libraries/StateLibrary.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {TickMath} from "v4-core/libraries/TickMath.sol";
import {BalanceDelta} from "v4-core/types/BalanceDelta.sol";

import {FixedPointMathLib} from "solmate/src/utils/FixedPointMathLib.sol";

// We use ERC1155: ERC-1155 is a multi-token standard for Ethereum that allows a single smart contract
// to manage multiple token types, including fungible, non-fungible (NFTs), and semi-fungible toke

contract TakeProfitsHook is BaseHook, ERC1155 {
    // StateLibrary is new here and we haven't seen that before
    // It's used to add helper functions to the PoolManager to read
    // storage values.
    // In this case, we use it for accessing `currentTick` values
    // from the pool manager
    using StateLibrary for IPoolManager;

    // PoolIdLibrary used to convert PoolKeys to IDs
    using PoolIdLibrary for PoolKey;
    // Used to represent Currency types and helper functions like `.isNative()`
    using CurrencyLibrary for Currency;
    // Used for helpful math operations like `mulDiv`
    using FixedPointMathLib for uint256;

    // 1. We need a way to keep track of "last known" ticks for different pools.
    // This is not information that is present directly in the afterSwap hook -
    // since that will only tell us the "new"/current tick at that time.
    // So, we must create a mapping in storage to keep track of last known ticks.

    // 2. Since we are executing a swap inside afterSwap - this itself will
    // trigger another execution of afterSwap internally. This can lead to too much recursion, re-entrancy attacks,
    // and stack too deep errors - so we must be careful not to allow this to happen.

    // 3. Tecognizing that as we fulfill each order, the tick shifts even more -
    // so we cannot simply execute all orders that existed within the original tick shift.

    // Storage: creating a mapping to store last known tick values for different pools
    mapping(PoolId poolId => int24 lastTick) public lastTicks;

    // Create a mapping to store pending orders
    // So we can now use: pendingOrders[poolKey.toId()][tickToSellAt][zeroForOne] = inputTokensAmount
    mapping(PoolId poolId => mapping(int24 tickToSellAt => mapping(bool zeroForOne => uint256 inputAmount))) public
        pendingOrders;

    // Create a mapping to keep track of output token amounts
    mapping(uint256 positionId => uint256 outputClaimable) public claimableOutputTokens;

    // Mapping to keep track of the total supply of claim tokens we have given out
    mapping(uint256 positionId => uint256 claimsSupply) public claimTokensSupply;

    // Errors
    error InvalidOrder();
    error NothingToClaim();
    error NotEnoughToClaim();

    // Constructor
    constructor(IPoolManager _manager, string memory _uri) BaseHook(_manager) ERC1155(_uri) {}

    // BaseHook Functions
    // We use 2 hooks below: afterInitialize and afterSwap
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
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

    // Function afterInitialize
    function afterInitialize(address, PoolKey calldata key, uint160, int24 tick)
        external
        override
        onlyPoolManager
        returns (bytes4)
    {
        // pool is initialized, so current tick is set for the first time
        lastTicks[key.toId()] = tick;
        return this.afterInitialize.selector;
    }

    // Function afterSwap
    // Potential vulnerability: Do not let afterSwap be triggered if it is being executed because
    // of a swap our hook created while fulfilling an order (to prevent deep recursion and re-entrancy issues)

    // Identify tick shift range, find first order that can be fulfilled in that range, fill it -
    // but then update tick shift range and search again if there are any new orders that can be fulfilled in this range or not
    // - ignoring any orders that may have existed within the original tick shift range
    function afterSwap(
        address sender,
        PoolKey calldata key,
        IPoolManager.SwapParams calldata params,
        BalanceDelta,
        bytes calldata
    ) external override onlyPoolManager returns (bytes4, int128) {
        // `sender` is the address which initiated the swap
        // if `sender` is the hook, we don't want to go down the `afterSwap`
        // rabbit hole again
        if (sender == address(this)) return (this.afterSwap.selector, 0);

        // Then, assuming sender is not the hook itself, we will set up a while loop which
        // keeps trying to fulfill orders within the tick shift range.
        // Should we try to find and execute orders? True initially
        bool tryMore = true;
        int24 currentTick;

        // Production implementation? Might want to have some reasonable limit here on maximum number (avoid gas issues!)

        while (tryMore) {
            // Try executing pending orders for this pool
            // So, inside the while loop - we use a helper function called tryExecutingOrders.
            // This function will return us two values: tryMore and tickAfterExecutingOrder.

            // `tryMore` is true if we successfully found and executed an order
            // which shifted the tick value
            // and therefore we need to look again if there are any pending orders
            // within the new tick range

            // `tickAfterExecutingOrder` is the tick value of the pool
            // after executing an order
            // if no order was executed, `tickAfterExecutingOrder` will be
            // the same as current tick, and `tryMore` will be false
            (tryMore, currentTick) = tryExecutingOrders(key, !params.zeroForOne);
        }

        // New last known tick for this pool is the tick value
        // after our orders are executed
        lastTicks[key.toId()] = currentTick;
        return (this.afterSwap.selector, 0);
    }

    // PLACE ORDER FUNCTION
    // Core Hook External Functions
    function placeOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmount)
        external
        returns (int24)
    {
        // Get lower actually usable tick given `tickToSellAt`
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        // Create a pending order
        pendingOrders[key.toId()][tick][zeroForOne] += inputAmount;

        // Mint claim tokens to user equal to their `inputAmount`
        // A position ID is computed based on the tick and trading pair (key)
        uint256 positionId = getPositionId(key, tick, zeroForOne);
        claimTokensSupply[positionId] += inputAmount;
        _mint(msg.sender, positionId, inputAmount, "");

        // Depending on direction of swap, we select the proper input token
        // and request a transfer of those tokens to the hook contract
        address sellToken = zeroForOne ? Currency.unwrap(key.currency0) : Currency.unwrap(key.currency1);
        IERC20(sellToken).transferFrom(msg.sender, address(this), inputAmount);

        // Return the tick at which the order was actually placed
        return tick;
    }

    // CANCEL ORDER FUNCTION (opposite of place order function above basically)
    function cancelOrder(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 amountToCancel) external {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // Check how many claim tokens they have for this position
        uint256 positionTokens = balanceOf(msg.sender, positionId);
        if (positionTokens < amountToCancel) revert NotEnoughToClaim();

        // Remove their `amountToCancel` worth of position from pending orders
        pendingOrders[key.toId()][tick][zeroForOne] -= amountToCancel;
        // Reduce claim token total supply and burn their share
        claimTokensSupply[positionId] -= amountToCancel;
        _burn(msg.sender, positionId, amountToCancel);

        // Send them their input token
        Currency token = zeroForOne ? key.currency0 : key.currency1;
        token.transfer(msg.sender, amountToCancel);
    }

    // REDEEM FUNCTION
    function redeem(PoolKey calldata key, int24 tickToSellAt, bool zeroForOne, uint256 inputAmountToClaimFor)
        external
    {
        // Get lower actually usable tick for their order
        int24 tick = getLowerUsableTick(tickToSellAt, key.tickSpacing);
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // If no output tokens can be claimed yet i.e. order hasn't been filled
        // throw error
        if (claimableOutputTokens[positionId] == 0) revert NothingToClaim();

        // they must have claim tokens >= inputAmountToClaimFor
        // positionTokens = amount of claimable input tokens they have. this is equal to how many input tokens they provided.
        uint256 positionTokens = balanceOf(msg.sender, positionId);

        if (positionTokens < inputAmountToClaimFor) revert NotEnoughToClaim();

        /*
        1. User’s Share of Total Input Tokens = positionTokens / totalInputAmountForPosition
        2. User’s Output Tokens = User’s Share * totalClaimableForPosition
        3. User’s Output Tokens = outputAmount = inputAmountToClaimFor * totalClaimableForPosition / totalInputAmountForPosition
        Takes into account integer division!
        */

        /*
        Scenario:
        User deposited 100 input tokens.
        Total input tokens in this position: 1,000.
        Total output tokens available to claim: 500.
        User wants to redeem 50 input tokens.

        Outcome:
        User’s Share of Total Input Tokens = 50 / 1000 = 0.05
        User’s Output Tokens = 0.05 * 500 = 25
        So the user gets 25 output tokens for 50 input tokens redeemed.
        */

        // totalClaimableForPosition = Total output tokens available to be claimed (from execution)
        // this position (not necessarily just for this user, but all users who placed this order)
        uint256 totalClaimableForPosition = claimableOutputTokens[positionId];

        // totalInputAmountForPosition = total supply of input tokens for this position
        // placed across limit orders we are tracking (across all users)
        uint256 totalInputAmountForPosition = claimTokensSupply[positionId];

        // outputAmount = (inputAmountToClaimFor * totalClaimableForPosition) / (totalInputAmountForPosition)
        uint256 outputAmount = inputAmountToClaimFor.mulDivDown(totalClaimableForPosition, totalInputAmountForPosition);

        // Reduce claimable output tokens amount
        // Reduce claim token total supply for position
        // Burn claim tokens
        claimableOutputTokens[positionId] -= outputAmount;
        claimTokensSupply[positionId] -= inputAmountToClaimFor;
        _burn(msg.sender, positionId, inputAmountToClaimFor);

        // Transfer output tokens
        Currency token = zeroForOne ? key.currency1 : key.currency0;
        token.transfer(msg.sender, outputAmount);
    }

    // Internal Functions
    function tryExecutingOrders(PoolKey calldata key, bool executeZeroForOne)
        internal
        returns (bool tryMore, int24 newTick)
    {
        (, int24 currentTick,,) = poolManager.getSlot0(key.toId());
        int24 lastTick = lastTicks[key.toId()];

        // Given `currentTick` and `lastTick`, 2 cases are possible:

        // Case (1) - Tick has increased, i.e. `currentTick > lastTick`
        // or, Case (2) - Tick has decreased, i.e. `currentTick < lastTick`

        // If tick increases => Token 0 price has increased
        // => We should check if we have orders looking to sell Token 0
        // i.e. orders with zeroForOne = true

        // Also not the differences between case 1 and 2 below:
        // The only difference is:
        // In Case (1) (currentTick > lastTick), we loop forwards (tick += key.tickSpacing).
        // In Case (2) (currentTick < lastTick), we loop backwards (tick -= key.tickSpacing).

        // ------------
        // Case (1)
        // ------------

        // Tick has increased i.e. people bought Token 0 by selling Token 1
        // i.e. Token 0 price has increased
        // e.g. in an ETH/USDC pool, people are buying ETH for USDC causing ETH price to increase
        // We should check if we have any orders looking to sell Token 0
        // at ticks `lastTick` to `currentTick`
        // i.e. check if we have any orders to sell ETH at the new price that ETH is at now because of the increase
        if (currentTick > lastTick) {
            // Loop over all ticks from `lastTick` to `currentTick`
            // and execute orders that are looking to sell Token 0
            for (int24 tick = lastTick; tick < currentTick; tick += key.tickSpacing) {
                // Orders that sell Token 0 have zeroForOne = true.
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    // An order with these parameters can be placed by one or more users
                    // We execute the full order as a single swap
                    // Regardless of how many unique users placed the same order
                    executeOrder(key, tick, executeZeroForOne, inputAmount);

                    // Return true because we may have more orders to execute
                    // from lastTick to new current tick
                    // But we need to iterate again from scratch since our sale of ETH shifted the tick down
                    return (true, currentTick);
                }
            }
        }
        // ------------
        // Case (2)
        // ------------
        // Tick has gone down i.e. people bought Token 1 by selling Token 0
        // i.e. Token 1 price has increased
        // e.g. in an ETH/USDC pool, people are selling ETH for USDC causing ETH price to decrease (and USDC to increase)
        // We should check if we have any orders looking to sell Token 1
        // at ticks `currentTick` to `lastTick`
        // i.e. check if we have any orders to buy ETH at the new price that ETH is at now because of the decrease
        else {
            for (int24 tick = lastTick; tick > currentTick; tick -= key.tickSpacing) {
                // Orders that sell Token 1 have zeroForOne = false.
                uint256 inputAmount = pendingOrders[key.toId()][tick][executeZeroForOne];
                if (inputAmount > 0) {
                    executeOrder(key, tick, executeZeroForOne, inputAmount);
                    return (true, currentTick);
                }
            }
        }

        return (false, currentTick);
    }

    // FUNCTION EXECUTE ORDER

    /* EXAMPLE EXECUTE ORDER
    Scenario: User Places a Limit Order for 10 USDC → WETH
    zeroForOne = true (USDC → WETH)
    executeOrder is triggered and swap executes successfully.

    1. Swap is executed using swapAndSettleBalances()
    delta.amount0() = -10;
    delta.amount1() = 0.005;

    2. Deduct input from pending orders
    pendingOrders[poolId][tick][true] -= 10;

    3. Calculate received output
    outputAmount = 0.005 WETH;

    4. Update claimable tokens
    claimableOutputTokens[positionId] += 0.005

    5. Users can now redeem their WETH by calling redeem()
    */

    // ExecuteOrder function performs the actual swap and updates the contract state to reflect the execution of a limit order.
    function executeOrder(PoolKey calldata key, int24 tick, bool zeroForOne, uint256 inputAmount) internal {
        // 1. Perform the Swap
        // Do the actual swap and settle all balances
        BalanceDelta delta = swapAndSettleBalances(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                // We provide a negative value here to signify an "exact input for output" swap
                amountSpecified: -int256(inputAmount),
                // No slippage limits (maximum slippage possible)
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            })
        );

        // 2. Deduct the Input Amount from Pending Orders
        // `inputAmount` has been deducted from this position
        pendingOrders[key.toId()][tick][zeroForOne] -= inputAmount;

        // 3. Get the Position ID: Each limit order position has a unique ID
        uint256 positionId = getPositionId(key, tick, zeroForOne);

        // 4.  Calculate the Received Output Amount
        uint256 outputAmount = zeroForOne ? uint256(int256(delta.amount1())) : uint256(int256(delta.amount0()));

        // 5. Update Claimable Output Tokens
        // `outputAmount` worth of tokens now can be claimed/redeemed by position holders
        claimableOutputTokens[positionId] += outputAmount;
    }

    // How to swap and settle balances??
    // Assuming the order information is provided to us by a higher-level function (afterSwap):

    // 1. Call poolManager.swap to conduct the actual swap. This will return a BalanceDelta
    // 2. Settle all balances with the pool manager
    // 3. Remove the swapped amount of input tokens from the pendingOrders mapping
    // 4. Increase the amount of output tokens now claimable for this position in the claimableOutputTokens mapping

    function swapAndSettleBalances(PoolKey calldata key, IPoolManager.SwapParams memory params)
        internal
        returns (BalanceDelta)
    {
        // Conduct the swap inside the Pool Manager
        // BalanceDelta delta contains the changes in token balances resulting from the swap.
        BalanceDelta delta = poolManager.swap(key, params, "");

        // If we just did a zeroForOne swap
        // We need to send Token 0 to PM, and receive Token 1 from PM
        // zeroForOne (true): Swapping Token 0 → Token 1.
        // zeroForOne (false): Swapping Token 1 → Token 0.
        if (params.zeroForOne) {
            // Negative Value => Money leaving user's wallet
            // If delta.amount0() < 0, we need to send Token 0 to the Pool Manager
            if (delta.amount0() < 0) {
                _settle(key.currency0, uint128(-delta.amount0()));
            }

            // Positive Value => Money coming into user's wallet
            // If delta.amount1() > 0, we need to take Token 1 from the Pool Manager
            if (delta.amount1() > 0) {
                _take(key.currency1, uint128(delta.amount1()));
            }
        } else {
            // If amount1() is negative, this means Token 1 must be sent to the Pool Manager.
            if (delta.amount1() < 0) {
                _settle(key.currency1, uint128(-delta.amount1()));
            }
            // If amount0() is positive, this means Token 0 should be taken from the Pool Manager
            if (delta.amount0() > 0) {
                _take(key.currency0, uint128(delta.amount0()));
            }
        }

        return delta;
    }

    /* EXAMPLE
    Scenario: User Swaps 10 USDC for WETH
    zeroForOne = true
    delta.amount0() = -10 (USDC sent to pool)
    delta.amount1() = 0.005 WETH (received from pool)
    Execution Steps
    1.  poolManager.swap() executes the trade, returning:
    2️.  _settle(key.currency0, 10); → Sends 10 USDC to Pool Manager. 
    3.  _take(key.currency1, 0.005); → Withdraws 0.005 WETH from the Pool Manager.
    */

    // Question for workshop:
    // We call both settle and take function when the swap is fully executed??
    // If a swap only sends tokens, only _settle() is called.
    // If a swap only receives tokens, only _take() is called.
    // Limit order not executed ==> No settle or take?

    function _settle(Currency currency, uint128 amount) internal {
        // Transfer tokens to PM and let it know
        poolManager.sync(currency); //  Notifies the Pool Manager about the token balance change.
        currency.transfer(address(poolManager), amount); // Transfers tokens to the Pool Manager.
        poolManager.settle(); // Finalizes the settlement
    }

    function _take(Currency currency, uint128 amount) internal {
        // Take tokens out of PM to our hook contract
        // Transfers them to the hook contract where they will be processed
        poolManager.take(currency, address(this), amount);
    }

    // Helper Functions to get the Position ID
    function getPositionId(PoolKey calldata key, int24 tick, bool zeroForOne) public pure returns (uint256) {
        return uint256(keccak256(abi.encode(key.toId(), tick, zeroForOne)));
    }

    // The getLowerUsableTick function calculates the closest lower tick that is a multiple of the tickSpacing
    function getLowerUsableTick(int24 tick, int24 tickSpacing) private pure returns (int24) {
        // E.g. tickSpacing = 60, tick = -100
        // closest usable tick rounded-down will be -120

        // intervals = -100/60 = -1 (integer division)
        // Divides tick by tickSpacing to determine how many full tick intervals fit into tick
        int24 intervals = tick / tickSpacing;

        // since tick < 0, we round `intervals` down to -2
        // if tick > 0, `intervals` is fine as it is
        if (tick < 0 && tick % tickSpacing != 0) intervals--; // round towards negative infinity

        // actual usable tick, then, is intervals * tickSpacing
        // i.e. -2 * 60 = -120
        return intervals * tickSpacing;
    }
}
