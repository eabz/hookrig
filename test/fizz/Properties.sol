// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "./Snapshots.sol";
import {PropertiesAsserts} from "./utils/PropertiesAsserts.sol";
import {KingOfThePoolLogic} from "../../src/blocks/rewards/KingOfThePoolBlock.sol";
import {LimitOrdersLogic} from "../../src/blocks/trading/LimitOrdersBlock.sol";
import {TWAMMLogic} from "../../src/blocks/trading/TWAMMBlock.sol";
import {AntiSnipeLogic} from "../../src/blocks/protection/AntiSnipeBlock.sol";
import {VestingSellCapLogic} from "../../src/blocks/token-rules/VestingSellCapBlock.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";

/// @notice Contains the functions that check the properties (invariants)
abstract contract Properties is PropertiesAsserts, Snapshots {
    using PoolIdLibrary for PoolKey;

    /// @notice Settled King rounds scanned per pool by GL-02 (most recent first); older rounds are skipped.
    uint256 internal constant MAX_KING_ROUNDS_SCAN = 256;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint8 internal constant LS_ACTIVE = uint8(ITokenLaunchpad.LaunchState.ActiveBonding);
    uint8 internal constant LS_GRADUATED = uint8(ITokenLaunchpad.LaunchState.Graduated);

    // ―――――――――――――――――――― Global properties ―――――――――――――――――――――
    // These properties must always hold after any function call.
    // They MUST BE PUBLIC so that fuzzers can find and call them.

    /// @notice GL-01: hook ERC-6909 balance per currency covers the sum of every pool's claims in that currency
    function property_GL01_claimSolvency() public {
        (uint256[] memory claimSum,) = _hookLiabilities(false);
        for (uint256 c; c < trackedCurrencies.length; c++) {
            gte(_hook6909(trackedCurrencies[c]), claimSum[c], "GL-01: hook ERC-6909 balance < sum of poolClaims");
        }
    }

    /// @notice GL-02: hook ERC-6909 balance covers claims + open King pots + unclaimed settled rounds + buyback reserves
    function property_GL02_fullBacking() public {
        (, uint256[] memory fullSum) = _hookLiabilities(true);
        for (uint256 c; c < trackedCurrencies.length; c++) {
            gte(_hook6909(trackedCurrencies[c]), fullSum[c], "GL-02: hook ERC-6909 balance < total 6909 liabilities");
        }
    }

    /// @notice GL-03: a non-empty King pot is funded in one currency and its potCurrency never changes mid-round
    function property_GL03_kingPotCurrencyPurity() public {
        eq(ghosts.kingMixedRounds, 0, "GL-03: a King round received a second pot currency");

        for (uint256 i; i < poolKeys.length; i++) {
            PoolId pid = poolKeys[i].toId();
            (uint64 round,,,) = orchestrator.getCurrentKing(pid);
            uint256 funded;
            for (uint256 c; c < trackedCurrencies.length; c++) {
                if (ghosts.kingAdded[pid][round][trackedCurrencies[c]] > 0) funded++;
            }
            lte(funded, 1, "GL-03: current King round funded in more than one currency");
        }

        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        for (uint256 i; i < n; i++) {
            PoolSnap storage b = stateBefore.pools[i];
            PoolSnap storage a = stateAfter.pools[i];
            if (a.kRound == b.kRound && b.kPot > 0) {
                t(a.potCurrency == b.potCurrency, "GL-03: potCurrency changed while the round's pot was non-zero");
            }
        }
    }

    /// @notice GL-04: hook token (and ETH) balances cover the input of every open tracked limit order
    function property_GL04_limitOrderEscrow() public {
        uint256 nC = trackedCurrencies.length;
        uint256[] memory owed = new uint256[](nC);
        uint256 owedNative;
        for (uint256 o; o < trackedOrders.length; o++) {
            TrackedOrder storage order = trackedOrders[o];
            if (order.closed) continue;
            if (order.inputCurrency.isAddressZero()) {
                owedNative += order.inputAmount;
            } else {
                uint256 c = _currencyIdx(order.inputCurrency);
                if (c < nC) owed[c] += order.inputAmount;
            }
        }
        for (uint256 c; c < nC; c++) {
            gte(
                _currencyBalance(trackedCurrencies[c], address(orchestrator)),
                owed[c],
                "GL-04: hook ERC-20 balance < open limit-order escrow"
            );
        }
        gte(address(orchestrator).balance, owedNative, "GL-04: hook ETH balance < open native limit-order escrow");
    }

    /// @notice GL-05: a bonding curve's quote balance covers realQuoteRaised (+ surcharges for tranche curves)
    function property_GL05_curveQuoteBacking() public {
        for (uint256 i; i < poolKeys.length; i++) {
            address curve = poolCurves[i];
            uint8 kind = ghosts.curveKind[curve];
            if (curve == address(0) || kind == CURVE_OTHER || _launchState(curve) != LS_ACTIVE) continue;
            uint256 quoteBal = _currencyBalance(poolKeys[i].currency0, curve);
            uint256 owed = _tryUint(curve, "realQuoteRaised()");
            if (kind == CURVE_TRANCHE) owed += _tryUint(curve, "totalSurchargeCollected()");
            gte(quoteBal, owed, "GL-05: curve quote balance < realQuoteRaised (+ surcharge)");
        }
    }

    /// @notice GL-06: poolClaims only decrease in a withdrawClaim call
    function property_GL06_claimsPullOnly() public {
        if (!_snapshotsValid() || ghosts.lastCallWasWithdraw) return;
        uint256 n = _commonPools();
        uint256 nCl = stateBefore.nClaimants;
        for (uint256 i; i < n; i++) {
            for (uint256 side; side < 2; side++) {
                for (uint256 a; a < nCl; a++) {
                    gte(
                        _snapClaim(stateAfter, i, side, a),
                        _snapClaim(stateBefore, i, side, a),
                        "GL-06: poolClaims decreased outside withdrawClaim"
                    );
                }
            }
        }
    }

    /// @notice GL-07: a non-zero enabled-blocks bitmap never changes
    function property_GL07_bitmapLocked() public {
        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        for (uint256 i; i < n; i++) {
            uint32 before_ = stateBefore.pools[i].bitmap;
            if (before_ != 0) eq(stateAfter.pools[i].bitmap, before_, "GL-07: registered pool bitmap changed");
        }
    }

    /// @notice GL-08: King rounds advance by at most one, only when expired with a king and a pot, and reset cleanly
    function property_GL08_kingRoundTransitions() public {
        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        bool nonSwapRoller = ghosts.lastCall == CallKind.FINALIZE_KING || ghosts.lastCall == CallKind.CLAIM_KING;
        for (uint256 i; i < n; i++) {
            PoolSnap storage b = stateBefore.pools[i];
            PoolSnap storage a = stateAfter.pools[i];
            gte(a.kRound, b.kRound, "GL-08: King roundId decreased");
            lte(a.kRound, uint256(b.kRound) + 1, "GL-08: King roundId rose by more than one in a call");

            // roundId 0 -> 1 is stack registration, not a roll
            if (b.kRound == 0 || a.kRound == b.kRound) continue;
            gte(stateAfter.timestamp, b.kDeadline, "GL-08: King round rolled before its deadline");
            t(b.kKing != address(0), "GL-08: King round rolled without a king");
            gt(b.kPot, 0, "GL-08: King round rolled with an empty pot");
            if (nonSwapRoller) {
                t(a.kKing == address(0), "GL-08: new round after finalize has a king");
                eq(a.kPot, 0, "GL-08: new round after finalize has a pot");
                gte(a.kDeadline, b.kDeadline, "GL-08: new round deadline earlier than the previous one");
            }
        }
    }

    /// @notice GL-09: launchState only moves forward and a graduated curve's accounting is frozen
    function property_GL09_launchLifecycle() public {
        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        for (uint256 i; i < n; i++) {
            if (poolCurves[i] == address(0)) continue;
            PoolSnap storage b = stateBefore.pools[i];
            PoolSnap storage a = stateAfter.pools[i];
            gte(a.launchState, b.launchState, "GL-09: launchState moved backwards");
            neq(a.launchState, 0, "GL-09: launch curve is Uninitialized");
            if (b.launchState != LS_GRADUATED) continue;
            eq(a.rqr, b.rqr, "GL-09: realQuoteRaised changed after graduation");
            eq(a.sold, b.sold, "GL-09: curveTokensSold changed after graduation");
            eq(a.vQ, b.vQ, "GL-09: virtualQuoteReserve changed after graduation");
            eq(a.vT, b.vT, "GL-09: virtualTokenReserve changed after graduation");
            eq(a.k, b.k, "GL-09: invariantK changed after graduation");
            eq(a.surch, b.surch, "GL-09: totalSurchargeCollected changed after graduation");
            gte(a.curvePosLiq, b.curvePosLiq, "GL-09: graduation LP position liquidity decreased");
        }
    }

    /// @notice GL-10: bonding curves stay below target with an uninitialized pool; graduated pools are initialized
    function property_GL10_atomicGraduation() public {
        for (uint256 i; i < poolKeys.length; i++) {
            address curve = poolCurves[i];
            uint8 kind = ghosts.curveKind[curve];
            if (curve == address(0) || kind == CURVE_OTHER) continue;
            (uint256 target, uint256 alloc,) = _curveTargets(curve, kind);
            uint256 rqr = _tryUint(curve, "realQuoteRaised()");
            uint8 state = _launchState(curve);
            (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolKeys[i].toId());

            lte(rqr, target, "GL-10: realQuoteRaised above graduationQuoteTarget");
            if (state == LS_ACTIVE) {
                lt(rqr, target, "GL-10: bonding curve reached target without graduating");
                lt(_tryUint(curve, "curveTokensSold()"), alloc, "GL-10: bonding curve sold out without graduating");
                eq(sqrtP, 0, "GL-10: launch pool initialized while still bonding");
            } else if (state == LS_GRADUATED) {
                neq(sqrtP, 0, "GL-10: graduated launch pool is not initialized");
            }
        }
    }

    /// @notice GL-11: graduated pool's initial price is within 1% of the curve's final marginal price
    function property_GL11_graduationPriceContinuity() public {
        for (uint256 i; i < poolKeys.length; i++) {
            address curve = poolCurves[i];
            uint8 kind = ghosts.curveKind[curve];
            if (curve == address(0) || kind == CURVE_OTHER || _launchState(curve) != LS_GRADUATED) continue;
            (,, uint256 lp) = _curveTargets(curve, kind);
            uint256 rqr = _tryUint(curve, "realQuoteRaised()");

            uint256 poolSide; // lp-token price expressed against the curve's marginal price
            uint256 curveSide;
            if (kind == CURVE_XYK) {
                // lp / rqr  vs  vT / vQ   ⇔   lp·vQ  vs  vT·rqr
                poolSide = lp * _tryUint(curve, "virtualQuoteReserve()");
                curveSide = _tryUint(curve, "virtualTokenReserve()") * rqr;
            } else {
                // lp / quoteToSeed  vs  2^96 / P   ⇔   lp·P  vs  quoteToSeed·2^96
                uint256 surch = _tryUint(curve, "totalSurchargeCollected()");
                (,,,,,,,,, uint16 kingBps) = SteppedTrancheLaunch(payable(curve)).trancheConfig();
                uint256 quoteToSeed = rqr + surch - (surch * kingBps) / 10_000;
                poolSide = lp * SteppedTrancheLaunch(payable(curve)).currentMarginalPriceQ96();
                curveSide = quoteToSeed << 96;
            }
            uint256 diff = poolSide > curveSide ? poolSide - curveSide : curveSide - poolSide;
            lte(diff * 100, curveSide, "GL-11: graduation price differs from final curve price by more than 1%");
        }
    }

    /// @notice GL-12: VirtualXYK reserve product never drops below invariantK
    function property_GL12_xykProductNonDecreasing() public {
        for (uint256 x; x < xykCurves.length; x++) {
            VirtualXYKLaunch curve = xykCurves[x];
            if (curve.launchState() == ITokenLaunchpad.LaunchState.Uninitialized) continue;
            gte(
                curve.virtualQuoteReserve() * curve.virtualTokenReserve(),
                curve.invariantK(),
                "GL-12: virtualQuoteReserve * virtualTokenReserve < invariantK"
            );
        }
    }

    /// @notice GL-13: virtualTokenReserve + curveTokensSold equals the configured virtual token reserve
    function property_GL13_xykTokenIdentity() public {
        for (uint256 x; x < xykCurves.length; x++) {
            VirtualXYKLaunch curve = xykCurves[x];
            (, uint128 cfgVT,,,,) = curve.curveConfig();
            eq(
                curve.virtualTokenReserve() + curve.curveTokensSold(),
                cfgVT,
                "GL-13: virtualTokenReserve + curveTokensSold != configured virtual token reserve"
            );
        }
    }

    /// @notice GL-14: virtualQuoteReserve equals the configured virtual quote reserve + realQuoteRaised
    function property_GL14_xykQuoteIdentity() public {
        for (uint256 x; x < xykCurves.length; x++) {
            VirtualXYKLaunch curve = xykCurves[x];
            (uint128 cfgVQ,,,,,) = curve.curveConfig();
            eq(
                curve.virtualQuoteReserve(),
                uint256(cfgVQ) + curve.realQuoteRaised(),
                "GL-14: virtualQuoteReserve != configured virtual quote reserve + realQuoteRaised"
            );
        }
    }

    /// @notice GL-15: tranche quote raised (+1 wei per buy) covers the integral of the price schedule over tokens sold
    function property_GL15_trancheScheduleFloor() public {
        for (uint256 x; x < trancheCurves.length; x++) {
            SteppedTrancheLaunch curve = trancheCurves[x];
            uint256 paidQ96 = (curve.realQuoteRaised() + ghosts.trancheBuys[address(curve)]) << 96;
            gte(
                paidQ96,
                _trancheCost(curve, curve.curveTokensSold()),
                "GL-15: tranche buys paid below the price schedule"
            );
        }
    }

    /// @notice GL-16: an open order whose target tick a hook-processed swap crossed in the filling direction is filled
    function property_GL16_crossedOrdersFilled() public {
        for (uint256 o; o < trackedOrders.length; o++) {
            TrackedOrder storage order = trackedOrders[o];
            // nativeOrderKey is never initialized, so it never crosses
            if (order.closed || !order.limitsEnabled || order.key.currency0.isAddressZero()) continue;
            int24 target = order.targetTick;
            // `processCrossedTicks` fills zeroForOne buckets on downward moves and oneForZero buckets on upward moves
            bool crossed = order.zeroForOne
                ? (order.placeTick > target && order.minTickSeen < target)
                : (order.placeTick < target && order.maxTickSeen > target);
            if (!crossed) continue;
            LimitOrdersLogic.LimitOrderBucket memory bucket =
                orchestrator.limitOrderBucket(order.key.toId(), target, order.zeroForOne);
            t(bucket.filled, "GL-16: limit order target tick crossed but bucket not filled");
        }
    }

    /// @notice GL-17: TWAMM streamed volume never exceeds submitted volume and sell rates drop expired orders
    function property_GL17_twammBounded() public {
        uint256 nP = poolKeys.length;
        uint256[] memory rate0 = new uint256[](nP);
        uint256[] memory rate1 = new uint256[](nP);
        for (uint256 o; o < ghosts.twammOrders.length; o++) {
            TwammOrder storage order = ghosts.twammOrders[o];
            if (order.cancelled || order.poolIdx >= nP || order.expiry <= block.timestamp) continue;
            if (order.zeroForOne) rate0[order.poolIdx] += order.rate;
            else rate1[order.poolIdx] += order.rate;
        }
        for (uint256 i; i < nP; i++) {
            PoolId pid = poolKeys[i].toId();
            TWAMMLogic.TWAMMState memory st = orchestrator.twammState(pid);
            lte(st.accruedVirtualVolume0, ghosts.twammSubmitted[pid][true], "GL-17: TWAMM volume0 streamed > submitted");
            lte(
                st.accruedVirtualVolume1, ghosts.twammSubmitted[pid][false], "GL-17: TWAMM volume1 streamed > submitted"
            );
            eq(st.sellRate0For1, rate0[i], "GL-17: sellRate0For1 != sum of unexpired order rates");
            eq(st.sellRate1For0, rate1[i], "GL-17: sellRate1For0 != sum of unexpired order rates");
        }
    }

    /// @notice GL-18: anti-snipe clock only starts at registration or graduation, and a decayed fee never rises again
    function property_GL18_antiSnipeNotRearmed() public {
        for (uint256 i; i < poolKeys.length; i++) {
            PoolId pid = poolKeys[i].toId();
            if (!ghosts.antiSnipeDecayed[pid]) continue;
            lte(
                orchestrator.antiSnipeFee(pid),
                orchestrator.antiSnipeState(pid).normalFee,
                "GL-18: decayed anti-snipe fee rose above normalFee"
            );
        }

        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        for (uint256 i; i < n; i++) {
            PoolSnap storage b = stateBefore.pools[i];
            PoolSnap storage a = stateAfter.pools[i];
            if (a.snipeStart == b.snipeStart) continue;
            bool registered = b.bitmap == 0 && a.bitmap != 0;
            bool graduated = b.launchState == LS_ACTIVE && a.launchState == LS_GRADUATED;
            t(registered || graduated, "GL-18: anti-snipe startBlock reset outside registration/graduation");
        }
    }

    /// @notice GL-19: oracle is frozen within a timestamp, moves at most 100 ticks per second, and stays in tick range
    function property_GL19_oracleBounds() public {
        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        uint256 dt = stateAfter.timestamp - stateBefore.timestamp;
        for (uint256 i; i < n; i++) {
            PoolSnap storage b = stateBefore.pools[i];
            PoolSnap storage a = stateAfter.pools[i];
            if ((a.bitmap & HookPermissionMasks.BIT_ORACLE) == 0) continue;
            gte(int256(a.oLast), int256(TickMath.MIN_TICK), "GL-19: oracle lastTick below MIN_TICK");
            lte(int256(a.oLast), int256(TickMath.MAX_TICK), "GL-19: oracle lastTick above MAX_TICK");
            if (b.sqrtP == 0) continue; // oracle initialized during this call

            if (dt == 0) {
                eq(int256(a.oLast), int256(b.oLast), "GL-19: oracle lastTick changed within one timestamp");
                eq(int256(a.oCum), int256(b.oCum), "GL-19: oracle tickCumulative changed within one timestamp");
                continue;
            }
            // Bound against the latest checkpoint time known to precede this call (a lower bound, so loose-safe)
            uint256 start = ghosts.oracleWindowStart[i];
            if (a.oLast == b.oLast || start == 0 || start > stateAfter.timestamp) continue;
            int256 move = int256(a.oLast) - int256(b.oLast);
            uint256 absMove = uint256(move >= 0 ? move : -move);
            lte(absMove, 100 * (stateAfter.timestamp - start), "GL-19: oracle lastTick moved > 100 ticks per second");
        }
    }

    /// @notice GL-20: each limit bucket's totalInputAmount equals the open tracked orders it holds
    function property_GL20_limitBucketSum() public {
        uint256 n = trackedOrders.length;
        bytes32[] memory pids = new bytes32[](n);
        for (uint256 o; o < n; o++) {
            if (!trackedOrders[o].closed) pids[o] = PoolId.unwrap(trackedOrders[o].key.toId());
        }
        for (uint256 o; o < n; o++) {
            TrackedOrder storage order = trackedOrders[o];
            if (order.closed) continue;
            bool seen;
            uint256 sum;
            for (uint256 j; j < n; j++) {
                TrackedOrder storage other = trackedOrders[j];
                if (
                    other.closed || pids[j] != pids[o] || other.targetTick != order.targetTick
                        || other.zeroForOne != order.zeroForOne
                ) continue;
                if (j < o) {
                    seen = true; // bucket already checked from an earlier order
                    break;
                }
                sum += other.inputAmount;
            }
            if (seen) continue;
            LimitOrdersLogic.LimitOrderBucket memory bucket =
                orchestrator.limitOrderBucket(PoolId.wrap(pids[o]), order.targetTick, order.zeroForOne);
            eq(bucket.totalInputAmount, sum, "GL-20: bucket totalInputAmount != sum of open orders");
        }
    }

    /// @notice GL-21: unregistered pools hold no hook state and per-block accumulators stay zero without their bit
    function property_GL21_bitmapGatedState() public {
        for (uint256 i; i < poolKeys.length; i++) {
            PoolKey memory key = poolKeys[i];
            PoolId pid = key.toId();
            uint32 bm = orchestrator.getPoolEnabledBlocks(pid);
            (uint64 round, address king, uint256 pot,) = orchestrator.getCurrentKing(pid);
            uint256 burned = orchestrator.totalAutoBurnedByPool(pid);
            uint256 donated = orchestrator.totalLPRewardsDonated(pid);
            uint256 points = orchestrator.totalPoolSwapPoints(pid);

            if (bm == 0) {
                for (uint256 a; a < claimants.length; a++) {
                    eq(
                        orchestrator.poolClaims(pid, key.currency0, claimants[a]),
                        0,
                        "GL-21: claims on unregistered pool"
                    );
                    eq(
                        orchestrator.poolClaims(pid, key.currency1, claimants[a]),
                        0,
                        "GL-21: claims on unregistered pool"
                    );
                }
                eq(round, 0, "GL-21: King round on unregistered pool");
                t(king == address(0), "GL-21: king on unregistered pool");
                eq(pot, 0, "GL-21: King pot on unregistered pool");
                eq(burned, 0, "GL-21: auto-burn on unregistered pool");
                eq(donated, 0, "GL-21: LP donations on unregistered pool");
                eq(points, 0, "GL-21: swap points on unregistered pool");
                continue;
            }
            if ((bm & HookPermissionMasks.BIT_AUTO_BURN) == 0) eq(burned, 0, "GL-21: burned without BIT_AUTO_BURN");
            uint32 donationBits = HookPermissionMasks.BIT_LP_REWARDS | HookPermissionMasks.BIT_ARB_RECAPTURE
                | HookPermissionMasks.BIT_AUTO_BUYBACK;
            if ((bm & donationBits) == 0) eq(donated, 0, "GL-21: LP donations without a donating block");
            if ((bm & HookPermissionMasks.BIT_SWAP_REWARDS) == 0) {
                eq(points, 0, "GL-21: swap points without BIT_SWAP_REWARDS");
            }
            if ((bm & HookPermissionMasks.BIT_KING_OF_THE_POOL) == 0) {
                t(king == address(0), "GL-21: king without BIT_KING_OF_THE_POOL");
                eq(pot, 0, "GL-21: King pot without BIT_KING_OF_THE_POOL");
            }
        }
    }

    /// @notice GL-22: allowlist entries and managed lpFee change only through their manager, within the fee cap
    function property_GL22_permissionedChanges() public {
        if (!_snapshotsValid()) return;
        uint256 n = _commonPools();
        uint256 nCl = stateBefore.nClaimants;
        for (uint256 i; i < n; i++) {
            for (uint256 a; a < nCl; a++) {
                if (stateAfter.allow[_allowIdx(stateAfter, i, a)] == stateBefore.allow[_allowIdx(stateBefore, i, a)]) {
                    continue;
                }
                t(ghosts.lastCall == CallKind.SET_ALLOWLIST, "GL-22: allowlist changed outside setAllowlistAccount");
                t(ghosts.lastCaller == ghosts.acManager[i], "GL-22: allowlist changed by a non-manager");
                t(ghosts.lastAccount == claimants[a], "GL-22: allowlist changed for a different account");
            }

            PoolSnap storage b = stateBefore.pools[i];
            PoolSnap storage s = stateAfter.pools[i];
            if (s.lpFee == b.lpFee || b.sqrtP == 0) continue; // fee set at pool initialization
            t(ghosts.lastCall == CallKind.SET_MANAGED_FEE, "GL-22: lpFee changed outside setManagedPoolFee");
            t(ghosts.lastCaller == ghosts.feeManager[i], "GL-22: lpFee changed by a non-manager");
            lte(s.lpFee, ghosts.feeCap[i], "GL-22: managed lpFee above feeCap");
        }
    }

    /// @notice GL-23: a bonding curve's project balance matches launch supply − sold + donations and can seed LP
    function property_GL23_curveTokenAccounting() public {
        for (uint256 i; i < poolKeys.length; i++) {
            address curve = poolCurves[i];
            uint8 kind = ghosts.curveKind[curve];
            if (curve == address(0) || kind == CURVE_OTHER || _launchState(curve) != LS_ACTIVE) continue;
            (, uint256 alloc, uint256 lp) = _curveTargets(curve, kind);
            uint256 sold = _tryUint(curve, "curveTokensSold()");
            uint256 bal = _currencyBalance(poolKeys[i].currency1, curve);
            eq(
                bal + sold,
                ghosts.initialCurveSupply[curve] + ghosts.tokensDonatedToCurve[curve],
                "GL-23: curve project balance != launch supply - sold + donated"
            );
            if (sold <= alloc) {
                gte(bal, (alloc - sold) + lp, "GL-23: curve cannot cover unsold allocation + LP reserve");
            }
        }
    }

    /// @notice GL-24: Σ totalAutoBurnedByPool per project token equals supply destroyed plus tokens sent to 0xdEaD
    /// @dev Every pool in this suite registers with `isToken0ProjectToken == false`, so the project currency is
    ///      `currency1` (the launchpad forces it, `LaunchpadFactory.sol:152`; fuzz/setup configs leave it unset).
    function property_GL24_autoBurnLedger() public {
        for (uint256 c; c < trackedCurrencies.length; c++) {
            Currency currency = trackedCurrencies[c];
            uint256 burnedSum;
            for (uint256 i; i < poolKeys.length; i++) {
                if (poolKeys[i].currency1 == currency) {
                    burnedSum += orchestrator.totalAutoBurnedByPool(poolKeys[i].toId());
                }
            }
            uint256 supply = _tryUint(Currency.unwrap(currency), "totalSupply()");
            uint256 dead = _currencyBalance(currency, DEAD);
            eq(
                burnedSum + supply,
                ghosts.initialSupply[currency] + dead,
                "GL-24: auto-burn ledger != supply destroyed + dead balance"
            );
        }
    }

    /// @notice GL-25: on a bonding curve with unsold allocation, a reasonable buy returns a non-zero token amount
    function property_GL25_reasonableBuyNonZero() public {
        for (uint256 i; i < poolKeys.length; i++) {
            address curve = poolCurves[i];
            uint8 kind = ghosts.curveKind[curve];
            if (curve == address(0) || kind == CURVE_OTHER || _launchState(curve) != LS_ACTIVE) continue;
            (uint256 target, uint256 alloc,) = _curveTargets(curve, kind);
            uint256 rqr = _tryUint(curve, "realQuoteRaised()");
            uint256 sold = _tryUint(curve, "curveTokensSold()");
            if (sold >= alloc || rqr >= target) continue;
            uint256 q = target - rqr < 1e18 ? target - rqr : 1e18;
            // A remaining gap below 1 gwei is not a "reasonable" buy: Ceil surcharge rounding can consume it entirely
            if (q < 1e9) continue;
            gt(_closedFormTokensOut(curve, kind, q, alloc - sold), 0, "GL-25: reasonable curve buy returns zero tokens");
        }
    }

    /// @notice GL-26: a graduated curve holds at most dust of project and quote tokens
    function property_GL26_noStrandedCurveValue() public {
        for (uint256 i; i < poolKeys.length; i++) {
            address curve = poolCurves[i];
            uint8 kind = ghosts.curveKind[curve];
            if (curve == address(0) || kind == CURVE_OTHER || _launchState(curve) != LS_GRADUATED) continue;
            (,, uint256 lp) = _curveTargets(curve, kind);
            uint256 rqr = _tryUint(curve, "realQuoteRaised()");
            lte(
                _currencyBalance(poolKeys[i].currency1, curve),
                lp / 10_000 + 1,
                "GL-26: project tokens stranded in graduated curve"
            );
            lte(
                _currencyBalance(poolKeys[i].currency0, curve),
                rqr / 10_000 + 1,
                "GL-26: quote stranded in graduated curve"
            );
        }
    }

    // ――――――――――――――――――― Specific properties ――――――――――――――――――――
    // These properties must hold after specific function calls.
    // They MUST BE INTERNAL and called at the end of the relevant handlers.

    /// @notice Value allowed to leak in favour of the actor in the JIT buyback snipe (SP-24), in quote units.
    uint256 internal constant SP24_DUST = 1e12;

    /// @notice One `withdrawClaim` call (SP-01). Index fields are `type(uint256).max` when unknown to the suite.
    struct WithdrawObs {
        uint256 poolIdx;
        uint256 side;
        uint256 claimantIdx;
        uint256 amount;
        uint256 claimBefore;
        uint256 claimAfter;
        uint256 hook6909Before;
        uint256 hook6909After;
        address to;
        uint256 toBefore;
        uint256 toAfter;
    }

    /// @notice One successful `claimKingPot` call (SP-02); `settled` is read before the call.
    struct KingClaimObs {
        PoolId pid;
        uint64 roundId;
        address caller;
        address to;
        KingOfThePoolLogic.SettledKingRound settled;
        bool ghostClaimed;
        uint256 cur6909Before;
        uint256 cur6909After;
        uint256 toBefore;
        uint256 toAfter;
    }

    /// @notice Pre-state and results of one VirtualXYK buy (SP-12).
    struct XykBuyObs {
        uint256 qIn;
        uint256 x;
        uint256 y;
        uint256 k;
        uint256 rqr;
        uint256 sold;
        uint256 target;
        uint256 alloc;
        uint256 usedRet;
        uint256 outRet;
        uint256 payerDebit;
        uint256 recipientCredit;
        bool checkCredit;
    }

    /// @notice Pre-state and results of one VirtualXYK sell (SP-12).
    struct XykSellObs {
        uint256 tIn;
        uint256 x;
        uint256 y;
        uint256 k;
        uint256 rqr;
        uint256 outRet;
        uint256 recipientCredit;
        bool checkCredit;
    }

    /// @notice Pre/post state and results of one SteppedTranche buy (SP-13, SP-27).
    struct TrancheBuyObs {
        uint256 qIn;
        uint256 bps;
        uint256 price;
        uint256 rqrBefore;
        uint256 rqrAfter;
        uint256 surchBefore;
        uint256 surchAfter;
        uint256 sold;
        uint256 target;
        uint256 alloc;
        uint256 outRet;
        uint256 surRet;
        uint256 payerDebit;
        uint256 recipientCredit;
        bool checkCredit;
        bool graduated;
    }

    /// @notice Pre-state and results of one SteppedTranche sell (SP-13).
    struct TrancheSellObs {
        uint256 tIn;
        uint256 base;
        uint256 rqr;
        uint256 sold;
        uint256 outRet;
        uint256 recipientCredit;
        bool checkCredit;
    }

    /// @notice Actor and curve values around a curve buy → sell round trip (SP-05, SP-06).
    struct CurveRoundTrip {
        uint256 quoteBefore;
        uint256 quoteAfter;
        uint256 projBefore;
        uint256 projAfter;
        uint256 raisedBefore; // realQuoteRaised (+ totalSurchargeCollected for Tranche)
        uint256 raisedAfter;
    }

    /// @notice SP-01: withdrawClaim lowers the claim and hook ERC-6909 by exactly `amount`, pays `to` exactly, touches nothing else
    function property_SP01_withdrawClaimExact(WithdrawObs memory w) internal {
        eq(w.claimAfter + w.amount, w.claimBefore, "SP-01: claim did not fall by exactly the withdrawn amount");
        eq(w.hook6909After + w.amount, w.hook6909Before, "SP-01: hook ERC-6909 did not fall by exactly the amount");
        if (w.to != address(poolManager)) {
            eq(w.toAfter, w.toBefore + w.amount, "SP-01: recipient did not receive exactly the withdrawn amount");
        }
        uint256 n = _commonPools();
        uint256 nCl = stateBefore.nClaimants;
        for (uint256 i; i < n; i++) {
            for (uint256 side; side < 2; side++) {
                for (uint256 a; a < nCl; a++) {
                    if (i == w.poolIdx && side == w.side && a == w.claimantIdx) continue;
                    eq(
                        _snapClaim(stateAfter, i, side, a),
                        _snapClaim(stateBefore, i, side, a),
                        "SP-01: withdrawClaim changed another (pool, currency, account) claim"
                    );
                }
            }
        }
    }

    /// @notice SP-01: a claimant withdrawing their full claim balance never reverts
    function property_SP01_fullWithdrawLive(bool ok) internal {
        t(ok, "SP-01: full-balance withdrawClaim reverted");
    }

    /// @notice SP-02: a King payout comes from the winner, pays exactly the settled amount once, in a single currency
    function property_SP02_kingPayoutExact(KingClaimObs memory k) internal {
        t(k.caller == k.settled.winner, "SP-02: King pot claimed by someone other than the round winner");
        t(!k.settled.claimed && !k.ghostClaimed, "SP-02: King round paid out twice");
        eq(
            k.cur6909After + k.settled.amount,
            k.cur6909Before,
            "SP-02: hook ERC-6909 did not fall by the settled amount"
        );
        if (k.to != address(poolManager)) {
            eq(k.toAfter, k.toBefore + k.settled.amount, "SP-02: King payout recipient not paid the settled amount");
        }
        uint256 nC = stateBefore.nCurrencies < stateAfter.nCurrencies ? stateBefore.nCurrencies : stateAfter.nCurrencies;
        for (uint256 c; c < nC; c++) {
            if (trackedCurrencies[c] == k.settled.currency) continue;
            eq(stateAfter.hook6909[c], stateBefore.hook6909[c], "SP-02: King payout moved another currency's ERC-6909");
        }
    }

    /// @notice SP-02: the recorded winner of an unclaimed, non-empty settled round can always claim it
    function property_SP02_winnerClaimLive(bool ok) internal {
        t(ok, "SP-02: winner claim of an unclaimed settled King round reverted");
    }

    /// @notice SP-03: placing a limit order escrows exactly inputAmount: hook +inputAmount, maker -inputAmount
    function property_SP03_limitOrderPlaceEscrow(uint256 hookDelta, uint256 paid, uint256 inputAmount) internal {
        eq(hookDelta, inputAmount, "SP-03: hook input-currency balance did not rise by inputAmount");
        eq(paid, inputAmount, "SP-03: maker input-currency balance did not fall by inputAmount");
    }

    /// @notice SP-03: cancel / claim refunds the maker at most what it paid (exactly, for an ERC-20 cancel)
    function property_SP03_limitOrderRefundBounded(uint256 refund, uint256 paid, bool exact) internal {
        lte(refund, paid, "SP-03: limit-order refund above what the maker escrowed");
        if (exact) eq(refund, paid, "SP-03: ERC-20 limit-order cancel did not refund exactly the escrow");
    }

    /// @notice SP-03: an honest maker's cancel / claim only reverts with the bucket-state error
    function property_SP03_honestSettleRevert(bytes4 sel, bytes4 allowed) internal {
        t(sel == allowed, "SP-03: honest limit-order cancel/claim reverted with an unexpected error");
    }

    /// @notice SP-04: an A → B → A exact-input round trip on a pool never returns more A (incl. own claims) and leaves B unchanged
    function property_SP04_swapRoundTrip(
        uint256 balABefore,
        uint256 balAAfter,
        uint256 claimsGainedA,
        uint256 balBBefore,
        uint256 balBAfter
    ) internal {
        lte(balAAfter + claimsGainedA, balABefore, "SP-04: pool swap round trip returned more than it spent");
        eq(balBAfter, balBBefore, "SP-04: pool swap round trip changed the intermediate balance");
    }

    /// @notice SP-05: a curve buy followed by selling everything bought never profits and never lowers realQuoteRaised
    function property_SP05_curveRoundTrip(CurveRoundTrip memory r) internal {
        lte(r.quoteAfter, r.quoteBefore, "SP-05: curve buy/sell round trip returned more quote than spent");
        eq(r.projAfter, r.projBefore, "SP-05: curve buy/sell round trip changed the project balance");
        gte(r.raisedAfter, r.raisedBefore, "SP-05: curve buy/sell round trip lowered realQuoteRaised (+ surcharge)");
    }

    /// @notice SP-06: N dust buy → sell cycles on a curve never raise the actor's quote and never lower realQuoteRaised
    function property_SP06_curveDustCycle(CurveRoundTrip memory r) internal {
        lte(r.quoteAfter, r.quoteBefore, "SP-06: curve dust cycles returned more quote than spent");
        gte(r.raisedAfter, r.raisedBefore, "SP-06: curve dust cycles lowered realQuoteRaised (+ surcharge)");
    }

    /// @notice SP-07: a target-reaching curve buy graduates the curve; only the curve wallet-cap error may revert it
    function property_SP07_graduationLiveness(bool reverted, bytes4 sel, bytes4 walletCapSel, address curve, uint256 i)
        internal
    {
        if (reverted) {
            t(sel == walletCapSel, "SP-07: target-reaching curve buy reverted (graduation must never revert)");
            return;
        }
        eq(_launchState(curve), LS_GRADUATED, "SP-07: target-reaching buy did not graduate the curve");
        (uint160 sqrtP,,,) = StateLibrary.getSlot0(poolManager, poolKeys[i].toId());
        neq(sqrtP, 0, "SP-07: graduated launch pool is not initialized");
    }

    /// @notice SP-08: the graduating call initializes the pool, locks full-range LP, touches no other pool, conserves the Tranche seed
    function property_SP08_graduationPostconditions(uint256 i, bool tranche, uint256 seed) internal {
        PoolSnap storage b = stateBefore.pools[i];
        PoolSnap storage a = stateAfter.pools[i];
        neq(a.sqrtP, 0, "SP-08: graduated pool not initialized");
        gt(a.curvePosLiq, 0, "SP-08: graduation full-range position has no liquidity");
        t(_otherPoolsUnchanged(i), "SP-08: graduation changed another pool's state");
        if (!tranche) return;
        uint256 c0 = _currencyIdx(poolKeys[i].currency0);
        eq(stateAfter.hook6909[c0], stateBefore.hook6909[c0] + seed, "SP-08: hook ERC-6909 currency0 rise != King seed");
        int256 potUp = int256(a.kPot) - int256(b.kPot);
        eq(potUp + _claimsDelta(i, 0), int256(seed), "SP-08: King pot + poolAdmin claim increase != King seed");
    }

    /// @notice SP-09: per swap, the hook ERC-6909 delta in a pool currency equals claims + King pot + buyback-reserve deltas
    /// @param uSide unspecified side (0 / 1) of a single swap, or 2 to check both sides (round trips)
    function property_SP09_swapDeltaIdentity(uint256 i, uint256 uSide) internal {
        for (uint256 side; side < 2; side++) {
            (int256 d6909, int256 rhs) = _swapIdentityTerms(i, side);
            if (uSide == 2 || side == uSide) {
                eq(d6909, rhs, "SP-09: hook ERC-6909 delta != claims + King pot + buyback reserve delta");
            } else {
                eq(d6909, 0, "SP-09: swap moved the hook's ERC-6909 of the specified currency");
            }
        }
        if (uSide == 2) return;
        PoolSnap storage b = stateBefore.pools[i];
        PoolSnap storage a = stateAfter.pools[i];
        if (a.bbReserve[uSide] < b.bbReserve[uSide]) {
            eq(a.bbReserve[uSide], 0, "SP-09: buyback reserve dropped without resetting to zero");
            gte(a.lpDonated, b.lpDonated + b.bbReserve[uSide], "SP-09: deployed buyback reserve not donated to LPs");
        }
    }

    /// @notice SP-10: an exact-input swap's aggregate cut stays within floor(25% of the gross output)
    function property_SP10_aggregateCutCap(uint256 i, uint256 uSide, uint256 net) internal {
        int256 withheld = _withheld(i, uSide);
        if (withheld <= 0) return;
        uint256 w = uint256(withheld);
        lte(w, (net + w) * 2500 / 10_000, "SP-10: aggregate after-swap cut above floor(25% of gross)");
    }

    /// @notice SP-11: on a POOL_XYK exact-output sell the tax slice is ceilDiv(grossIn * sellTaxBps, 1e4)
    function property_SP11_exactOutputCeil(uint256 projectPaid) internal {
        uint256 sellBps = ghosts.cfgBps[POOL_XYK][1];
        if (sellBps == 0) return;
        uint256 taxIdx = _claimantIdx(actors[1]);
        uint256 b = _snapClaim(stateBefore, POOL_XYK, 1, taxIdx);
        uint256 a = _snapClaim(stateAfter, POOL_XYK, 1, taxIdx);
        if (a < b || projectPaid < a - b) return;
        uint256 withheld = a - b;
        uint256 grossIn = projectPaid - withheld;
        eq(withheld, (grossIn * sellBps + 9999) / 10_000, "SP-11: exact-output sell tax not rounded up (Ceil)");
    }

    /// @notice SP-12: a VirtualXYK buy charges min(qIn, target - rqr) and pays min(Y - ceil(k / (X + used)), alloc - sold)
    function property_SP12_xykBuyModel(XykBuyObs memory o) internal {
        uint256 remaining = o.target > o.rqr ? o.target - o.rqr : 0;
        uint256 used = o.qIn < remaining ? o.qIn : remaining;
        eq(o.usedRet, used, "SP-12: XYK quoteUsed != min(quoteIn, target - realQuoteRaised)");
        eq(o.payerDebit, used, "SP-12: XYK buyer debited a different amount than quoteUsed");
        uint256 newY = _ceilDiv(o.k, o.x + used);
        uint256 out = o.y > newY ? o.y - newY : 0;
        uint256 left = o.alloc > o.sold ? o.alloc - o.sold : 0;
        if (out > left) out = left;
        eq(o.outRet, out, "SP-12: XYK tokensOut != min(Y - ceil(k / (X + used)), allocation - sold)");
        if (o.checkCredit) eq(o.recipientCredit, out, "SP-12: XYK buy recipient credit != tokensOut");
    }

    /// @notice SP-12: a VirtualXYK sell pays min(max(X - ceil(k / (Y + t)), 0), realQuoteRaised)
    function property_SP12_xykSellModel(XykSellObs memory o) internal {
        uint256 newX = _ceilDiv(o.k, o.y + o.tIn);
        uint256 out = o.x > newX ? o.x - newX : 0;
        if (out > o.rqr) out = o.rqr;
        eq(o.outRet, out, "SP-12: XYK quoteOut != min(X - ceil(k / (Y + t)), realQuoteRaised)");
        if (o.checkCredit) eq(o.recipientCredit, out, "SP-12: XYK sell recipient credit != quoteOut");
    }

    /// @notice SP-13: a SteppedTranche buy matches the Ceil surcharge / Floor tokens rounding model
    function property_SP13_trancheBuyModel(TrancheBuyObs memory o) internal {
        uint256 used = _trancheQuoteUsed(o);
        eq(o.payerDebit, used, "SP-13: tranche buyer debited a different amount than quoteUsed");
        uint256 sur = (used * o.bps + 9999) / 10_000;
        eq(o.surRet, sur, "SP-13: tranche surcharge != ceil(quoteUsed * bps / 1e4)");
        eq(o.surchAfter, o.surchBefore + sur, "SP-13: totalSurchargeCollected did not rise by the surcharge");
        uint256 out = ((used - sur) << 96) / o.price;
        uint256 left = o.alloc > o.sold ? o.alloc - o.sold : 0;
        if (out > left) out = left;
        eq(o.outRet, out, "SP-13: tranche tokensOut != min(floor(net * 2^96 / P), allocation - sold)");
        if (o.checkCredit) eq(o.recipientCredit, out, "SP-13: tranche buy recipient credit != tokensOut");
        if (!o.graduated) eq(o.rqrAfter, o.rqrBefore + used - sur, "SP-13: realQuoteRaised did not rise by net quote");
    }

    /// @notice SP-13: a SteppedTranche sell pays min(floor(t * base / 2^96), floor(rqr * t / sold), rqr)
    function property_SP13_trancheSellModel(TrancheSellObs memory o) internal {
        uint256 baseR = (o.tIn * o.base) >> 96;
        uint256 proRata = o.sold > 0 ? (o.rqr * o.tIn) / o.sold : 0;
        uint256 out = baseR < proRata ? baseR : proRata;
        if (out > o.rqr) out = o.rqr;
        eq(o.outRet, out, "SP-13: tranche quoteOut != min(base redemption, pro-rata, realQuoteRaised)");
        if (o.checkCredit) eq(o.recipientCredit, out, "SP-13: tranche sell recipient credit != quoteOut");
    }

    /// @notice SP-14: a swap on pool i leaves every other pool's claims, King state and accumulators unchanged
    function property_SP14_swapIsolation(uint256 i) internal {
        t(_otherPoolsUnchanged(i), "SP-14: swap changed another pool's claims, King state or accumulators");
    }

    /// @notice SP-15: a successful swap / add on an AccessControl pool implies the paying actor is allowlisted
    function property_SP15_accessControlNoSpoof(uint256 i, bool isAdd) internal {
        PoolId pid = poolKeys[i].toId();
        if ((orchestrator.getPoolEnabledBlocks(pid) & HookPermissionMasks.BIT_ACCESS_CONTROL) == 0) return;
        if ((ghosts.acChecks[i] & (isAdd ? 2 : 1)) == 0 || ghosts.merkleRootSet[i]) return;
        t(orchestrator.isAccountAllowlisted(pid, actor), "SP-15: non-allowlisted actor passed AccessControl");
    }

    /// @notice SP-16: a successful removal happens at least minHold blocks after the position's last add
    function property_SP16_jitHoldNoBypass(uint256 i, bytes32 positionKey) internal {
        uint32 bm = orchestrator.getPoolEnabledBlocks(poolKeys[i].toId());
        if ((bm & (HookPermissionMasks.BIT_MEV_PROTECTION | HookPermissionMasks.BIT_JIT_GUARD)) == 0) return;
        uint256 added = ghosts.lpAddBlock[i][positionKey];
        if (added == 0) return;
        gte(block.number, added + ghosts.minHold[i], "SP-16: liquidity removed before the JIT hold expired");
    }

    /// @notice SP-17: an actor never sells more than maxDailySellBps of its own start-of-epoch balance in one epoch
    function property_SP17_vestingCapNoBypass(PoolId pid, address seller, uint256 epoch, uint16 maxBps) internal {
        uint256 cap = (ghosts.epochStartBal[pid][seller][epoch] * maxBps) / 10_000;
        lte(ghosts.soldInEpoch[pid][seller][epoch], cap, "SP-17: actor sold above maxDailySellBps of its epoch balance");
    }

    /// @notice SP-18: an honest fresh-epoch trusted-route sell within the cap never reverts with DailyVestingSellCapExceeded
    function property_SP18_vestingCapNoGrief(bytes4 innerSel) internal {
        t(
            innerSel != VestingSellCapLogic.DailyVestingSellCapExceeded.selector,
            "SP-18: honest in-cap sell blocked by DailyVestingSellCapExceeded"
        );
    }

    /// @notice SP-19: a non-launchpad registerPoolStack only succeeds on a not-yet-initialized pool
    function property_SP19_noRetroRegistration(uint160 sqrtPriceBefore) internal {
        eq(sqrtPriceBefore, 0, "SP-19: stack registered on an already-initialized pool");
    }

    /// @notice SP-20: a hook call on a live oracle pool after >= 1 s with a non-zero clamped tick checkpoints the oracle
    function property_SP20_oracleCheckpointLiveness(uint256 i, uint256 prevTouch) internal {
        PoolSnap storage b = stateBefore.pools[i];
        PoolSnap storage a = stateAfter.pools[i];
        if ((b.bitmap & HookPermissionMasks.BIT_ORACLE) == 0 || b.sqrtP == 0) return;
        if (stateAfter.timestamp <= prevTouch || b.tick == 0) return;
        int256 diff = int256(b.tick) - int256(b.oLast);
        uint256 absDiff = uint256(diff >= 0 ? diff : -diff);
        // Only when the clamp cannot bind: then the checkpointed tick is the (non-zero) pre-call tick
        if (absDiff > 100 * (stateAfter.timestamp - prevTouch)) return;
        t(a.oLast != b.oLast || a.oCum != b.oCum, "SP-20: live oracle pool not checkpointed after time passed");
    }

    /// @notice SP-21: removing a full position with the identity that added it, after the hold, never reverts
    function property_SP21_lpExitLiveness(bool ok) internal {
        t(ok, "SP-21: full LP exit after the hold reverted");
    }

    /// @notice SP-22: on an ActiveBonding curve a full-balance sell (minQuoteOut 0) never reverts
    function property_SP22_curveExitLiveness(bool ok) internal {
        t(ok, "SP-22: full-balance curve sell reverted before graduation");
    }

    /// @notice SP-23: privileged setters / curve hooks only succeed for the manager, owner or authorized curve
    function property_SP23_noPrivilegeEscalation(bool authorized, string memory reason) internal {
        t(authorized, reason);
    }

    /// @notice SP-24: an atomic JIT add → floor-breaking swap → remove → swap back does not capture donated value
    function property_SP24_noJitDonationCapture(uint256 valueBefore, uint256 valueAfter) internal {
        lte(valueAfter, valueBefore + SP24_DUST, "SP-24: JIT LP captured buyback/LP donations in one sequence");
    }

    /// @notice SP-25: after a successful buy under an active WalletCap the actor holds at most maxWalletBps of supply
    function property_SP25_walletCapNoBypass(uint256 i) internal {
        PoolId pid = poolKeys[i].toId();
        if ((orchestrator.getPoolEnabledBlocks(pid) & HookPermissionMasks.BIT_WALLET_CAP) == 0) return;
        IHookRigBlock.WalletCapParams memory cfg = ghosts.walletCapCfg[i];
        if (cfg.maxWalletBps == 0 || cfg.maxWalletBps >= 10_000) return;
        if (cfg.sunsetBlocks > 0 && block.number >= ghosts.registeredAtBlock[i] + cfg.sunsetBlocks) return;
        Currency proj = poolKeys[i].currency1;
        uint256 supply = _tryUint(Currency.unwrap(proj), "totalSupply()");
        if (supply == 0) return;
        lte(
            _currencyBalance(proj, actor),
            (supply * cfg.maxWalletBps) / 10_000,
            "SP-25: actor above WalletCap after a buy"
        );
    }

    /// @notice SP-26: claims credited by an exact-input swap are at most the floored tax + fee-share + referral slices
    function property_SP26_claimSlicesFloored(uint256 i, uint256 uSide, uint256 gross, bool isBuy) internal {
        uint16[4] memory bps = ghosts.cfgBps[i];
        uint256 bound =
            (gross * (isBuy ? bps[0] : bps[1])) / 10_000 + (gross * bps[2]) / 10_000 + (gross * bps[3]) / 10_000;
        lte(uint256(_claimsDelta(i, uSide)), bound, "SP-26: claims credited above the floored claim slices");
        if (i != POOL_MULTI) return;
        uint256 tIdx = _claimantIdx(TREASURY);
        uint256 pIdx = _claimantIdx(actors[2]);
        uint256 dTreasury = _snapClaim(stateAfter, i, uSide, tIdx) - _snapClaim(stateBefore, i, uSide, tIdx);
        uint256 dPrimary = _snapClaim(stateAfter, i, uSide, pIdx) - _snapClaim(stateBefore, i, uSide, pIdx);
        lte(dTreasury, (((gross * 200) / 10_000) * 2500) / 10_000, "SP-26: fee-share secondary slice not floored");
        gte(dPrimary, 3 * dTreasury, "SP-26: fee-share primary slice below 3x the secondary slice");
    }

    /// @notice SP-27: an XYK buy leaves only Ceil rounding in the product (vQ * vT < k + vQ)
    function property_SP27_noUndeliveredChargeXYK(VirtualXYKLaunch curve) internal {
        uint256 vQ = curve.virtualQuoteReserve();
        lt(vQ * curve.virtualTokenReserve(), curve.invariantK() + vQ, "SP-27: XYK buyer charged for undelivered tokens");
    }

    /// @notice SP-27: a Tranche buy delivers floor(net * 2^96 / P) tokens (net * 2^96 <= (out + 1) * P)
    function property_SP27_noUndeliveredChargeTranche(uint256 net, uint256 out, uint256 priceBefore) internal {
        lte(net << 96, (out + 1) * priceBefore, "SP-27: tranche buyer charged for undelivered tokens");
    }

    /// @notice SP-28: claiming a filled limit order raises the maker's output-currency balance
    function property_SP28_filledOrderPaysOutput(uint256 outBefore, uint256 outAfter) internal {
        gt(outAfter, outBefore, "SP-28: filled limit order claim paid no output currency");
    }

    /// @notice SP-29: adding then removing the same liquidity on a fresh position never returns more of either token
    function property_SP29_lpRoundTrip(uint256 b0, uint256 a0, uint256 b1, uint256 a1) internal {
        lte(a0, b0, "SP-29: LP round trip returned more currency0 than deposited");
        lte(a1, b1, "SP-29: LP round trip returned more currency1 than deposited");
    }

    /// @notice SP-30: a free max-size TWAMM / native limit order does not block an honest small order
    function property_SP30_accumulatorGrief(uint8 status, string memory reason) internal {
        t(status != PROBE_HONEST_FAILED, reason);
    }

    // ――――――――――――――――――― Specific-property helpers ――――――――――――――――――

    uint8 internal constant PROBE_ATTACK_FAILED = 0;
    uint8 internal constant PROBE_HONEST_OK = 1;
    uint8 internal constant PROBE_HONEST_FAILED = 2;

    /// @notice First 4 bytes of revert data, unwrapping v4 `WrappedError` (hook reverts) to the inner selector.
    function _revertSelector(bytes memory err) internal pure returns (bytes4 sel) {
        if (err.length < 4) return bytes4(0);
        sel = bytes4(err);
        if (sel == CustomRevert.WrappedError.selector && err.length > 4) {
            bytes memory body = new bytes(err.length - 4);
            for (uint256 j; j < body.length; j++) {
                body[j] = err[j + 4];
            }
            (,, bytes memory reason,) = abi.decode(body, (address, bytes4, bytes, bytes));
            return _revertSelector(reason);
        }
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return a == 0 ? 0 : (a - 1) / b + 1;
    }

    /// @notice Index of `account` in `claimants` (`type(uint256).max` if absent).
    function _claimantIdx(address account) internal view returns (uint256) {
        for (uint256 a; a < claimants.length; a++) {
            if (claimants[a] == account) return a;
        }
        return type(uint256).max;
    }

    /// @notice Σ over claimants of the claim change on (pool i, side) between the snapshots.
    function _claimsDelta(uint256 i, uint256 side) internal view returns (int256 delta) {
        uint256 nCl = stateBefore.nClaimants;
        for (uint256 a; a < nCl; a++) {
            delta += int256(_snapClaim(stateAfter, i, side, a)) - int256(_snapClaim(stateBefore, i, side, a));
        }
    }

    /// @notice King pot added in `currency` on pool i between the snapshots (post-roll pot counts in full).
    function _kingAddedIn(uint256 i, Currency currency) internal view returns (int256) {
        PoolSnap storage b = stateBefore.pools[i];
        PoolSnap storage a = stateAfter.pools[i];
        if (!(a.potCurrency == currency)) return 0;
        if (a.kRound != b.kRound) return int256(a.kPot);
        return int256(a.kPot) - int256(b.kPot);
    }

    /// @notice (Δ hook ERC-6909, Δ claims + King pot added + Δ buyback reserve) for one side of pool i.
    function _swapIdentityTerms(uint256 i, uint256 side) internal view returns (int256 d6909, int256 rhs) {
        Currency currency = side == 0 ? poolKeys[i].currency0 : poolKeys[i].currency1;
        uint256 c = _currencyIdx(currency);
        if (c >= stateBefore.nCurrencies) return (0, 0);
        d6909 = int256(stateAfter.hook6909[c]) - int256(stateBefore.hook6909[c]);
        PoolSnap storage b = stateBefore.pools[i];
        PoolSnap storage a = stateAfter.pools[i];
        rhs = _claimsDelta(i, side) + _kingAddedIn(i, currency) + int256(a.bbReserve[side]) - int256(b.bbReserve[side]);
    }

    /// @notice Amount withheld from a single swap's unspecified side: Δ hook ERC-6909 + Δ burned + Δ LP donations.
    function _withheld(uint256 i, uint256 uSide) internal view returns (int256) {
        (int256 d6909,) = _swapIdentityTerms(i, uSide);
        PoolSnap storage b = stateBefore.pools[i];
        PoolSnap storage a = stateAfter.pools[i];
        return d6909 + int256(a.burned) - int256(b.burned) + int256(a.lpDonated) - int256(b.lpDonated);
    }

    /// @notice True when no pool other than `skip` changed claims, King round/pot or swap accumulators.
    function _otherPoolsUnchanged(uint256 skip) internal view returns (bool) {
        uint256 n = _commonPools();
        uint256 nCl = stateBefore.nClaimants;
        for (uint256 j; j < n; j++) {
            if (j == skip) continue;
            PoolSnap storage b = stateBefore.pools[j];
            PoolSnap storage a = stateAfter.pools[j];
            if (a.kRound != b.kRound || a.kPot != b.kPot || a.lpDonated != b.lpDonated) return false;
            if (a.burned != b.burned || a.poolPoints != b.poolPoints) return false;
            for (uint256 side; side < 2; side++) {
                for (uint256 c; c < nCl; c++) {
                    if (_snapClaim(stateAfter, j, side, c) != _snapClaim(stateBefore, j, side, c)) return false;
                }
            }
        }
        return true;
    }

    /// @notice Index of the pool whose launch curve is `curve` (`type(uint256).max` if none).
    function _poolIdxOfCurve(address curve) internal view returns (uint256) {
        for (uint256 i; i < poolCurves.length; i++) {
            if (poolCurves[i] == curve) return i;
        }
        return type(uint256).max;
    }

    /// @notice Index of the tracked pool with id `pid`.
    function _findPoolIdx(PoolId pid) internal view returns (bool found, uint256 idx) {
        for (uint256 i; i < poolKeys.length; i++) {
            if (PoolId.unwrap(poolKeys[i].toId()) == PoolId.unwrap(pid)) return (true, i);
        }
    }

    /// @notice SP-08 hook for curve buy handlers: runs only when this call flipped pool i to Graduated.
    function _checkGraduation(uint256 i) internal {
        if (i >= _commonPools()) return;
        if (stateBefore.pools[i].launchState != LS_ACTIVE || stateAfter.pools[i].launchState != LS_GRADUATED) return;
        ghosts.lastOracleTouch[i] = block.timestamp; // the pool's oracle (if any) initialized now
        address curve = poolCurves[i];
        bool tranche = ghosts.curveKind[curve] == CURVE_TRANCHE;
        uint256 seed;
        if (tranche) {
            (,,,,,,,,, uint16 kingBps) = SteppedTrancheLaunch(payable(curve)).trancheConfig();
            seed = (stateAfter.pools[i].surch * kingBps) / 10_000;
        }
        property_SP08_graduationPostconditions(i, tranche, seed);
    }

    /// @notice quoteUsed a SteppedTranche buy charges (`SteppedTrancheLaunch.buy` cap-at-target formula).
    function _trancheQuoteUsed(TrancheBuyObs memory o) internal pure returns (uint256) {
        uint256 remaining = o.target > o.rqrBefore ? o.target - o.rqrBefore : 0;
        uint256 maxGross = o.bps < 10_000 ? _ceilDiv(remaining * 10_000, 10_000 - o.bps) : o.qIn;
        return o.qIn > maxGross && maxGross > 0 ? maxGross : o.qIn;
    }

    // ――――――――――――――――――――――――― Helpers ――――――――――――――――――――――――――

    function _hook6909(Currency currency) internal view returns (uint256) {
        return poolManager.balanceOf(address(orchestrator), currency.toId());
    }

    /// @notice Per tracked currency: Σ poolClaims and (if `full`) every other liability backed by hook ERC-6909.
    function _hookLiabilities(bool full) internal view returns (uint256[] memory claimSum, uint256[] memory fullSum) {
        uint256 nC = trackedCurrencies.length;
        claimSum = new uint256[](nC);
        fullSum = new uint256[](nC);
        for (uint256 i; i < poolKeys.length; i++) {
            PoolKey memory key = poolKeys[i];
            PoolId pid = key.toId();
            uint256 c0 = _currencyIdx(key.currency0);
            uint256 c1 = _currencyIdx(key.currency1);
            for (uint256 a; a < claimants.length; a++) {
                if (c0 < nC) claimSum[c0] += orchestrator.poolClaims(pid, key.currency0, claimants[a]);
                if (c1 < nC) claimSum[c1] += orchestrator.poolClaims(pid, key.currency1, claimants[a]);
            }
            if (!full) continue;

            if (c0 < nC) fullSum[c0] += orchestrator.buybackReserve(pid, key.currency0);
            if (c1 < nC) fullSum[c1] += orchestrator.buybackReserve(pid, key.currency1);

            KingOfThePoolLogic.KingRoundState memory ks = orchestrator.kingState(pid);
            uint256 potIdx = _currencyIdx(ks.potCurrency);
            if (ks.currentPotAmount > 0 && potIdx < nC) fullSum[potIdx] += ks.currentPotAmount;

            uint64 lowest =
                ks.currentRoundId > MAX_KING_ROUNDS_SCAN ? uint64(ks.currentRoundId - MAX_KING_ROUNDS_SCAN) : 1;
            for (uint64 r = lowest; r < ks.currentRoundId; r++) {
                KingOfThePoolLogic.SettledKingRound memory settled = orchestrator.settledKingRound(pid, r);
                if (settled.claimed || settled.amount == 0) continue;
                uint256 idx = _currencyIdx(settled.currency);
                if (idx < nC) fullSum[idx] += settled.amount;
            }
        }
        for (uint256 c; c < nC; c++) {
            fullSum[c] += claimSum[c];
        }
    }

    /// @notice (graduationQuoteTarget, curveTokenAllocation, lpTokenReserve) for an XYK or Tranche curve.
    function _curveTargets(address curve, uint8 kind)
        internal
        view
        returns (uint256 target, uint256 alloc, uint256 lp)
    {
        if (kind == CURVE_XYK) {
            (,, uint128 t_, uint128 a_, uint128 l_,) = VirtualXYKLaunch(payable(curve)).curveConfig();
            return (t_, a_, l_);
        }
        (,,, uint128 t2, uint128 a2, uint128 l2,,,,) = SteppedTrancheLaunch(payable(curve)).trancheConfig();
        return (t2, a2, l2);
    }

    /// @notice Integral of the tranche price schedule over the first `sold` tokens, in Q96 quote units.
    /// @dev Token at position s is priced at tranche floor(s·n / alloc), matching `currentTrancheIndex`.
    function _trancheCost(SteppedTrancheLaunch curve, uint256 sold) internal view returns (uint256 cost) {
        (uint8 n, uint128 base, uint128 step,, uint128 alloc,,,,,) = curve.trancheConfig();
        if (n <= 1 || alloc == 0) return uint256(base) * sold;
        for (uint256 i; i < n; i++) {
            uint256 lo = (i * alloc + n - 1) / n;
            if (lo >= sold) break;
            uint256 hi = i == n - 1 ? sold : ((i + 1) * alloc + n - 1) / n;
            if (hi > sold) hi = sold;
            cost += (uint256(base) + i * uint256(step)) * (hi - lo);
        }
    }

    /// @notice Closed-form tokens a buy of `q` quote would return now, capped at `remaining` allocation.
    function _closedFormTokensOut(address curve, uint8 kind, uint256 q, uint256 remaining)
        internal
        view
        returns (uint256 out)
    {
        if (kind == CURVE_XYK) {
            VirtualXYKLaunch xyk = VirtualXYKLaunch(payable(curve));
            uint256 k = xyk.invariantK();
            uint256 x = xyk.virtualQuoteReserve() + q;
            uint256 newY = (k + x - 1) / x;
            uint256 y = xyk.virtualTokenReserve();
            out = y > newY ? y - newY : 0;
        } else {
            SteppedTrancheLaunch tr = SteppedTrancheLaunch(payable(curve));
            uint256 bps = tr.currentAntiSnipeSurchargeBps();
            uint256 sur = (q * bps + 9999) / 10_000;
            uint256 net = q > sur ? q - sur : 0;
            out = (net << 96) / tr.currentMarginalPriceQ96();
        }
        if (out > remaining) out = remaining;
    }
}
