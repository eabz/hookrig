// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";
import {HookRigBase} from "../../base/HookRigBase.sol";
import {HookPermissionMasks} from "../../libraries/HookPermissionMasks.sol";
import {PoolTokenDir} from "../../libraries/PoolTokenDir.sol";
import {CircuitBreakerLogic} from "../protection/CircuitBreakerBlock.sol";
import {ReferralSplitLogic} from "./ReferralSplitBlock.sol";
import {VestingSellCapLogic} from "../token-rules/VestingSellCapBlock.sol";
import {AutoBuybackLogic} from "./AutoBuybackBlock.sol";

library KingOfThePoolLogic {
    uint16 internal constant MAX_KING_POT_BPS = 500; // 5.00%
    uint32 internal constant MIN_KING_ROUND_DURATION = 60; // 1 minute
    uint32 internal constant MAX_KING_ROUND_DURATION = 30 days; // 30 days
    uint128 internal constant MAX_MIN_BUY_AMOUNT_FOR_RESET = 1_000_000_000 ether;

    struct KingRoundState {
        uint16 potFeeOnBuyBps;
        uint32 roundDurationSeconds;
        uint128 minBuyAmountForReset;
        uint64 currentRoundId;
        uint64 roundDeadline;
        address currentKing;
        Currency potCurrency;
        uint256 currentPotAmount;
    }

    struct SettledKingRound {
        address winner;
        Currency currency;
        uint256 amount;
        bool claimed;
    }

    event NewKingCrowned(
        PoolId indexed poolId,
        uint64 indexed roundId,
        address indexed newKing,
        uint256 potContribution,
        uint256 totalPot,
        uint64 newDeadline
    );
    event KingRoundFinalized(
        PoolId indexed poolId, uint64 indexed roundId, address indexed winner, Currency currency, uint256 rewardAmount
    );
    event KingPotClaimed(PoolId indexed poolId, uint64 indexed roundId, address indexed winner, uint256 amount);

    error KingPotBpsExceedsCap(uint16 requestedBps);
    error InvalidKingRoundDuration(uint32 durationSeconds);
    error RoundNotClaimable(PoolId poolId, uint64 roundId);
    error NotRoundWinner(address caller, address winner);

    function initKing(
        mapping(PoolId => KingRoundState) storage states,
        PoolId poolId,
        IHookRigBlock.KingOfThePoolParams calldata params,
        uint32 overrideDuration
    ) public {
        if (params.potFeeOnBuyBps > MAX_KING_POT_BPS || params.minBuyAmountForReset > MAX_MIN_BUY_AMOUNT_FOR_RESET) {
            revert KingPotBpsExceedsCap(params.potFeeOnBuyBps);
        }
        if (
            overrideDuration == 0 && params.roundDurationSeconds != 0
                && (params.roundDurationSeconds < MIN_KING_ROUND_DURATION
                    || params.roundDurationSeconds > MAX_KING_ROUND_DURATION)
        ) {
            revert InvalidKingRoundDuration(params.roundDurationSeconds);
        }
        uint32 duration = overrideDuration > 0
            ? overrideDuration
            : (params.roundDurationSeconds > 0 ? params.roundDurationSeconds : 3600);
        states[poolId] = KingRoundState({
            potFeeOnBuyBps: params.potFeeOnBuyBps,
            roundDurationSeconds: duration,
            minBuyAmountForReset: params.minBuyAmountForReset,
            currentRoundId: 1,
            roundDeadline: uint64(block.timestamp + duration),
            currentKing: address(0),
            potCurrency: Currency.wrap(address(0)),
            currentPotAmount: 0
        });
    }

    function initExpansionBlocks(
        mapping(PoolId => KingRoundState) storage kingStates,
        mapping(PoolId => CircuitBreakerLogic.CircuitBreakerState) storage circuitBreakerStates,
        mapping(PoolId => IHookRigBlock.ReferralSplitParams) storage referralConfigs,
        mapping(PoolId => IHookRigBlock.VestingSellCapParams) storage vestingSellCapConfigs,
        mapping(PoolId => AutoBuybackLogic.AutoBuybackState) storage autoBuybackStates,
        PoolId poolId,
        IHookRigBlock.PoolStackConfig calldata config,
        uint32 bitmap
    ) external {
        if ((bitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0) {
            uint32 overrideDuration = (config.presetId == IHookRigBlock.PresetId.WeeklyKingWithBuyRewards
                    && config.kingOfThePool.roundDurationSeconds == 0)
                ? uint32(168 hours)
                : 0;
            initKing(kingStates, poolId, config.kingOfThePool, overrideDuration);
        }
        if ((bitmap & HookPermissionMasks.BIT_CIRCUIT_BREAKER) != 0) {
            CircuitBreakerLogic.init(circuitBreakerStates, poolId, config.circuitBreaker);
        }
        if ((bitmap & HookPermissionMasks.BIT_REFERRAL_SPLIT) != 0) {
            ReferralSplitLogic.init(referralConfigs, poolId, config.referralSplit);
        }
        if ((bitmap & HookPermissionMasks.BIT_VESTING_SELL_CAP) != 0) {
            VestingSellCapLogic.init(vestingSellCapConfigs, poolId, config.vestingSellCap);
        }
        if ((bitmap & HookPermissionMasks.BIT_AUTO_BUYBACK) != 0) {
            AutoBuybackLogic.init(autoBuybackStates, poolId, config.autoBuyback);
        }
    }

    function processBuy(
        mapping(PoolId => KingRoundState) storage states,
        mapping(PoolId => mapping(uint64 => SettledKingRound)) storage settledRounds,
        PoolId poolId,
        address buyer,
        Currency cutCurrency,
        uint256 potContribution,
        uint256 grossBuyOutput
    ) public {
        KingRoundState storage state = states[poolId];
        if (state.potFeeOnBuyBps == 0) return;

        if (block.timestamp >= state.roundDeadline && state.currentKing != address(0) && state.currentPotAmount > 0) {
            _rollKingRound(settledRounds, poolId, state);
        }

        if (potContribution > 0) {
            if (state.currentPotAmount > 0 && Currency.unwrap(state.potCurrency) != Currency.unwrap(cutCurrency)) {
                if (state.currentKing == address(0) && buyer != address(0)) {
                    state.currentKing = buyer;
                }
                if (state.currentKing != address(0)) {
                    _rollKingRound(settledRounds, poolId, state);
                }
            }
            if (state.currentPotAmount == 0) {
                state.potCurrency = cutCurrency;
            }
            require(Currency.unwrap(state.potCurrency) == Currency.unwrap(cutCurrency), "CurrencyMismatch");
            state.currentPotAmount += potContribution;
        }

        if (buyer != address(0) && grossBuyOutput >= state.minBuyAmountForReset) {
            state.currentKing = buyer;
            state.roundDeadline = uint64(block.timestamp + state.roundDurationSeconds);
            emit NewKingCrowned(
                poolId, state.currentRoundId, buyer, potContribution, state.currentPotAmount, state.roundDeadline
            );
        }
    }

    function processWaterfallKing(
        mapping(PoolId => KingRoundState) storage states,
        mapping(PoolId => mapping(uint64 => SettledKingRound)) storage settledRounds,
        IPoolManager manager,
        PoolId poolId,
        address trader,
        Currency unspecifiedCurrency,
        uint256 grossAmount,
        bool isExactInput,
        uint256 totalCutAmount
    ) external returns (uint256 newTotalCut) {
        newTotalCut = totalCutAmount;
        uint16 potBps = states[poolId].potFeeOnBuyBps;
        if (potBps > 0) {
            Math.Rounding rounding = isExactInput ? Math.Rounding.Floor : Math.Rounding.Ceil;
            uint256 maxAllowedTotalCut = Math.mulDiv(grossAmount, 2500, 10_000, rounding);
            uint256 potCut = 0;
            if (newTotalCut < maxAllowedTotalCut) {
                potCut = Math.mulDiv(grossAmount, potBps, 10_000, rounding);
                if (newTotalCut + potCut > maxAllowedTotalCut) {
                    potCut = maxAllowedTotalCut - newTotalCut;
                }
            }
            if (potCut > 0) {
                newTotalCut += potCut;
                manager.mint(address(this), unspecifiedCurrency.toId(), potCut);
            }
            processBuy(states, settledRounds, poolId, trader, unspecifiedCurrency, potCut, grossAmount);
        }
    }

    function finalizeExpired(
        mapping(PoolId => KingRoundState) storage states,
        mapping(PoolId => mapping(uint64 => SettledKingRound)) storage settledRounds,
        PoolId poolId
    ) public {
        KingRoundState storage state = states[poolId];
        if (block.timestamp >= state.roundDeadline && state.currentKing != address(0) && state.currentPotAmount > 0) {
            _rollKingRound(settledRounds, poolId, state);
        }
    }

    function validateAndMarkClaimed(
        mapping(PoolId => KingRoundState) storage states,
        mapping(PoolId => mapping(uint64 => SettledKingRound)) storage settledRounds,
        PoolId poolId,
        uint64 roundId
    ) external returns (Currency currency, uint256 reward) {
        finalizeExpired(states, settledRounds, poolId);
        SettledKingRound storage round = settledRounds[poolId][roundId];
        if (round.amount == 0 || round.claimed) revert RoundNotClaimable(poolId, roundId);
        if (msg.sender != round.winner) revert NotRoundWinner(msg.sender, round.winner);

        round.claimed = true;
        reward = round.amount;
        currency = round.currency;

        emit KingPotClaimed(poolId, roundId, msg.sender, reward);
    }

    function _rollKingRound(
        mapping(PoolId => mapping(uint64 => SettledKingRound)) storage settledRounds,
        PoolId poolId,
        KingRoundState storage state
    ) private {
        uint64 finishedRound = state.currentRoundId;
        settledRounds[poolId][finishedRound] = SettledKingRound({
            winner: state.currentKing, currency: state.potCurrency, amount: state.currentPotAmount, claimed: false
        });
        emit KingRoundFinalized(poolId, finishedRound, state.currentKing, state.potCurrency, state.currentPotAmount);

        state.currentRoundId = finishedRound + 1;
        state.currentKing = address(0);
        state.currentPotAmount = 0;
        state.roundDeadline = uint64(block.timestamp + state.roundDurationSeconds);
    }

    function seedPotFromLaunchCurve(
        mapping(PoolId => KingRoundState) storage states,
        mapping(PoolId => HookRigBase.PoolRuntimeMeta) storage poolMeta,
        mapping(PoolId => mapping(Currency => mapping(address => uint256))) storage poolClaims,
        PoolId poolId,
        Currency currency,
        uint256 amount,
        address launchpadFactory,
        address ownerAddress
    ) external {
        HookRigBase.PoolRuntimeMeta storage meta = poolMeta[poolId];
        if (msg.sender != meta.authorizedCurve && msg.sender != launchpadFactory) {
            revert HookRigBase.OnlyAuthorizedCurve(msg.sender);
        }
        if (amount == 0) return;
        KingRoundState storage st = states[poolId];
        if (
            (meta.enabledBlocksBitmap & HookPermissionMasks.BIT_KING_OF_THE_POOL) != 0
                && currency == meta.projectCurrency && (st.currentPotAmount == 0 || st.potCurrency == currency)
        ) {
            st.potCurrency = currency;
            st.currentPotAmount += amount;
        } else {
            address admin = meta.poolAdmin != address(0) ? meta.poolAdmin : ownerAddress;
            poolClaims[poolId][currency][admin] += amount;
        }
    }
}

/// @title KingOfThePoolBlock
/// @notice Group 4 (Rewards & Income) — Block #14: Rolling countdown jackpot funded by a pot fee on buys
///         (`afterSwap`, `afterSwapReturnDelta`).
/// @dev Trust Level: Medium (potFeeOnBuyBps <= 5%; anti-dust reset minimum; pull-based jackpot payout).
abstract contract KingOfThePoolBlock is IHookRigBlock {
    mapping(PoolId poolId => KingOfThePoolLogic.KingRoundState state) internal _kingStates;
    mapping(PoolId poolId => mapping(uint64 roundId => KingOfThePoolLogic.SettledKingRound round)) internal
        _settledKingRounds;

    function _initKingOfThePool(PoolId poolId, KingOfThePoolParams calldata params, uint32 overrideDuration) internal {
        KingOfThePoolLogic.initKing(_kingStates, poolId, params, overrideDuration);
    }

    function _resetKingGraduationClock(PoolId poolId) internal {
        KingOfThePoolLogic.KingRoundState storage s = _kingStates[poolId];
        if (s.roundDurationSeconds > 0) {
            s.roundDeadline = uint64(block.timestamp + s.roundDurationSeconds);
        }
    }

    /// @notice Processes a buy contribution into the King of the Pool pot and updates the countdown timer.
    function _processKingOfThePoolBuy(
        PoolId poolId,
        address buyer,
        Currency cutCurrency,
        uint256 potContribution,
        uint256 grossBuyOutput
    ) internal {
        KingOfThePoolLogic.processBuy(
            _kingStates, _settledKingRounds, poolId, buyer, cutCurrency, potContribution, grossBuyOutput
        );
    }

    function finalizeExpiredKingRound(PoolId poolId) public {
        KingOfThePoolLogic.finalizeExpired(_kingStates, _settledKingRounds, poolId);
    }

    function _validateKingClaim(PoolId poolId, uint64 roundId) internal returns (Currency currency, uint256 reward) {
        return KingOfThePoolLogic.validateAndMarkClaimed(_kingStates, _settledKingRounds, poolId, roundId);
    }

    function getCurrentKing(PoolId poolId)
        external
        view
        returns (uint64 roundId, address king, uint256 potAmount, uint64 deadline)
    {
        KingOfThePoolLogic.KingRoundState storage s = _kingStates[poolId];
        return (s.currentRoundId, s.currentKing, s.currentPotAmount, s.roundDeadline);
    }
}
