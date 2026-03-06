// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "forge-std/Test.sol";
import "../src/MemeLaunchpad.sol";
import "../src/MemeToken.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

// Mock TRUST token for testing
contract MockTrustToken is ERC20 {
    constructor() ERC20("TRUST", "TRUST") {
        _mint(msg.sender, 1000000000e18); // Mint 1 billion tokens to deployer
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

// Mock WETH contract for testing
contract MockWETH is ERC20 {
    constructor() ERC20("Wrapped Ether", "WETH") {}
    
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }
    
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

contract SellTokenTest is Test {
    MemeLaunchpad public launchpad;
    MockTrustToken public trustToken;
    MockWETH public weth;
    address public treasury;
    address public creator;
    address public dexRouter;

    function setUp() public {
        treasury = makeAddr("treasury");
        creator = makeAddr("creator");
        dexRouter = makeAddr("dexRouter");
        
        // Deploy mock WETH contract (for router to return)
        weth = new MockWETH();
        
        // Deploy mock payment token (previously TRUST token) - not used anymore but kept for compatibility
        trustToken = new MockTrustToken();
        
        // Mock router.WETH() to return our mock WETH address
        vm.mockCall(
            dexRouter,
            abi.encodeWithSelector(bytes4(keccak256("WETH()"))),
            abi.encode(address(weth))
        );
        
        // Deploy DEXMigrationLib and etch to fixed address; MemeLaunchpad calls it via delegatecall
        address lib = deployCode("src/DEXMigrationLib.sol:DEXMigrationLib");
        vm.etch(address(0x0000000000000000000000000000000000000100), lib.code);
        
        launchpad = new MemeLaunchpad(treasury, dexRouter, address(0x0000000000000000000000000000000000000100));
    }

    // Helper function to unlock a token by having the creator buy enough tokens
    // Unlock threshold is 2% of max supply = 20M tokens
    function unlockToken(address tokenAddress) internal {
        // Check if already unlocked
        if (launchpad.tokenUnlocked(tokenAddress)) {
            return;
        }
        
        uint256 maxSupply = 1_000_000_000 * 1e18;
        uint256 unlockThreshold = (maxSupply * 2) / 100; // 20M tokens
        
        // Buy tokens until unlocked
        uint256 maxIterations = 100; // Safety limit
        for (uint256 i = 0; i < maxIterations && !launchpad.tokenUnlocked(tokenAddress); i++) {
            uint256 currentBought = launchpad.creatorBoughtAmount(tokenAddress, creator);
            if (currentBought >= unlockThreshold) {
                break;
            }
            
            // Give creator enough native currency for this purchase
            uint256 nativeAmount = 5000e18;
            vm.deal(creator, nativeAmount);
            
            // Buy with native currency
            vm.prank(creator);
            launchpad.buyTokens{value: nativeAmount}(tokenAddress, 1);
        }
    }

    // Helper function to give native currency to a user
    function giveNativeCurrency(address user, uint256 amount) internal {
        vm.deal(user, amount);
    }

    function testSellTokens() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("SellToken", "ST", "Sell metadata", 255);

        // Unlock the token first
        unlockToken(tokenAddress);

        // Buy some tokens first to have circulating supply
        address buyer = makeAddr("buyer");
        uint256 buyNative = 1e18;
        giveNativeCurrency(buyer, buyNative);
        vm.prank(buyer);
        uint256 initialTokens = launchpad.buyTokens{value: buyNative}(tokenAddress, 1e18);

        // Get current info and approve
        MemeLaunchpad.TokenInfo memory info = launchpad.getTokenInfo(tokenAddress);
        uint256 sellAmount = 1e18;
        vm.prank(buyer);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), sellAmount);

        // Record balances
        uint256 nativeBefore = buyer.balance;
        uint256 treasuryBefore = treasury.balance;

        // Sell tokens (minPaymentOut = 0 for testing, no slippage protection needed)
        vm.prank(buyer);
        uint256 received = launchpad.sellTokens(tokenAddress, sellAmount, 0, address(0));

        // Verify basic functionality
        assertGt(received, 0);
        assertEq(buyer.balance, nativeBefore + received);
        assertEq(MemeToken(payable(tokenAddress)).balanceOf(buyer), initialTokens - sellAmount);
        assertEq(launchpad.getTokenInfo(tokenAddress).currentSupply, info.currentSupply - sellAmount);
        assertGt(treasury.balance, treasuryBefore);
    }

    function testSellTokensInsufficientAllowance() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("FailSellToken", "FST", "Fail metadata", 255);

        // Unlock the token first
        unlockToken(tokenAddress);

        // Buy some tokens
        address buyer = makeAddr("buyer");
        uint256 buyNative = 1e18;
        giveNativeCurrency(buyer, buyNative);
        vm.prank(buyer);
        launchpad.buyTokens{value: buyNative}(tokenAddress, 1);

        address seller = buyer;
        uint256 sellAmount = 1e18;

        // Do not approve

        vm.prank(seller);
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientAllowance.selector,
                address(launchpad),
                0,
                sellAmount
            )
        );
        launchpad.sellTokens(tokenAddress, sellAmount, 0, address(0));
    }

    function testSellTokensNoTokens() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("NoSellToken", "NST", "No metadata", 255);

        address seller = makeAddr("seller");
        uint256 sellAmount = 0;

        vm.prank(seller);
        vm.expectRevert(MemeLaunchpad.MustSellTokens.selector);
        launchpad.sellTokens(tokenAddress, sellAmount, 0, address(0));
    }

    function testSellTokensExceedsCirculatingSupply() public {
        // Create a token
        vm.prank(creator);
        address tokenAddress = launchpad.createToken("ExceedToken", "ET", "Exceed metadata", 255);

        // Unlock the token first
        unlockToken(tokenAddress);

        // Buy some tokens
        address buyer = makeAddr("buyer");
        uint256 buyNative = 1e18;
        giveNativeCurrency(buyer, buyNative);
        vm.prank(buyer);
        launchpad.buyTokens{value: buyNative}(tokenAddress, 1);

        // Try to sell more than available
        vm.prank(buyer);
        MemeToken(payable(tokenAddress)).approve(address(launchpad), 1e28);

        vm.prank(buyer);
        // User doesn't have 1e28 tokens, so will fail with InsufficientTokenBalance first
        vm.expectRevert(MemeLaunchpad.InsufficientTokenBalance.selector);
        launchpad.sellTokens(tokenAddress, 1e28, 0, address(0));
    }
}