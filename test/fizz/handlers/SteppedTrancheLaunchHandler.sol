// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with SteppedTrancheLaunch curves (setup launch + any launched mid-campaign)
abstract contract SteppedTrancheLaunchHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function steppedTrancheLaunch_buy_clamped(uint256 curveSeed, uint256 quoteAmountIn, address recipient)
        public
        tracked
    {
        SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        (,,, uint128 target,,,,,,) = curve.trancheConfig();
        uint256 balance = token0.balanceOf(actor);
        if (balance == 0) return;
        uint256 maxIn = uint256(target) * 12 / 10;
        quoteAmountIn = clampBetween(quoteAmountIn, 1e12, maxIn < balance ? maxIn : balance);
        steppedTrancheLaunch_buy(curveSeed, quoteAmountIn, 0, toActor(recipient));
    }

    /// @notice Near-zero stress: dust buys where surcharge (Ceil) can exceed the tokens bought (Floor).
    function steppedTrancheLaunch_buy_dust(uint256 curveSeed, uint256 quoteAmountIn) public tracked {
        quoteAmountIn = clampBetween(quoteAmountIn, 1, 1e12);
        steppedTrancheLaunch_buy(curveSeed, quoteAmountIn, 0, actor);
    }

    /// @notice Single buy sized to the full remaining target: one purchase spanning every tranche at one price.
    ///         Graduation must not revert (SP-07).
    function steppedTrancheLaunch_buy_toGraduation(uint256 curveSeed) public tracked {
        SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        (,,, uint128 target,,,,,,) = curve.trancheConfig();
        uint256 remaining = uint256(target) > curve.realQuoteRaised() ? uint256(target) - curve.realQuoteRaised() : 0;
        if (remaining == 0) return;
        uint256 gross = remaining * 2; // covers any surcharge; the curve caps quoteUsed itself
        if (token0.balanceOf(actor) < gross) return;
        _trancheBuyChecked(curve, gross, 0, actor, true);
    }

    function steppedTrancheLaunch_sell_clamped(uint256 curveSeed, uint256 tokenAmountIn, address recipient)
        public
        tracked
    {
        SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
        uint256 balance = MockBurnableERC20(curve.projectToken()).balanceOf(actor);
        if (balance == 0) return;
        tokenAmountIn = clampBetween(tokenAmountIn, 1, balance);
        steppedTrancheLaunch_sell(curveSeed, tokenAmountIn, 0, toActor(recipient));
    }

    /// @notice Full-amount stress: sells the actor's entire project-token balance back into the curve (SP-22).
    function steppedTrancheLaunch_sell_full(uint256 curveSeed) public tracked {
        SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
        uint256 balance = MockBurnableERC20(curve.projectToken()).balanceOf(actor);
        if (balance == 0) return;
        bool active = curve.launchState() == ITokenLaunchpad.LaunchState.ActiveBonding;
        _trancheSellChecked(curve, actor, balance, 0, actor, active);
    }

    /// @notice Round trip (SP-05): buy `q` (also inside the anti-snipe surcharge window), then sell every token received.
    function steppedTrancheLaunch_buySellRoundTrip(uint256 curveSeed, uint256 quoteAmountIn) public tracked {
        SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        (,,, uint128 target,,,,,,) = curve.trancheConfig();
        uint256 balance = token0.balanceOf(actor);
        uint256 maxIn = uint256(target) * 12 / 10;
        if (balance < 1e12 || maxIn < 1e12) return;
        quoteAmountIn = clampBetween(quoteAmountIn, 1e12, maxIn < balance ? maxIn : balance);

        CurveRoundTrip memory r = _trancheRoundTripState(curve, true, CurveRoundTrip(0, 0, 0, 0, 0, 0));
        (, uint256 out) = _trancheBuy(curve, quoteAmountIn, 0, actor, false);
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return; // graduated: sell disabled
        if (out > 0) _trancheSell(curve, actor, out, 0, actor, false);
        r = _trancheRoundTripState(curve, false, r);
        property_SP05_curveRoundTrip(r);
    }

    /// @notice C2 dust cycles (SP-06): `cycles` × (dust buy of 1..1e12 wei, sell everything bought).
    function steppedTrancheLaunch_dustCycle(uint256 curveSeed, uint256 quoteAmountIn, uint8 cycles) public tracked {
        SteppedTrancheLaunch curve = trancheCurves[curveSeed % trancheCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        quoteAmountIn = clampBetween(quoteAmountIn, 1, 1e12);
        uint256 n = clampBetween(cycles, 1, 20);

        CurveRoundTrip memory r = _trancheRoundTripState(curve, true, CurveRoundTrip(0, 0, 0, 0, 0, 0));
        for (uint256 c; c < n; c++) {
            (, uint256 out) = _trancheBuy(curve, quoteAmountIn, 0, actor, false);
            if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return; // graduated
            if (out > 0) _trancheSell(curve, actor, out, 0, actor, false);
        }
        r = _trancheRoundTripState(curve, false, r);
        property_SP06_curveDustCycle(r);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function steppedTrancheLaunch_buy(uint256 curveSeed, uint256 quoteAmountIn, uint256 minTokensOut, address recipient)
        public
        tracked
    {
        _trancheBuyChecked(trancheCurves[curveSeed % trancheCurves.length], quoteAmountIn, minTokensOut, recipient, false);
    }

    function steppedTrancheLaunch_sell(uint256 curveSeed, uint256 tokenAmountIn, uint256 minQuoteOut, address recipient)
        public
        tracked
    {
        _trancheSellChecked(
            trancheCurves[curveSeed % trancheCurves.length], actor, tokenAmountIn, minQuoteOut, recipient, false
        );
    }

    // ―――――――――――――――――――――――― Internals ―――――――――――――――――――――――――

    /// @notice Buy with SP-13 / SP-27, then SP-08 if the call graduated the curve. With `liveness` (SP-07) a revert
    ///         is caught and only the curve wallet-cap error is accepted.
    function _trancheBuyChecked(
        SteppedTrancheLaunch curve,
        uint256 quoteAmountIn,
        uint256 minTokensOut,
        address recipient,
        bool liveness
    ) internal {
        uint256 i = _poolIdxOfCurve(address(curve));
        (bytes4 err,) = _trancheBuy(curve, quoteAmountIn, minTokensOut, recipient, liveness);
        bytes4 walletCapSel = SteppedTrancheLaunch.WalletCapExceededOnTranche.selector;
        if (err != bytes4(0)) {
            property_SP07_graduationLiveness(true, err, walletCapSel, address(curve), i);
            return;
        }
        snapshotAfter();
        if (liveness) property_SP07_graduationLiveness(false, bytes4(0), walletCapSel, address(curve), i);
        _checkGraduation(i);
    }

    function _trancheSellChecked(
        SteppedTrancheLaunch curve,
        address seller,
        uint256 tokenAmountIn,
        uint256 minQuoteOut,
        address recipient,
        bool liveness
    ) internal {
        (bool ok,) = _trancheSell(curve, seller, tokenAmountIn, minQuoteOut, recipient, liveness);
        if (liveness) property_SP22_curveExitLiveness(ok);
    }

    /// @notice One buy by `actor` with its SP-13 / SP-27 checks and the GL-15 `trancheBuys` ghost. When
    ///         `catchRevert`, returns the revert selector (`0xffffffff` without one) instead of reverting.
    function _trancheBuy(
        SteppedTrancheLaunch curve,
        uint256 quoteAmountIn,
        uint256 minTokensOut,
        address recipient,
        bool catchRevert
    ) internal returns (bytes4 err, uint256 tokensOut) {
        if (recipient == address(0)) recipient = actor;
        TrancheBuyObs memory o = _trancheBuyObsBefore(curve, quoteAmountIn, recipient);
        _setCallContext(CallKind.CURVE_BUY, actor, _poolIdxOfCurve(address(curve)), recipient);

        vm.prank(actor);
        if (catchRevert) {
            try curve.buy(quoteAmountIn, minTokensOut, recipient) returns (uint256 out, uint256 sur) {
                (o.outRet, o.surRet) = (out, sur);
            } catch (bytes memory data) {
                err = _revertSelector(data);
                return (err == bytes4(0) ? bytes4(0xffffffff) : err, 0);
            }
        } else {
            (o.outRet, o.surRet) = curve.buy(quoteAmountIn, minTokensOut, recipient);
        }
        ghosts.trancheBuys[address(curve)]++;

        uint256 quoteAfter = _currencyBalance(curve.quoteCurrency(), actor);
        o.payerDebit = o.payerDebit >= quoteAfter ? o.payerDebit - quoteAfter : type(uint256).max;
        uint256 projAfter = _currencyBalance(Currency.wrap(curve.projectToken()), recipient);
        o.recipientCredit = projAfter >= o.recipientCredit ? projAfter - o.recipientCredit : 0;
        o.rqrAfter = curve.realQuoteRaised();
        o.surchAfter = curve.totalSurchargeCollected();
        o.graduated = curve.launchState() == ITokenLaunchpad.LaunchState.Graduated;
        property_SP13_trancheBuyModel(o);
        if (o.payerDebit >= o.surRet && o.payerDebit != type(uint256).max) {
            property_SP27_noUndeliveredChargeTranche(o.payerDebit - o.surRet, o.outRet, o.price);
        }
        return (bytes4(0), o.outRet);
    }

    /// @notice One sell by `seller` with its SP-13 check. Returns false (instead of reverting) when `catchRevert`.
    function _trancheSell(
        SteppedTrancheLaunch curve,
        address seller,
        uint256 tokenAmountIn,
        uint256 minQuoteOut,
        address recipient,
        bool catchRevert
    ) internal returns (bool ok, uint256 quoteOut) {
        if (recipient == address(0)) recipient = seller;
        TrancheSellObs memory o;
        o.tIn = tokenAmountIn;
        (, uint128 base,,,,,,,,) = curve.trancheConfig();
        o.base = base;
        o.rqr = curve.realQuoteRaised();
        o.sold = curve.curveTokensSold();
        o.checkCredit = recipient != address(curve);
        o.recipientCredit = _currencyBalance(curve.quoteCurrency(), recipient);
        _setCallContext(CallKind.CURVE_SELL, seller, _poolIdxOfCurve(address(curve)), recipient);

        vm.prank(seller);
        if (catchRevert) {
            try curve.sell(tokenAmountIn, minQuoteOut, recipient) returns (uint256 out) {
                o.outRet = out;
            } catch {
                return (false, 0);
            }
        } else {
            o.outRet = curve.sell(tokenAmountIn, minQuoteOut, recipient);
        }

        uint256 quoteAfter = _currencyBalance(curve.quoteCurrency(), recipient);
        o.recipientCredit = quoteAfter >= o.recipientCredit ? quoteAfter - o.recipientCredit : 0;
        property_SP13_trancheSellModel(o);
        return (true, o.outRet);
    }

    /// @notice Pre-state for SP-13; `payerDebit` / `recipientCredit` temporarily hold the balances before the buy.
    function _trancheBuyObsBefore(SteppedTrancheLaunch curve, uint256 quoteAmountIn, address recipient)
        internal
        view
        returns (TrancheBuyObs memory o)
    {
        o.qIn = quoteAmountIn;
        o.bps = curve.currentAntiSnipeSurchargeBps();
        o.price = curve.currentMarginalPriceQ96();
        o.rqrBefore = curve.realQuoteRaised();
        o.surchBefore = curve.totalSurchargeCollected();
        o.sold = curve.curveTokensSold();
        (,,, uint128 target, uint128 alloc,,,,,) = curve.trancheConfig();
        o.target = target;
        o.alloc = alloc;
        o.payerDebit = _currencyBalance(curve.quoteCurrency(), actor);
        o.recipientCredit = _currencyBalance(Currency.wrap(curve.projectToken()), recipient);
        o.checkCredit = recipient != address(curve);
    }

    /// @notice Fills the before (`isBefore`) or after half of a curve round-trip record (raised includes surcharges).
    function _trancheRoundTripState(SteppedTrancheLaunch curve, bool isBefore, CurveRoundTrip memory r)
        internal
        view
        returns (CurveRoundTrip memory)
    {
        uint256 quote = _currencyBalance(curve.quoteCurrency(), actor);
        uint256 proj = _currencyBalance(Currency.wrap(curve.projectToken()), actor);
        uint256 raised = curve.realQuoteRaised() + curve.totalSurchargeCollected();
        if (isBefore) (r.quoteBefore, r.projBefore, r.raisedBefore) = (quote, proj, raised);
        else (r.quoteAfter, r.projAfter, r.raisedAfter) = (quote, proj, raised);
        return r;
    }
}
