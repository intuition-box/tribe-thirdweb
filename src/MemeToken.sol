// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MemeToken is ERC20, ERC20Burnable {
    address public launchpad;
    IERC20 public trustToken;
    bool public transferFeeEnabled;
    uint256 public transferFeePercent;

    modifier onlyLaunchpad() {
        require(msg.sender == launchpad, "Only launchpad");
        _;
    }

    constructor(string memory name, string memory symbol, uint256 /*totalSupply*/) ERC20(name, symbol) {}

    /**
     * @notice Allow contract to receive native currency
     * @dev This allows each token contract to hold its own liquidity
     */
    receive() external payable {}

    function setLaunchpad(address _launchpad) external {
        require(launchpad == address(0), "Launchpad already set");
        require(_launchpad != address(0), "Invalid launchpad");
        launchpad = _launchpad;
    }

    function setTrustToken(address _trustToken) external onlyLaunchpad {
        require(address(trustToken) == address(0), "Trust token already set");
        trustToken = IERC20(_trustToken);
    }

    function mint(address to, uint256 amount) external onlyLaunchpad {
        _mint(to, amount);
    }

    function setAllowanceForUser(address spender, uint256 amount) external {
        require(msg.sender == launchpad, "Only launchpad");
        _approve(msg.sender, spender, amount);
    }

    /**
     * @notice Enables transfer fee after DEX migration
     * @dev Can only be called by launchpad. Fee must be <= 100 to avoid underflow in _update.
     * @param feePercent Transfer fee percentage (e.g., 2 = 2%)
     */
    function enableTransferFee(uint256 feePercent) external onlyLaunchpad {
        require(!transferFeeEnabled, "Transfer fee already enabled");
        require(feePercent <= 100, "Fee exceeds 100%");
        transferFeeEnabled = true;
        transferFeePercent = feePercent;
    }

    /**
     * @notice Override _update to add transfer fee after migration
     * @dev Applies fee only if transfer fee is enabled and not minting/burning
     */
    function _update(address from, address to, uint256 value) internal override {
        // Skip fee for minting, burning, or if transfer fee not enabled
        if (from != address(0) && to != address(0) && transferFeeEnabled) {
            // Calculate fee
            uint256 fee = (value * transferFeePercent) / 100;
            uint256 transferAmount = value - fee;
            
            // Transfer fee to launchpad contract (will be split later)
            if (fee > 0) {
                super._update(from, address(launchpad), fee);
            }
            
            // Transfer remaining amount
            if (transferAmount > 0) {
                super._update(from, to, transferAmount);
            }
        } else {
            // Normal transfer (minting/burning or fee not enabled)
            super._update(from, to, value);
        }
    }

    /**
     * @notice Transfers all TRUST tokens held by this contract to the launchpad
     * @dev Can only be called by the launchpad. This allows completeTokenLaunch to work
     *      when TRUST is held on the token contract instead of the launchpad contract.
     * @return success Whether the transfer was successful
     */
    function transferTrustToLaunchpad() external onlyLaunchpad returns (bool) {
        require(address(trustToken) != address(0), "Trust token not set");
        uint256 balance = trustToken.balanceOf(address(this));
        if (balance > 0) {
            return trustToken.transfer(launchpad, balance);
        }
        return true;
    }

    /**
     * @notice Transfers native currency from this token contract to a recipient
     * @dev Can only be called by the launchpad to manage liquidity
     * @param to Address to send native currency to
     * @param amount Amount of native currency to send
     * @return success Whether the transfer was successful
     */
    function transferNative(address payable to, uint256 amount) external onlyLaunchpad returns (bool) {
        require(to != address(0), "Invalid recipient");
        require(address(this).balance >= amount, "Insufficient balance");
        (bool success, ) = to.call{value: amount}("");
        return success;
    }

    /**
     * @notice Gets the native currency balance of this token contract
     * @return balance The native currency balance
     */
    function getNativeBalance() external view returns (uint256) {
        return address(this).balance;
    }
}