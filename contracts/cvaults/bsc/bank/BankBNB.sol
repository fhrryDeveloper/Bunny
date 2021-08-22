// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts/math/Math.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

import "../../../library/bep20/BEP20Upgradeable.sol";
import "../../../library/SafeToken.sol";
import "../../../library/Whitelist.sol";
import "../../interface/IBankBNB.sol";
import "./config/BankConfig.sol";


contract BankBNB is IBankBNB, BEP20Upgradeable, ReentrancyGuardUpgradeable, Whitelist {
    using SafeToken for address;
    using SafeBEP20 for IBEP20;

    /* ========== STATE VARIABLES ========== */

    BankConfig public config;

    uint public glbDebtShare;
    uint public glbDebtVal;
    uint public lastAccrueTime;
    uint public reservePool;

    address public bankETH;

    mapping (address => mapping (address => uint)) private _debt;

    /* ========== EVENTS ========== */

    event AddDebt(address indexed pool, address indexed borrower, uint256 debtShare);
    event RemoveDebt(address indexed pool, address indexed borrower, uint256 debtShare);
    event HandOverDebt(address indexed pool, address indexed borrower, address indexed handOverTo, uint256 debtShare);

    /* ========== MODIFIERS ========== */

    modifier accrue(uint msgValue) {
        if (now > lastAccrueTime) {
            uint interest = pendingInterest(msgValue);
            uint toReserve = interest.mul(config.getReservePoolBps()).div(10000);
            reservePool = reservePool.add(toReserve);
            glbDebtVal = glbDebtVal.add(interest);
            lastAccrueTime = now;
        }
        _;
    }

    modifier onlyBankETH {
        require(msg.sender == bankETH, "BankBNB: caller is not bankETH");
        _;
    }

    /* ========== INITIALIZER ========== */

    function initialize(string memory name, string memory symbol, uint8 decimals) external initializer {
        __BEP20__init(name, symbol, decimals);
        __ReentrancyGuard_init();
        __Whitelist_init();

        lastAccrueTime = block.timestamp;
    }

    /* ========== VIEW FUNCTIONS ========== */

    /// @dev Return the pending interest that will be accrued in the next call.
    /// @param msgValue Balance value to subtract off address(this).balance when called from payable functions.
    function pendingInterest(uint msgValue) public view returns (uint) {
        if (now > lastAccrueTime) {
            uint timePast = block.timestamp.sub(lastAccrueTime);
            uint balance = address(this).balance.sub(msgValue);
            uint ratePerSec = config.getInterestRate(glbDebtVal, balance);
            return ratePerSec.mul(glbDebtVal).mul(timePast).div(1e18);
        } else {
            return 0;
        }
    }

    /// @dev Return the total BNB entitled to the token holders. Be careful of unaccrued interests.
    function totalBNB() public view returns (uint) {
        return address(this).balance.add(glbDebtVal).sub(reservePool);
    }

    function debtValOf(address pool, address account) external view override returns(uint) {
        return debtShareToVal(debtShareOf(pool, account));
    }

    function debtValOfETHVault() external view returns(uint) {
        return debtShareToVal(debtShareOf(address(this), bankETH));
    }

    function debtShareOf(address pool, address account) public view override returns(uint) {
        return _debt[pool][account];
    }

    /// @dev Return the BNB debt value given the debt share. Be careful of unaccrued interests.
    /// @param debtShare The debt share to be converted.
    function debtShareToVal(uint debtShare) public view override returns (uint) {
        if (glbDebtShare == 0) return debtShare; // When there's no share, 1 share = 1 val.
        return debtShare.mul(glbDebtVal).div(glbDebtShare);
    }

    /// @dev Return the debt share for the given debt value. Be careful of unaccrued interests.
    /// @param debtVal The debt value to be converted.
    function debtValToShare(uint debtVal) public view returns (uint) {
        if (glbDebtShare == 0) return debtVal; // When there's no share, 1 share = 1 val.
        return debtVal.mul(glbDebtShare).div(glbDebtVal);
    }

    function getUtilizationInfo() external view override returns(uint totalSupply, uint utilized) {
        totalSupply = totalBNB();
        utilized = glbDebtVal;
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    /// @dev Add more BNB to the bank. Hope to get some good returns.
    function deposit() external payable accrue(msg.value) nonReentrant {
        uint total = totalBNB().sub(msg.value);
        uint share = total == 0 ? msg.value : msg.value.mul(totalSupply()).div(total);
        _mint(msg.sender, share);
    }

    /// @dev Withdraw BNB from the bank by burning the share tokens.
    function withdraw(uint share) external accrue(0) nonReentrant {
        uint amount = share.mul(totalBNB()).div(totalSupply());
        _burn(msg.sender, share);
        SafeToken.safeTransferETH(msg.sender, amount);
    }

    function accruedDebtValOf(address pool, address account) external override accrue(0) returns(uint) {
        return debtShareToVal(debtShareOf(pool, account));
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // @return DebtShares of borrower
    function borrow(address pool, address borrower, uint debtVal) external override accrue(0) onlyWhitelisted returns(uint debtSharesOfBorrower) {
        debtVal = Math.min(debtVal, address(this).balance);
        uint debtShare = debtValToShare(debtVal);

        _debt[pool][borrower] = _debt[pool][borrower].add(debtShare);
        glbDebtShare = glbDebtShare.add(debtShare);
        glbDebtVal = glbDebtVal.add(debtVal);
        emit AddDebt(pool, borrower, debtShare);

        SafeToken.safeTransferETH(msg.sender, debtVal);
        return debtVal;
    }

    // @return DebtShares of borrower
    function repay(address pool, address borrower) public payable override accrue(msg.value) onlyWhitelisted returns(uint debtSharesOfBorrower) {
        uint debtShare = Math.min(debtValToShare(msg.value), _debt[pool][borrower]);
        if (debtShare > 0) {
            uint debtVal = debtShareToVal(debtShare);
            _debt[pool][borrower] = _debt[pool][borrower].sub(debtShare);
            glbDebtShare = glbDebtShare.sub(debtShare);
            glbDebtVal = glbDebtVal.sub(debtVal);
            emit RemoveDebt(pool, borrower, debtShare);
        }

        return _debt[pool][borrower];
    }

    function handOverDebtToTreasury(address pool, address borrower) external override accrue(0) onlyBankETH returns(uint debtSharesOfBorrower) {
        uint debtShare = _debt[pool][borrower];
        _debt[pool][borrower] = 0;
        _debt[address(this)][bankETH] = _debt[address(this)][bankETH].add(debtShare); // The debt belongs to treasury

        if (debtShare > 0) {
            emit HandOverDebt(pool, borrower, msg.sender, debtShare);
        }

        return debtShare;
    }

    function repayTreasuryDebt() external payable override accrue(msg.value) onlyBankETH returns(uint debtSharesOfBorrower) {
        return repay(address(this), bankETH);
    }

    function setBankETH(address newBankETH) external onlyOwner {
        require(bankETH == address(0), "BankBNB: bankETH is already set");
        bankETH = newBankETH;
    }

    /// @dev Update bank configuration to a new address. Must only be called by owner.
    /// @param newConfig The new configurator address.
    function updateConfig(address newConfig) external onlyOwner {
        config = BankConfig(newConfig);
    }

    /// @dev Withdraw BNB reserve for underwater positions to the given address.
    /// @param to The address to transfer BNB to.
    /// @param value The number of BNB tokens to withdraw. Must not exceed `reservePool`.
    function withdrawReserve(address to, uint256 value) external onlyOwner nonReentrant {
        reservePool = reservePool.sub(value);
        SafeToken.safeTransferETH(to, value);
    }

    /// @dev Reduce BNB reserve, effectively giving them to the depositors.
    /// @param value The number of BNB reserve to reduce.
    function reduceReserve(uint256 value) external onlyOwner {
        reservePool = reservePool.sub(value);
    }

    /// @dev Recover BEP20 tokens that were accidentally sent to this smart contract.
    /// @param token The token contract. Can be anything. This contract should not hold BEP20 tokens.
    /// @param to The address to send the tokens to.
    /// @param value The number of tokens to transfer to `to`.
    function recover(address token, address to, uint256 value) external onlyOwner {
        token.safeTransfer(to, value);
    }
}
