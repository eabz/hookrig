// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import "../Base.sol";
import {Properties} from "../Properties.sol";

/// @notice Handles the interaction with VirtualXYKLaunch curves (setup launch + any launched mid-campaign)
abstract contract VirtualXYKLaunchHandler is Properties {
    // ――――――――――――――――――――――――― Clamped ――――――――――――――――――――――――――

    function virtualXYKLaunch_buy_clamped(uint256 curveSeed, uint256 quoteAmountIn, address recipient) public tracked {
        VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        (,, uint128 target,,,) = curve.curveConfig();
        uint256 balance = token0.balanceOf(actor);
        if (balance == 0) return;
        // up to 120% of the target so the cap-and-refund branch is reached
        uint256 maxIn = uint256(target) * 12 / 10;
        quoteAmountIn = clampBetween(quoteAmountIn, 1e12, maxIn < balance ? maxIn : balance);
        virtualXYKLaunch_buy(curveSeed, quoteAmountIn, 0, toActor(recipient));
    }

    /// @notice Near-zero stress: dust buys where `tokensOut` floors toward zero.
    function virtualXYKLaunch_buy_dust(uint256 curveSeed, uint256 quoteAmountIn) public tracked {
        quoteAmountIn = clampBetween(quoteAmountIn, 1, 1e12);
        virtualXYKLaunch_buy(curveSeed, quoteAmountIn, 0, actor);
    }

    /// @notice Buys exactly the remaining quote to target, forcing graduation (must not revert, SP-07).
    function virtualXYKLaunch_buy_toGraduation(uint256 curveSeed) public tracked {
        VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        (,, uint128 target,,,) = curve.curveConfig();
        uint256 remaining = uint256(target) - curve.realQuoteRaised();
        if (remaining == 0 || token0.balanceOf(actor) < remaining) return;
        _xykBuyChecked(curve, remaining, 0, actor, true);
    }

    function virtualXYKLaunch_sell_clamped(uint256 curveSeed, uint256 tokenAmountIn, address recipient) public tracked {
        VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
        uint256 balance = MockBurnableERC20(curve.projectToken()).balanceOf(actor);
        if (balance == 0) return;
        tokenAmountIn = clampBetween(tokenAmountIn, 1, balance);
        virtualXYKLaunch_sell(curveSeed, tokenAmountIn, 0, toActor(recipient));
    }

    /// @notice Full-amount stress: sells the actor's entire project-token balance back into the curve (SP-22).
    function virtualXYKLaunch_sell_full(uint256 curveSeed) public tracked {
        VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
        uint256 balance = MockBurnableERC20(curve.projectToken()).balanceOf(actor);
        if (balance == 0) return;
        bool active = curve.launchState() == ITokenLaunchpad.LaunchState.ActiveBonding;
        _xykSellChecked(curve, actor, balance, 0, actor, active);
    }

    /// @notice Round trip (SP-05): buy `q`, then sell every token received.
    function virtualXYKLaunch_buySellRoundTrip(uint256 curveSeed, uint256 quoteAmountIn) public tracked {
        VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        (,, uint128 target,,,) = curve.curveConfig();
        uint256 balance = token0.balanceOf(actor);
        uint256 maxIn = uint256(target) * 12 / 10;
        if (balance < 1e12 || maxIn < 1e12) return;
        quoteAmountIn = clampBetween(quoteAmountIn, 1e12, maxIn < balance ? maxIn : balance);

        CurveRoundTrip memory r = _xykRoundTripState(curve, true, CurveRoundTrip(0, 0, 0, 0, 0, 0));
        (, uint256 out) = _xykBuy(curve, quoteAmountIn, 0, actor, false);
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return; // graduated: sell disabled
        if (out > 0) _xykSell(curve, actor, out, 0, actor, false);
        r = _xykRoundTripState(curve, false, r);
        property_SP05_curveRoundTrip(r);
    }

    /// @notice C2 dust cycles (SP-06): `cycles` × (dust buy of 1..1e12 wei, sell everything bought).
    function virtualXYKLaunch_dustCycle(uint256 curveSeed, uint256 quoteAmountIn, uint8 cycles) public tracked {
        VirtualXYKLaunch curve = xykCurves[curveSeed % xykCurves.length];
        if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return;
        quoteAmountIn = clampBetween(quoteAmountIn, 1, 1e12);
        uint256 n = clampBetween(cycles, 1, 20);

        CurveRoundTrip memory r = _xykRoundTripState(curve, true, CurveRoundTrip(0, 0, 0, 0, 0, 0));
        for (uint256 c; c < n; c++) {
            (, uint256 out) = _xykBuy(curve, quoteAmountIn, 0, actor, false);
            if (curve.launchState() != ITokenLaunchpad.LaunchState.ActiveBonding) return; // graduated
            if (out > 0) _xykSell(curve, actor, out, 0, actor, false);
        }
        r = _xykRoundTripState(curve, false, r);
        property_SP06_curveDustCycle(r);
    }

    // ―――――――――――――――――――――――― Unclamped ―――――――――――――――――――――――――

    function virtualXYKLaunch_buy(uint256 curveSeed, uint256 quoteAmountIn, uint256 minTokensOut, address recipient)
        public
        tracked
    {
        _xykBuyChecked(xykCurves[curveSeed % xykCurves.length], quoteAmountIn, minTokensOut, recipient, false);
    }

    function virtualXYKLaunch_sell(uint256 curveSeed, uint256 tokenAmountIn, uint256 minQuoteOut, address recipient)
        public
        tracked
    {
        _xykSellChecked(xykCurves[curveSeed % xykCurves.length], actor, tokenAmountIn, minQuoteOut, recipient, false);
    }

    // ―――――――――――――――――――――――― Internals ―――――――――――――――――――――――――

    /// @notice Buy with SP-12 / SP-27, then SP-08 if the call graduated the curve. With `liveness` (SP-07) a revert
    ///         is caught and only the curve wallet-cap error is accepted.
    function _xykBuyChecked(
        VirtualXYKLaunch curve,
        uint256 quoteAmountIn,
        uint256 minTokensOut,
        address recipient,
        bool liveness
    ) internal {
        uint256 i = _poolIdxOfCurve(address(curve));
        (bytes4 err, ) = _xykBuy(curve, quoteAmountIn, minTokensOut, recipient, liveness);
        bytes4 walletCapSel = VirtualXYKLaunch.WalletCapExceededOnCurve.selector;
        if (err != bytes4(0)) {
            property_SP07_graduationLiveness(true, err, walletCapSel, address(curve), i);
            return;
        }
        snapshotAfter();
        if (liveness) property_SP07_graduationLiveness(false, bytes4(0), walletCapSel, address(curve), i);
        _checkGraduation(i);
    }

    function _xykSellChecked(
        VirtualXYKLaunch curve,
        address seller,
        uint256 tokenAmountIn,
        uint256 minQuoteOut,
        address recipient,
        bool liveness
    ) internal {
        (bool ok,) = _xykSell(curve, seller, tokenAmountIn, minQuoteOut, recipient, liveness);
        if (liveness) property_SP22_curveExitLiveness(ok);
    }

    /// @notice One buy by `actor` with its SP-12 / SP-27 checks. When `catchRevert`, returns the revert selector
    ///         (`0xffffffff` for revert data without one) instead of reverting.
    function _xykBuy(
        VirtualXYKLaunch curve,
        uint256 quoteAmountIn,
        uint256 minTokensOut,
        address recipient,
        bool catchRevert
    ) internal returns (bytes4 err, uint256 tokensOut) {
        if (recipient == address(0)) recipient = actor;
        XykBuyObs memory o = _xykBuyObsBefore(curve, quoteAmountIn, recipient);
        _setCallContext(CallKind.CURVE_BUY, actor, _poolIdxOfCurve(address(curve)), recipient);

        vm.prank(actor);
        if (catchRevert) {
            try curve.buy(quoteAmountIn, minTokensOut, recipient) returns (uint256 out, uint256 used) {
                (o.outRet, o.usedRet) = (out, used);
            } catch (bytes memory data) {
                err = _revertSelector(data);
                return (err == bytes4(0) ? bytes4(0xffffffff) : err, 0);
            }
        } else {
            (o.outRet, o.usedRet) = curve.buy(quoteAmountIn, minTokensOut, recipient);
        }

        uint256 quoteAfter = _currencyBalance(curve.quoteCurrency(), actor);
        o.payerDebit = o.payerDebit >= quoteAfter ? o.payerDebit - quoteAfter : type(uint256).max;
        uint256 projAfter = _currencyBalance(Currency.wrap(curve.projectToken()), recipient);
        o.recipientCredit = projAfter >= o.recipientCredit ? projAfter - o.recipientCredit : 0;
        property_SP12_xykBuyModel(o);
        property_SP27_noUndeliveredChargeXYK(curve);
        return (bytes4(0), o.outRet);
    }

    /// @notice One sell by `seller` with its SP-12 check. Returns false (instead of reverting) when `catchRevert`.
    function _xykSell(
        VirtualXYKLaunch curve,
        address seller,
        uint256 tokenAmountIn,
        uint256 minQuoteOut,
        address recipient,
        bool catchRevert
    ) internal returns (bool ok, uint256 quoteOut) {
        if (recipient == address(0)) recipient = seller;
        XykSellObs memory o;
        o.tIn = tokenAmountIn;
        o.x = curve.virtualQuoteReserve();
        o.y = curve.virtualTokenReserve();
        o.k = curve.invariantK();
        o.rqr = curve.realQuoteRaised();
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
        property_SP12_xykSellModel(o);
        return (true, o.outRet);
    }

    /// @notice Pre-state for SP-12; `payerDebit` / `recipientCredit` temporarily hold the balances before the buy.
    function _xykBuyObsBefore(VirtualXYKLaunch curve, uint256 quoteAmountIn, address recipient)
        internal
        view
        returns (XykBuyObs memory o)
    {
        o.qIn = quoteAmountIn;
        o.x = curve.virtualQuoteReserve();
        o.y = curve.virtualTokenReserve();
        o.k = curve.invariantK();
        o.rqr = curve.realQuoteRaised();
        o.sold = curve.curveTokensSold();
        (,, uint128 target, uint128 alloc,,) = curve.curveConfig();
        o.target = target;
        o.alloc = alloc;
        o.payerDebit = _currencyBalance(curve.quoteCurrency(), actor);
        o.recipientCredit = _currencyBalance(Currency.wrap(curve.projectToken()), recipient);
        o.checkCredit = recipient != address(curve);
    }

    /// @notice Fills the before (`isBefore`) or after half of a curve round-trip record for `actor`.
    function _xykRoundTripState(VirtualXYKLaunch curve, bool isBefore, CurveRoundTrip memory r)
        internal
        view
        returns (CurveRoundTrip memory)
    {
        uint256 quote = _currencyBalance(curve.quoteCurrency(), actor);
        uint256 proj = _currencyBalance(Currency.wrap(curve.projectToken()), actor);
        uint256 raised = curve.realQuoteRaised();
        if (isBefore) (r.quoteBefore, r.projBefore, r.raisedBefore) = (quote, proj, raised);
        else (r.quoteAfter, r.projAfter, r.raisedAfter) = (quote, proj, raised);
        return r;
    }
}
