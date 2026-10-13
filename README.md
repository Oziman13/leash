# Leash

**Spending limits for AI agents, settled in USDC on Arc.**

Giving an AI agent a wallet today means trusting it with everything in that wallet. One bad prompt, one hallucinated invoice, one compromised tool, and the money is gone.

Leash gives the agent a **budget with rules** instead of a wallet:

- **Daily limit** and **per-payment limit**, enforced on-chain
- **Trusted recipients only** (optional): unknown addresses need your approval
- **Ask, don't fail:** a payment outside the rules is not rejected. It is queued for you, with the agent's note and the reason it was held. You approve it, approve and trust the recipient, or reject it.
- **Kill switch:** one transaction freezes the agent. It can't pay, refuel gas, or even queue requests.
- **Audit trail:** every payment, refuel and request is an event with the agent's note attached.

Live demo: `https://<your-github-user>.github.io/leash/` · Contract on Arc mainnet: `<address>`

## Why this only fully works on Arc

An agent needs two kinds of money: the money it spends, and the gas to spend it. On other chains those are different assets. A USDC budget plus an ETH gas balance means "this agent can spend at most $1 a day" is never actually true: gas is extra, priced in a volatile token, and has to be topped up by someone.

On Arc, **gas is USDC.** Leash refuels the agent's gas (`refuel`) from the **same dollar budget**, counted against the **same daily limit** as its payments. So the cap is total and exact: *$1 a day means $1 a day, gas included.* The owner never has to manage a second asset, and the agent can never cost more than its leash.

Arc also makes the human-in-the-loop part practical: deterministic sub-second finality means a payment within the rules is final before the agent's next thought, and an approval tap settles instantly.

## How it works

```
                 within rules ──► paid instantly (native USDC transfer)
agent.pay() ──►  outside rules ─► queued ──► owner: approve / approve+trust / reject
                 frozen ─────────► reverts
agent.refuel() ─► gas from the same budget, same daily limit
```

One contract (`src/Leash.sol`) holds budgets for any number of owners and agents. The agent is a normal key (EOA) that the agent software controls; the owner keeps their own key. The agent can only ever touch its own leash.

| Function | Who | What |
|---|---|---|
| `registerAgent(agent, name, daily, perTx, trustedOnly, gasSeed, trusted[])` | owner | create a leash, deposit `msg.value`, seed starting gas |
| `pay(to, amount, memo)` | agent | pay now, or queue for approval; returns `(settled, requestId)` |
| `refuel(amount)` | agent | move budget to the agent's own address for gas, within limits |
| `check(agent, to, amount)` | anyone | dry run: `""` means instant, otherwise the reason it would be held |
| `approve(id, trust)` / `reject(id)` | owner | resolve a queued payment |
| `setFrozen` / `setLimits` / `setAllowed` / `fund` / `withdraw` | owner | manage the leash |

Amounts are native USDC (`msg.value`, 18 decimals on Arc). No approvals, no token wrapping.

## Plug in a real agent

Any agent that can sign a transaction can use Leash: an LLM tool call, a script, a trading bot.

```python
from web3 import Web3
w3 = Web3(Web3.HTTPProvider("https://rpc.mainnet.arc.io"))
agent = w3.eth.account.from_key(AGENT_PRIVATE_KEY)          # the agent's key, never yours
leash = w3.eth.contract(address=LEASH_ADDRESS, abi=LEASH_ABI)  # docs/abi.json

amount = w3.to_wei("0.10", "ether")                         # native USDC, 18 decimals
reason = leash.functions.check(agent.address, SHOP, amount).call()   # "" = instant
tx = leash.functions.pay(SHOP, amount, "API credits").build_transaction(
    {"from": agent.address, "nonce": w3.eth.get_transaction_count(agent.address)})
w3.eth.send_raw_transaction(agent.sign_transaction(tx).raw_transaction)
```

Expose `check` and `pay` as tools to your LLM and it can reason about its own budget ("this would be held for approval: over per-payment limit") before acting.

## Tests

```
forge test
```

22 tests, including a fuzz test of the core guarantee: across 1,000 random sequences of payments and gas refuels, money that leaves the budget without a human approval never exceeds the daily limit. Also covered: approvals, trust-on-approve, rejection and cancellation finality, the kill switch, reentrancy on approval, recipients that refuse funds, the 24-hour window, and gas counting against the same limit.

## Run the demo yourself

The web app is one static file (`docs/index.html`, built from `web/index.src.html` by `build.py`). It needs a wallet on Arc mainnet (chain ID 5042) with a little USDC.

1. Open the page and connect. If no contract is configured, the page offers to deploy one from your wallet.
2. Create a leash. The page generates an agent key that stays in your browser, deposits your budget and seeds the agent's gas.
3. Use the agent panel: a small payment settles instantly, an oversized one and a payment to an unknown site wait for you, a spending spree stops at the daily limit, and the freeze button blocks everything.

Demo payments go back to your own address, so trying it costs only gas (fractions of a cent).

## Arc specifics handled

- Native USDC uses 18 decimals via `msg.value`; the ERC-20 interface at `0x3600…0000` uses 6. Leash uses native value only, so the two are never mixed.
- Transfers to blocklisted or refusing addresses revert; Leash reverts the whole payment so the budget is never debited for money that didn't move.
- `block.timestamp` is only used for the 24-hour window, which tolerates Arc's non-strictly-increasing timestamps.

## Status

An early proof of concept on Arc mainnet. Not audited. Keep budgets small.

Next: ERC-4337/EIP-7702 smart-account version (the agent never holds even gas money), EURC budgets, per-recipient limits, spend categories, and an MCP server so any LLM agent gets a leash with one config line.

## License

MIT
