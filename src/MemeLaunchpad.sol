// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MemeToken} from "../src/MemeToken.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @notice Interface for DEX router to add liquidity
 * @dev Used for migrating tokens to decentralized exchanges after launch completion
 */
interface IDEXRouter {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);
    
    function factory() external view returns (address);
    
    function WETH() external view returns (address);
}

/**
 * @notice Interface for WETH contract to wrap native currency
 * @dev Used to convert native currency to WETH before adding liquidity
 */
interface IWETH {
    function deposit() external payable;
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}

/**
 * @notice Interface for DEX factory to get pair address and create pairs
 * @dev Used to get LP token address after adding liquidity and create pair if needed
 */
interface IDEXFactory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
    function createPair(address tokenA, address tokenB) external returns (address pair);
}


/**
 * @title MemeLaunchpad
 * @notice Main contract for creating and managing meme tokens with bonding curve mechanics
 * @dev Implements a bonding curve where tokens can be bought/sold before DEX migration
 */
contract MemeLaunchpad {
    // ==================== ACCESS CONTROL ====================
    
    /// @notice Owner address for admin functions
    address private _owner;
    
    /// @notice Restricts function access to contract owner only
    modifier onlyOwner() {
        if (msg.sender != _owner) revert NotOwner();
        _;
    }
    
    // ==================== REENTRANCY PROTECTION ====================
    
    /// @notice Reentrancy guard status (1 = not entered, 2 = entered)
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;
    
    /// @notice Prevents reentrant calls to protected functions
    modifier nonReentrant() {
        if (_status == _ENTERED) revert ReentrantCall();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    event TokenCreated(
        address indexed tokenAddress,
        string name,
        string symbol,
        string metadata,
        address indexed creator,
        uint256 creatorAllocation
    );

    event TokensBought(
        address indexed tokenAddress,
        address indexed buyer,
        uint256 paymentAmount,
        uint256 tokenAmount,
        uint256 newPrice
    );

    event TokensSold(
        address indexed tokenAddress,
        address indexed seller,
        uint256 paymentAmount,
        uint256 tokenAmount,
        uint256 newPrice
    );

    event TokenCompleted(
        address indexed tokenAddress,
        uint256 finalSupply,
        uint256 finalPrice
    );

    event TokenCommented(
        address indexed tokenAddress,
        address indexed commenter,
        string comment,
        uint256 timestamp
    );

    event TokenUnlocked(
        address indexed tokenAddress,
        address indexed creator,
        uint256 creatorBoughtAmount
    );

    event DEXRouterUpdated(
        address indexed oldRouter,
        address indexed newRouter
    );

    event FeePercentUpdated(
        uint256 oldFeePercent,
        uint256 newFeePercent
    );


    event TransferFeeEnabled(
        address indexed tokenAddress,
        uint256 transferFeePercent
    );

    event CreatorTransferFeeSet(
        address indexed tokenAddress,
        address indexed creator,
        uint256 transferFeePercent
    );

    event TransferFeeCollected(
        address indexed tokenAddress,
        address indexed from,
        uint256 feeAmount,
        uint256 creatorShare,
        uint256 launchpadShare
    );

    event LPLocked(
        address indexed tokenAddress,
        address lpTokenAddress,
        uint256 lpAmount
    );

    event EmergencyWithdrawal(
        address indexed tokenAddress,
        address indexed recipient,
        uint256 tokenAmount
    );

    // ==================== CUSTOM ERRORS ====================
    
    error TokenLaunchCompleted();           // Token has reached max supply and completed
    error MustSendPayment();                // No payment token sent with buy transaction
    error NoTokensToBuy();                 // Calculated token amount is zero
    error SlippageTooHigh();                // Received tokens less than minimum expected
    error ExceedsMaxSupply();               // Purchase would exceed bonding curve max supply
    error MustSellTokens();                 // No tokens specified to sell
    error InsufficientCirculatingSupply();  // Not enough circulating supply to sell
    error CreatorBuyLimitExceeded();       // Creator exceeded their buy limit (20% of bonding curve)
    error TokenLocked();                    // Token is locked until creator buys 2% of max supply
    error InvalidAddress();                 // Invalid address (zero address)
    error InvalidInput();                   // Invalid input parameter
    error NoTokensPurchased();              // Recipient has not purchased any tokens
    error InsufficientContractBalance();     // Contract doesn't have enough tokens
    error FeeExceedsMaximum();              // Fee exceeds maximum allowed
    error NotOwner();                       // Not the contract owner
    error ReentrantCall();                  // Reentrant call detected
    error InvalidToken();                   // Invalid token address
    error TransferFailed();                 // Transfer operation failed
    error InsufficientBondingCurveLiquidity(); // Not enough liquidity in bonding curve
    error InsufficientBalance();            // Contract doesn't have enough balance
    error SlippageTooHighSell();            // Received payment less than minimum expected
    error InsufficientTokenBalance();       // User doesn't have enough tokens

    // ==================== STRUCTS ====================
    
    /// @notice Stores information about each created token
    struct TokenInfo {
        string name;              // Token name
        string symbol;            // Token symbol
        string metadata;          // Token metadata/description
        address creator;          // Address of token creator
        uint256 heldTokens;       // Tokens held by contract (30% of max supply)
        uint256 maxSupply;        // Maximum token supply (1 billion)
        uint256 currentSupply;    // Current circulating supply from bonding curve
        bool completed;           // Whether token launch has completed
        uint256 creationTime;     // Timestamp when token was created
    }

    /// @notice Stores comment information for tokens
    struct Comment {
        address commenter;        // Address of user who commented
        string text;              // Comment text
        uint256 timestamp;        // When comment was made
    }

    // ==================== CONSTANTS ====================
    
    uint256 public constant BONDING_CURVE_PERCENT = 70;              // 70% of supply for bonding curve
    uint256 public constant HELD_PERCENT = 30;                      // 30% of supply held by contract
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;      // 1 billion tokens max supply
    uint256 public constant INITIAL_PRICE = 0.0001533e18;           // Initial price per token in payment token
    uint256 public constant MAX_FEE_PERCENT = 20;                   // Maximum allowed fee percent (20%)
    uint256 public constant PRICE_STEP_SIZE = 10_000_000 * 1e18;    // Price increases every 10M tokens
    uint256 public constant CREATOR_MAX_BUY_PERCENT = 20;           // Creator can buy max 20% of bonding curve
    uint256 public constant CREATOR_UNLOCK_THRESHOLD_PERCENT = 2;   // Creator must buy 2% to unlock token
    uint256 public constant COMMENT_FEE = 0.025e18;                 // Fee required to comment on tokens (in native currency) 
    
    // ==================== STATE VARIABLES ====================
    
    /// @notice Maps token address to its information
    mapping(address => TokenInfo) public tokenInfo;
    
    /// @notice Tracks which token addresses are valid
    mapping(address => bool) public isValidToken;
    
    /// @notice Array of all created token addresses
    address[] public allTokens;
    
    /// @notice Get the number of created tokens
    function allTokensLength() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Tracks unique addresses that have purchased tokens per token
    mapping(address => address[]) private tokenHolders;
    
    /// @notice Quick lookup to check if address has purchased from bonding curve
    mapping(address => mapping(address => bool)) private isTokenHolder;
    
    /// @notice Stores comments for each token
    mapping(address => Comment[]) private tokenComments;
    
    /// @notice Tracks how much each creator has bought from bonding curve
    mapping(address => mapping(address => uint256)) public creatorBoughtAmount;

    /// @notice Tracks if a token is unlocked (once unlocked, stays unlocked)
    mapping(address => bool) public tokenUnlocked;

    /// @notice Treasury address that receives fees
    address public treasuryAddress;

    /// @notice Tracks user trading volumes
    struct UserVolume {
        uint256 totalBuyVolume;   // Total native currency spent buying tokens
        uint256 totalSellVolume;  // Total native currency received selling tokens
    }

    /// @notice Maps user address to their trading volume
    mapping(address => UserVolume) public userVolumes;

    /// @notice Tracks total value traded (TVT) per token in native currency
    mapping(address => uint256) public tokenTotalValueTraded;

    /// @notice DEX router address for liquidity migration
    address public dexRouter;

    /// @notice Fee percent for buy/sell transactions (in basis points, e.g., 200 = 2%)
    uint256 public feePercent;

    /// @notice Default post-migration transfer fee percent (in percentage, e.g., 2 = 2%)
    uint256 public defaultPostMigrationTransferFeePercent;

    /// @notice Maximum allowed transfer fee percent (5%)
    uint256 public constant MAX_TRANSFER_FEE_PERCENT = 5;

    /// @notice Maps token address to its LP token address after DEX migration
    mapping(address => address) public tokenLPToken;

    /// @notice Maps token address to whether transfer fee is enabled (after migration)
    mapping(address => bool) public transferFeeEnabled;

    /// @notice Maps token address to creator-set transfer fee percent (0 = not set, uses default)
    mapping(address => uint256) public creatorTransferFeePercent;

    /// @notice Maps token address to bonding curve liquidity (dedicated accounting for buy/sell operations)
    mapping(address => uint256) public curveLiquidity;

    /// @notice Tracks how many tokens each user has purchased (net of sells) per token
    mapping(address => mapping(address => uint256)) public userTokenPurchases;

    /// @notice Tracks net native currency contributed by each user per token (for 1:1 sell returns)
    /// @dev This ensures users get back exactly what they put in when selling, preventing rug pulls
    mapping(address => mapping(address => uint256)) public userContributions;

    // ==================== MODIFIERS ====================
    
    /// @notice Validates that the token address is a valid token created through this launchpad
    modifier onlyValidToken(address tokenAddress) {
        if (!isValidToken[tokenAddress]) revert InvalidToken();
        _;
    }

    // ==================== CONSTRUCTOR ====================
    
    /**
     * @notice Initializes the MemeLaunchpad contract
     * @param _treasuryAddress Address that will receive all fees
     * @param _dexRouter Address of DEX router for liquidity migration (must have WETH() function)
     */
    constructor(address _treasuryAddress, address _dexRouter) {
        _owner = msg.sender;
        _status = _NOT_ENTERED;
        treasuryAddress = _treasuryAddress;
        dexRouter = _dexRouter;
        feePercent = 2; // Initialize to 2% (200 basis points)
        defaultPostMigrationTransferFeePercent = 2; // Initialize to 2% transfer fee after migration (default)
    }
    
    // ==================== RECEIVE NATIVE CURRENCY ====================
    
    /// @notice Allow contract to receive native currency
    receive() external payable {}
    
    // ==================== HELPER FUNCTIONS ====================
    
    
    // ==================== OWNER FUNCTIONS ====================
    
    /// @notice Returns the current owner address
    function owner() external view returns (address) {
        return _owner;
    }
    
    /// @notice Transfers ownership to a new address
    /// @param newOwner Address of the new owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert InvalidAddress();
        _owner = newOwner;
    }

    /// @notice Updates the DEX router address
    /// @param newDexRouter Address of the new DEX router
    function setDexRouter(address newDexRouter) external onlyOwner {
        if (newDexRouter == address(0)) revert InvalidAddress();
        address oldRouter = dexRouter;
        dexRouter = newDexRouter;
        emit DEXRouterUpdated(oldRouter, newDexRouter);
    }

    /**
     * @notice Updates the fee percent for buy/sell transactions
     * @dev Fee is in percentage (e.g., 2 = 2%, 5 = 5%)
     * @param newFeePercent New fee percent (must be <= MAX_FEE_PERCENT)
     */
    function setFeePercent(uint256 newFeePercent) external onlyOwner {
        if (newFeePercent > MAX_FEE_PERCENT) revert FeeExceedsMaximum();
        uint256 oldFeePercent = feePercent;
        feePercent = newFeePercent;
        emit FeePercentUpdated(oldFeePercent, newFeePercent);
    }

    /**
     * @notice Updates the default post-migration transfer fee percent
     * @dev Fee is in percentage (e.g., 2 = 2%, 5 = 5%)
     *      This is used if creator hasn't set their own fee
     * @param newTransferFeePercent New default transfer fee percent (must be <= MAX_TRANSFER_FEE_PERCENT)
     */
    function setDefaultPostMigrationTransferFeePercent(uint256 newTransferFeePercent) external onlyOwner {
        if (newTransferFeePercent > MAX_TRANSFER_FEE_PERCENT) revert FeeExceedsMaximum();
        defaultPostMigrationTransferFeePercent = newTransferFeePercent;
    }

    /**
     * @notice Allows creator to set their own transfer fee for their token
     * @dev Can only be called by token creator, before migration
     * @param tokenAddress Address of the token
     * @param transferFeePercent Transfer fee percent (must be <= MAX_TRANSFER_FEE_PERCENT)
     */
    function setCreatorTransferFee(address tokenAddress, uint256 transferFeePercent) external onlyValidToken(tokenAddress) {
        TokenInfo memory token = tokenInfo[tokenAddress];
        if (msg.sender != token.creator) revert InvalidInput();
        if (token.completed) revert TokenLaunchCompleted();
        if (transferFeePercent > MAX_TRANSFER_FEE_PERCENT) revert FeeExceedsMaximum();
        
        creatorTransferFeePercent[tokenAddress] = transferFeePercent;
        emit CreatorTransferFeeSet(tokenAddress, token.creator, transferFeePercent);
    }

    // ==================== TOKEN CREATION ====================
    
    /**
     * @notice Creates a new meme token with bonding curve mechanics
     * @dev Creates token with 70% for bonding curve, 30% held by contract
     *      Uses native chain currency (ETH, AVAX, etc.) for all transactions
     * @param name Token name
     * @param symbol Token symbol
     * @param metadata Token description/metadata
     * @return Address of the newly created token
     */
    function createToken(
        string memory name,
        string memory symbol,
        string memory metadata
    ) external returns (address) {
        if (bytes(name).length == 0 || bytes(symbol).length == 0) revert InvalidInput();
        uint256 totalSupply = MAX_SUPPLY;

        // Deploy new MemeToken contract
        MemeToken token = new MemeToken(name, symbol, totalSupply);

        // Set this contract as the launchpad (allows minting)
        token.setLaunchpad(address(this));

        // Calculate 30% of supply to be held by contract
        uint256 heldAmount = (totalSupply * HELD_PERCENT) / 100;

        // Store token information
        tokenInfo[address(token)] = TokenInfo({
            name: name,
            symbol: symbol,
            metadata: metadata,
            creator: msg.sender,
            heldTokens: heldAmount,
            maxSupply: totalSupply,
            currentSupply: 0,
            completed: false,
            creationTime: block.timestamp
        });

        // Mark token as valid and add to list
        isValidToken[address(token)] = true;
        allTokens.push(address(token));

        // Mint the 30% held tokens to this contract
        token.mint(address(this), heldAmount); 

        emit TokenCreated(address(token), name, symbol, metadata, msg.sender, 0);

        return address(token);
    }

    // ==================== TOKEN BUYING ====================
    
    /**
     * @notice Buy tokens from the bonding curve
     * @dev Uses quadratic bonding curve pricing. Token must be unlocked unless buyer is creator.
     *      User sends native currency (ETH, AVAX, etc.) with this transaction.
     *      User's contribution (net payment after fee) is tracked for 1:1 sell returns.
     * @param tokenAddress Address of the token to buy
     * @param minTokensOut Minimum tokens expected (slippage protection)
     * @return tokensBought Amount of tokens purchased
     */
    function buyTokens(address tokenAddress, uint256 minTokensOut)
        external
        payable
        nonReentrant
        onlyValidToken(tokenAddress)
        returns (uint256 tokensBought)
    {
        TokenInfo storage token = tokenInfo[tokenAddress];
        uint256 paymentAmount = msg.value;
        if (token.completed) revert TokenLaunchCompleted();
        if (paymentAmount == 0) revert MustSendPayment();

        // Check if token is locked - only creator can buy if locked
        if (!tokenUnlocked[tokenAddress]) {
            if (msg.sender != token.creator) {
                revert TokenLocked();
            }
        }

        // Payment is sent with the transaction (msg.value), no transfer needed

        // Calculate current price using quadratic bonding curve
        uint256 currentPrice = _calculatePrice(token.currentSupply);

        // Calculate tokens that can be bought with the payment sent
        tokensBought = (paymentAmount * 1e18) / currentPrice;
        if (tokensBought == 0) revert NoTokensToBuy();
        if (tokensBought < minTokensOut) revert SlippageTooHigh();

        // Check if purchase would exceed bonding curve max supply (70% of total)
        uint256 bondingMax = (token.maxSupply * BONDING_CURVE_PERCENT) / 100;
        uint256 newSupply;
        unchecked {
            newSupply = token.currentSupply + tokensBought;
        }
        if (newSupply > bondingMax) revert ExceedsMaxSupply();

        // Handle creator-specific logic (buy limits and unlock mechanism)
        if (msg.sender == token.creator) {
            uint256 creatorMaxBuy = (bondingMax * CREATOR_MAX_BUY_PERCENT) / 100;
            uint256 creatorBought = creatorBoughtAmount[tokenAddress][msg.sender];
            uint256 newCreatorBought;
            unchecked {
                newCreatorBought = creatorBought + tokensBought;
            }
            if (newCreatorBought > creatorMaxBuy) {
                revert CreatorBuyLimitExceeded();
            }
            creatorBoughtAmount[tokenAddress][msg.sender] = newCreatorBought;

            // Check if creator has reached unlock threshold (2% of max supply)
            if (!tokenUnlocked[tokenAddress]) {
                uint256 unlockThreshold = (token.maxSupply * CREATOR_UNLOCK_THRESHOLD_PERCENT) / 100;
                if (newCreatorBought >= unlockThreshold) {
                    tokenUnlocked[tokenAddress] = true;
                    emit TokenUnlocked(tokenAddress, msg.sender, newCreatorBought);
                }
            }
        }

        // Calculate fee and update supply
        uint256 fee = (paymentAmount * feePercent) / 100;
        token.currentSupply = newSupply; // Use cached newSupply (already checked for overflow)

        // Check if token should be completed (reached bonding curve max)
        if (token.currentSupply >= bondingMax && !token.completed) {
            token.completed = true;
            uint256 finalPrice = _calculatePrice(token.currentSupply);
            _finalizeTokenCompletion(tokenAddress);
            emit TokenCompleted(tokenAddress, token.currentSupply, finalPrice);
        }

        // Mint tokens to buyer
        MemeToken(payable(tokenAddress)).mint(msg.sender, tokensBought);

        // Track unique holders
        if (!isTokenHolder[tokenAddress][msg.sender]) {
            isTokenHolder[tokenAddress][msg.sender] = true;
            tokenHolders[tokenAddress].push(msg.sender);
        }

        // Track user purchases for emergency withdrawal
        unchecked {
            userTokenPurchases[tokenAddress][msg.sender] += tokensBought;
        }
        
        // TRUST FLOW AUDIT: Send fee to treasury (native currency)
        // Fee is deducted from payment and sent to treasury immediately
        (bool feeSent, ) = payable(treasuryAddress).call{value: fee}("");
        if (!feeSent) revert TransferFailed();

        // TRUST FLOW AUDIT: Send net payment to token contract (each token holds its own liquidity)
        // Only net payment (after fee) is sent to token contract
        // This ensures each token's liquidity is isolated from other tokens
        uint256 netPayment;
        unchecked {
            netPayment = paymentAmount - fee;
            curveLiquidity[tokenAddress] += netPayment;
        }
        
        // Track user contribution (net payment after fee) for 1:1 sell returns
        // This ensures users get back exactly what they put in when selling
        unchecked {
            userContributions[tokenAddress][msg.sender] += netPayment;
        }
        
        // Send net payment to token contract to hold its own liquidity
        (bool paymentSent, ) = payable(tokenAddress).call{value: netPayment}("");
        if (!paymentSent) revert TransferFailed();
        
        // At this point:
        // - Launchpad received: paymentAmount (msg.value)
        // - Fee sent to treasury: fee
        // - Net payment sent to token contract: netPayment = paymentAmount - fee
        // - Token contract balance increased by: netPayment
        // - curveLiquidity tracks the amount held in token contract

        // Update volume tracking
        unchecked {
            userVolumes[msg.sender].totalBuyVolume += paymentAmount;
            tokenTotalValueTraded[tokenAddress] += netPayment;
        }

        emit TokensBought(tokenAddress, msg.sender, paymentAmount - fee, tokensBought, currentPrice);
        return tokensBought;
    }

    // ==================== TOKEN SELLING ====================
    
    /**
     * @notice Sell tokens back to the bonding curve
     * @dev User must approve this contract to spend their tokens first
     *      Users receive back exactly what they contributed (1:1 return) based on their original purchase
     *      This prevents rug pulls by ensuring users get back their original investment proportionally
     * @param tokenAddress Address of the token to sell
     * @param tokenAmount Amount of tokens to sell
     * @param minPaymentOut Minimum native currency expected (slippage protection)
     * @return paymentReceived Net native currency received after fees (proportional to original contribution)
     */
    function sellTokens(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 minPaymentOut
    ) external nonReentrant onlyValidToken(tokenAddress) returns (uint256 paymentReceived) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        if (token.completed) revert TokenLaunchCompleted();
        if (tokenAmount == 0) revert MustSellTokens();

        // Check user has sufficient token balance (verify before any calculations)
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        if (tokenContract.balanceOf(msg.sender) < tokenAmount) revert InsufficientTokenBalance();

        // Ensure sufficient circulating supply (must check before price calculation to prevent underflow)
        if (token.currentSupply < tokenAmount) revert InsufficientCirculatingSupply();
        if (token.currentSupply == 0) revert InsufficientCirculatingSupply();

        // Verify user has purchased tokens (must have contribution to sell)
        uint256 userPurchasedTokens = userTokenPurchases[tokenAddress][msg.sender];
        if (userPurchasedTokens == 0) revert NoTokensPurchased();
        if (tokenAmount > userPurchasedTokens) revert InsufficientTokenBalance();
        
        // Calculate payment based on user's original contribution (1:1 return)
        // This prevents rug pulls by ensuring users get back exactly what they put in
        uint256 userContribution = userContributions[tokenAddress][msg.sender];
        if (userContribution == 0) revert NoTokensPurchased();
        
        // Calculate proportional contribution for tokens being sold
        // calculatedPayment = (userContribution * tokenAmount) / userPurchasedTokens
        uint256 calculatedPayment = (userContribution * tokenAmount) / userPurchasedTokens;
        if (calculatedPayment == 0) revert MustSellTokens();
        
        // Verify token contract has sufficient liquidity
        if (tokenContract.getNativeBalance() < calculatedPayment) revert InsufficientBondingCurveLiquidity();

        // Calculate fee and net payment
        uint256 fee = (calculatedPayment * feePercent) / 100;
        uint256 netPayment;
        unchecked {
            netPayment = calculatedPayment - fee;
        }

        // Slippage protection: ensure net payment meets minimum requirement
        if (netPayment < minPaymentOut) revert SlippageTooHighSell();

        // Update supply FIRST (before external calls) to prevent reentrancy issues
        unchecked {
            token.currentSupply -= tokenAmount;
        }

        // Burn tokens from user (this will fail if allowance is insufficient)
        tokenContract.burnFrom(msg.sender, tokenAmount);

        // TRUST FLOW AUDIT: Get native currency from token contract (each token holds its own liquidity)
        // Transfer gross payment from token contract to launchpad first
        if (!tokenContract.transferNative(payable(address(this)), calculatedPayment)) revert TransferFailed();

        // TRUST FLOW AUDIT: Deduct from bonding curve liquidity (gross payment before fees)
        // We deduct the full calculatedPayment from curveLiquidity because that's the gross amount
        // we're paying out (netPayment + fee). This matches the accounting in buyTokens where
        // we only add netPayment to curveLiquidity (after fee is removed).
        unchecked {
            curveLiquidity[tokenAddress] -= calculatedPayment;
        }

        // Reduce tracked purchases and contributions (user sold tokens)
        // Use helper function to reduce stack depth
        _updateUserTrackingOnSell(tokenAddress, msg.sender, tokenAmount, userPurchasedTokens, calculatedPayment);

        // TRUST FLOW AUDIT: Transfer net payment to user (after fee deduction)
        (bool success, ) = payable(msg.sender).call{value: netPayment}("");
        if (!success) revert TransferFailed();

        // TRUST FLOW AUDIT: Transfer fee to treasury
        (success, ) = payable(treasuryAddress).call{value: fee}("");
        if (!success) revert TransferFailed();

        // At this point:
        // - Token contract sent to launchpad: calculatedPayment (gross, based on user's original contribution)
        // - curveLiquidity decreased by: calculatedPayment (gross)
        // - User received: netPayment (proportional to their original contribution, minus fee)
        // - Treasury received: fee
        // - Total paid out: netPayment + fee = calculatedPayment ✓
        // - Token contract balance decreased by: calculatedPayment ✓
        // - User contributions reduced proportionally ✓
        // - User token purchases reduced proportionally ✓

        // Update volume tracking (using net payment, not gross)
        unchecked {
            userVolumes[msg.sender].totalSellVolume += netPayment;
            tokenTotalValueTraded[tokenAddress] += netPayment;
        }

        // Note: currentPrice is not used for sell calculation anymore, but kept for event emission
        // Calculate price inline to reduce stack depth
        emit TokensSold(tokenAddress, msg.sender, netPayment, tokenAmount, _calculatePrice(token.currentSupply));
        return netPayment;
    }

    // ==================== HELPER FUNCTIONS ====================
    
    /**
     * @notice Updates user tracking when tokens are sold
     * @dev Helper function to reduce stack depth in sellTokens
     * @param tokenAddress Address of the token
     * @param user Address of the user selling
     * @param tokenAmount Amount of tokens being sold
     * @param userPurchasedTokens Total tokens user has purchased
     * @param calculatedPayment Payment amount calculated for this sale
     */
    function _updateUserTrackingOnSell(
        address tokenAddress,
        address user,
        uint256 tokenAmount,
        uint256 userPurchasedTokens,
        uint256 calculatedPayment
    ) private {
        if (tokenAmount >= userPurchasedTokens) {
            // Selling all tokens
            delete userTokenPurchases[tokenAddress][user];
            delete userContributions[tokenAddress][user];
        } else {
            // Selling partial tokens - reduce proportionally
            unchecked {
                userTokenPurchases[tokenAddress][user] -= tokenAmount;
                userContributions[tokenAddress][user] -= calculatedPayment;
            }
        }
    }

    /**
     * @notice Finalizes DEX migration by storing LP token and enabling transfer fees
     * @dev Helper function to reduce stack depth in _migrateToDEX
     * @param tokenAddress Address of the token
     * @param tokenContract MemeToken contract instance
     * @param pairAddress Address of the LP pair
     * @param wethAddress Address of WETH
     * @param liquidity Amount of LP tokens received
     */
    function _finalizeMigration(
        address tokenAddress,
        MemeToken tokenContract,
        address pairAddress,
        address wethAddress,
        uint256 liquidity
    ) private {
        // Get LP token address (should be the pair we just created/verified) and store it
        address lpToken = _getLPToken(tokenAddress, wethAddress);
        if (lpToken == address(0) || lpToken != pairAddress) revert InvalidInput();
        tokenLPToken[tokenAddress] = lpToken;

        // Enable transfer fee on MemeToken after migration
        uint256 transferFee = creatorTransferFeePercent[tokenAddress] != 0
            ? creatorTransferFeePercent[tokenAddress]
            : defaultPostMigrationTransferFeePercent;
        
        tokenContract.enableTransferFee(transferFee);
        transferFeeEnabled[tokenAddress] = true;

        // Mark held tokens as migrated
        tokenInfo[tokenAddress].heldTokens = 0;
        
        // Reset bonding curve liquidity AFTER successful migration
        curveLiquidity[tokenAddress] = 0;

        emit LPLocked(tokenAddress, lpToken, liquidity);
        emit TransferFeeEnabled(tokenAddress, transferFee);
    }

    // ==================== PRICING ====================
    
    /**
     * @notice Calculates the current price using quadratic bonding curve
     * @dev Price increases quadratically based on supply: price = initialPrice * (1 + (supply/stepSize)^2)
     * @param currentSupply Current circulating supply of tokens
     * @return Current price per token in payment token
     */
    function _calculatePrice(uint256 currentSupply) internal pure returns (uint256) {
        if (currentSupply == 0) {
            return INITIAL_PRICE;
        }
        uint256 supplyRatio = (currentSupply * 1e18) / PRICE_STEP_SIZE;
        return (INITIAL_PRICE * (1e18 + (supplyRatio * supplyRatio) / 1e18)) / 1e18;
    }

    /**
     * @notice Get the current price for a token
     * @param tokenAddress Address of the token
     * @return Current price per token in native currency
     */
    function getCurrentPrice(address tokenAddress) public view onlyValidToken(tokenAddress) returns (uint256) {
        return _calculatePrice(tokenInfo[tokenAddress].currentSupply);
    }

    // ==================== UTILITY FUNCTIONS ====================
    
    /**
     * @notice Get token information
     * @param tokenAddress Address of the token
     * @return TokenInfo struct containing all token details
     */
    function getTokenInfo(address tokenAddress) external view returns (TokenInfo memory) {
        return tokenInfo[tokenAddress];
    }

    /**
     * @notice Audits TRUST/native currency accounting for a token
     * @dev This function verifies that curveLiquidity matches expected accounting
     *      by checking that token contract balance >= curveLiquidity (accounting can't exceed reality)
     *      Returns detailed breakdown of accounting state
     *      Each token holds its own liquidity, so we check the token contract balance
     * @param tokenAddress Address of the token to audit
     * @return accountingValid Whether accounting is valid (curveLiquidity <= token contract balance)
     * @return curveLiquidityAmount Tracked bonding curve liquidity
     * @return contractBalance Actual token contract native currency balance
     * @return balanceDifference Difference between token contract balance and tracked liquidity
     */
    function auditTrustAccounting(address tokenAddress) 
        external 
        view 
        onlyValidToken(tokenAddress) 
        returns (
            bool accountingValid,
            uint256 curveLiquidityAmount,
            uint256 contractBalance,
            uint256 balanceDifference
        ) 
    {
        curveLiquidityAmount = curveLiquidity[tokenAddress];
        // Each token holds its own liquidity, so check the token contract balance
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        contractBalance = tokenContract.getNativeBalance();
        
        // Accounting is valid if token contract has at least as much balance as tracked
        // (token contract can have more due to other sources like direct transfers, but not less)
        accountingValid = contractBalance >= curveLiquidityAmount;
        balanceDifference = contractBalance >= curveLiquidityAmount 
            ? contractBalance - curveLiquidityAmount 
            : 0;
    }

    /**
     * @notice Validates DEX router configuration
     * @dev Helper function to check if router is properly configured before migration
     * @return routerValid Whether router address has code
     * @return wethAddress WETH address from router (or zero if call fails)
     * @return factoryAddress Factory address from router (or zero if call fails)
     */
    function validateRouter() external view returns (
        bool routerValid,
        address wethAddress,
        address factoryAddress
    ) {
        address router = dexRouter; // Load storage variable into local for assembly
        if (router == address(0)) {
            return (false, address(0), address(0));
        }
        
        // Check if router has code
        uint256 routerCodeSize;
        assembly {
            routerCodeSize := extcodesize(router)
        }
        routerValid = routerCodeSize > 0;
        
        if (!routerValid) {
            return (false, address(0), address(0));
        }
        
        // Try to get WETH address
        try IDEXRouter(router).WETH() returns (address weth) {
            wethAddress = weth;
        } catch {
            wethAddress = address(0);
        }
        
        // Try to get factory address
        try IDEXRouter(router).factory() returns (address factory) {
            factoryAddress = factory;
        } catch {
            factoryAddress = address(0);
        }
        
        return (routerValid, wethAddress, factoryAddress);
    }

    // ==================== COMMENT SYSTEM ====================
    
    /**
     * @notice Add a comment to a token (requires exact fee)
     * @dev User must send COMMENT_FEE in native currency with this transaction
     * @param tokenAddress Address of the token to comment on
     * @param commentText The comment text
     */
    function addComment(address tokenAddress, string calldata commentText)
        external
        payable
        nonReentrant
        onlyValidToken(tokenAddress)
    {
        if (bytes(commentText).length == 0) revert InvalidInput();
        if (msg.value != COMMENT_FEE) revert InvalidInput();
        
        // Store comment
        tokenComments[tokenAddress].push(
            Comment({
                commenter: msg.sender,
                text: commentText,
                timestamp: block.timestamp
            })
        );

        // Transfer fee to treasury (native currency)
        (bool feeSent, ) = payable(treasuryAddress).call{value: COMMENT_FEE}("");
        if (!feeSent) revert TransferFailed();

        emit TokenCommented(tokenAddress, msg.sender, commentText, block.timestamp);
    }



    /**
     * @notice Collects and splits accumulated transfer fees between creator and launchpad
     * @dev Can be called by anyone to distribute accumulated fees
     * @param tokenAddress Address of the token
     */
    function collectAndSplitTransferFees(address tokenAddress) external onlyValidToken(tokenAddress) {
        if (!transferFeeEnabled[tokenAddress]) revert InvalidInput();
        
        TokenInfo memory token = tokenInfo[tokenAddress];
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        
        // Get accumulated fees in launchpad contract
        uint256 accumulatedFees = tokenContract.balanceOf(address(this));
        if (accumulatedFees == 0) revert InvalidInput();
        
        // Split fees 50/50 between creator and launchpad
        uint256 creatorShare = accumulatedFees / 2;
        uint256 launchpadShare = accumulatedFees - creatorShare;
        
        // Transfer creator's share
        if (creatorShare > 0) {
            if (!tokenContract.transfer(token.creator, creatorShare)) revert TransferFailed();
        }
        
        // Launchpad's share stays in contract (can be used for protocol operations)
        
        emit TransferFeeCollected(tokenAddress, address(0), accumulatedFees, creatorShare, launchpadShare);
    }

    // ==================== ADMIN FUNCTIONS ====================
    
    /**
     * @notice Get available withdrawal amount for emergency withdrawal
     * @dev Returns the maximum tokens and native currency that can be withdrawn for a recipient
     * @param tokenAddress Address of the token
     * @param recipient Address of the user
     * @return availableTokenAmount Maximum tokens that can be withdrawn (net of sells)
     * @return availableNativeAmount Native currency that would be refunded for available tokens
     */
    function getAvailableWithdrawalAmount(address tokenAddress, address recipient) 
        external 
        view 
        onlyValidToken(tokenAddress) 
        returns (
            uint256 availableTokenAmount, 
            uint256 availableNativeAmount
        ) 
    {
        uint256 purchasedAmount = userTokenPurchases[tokenAddress][recipient];
        uint256 userContribution = userContributions[tokenAddress][recipient];
        
        // Available token amount is what user has purchased (net of sells)
        availableTokenAmount = purchasedAmount;
        
        // Calculate proportional native currency refund
        if (purchasedAmount > 0 && userContribution > 0) {
            // Calculate for all available tokens
            availableNativeAmount = (userContribution * availableTokenAmount) / purchasedAmount;
        }
    }

    /**
     * @notice Emergency withdrawal function to return native currency to all users
     * @dev Owner-only function. No user approval required.
     *      Returns all native currency contributions to all users who purchased the token (no fees)
     *      Does not burn tokens - only refunds native currency
     *      Automatically processes all users who have contributions for this token
     * @param tokenAddress Address of the token
     */
    function emergencyWithdrawTokens(
        address tokenAddress
    ) external onlyOwner onlyValidToken(tokenAddress) {
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        
        // Get all users who have purchased this token
        address[] memory holders = tokenHolders[tokenAddress];
        uint256 holdersLength = holders.length;
        
        if (holdersLength == 0) revert NoTokensPurchased();
        
        // Calculate total refund amount needed and process each user
        uint256 totalRefundAmount = 0;
        for (uint256 i = 0; i < holdersLength; i++) {
            address user = holders[i];
            uint256 userContribution = userContributions[tokenAddress][user];
            
            // Skip users with no contribution (already refunded or no purchases)
            if (userContribution > 0) {
                unchecked {
                    totalRefundAmount += userContribution;
                }
            }
        }
        
        if (totalRefundAmount == 0) revert NoTokensPurchased();
        
        // Verify token contract has sufficient native currency liquidity
        if (tokenContract.getNativeBalance() < totalRefundAmount) revert InsufficientBondingCurveLiquidity();
        
        // TRUST FLOW: Get native currency from token contract (each token holds its own liquidity)
        if (!tokenContract.transferNative(payable(address(this)), totalRefundAmount)) revert TransferFailed();
        
        // Deduct from bonding curve liquidity tracking
        unchecked {
            curveLiquidity[tokenAddress] -= totalRefundAmount;
        }
        
        // Process each user and refund their contribution
        for (uint256 i = 0; i < holdersLength; i++) {
            address user = holders[i];
            uint256 userContribution = userContributions[tokenAddress][user];
            uint256 userPurchasedTokens = userTokenPurchases[tokenAddress][user];
            
            // Skip users with no contribution
            if (userContribution > 0) {
                // Clear user tracking
                delete userTokenPurchases[tokenAddress][user];
                delete userContributions[tokenAddress][user];
                
                // Transfer native currency to user
                (bool success, ) = payable(user).call{value: userContribution}("");
                if (!success) revert TransferFailed();
                
                emit EmergencyWithdrawal(tokenAddress, user, userPurchasedTokens);
            }
        }
    }



    // ==================== TOKEN COMPLETION & MIGRATION ====================
    
    /**
     * @notice Finalizes token completion: migrates all liquidity to DEX
     * @dev Called automatically when bonding curve reaches max or manually by owner
     *      Migrates all held tokens (30% of max supply) and all accumulated native currency to DEX
     * @param tokenAddress Address of the token to finalize
     */
    function _finalizeTokenCompletion(address tokenAddress) internal {
        // Migrate all liquidity to DEX (all held tokens + all native currency balance)
        _migrateToDEX(tokenAddress);
    }

    /**
     * @notice Get factory address from router and verify router
     * @dev Helper function to reduce stack depth
     */
    function _getFactoryAndVerifyRouter() internal view returns (address factory) {
        // Verify router contract exists (has code)
        address routerAddr = dexRouter;
        uint256 routerCodeSize;
        assembly {
            routerCodeSize := extcodesize(routerAddr)
        }
        if (routerCodeSize == 0) {
            revert("DEX router address has no code - check router address is correct");
        }
        
        // Get factory address from router
        try IDEXRouter(dexRouter).factory() returns (address factoryAddr) {
            factory = factoryAddr;
            if (factory == address(0)) revert InvalidAddress();
        } catch {
            revert("Router factory() call failed - router may not support this function or interface is incorrect");
        }
    }
    
    /**
     * @notice Get or create DEX pair
     * @dev Helper function to reduce stack depth
     *      Checks if pair exists and has existing liquidity
     */
    function _getOrCreatePair(address tokenAddress, address wethAddress, address factory) internal returns (address pair) {
        pair = IDEXFactory(factory).getPair(tokenAddress, wethAddress);
        if (pair == address(0)) {
            // Pair doesn't exist, create it
            try IDEXFactory(factory).createPair(tokenAddress, wethAddress) returns (address newPair) {
                if (newPair == address(0)) revert InvalidInput();
                pair = newPair;
            } catch Error(string memory reason) {
                revert(string(abi.encodePacked("Pair creation failed: ", reason)));
            } catch {
                revert("Pair creation failed - factory may not support createPair function");
            }
        } else {
            // Pair exists - check if it has existing liquidity (this would require matching ratio)
            // For now, we'll let the router handle this, but it may fail if ratio doesn't match
        }
    }
    
    /**
     * @notice Wrap native currency and verify balances
     * @dev Helper function to reduce stack depth
     */
    function _wrapNativeAndVerify(address wethAddress, uint256 nativeAmount) internal {
        // ETH Accounting Safeguard #5: Capture balance before wrapping
        uint256 balanceBeforeWrap = address(this).balance;
        _wrapNativeToWETH(wethAddress, nativeAmount);
        
        // ETH Accounting Safeguard #6: Verify native currency was wrapped correctly
        if (balanceBeforeWrap - address(this).balance != nativeAmount) revert InvalidInput();
        
        // ETH Accounting Safeguard #7: Verify WETH balance matches wrapped amount
        if (IWETH(wethAddress).balanceOf(address(this)) < nativeAmount) revert InsufficientBalance();
    }
    
    /**
     * @notice Add liquidity and verify WETH consumption
     * @dev Helper function to reduce stack depth
     */
    function _addLiquidityAndVerify(
        address tokenAddress,
        address wethAddress,
        uint256 tokenAmount,
        uint256 nativeAmount,
        MemeToken tokenContract
    ) internal returns (uint256 liquidity) {
        // Approve tokens and WETH
        _approveTokens(tokenContract, tokenAmount);
        _approveWETH(wethAddress, nativeAmount);
        
        // ETH Accounting Safeguard #8: Add liquidity and verify
        IWETH wethContract = IWETH(wethAddress);
        uint256 wethBalanceBefore = wethContract.balanceOf(address(this));
        liquidity = _addLiquidity(tokenAddress, wethAddress, tokenAmount, nativeAmount);
        
        // ETH Accounting Safeguard #9: Verify WETH was consumed or liquidity was added
        uint256 wethBalanceAfter = wethContract.balanceOf(address(this));
        if (wethBalanceBefore <= wethBalanceAfter && liquidity == 0) revert InvalidInput();
        if (wethBalanceBefore > wethBalanceAfter) {
            if (wethBalanceBefore - wethBalanceAfter < (nativeAmount * 99) / 100 && liquidity == 0) {
                revert InvalidInput();
            }
        }
    }

    /**
     * @notice Migrates token liquidity to a DEX (Uniswap, etc.)
     * @dev Wraps native currency to WETH, then adds liquidity using addLiquidity() with token and WETH
     *      Includes comprehensive ETH accounting safeguards to ensure no funds are lost
     * 
     * TRUST FLOW AUDIT - DEX Migration:
     * 1. Source of native currency: token contract balance (each token holds its own liquidity)
     * 2. All buys send netPayment (after fee) to token contract, tracked in curveLiquidity
     * 3. All sells get gross payment (before fee) from token contract, deducted from curveLiquidity
     * 4. At migration: curveLiquidity represents net native currency held in token contract
     * 5. Native currency is transferred from token contract to launchpad, wrapped to WETH, and added to DEX LP
     * 6. After migration, curveLiquidity is reset to 0
     * 
     * @param tokenAddress Address of the token to migrate
     */
    function _migrateToDEX(address tokenAddress) internal {
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        
        // Get all tokens held by contract (should be 30% of max supply)
        uint256 tokenAmount = tokenContract.balanceOf(address(this));
        // TRUST FLOW: Use bonding curve liquidity for migration
        // This represents the net native currency accumulated from buy/sell operations
        // (fees were already deducted and sent to treasury in buyTokens/sellTokens)
        uint256 nativeAmount = curveLiquidity[tokenAddress];
        
        if (tokenAmount == 0) revert InvalidInput();
        if (nativeAmount == 0) revert InvalidInput();
        if (dexRouter == address(0)) revert InvalidAddress();
        
        // ETH Accounting Safeguard #1: Verify token contract has sufficient balance for migration
        // Each token holds its own liquidity, so we check the token contract balance
        if (tokenContract.getNativeBalance() < nativeAmount) revert InsufficientBalance();
        
        // ETH Accounting Safeguard #2: Verify curveLiquidity matches token contract balance
        // This ensures we're only migrating funds that were tracked from buy/sell operations
        // The token contract balance should match or exceed curveLiquidity (allowing for rounding)
        
        // ETH Accounting Safeguard #3: Transfer native currency from token contract to launchpad
        // This is needed because we need to wrap it to WETH and add liquidity
        if (!tokenContract.transferNative(payable(address(this)), nativeAmount)) revert TransferFailed();
        
        // ETH Accounting Safeguard #4: Capture initial launchpad contract balance after transfer
        uint256 initialContractBalance = address(this).balance;
        if (initialContractBalance < nativeAmount) revert InsufficientBalance();
        
        // STEP 1: Get WETH address and factory, verify router
        address wethAddress = _getWETHAddress();
        address factory = _getFactoryAndVerifyRouter();
        
        // STEP 2: Wrap native currency (TRUST) to WTRUST/WETH
        _wrapNativeAndVerify(wethAddress, nativeAmount);
        
        // STEP 3: Get or create pair
        address pair = _getOrCreatePair(tokenAddress, wethAddress, factory);
        
        // STEP 4: Add liquidity and verify
        uint256 liquidity = _addLiquidityAndVerify(tokenAddress, wethAddress, tokenAmount, nativeAmount, tokenContract);
        
        // ETH Accounting Safeguard #10: Final balance check - verify no unexpected ETH remains
        // Allow 1 wei tolerance for rounding
        if (address(this).balance > initialContractBalance - nativeAmount + 1) revert InvalidInput();
        
        // Finalize migration (store LP token, enable transfer fees, reset accounting)
        _finalizeMigration(tokenAddress, tokenContract, pair, wethAddress, liquidity);
    }

    /**
     * @notice Check if token is ready for migration
     * @dev Validates that token has sufficient liquidity and tokens for DEX migration
     * @param tokenAddress Address of the token
     * @return ready Whether token is ready for migration
     * @return tokenAmount Tokens available for migration
     * @return nativeAmount Native currency available for migration
     * @return tokenContractBalance Token contract's native balance
     */
    function checkMigrationReadiness(address tokenAddress) 
        external 
        view 
        onlyValidToken(tokenAddress) 
        returns (
            bool ready,
            uint256 tokenAmount,
            uint256 nativeAmount,
            uint256 tokenContractBalance
        ) 
    {
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        tokenAmount = tokenContract.balanceOf(address(this));
        nativeAmount = curveLiquidity[tokenAddress];
        tokenContractBalance = tokenContract.getNativeBalance();
        
        ready = tokenAmount > 0 && 
                nativeAmount > 0 && 
                tokenContractBalance >= nativeAmount &&
                dexRouter != address(0);
    }

    /**
     * @notice Manually complete a token launch (owner only)
     * @dev Allows owner to force completion before reaching max supply
     *      Use checkMigrationReadiness() first to verify token is ready
     * @param tokenAddress Address of the token to complete
     */
    function completeTokenLaunch(address tokenAddress) external onlyOwner onlyValidToken(tokenAddress) {
        TokenInfo storage token = tokenInfo[tokenAddress];
        require(!token.completed, "Completed");

        token.completed = true;
        
        uint256 finalPrice = _calculatePrice(token.currentSupply);
        _finalizeTokenCompletion(tokenAddress);
        emit TokenCompleted(tokenAddress, token.currentSupply, finalPrice);
    }
    
    /**
     * @notice Get WETH address from router
     * @dev Helper function to reduce stack depth
     */
    function _getWETHAddress() internal view returns (address) {
        address wethAddress;
        try IDEXRouter(dexRouter).WETH() returns (address weth) {
            wethAddress = weth;
        } catch {
            revert("Router WETH() call failed - verify router address and interface");
        }
        require(wethAddress != address(0), "WETH address is zero");
        return wethAddress;
    }
    
    
    /**
     * @notice Approve router to spend tokens
     * @dev Helper function to reduce stack depth
     */
    function _approveTokens(MemeToken tokenContract, uint256 tokenAmount) internal {
        uint256 currentAllowance = tokenContract.allowance(address(this), dexRouter);
        if (currentAllowance > 0) {
            tokenContract.approve(dexRouter, 0);
        }
        tokenContract.approve(dexRouter, tokenAmount);
    }
    
    /**
     * @notice Approve router to spend WETH
     * @dev Helper function to reduce stack depth
     */
    function _approveWETH(address wethAddress, uint256 wethAmount) internal {
        IWETH weth = IWETH(wethAddress);
        uint256 currentAllowance = weth.allowance(address(this), dexRouter);
        if (currentAllowance > 0) {
            weth.approve(dexRouter, 0);
        }
        weth.approve(dexRouter, wethAmount);
    }
    
    /**
     * @notice Wrap native currency to WETH
     * @dev Helper function to reduce stack depth
     */
    function _wrapNativeToWETH(address wethAddress, uint256 nativeAmount) internal {
        IWETH(wethAddress).deposit{value: nativeAmount}();
    }
    
    /**
     * @notice Add liquidity to DEX using addLiquidity() with WETH
     * @dev Helper function to reduce stack depth
     *      Assumes WETH is already wrapped and approved (wrapping happens in _migrateToDEX)
     * @param tokenAddress Address of the token
     * @param wethAddress Address of WETH/WTRUST
     * @param tokenAmount Amount of tokens to add
     * @param nativeAmount Amount of native currency (already wrapped to WETH)
     */
    function _addLiquidity(address tokenAddress, address wethAddress, uint256 tokenAmount, uint256 nativeAmount) internal returns (uint256 liquidity) {
        // Calculate minimum amounts (1% slippage)
        // Note: Some DEX routers require minimum liquidity amounts (e.g., 1000 wei)
        // If amounts are too small, this will fail
        uint256 minTokenAmount = (tokenAmount * 99) / 100;
        uint256 minWETHAmount = (nativeAmount * 99) / 100;
        
        // Ensure minimum amounts are not zero (some routers reject zero minimums)
        if (minTokenAmount == 0 || minWETHAmount == 0) {
            revert("Liquidity amounts too small for DEX migration");
        }
        
        // Call router to add liquidity
        return _callAddLiquidity(tokenAddress, wethAddress, tokenAmount, nativeAmount, minTokenAmount, minWETHAmount);
    }
    
    /**
     * @notice Internal function to call router's addLiquidity
     * @dev Separated to reduce stack depth in _addLiquidity
     */
    function _callAddLiquidity(
        address tokenAddress,
        address wethAddress,
        uint256 tokenAmount,
        uint256 nativeAmount,
        uint256 minTokenAmount,
        uint256 minWETHAmount
    ) internal returns (uint256 liquidity) {
        IDEXRouter router = IDEXRouter(dexRouter);
        uint256 deadline = block.timestamp + 300;
        
        // Verify balances and allowances (already checked in _migrateToDEX, but double-check for safety)
        IWETH weth = IWETH(wethAddress);
        if (weth.balanceOf(address(this)) < nativeAmount) revert InvalidInput();
        if (weth.allowance(address(this), dexRouter) < nativeAmount) revert InvalidInput();
        
        MemeToken tokenContract = MemeToken(payable(tokenAddress));
        if (tokenContract.balanceOf(address(this)) < tokenAmount) revert InvalidInput();
        if (tokenContract.allowance(address(this), dexRouter) < tokenAmount) revert InvalidInput();
        
        // Note: Pair is already created/verified in _migrateToDEX before calling this function
        // No need to check again here
        
        try router.addLiquidity(
            tokenAddress,
            wethAddress,
            tokenAmount,
            nativeAmount,
            minTokenAmount,
            minWETHAmount,
            address(this),
            deadline
        ) returns (uint256 /* amountA */, uint256 /* amountB */, uint256 _liquidity) {
            if (_liquidity == 0) revert InvalidInput();
            return _liquidity;
        } catch Error(string memory reason) {
            revert(string(abi.encodePacked("Router error: ", reason)));
        } catch (bytes memory lowLevelData) {
            // Check if router address is valid (has code)
            address routerAddr = dexRouter;
            uint256 routerCodeSize;
            assembly {
                routerCodeSize := extcodesize(routerAddr)
            }
            if (routerCodeSize == 0) {
                revert("Router address has no code - check router address");
            }
            
            if (lowLevelData.length == 0) {
                revert("Router addLiquidity call failed - function may not exist or parameters invalid");
            }
            // Try to decode error message if available
            if (lowLevelData.length >= 68) {
                bytes4 errorSelector = bytes4(0x08c379a0); // Error(string) selector
                bytes4 receivedSelector;
                assembly {
                    receivedSelector := mload(add(lowLevelData, 0x20))
                }
                if (receivedSelector == errorSelector) {
                    (string memory errorMessage) = abi.decode(lowLevelData, (string));
                    revert(string(abi.encodePacked("Router error: ", errorMessage)));
                }
            }
            revert("Router addLiquidity failed - check router address and parameters");
        }
    }
    
    
    /**
     * @notice Get LP token address from factory
     * @dev Helper function to reduce stack depth
     */
    function _getLPToken(address tokenAddress, address wethAddress) internal view returns (address) {
        address factory;
        try IDEXRouter(dexRouter).factory() returns (address factoryAddr) {
            factory = factoryAddr;
        } catch {
            revert("Router factory() call failed");
        }
        if (factory == address(0)) revert InvalidAddress();
        address lpToken = IDEXFactory(factory).getPair(tokenAddress, wethAddress);
        if (lpToken == address(0)) revert InvalidInput();
        return lpToken;
    }

}
