// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/*
KipuBankV2
Mejoras:
- Soporte multi-token (ERC-20) + ETH (address(0) usado como token nativo)
- Control de acceso con OpenZeppelin AccessControl (ADMIN_ROLE)
- ReentrancyGuard (OpenZeppelin)
- SafeERC20 para transferencias ERC20
- Chainlink price feeds por token para convertir a USD y aplicar bankCap en USD
- Per-token per-tx withdraw limits y contabilidad por token y usuario
- Eventos y errores personalizados
- Funciones administrativas para configurar feeds / limites / rescates
*/

import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IERC20Decimals {
    function decimals() external view returns (uint8);
}

contract KipuBankV2 is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // Roles
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    // Bank cap expressed in USD with 8 decimals (same scaling as Chainlink USD price feeds)
    // e.g. $1_000_000 -> 1_000_000 * 10**8
    uint256 public immutable bankCapUSD; // 8 decimals

    // Events
    event Deposit(address indexed token, address indexed user, uint256 amount, uint256 usdValue);
    event Withdraw(address indexed token, address indexed user, uint256 amount, uint256 usdValue);
    event FeedSet(address indexed token, address indexed feed);
    event PerTxLimitSet(address indexed token, uint256 limit);
    event Rescued(address indexed token, address indexed to, uint256 amount);
    event Paused(bool paused);

    // Errors
    error ZeroAmount();
    error BankCapExceeded(uint256 attemptedUSD, uint256 capUSD);
    error InsufficientBalance(address token, address user, uint256 available, uint256 requested);
    error WithdrawLimitExceeded(address token, uint256 attempted, uint256 limit);
    error NoPriceFeed(address token);
    error NotAdmin();
    error PausedError();

    // State
    bool public paused;

    // Mapping token => user => balance (raw token units)
    mapping(address => mapping(address => uint256)) private balances;

    // Aggregator (Chainlink) per token to get price token/USD (8 decimals)
    mapping(address => AggregatorV3Interface) public priceFeed;

    // per-token withdraw limit (in token units). For ETH use token == address(0).
    mapping(address => uint256) public perTxWithdrawLimit;

    // per-token total deposited (token units)
    mapping(address => uint256) public totalDepositedToken;
    mapping(address => uint256) public totalWithdrawnToken;

    // Total bank exposure in USD (8 decimals). We update this on deposits/withdrawals (approx).
    uint256 public totalDepositedUSD; // 8 decimals
    uint256 public totalWithdrawnUSD; // 8 decimals

    // Owner / admin assigned by AccessControl
    constructor(uint256 _bankCapUSD) {
        require(_bankCapUSD > 0, "bankCapUSD > 0");
        bankCapUSD = _bankCapUSD;

        _setupRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _setupRole(ADMIN_ROLE, msg.sender);
        paused = false;
    }

    // ---------- Modifiers ----------
    modifier onlyAdmin() {
        if (!hasRole(ADMIN_ROLE, msg.sender)) revert NotAdmin();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    // ---------- Admin functions ----------
    /// @notice Set Chainlink price feed for a token. token == address(0) => ETH/USD feed.
    function setPriceFeed(address token, address feed) external onlyAdmin {
        priceFeed[token] = AggregatorV3Interface(feed);
        emit FeedSet(token, feed);
    }

    /// @notice Set per-transaction withdraw limit for a token (in token units).
    function setPerTxWithdrawLimit(address token, uint256 limit) external onlyAdmin {
        perTxWithdrawLimit[token] = limit;
        emit PerTxLimitSet(token, limit);
    }

    /// @notice Pause / unpause contract actions that change state.
    function setPaused(bool _paused) external onlyAdmin {
        paused = _paused;
        emit Paused(_paused);
    }

    /// @notice Rescue tokens or ETH sent by mistake. Only admin.
    function rescue(address token, address to, uint256 amount) external onlyAdmin {
        if (to == address(0)) revert();
        if (token == address(0)) {
            // ETH rescue
            (bool ok, ) = to.call{value: amount}("");
            require(ok, "ETH rescue failed");
        } else {
            IERC20(token).safeTransfer(to, amount);
        }
        emit Rescued(token, to, amount);
    }

    // ---------- Deposits ----------
    /// @notice Deposit ETH into your account. bankCapUSD enforced.
    function depositETH() external payable whenNotPaused nonReentrant {
        uint256 amount = msg.value;
        if (amount == 0) revert ZeroAmount();

        // get USD value
        uint256 usdValue = _toUSD(address(0), amount);

        // bank cap check (sum of depositedUSD - withdrawnUSD + new deposit <= bankCapUSD)
        uint256 currentExposure = totalDepositedUSD - totalWithdrawnUSD;
        uint256 newExposure = currentExposure + usdValue;
        if (newExposure > bankCapUSD) revert BankCapExceeded(newExposure, bankCapUSD);

        balances[address(0)][msg.sender] += amount;
        totalDepositedToken[address(0)] += amount;
        totalDepositedUSD += usdValue;

        emit Deposit(address(0), msg.sender, amount, usdValue);
    }

    /// @notice Deposit ERC20 tokens into your account (token must be approved beforehand).
    function depositERC20(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert();

        uint256 usdValue = _toUSD(token, amount);
        uint256 currentExposure = totalDepositedUSD - totalWithdrawnUSD;
        uint256 newExposure = currentExposure + usdValue;
        if (newExposure > bankCapUSD) revert BankCapExceeded(newExposure, bankCapUSD);

        // Transfer token from user
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);

        balances[token][msg.sender] += amount;
        totalDepositedToken[token] += amount;
        totalDepositedUSD += usdValue;

        emit Deposit(token, msg.sender, amount, usdValue);
    }

    // ---------- Withdrawals ----------
    /// @notice Withdraw ETH (address(0) used for ETH).
    function withdrawETH(uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 userBal = balances[address(0)][msg.sender];
        if (userBal < amount) revert InsufficientBalance(address(0), msg.sender, userBal, amount);

        uint256 limit = perTxWithdrawLimit[address(0)];
        if (limit != 0 && amount > limit) revert WithdrawLimitExceeded(address(0), amount, limit);

        uint256 usdValue = _toUSD(address(0), amount);

        // Effects
        balances[address(0)][msg.sender] = userBal - amount;
        totalWithdrawnToken[address(0)] += amount;
        totalWithdrawnUSD += usdValue;

        // Interaction
        (bool ok, ) = msg.sender.call{value: amount}("");
        require(ok, "ETH transfer failed");

        emit Withdraw(address(0), msg.sender, amount, usdValue);
    }

    /// @notice Withdraw ERC20 token
    function withdrawERC20(address token, uint256 amount) external whenNotPaused nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (token == address(0)) revert();

        uint256 userBal = balances[token][msg.sender];
        if (userBal < amount) revert InsufficientBalance(token, msg.sender, userBal, amount);

        uint256 limit = perTxWithdrawLimit[token];
        if (limit != 0 && amount > limit) revert WithdrawLimitExceeded(token, amount, limit);

        uint256 usdValue = _toUSD(token, amount);

        // Effects
        balances[token][msg.sender] = userBal - amount;
        totalWithdrawnToken[token] += amount;
        totalWithdrawnUSD += usdValue;

        // Interaction (safe)
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Withdraw(token, msg.sender, amount, usdValue);
    }

    // ---------- Views ----------
    /// @notice Get user balance for a token (raw token units). ETH token => address(0).
    function getUserBalance(address token, address user) external view returns (uint256) {
        return balances[token][user];
    }

    /// @notice Get deposit & withdraw totals for a token (raw units).
    function getTokenTotals(address token) external view returns (uint256 deposited, uint256 withdrawn) {
        deposited = totalDepositedToken[token];
        withdrawn = totalWithdrawnToken[token];
    }

    /// @notice Returns USD value (8 decimals) for token amount using configured price feed.
    function toUSD(address token, uint256 amount) external view returns (uint256) {
        return _toUSD(token, amount);
    }

    // ---------- Internal helpers ----------
    /// @dev Convert token amount to USD (8 decimals). Requires priceFeed[token] set.
    function _toUSD(address token, uint256 amount) internal view returns (uint256) {
        AggregatorV3Interface feed = priceFeed[token];
        if (address(feed) == address(0)) revert NoPriceFeed(token);

        (, int256 price, , , ) = feed.latestRoundData();
        require(price > 0, "invalid price");

        // price has 8 decimals (Chainlink standard), amount is token units with tokenDecimals decimals
        uint8 tokenDecimals = _getTokenDecimals(token);

        // USD value (8 decimals) = amount * price / (10 ** tokenDecimals)
        // Do multiplication in uint256 to avoid precision loss.
        uint256 amt = amount;
        uint256 p = uint256(int256(price));
        uint256 usdValue = (amt * p) / (10 ** tokenDecimals);

        return usdValue;
    }

    /// @dev Get token decimals; for ETH return 18.
    function _getTokenDecimals(address token) internal view returns (uint8) {
        if (token == address(0)) return 18; // ETH decimals
        // try ERC20.decimals()
        try IERC20Decimals(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            // default fallback to 18 if token does not implement decimals (rare)
            return 18;
        }
    }

    // Allow contract to receive ETH
    receive() external payable {
        revert("Use depositETH()");
    }

    fallback() external payable {
        revert("Use depositETH()");
    }
}

