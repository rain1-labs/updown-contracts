#!/usr/bin/env node
// SPDX-License-Identifier: MIT
//
// fetch_streams_report.mjs — fetch a single signed Chainlink Data Streams
// `ReportV3` blob from the REST API, for two consumers:
//
//   1. UpDownForkTest.t.sol (Gate 3 real-DON fork test) via `vm.ffi`. In that
//      mode it prints ONE line: the `0x`-hex `fullReport` blob, which forge
//      decodes straight into `bytes`. The Solidity test then decodes the
//      ReportV3 itself (same `(bytes32[3],bytes)` unwrap the resolver does) so
//      the FFI surface stays minimal and un-spoofable.
//   2. A human operator sanity-checking creds / feed authorization / the 3s
//      window / decimals, via `--pretty` (decoded, annotated summary).
//
// The HMAC canonicalization is byte-identical to the production backend
// (`updown-backend/src/services/ChainlinkResolverService.ts#buildAuthHeaders`
// + `fetchSignedReport`) so this is a faithful proxy for what the live
// resolver-service does — if this fetch works, the backend's does too.
//
//   stringToSign = `${method} ${pathAndQuery} ${sha256hex(body)} ${apiKey} ${timestampMs}`
//   signature    = HMAC-SHA256(apiSecret, stringToSign)          // hex
//   headers: Authorization=<apiKey>
//            X-Authorization-Timestamp=<timestampMs>
//            X-Authorization-Signature-SHA256=<signature>
//
// Env (accepts the backend `CHAINLINK_STREAMS_*` names AND the bare
// `STREAMS_*` names used in the testnet cred bundle):
//   CHAINLINK_STREAMS_API_KEY    | STREAMS_API_KEY       (required)
//   CHAINLINK_STREAMS_API_SECRET | STREAMS_API_SECRET    (required)
//   CHAINLINK_STREAMS_API_BASE_URL | STREAMS_API_BASE_URL
//       (default https://api.testnet-dataengine.chain.link)
//
// Usage:
//   node script/fetch_streams_report.mjs <feedId> <timestamp|latest|prev>
//   node script/fetch_streams_report.mjs <feedId> <ts> --pretty
//
//   <timestamp> : unix seconds. `latest` uses /reports/latest; `prev` uses the
//                 previous clock-aligned 300s boundary (a safely-finalized,
//                 non-expired past report — the default the fork test passes).

import { createHash, createHmac } from 'node:crypto';

const DEFAULT_BASE = 'https://api.testnet-dataengine.chain.link';
const ALIGN = 300; // smallest UpDown timeframe / STRIKE_ALIGNMENT

function env(...names) {
  for (const n of names) {
    if (process.env[n] && process.env[n].length > 0) return process.env[n];
  }
  return '';
}

function die(msg) {
  process.stderr.write(`fetch_streams_report: ${msg}\n`);
  process.exit(1);
}

function buildAuthHeaders(apiKey, apiSecret, method, pathAndQuery, body) {
  const timestampMs = Date.now().toString();
  const bodyHash = createHash('sha256').update(body).digest('hex');
  const stringToSign = [method, pathAndQuery, bodyHash, apiKey, timestampMs].join(' ');
  const signature = createHmac('sha256', apiSecret).update(stringToSign).digest('hex');
  return {
    Authorization: apiKey,
    'X-Authorization-Timestamp': timestampMs,
    'X-Authorization-Signature-SHA256': signature,
  };
}

// ── Minimal, dependency-free ABI reader for the fullReport envelope ──────────
// fullReport = abi.encode(bytes32[3] ctx, bytes reportData, bytes32[] rs,
//                         bytes32[] ss, bytes32 rawVs)
// reportData = abi.encode(ReportV3) — 9 static words, inline.
function hexToBytes(hex) {
  const h = hex.startsWith('0x') ? hex.slice(2) : hex;
  return Buffer.from(h, 'hex');
}
function wordBig(buf, wordIndex) {
  const start = wordIndex * 32;
  return BigInt('0x' + buf.subarray(start, start + 32).toString('hex'));
}
function asInt(u, bits) {
  // two's-complement reinterpret of a `bits`-wide value packed in a 256-bit word
  const mask = (1n << BigInt(bits)) - 1n;
  const v = u & mask;
  return v >= 1n << BigInt(bits - 1) ? v - (1n << BigInt(bits)) : v;
}
function decodeReportV3(fullReportHex) {
  const buf = hexToBytes(fullReportHex);
  // head: [ctx0, ctx1, ctx2, reportDataOffset, rsOffset, ssOffset, rawVs]
  const reportDataOffset = Number(wordBig(buf, 3)); // bytes from start of blob
  const len = Number(wordBig(buf, reportDataOffset / 32));
  const rdStart = reportDataOffset + 32;
  const rd = buf.subarray(rdStart, rdStart + len);
  const w = (i) => BigInt('0x' + rd.subarray(i * 32, i * 32 + 32).toString('hex'));
  return {
    feedId: '0x' + rd.subarray(0, 32).toString('hex'),
    // validFromTimestamp/observationsTimestamp/expiresAt are uint32 — plain
    // low-4-byte reads (no sign handling).
    validFromTimestamp: Number(w(1) & 0xffffffffn),
    observationsTimestamp: Number(w(2) & 0xffffffffn),
    nativeFee: w(3) & ((1n << 192n) - 1n),
    linkFee: w(4) & ((1n << 192n) - 1n),
    expiresAt: Number(w(5) & 0xffffffffn),
    price: asInt(w(6), 192),
    bid: asInt(w(7), 192),
    ask: asInt(w(8), 192),
  };
}

function fmt18(x) {
  const neg = x < 0n;
  const v = neg ? -x : x;
  const whole = v / 10n ** 18n;
  const frac = (v % 10n ** 18n).toString().padStart(18, '0').replace(/0+$/, '') || '0';
  return `${neg ? '-' : ''}${whole}.${frac}`;
}

async function main() {
  const [, , feedIdArg, tsArg, ...rest] = process.argv;
  const pretty = rest.includes('--pretty');
  const apiKey = env('CHAINLINK_STREAMS_API_KEY', 'STREAMS_API_KEY');
  const apiSecret = env('CHAINLINK_STREAMS_API_SECRET', 'STREAMS_API_SECRET');
  const base = (env('CHAINLINK_STREAMS_API_BASE_URL', 'STREAMS_API_BASE_URL') || DEFAULT_BASE).replace(/\/$/, '');

  if (!feedIdArg) die('missing <feedId> arg');
  if (!apiKey || !apiSecret) die('missing STREAMS_API_KEY / STREAMS_API_SECRET in env');

  const nowSec = Math.floor(Date.now() / 1000);
  let path;
  if (!tsArg || tsArg === 'latest') {
    // operator-only convenience. Production (ChainlinkResolverService) NEVER
    // issues /reports/latest — the parity path is the timestamp form below, and
    // the FFI consumer (UpDownForkTest) always passes an explicit timestamp.
    path = `/api/v1/reports/latest?feedID=${encodeURIComponent(feedIdArg)}`;
  } else {
    let ts;
    if (tsArg === 'prev') ts = (Math.floor(nowSec / ALIGN) - 1) * ALIGN;
    else ts = parseInt(tsArg, 10);
    if (!Number.isFinite(ts)) die(`bad <timestamp> '${tsArg}'`);
    path = `/api/v1/reports?feedID=${encodeURIComponent(feedIdArg)}&timestamp=${ts}`;
  }

  const headers = buildAuthHeaders(apiKey, apiSecret, 'GET', path, '');
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  let res;
  try {
    res = await fetch(`${base}${path}`, { method: 'GET', headers, signal: controller.signal });
  } catch (e) {
    die(`network error: ${e.message}`);
  } finally {
    clearTimeout(timer);
  }
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    die(`HTTP ${res.status}: ${body.slice(0, 300)}`);
  }
  const json = await res.json();
  const full = json?.report?.fullReport;
  if (!full || typeof full !== 'string' || !full.startsWith('0x')) {
    die(`missing/malformed fullReport in response: ${JSON.stringify(json).slice(0, 300)}`);
  }

  if (!pretty) {
    // FFI mode: single line, the raw blob. forge decodes 0x-hex → bytes.
    process.stdout.write(full + '\n');
    return;
  }

  const r = decodeReportV3(full);
  const LINK = fmt18(r.linkFee);
  const out = {
    base,
    feedId: r.feedId,
    price_1e18: r.price.toString(),
    price_human: fmt18(r.price),
    bid_human: fmt18(r.bid),
    ask_human: fmt18(r.ask),
    observationsTimestamp: r.observationsTimestamp,
    validFromTimestamp: r.validFromTimestamp,
    expiresAt: r.expiresAt,
    expiresInSec: r.expiresAt - nowSec,
    linkFee_wei: r.linkFee.toString(),
    linkFee_LINK: LINK,
    nativeFee_wei: r.nativeFee.toString(),
    reportTopLevelObs: json.report.observationsTimestamp,
    fullReportBytes: (full.length - 2) / 2,
  };
  process.stdout.write(JSON.stringify(out, null, 2) + '\n');
}

main().catch((e) => die(e.stack || String(e)));
