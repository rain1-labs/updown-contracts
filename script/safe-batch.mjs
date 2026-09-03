#!/usr/bin/env node
// safe-batch.mjs — build, and optionally propose, the owner transactions for a stack whose
// owner is a Safe (or any address that is not the deployer key).
//
//   node script/safe-batch.mjs <dev|prod>
//       Derive every owner action the live stack is still waiting on: acceptOwnership() for
//       any contract pending to OWNER_ADDRESS, setResolver/setAutocycler when the latest
//       deployment record points somewhere Settlement does not yet, deprecate() on the cycler
//       being replaced, and relayer/treasury drift against the env file. Reads the chain, so
//       it is idempotent: run it again and it prints "nothing pending".
//
//   node script/safe-batch.mjs <dev|prod> --call <to> '<sig>' [args...] [--call ...]
//       Ad-hoc owner call(s). <to> may be an address or one of: settlement, resolver, cycler
//       (resolved from EXISTING_SETTLEMENT_ADDRESS and its live pointers).
//         --call cycler 'toggleTimeframe(uint256,bool)' 2 false
//
//   Flags
//     --name <slug>        file name component (default: pending | call)
//     --out <file>         write the batch here instead of deployments/safe/
//     --settlement <addr>  override EXISTING_SETTLEMENT_ADDRESS
//     --record <file>      deployment record naming the target Resolver/AutoCycler (default:
//                          newest deployments/<label>-*.json whose settlement matches)
//     --propose            also submit to the Safe Transaction Service, signed by ONE signer
//                          (SAFE_PROPOSER_PRIVATE_KEY, or --ledger / --trezor / --account <name>)
//     --nonce <n>          Safe nonce for --propose (default: next free, queue-aware)
//     --dry-run            with --propose: build and sign, print the payload, do not submit
//
// Output is a Safe{Wallet} Transaction Builder batch file (version 1.0, checksummed exactly the
// way the app does it). Import it via Safe{Wallet} > Apps > Transaction Builder, or let
// --propose put it straight into the Safe's queue for the other signers.
//
// Zero dependencies on purpose: every ABI encoding, hash and signature goes through `cast`.

import { execFileSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..');
const ZERO = '0x0000000000000000000000000000000000000000';
// Safe 1.4.1 canonical MultiSendCallOnly — same address on every chain it is deployed to.
const MULTISEND_CALL_ONLY = '0x9641d764fc13c8B624c04430C7356C1C7C8102e2';
const CHAINS = {
  42161: { prefix: 'arb1', txService: 'https://api.safe.global/tx-service/arb1' },
};

// ── helpers ─────────────────────────────────────────────────────────────────
const lc = (s) => String(s).toLowerCase();
const same = (a, b) => !!a && !!b && lc(a) === lc(b);
const isAddr = (v) => typeof v === 'string' && /^0x[0-9a-fA-F]{40}$/.test(v);
const addrOr = (v) => (isAddr(v) ? v : null);
const short = (a) => `${a.slice(0, 6)}…${a.slice(-4)}`;
const log = (...a) => console.log(...a);
const warn = (m) => console.log(`  ! ${m}`);
function die(m) {
  console.error(`\n  ✗ ${m}\n`);
  process.exit(1);
}

function usage() {
  log(readFileSync(fileURLToPath(import.meta.url), 'utf8').split('\n').slice(1, 30).map((l) => l.replace(/^\/\/ ?/, '')).join('\n'));
}

function cast(args, input) {
  try {
    return execFileSync('cast', args, { encoding: 'utf8', input, stdio: ['pipe', 'pipe', 'pipe'] }).trim();
  } catch (e) {
    die(`cast ${args.slice(0, 2).join(' ')} failed:\n${(e.stderr || e.message || '').trim()}`);
  }
}

// ── args ────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const o = { label: null, calls: [], name: null, out: null, settlement: null, record: null, propose: false, nonce: null, dryRun: false, signer: [] };
  let i = 0;
  if (argv[0] && !argv[0].startsWith('-')) {
    o.label = argv[0];
    i = 1;
  }
  for (; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case '--call': {
        const to = argv[++i];
        const sig = argv[++i];
        if (!to || !sig) die('--call needs <to> <sig> [args...]');
        const args = [];
        while (i + 1 < argv.length && !argv[i + 1].startsWith('--')) args.push(argv[++i]);
        o.calls.push({ to, sig, args });
        break;
      }
      case '--name': o.name = argv[++i]; break;
      case '--out': o.out = argv[++i]; break;
      case '--settlement': o.settlement = argv[++i]; break;
      case '--record': o.record = argv[++i]; break;
      case '--propose': o.propose = true; break;
      case '--nonce': o.nonce = Number(argv[++i]); break;
      case '--dry-run': o.dryRun = true; break;
      case '--ledger': case '--trezor': o.signer.push(a); break;
      case '--account': o.signer.push(a, argv[++i]); break;
      case '-h': case '--help': usage(); process.exit(0);
      default: die(`unknown flag: ${a}`);
    }
  }
  if (o.label !== 'dev' && o.label !== 'prod') {
    usage();
    die('first argument must be dev or prod');
  }
  return o;
}

// ── env ─────────────────────────────────────────────────────────────────────
function loadEnv(label) {
  const file = join(ROOT, `.env.${label}`);
  if (!existsSync(file)) die(`missing ${file}`);
  const env = {};
  for (const raw of readFileSync(file, 'utf8').split('\n')) {
    const line = raw.trim();
    if (!line || line.startsWith('#')) continue;
    const m = line.match(/^(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (!m) continue;
    let v = m[2].trim();
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
    env[m[1]] = v;
  }
  // Anything already exported into the process wins (upgrade.sh sources the file; a one-off
  // SAFE_PROPOSER_PRIVATE_KEY=... on the command line must not need editing the file).
  for (const k of Object.keys(process.env)) {
    if (k in env || /^(SAFE_|ARBITRUM_|OWNER_|EXISTING_|RELAYER_|TREASURY_)/.test(k)) env[k] = process.env[k];
  }
  return env;
}

// ── deployment records ──────────────────────────────────────────────────────
function latestRecord(label, explicit) {
  if (explicit) {
    const f = resolve(explicit);
    if (!existsSync(f)) die(`--record ${explicit}: no such file`);
    return { ...JSON.parse(readFileSync(f, 'utf8')), file: explicit };
  }
  const dir = join(ROOT, 'deployments');
  let best = null;
  for (const f of readdirSync(dir)) {
    if (!f.startsWith(`${label}-`) || !f.endsWith('.json')) continue;
    let rec;
    try { rec = JSON.parse(readFileSync(join(dir, f), 'utf8')); } catch { continue; }
    const blk = Number(rec.l1Block ?? rec.block ?? 0);
    if (!best || blk > best.blk) best = { ...rec, blk, file: `deployments/${f}` };
  }
  return best;
}

// ── actions ─────────────────────────────────────────────────────────────────
function parseSig(sig) {
  const m = sig.match(/^([A-Za-z_][A-Za-z0-9_]*)\((.*)\)$/);
  if (!m) die(`bad function signature: ${sig}`);
  const inner = m[2].trim();
  return { name: m[1], types: inner === '' ? [] : inner.split(',').map((s) => s.trim()) };
}

function action(to, sig, args, note, argNames = []) {
  const { name, types } = parseSig(sig);
  if (types.length !== args.length) die(`${sig}: expected ${types.length} arg(s), got ${args.length}`);
  const data = types.length ? cast(['calldata', sig, ...args]) : cast(['sig', sig]);
  const inputs = types.map((t, i) => ({ internalType: t, name: argNames[i] ?? `arg${i}`, type: t }));
  const values = Object.fromEntries(inputs.map((inp, i) => [inp.name, String(args[i])]));
  return { to, sig, name, args, data, note, method: { inputs, name, payable: false }, values };
}

function derivePending({ label, env, rpc, settlementOverride, recordOverride }) {
  const c = (to, sig, ...args) => cast(['call', to, sig, ...args, '--rpc-url', rpc]);
  const own = (a) => ({ owner: c(a, 'owner()(address)'), pending: c(a, 'pendingOwner()(address)') });

  const owner = addrOr(env.OWNER_ADDRESS);
  if (!owner) die(`OWNER_ADDRESS is unset in .env.${label} -- nothing here is owned by a Safe`);
  const S = addrOr(settlementOverride) ?? addrOr(env.EXISTING_SETTLEMENT_ADDRESS);
  if (!S) die('EXISTING_SETTLEMENT_ADDRESS is unset (or pass --settlement <addr>)');

  const rec = latestRecord(label, recordOverride);
  let target = null;
  if (rec && same(rec.settlement, S)) target = rec;
  else if (rec) warn(`latest record ${rec.file} deploys Settlement ${rec.settlement}, not ${S} -- if that is the live stack, update EXISTING_SETTLEMENT_ADDRESS or pass --settlement`);

  const liveRes = c(S, 'resolver()(address)');
  const liveCyc = c(S, 'autocycler()(address)');
  const s = own(S);
  const tRes = target?.resolver ?? liveRes;
  const tCyc = target?.autocycler ?? liveCyc;

  log(`  Settlement ${S}`);
  log(`    owner ${s.owner}${same(s.owner, owner) ? '  (= OWNER_ADDRESS)' : ''}  pending ${s.pending}`);
  log(`    resolver ${liveRes}${same(tRes, liveRes) ? '' : `  -> record says ${tRes}`}`);
  log(`    cycler   ${liveCyc}${same(tCyc, liveCyc) ? '' : `  -> record says ${tCyc}`}`);
  if (target) log(`  Record     ${target.file}`);
  log('');

  const actions = [];
  const controlsS = same(s.owner, owner) || same(s.pending, owner);

  if (same(s.pending, owner)) actions.push(action(S, 'acceptOwnership()', [], 'Settlement: complete the Ownable2Step handoff'));
  else if (!same(s.owner, owner)) warn(`Settlement is owned by ${s.owner} and not pending to OWNER_ADDRESS -- run npm run handoff:${label} from the deployer first`);

  if (!same(tRes, liveRes)) {
    if (controlsS) actions.push(action(S, 'setResolver(address)', [tRes], 'Settlement: adopt the newly deployed Resolver', ['a']));
    else warn(`record wants resolver ${tRes} but OWNER_ADDRESS does not control Settlement -- cannot repoint`);
  }
  if (!same(tCyc, liveCyc)) {
    if (controlsS) actions.push(action(S, 'setAutocycler(address)', [tCyc], 'Settlement: adopt the newly deployed AutoCycler', ['a']));
    else warn(`record wants cycler ${tCyc} but OWNER_ADDRESS does not control Settlement -- cannot repoint`);
  }

  for (const [name, a] of [['Resolver', tRes], ['AutoCycler', tCyc]]) {
    const o = own(a);
    if (same(o.pending, owner)) actions.push(action(a, 'acceptOwnership()', [], `${name}: complete the Ownable2Step handoff`));
    else if (!same(o.owner, owner)) warn(`${name} ${a} is owned by ${o.owner} and not pending to OWNER_ADDRESS`);
  }

  if (!same(tCyc, liveCyc)) {
    const o = own(liveCyc);
    if (same(o.owner, owner) || same(o.pending, owner)) {
      if (same(o.pending, owner)) actions.push(action(liveCyc, 'acceptOwnership()', [], 'Old AutoCycler: accept so it can be retired'));
      if (c(liveCyc, 'deprecated()(bool)') === 'false') {
        actions.push(action(liveCyc, 'deprecate(address)', [tCyc], 'Old AutoCycler: fence it off from keeper work', ['replacement']));
      }
    } else {
      warn(`old cycler ${liveCyc} is owned by ${o.owner} -- deprecate it from that key`);
    }
  }

  if (controlsS) {
    const relayer = addrOr(env.RELAYER_ADDRESS);
    const treasury = addrOr(env.TREASURY_ADDRESS);
    const liveRelayer = c(S, 'relayer()(address)');
    const liveTreasury = c(S, 'treasury()(address)');
    if (relayer && !same(relayer, liveRelayer)) actions.push(action(S, 'setRelayer(address)', [relayer], `Settlement: relayer drift (live ${liveRelayer})`, ['a']));
    if (treasury && !same(treasury, liveTreasury)) actions.push(action(S, 'setTreasury(address)', [treasury], `Settlement: treasury drift (live ${liveTreasury})`, ['a']));
  }

  return { actions, safe: owner, settlement: S };
}

function resolveTarget(to, { env, rpc, settlementOverride }) {
  if (isAddr(to)) return to;
  const S = addrOr(settlementOverride) ?? addrOr(env.EXISTING_SETTLEMENT_ADDRESS);
  if (!S) die(`--call ${to}: EXISTING_SETTLEMENT_ADDRESS is unset, so the alias cannot be resolved`);
  if (to === 'settlement') return S;
  if (to === 'resolver') return cast(['call', S, 'resolver()(address)', '--rpc-url', rpc]);
  if (to === 'cycler' || to === 'autocycler') return cast(['call', S, 'autocycler()(address)', '--rpc-url', rpc]);
  die(`--call ${to}: not an address or one of settlement | resolver | cycler`);
}

// ── Transaction Builder file ────────────────────────────────────────────────
// Port of apps/tx-builder/src/lib/checksum.ts from safe-global/safe-react-apps. The app
// re-derives this on import, so the serialisation has to match byte for byte.
const stringifyReplacer = (_, v) => (v === undefined ? null : v);
function serializeJSONObject(json) {
  if (Array.isArray(json)) return `[${json.map(serializeJSONObject).join(',')}]`;
  if (typeof json === 'object' && json !== null) {
    let acc = '';
    const keys = Object.keys(json).sort();
    acc += `{${JSON.stringify(keys, stringifyReplacer)}`;
    for (const k of keys) acc += `${serializeJSONObject(json[k])},`;
    return `${acc}}`;
  }
  return `${JSON.stringify(json, stringifyReplacer)}`;
}
function checksum(batch) {
  return cast(['keccak', serializeJSONObject({ ...batch, meta: { ...batch.meta, name: null } })]);
}

function buildBatch({ chainId, safe, name, description, actions }) {
  const batch = {
    version: '1.0',
    chainId: String(chainId),
    createdAt: Date.now(),
    meta: { name, description, txBuilderVersion: '1.17.1', createdFromSafeAddress: safe, createdFromOwnerAddress: '' },
    transactions: actions.map((a) => ({ to: a.to, value: '0', data: a.data, contractMethod: a.method, contractInputsValues: a.values })),
  };
  batch.meta.checksum = checksum(batch);
  return batch;
}

// ── Safe Transaction Service proposal ───────────────────────────────────────
function packMultiSend(actions) {
  return `0x${actions
    .map((a) => {
      const data = a.data.slice(2);
      return `00${a.to.slice(2).toLowerCase()}${'0'.repeat(64)}${(data.length / 2).toString(16).padStart(64, '0')}${data}`;
    })
    .join('')}`;
}

async function getJson(url) {
  const r = await fetch(url, { headers: { accept: 'application/json' } });
  if (!r.ok) die(`GET ${url} -> ${r.status} ${await r.text()}`);
  return r.json();
}

async function propose({ env, rpc, chainId, safe, actions, nonceOverride, signerFlags, dryRun }) {
  const base = env.SAFE_TX_SERVICE_URL || CHAINS[chainId]?.txService;
  if (!base) die(`no Safe Transaction Service known for chain ${chainId}; set SAFE_TX_SERVICE_URL`);

  let to, data, operation;
  if (actions.length === 1) {
    ({ to, data } = actions[0]);
    operation = 0;
  } else {
    to = MULTISEND_CALL_ONLY;
    operation = 1; // DELEGATECALL into MultiSendCallOnly; every inner call is a plain CALL from the Safe
    data = cast(['calldata', 'multiSend(bytes)', packMultiSend(actions)]);
  }

  const info = await getJson(`${base}/api/v1/safes/${safe}/`);
  let nonce = Number(info.nonce);
  const queued = await getJson(`${base}/api/v1/safes/${safe}/multisig-transactions/?executed=false&ordering=-nonce&limit=1`);
  if (queued.results?.length) nonce = Math.max(nonce, Number(queued.results[0].nonce) + 1);
  if (nonceOverride != null && !Number.isNaN(nonceOverride)) nonce = nonceOverride;

  const signerArgs = signerFlags.length
    ? signerFlags
    : env.SAFE_PROPOSER_PRIVATE_KEY && env.SAFE_PROPOSER_PRIVATE_KEY !== '0x'
      ? ['--private-key', env.SAFE_PROPOSER_PRIVATE_KEY]
      : die('no signer for --propose: set SAFE_PROPOSER_PRIVATE_KEY, or pass --ledger / --trezor / --account <keystore>');
  const sender = cast(['wallet', 'address', ...signerArgs]);
  if (!info.owners.map(lc).includes(lc(sender))) die(`${sender} is not a signer of Safe ${safe} (signers: ${info.owners.join(', ')})`);

  // The Safe's own hash is the source of truth; the EIP-712 signature must recover against it.
  const safeTxHash = cast([
    'call', safe,
    'getTransactionHash(address,uint256,bytes,uint8,uint256,uint256,uint256,address,address,uint256)(bytes32)',
    to, '0', data, String(operation), '0', '0', '0', ZERO, ZERO, String(nonce), '--rpc-url', rpc,
  ]);
  const typed = {
    types: {
      EIP712Domain: [{ name: 'chainId', type: 'uint256' }, { name: 'verifyingContract', type: 'address' }],
      SafeTx: [
        { name: 'to', type: 'address' }, { name: 'value', type: 'uint256' }, { name: 'data', type: 'bytes' },
        { name: 'operation', type: 'uint8' }, { name: 'safeTxGas', type: 'uint256' }, { name: 'baseGas', type: 'uint256' },
        { name: 'gasPrice', type: 'uint256' }, { name: 'gasToken', type: 'address' }, { name: 'refundReceiver', type: 'address' },
        { name: 'nonce', type: 'uint256' },
      ],
    },
    primaryType: 'SafeTx',
    domain: { chainId: String(chainId), verifyingContract: safe },
    message: { to, value: '0', data, operation: String(operation), safeTxGas: '0', baseGas: '0', gasPrice: '0', gasToken: ZERO, refundReceiver: ZERO, nonce: String(nonce) },
  };
  const typedFile = join(ROOT, 'deployments', 'safe', `.typed-${Date.now()}.json`);
  mkdirSync(dirname(typedFile), { recursive: true });
  writeFileSync(typedFile, JSON.stringify(typed));
  let signature;
  try {
    signature = cast(['wallet', 'sign', '--data', '--from-file', typedFile, ...signerArgs]);
  } finally {
    try { execFileSync('rm', ['-f', typedFile]); } catch { /* best effort */ }
  }
  // ecrecover precompile: proves the signature is over the Safe's hash and made by `sender`.
  const v = signature.slice(130, 132).padStart(64, '0');
  const recovered = cast(['call', '0x0000000000000000000000000000000000000001', '--data', `${safeTxHash}${v}${signature.slice(2, 130)}`, '--rpc-url', rpc]);
  if (!same(`0x${recovered.slice(-40)}`, sender)) die('signature does not recover to the signer over the Safe tx hash -- refusing to submit');

  const body = {
    safe, to, value: '0', data, operation, gasToken: ZERO, safeTxGas: 0, baseGas: 0, gasPrice: '0', refundReceiver: ZERO,
    nonce, contractTransactionHash: safeTxHash, sender, signature, origin: 'updown-contracts safe-batch.mjs',
  };
  log(`  Safe tx hash ${safeTxHash}  nonce ${nonce}  signer ${sender}`);
  if (dryRun) {
    log('  --dry-run: not submitted. Payload:');
    log(JSON.stringify(body, null, 2));
    return;
  }
  const r = await fetch(`${base}/api/v1/safes/${safe}/multisig-transactions/`, {
    method: 'POST', headers: { 'content-type': 'application/json', accept: 'application/json' }, body: JSON.stringify(body),
  });
  if (!r.ok) die(`proposal rejected: ${r.status} ${await r.text()}`);
  const prefix = CHAINS[chainId]?.prefix ?? chainId;
  log(`  ✓ proposed (1 of ${info.threshold} signatures). Other signers confirm and execute at:`);
  log(`    https://app.safe.global/transactions/queue?safe=${prefix}:${safe}`);
}

// ── main ────────────────────────────────────────────────────────────────────
async function main() {
  const opts = parseArgs(process.argv.slice(2));
  const { label } = opts;
  const env = loadEnv(label);
  const rpc = env.ARBITRUM_RPC_URL;
  if (!rpc) die('ARBITRUM_RPC_URL unset');
  const chainId = Number(cast(['chain-id', '--rpc-url', rpc]));
  const ctx = { label, env, rpc, settlementOverride: opts.settlement, recordOverride: opts.record };

  log(`\n══ SAFE BATCH — ${label} (chain ${chainId}) ══`);
  let actions, safe;
  if (opts.calls.length) {
    safe = addrOr(env.OWNER_ADDRESS);
    if (!safe) die(`OWNER_ADDRESS is unset in .env.${label}`);
    actions = opts.calls.map((cl) => action(resolveTarget(cl.to, ctx), cl.sig, cl.args, 'ad-hoc owner call'));
  } else {
    ({ actions, safe } = derivePending(ctx));
  }

  if (!actions.length) {
    log('  ✓ nothing pending — the owner has no outstanding action on this stack\n');
    return;
  }

  log(`  Owner (Safe) ${safe}`);
  actions.forEach((a, i) => {
    log(`  ${String(i + 1).padStart(2)}. ${short(a.to)}  ${a.name}(${a.args.join(', ')})`);
    log(`      ${a.note}`);
  });

  const name = opts.name ?? (opts.calls.length ? 'call' : 'pending');
  // ASCII only: the checksum is over the UTF-8 bytes and every reader hashes it the same way.
  const description = `${label}: ${actions.map((a) => `${a.to.slice(0, 10)}.${a.name}(${a.args.join(',')})`).join('; ')}`;
  const batch = buildBatch({ chainId, safe, name: `updown ${label} ${name}`, description, actions });
  const stamp = new Date().toISOString().replace(/[-:]/g, '').replace(/\..*/, '').replace('T', '-');
  const out = opts.out ? resolve(opts.out) : join(ROOT, 'deployments', 'safe', `${label}-${name}-${stamp}.json`);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, `${JSON.stringify(batch, null, 2)}\n`);
  const prefix = CHAINS[chainId]?.prefix ?? chainId;
  log(`\n  Batch file ${out.replace(`${ROOT}/`, '')}`);
  log(`  Import it: Safe{Wallet} > Apps > Transaction Builder > drag the file > Create Batch > Send Batch`);
  log(`    https://app.safe.global/apps/open?safe=${prefix}:${safe}&appUrl=https%3A%2F%2Fapps-portal.safe.global%2Ftx-builder`);

  if (opts.propose) {
    log('');
    await propose({ env, rpc, chainId, safe, actions, nonceOverride: opts.nonce, signerFlags: opts.signer, dryRun: opts.dryRun });
  }
  log('');
}

main().catch((e) => die(e?.stack || String(e)));
