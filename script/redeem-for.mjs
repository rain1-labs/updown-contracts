#!/usr/bin/env node
// redeem-for.mjs — push unredeemed winnings to their holders with the permissionless
// `redeemFor(marketId, holders[])`. No owner involved; the caller only pays gas and funds can
// only ever reach the share owner.
//
//   node script/redeem-for.mjs <dev|prod> --settlement <addr> --markets 1,2,3        # dry run
//   node script/redeem-for.mjs <dev|prod> --settlement <addr> --markets 1,2,3 --send # broadcast
//
// For each market it collects every address that ever received shares (PositionEntered buyer,
// ComplementaryMinted minter, MintMatched up/down buyer), keeps the ones whose
// `userShares[market][holder][winner]` is still non-zero, and sends one redeemFor per market
// from DEPLOYER_PRIVATE_KEY (or --private-key / --ledger). Market ids come from
// script/UnredeemedSweep.s.sol. Zero dependencies: everything goes through `cast`.
//
//   --from-block <n>   log scan start (default: the Settlement's creation block, found by
//                      binary search on eth_getCode)

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const lc = (s) => String(s).toLowerCase();
const log = (...a) => console.log(...a);
function die(m) { console.error(`\n  ✗ ${m}\n`); process.exit(1); }
function cast(args) {
  try { return execFileSync('cast', args, { encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim(); }
  catch (e) { die(`cast ${args.slice(0, 2).join(' ')} failed:\n${(e.stderr || e.message || '').trim()}`); }
}

const argv = process.argv.slice(2);
const label = argv[0];
if (label !== 'dev' && label !== 'prod') die('first argument must be dev or prod');
const opt = { settlement: null, markets: [], send: false, fromBlock: 'auto', signer: [] };
for (let i = 1; i < argv.length; i++) {
  switch (argv[i]) {
    case '--settlement': opt.settlement = argv[++i]; break;
    case '--markets': opt.markets = argv[++i].split(',').map((s) => s.trim()).filter(Boolean); break;
    case '--send': opt.send = true; break;
    case '--from-block': opt.fromBlock = argv[++i]; break;
    case '--private-key': opt.signer = ['--private-key', argv[++i]]; break;
    case '--ledger': case '--trezor': opt.signer = [argv[i]]; break;
    case '--account': opt.signer = ['--account', argv[++i]]; break;
    default: die(`unknown flag: ${argv[i]}`);
  }
}
if (!opt.settlement) die('--settlement <addr> is required');
if (!opt.markets.length) die('--markets <id,id,...> is required');

const envFile = join(ROOT, `.env.${label}`);
if (!existsSync(envFile)) die(`missing ${envFile}`);
const env = {};
for (const line of readFileSync(envFile, 'utf8').split('\n')) {
  const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
  if (m && !line.trim().startsWith('#')) env[m[1]] = m[2].trim();
}
const rpc = process.env.ARBITRUM_RPC_URL || env.ARBITRUM_RPC_URL;
if (!rpc) die('ARBITRUM_RPC_URL unset');
if (!opt.signer.length) {
  const k = process.env.DEPLOYER_PRIVATE_KEY || env.DEPLOYER_PRIVATE_KEY;
  if (!k) die('no signer: set DEPLOYER_PRIVATE_KEY or pass --private-key / --ledger');
  opt.signer = ['--private-key', k];
}
const sender = cast(['wallet', 'address', ...opt.signer]);
const S = opt.settlement;
const call = (sig, ...args) => cast(['call', S, sig, ...args, '--rpc-url', rpc]);

const EVENTS = {
  PositionEntered: { sig: 'PositionEntered(uint256,uint8,uint256,address)', holders: (l) => [l.topics[2]] },
  ComplementaryMinted: { sig: 'ComplementaryMinted(uint256,address,uint256)', holders: (l) => [l.topics[2]] },
  MintMatched: { sig: 'MintMatched(uint256,address,address,uint256,uint256,uint256,address,uint256,uint256)', holders: (l) => [l.topics[2], l.topics[3]] },
};
for (const ev of Object.values(EVENTS)) ev.topic = cast(['sig-event', ev.sig]);
const topicAddr = (t) => `0x${t.slice(-40)}`;
const hex = (n) => `0x${n.toString(16)}`;

// Raw JSON-RPC. `cast logs` sends one request for the whole range, and providers such as
// Alchemy reject wide ranges with a size-heuristic 400 even when the filtered result is tiny —
// so fetch here and split the range on rejection.
let rpcId = 1;
async function rpcCall(method, params) {
  const r = await fetch(rpc, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ jsonrpc: '2.0', id: rpcId++, method, params }) });
  const j = await r.json();
  if (j.error) throw new Error(j.error.message);
  return j.result;
}
async function getLogs(filter, from, to, out) {
  try {
    for (const l of await rpcCall('eth_getLogs', [{ ...filter, fromBlock: hex(from), toBlock: hex(to) }])) out.push(l);
  } catch (e) {
    if (to - from < 2) throw e;
    const mid = Math.floor((from + to) / 2);
    await getLogs(filter, from, mid, out);
    await getLogs(filter, mid + 1, to, out);
  }
}
// First block at which the Settlement had code: the natural lower bound for every scan.
async function creationBlock(latest) {
  let lo = 0, hi = latest;
  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await rpcCall('eth_getCode', [S, hex(mid)])) === '0x') lo = mid + 1; else hi = mid;
  }
  return lo;
}
async function holdersOf(marketId, from, to) {
  const idTopic = `0x${BigInt(marketId).toString(16).padStart(64, '0')}`;
  const set = new Set();
  for (const ev of Object.values(EVENTS)) {
    const out = [];
    await getLogs({ address: S, topics: [ev.topic, idTopic] }, from, to, out);
    for (const l of out) for (const t of ev.holders(l)) set.add(lc(topicAddr(t)));
  }
  return [...set];
}

async function main() {
log(`\n══ REDEEM FOR — ${label} ══`);
log(`  Settlement ${S}`);
log(`  Sender     ${sender}  (pays gas only)`);
log(`  Mode       ${opt.send ? 'SEND' : 'dry run'}`);
const latest = parseInt(await rpcCall('eth_blockNumber', []), 16);
const fromBlock = opt.fromBlock === 'auto' ? await creationBlock(latest) : Number(opt.fromBlock);
log(`  Log scan   blocks ${fromBlock} .. ${latest}`);
const usdt = call('usdt()(address)');
log(`  USDT held  ${cast(['call', usdt, 'balanceOf(address)(uint256)', S, '--rpc-url', rpc])}`);

let grand = 0n;
const plan = [];
for (const id of opt.markets) {
  const m = call('markets(uint256)(bytes32,uint128,uint128,uint64,uint64,uint32,uint8,bool,bool,int128,int128)', id).split('\n').map((s) => s.trim());
  const winner = m[6];
  const resolved = m[7] === 'true';
  const retained = BigInt(call('marketRetained(uint256)(uint256)', id).split(' ')[0]);
  log(`\n  market ${id}: retained ${retained} resolved ${resolved} winner ${winner}`);
  if (!resolved) { log('    not resolved — redeem would revert NotResolved; skipping (needs the resolver first)'); continue; }
  if (retained === 0n) { log('    nothing retained — skipping'); continue; }
  const candidates = await holdersOf(id, fromBlock, latest);
  const holders = [];
  let sum = 0n;
  for (const h of candidates) {
    const sh = BigInt(call('userShares(uint256,address,uint8)(uint256)', id, h, winner).split(' ')[0]);
    if (sh > 0n) { holders.push(h); sum += sh; log(`    ${h}  ${sh}`); }
  }
  if (!holders.length) { log(`    ${candidates.length} past holder(s), none with winner shares — retained USDT is not claimable by anyone via redeem`); continue; }
  if (sum !== retained) log(`    ! winner shares ${sum} != retained ${retained} (difference stays in the contract)`);
  grand += sum;
  plan.push({ id, holders, sum });
}

log(`\n  Redeemable total: ${grand} (6dp) across ${plan.length} market(s)`);
if (!opt.send) { log('  Dry run — pass --send to broadcast.\n'); return; }

for (const p of plan) {
  const arr = `[${p.holders.join(',')}]`;
  const tx = cast(['send', S, 'redeemFor(uint256,address[])', p.id, arr, '--rpc-url', rpc, ...opt.signer, '--json']);
  let hash = '?';
  try { hash = JSON.parse(tx).transactionHash; } catch { /* keep ? */ }
  const after = call('marketRetained(uint256)(uint256)', p.id).split(' ')[0];
  log(`  ✓ market ${p.id}: redeemFor ${p.holders.length} holder(s), ${p.sum} paid — tx ${hash} — retained now ${after}`);
}
log(`\n  USDT held after: ${cast(['call', usdt, 'balanceOf(address)(uint256)', S, '--rpc-url', rpc])}\n`);
}

main().catch((e) => die(e?.stack || String(e)));
