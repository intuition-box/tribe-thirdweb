// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {MemeToken} from "./MemeToken.sol";
import {DEXMigrationLib} from "./DEXMigrationLib.sol";

/// @title MemeLaunchpad
/// @notice Bonding curve launchpad for meme tokens. Users buy/sell before DEX migration; creators hold 30%, curve uses 70%.
///
/// Trust model (for audits):
/// - Only owner: setDexRouter, setFeePercent, setSellSpreadPercent, setTokenSellSpread, emergencyWithdrawTokens, recoverSellSpreadLiquidity, completeTokenLaunch.
/// - Only launchpad can mint/burn MemeToken and move native via MemeToken.transferNative; token creation and buy/sell are permissioned by onlyValidToken.
/// - Invariant: curveLiquidity[t] <= MemeToken(t).getNativeBalance() (excess = balance - curve is sell-spread; recoverable by owner).
/// - Reentrancy: guarded on all payable and fund-moving paths (buy, sell, addComment, emergencyWithdraw, recoverSellSpread, completeTokenLaunch, collectAndSplitTransferFees).

interface IDEXRouter {
    function addLiquidity(address,address,uint,uint,uint,uint,address,uint) external returns (uint,uint,uint);
    function factory() external view returns (address);
    function WETH() external view returns (address);
}

interface IWETH {
    function deposit() external payable;
    function approve(address,uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
    function allowance(address,address) external view returns (uint256);
}

contract MemeLaunchpad {
    // --- Access & Reentrancy ---
    address private _owner;
    uint256 private _status;
    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED = 2;

    modifier onlyOwner() { if (msg.sender != _owner) revert NotOwner(); _; }
    modifier nonReentrant() { if (_status == _ENTERED) revert ReentrantCall(); _status = _ENTERED; _; _status = _NOT_ENTERED; }
    modifier onlyValidToken(address t) { if (!isValidToken[t]) revert InvalidToken(); _; }

    event TokenCreated(address indexed token,string name,string symbol,string metadata,address indexed creator,uint256);
    event TokensBought(address indexed token,address indexed buyer,uint256 payment,uint256 tokens,uint256 price);
    event TokensSold(address indexed token,address indexed seller,uint256 tokens,uint256 payment,address indexed payoutRecipient);
    event TokenCompleted(address indexed token,uint256 supply,uint256 price);
    event TokenCommented(address indexed token,address indexed commenter,string comment,uint256 timestamp);
    event TokenUnlocked(address indexed token,address indexed creator,uint256 amount);
    event DEXRouterUpdated(address indexed oldR,address indexed newR);
    event FeePercentUpdated(uint256 oldP,uint256 newP);
    event TransferFeeEnabled(address indexed token,uint256 pct);
    event CreatorTransferFeeSet(address indexed token,address indexed creator,uint256 pct);
    event TransferFeeCollected(address indexed token,address indexed from,uint256 total,uint256 creator,uint256 launchpad);
    event LPLocked(address indexed token,address lpToken,uint256 amount);
    event EmergencyWithdrawal(address indexed token,address indexed recipient,uint256 amount);
    event SellSpreadPercentUpdated(uint256 oldP,uint256 newP);
    event TokenSellSpreadSet(address indexed token,address indexed creator,uint256 pct);
    event SellSpreadLiquidityRecovered(address indexed token,uint256 amount,address indexed to);

    error TokenLaunchCompleted(); error MustSendPayment(); error NoTokensToBuy(); error SlippageTooHigh();
    error ExceedsMaxSupply(); error MustSellTokens(); error InsufficientCirculatingSupply(); error CreatorBuyLimitExceeded();
    error TokenLocked(); error InvalidAddress(); error InvalidInput(); error NoTokensPurchased(); error FeeExceedsMaximum();
    error NotOwner(); error ReentrantCall(); error InvalidToken(); error TransferFailed(); error InsufficientBondingCurveLiquidity();
    error InsufficientBalance(); error SlippageTooHighSell(); error InsufficientTokenBalance(); error SellSpreadExceedsMaximum();
    error NoExcessLiquidityToRecover();

    // --- Structs & Constants ---
    struct TokenInfo { string name; string symbol; string metadata; address creator; uint256 heldTokens; uint256 maxSupply; uint256 currentSupply; bool completed; uint256 creationTime; }
    struct Comment { address commenter; string text; uint256 timestamp; }
    struct UserVolume { uint256 totalBuyVolume; uint256 totalSellVolume; }

    uint256 public constant BONDING_CURVE_PERCENT=70; uint256 public constant HELD_PERCENT=30;
    uint256 public constant MAX_SUPPLY=1_000_000_000*1e18; uint256 public constant INITIAL_PRICE=0.0001533e18;
    uint256 public constant MAX_FEE_PERCENT=20; uint256 public constant PRICE_STEP_SIZE=10_000_000*1e18;
    uint256 public constant CREATOR_MAX_BUY_PERCENT=20; uint256 public constant CREATOR_UNLOCK_THRESHOLD_PERCENT=2;
    uint256 public constant COMMENT_FEE=0.025e18; uint256 public constant EXCESS_LIQUIDITY_PRICE_SCALE=100 ether;
    uint256 public constant MAX_TRANSFER_FEE_PERCENT=5; uint256 public constant MAX_SELL_SPREAD_PERCENT=25;

    mapping(address=>TokenInfo) public tokenInfo; mapping(address=>bool) public isValidToken;
    address[] public allTokens; mapping(address=>address[]) private tokenHolders;
    mapping(address=>mapping(address=>bool)) private isTokenHolder; mapping(address=>Comment[]) private tokenComments;
    mapping(address=>mapping(address=>uint256)) public creatorBoughtAmount; mapping(address=>bool) public tokenUnlocked;
    address public treasuryAddress; mapping(address=>UserVolume) public userVolumes;
    mapping(address=>uint256) public tokenTotalValueTraded; address public dexRouter;
    address public immutable dexMigrationLib;
    uint256 public feePercent; uint256 public defaultPostMigrationTransferFeePercent;
    uint256 public sellSpreadPercent; mapping(address=>bool) public hasTokenSellSpread;
    mapping(address=>uint256) public tokenSellSpreadPercent; mapping(address=>address) public tokenLPToken;
    mapping(address=>bool) public transferFeeEnabled; mapping(address=>uint256) public creatorTransferFeePercent;
    mapping(address=>uint256) public curveLiquidity; mapping(address=>mapping(address=>uint256)) public userTokenPurchases;
    mapping(address=>mapping(address=>uint256)) public userContributions;

    // --- Admin ---
    constructor(address _treasury, address _router, address _dexLib) {
        if(_treasury==address(0))revert InvalidAddress();
        if(_dexLib==address(0))revert InvalidAddress();
        _owner=msg.sender; _status=_NOT_ENTERED; treasuryAddress=_treasury; dexRouter=_router; dexMigrationLib=_dexLib;
        feePercent=2; defaultPostMigrationTransferFeePercent=2; sellSpreadPercent=2;
    }

    receive() external payable {}
    function owner() external view returns(address){return _owner;}
    function allTokensLength() external view returns(uint256){return allTokens.length;}

    function transferOwnership(address newOwner) external onlyOwner { if(newOwner==address(0))revert InvalidAddress(); _owner=newOwner; }
    function setDexRouter(address newR) external onlyOwner { if(newR==address(0))revert InvalidAddress(); emit DEXRouterUpdated(dexRouter,newR); dexRouter=newR; }
    function setFeePercent(uint256 newP) external onlyOwner { if(newP>MAX_FEE_PERCENT)revert FeeExceedsMaximum(); emit FeePercentUpdated(feePercent,newP); feePercent=newP; }
    function setDefaultPostMigrationTransferFeePercent(uint256 newP) external onlyOwner { if(newP>MAX_TRANSFER_FEE_PERCENT)revert FeeExceedsMaximum(); defaultPostMigrationTransferFeePercent=newP; }
    function setSellSpreadPercent(uint256 newP) external onlyOwner { if(newP>MAX_SELL_SPREAD_PERCENT)revert SellSpreadExceedsMaximum(); emit SellSpreadPercentUpdated(sellSpreadPercent,newP); sellSpreadPercent=newP; }
    function setCreatorTransferFee(address t,uint256 pct) external onlyValidToken(t) { TokenInfo memory ti=tokenInfo[t]; if(msg.sender!=ti.creator)revert InvalidInput(); if(ti.completed)revert TokenLaunchCompleted(); if(pct>MAX_TRANSFER_FEE_PERCENT)revert FeeExceedsMaximum(); creatorTransferFeePercent[t]=pct; emit CreatorTransferFeeSet(t,ti.creator,pct); }
    function setTokenSellSpread(address t,uint256 pct) external onlyOwner onlyValidToken(t) { if(tokenInfo[t].completed)revert TokenLaunchCompleted(); if(pct>MAX_SELL_SPREAD_PERCENT)revert SellSpreadExceedsMaximum(); hasTokenSellSpread[t]=true; tokenSellSpreadPercent[t]=pct; emit TokenSellSpreadSet(t,tokenInfo[t].creator,pct); }

    // --- Token Creation ---
    function createToken(string memory name,string memory symbol,string memory metadata,uint256 spreadPercent) external returns(address) {
        if(bytes(name).length==0||bytes(symbol).length==0)revert InvalidInput();
        MemeToken token=new MemeToken(name,symbol,MAX_SUPPLY); token.setLaunchpad(address(this));
        uint256 held=(MAX_SUPPLY*HELD_PERCENT)/100;
        tokenInfo[address(token)]=TokenInfo(name,symbol,metadata,msg.sender,held,MAX_SUPPLY,0,false,block.timestamp);
        isValidToken[address(token)]=true; allTokens.push(address(token));
        if(spreadPercent<=MAX_SELL_SPREAD_PERCENT){ hasTokenSellSpread[address(token)]=true; tokenSellSpreadPercent[address(token)]=spreadPercent; emit TokenSellSpreadSet(address(token),msg.sender,spreadPercent); }
        token.mint(address(this),held); emit TokenCreated(address(token),name,symbol,metadata,msg.sender,0);
        return address(token);
    }

    // --- Buy (bonding curve) ---
    function _processCreatorBuy(address t,TokenInfo storage ti,uint256 bondMax,uint256 bought) private {
        if(msg.sender!=ti.creator)return;
        uint256 maxBuy=(bondMax*CREATOR_MAX_BUY_PERCENT)/100; uint256 prev=creatorBoughtAmount[t][msg.sender];
        uint256 total; unchecked{total=prev+bought;}
        if(total>maxBuy)revert CreatorBuyLimitExceeded(); creatorBoughtAmount[t][msg.sender]=total;
        if(!tokenUnlocked[t]&&total>=(ti.maxSupply*CREATOR_UNLOCK_THRESHOLD_PERCENT)/100){ tokenUnlocked[t]=true; emit TokenUnlocked(t,msg.sender,total); }
    }
    function _processBuyCompletionIfReached(address t,TokenInfo storage ti,uint256 bondMax,uint256 excess) private {
        if(ti.currentSupply<bondMax||ti.completed)return; ti.completed=true;
        emit TokenCompleted(t,ti.currentSupply,_calculatePrice(ti.currentSupply,excess)); _finalizeTokenCompletion(t);
    }
    function _processBuyPaymentAndTracking(address t,uint256 payment,uint256 bought,uint256 price) private {
        uint256 fee=(payment*feePercent)/100; (bool ok,)=payable(treasuryAddress).call{value:fee}(""); if(!ok)revert TransferFailed();
        uint256 net; unchecked{net=payment-fee; curveLiquidity[t]+=net; userContributions[t][msg.sender]+=net;}
        (ok,)=payable(t).call{value:net}(""); if(!ok)revert TransferFailed();
        unchecked{ userVolumes[msg.sender].totalBuyVolume+=payment; tokenTotalValueTraded[t]+=net; }
        emit TokensBought(t,msg.sender,net,bought,price);
    }

    /// @notice Buy tokens from bonding curve. Send native currency with tx. Buy price uses supply only (not sell-spread excess).
    function buyTokens(address t,uint256 minOut) external payable nonReentrant onlyValidToken(t) returns(uint256 bought) {
        TokenInfo storage ti=tokenInfo[t];
        uint256 payment=msg.value;
        if(ti.completed)revert InvalidInput();
        if(payment==0)revert MustSendPayment();
        if(!tokenUnlocked[t]&&msg.sender!=ti.creator)revert TokenLocked();
        uint256 price=_calculatePrice(ti.currentSupply,0);
        bought=(payment*1e18)/price; if(bought==0)revert NoTokensToBuy(); if(bought<minOut)revert SlippageTooHigh();
        uint256 bondMax=(ti.maxSupply*BONDING_CURVE_PERCENT)/100; uint256 newSupply; unchecked{newSupply=ti.currentSupply+bought;}
        if(newSupply>bondMax)revert ExceedsMaxSupply();
        _processCreatorBuy(t,ti,bondMax,bought); ti.currentSupply=newSupply;
        _processBuyCompletionIfReached(t,ti,bondMax,0);
        MemeToken(payable(t)).mint(msg.sender,bought);
        if(!isTokenHolder[t][msg.sender]){ isTokenHolder[t][msg.sender]=true; tokenHolders[t].push(msg.sender); }
        unchecked{userTokenPurchases[t][msg.sender]+=bought;}
        _processBuyPaymentAndTracking(t,payment,bought,price); return bought;
    }

    // --- Sell (bonding curve) ---
    /// @notice Sell tokens back to bonding curve. Approve this contract first. Native payout goes to payoutTo if set, else to msg.sender.
    function sellTokens(address t,uint256 amount,uint256 minOut,address payoutTo) external nonReentrant onlyValidToken(t) returns(uint256 net) {
        TokenInfo storage ti=tokenInfo[t];
        if(ti.completed)revert TokenLaunchCompleted();
        if(amount==0)revert MustSellTokens();
        address seller=msg.sender;
        address payoutReceiver=(payoutTo!=address(0))?payoutTo:seller;
        (uint256 calcPay,uint256 toDist)=_calculateSellPayment(t,seller,amount,minOut);
        net=_processSellTokenOps(t,seller,amount,calcPay,toDist);
        _processSellPayout(t,seller,payoutReceiver,net,toDist,amount);
        return net;
    }

    function _calculateSellPayment(address t,address seller,uint256 amount,uint256 minOut) private view returns(uint256 calcPay,uint256 toDist) {
        if(MemeToken(payable(t)).balanceOf(seller)<amount)revert InsufficientTokenBalance();
        TokenInfo storage ti=tokenInfo[t];
        if(ti.currentSupply<amount||ti.currentSupply==0)revert InsufficientCirculatingSupply();
        uint256 purchased=userTokenPurchases[t][seller];
        uint256 contrib=userContributions[t][seller];
        if(purchased==0||contrib==0)revert NoTokensPurchased();
        if(amount>purchased)revert InsufficientTokenBalance();
        calcPay=(contrib*amount)/purchased;
        if(calcPay==0)revert MustSellTokens();
        toDist=(calcPay*(100-(hasTokenSellSpread[t]?tokenSellSpreadPercent[t]:sellSpreadPercent)))/100;
        if(curveLiquidity[t]<calcPay)revert InsufficientBondingCurveLiquidity();
        if(MemeToken(payable(t)).getNativeBalance()<toDist)revert InsufficientBondingCurveLiquidity();
        if(toDist-(toDist*feePercent)/100<minOut)revert SlippageTooHighSell();
    }
    // Spread: we pull toDist from token; curve is reduced by calcPay so (calcPay-toDist) stays in token as excess. _calculateSellPayment enforces curveLiquidity[t]>=calcPay.
    function _processSellTokenOps(address t,address seller,uint256 amount,uint256 calcPay,uint256 toDist) private returns(uint256 net) {
        TokenInfo storage ti=tokenInfo[t];
        unchecked{ ti.currentSupply-=amount; }
        MemeToken(payable(t)).burnFrom(seller,amount);
        if(!MemeToken(payable(t)).transferNative(payable(address(this)),toDist))revert TransferFailed();
        unchecked{ curveLiquidity[t]-=calcPay; }
        uint256 purchased=userTokenPurchases[t][seller];
        if(amount>=purchased){
            delete userTokenPurchases[t][seller];
            delete userContributions[t][seller];
        } else {
            unchecked{
                userTokenPurchases[t][seller]-=amount;
                userContributions[t][seller]-=calcPay;
            }
        }
        unchecked{ net=toDist-(toDist*feePercent)/100; }
    }

    function _processSellPayout(address t,address seller,address payoutReceiver,uint256 net,uint256 toDist,uint256 amount) private {
        (bool ok,)=payable(payoutReceiver).call{value:net}("");
        if(!ok)revert TransferFailed();
        (ok,)=payable(treasuryAddress).call{value:toDist-net}("");
        if(!ok)revert TransferFailed();
        unchecked{
            userVolumes[seller].totalSellVolume+=net;
            tokenTotalValueTraded[t]+=net;
        }
        emit TokensSold(t,seller,amount,net,payoutReceiver);
    }

    function _finalizeMigration(address t,MemeToken tc,address pair,address weth,uint256 liq) private {
        if(pair==address(0))revert InvalidInput();
        tokenLPToken[t]=pair;
        uint256 fee=creatorTransferFeePercent[t]!=0?creatorTransferFeePercent[t]:defaultPostMigrationTransferFeePercent;
        tc.enableTransferFee(fee);
        transferFeeEnabled[t]=true;
        tokenInfo[t].heldTokens=0;
        curveLiquidity[t]=0;
        emit LPLocked(t,pair,liq);
        emit TransferFeeEnabled(t,fee);
    }

    // --- Pricing: quadratic in supply. Buy uses excess=0; getCurrentPrice includes excess (sell-spread floor). ---
    function _getExcessLiquidity(address t) internal view returns(uint256) {
        uint256 b=MemeToken(payable(t)).getNativeBalance();
        uint256 tr=curveLiquidity[t];
        return b>tr ? b-tr : 0;
    }
    function _calculatePrice(uint256 supply,uint256 excess) internal pure returns(uint256) {
        uint256 effInit=(INITIAL_PRICE*(1e18+(excess*1e18)/EXCESS_LIQUIDITY_PRICE_SCALE))/1e18;
        if(supply==0)return effInit;
        uint256 ratio=(supply*1e18)/PRICE_STEP_SIZE;
        return (effInit*(1e18+(ratio*ratio)/1e18))/1e18;
    }
    function getCurrentPrice(address t) public view onlyValidToken(t) returns(uint256) {
        return _calculatePrice(tokenInfo[t].currentSupply,_getExcessLiquidity(t));
    }
    /// @notice Excess native balance in token contract from sell spread (token balance minus tracked curve liquidity).
    function getExcessLiquidity(address t) external view onlyValidToken(t) returns(uint256){ return _getExcessLiquidity(t); }

    function getTokenInfo(address t) external view returns(TokenInfo memory) { return tokenInfo[t]; }
    function auditTrustAccounting(address t) external view onlyValidToken(t) returns(bool ok,uint256 curve,uint256 bal,uint256 diff) {
        curve=curveLiquidity[t];
        bal=MemeToken(payable(t)).getNativeBalance();
        ok=bal>=curve;
        diff=bal>=curve ? bal-curve : 0;
    }

    // --- Comments & Transfer Fees ---
    /// @notice Add a comment on a token. Call must send COMMENT_FEE (0.025 ether) as msg.value; fee goes to treasury. Comment is stored and emitted with block.timestamp.
    function addComment(address t,string calldata text) external payable nonReentrant onlyValidToken(t) {
        if(bytes(text).length==0)revert InvalidInput();
        if(msg.value!=COMMENT_FEE)revert InvalidInput();
        uint256 ts=block.timestamp;
        tokenComments[t].push(Comment(msg.sender,text,ts));
        (bool ok,)=payable(treasuryAddress).call{value:COMMENT_FEE}("");
        if(!ok)revert TransferFailed();
        emit TokenCommented(t,msg.sender,text,ts);
    }

    function getComments(address t) external view onlyValidToken(t) returns(Comment[] memory) {
        return tokenComments[t];
    }

    /// @notice Split accumulated transfer fees: half to creator, half remains in this contract as token balance (sweep to treasury separately if desired).
    function collectAndSplitTransferFees(address t) external nonReentrant onlyValidToken(t) {
        if(!transferFeeEnabled[t])revert InvalidInput();
        MemeToken tc=MemeToken(payable(t)); uint256 acc=tc.balanceOf(address(this)); if(acc==0)revert InvalidInput();
        uint256 creator=acc/2; uint256 launchpadShare=acc-creator;
        if(creator>0&&!tc.transfer(tokenInfo[t].creator,creator))revert TransferFailed();
        emit TransferFeeCollected(t,address(0),acc,creator,launchpadShare);
    }

    // --- Emergency & Recovery ---
    /// @notice For a user r: returns their curve-backed token amount and the proportional native refund (e.g. for display). When r holds all their tokens, nat equals their total contribution.
    function getAvailableWithdrawalAmount(address t,address r) external view onlyValidToken(t) returns(uint256 tok,uint256 nat) {
        tok=userTokenPurchases[t][r]; uint256 contrib=userContributions[t][r]; nat=tok>0&&contrib>0?(contrib*tok)/userTokenPurchases[t][r]:0;
    }

    /// @notice Refund all users' native contributions (owner only). Tokens are not burned; holders keep receipt tokens (no further redemption after this).
    function emergencyWithdrawTokens(address t) external onlyOwner nonReentrant onlyValidToken(t) {
        address[] memory holders=tokenHolders[t];
        if(holders.length==0)revert NoTokensPurchased();
        uint256 total=_emergencyWithdrawTotal(t,holders);
        if(total==0)revert NoTokensPurchased();
        MemeToken tc=MemeToken(payable(t));
        if(tc.getNativeBalance()<total)revert InsufficientBondingCurveLiquidity();
        if(!tc.transferNative(payable(address(this)),total))revert TransferFailed();
        unchecked{ curveLiquidity[t]-=total; }
        for(uint256 i;i<holders.length;){ _emergencyWithdrawOne(t,holders[i]); unchecked{i++;} }
    }
    function _emergencyWithdrawTotal(address t,address[] memory holders) private view returns(uint256 total) {
        for(uint256 i;i<holders.length;) {
            uint256 c=userContributions[t][holders[i]];
            if(c>0){ unchecked{ total+=c; } }
            unchecked{ i++; }
        }
    }
    function _emergencyWithdrawOne(address t,address u) private {
        uint256 c=userContributions[t][u];
        if(c==0)return;
        uint256 tok=userTokenPurchases[t][u];
        delete userTokenPurchases[t][u];
        delete userContributions[t][u];
        (bool ok,)=payable(u).call{value:c}("");
        if(!ok)revert TransferFailed();
        emit EmergencyWithdrawal(t,u,tok);
    }

    /// @notice Recover excess liquidity (sell spread) from token contract to treasury.
    function recoverSellSpreadLiquidity(address t) external onlyOwner nonReentrant onlyValidToken(t) returns(uint256 amt) {
        uint256 bal=MemeToken(payable(t)).getNativeBalance(); uint256 tr=curveLiquidity[t]; if(bal<=tr)revert NoExcessLiquidityToRecover();
        unchecked{amt=bal-tr;} if(!MemeToken(payable(t)).transferNative(payable(address(this)),amt))revert TransferFailed();
        (bool ok,)=payable(treasuryAddress).call{value:amt}(""); if(!ok)revert TransferFailed();
        emit SellSpreadLiquidityRecovered(t,amt,treasuryAddress);
    }

    // --- DEX Migration (wrap native → add liquidity via library → finalize) ---
    function _finalizeTokenCompletion(address t) internal { _migrateToDEX(t); }

    function _wrapNativeAndVerify(address w,uint256 amt) internal { IWETH(w).deposit{value:amt}(); if(IWETH(w).balanceOf(address(this))<amt)revert InsufficientBalance(); }

    function _migrateToDEX(address t) internal {
        MemeToken tc=MemeToken(payable(t));
        uint256 tokAmt=tc.balanceOf(address(this));
        uint256 natAmt=curveLiquidity[t];
        if(tokAmt==0||natAmt==0||dexRouter==address(0))revert InvalidInput();
        if(tc.getNativeBalance()<natAmt)revert InsufficientBalance();
        if(!tc.transferNative(payable(address(this)),natAmt))revert TransferFailed();
        if(address(this).balance<natAmt)revert InsufficientBalance();
        address w=_getWETHAddress();
        _wrapNativeAndVerify(w,natAmt);
        _approveTokens(tc,tokAmt);
        _approveWETH(w,natAmt);
        (address pair,uint256 liq)=_callDEXLibAddLiquidity(dexRouter,t,w,tokAmt,natAmt);
        _finalizeMigration(t,tc,pair,w,liq);
    }

    function checkMigrationReadiness(address t) external view onlyValidToken(t) returns(bool ready,uint256 tok,uint256 nat,uint256 bal) {
        MemeToken tc=MemeToken(payable(t)); tok=tc.balanceOf(address(this)); nat=curveLiquidity[t]; bal=tc.getNativeBalance();
        ready=tok>0&&nat>0&&bal>=nat&&dexRouter!=address(0);
    }

    /// @notice Manually complete token launch and migrate to DEX (owner only).
    function completeTokenLaunch(address t) external onlyOwner nonReentrant onlyValidToken(t) {
        TokenInfo storage ti=tokenInfo[t];
        require(!ti.completed,"Done");
        ti.completed=true;
        emit TokenCompleted(t,ti.currentSupply,_calculatePrice(ti.currentSupply,_getExcessLiquidity(t)));
        _finalizeTokenCompletion(t);
    }

    function _getWETHAddress() internal view returns(address) { address w; try IDEXRouter(dexRouter).WETH() returns(address x){w=x;}catch{revert InvalidInput();} if(w==address(0))revert InvalidAddress(); return w; }
    function _approveTokens(MemeToken tc,uint256 amt) internal { if(tc.allowance(address(this),dexRouter)>0)tc.approve(dexRouter,0); tc.approve(dexRouter,amt); }
    function _approveWETH(address w,uint256 amt) internal { IWETH weth=IWETH(w); if(weth.allowance(address(this),dexRouter)>0)weth.approve(dexRouter,0); weth.approve(dexRouter,amt); }

    function _callDEXLibAddLiquidity(address router,address token,address weth,uint256 tokAmt,uint256 natAmt) internal returns(address pair,uint256 liq) {
        (bool ok,bytes memory r)=dexMigrationLib.delegatecall(abi.encodeWithSelector(DEXMigrationLib.addLiquidity.selector,router,token,weth,tokAmt,natAmt));
        if(!ok)revert InvalidInput();
        (pair,liq)=abi.decode(r,(address,uint256));
    }
}
