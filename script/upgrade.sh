#!/usr/bin/env bash
#
# upgrade.sh — drive a Resolver + AutoCycler redeploy end to end.
#
#   ./script/upgrade.sh dev
#   ./script/upgrade.sh prod
#
# Settlement is never redeployed: it holds every position and all collateral,
# and Deploy.s.sol reuses it via EXISTING_SETTLEMENT_ADDRESS. Only the two
# satellite contracts are replaced, then Settlement is repointed at them.
#
# Phases, in order:
#   1  preflight                     read-only
#   2  removePair for each pair      broadcast   — stops new market creation
#   3  wait for open markets         read-only   — polls until every one settles
#   4  pruneResolved                 broadcast   — required; see below
#   5  preflight again               read-only   — must reach GO
#   6  deploy                        broadcast   — confirmed separately
#   7  post-deploy verification      read-only
#
# Why the drain is not optional: the moment Deploy.s.sol calls
# settlement.setResolver(new), the OLD resolver fails Settlement's onlyResolver
# check and the NEW resolver's markets mapping is empty. Any market still open
# at that instant can be settled by neither, and its collateral is stuck until
# an operator re-registers it by hand. Phase 5 is a hard gate for that reason.
#
# Safe to re-run. Every phase checks whether it has already happened, so an
# interrupted run picks up where it left off rather than repeating broadcasts.
#
# Flags:
#   --yes          skip the confirmation prompts (prod still confirms the deploy)
#   --skip-deploy  run phases 1-5 only, then stop and print the deploy command
#   --skip-drain   do NOT wait for open markets — see below
#   --orphan-collateral
#                  stands in for the typed ORPHAN confirmation, for unattended
#                  runs. Only meaningful with --skip-drain.
#   --poll <sec>   drain poll interval (default 60)
#
# --skip-drain abandons every open market: after setResolver they can be settled
# by neither resolver, so any collateral in them is unredeemable until an
# operator re-registers each one on the new resolver. It is defensible when the
# open markets are empty — a quiet dev environment — and a deliberate cost
# otherwise, so the flag prints the collateral at stake, requires a typed
# confirmation when any is found, and emits the recovery commands for every
# market it strands.
#
# --yes does not satisfy that confirmation: a run left unattended must not decide
# on its own to strand someone's position. --orphan-collateral is the separate,
# explicit way to say it, so the choice is always written down in the command
# rather than inherited from a general-purpose "assume yes".

set -euo pipefail

# ── args ────────────────────────────────────────────────────────────────────
ENVNAME="${1:-}"
shift || true
ASSUME_YES=0
SKIP_DEPLOY=0
SKIP_DRAIN=0
ORPHAN_OK=0
POLL=60

while [ $# -gt 0 ]; do
  case "$1" in
    --yes) ASSUME_YES=1 ;;
    --skip-deploy) SKIP_DEPLOY=1 ;;
    --skip-drain) SKIP_DRAIN=1 ;;
    --orphan-collateral) ORPHAN_OK=1 ;;
    --poll) POLL="$2"; shift ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ "$ENVNAME" != "dev" ] && [ "$ENVNAME" != "prod" ]; then
  echo "usage: $0 <dev|prod> [--yes] [--skip-deploy] [--skip-drain] [--orphan-collateral] [--poll <sec>]" >&2
  exit 2
fi

cd "$(dirname "$0")/.."
ENVFILE=".env.$ENVNAME"
[ -f "$ENVFILE" ] || { echo "missing $ENVFILE" >&2; exit 1; }

# ── colours / helpers ───────────────────────────────────────────────────────
# NB: single-letter names collide easily with loop vars — RS (reset) is
# deliberately two characters for that reason.
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; D=$'\033[2m'; RS=$'\033[0m'
else B=""; G=""; Y=""; R=""; D=""; RS=""; fi

phase () { printf '\n%s══ %s ══%s\n' "$B" "$1" "$RS"; }
ok    () { printf '  %s✓%s %s\n' "$G" "$RS" "$1"; }
info  () { printf '  %s·%s %s\n' "$D" "$RS" "$1"; }
warn  () { printf '  %s!%s %s\n' "$Y" "$RS" "$1"; }
die   () { printf '\n  %s✗ %s%s\n\n' "$R" "$1" "$RS"; exit 1; }

# macOS ships bash 3.2, so no ${var,,}.
lc () { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }

# Prefer the terminal, fall back to stdin, and abort if neither can answer —
# an unanswerable prompt must never be read as consent.
confirm () {
  [ "$ASSUME_YES" = "1" ] && return 0
  printf '  %s%s%s [y/N] ' "$B" "$1" "$RS"
  a=""
  { read -r a </dev/tty; } 2>/dev/null || read -r a 2>/dev/null || true
  case "$a" in
    y|Y) return 0 ;;
    "")  die "no answer available (not a terminal) — re-run with --yes to proceed unattended" ;;
    *)   die "aborted" ;;
  esac
}

# ── env ─────────────────────────────────────────────────────────────────────
set -a; . "./$ENVFILE"; set +a

: "${ARBITRUM_RPC_URL:?ARBITRUM_RPC_URL unset}"
: "${DEPLOYER_PRIVATE_KEY:?DEPLOYER_PRIVATE_KEY unset}"
: "${EXISTING_SETTLEMENT_ADDRESS:?EXISTING_SETTLEMENT_ADDRESS unset — without it the deploy creates a SECOND Settlement and strands all collateral on the current one}"

RPC="$ARBITRUM_RPC_URL"
SETT="$EXISTING_SETTLEMENT_ADDRESS"
KEY="$DEPLOYER_PRIVATE_KEY"

call () { cast call "$@" --rpc-url "$RPC"; }
send () { cast send "$@" --rpc-url "$RPC" --private-key "$KEY" >/dev/null; }

# The live stack comes from Settlement's own pointers, never from a env var or
# a deployment record — those describe what someone believes is deployed.
RESOLVER=$(call "$SETT" "resolver()(address)")
CYCLER=$(call "$SETT" "autocycler()(address)")
OWNER=$(call "$SETT" "owner()(address)")
DEPLOYER=$(cast wallet address --private-key "$KEY")

phase "TARGET — $ENVNAME"
info "Settlement (kept)     $SETT"
info "Resolver   (replaced) $RESOLVER"
info "Cycler     (replaced) $CYCLER"
info "Deployer              $DEPLOYER"
[ "$(lc "$OWNER")" = "$(lc "$DEPLOYER")" ] \
  && ok "deployer owns Settlement" \
  || die "deployer is not Settlement owner ($OWNER) — every owner-gated call would revert mid-broadcast"

if [ "$ENVNAME" = "prod" ]; then
  warn "PROD — real users, real collateral, markets go offline for the duration"
fi

# ── 1. preflight ────────────────────────────────────────────────────────────
phase "1/7  PREFLIGHT"
if npm run --silent "preflight:$ENVNAME" >/tmp/upgrade-preflight-1.log 2>&1; then
  ok "already GO — nothing to drain"
else
  info "NO-GO (expected at this point); see /tmp/upgrade-preflight-1.log"
fi

# ── 2. removePair ───────────────────────────────────────────────────────────
phase "2/7  STOP MARKET CREATION"
NPAIRS=$(call "$CYCLER" "cyclingPairCount()(uint256)")
if [ "$NPAIRS" = "0" ]; then
  ok "no cycling pairs — already stopped"
else
  # Read every pair BEFORE removing any: removePair swap-and-pops, so indices
  # shift underneath an interleaved read.
  PAIRS=()
  for i in $(seq 0 $((NPAIRS - 1))); do PAIRS+=("$(call "$CYCLER" "cyclingPairAt(uint256)(bytes32)" "$i")"); done
  info "removing $NPAIRS pair(s): ${PAIRS[*]}"
  confirm "send ${NPAIRS} removePair transaction(s)?"
  for p in "${PAIRS[@]}"; do
    send "$CYCLER" "removePair(bytes32)" "$p"
    ok "removePair $p"
  done
fi

# ── 3. drain ────────────────────────────────────────────────────────────────
# Scan the active set once: how many are unresolved, how much collateral they
# hold, and (for --skip-drain) the data needed to re-adopt each one later.
ORPHAN_FILE=/tmp/upgrade-orphans-$ENVNAME.txt
scan_active () {
  : >"$ORPHAN_FILE"
  UNRESOLVED=0; LATEST=0; EXPOSED=0; EXPOSED_TOTAL=0
  ACTIVE_N=$(call "$CYCLER" "activeMarketCount()(uint256)")
  [ "$ACTIVE_N" = "0" ] && return 0
  for i in $(seq 0 $((ACTIVE_N - 1))); do
    OUT=$(call "$CYCLER" "activeMarkets(uint256)(uint256,uint256,bytes32)" "$i")
    MID=$(echo "$OUT" | sed -n 1p)
    END=$(echo "$OUT" | sed -n 2p | sed 's/ .*//')
    M=$(call "$SETT" "getMarket(uint256)((bytes32,uint128,uint128,uint64,uint64,uint32,uint8,bool,bool,int128,int128))" "$MID" | sed 's/[()]//g')
    RES=$(echo "$M" | cut -d, -f8 | tr -d ' ')
    [ "$RES" = "false" ] || continue
    UNRESOLVED=$((UNRESOLVED + 1))
    [ "$END" -gt "$LATEST" ] && LATEST=$END || true
    PAIR=$(echo "$M" | cut -d, -f1 | tr -d ' ')
    STRIKE=$(echo "$M" | cut -d, -f10 | tr -d ' ' | sed 's/\[.*//')
    UP=$(echo "$M" | cut -d, -f2 | tr -d ' ' | sed 's/\[.*//')
    DN=$(echo "$M" | cut -d, -f3 | tr -d ' ' | sed 's/\[.*//')
    T=$((UP + DN))
    if [ "$T" -gt 0 ]; then EXPOSED=$((EXPOSED + 1)); EXPOSED_TOTAL=$((EXPOSED_TOTAL + T)); fi
    echo "$MID $PAIR $STRIKE $T" >>"$ORPHAN_FILE"
  done
  return 0
}

if [ "$SKIP_DRAIN" = "1" ]; then
  phase "3/7  DRAIN — SKIPPED (--skip-drain)"
  scan_active
  if [ "$UNRESOLVED" = "0" ]; then
    ok "nothing open — the flag changed nothing"
    SKIP_DRAIN=0   # nothing was stranded, so keep the normal gate
  else
    warn "abandoning $UNRESOLVED open market(s); $EXPOSED hold collateral"
    if [ "$EXPOSED" -gt 0 ]; then
      printf '  %s!%s total at stake: %s (6dp) — these positions become\n' "$Y" "$RS" "$EXPOSED_TOTAL"
      printf '      unredeemable until each market is re-registered.\n'
      while read -r MID PAIR STRIKE T; do
        [ "$T" -gt 0 ] && printf '        market %-8s notional %s\n' "$MID" "$T"
      done <"$ORPHAN_FILE"
      # Real value is on the line, so --yes alone must never carry this.
      if [ "$ORPHAN_OK" = "1" ]; then
        warn "--orphan-collateral given: stranding the above without prompting"
      else
        printf '\n  %sType ORPHAN to strand the collateral above:%s ' "$B" "$RS"
        typed=""
        { read -r typed </dev/tty; } 2>/dev/null || read -r typed 2>/dev/null || true
        [ "$typed" = "ORPHAN" ] \
          || die "not confirmed — let it settle, or pass --orphan-collateral to mean it"
      fi
    else
      ok "none hold collateral — nothing becomes unredeemable"
      confirm "proceed without draining?"
    fi
  fi
else
  phase "3/7  DRAIN"
  while :; do
    scan_active
    [ "$UNRESOLVED" = "0" ] && { ok "all markets settled"; break; }
    NOW=$(date +%s)
    REMAIN=$(( LATEST > NOW ? (LATEST - NOW) : 0 ))
    info "$UNRESOLVED unresolved ($EXPOSED holding collateral) — last endTime in ${REMAIN}s; polling every ${POLL}s"
    [ "$REMAIN" = "0" ] && warn "past every endTime but still unresolved — is the resolver service running?" || true
    sleep "$POLL"
  done
fi

# ── 4. prune ────────────────────────────────────────────────────────────────
phase "4/7  PRUNE"
# With every pair removed, createCount is 0, so upkeepNeeded is false and
# performUpkeep never fires again — and _pruneResolved only runs inside it.
# Without this call activeMarketCount stays put and tells you nothing.
if [ "$SKIP_DRAIN" = "1" ]; then
  ok "skipped — the active set is being abandoned, not tidied"
elif [ "$(call "$CYCLER" "activeMarketCount()(uint256)")" = "0" ]; then
  ok "active set already empty"
else
  confirm "send pruneResolved()?"
  send "$CYCLER" "pruneResolved()"
  REMAINING=$(call "$CYCLER" "activeMarketCount()(uint256)")
  [ "$REMAINING" = "0" ] && ok "active set cleared" || die "pruneResolved left $REMAINING market(s) — unresolved, do not proceed"
fi

# ── 5. gate ─────────────────────────────────────────────────────────────────
phase "5/7  PREFLIGHT GATE"
if [ "$SKIP_DRAIN" = "1" ]; then
  # Only the drain findings are downgraded. Ownership, stream-id schema and
  # Chainlink wiring stay blocking — those have nothing to do with draining.
  export PREFLIGHT_ALLOW_UNRESOLVED=true
  warn "drain findings downgraded to warnings; every other check still blocks"
fi
if npm run --silent "preflight:$ENVNAME" >/tmp/upgrade-preflight-2.log 2>&1; then
  ok "GO"
else
  sed -n '/UPGRADE PREFLIGHT/,$p' /tmp/upgrade-preflight-2.log | grep -E '\[FAIL\]|\[WARN\]' || true
  die "preflight still blocking — see /tmp/upgrade-preflight-2.log"
fi

if [ "$SKIP_DEPLOY" = "1" ]; then
  phase "STOPPING BEFORE DEPLOY (--skip-deploy)"
  info "when ready:  npm run deploy:$ENVNAME"
  exit 0
fi

# ── 6. deploy ───────────────────────────────────────────────────────────────
phase "6/7  DEPLOY"
info "simulating first (no broadcast)"
npm run --silent "simulate:$ENVNAME" >/tmp/upgrade-simulate.log 2>&1 \
  && ok "simulation clean" \
  || { tail -30 /tmp/upgrade-simulate.log; die "simulation failed — nothing was broadcast"; }

printf '\n'
warn "next step broadcasts: deploys Resolver + AutoCycler and repoints Settlement"
confirm "run deploy:$ENVNAME?"
npm run "deploy:$ENVNAME"

# ── 7. verify ───────────────────────────────────────────────────────────────
phase "7/7  VERIFY"
NEW_RESOLVER=$(call "$SETT" "resolver()(address)")
NEW_CYCLER=$(call "$SETT" "autocycler()(address)")
[ "$(lc "$NEW_RESOLVER")" != "$(lc "$RESOLVER")" ] && ok "Settlement repointed: resolver $NEW_RESOLVER" || die "resolver pointer unchanged"
[ "$(lc "$NEW_CYCLER")" != "$(lc "$CYCLER")" ] && ok "Settlement repointed: cycler   $NEW_CYCLER" || die "cycler pointer unchanged"

for v in BTC ETH; do
  PID=$(cast keccak "$v/USD")
  CONF=$(call "$NEW_RESOLVER" "streamsFeedId(bytes32)(bytes32)" "$PID")
  [ "$CONF" = "0x0000000000000000000000000000000000000000000000000000000000000000" ] \
    && die "$v/USD has no stream id on the new resolver — it would open markets it can never settle" \
    || ok "$v/USD stream id $CONF"
done

ok "cycling pairs: $(call "$NEW_CYCLER" "cyclingPairCount()(uint256)")"

if [ "$SKIP_DRAIN" = "1" ] && [ -s "$ORPHAN_FILE" ]; then
  phase "ORPHANED MARKETS — RECOVERY"
  echo "  These were open when Settlement was repointed, so neither resolver can"
  echo "  settle them. Re-adopt any you care about on the new resolver — the call"
  echo "  validates against Settlement's own record, so it cannot invent a market:"
  echo ""
  while read -r MID PAIR STRIKE T; do
    printf '    # market %s  notional %s\n' "$MID" "$T"
    printf '    cast send %s \\\n      "registerMarket(uint256,address,bytes32,int256)" \\\n      %s %s %s %s \\\n      --rpc-url "$ARBITRUM_RPC_URL" --private-key "$DEPLOYER_PRIVATE_KEY"\n\n' \
      "$NEW_RESOLVER" "$MID" "$SETT" "$PAIR" "$STRIKE"
  done <"$ORPHAN_FILE"
  echo "  Then resolve each with a report observed at its endTime. Streams reports"
  echo "  stay verifiable ~30 days, so this is not urgent, but it is manual."
  echo "  Full list: $ORPHAN_FILE"
fi

phase "DONE — REMAINING WORK IS OFF-CHAIN"
cat <<EOF
  The chain side is complete. Until the following are done, no markets are
  created or settled:

    1. Point the backend at the new addresses:
         resolver  $NEW_RESOLVER
         cycler    $NEW_CYCLER
    2. Point the keeper / cron at the new cycler — nothing on-chain does this,
       and market creation stays silent if it is missed.
    3. Confirm the report producer emits the schema each configured stream id
       advertises (0x0002 = 7-word v2, 0x0003 = 9-word v3). A mismatch reverts
       every captureStrike with UnexpectedReportLength.

  Then watch for StrikeCaptured followed by MarketResolved on
  $NEW_RESOLVER, and confirm no ResolveFailed.

  Retire the old cycler once the new one is producing:
    cast send $CYCLER "deprecate(address)" $NEW_CYCLER \\
      --rpc-url "\$ARBITRUM_RPC_URL" --private-key "\$DEPLOYER_PRIVATE_KEY"

  Rollback, if needed — Settlement kept every position and balance:
    cast send $SETT "setResolver(address)"   $RESOLVER ...
    cast send $SETT "setAutocycler(address)" $CYCLER ...
EOF
