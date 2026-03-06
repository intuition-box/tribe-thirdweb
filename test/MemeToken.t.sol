// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MemeLaunchpad.sol";
import "../src/MemeToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract MockWETHMemeToken is ERC20 {
    constructor() ERC20("WETH", "WETH") {}
    function deposit() external payable { _mint(msg.sender, msg.value); }
}

contract MockERC20WithMint is ERC20 {
    constructor(string memory name, string memory symbol) ERC20(name, symbol) {}
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract MemeTokenTest is Test {
    MemeLaunchpad public launchpad;
    MemeToken public token;
    address public launchpadAddr;
    address public treasury;
    address public creator;
    address public dexRouter;

    function setUp() public {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        dexRouter = makeAddr("dexRouter");
        MockWETHMemeToken weth = new MockWETHMemeToken();
        vm.mockCall(dexRouter, abi.encodeWithSelector(bytes4(keccak256("WETH()"))), abi.encode(address(weth)));
        address lib = deployCode("src/DEXMigrationLib.sol:DEXMigrationLib");
        vm.etch(address(0x0000000000000000000000000000000000000100), lib.code);
        launchpad = new MemeLaunchpad(treasury, dexRouter, address(0x0000000000000000000000000000000000000100));
        launchpadAddr = address(launchpad);
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("Test", "TST", "meta", 255);
        token = MemeToken(payable(tokenAddress));
    }

    function testLaunchpadIsSet() public view {
        assertEq(token.launchpad(), launchpadAddr);
    }

    function testSetLaunchpadRevertsWhenAlreadySet() public {
        MemeToken newToken = new MemeToken("New", "NEW", 1_000_000_000 * 1e18);
        newToken.setLaunchpad(launchpadAddr);
        vm.expectRevert("Launchpad already set");
        newToken.setLaunchpad(makeAddr("other"));
    }

    function testSetLaunchpadRevertsZeroAddress() public {
        MemeToken newToken = new MemeToken("New", "N2", 1_000_000_000 * 1e18);
        vm.expectRevert("Invalid launchpad");
        newToken.setLaunchpad(address(0));
    }

    function testMintOnlyLaunchpad() public {
        uint256 supplyBefore = token.totalSupply();
        vm.prank(launchpadAddr);
        token.mint(creator, 100e18);
        assertEq(token.totalSupply(), supplyBefore + 100e18);
        assertEq(token.balanceOf(creator), 100e18);
    }

    function testMintRevertsNotLaunchpad() public {
        vm.prank(creator);
        vm.expectRevert("Only launchpad");
        token.mint(creator, 100e18);
    }

    function testSetTrustTokenOnlyLaunchpad() public {
        MockERC20WithMint trustToken = new MockERC20WithMint("TRUST", "TRUST");
        vm.prank(address(launchpad));
        token.setTrustToken(address(trustToken));
        assertEq(address(token.trustToken()), address(trustToken));
    }

    function testSetTrustTokenRevertsNotLaunchpad() public {
        MockERC20WithMint trustToken = new MockERC20WithMint("TRUST", "TRUST");
        vm.prank(creator);
        vm.expectRevert("Only launchpad");
        token.setTrustToken(address(trustToken));
    }

    function testSetTrustTokenRevertsAlreadySet() public {
        MockERC20WithMint trustToken = new MockERC20WithMint("TRUST", "TRUST");
        vm.prank(launchpadAddr);
        token.setTrustToken(address(trustToken));
        vm.prank(launchpadAddr);
        vm.expectRevert("Trust token already set");
        token.setTrustToken(address(trustToken));
    }

    function testEnableTransferFeeOnlyLaunchpad() public {
        vm.prank(launchpadAddr);
        token.enableTransferFee(2);
        assertTrue(token.transferFeeEnabled());
        assertEq(token.transferFeePercent(), 2);
    }

    function testEnableTransferFeeRevertsNotLaunchpad() public {
        vm.prank(creator);
        vm.expectRevert("Only launchpad");
        token.enableTransferFee(2);
    }

    function testEnableTransferFeeRevertsAlreadyEnabled() public {
        vm.prank(launchpadAddr);
        token.enableTransferFee(2);
        vm.prank(launchpadAddr);
        vm.expectRevert("Transfer fee already enabled");
        token.enableTransferFee(3);
    }

    function testEnableTransferFeeRevertsOver100() public {
        vm.prank(launchpadAddr);
        vm.expectRevert("Fee exceeds 100%");
        token.enableTransferFee(101);
    }

    function testTransferNativeOnlyLaunchpad() public {
        vm.deal(address(token), 1e18);
        address recipient = makeAddr("recipient");
        uint256 recipientBefore = recipient.balance;
        vm.prank(launchpadAddr);
        bool ok = token.transferNative(payable(recipient), 0.5e18);
        assertTrue(ok);
        assertEq(recipient.balance, recipientBefore + 0.5e18);
        assertEq(address(token).balance, 0.5e18);
    }

    function testTransferNativeRevertsNotLaunchpad() public {
        vm.deal(address(token), 1e18);
        vm.prank(creator);
        vm.expectRevert("Only launchpad");
        token.transferNative(payable(creator), 1e18);
    }

    function testTransferNativeRevertsZeroRecipient() public {
        vm.deal(address(token), 1e18);
        vm.prank(launchpadAddr);
        vm.expectRevert("Invalid recipient");
        token.transferNative(payable(address(0)), 1e18);
    }

    function testGetNativeBalance() public {
        assertEq(token.getNativeBalance(), 0);
        vm.deal(address(token), 2e18);
        assertEq(token.getNativeBalance(), 2e18);
    }

    function testReceive() public {
        (bool ok,) = address(token).call{value: 1e18}("");
        assertTrue(ok);
        assertEq(token.getNativeBalance(), 1e18);
    }

    function testSetAllowanceForUserOnlyLaunchpad() public {
        address spender = makeAddr("spender");
        vm.prank(launchpadAddr);
        token.setAllowanceForUser(spender, 100e18);
        assertEq(token.allowance(launchpadAddr, spender), 100e18);
    }

    function testSetAllowanceForUserRevertsNotLaunchpad() public {
        vm.prank(creator);
        vm.expectRevert("Only launchpad");
        token.setAllowanceForUser(creator, 100e18);
    }

    function testTransferFeeAppliedAfterEnable() public {
        vm.prank(launchpadAddr);
        token.mint(creator, 1000e18);
        vm.prank(launchpadAddr);
        token.enableTransferFee(10); // 10%
        address to = makeAddr("to");
        uint256 launchpadBefore = token.balanceOf(launchpadAddr);
        vm.prank(creator);
        assertTrue(token.transfer(to, 100e18));
        assertEq(token.balanceOf(to), 90e18);
        assertEq(token.balanceOf(launchpadAddr), launchpadBefore + 10e18);
    }

    function testTransferFeeNotAppliedBeforeEnable() public {
        vm.prank(launchpadAddr);
        token.mint(creator, 1000e18);
        address to = makeAddr("to");
        vm.prank(creator);
        assertTrue(token.transfer(to, 100e18));
        assertEq(token.balanceOf(to), 100e18);
        assertEq(token.balanceOf(creator), 900e18);
        // Launchpad holds initial 30% (totalSupply - 1000e18 minted to creator)
        assertEq(token.balanceOf(launchpadAddr), token.totalSupply() - 1000e18);
    }

    function testTransferTrustToLaunchpad() public {
        MockERC20WithMint trustToken = new MockERC20WithMint("TRUST", "TRUST");
        trustToken.mint(address(token), 500e18);
        vm.prank(launchpadAddr);
        token.setTrustToken(address(trustToken));
        vm.prank(launchpadAddr);
        bool ok = token.transferTrustToLaunchpad();
        assertTrue(ok);
        assertEq(trustToken.balanceOf(launchpadAddr), 500e18);
        assertEq(trustToken.balanceOf(address(token)), 0);
    }

    function testTransferTrustToLaunchpadRevertsNotSet() public {
        vm.prank(launchpadAddr);
        vm.expectRevert("Trust token not set");
        token.transferTrustToLaunchpad();
    }

    function testBurnFrom() public {
        vm.prank(launchpadAddr);
        token.mint(creator, 100e18);
        vm.prank(creator);
        token.approve(launchpadAddr, 50e18);
        vm.prank(launchpadAddr);
        token.burnFrom(creator, 50e18);
        assertEq(token.balanceOf(creator), 50e18);
        assertEq(token.totalSupply(), token.balanceOf(launchpadAddr) + 50e18);
    }
}
