# leash-mcp

An MCP server that gives an AI assistant (Claude Desktop, or any MCP client) a USDC budget on Arc that it **cannot overspend**.

The assistant only ever holds the *agent* key. The rules live in the Leash contract on-chain, so a confused, jailbroken or prompt-injected assistant still can't go past them:

- payments inside the rules settle immediately
- payments outside them are queued for the owner's approval, with the assistant's memo
- the owner can freeze the agent at any moment
- gas is refueled from the same dollar budget, under the same daily limit

## Tools

| Tool | What it does |
|---|---|
| `leash_status` | budget left, what can be spent today without approval, limits, frozen or not |
| `leash_check` | dry run: "pays instantly" or the reason it would be held. Costs nothing |
| `leash_pay` | pay USDC with a memo; returns `paid` with the tx, or `held for owner approval` with a request id |
| `leash_request` | check whether the owner approved, rejected or hasn't decided yet |

## Setup

1. Create a leash on the Leash web page, then open **The agent → Hand this leash to a real AI assistant → Show assistant config**. It contains the contract address and the agent key.
2. Install:
   ```
   git clone https://github.com/Oziman13/leash && cd leash/mcp && npm install
   ```
3. Add the config to Claude Desktop (`claude_desktop_config.json`), replacing the path:
   ```json
   {
     "mcpServers": {
       "leash": {
         "command": "node",
         "args": ["/absolute/path/to/leash/mcp/index.js"],
         "env": {
           "LEASH_NETWORK": "mainnet",
           "LEASH_ADDRESS": "0x…",
           "LEASH_AGENT_KEY": "0x…"
         }
       }
     }
   }
   ```
4. Restart the assistant and ask it something like *"Check my leash, then pay 0.05 USDC to 0x… for API credits."* Watch the payment, or the approval request, appear on the Leash page.

Optional: `LEASH_RPC` to use a different Arc RPC endpoint.

Never put your own wallet key in `LEASH_AGENT_KEY`. The point of Leash is that the assistant never has it.
