// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title Leash — spending guardrails for AI agents, settled in native USDC on Arc.
/// @notice An owner gives an AI agent (an EOA the agent controls) a budget held in this
/// contract. The agent can pay within its rules instantly; anything outside the rules is
/// queued for the owner's approval instead of failing. Because gas on Arc is paid in USDC,
/// the agent's gas is refueled from the same dollar budget, so the agent's *total* cost,
/// gas included, is capped in dollars.
/// @dev All amounts are native USDC with 18 decimals (msg.value / address.balance on Arc).
contract Leash {
    // ------------------------------------------------------------------ types

    enum Status {
        None,
        Pending,
        Approved,
        Rejected,
        Cancelled
    }

    struct Agent {
        address owner;
        bool frozen;
        bool allowlistOnly;
        uint128 balance; // budget still held for this agent
        uint128 dailyLimit; // max auto-spend per rolling 24h window (payments + gas refuels)
        uint128 perTxLimit; // max auto-spend per single action
        uint128 spentInWindow;
        uint64 windowStart;
        uint64 totalPayments;
        uint128 totalSpent; // lifetime: auto payments + approved payments + gas refuels
        uint128 totalGas; // lifetime gas refuels
        string name;
    }

    struct Request {
        address agent;
        address to;
        uint128 amount;
        uint64 createdAt;
        Status status;
        string memo;
    }

    // ------------------------------------------------------------------ storage

    uint256 public constant WINDOW = 1 days;

    mapping(address => Agent) private _agents;
    mapping(address => address[]) private _ownerAgents;
    mapping(address => mapping(address => bool)) public allowed; // agent => recipient => ok
    Request[] private _requests;

    uint256 private _lock = 1;

    // ------------------------------------------------------------------ events

    event AgentRegistered(address indexed owner, address indexed agent, string name, uint256 dailyLimit, uint256 perTxLimit);
    event Funded(address indexed agent, address indexed from, uint256 amount);
    event Withdrawn(address indexed agent, address indexed to, uint256 amount);
    event LimitsUpdated(address indexed agent, uint256 dailyLimit, uint256 perTxLimit, bool allowlistOnly);
    event AllowlistUpdated(address indexed agent, address indexed recipient, bool ok);
    event Frozen(address indexed agent, bool frozen);
    event Paid(address indexed agent, address indexed to, uint256 amount, string memo, bool viaApproval);
    event GasRefueled(address indexed agent, uint256 amount);
    event RequestQueued(uint256 indexed id, address indexed agent, address indexed to, uint256 amount, string memo, string reason);
    event RequestResolved(uint256 indexed id, Status status);

    // ------------------------------------------------------------------ errors

    error NotOwner();
    error NotAgent();
    error AgentExists();
    error BadAddress();
    error BadLimits();
    error IsFrozen();
    error InsufficientBudget();
    error OverLimit();
    error NotPending();
    error TransferFailed();
    error Reentrancy();

    // ------------------------------------------------------------------ modifiers

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    modifier onlyOwnerOf(address agent) {
        if (_agents[agent].owner != msg.sender) revert NotOwner();
        _;
    }

    modifier onlyAgent() {
        if (_agents[msg.sender].owner == address(0)) revert NotAgent();
        _;
    }

    // ------------------------------------------------------------------ owner

    /// @notice Register an agent address, set its rules and fund it with msg.value.
    /// @param gasSeed part of the budget sent straight to the agent so it can pay its first gas.
    ///        Counted as spend, exactly like later refuels.
    /// @param trusted recipients the agent may pay without approval when allowlistOnly is on.
    function registerAgent(
        address agent,
        string calldata name,
        uint128 dailyLimit,
        uint128 perTxLimit,
        bool allowlistOnly,
        uint128 gasSeed,
        address[] calldata trusted
    ) external payable nonReentrant {
        if (agent == address(0) || agent == msg.sender || agent == address(this)) revert BadAddress();
        if (_agents[agent].owner != address(0)) revert AgentExists();
        if (perTxLimit == 0 || perTxLimit > dailyLimit) revert BadLimits();
        if (gasSeed > msg.value || gasSeed > perTxLimit) revert BadLimits();

        Agent storage a = _agents[agent];
        a.owner = msg.sender;
        a.name = name;
        a.dailyLimit = dailyLimit;
        a.perTxLimit = perTxLimit;
        a.allowlistOnly = allowlistOnly;
        a.windowStart = uint64(block.timestamp);
        a.balance = uint128(msg.value);
        _ownerAgents[msg.sender].push(agent);
        for (uint256 i; i < trusted.length; i++) {
            if (trusted[i] == address(0)) revert BadAddress();
            allowed[agent][trusted[i]] = true;
            emit AllowlistUpdated(agent, trusted[i], true);
        }

        emit AgentRegistered(msg.sender, agent, name, dailyLimit, perTxLimit);
        if (msg.value > 0) emit Funded(agent, msg.sender, msg.value);

        if (gasSeed > 0) {
            a.balance -= gasSeed;
            a.spentInWindow += gasSeed;
            a.totalSpent += gasSeed;
            a.totalGas += gasSeed;
            emit GasRefueled(agent, gasSeed);
            _send(agent, gasSeed);
        }
    }

    /// @notice Anyone can top up an agent's budget.
    function fund(address agent) external payable {
        Agent storage a = _agents[agent];
        if (a.owner == address(0)) revert NotAgent();
        a.balance += uint128(msg.value);
        emit Funded(agent, msg.sender, msg.value);
    }

    function withdraw(address agent, uint128 amount) external nonReentrant onlyOwnerOf(agent) {
        Agent storage a = _agents[agent];
        if (amount > a.balance) revert InsufficientBudget();
        a.balance -= amount;
        emit Withdrawn(agent, msg.sender, amount);
        _send(msg.sender, amount);
    }

    function setLimits(address agent, uint128 dailyLimit, uint128 perTxLimit, bool allowlistOnly)
        external
        onlyOwnerOf(agent)
    {
        if (perTxLimit == 0 || perTxLimit > dailyLimit) revert BadLimits();
        Agent storage a = _agents[agent];
        a.dailyLimit = dailyLimit;
        a.perTxLimit = perTxLimit;
        a.allowlistOnly = allowlistOnly;
        emit LimitsUpdated(agent, dailyLimit, perTxLimit, allowlistOnly);
    }

    function setAllowed(address agent, address recipient, bool ok) external onlyOwnerOf(agent) {
        if (recipient == address(0)) revert BadAddress();
        allowed[agent][recipient] = ok;
        emit AllowlistUpdated(agent, recipient, ok);
    }

    /// @notice Kill switch. A frozen agent can neither pay nor refuel nor queue requests.
    function setFrozen(address agent, bool frozen_) external onlyOwnerOf(agent) {
        _agents[agent].frozen = frozen_;
        emit Frozen(agent, frozen_);
    }

    /// @notice Approve a queued payment. Owner-approved payments bypass the auto limits
    ///         (the human is the limit) but still need budget.
    /// @param trustRecipient also add the recipient to the agent's allowlist.
    function approve(uint256 id, bool trustRecipient) external nonReentrant {
        Request storage r = _requests[id];
        Agent storage a = _agents[r.agent];
        if (a.owner != msg.sender) revert NotOwner();
        if (r.status != Status.Pending) revert NotPending();
        if (r.amount > a.balance) revert InsufficientBudget();

        r.status = Status.Approved;
        a.balance -= r.amount;
        a.totalSpent += r.amount;
        a.totalPayments += 1;
        if (trustRecipient && !allowed[r.agent][r.to]) {
            allowed[r.agent][r.to] = true;
            emit AllowlistUpdated(r.agent, r.to, true);
        }
        emit RequestResolved(id, Status.Approved);
        emit Paid(r.agent, r.to, r.amount, r.memo, true);
        _send(r.to, r.amount);
    }

    function reject(uint256 id) external {
        Request storage r = _requests[id];
        if (_agents[r.agent].owner != msg.sender) revert NotOwner();
        if (r.status != Status.Pending) revert NotPending();
        r.status = Status.Rejected;
        emit RequestResolved(id, Status.Rejected);
    }

    // ------------------------------------------------------------------ agent

    /// @notice Pay `amount` to `to`. Settles instantly when within the rules; otherwise the
    ///         payment is queued for the owner and the returned id identifies the request.
    /// @return settled true if paid now, false if queued.
    /// @return requestId id of the queued request (0 and meaningless when settled).
    function pay(address to, uint128 amount, string calldata memo)
        external
        nonReentrant
        onlyAgent
        returns (bool settled, uint256 requestId)
    {
        if (to == address(0) || to == address(this)) revert BadAddress();
        if (amount == 0) revert BadLimits();
        Agent storage a = _agents[msg.sender];
        if (a.frozen) revert IsFrozen();
        _roll(a);

        string memory reason = _blockReason(a, msg.sender, to, amount);
        if (bytes(reason).length != 0) {
            requestId = _requests.length;
            _requests.push(
                Request({
                    agent: msg.sender,
                    to: to,
                    amount: amount,
                    createdAt: uint64(block.timestamp),
                    status: Status.Pending,
                    memo: memo
                })
            );
            emit RequestQueued(requestId, msg.sender, to, amount, memo, reason);
            return (false, requestId);
        }

        a.balance -= amount;
        a.spentInWindow += amount;
        a.totalSpent += amount;
        a.totalPayments += 1;
        emit Paid(msg.sender, to, amount, memo, false);
        _send(to, amount);
        return (true, 0);
    }

    /// @notice Move part of the budget to the agent's own address to pay for gas.
    ///         Counts against the same limits as payments: gas is just dollars on Arc.
    function refuel(uint128 amount) external nonReentrant onlyAgent {
        Agent storage a = _agents[msg.sender];
        if (a.frozen) revert IsFrozen();
        if (amount == 0) revert BadLimits();
        _roll(a);
        if (amount > a.balance) revert InsufficientBudget();
        if (amount > a.perTxLimit || a.spentInWindow + amount > a.dailyLimit) revert OverLimit();

        a.balance -= amount;
        a.spentInWindow += amount;
        a.totalSpent += amount;
        a.totalGas += amount;
        emit GasRefueled(msg.sender, amount);
        _send(msg.sender, amount);
    }

    function cancel(uint256 id) external {
        Request storage r = _requests[id];
        if (r.agent != msg.sender) revert NotAgent();
        if (r.status != Status.Pending) revert NotPending();
        r.status = Status.Cancelled;
        emit RequestResolved(id, Status.Cancelled);
    }

    // ------------------------------------------------------------------ views

    function getAgent(address agent) external view returns (Agent memory a, uint256 remainingToday) {
        a = _agents[agent];
        uint256 spent = block.timestamp >= a.windowStart + WINDOW ? 0 : a.spentInWindow;
        remainingToday = a.dailyLimit > spent ? a.dailyLimit - spent : 0;
        if (remainingToday > a.balance) remainingToday = a.balance;
    }

    function agentsOf(address owner) external view returns (address[] memory) {
        return _ownerAgents[owner];
    }

    function requestCount() external view returns (uint256) {
        return _requests.length;
    }

    function getRequest(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }

    /// @notice Dry-run: what would happen if `agent` tried to pay now? Empty string = instant.
    function check(address agent, address to, uint128 amount) external view returns (string memory) {
        Agent memory a = _agents[agent];
        if (a.owner == address(0)) return "not an agent";
        if (a.frozen) return "frozen";
        if (block.timestamp >= a.windowStart + WINDOW) a.spentInWindow = 0;
        return _blockReasonMem(a, agent, to, amount);
    }

    // ------------------------------------------------------------------ internal

    function _roll(Agent storage a) private {
        if (block.timestamp >= a.windowStart + WINDOW) {
            a.windowStart = uint64(block.timestamp);
            a.spentInWindow = 0;
        }
    }

    function _blockReason(Agent storage a, address agent, address to, uint128 amount)
        private
        view
        returns (string memory)
    {
        if (amount > a.balance) revert InsufficientBudget();
        if (a.allowlistOnly && !allowed[agent][to]) return "recipient not on allowlist";
        if (amount > a.perTxLimit) return "over per-payment limit";
        if (a.spentInWindow + amount > a.dailyLimit) return "over daily limit";
        return "";
    }

    function _blockReasonMem(Agent memory a, address agent, address to, uint128 amount)
        private
        view
        returns (string memory)
    {
        if (amount > a.balance) return "insufficient budget";
        if (a.allowlistOnly && !allowed[agent][to]) return "recipient not on allowlist";
        if (amount > a.perTxLimit) return "over per-payment limit";
        if (a.spentInWindow + amount > a.dailyLimit) return "over daily limit";
        return "";
    }

    function _send(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
