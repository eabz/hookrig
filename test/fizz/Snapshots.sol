// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Base.sol";
import {Position} from "@uniswap/v4-core/src/libraries/Position.sol";
import {KingOfThePoolLogic} from "../../src/blocks/rewards/KingOfThePoolBlock.sol";

/// @notice Used to take snapshots of the state before and after a function call
/// @dev Layout: per-pool data lives in `State.pools[poolIdx]`; claims and allowlist flags are flattened
///      (see `_claimIdx` / `_allowIdx`); per-currency data is indexed like `trackedCurrencies`. Pools and
///      currencies only ever get appended, so compare index `i` only while `i < min(before.nPools, after.nPools)`.
abstract contract Snapshots is Base {
    using PoolIdLibrary for PoolKey;

    /// @notice Per-pool snapshot (curve fields are zero for standard pools).
    struct PoolSnap {
        uint32 bitmap;
        // King of the Pool
        uint64 kRound;
        address kKing;
        uint256 kPot;
        uint64 kDeadline;
        Currency potCurrency;
        // Accumulators and reserves
        uint256[2] bbReserve; // buyback reserve in currency0 / currency1
        uint256 lpDonated;
        uint256 burned;
        uint256 poolPoints;
        // PoolManager slot0
        uint24 lpFee;
        uint160 sqrtP;
        int24 tick;
        // Oracle and anti-snipe
        int24 oLast;
        int56 oCum;
        uint32 oTs;
        uint32 snipeStart;
        // Launch curve (poolCurves[i])
        uint8 launchState;
        uint256 rqr;
        uint256 sold;
        uint256 vQ;
        uint256 vT;
        uint256 k;
        uint256 surch;
        uint128 curvePosLiq; // curve's full-range graduation position (salt 0)
    }

    struct State {
        bool snapshotValid;
        uint256 timestamp;
        uint256 blockNumber;
        address actor;
        uint256 nPools;
        uint256 nCurrencies;
        uint256 nClaimants;
        PoolSnap[] pools;
        uint256[] claims; // (pool, side, claimant) → `_claimIdx`
        bool[] allow; // (pool, claimant) → `_allowIdx`
        uint256[] hook6909; // per tracked currency
        uint256[] hookBal; // hook ERC-20 balance per tracked currency
        uint256 hookEth;
        uint256[] actorBal; // `actor` balance per tracked currency
        uint256 actorEth;
    }

    State internal stateBefore;
    State internal stateAfter;

    /// @notice True once the current tracked call took its after-snapshot (handlers that run specific properties
    ///         take it explicitly right after the protocol call, so `tracked` must not take it again).
    bool internal afterSnapshotTaken;

    // ――――――――――――――――――――――――― Tracking ――――――――――――――――――――――――――

    /// @notice Wraps a public handler with before/after snapshots. Nested tracked handlers only snapshot at the
    ///         outermost entry. Resets the call-context ghosts so handlers only set what applies to them.
    modifier tracked() {
        bool outermost = ghosts.trackDepth == 0;
        if (outermost) {
            ghosts.lastCall = CallKind.NONE;
            ghosts.lastCaller = address(0);
            ghosts.lastPoolIdx = 0;
            ghosts.lastAccount = address(0);
            ghosts.lastCallWasWithdraw = false;
            afterSnapshotTaken = false;
            snapshotBefore();
        }
        ghosts.trackDepth++;
        _;
        ghosts.trackDepth--;
        if (outermost && !afterSnapshotTaken) snapshotAfter();
    }

    /// @notice Records the call context read by GL-08 / GL-22 / SP-23 (set before the protocol call).
    function _setCallContext(CallKind kind, address caller, uint256 poolIdx, address account) internal {
        ghosts.lastCall = kind;
        ghosts.lastCaller = caller;
        ghosts.lastPoolIdx = poolIdx;
        ghosts.lastAccount = account;
    }

    function snapshotBefore() internal {
        _takeSnapshot(stateBefore);
    }

    /// @dev Runs at most once per tracked call: derived ghosts are deltas of the before/after pair, so a second
    ///      evaluation would double-count them.
    function snapshotAfter() internal {
        if (afterSnapshotTaken) return;
        afterSnapshotTaken = true;
        _takeSnapshot(stateAfter);
        _updateDerivedGhosts();
    }

    // ――――――――――――――――――――――――― Accessors ―――――――――――――――――――――――――

    function _claimIdx(State storage s, uint256 poolIdx, uint256 side, uint256 claimantIdx)
        internal
        view
        returns (uint256)
    {
        return (poolIdx * 2 + side) * s.nClaimants + claimantIdx;
    }

    function _allowIdx(State storage s, uint256 poolIdx, uint256 claimantIdx) internal view returns (uint256) {
        return poolIdx * s.nClaimants + claimantIdx;
    }

    function _snapClaim(State storage s, uint256 poolIdx, uint256 side, uint256 claimantIdx)
        internal
        view
        returns (uint256)
    {
        return s.claims[_claimIdx(s, poolIdx, side, claimantIdx)];
    }

    /// @notice Number of pools present in both snapshots.
    function _commonPools() internal view returns (uint256) {
        return stateBefore.nPools < stateAfter.nPools ? stateBefore.nPools : stateAfter.nPools;
    }

    /// @notice True when a before/after pair from the same tracked call is available.
    function _snapshotsValid() internal view returns (bool) {
        return stateBefore.snapshotValid && stateAfter.snapshotValid;
    }

    // ――――――――――――――――――――――――― Snapshot ――――――――――――――――――――――――――

    /// @dev Every read is a view call that cannot revert, or a guarded staticcall that falls back to 0.
    function _takeSnapshot(State storage s) private {
        s.snapshotValid = true;
        s.timestamp = block.timestamp;
        s.blockNumber = block.number;
        s.actor = actor;
        s.nPools = poolKeys.length;
        s.nCurrencies = trackedCurrencies.length;
        s.nClaimants = claimants.length;

        for (uint256 c; c < trackedCurrencies.length; c++) {
            Currency currency = trackedCurrencies[c];
            _setU(s.hook6909, c, poolManager.balanceOf(address(orchestrator), currency.toId()));
            _setU(s.hookBal, c, _currencyBalance(currency, address(orchestrator)));
            _setU(s.actorBal, c, _currencyBalance(currency, actor));
        }
        s.hookEth = address(orchestrator).balance;
        s.actorEth = actor.balance;

        for (uint256 i; i < poolKeys.length; i++) {
            if (s.pools.length <= i) s.pools.push();
            _snapPool(s, s.pools[i], i);
        }
    }

    function _snapPool(State storage s, PoolSnap storage ps, uint256 i) private {
        PoolKey memory key = poolKeys[i];
        PoolId pid = key.toId();

        ps.bitmap = orchestrator.getPoolEnabledBlocks(pid);
        (ps.kRound, ps.kKing, ps.kPot, ps.kDeadline) = orchestrator.getCurrentKing(pid);
        ps.potCurrency = orchestrator.kingState(pid).potCurrency;
        ps.bbReserve[0] = orchestrator.buybackReserve(pid, key.currency0);
        ps.bbReserve[1] = orchestrator.buybackReserve(pid, key.currency1);
        ps.lpDonated = orchestrator.totalLPRewardsDonated(pid);
        ps.burned = orchestrator.totalAutoBurnedByPool(pid);
        ps.poolPoints = orchestrator.totalPoolSwapPoints(pid);
        (ps.sqrtP, ps.tick,, ps.lpFee) = StateLibrary.getSlot0(poolManager, pid);
        (ps.oLast, ps.oCum) = orchestrator.getOracleTickCumulative(pid);
        (,, ps.oTs) = orchestrator.observeOracleAtCurrentTime(pid);
        ps.snipeStart = orchestrator.antiSnipeState(pid).startBlock;

        for (uint256 a; a < claimants.length; a++) {
            address claimant = claimants[a];
            _setU(s.claims, _claimIdx(s, i, 0, a), orchestrator.poolClaims(pid, key.currency0, claimant));
            _setU(s.claims, _claimIdx(s, i, 1, a), orchestrator.poolClaims(pid, key.currency1, claimant));
            _setB(s.allow, _allowIdx(s, i, a), orchestrator.isAccountAllowlisted(pid, claimant));
        }

        address curve = poolCurves[i];
        if (curve != address(0)) {
            ps.launchState = _launchState(curve);
            ps.rqr = _tryUint(curve, "realQuoteRaised()");
            ps.sold = _tryUint(curve, "curveTokensSold()");
            ps.vQ = _tryUint(curve, "virtualQuoteReserve()");
            ps.vT = _tryUint(curve, "virtualTokenReserve()");
            ps.k = _tryUint(curve, "invariantK()");
            ps.surch = _tryUint(curve, "totalSurchargeCollected()");
            ps.curvePosLiq = _curveFullRangeLiquidity(curve, key);
        }
    }

    /// @notice Liquidity of the curve's permanent full-range graduation position (`unlockCallback`, salt 0).
    function _curveFullRangeLiquidity(address curve, PoolKey memory key) internal view returns (uint128) {
        int24 spacing = key.tickSpacing;
        int24 tickLower = (TickMath.MIN_TICK / spacing) * spacing;
        int24 tickUpper = (TickMath.MAX_TICK / spacing) * spacing;
        bytes32 posKey = Position.calculatePositionKey(curve, tickLower, tickUpper, bytes32(0));
        return StateLibrary.getPositionLiquidity(poolManager, key.toId(), posKey);
    }

    /// @notice Calls a no-argument uint256 getter; returns 0 if it is missing or reverts.
    function _tryUint(address target, string memory sig) internal view returns (uint256 value) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        if (ok && data.length >= 32) value = abi.decode(data, (uint256));
    }

    function _setU(uint256[] storage arr, uint256 idx, uint256 value) private {
        while (arr.length <= idx) arr.push();
        arr[idx] = value;
    }

    function _setB(bool[] storage arr, uint256 idx, bool value) private {
        while (arr.length <= idx) arr.push();
        arr[idx] = value;
    }

    // ――――――――――――――――――――― Derived ghost updates ――――――――――――――――――――

    /// @notice Ghosts that follow from the before/after pair alone, so they stay correct for every tracked handler.
    function _updateDerivedGhosts() private {
        uint256 nBefore = stateBefore.nPools;
        for (uint256 i; i < stateAfter.nPools; i++) {
            PoolSnap storage a = stateAfter.pools[i];
            PoolId pid = poolKeys[i].toId();

            // King: attribute pot growth to the round and the pot currency it was recorded under
            if (i >= nBefore) {
                if (a.kPot > 0) _recordKingAdded(pid, a.kRound, a.potCurrency, a.kPot);
                if (a.sqrtP != 0) ghosts.oracleChangedAt[i] = stateBefore.timestamp; // initialized during this call
            } else {
                PoolSnap storage b = stateBefore.pools[i];
                if (a.kRound == b.kRound) {
                    if (a.kPot > b.kPot) _recordKingAdded(pid, a.kRound, a.potCurrency, a.kPot - b.kPot);
                } else if (a.kPot > 0) {
                    _recordKingAdded(pid, a.kRound, a.potCurrency, a.kPot);
                }

                // Oracle: a visible checkpoint happened somewhere in [before.timestamp, after.timestamp]
                if (b.sqrtP == 0 && a.sqrtP != 0) {
                    ghosts.oracleChangedAt[i] = stateBefore.timestamp; // initialized during this call
                } else if (a.oLast != b.oLast || a.oCum != b.oCum) {
                    ghosts.oracleWindowStart[i] = ghosts.oracleChangedAt[i];
                    ghosts.oracleChangedAt[i] = stateBefore.timestamp;
                }
            }

            // Anti-snipe: once a live pool's fee reaches normalFee it must never rise again (GL-18)
            if (!ghosts.antiSnipeDecayed[pid] && (a.bitmap & HookPermissionMasks.BIT_ANTI_SNIPE) != 0 && _isPoolLive(i))
            {
                uint24 normalFee = orchestrator.antiSnipeState(pid).normalFee;
                uint24 launchFee = orchestrator.antiSnipeState(pid).launchFee;
                if (launchFee > 0 && orchestrator.antiSnipeFee(pid) == normalFee) {
                    ghosts.antiSnipeDecayed[pid] = true;
                }
            }
        }
    }

    function _recordKingAdded(PoolId pid, uint64 round, Currency currency, uint256 amount) private {
        ghosts.kingAdded[pid][round][currency] += amount;
        if (!ghosts.kingRoundFunded[pid][round]) {
            ghosts.kingRoundFunded[pid][round] = true;
            ghosts.kingFundingCurrency[pid][round] = currency;
        } else if (!(ghosts.kingFundingCurrency[pid][round] == currency)) {
            ghosts.kingMixedRounds++;
        }
    }
}
