// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MemeLaunchpad.sol";
import "../src/MemeToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWETHExtended is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
    function withdraw(uint256 amount) external {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _burn(msg.sender, amount);
        payable(msg.sender).transfer(amount);
    }
    function approve(address spender, uint256 amount) public override returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }
}

contract MemeLaunchpadExtendedTest is Test {
    MemeLaunchpad public launchpad;
    MockWETHExtended public weth;
    address public treasury;
    address public owner;
    address public creator;
    address public dexRouter;

    function setUp() public {
        treasury = makeAddr("treasury");
        owner = makeAddr("owner");
        creator = makeAddr("creator");
        dexRouter = makeAddr("dexRouter");
        weth = new MockWETHExtended();
        vm.mockCall(dexRouter, abi.encodeWithSelector(bytes4(keccak256("WETH()"))), abi.encode(address(weth)));
        // Deploy DEXMigrationLib and etch to fixed address; MemeLaunchpad calls it via delegatecall
        address lib = deployCode("src/DEXMigrationLib.sol:DEXMigrationLib");
        vm.etch(address(0x0000000000000000000000000000000000000100), lib.code);
        vm.prank(owner);
        launchpad = new MemeLaunchpad(treasury, dexRouter, address(0x0000000000000000000000000000000000000100));
    }

    function unlockToken(address tokenAddress) internal {
        if (launchpad.tokenUnlocked(tokenAddress)) return;
        uint256 maxSupply = 1_000_000_000 * 1e18;
        for (uint256 i = 0; i < 100 && !launchpad.tokenUnlocked(tokenAddress); i++) {
            vm.deal(creator, 5000e18);
            vm.prank(creator);
            launchpad.buyTokens{value: 5000e18}(tokenAddress, 1);
        }
    }

    /// @dev Sets up router/factory/addLiquidity mocks so completeTokenLaunch can run (avoids stack too deep in coverage).
    function _setupDEXMocksForCompletion(address tokenAddress) internal {
        uint256 held = launchpad.getTokenInfo(tokenAddress).heldTokens;
        uint256 curve = launchpad.curveLiquidity(tokenAddress);
        address router = launchpad.dexRouter();
        address factoryAddr = makeAddr("mockFactory");
        vm.mockCall(router, abi.encodeWithSelector(bytes4(keccak256("factory()"))), abi.encode(factoryAddr));
        address pairAddr = makeAddr("mockLP");
        vm.mockCall(factoryAddr, abi.encodeWithSelector(bytes4(keccak256("getPair(address,address)")), tokenAddress, address(weth)), abi.encode(pairAddr));
        _mockAddLiquidity(router, tokenAddress, held, curve);
    }

    function _mockAddLiquidity(address router, address tokenAddress, uint256 held, uint256 curve) internal {
        uint256 minT = (held * 99) / 100;
        uint256 minW = (curve * 99) / 100;
        uint256 deadline = block.timestamp + 300;
        vm.mockCall(
            router,
            abi.encodeWithSelector(
                bytes4(keccak256("addLiquidity(address,address,uint256,uint256,uint256,uint256,address,uint256)")),
                tokenAddress,
                address(weth),
                held,
                curve,
                minT,
                minW,
                address(launchpad),
                deadline
            ),
            abi.encode(uint256(0), uint256(0), uint256(1))
        );
    }

    function testOwner() public view {
        assertEq(launchpad.owner(), owner);
    }

    function testTransferOwnership() public {
        address newOwner = makeAddr("newOwner");
        vm.prank(owner);
        launchpad.transferOwnership(newOwner);
        assertEq(launchpad.owner(), newOwner);
    }

    function testTransferOwnershipRevertsIfNotOwner() public {
        vm.prank(creator);
        vm.expectRevert(MemeLaunchpad.NotOwner.selector);
        launchpad.transferOwnership(creator);
    }

    function testTransferOwnershipRevertsZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(MemeLaunchpad.InvalidAddress.selector);
        launchpad.transferOwnership(address(0));
    }

    function testSetDexRouter() public {
        address newRouter = makeAddr("newRouter");
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(launchpad));
        emit MemeLaunchpad.DEXRouterUpdated(dexRouter, newRouter);
        launchpad.setDexRouter(newRouter);
        assertEq(launchpad.dexRouter(), newRouter);
    }

    function testSetDexRouterRevertsZero() public {
        vm.prank(owner);
        vm.expectRevert(MemeLaunchpad.InvalidAddress.selector);
        launchpad.setDexRouter(address(0));
    }

    function testSetFeePercent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(launchpad));
        emit MemeLaunchpad.FeePercentUpdated(2, 5);
        launchpad.setFeePercent(5);
        assertEq(launchpad.feePercent(), 5);
    }

    function testSetFeePercentRevertsOverMax() public {
        vm.prank(owner);
        vm.expectRevert(MemeLaunchpad.FeeExceedsMaximum.selector);
        launchpad.setFeePercent(21);
    }

    function testSetDefaultPostMigrationTransferFeePercent() public {
        vm.prank(owner);
        launchpad.setDefaultPostMigrationTransferFeePercent(3);
        assertEq(launchpad.defaultPostMigrationTransferFeePercent(), 3);
    }

    function testSetSellSpreadPercent() public {
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(launchpad));
        emit MemeLaunchpad.SellSpreadPercentUpdated(2, 10);
        launchpad.setSellSpreadPercent(10);
        assertEq(launchpad.sellSpreadPercent(), 10);
    }

    function testSetSellSpreadPercentRevertsOverMax() public {
        vm.prank(owner);
        vm.expectRevert(MemeLaunchpad.SellSpreadExceedsMaximum.selector);
        launchpad.setSellSpreadPercent(26);
    }

    function testSetCreatorTransferFee() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("FeeToken", "FT", "meta", 255);
        vm.prank(creator);
        vm.expectEmit(true, true, false, false, address(launchpad));
        emit MemeLaunchpad.CreatorTransferFeeSet(tokenAddress, creator, 3);
        launchpad.setCreatorTransferFee(tokenAddress, 3);
        assertEq(launchpad.creatorTransferFeePercent(tokenAddress), 3);
    }

    function testSetCreatorTransferFeeRevertsNonCreator() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("FeeToken2", "F2", "meta", 255);
        vm.prank(owner);
        vm.expectRevert(MemeLaunchpad.InvalidInput.selector);
        launchpad.setCreatorTransferFee(tokenAddress, 3);
    }

    function testSetTokenSellSpread() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("SpreadToken", "SP", "meta", 255);
        vm.prank(owner);
        vm.expectEmit(true, true, false, false, address(launchpad));
        emit MemeLaunchpad.TokenSellSpreadSet(tokenAddress, creator, 5);
        launchpad.setTokenSellSpread(tokenAddress, 5);
        assertTrue(launchpad.hasTokenSellSpread(tokenAddress));
        assertEq(launchpad.tokenSellSpreadPercent(tokenAddress), 5);
    }

    function testGetCurrentPriceAndExcessLiquidity() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("PriceToken", "PT", "meta", 255);
        uint256 price0 = launchpad.getCurrentPrice(tokenAddress);
        assertEq(price0, 0.0001533e18, "Initial price");
        assertEq(launchpad.getExcessLiquidity(tokenAddress), 0);

        unlockToken(tokenAddress);
        vm.deal(creator, 1e18);
        vm.prank(creator);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
        assertGt(launchpad.getCurrentPrice(tokenAddress), price0);
        assertEq(launchpad.getExcessLiquidity(tokenAddress), 0);
    }

    function testAddCommentAndGetComments() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("CommentToken", "CT", "meta", 255);
        uint256 fee = 0.025e18;
        vm.deal(creator, fee);
        vm.prank(creator);
        launchpad.addComment{value: fee}(tokenAddress, "Hello world");
        MemeLaunchpad.Comment[] memory comments = launchpad.getComments(tokenAddress);
        assertEq(comments.length, 1);
        assertEq(comments[0].commenter, creator);
        assertEq(comments[0].text, "Hello world");
        assertEq(comments[0].timestamp, block.timestamp);

        vm.deal(creator, fee);
        vm.prank(creator);
        launchpad.addComment{value: fee}(tokenAddress, "Second");
        comments = launchpad.getComments(tokenAddress);
        assertEq(comments.length, 2);
        assertEq(comments[1].text, "Second");
    }

    function testAddCommentRevertsWrongFee() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("CommentToken2", "C2", "meta", 255);
        vm.deal(creator, 1e18);
        vm.prank(creator);
        vm.expectRevert(MemeLaunchpad.InvalidInput.selector);
        launchpad.addComment{value: 0.01e18}(tokenAddress, "Hi");
    }

    function testAddCommentRevertsEmptyText() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("CommentToken3", "C3", "meta", 255);
        vm.deal(creator, 0.025e18);
        vm.prank(creator);
        vm.expectRevert(MemeLaunchpad.InvalidInput.selector);
        launchpad.addComment{value: 0.025e18}(tokenAddress, "");
    }

    function testAuditTrustAccounting() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("AuditToken", "AT", "meta", 255);
        (bool ok, uint256 curve, uint256 bal, uint256 diff) = launchpad.auditTrustAccounting(tokenAddress);
        assertTrue(ok);
        assertEq(curve, 0);
        assertEq(bal, 0);
        assertEq(diff, 0);

        unlockToken(tokenAddress);
        vm.deal(creator, 1e18);
        vm.prank(creator);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
        (ok, curve, bal, diff) = launchpad.auditTrustAccounting(tokenAddress);
        assertTrue(ok);
        assertGt(curve, 0);
        assertGe(bal, curve);
        assertEq(diff, bal - curve);
    }

    function testGetAvailableWithdrawalAmount() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("WithdrawToken", "WT", "meta", 255);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 2e18);
        vm.prank(buyer);
        uint256 bought = launchpad.buyTokens{value: 2e18}(tokenAddress, 1);
        (uint256 tok, uint256 nat) = launchpad.getAvailableWithdrawalAmount(tokenAddress, buyer);
        assertEq(tok, bought);
        assertEq(nat, launchpad.userContributions(tokenAddress, buyer));
    }

    function testBuyRevertsWhenTokenLockedNonCreator() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("LockedToken", "LT", "meta", 255);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);
        vm.prank(buyer);
        vm.expectRevert(MemeLaunchpad.TokenLocked.selector);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
    }

    function testSellRevertsWhenCompleted() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("CompletedSellToken", "CST", "meta", 255);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);
        vm.prank(buyer);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
        vm.prank(buyer);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), 1e18);

        _setupDEXMocksForCompletion(tokenAddress);
        vm.prank(owner);
        launchpad.completeTokenLaunch(tokenAddress);

        vm.prank(buyer);
        vm.expectRevert(MemeLaunchpad.TokenLaunchCompleted.selector);
        launchpad.sellTokens(tokenAddress, 1e17, 0, address(0));
    }

    function testSellRevertsNoTokensPurchased() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("NoPurchaseToken", "NPT", "meta", 255);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 1e18);
        vm.prank(buyer);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
        address other = makeAddr("other");
        vm.prank(buyer);
        assertTrue(MemeToken(payable(tokenAddress)).transfer(other, 1e17));
        vm.prank(other);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), 1e17);
        vm.prank(other);
        vm.expectRevert(MemeLaunchpad.NoTokensPurchased.selector);
        launchpad.sellTokens(tokenAddress, 1e17, 0, address(0));
    }

    function testSellTokensWithPayoutTo() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("PayoutToken", "PYT", "meta", 255);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        address payoutRecipient = makeAddr("payoutRecipient");
        vm.deal(buyer, 2e18);
        vm.prank(buyer);
        uint256 bought = launchpad.buyTokens{value: 2e18}(tokenAddress, 1);
        uint256 sellAmount = 1e18;
        vm.prank(buyer);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), sellAmount);
        uint256 recipientBefore = payoutRecipient.balance;
        vm.prank(buyer);
        uint256 received = launchpad.sellTokens(tokenAddress, sellAmount, 0, payoutRecipient);
        assertEq(payoutRecipient.balance, recipientBefore + received);
        assertEq(MemeToken(payable(tokenAddress)).balanceOf(buyer), bought - sellAmount);
    }

    /// @notice When selling on the bonding curve with an optional payout address, the optional wallet receives the native funds (not the seller).
    function testSellTokensOptionalWalletReceivesFundsNotSeller() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("OptionalPayoutToken", "OPT", "meta", 255);
        unlockToken(tokenAddress);
        address seller = makeAddr("seller");
        address optionalWallet = makeAddr("optionalWallet");
        vm.deal(seller, 3e18);
        vm.prank(seller);
        uint256 bought = launchpad.buyTokens{value: 3e18}(tokenAddress, 1);
        uint256 sellAmount = 1e18;
        vm.prank(seller);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), sellAmount);

        uint256 sellerNativeBefore = seller.balance;
        uint256 optionalWalletBefore = optionalWallet.balance;

        vm.prank(seller);
        uint256 netReceived = launchpad.sellTokens(tokenAddress, sellAmount, 0, optionalWallet);

        // Optional wallet must receive exactly the net payout
        assertEq(optionalWallet.balance, optionalWalletBefore + netReceived, "Optional wallet did not receive the sell payout");
        // Seller must not receive any of the payout (funds went to optional wallet)
        assertEq(seller.balance, sellerNativeBefore, "Seller must not receive payout when optional address is set");
        // Token accounting: seller's tokens decreased
        assertEq(MemeToken(payable(tokenAddress)).balanceOf(seller), bought - sellAmount);
    }

    function testSellTokensSlippageTooHigh() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("SlippageToken", "SLT", "meta", 255);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 2e18);
        vm.prank(buyer);
        launchpad.buyTokens{value: 2e18}(tokenAddress, 1);
        vm.prank(buyer);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), 1e18);
        vm.prank(buyer);
        vm.expectRevert(MemeLaunchpad.SlippageTooHighSell.selector);
        launchpad.sellTokens(tokenAddress, 1e18, type(uint256).max, address(0));
    }

    function testEmergencyWithdrawTokens() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("EmergencyToken", "EMT", "meta", 255);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 2e18);
        vm.prank(buyer);
        launchpad.buyTokens{value: 2e18}(tokenAddress, 1);
        uint256 contrib = launchpad.userContributions(tokenAddress, buyer);
        uint256 buyerBefore = buyer.balance;
        vm.prank(owner);
        launchpad.emergencyWithdrawTokens(tokenAddress);
        assertEq(buyer.balance, buyerBefore + contrib);
        assertEq(launchpad.userContributions(tokenAddress, buyer), 0);
        assertEq(launchpad.userTokenPurchases(tokenAddress, buyer), 0);
    }

    function testEmergencyWithdrawTokensRevertsNotOwner() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("EmergencyToken2", "E2", "meta", 255);
        vm.prank(creator);
        vm.expectRevert(MemeLaunchpad.NotOwner.selector);
        launchpad.emergencyWithdrawTokens(tokenAddress);
    }

    function testRecoverSellSpreadLiquidity() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("RecoverToken", "RCT", "meta", 3);
        unlockToken(tokenAddress);
        address buyer = makeAddr("buyer");
        vm.deal(buyer, 2e18);
        vm.prank(buyer);
        launchpad.buyTokens{value: 2e18}(tokenAddress, 1);
        vm.prank(buyer);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), 1e18);
        vm.prank(buyer);
        launchpad.sellTokens(tokenAddress, 1e18, 0, address(0));
        uint256 excess = launchpad.getExcessLiquidity(tokenAddress);
        if (excess > 0) {
            uint256 treasuryBefore = treasury.balance;
            vm.prank(owner);
            uint256 amt = launchpad.recoverSellSpreadLiquidity(tokenAddress);
            assertEq(amt, excess);
            assertEq(treasury.balance, treasuryBefore + amt);
        }
    }

    function testRecoverSellSpreadLiquidityRevertsNoExcess() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("NoExcessToken", "NET", "meta", 255);
        vm.prank(owner);
        vm.expectRevert(MemeLaunchpad.NoExcessLiquidityToRecover.selector);
        launchpad.recoverSellSpreadLiquidity(tokenAddress);
    }

    function testCheckMigrationReadiness() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("ReadyToken", "RDT", "meta", 255);
        (bool ready,,,) = launchpad.checkMigrationReadiness(tokenAddress);
        assertFalse(ready);
        unlockToken(tokenAddress);
        vm.deal(creator, 1e18);
        vm.prank(creator);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
        (ready,,,) = launchpad.checkMigrationReadiness(tokenAddress);
        assertTrue(ready);
    }

    function testReceive() public {
        vm.deal(address(this), 1e18);
        (bool ok,) = address(launchpad).call{value: 1e18}("");
        assertTrue(ok);
        assertEq(address(launchpad).balance, 1e18);
    }

    function testAllTokensLength() public {
        assertEq(launchpad.allTokensLength(), 0);
        vm.prank(creator);
        launchpad.createToken("A", "A", "m", 255);
        assertEq(launchpad.allTokensLength(), 1);
        vm.prank(creator);
        launchpad.createToken("B", "B", "m", 255);
        assertEq(launchpad.allTokensLength(), 2);
    }

    function testCollectAndSplitTransferFees() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("FeeSplitToken", "FST", "meta", 255);
        unlockToken(tokenAddress);
        vm.deal(creator, 2e18);
        vm.prank(creator);
        launchpad.buyTokens{value: 2e18}(tokenAddress, 1);
        _setupDEXMocksForCompletion(tokenAddress);
        vm.prank(owner);
        launchpad.completeTokenLaunch(tokenAddress);
        assertTrue(launchpad.transferFeeEnabled(tokenAddress));
        address holder = makeAddr("holder");
        vm.prank(creator);
        assertTrue(MemeToken(payable(tokenAddress)).transfer(holder, 100e18));
        uint256 creatorBefore = MemeToken(payable(tokenAddress)).balanceOf(creator);
        vm.prank(creator);
        launchpad.collectAndSplitTransferFees(tokenAddress);
        assertGt(MemeToken(payable(tokenAddress)).balanceOf(creator), creatorBefore, "Creator should receive half of fees");
    }

    function testSetCreatorTransferFeeRevertsWhenCompleted() public {
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("DoneToken", "DNT", "meta", 255);
        unlockToken(tokenAddress);
        vm.deal(creator, 1e18);
        vm.prank(creator);
        launchpad.buyTokens{value: 1e18}(tokenAddress, 1);
        _setupDEXMocksForCompletion(tokenAddress);
        vm.prank(owner);
        launchpad.completeTokenLaunch(tokenAddress);
        vm.prank(creator);
        vm.expectRevert(MemeLaunchpad.TokenLaunchCompleted.selector);
        launchpad.setCreatorTransferFee(tokenAddress, 1);
    }
}
