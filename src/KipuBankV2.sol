// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
KipuBankV2
Versión autónoma para Remix/Sepolia

Incluye:
- Soporte multi-token (ERC20 y ETH)
- Control de acceso (AccessControl)
- ReentrancyGuard
- SafeERC20
- Interfaz local de Chainlink AggregatorV3Interface
*/

// ----------- INTERFACES Y LIBRERÍAS INCLUIDAS LOCALMENTE -----------

interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
}

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

// --- Chainlink local interface ---
interface AggregatorV3Interface {
  function decimals() external view returns (uint8);
  function description() external view returns (string memory);
  function version() external view returns (uint256);
  function latestRoundData() external view returns (
      uint80 roundId,
      int256 answer,
      uint256 startedAt,
      uint256 updatedAt,
      uint80 answeredInRound
  );
}

// --- AccessControl simplificado (solo lo necesario) ---
abstract contract AccessControl {
    mapping(bytes32 => mapping(address => bool)) private _roles;
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    modifier onlyRole(bytes32 role) {
        require(_roles[role][msg.sender], "AccessControl: missing role");
        _;
    }

    function _grantRole(bytes32 role, address account) internal {
        _roles[role][account] = true;
    }

    function hasRole(bytes32 role, address account) public view returns (bool) {
        return _roles[role][account];
    }
}

// --- ReentrancyGuard ---
abstract contract ReentrancyGuard {
    uint256 private _status;
    constructor() {
        _status = 1;
    }
    modifier nonReentrant() {
        require(_status == 1, "ReentrancyGuard: reentrant");
        _status = 2;
        _;
        _status = 1;
    }
}

// --- SafeERC20 (versión mínima) ---
library SafeERC20 {
    function safeTransfer(IERC20 token, address to, uint256 value) internal {
        require(token.transfer(to, value), "SafeERC20: transfer failed");
    }
    function safeTransferFrom(IERC20 token, address from, address to, uint256 value) internal {
        require(token.transferFrom(from, to, value), "SafeERC20: transferFrom failed");
    }
}

// ------------------ CONTRATO PRINCIPAL ------------------

contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    uint256 public immutable bankCapUSD;

    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 usdValue);
    event Withdraw(address indexed token, address indexed user, uint256 amount, uint256 usdValue);
    event FeedSet(address indexed token, address indexed feed);
    event PerTxLimitSet(address indexed token, uint256 limit);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Paused(bool paused);

    error ZeroAmount();
    error BankCapExceeded(uint256 attemptedUSD, uint256 capUSD);
    error InsufficientBalance(address token, address user, uint256 available, uint256 requested);
    error WithdrawLimitExceeded(address token, uint256 attempted, uint256 limit);
    error NoPriceFeed(address token);
    error NotAdmin();
    error PausedError();

    bool public paused;

    mapping(address => mapping(address => uint256)) private balances;
    mapping(address => AggregatorV3Interface) public priceFeed;
    mapping(address => uint256) public perTxWithdrawLimit;
    mapping(address => uint256) public totalDepositedToken;
    mapping(address => uint256) public totalWithdrawnToken;

    uint256 public totalDepositedUSD;
    uint256 public totalWithdrawnUSD;

    constructor(uint256 _bankCapUSD) {
        require(_bankCapUSD > 0, "bankCapUSD > 0");
        bankCapUSD = _bankCapUSD;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ADMIN_ROLE, msg.sender);
    }

    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    // ---------- Admin ----------
    function setPriceFeed(address token, address feed) external onlyAdmin {
        priceFeed[token] = AggregatorV3Interface(feed);
        emit FeedSet(token, feed);
    }

    function setPerTxWithdrawLimit(address token, uint256 limit) external onlyAdmin {
        perTxWithdrawLimit[token] = limit;
        emit PerTxLimitSet(token, limit);
    }

    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit Paused(_paused);
    }

    function rescue(address token, address to, uint256 amount) external onlyAdmin {
        require(to != address(0), "invalid to");
        if (token == address(0)) {
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH rescue failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    // ---------- Deposits ----------
    function depositETH() external payable whenNotPaused nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        uint256 usdValue = _toUSD(address(0), amount);
        uint256 newExposure = (totalDepositedUSD - totalWithdrawnUSD) + usdValue;
        if (newExposure > bankCapUSD) revert BankCapExceeded(newExposure, bankCapUSD);

        balances[address(0)][msg.sender] += amount;
        totalDepositedToken[address(0)] += amount;
        totalDepositedUSD += usdValue;

        emit Deposit(address(0), msg.sender, amount, usdValue);
    }

    function depositERC20(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert();

        uint256 usdValue = _toUSD(token, amount);
        uint256 newExposure = (totalDepositedUSD - totalWithdrawnUSD) + usdValue;
        if (newExposure > bankCapUSD) revert BankCapExceeded(newExposure, bankCapUSD);

        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[token][msg.sender] += amount;
        totalDepositedToken[token] += amount;
        totalDepositedUSD += usdValue;

        emit Deposit(token, msg.sender, amount, usdValue);
    }

    // ---------- Withdraw ----------
    function withdrawETH(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 userBal = balances[address(0)][msg.sender];
        if (userBal < amount) revert InsufficientBalance(address(0), msg.sender, userBal, amount);

        uint256 limit = perTxWithdrawLimit[address(0)];
        if (limit != 0 && amount > limit) revert WithdrawLimitExceeded(address(0), amount, limit);

        uint256 usdValue = _toUSD(address(0), amount);

        balances[address(0)][msg.sender] = userBal - amount;
        totalWithdrawnToken[address(0)] += amount;
        totalWithdrawnUSD += usdValue;

        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit Withdraw(address(0), msg.sender, amount, usdValue);
    }

    function withdrawERC20(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert();

        uint256 userBal = balances[token][msg.sender];
        if (userBal < amount) revert InsufficientBalance(token, msg.sender, userBal, amount);

        uint256 limit = perTxWithdrawLimit[token];
        if (limit != 0 && amount > limit) revert WithdrawLimitExceeded(token, amount, limit);

        uint256 usdValue = _toUSD(token, amount);

        balances[token][msg.sender] = userBal - amount;
        totalWithdrawnToken[token] += amount;
        totalWithdrawnUSD += usdValue;

        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(token, msg.sender, amount, usdValue);
    }

    // ---------- Views ----------
    function getUserBalance(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    function getTokenTotals(address token) external view returns (uint256 deposited, uint256 withdrawn) {
        deposited = totalDepositedToken[token];
        withdrawn = totalWithdrawnToken[token];
    }

    function toUSD(address token, uint256 amount) external view returns (uint256) {
        return _toUSD(token, amount);
    }

    // ---------- Internos ----------
    function _toUSD(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface feed = priceFeed[token];
        if (address(feed) == address(0)) revert NoPriceFeed(token);

        (, int256 price, , , ) = feed.latestRoundData();
        require(price > 0, "invalid price");

        uint8 tokenDecimals = _getTokenDecimals(token);
        uint256 usdValue = (amount * uint256(price)) / (10 ** tokenDecimals);
        return usdValue;
    }

    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18;
        try IERC20Decimals(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }

    receive() external payable {
        revert("Use depositETH()");
    }

    fallback() external payable {
        revert("Use depositETH()");
    }
}
