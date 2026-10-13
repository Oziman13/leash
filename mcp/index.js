#!/usr/bin/env node
// Leash MCP server: gives an AI assistant a USDC budget on Arc that it cannot overspend.
// The assistant holds only the *agent* key. Every rule (daily limit, per-payment limit,
// trusted recipients, freeze) is enforced by the Leash contract on-chain, not by this server.
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { ethers } from "ethers";
import { readFileSync } from "node:fs";

const NETS = {
  mainnet: { chainId: 5042, rpc: "https://rpc.mainnet.arc.io", explorer: "https://explorer.arc.io" },
  testnet: { chainId: 5042002, rpc: "https://rpc.testnet.arc.io", explorer: "https://explorer.testnet.arc.io" },
};
const netName = (process.env.LEASH_NETWORK || "mainnet").toLowerCase();
const NET = NETS[netName];
if (!NET) fail(`LEASH_NETWORK must be "mainnet" or "testnet", got "${netName}"`);
const KEY = process.env.LEASH_AGENT_KEY;
const ADDRESS = process.env.LEASH_ADDRESS;
if (!KEY) fail("Set LEASH_AGENT_KEY to the agent's private key (export it from the Leash page). Never use your own wallet key.");
if (!ADDRESS || !ethers.isAddress(ADDRESS)) fail("Set LEASH_ADDRESS to the Leash contract address.");

const ABI = JSON.parse(readFileSync(new URL("./abi.json", import.meta.url), "utf8"));
const provider = new ethers.JsonRpcProvider(process.env.LEASH_RPC || NET.rpc, NET.chainId, { staticNetwork: true, cacheTimeout: -1 }); // no response cache: back-to-back payments need fresh nonces
provider.pollingInterval = 250;
const agent = new ethers.Wallet(KEY, provider);
const leash = new ethers.Contract(ADDRESS, ABI, agent);
const iface = new ethers.Interface(ABI);
const MIN_GAS = ethers.parseEther("0.008");

function fail(msg) { console.error(`leash-mcp: ${msg}`); process.exit(1); }
const usd = (wei) => "$" + Number(ethers.formatEther(wei)).toFixed(4).replace(/0{1,2}$/, "");
const toWei = (usdc) => ethers.parseEther(String(usdc));
const txUrl = (h) => `${NET.explorer}/tx/${h}`;
const text = (obj) => ({ content: [{ type: "text", text: typeof obj === "string" ? obj : JSON.stringify(obj, null, 2) }] });
const STATUS = ["none", "pending", "approved", "rejected", "cancelled"];

const REASONS = {
  IsFrozen: "the owner has frozen this agent. Do not retry; tell the user.",
  InsufficientBudget: "not enough budget left in the leash. Ask the owner to add funds.",
  OverLimit: "that would exceed today's limit.",
  NotAgent: "this key is not registered as an agent in this Leash contract.",
  TransferFailed: "the recipient refused the USDC (or is blocklisted).",
  BadAddress: "that recipient address can't be used.",
  BadLimits: "the amount must be greater than zero.",
};
function friendly(e) {
  const data = e?.data || e?.info?.error?.data || e?.error?.data;
  let name;
  try { const p = data && iface.parseError(data); if (p) name = p.name; } catch {}
  name = name || e?.revert?.name;
  return name ? (REASONS[name] || name) : (e?.shortMessage || e?.message || String(e));
}

async function status() {
  const [a, remaining] = await leash.getAgent(agent.address);
  if (a.owner === ethers.ZeroAddress) throw new Error("This key is not registered as an agent in this Leash contract.");
  return {
    agent: agent.address,
    name: a.name,
    frozen: a.frozen,
    budget_left: usd(a.balance),
    can_spend_today_without_approval: usd(remaining),
    daily_limit: usd(a.dailyLimit),
    per_payment_limit: usd(a.perTxLimit),
    trusted_recipients_only: a.allowlistOnly,
    spent_all_time: usd(a.totalSpent),
    of_which_gas: usd(a.totalGas),
    gas_wallet: usd(await provider.getBalance(agent.address)),
    network: `Arc ${netName}`,
  };
}

// Gas on Arc is USDC, so the agent tops up its own gas from the same leash budget,
// counted against the same daily limit. The owner never manages a second asset.
async function ensureGas() {
  const bal = await provider.getBalance(agent.address);
  if (bal >= MIN_GAS) return null;
  const [a] = await leash.getAgent(agent.address);
  let amt = ethers.parseEther("0.03");
  if (amt > a.perTxLimit) amt = a.perTxLimit;
  const tx = await leash.refuel(amt);
  await tx.wait();
  return { refueled: usd(amt), tx: txUrl(tx.hash) };
}

const server = new McpServer({ name: "leash", version: "0.1.0" });

server.registerTool("leash_status", {
  title: "Leash: budget and rules",
  description: "Show this agent's USDC budget on Arc: what is left, what can be spent today without the owner's approval, the limits, and whether the owner has frozen it. Call this before planning purchases.",
  inputSchema: {},
}, async () => {
  try { return text(await status()); } catch (e) { return { ...text(friendly(e)), isError: true }; }
});

server.registerTool("leash_check", {
  title: "Leash: dry-run a payment",
  description: "Check, without spending anything, what would happen if you paid `amount_usdc` to `to`. Returns 'pays instantly' or the reason it would be held for the owner's approval.",
  inputSchema: {
    to: z.string().describe("Recipient address (0x...)"),
    amount_usdc: z.number().positive().describe("Amount in USDC, e.g. 0.25"),
  },
}, async ({ to, amount_usdc }) => {
  if (!ethers.isAddress(to)) return { ...text("Not a valid address."), isError: true };
  const reason = await leash.check(agent.address, to, toWei(amount_usdc));
  return text(reason === "" ? "pays instantly" : `would be held for the owner's approval: ${reason}`);
});

server.registerTool("leash_pay", {
  title: "Leash: pay in USDC",
  description: "Pay USDC on Arc from your leash budget. Inside the rules it settles immediately. Outside them (too large, over today's limit, unknown recipient) it is NOT rejected: it is queued for the owner's approval and you get a request id to check later with leash_request. Always include a clear memo; the owner sees it when deciding.",
  inputSchema: {
    to: z.string().describe("Recipient address (0x...)"),
    amount_usdc: z.number().positive().describe("Amount in USDC, e.g. 0.25"),
    memo: z.string().min(3).max(140).describe("What this payment is for. Shown to the owner."),
  },
}, async ({ to, amount_usdc, memo }) => {
  if (!ethers.isAddress(to)) return { ...text("Not a valid address."), isError: true };
  const amount = toWei(amount_usdc);
  try {
    await leash.pay.staticCall(to, amount, memo); // fails fast (frozen, no budget) without spending gas
    const gas = await ensureGas();
    const t0 = Date.now();
    const tx = await leash.pay(to, amount, memo);
    const rcpt = await tx.wait();
    const ms = Date.now() - t0;
    const queued = rcpt.logs.map((l) => { try { return iface.parseLog(l); } catch { return null; } }).find((p) => p?.name === "RequestQueued");
    const out = queued
      ? { result: "held for owner approval", request_id: Number(queued.args.id), reason: queued.args.reason, amount: usd(amount), tx: txUrl(tx.hash) }
      : { result: "paid", amount: usd(amount), to, memo, final_after_ms: ms, tx: txUrl(tx.hash) };
    if (gas) out.gas_refuel = gas;
    return text(out);
  } catch (e) {
    return { ...text(`Blocked: ${friendly(e)}`), isError: true };
  }
});

server.registerTool("leash_request", {
  title: "Leash: check an approval request",
  description: "See whether the owner approved, rejected or has not yet decided on a held payment.",
  inputSchema: { request_id: z.number().int().nonnegative() },
}, async ({ request_id }) => {
  try {
    const r = await leash.getRequest(request_id);
    if (r.agent.toLowerCase() !== agent.address.toLowerCase()) return { ...text("That request belongs to another agent."), isError: true };
    return text({ request_id, status: STATUS[Number(r.status)], amount: usd(r.amount), to: r.to, memo: r.memo });
  } catch (e) { return { ...text(friendly(e)), isError: true }; }
});

await server.connect(new StdioServerTransport());
console.error(`leash-mcp: agent ${agent.address} on Arc ${netName}, leash ${ADDRESS}`);
