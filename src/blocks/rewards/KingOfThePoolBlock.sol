// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {IHookRigBlock} from "../../interfaces/IHookRigBlock.sol";

library KingOfThePoolLogic {
    uint16 internal constant MAX_KING_POT_BPS = 500; // 5.00%
    uint32 internal constant MIN_KING_ROUND_DURATION = 60; // 1 minute
    uint32 internal constant MAX_KING_ROUND_DURATION = 30 days; // 30 days

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
    ) external {
        if (params.potFeeOnBuyBps > MAX_KING_POT_BPS) {
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

    function processBuy(
        mapping(PoolId => KingRoundState) storage states,
        mapping(PoolId => mapping(uint64 => SettledKingRound)) storage settledRounds,
        PoolId poolId,
        address buyer,
        Currency cutCurrency,
        uint256 potContribution,
        uint256 grossBuyOutput
    ) external {
        KingRoundState storage state = states[poolId];
        if (state.potFeeOnBuyBps == 0) return;

        if (block.timestamp >= state.roundDeadline && state.currentKing != address(0) && state.currentPotAmount > 0) {
            _rollKingRound(settledRounds, poolId, state);
        }

        if (potContribution > 0) {
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
