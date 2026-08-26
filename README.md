# Launchpad contracts

Bonding-curve launchpad for Ethereum Sepolia. Anyone deploys an ERC-20 in one
transaction, it trades against a virtual-reserve constant-product curve, and at
a fixed supply threshold it graduates into a Uniswap V2 pool with the LP burned.

> **Not yet compiled.** These were written in an environment with no access to
> package registries, so `forge build` has never run against them. Treat the
> first `forge build` as part of the work. See *Getting it running* below.

## Contracts

| File | Role |
| --- | --- |
| `src/libs/CurveMath.sol` | Pure library. The four formulas, the rounding policy, nothing else. |
| `src/LaunchToken.sol` | Fixed-supply ERC-20, clone-initialisable, transfer-gated until graduation. |
| `src/TokenFactory.sol` | EIP-1167 clone deploy, registry, create fee, optional atomic creator buy. |
| `src/BondingCurve.sol` | Singleton holding per-token state and all ETH. Buy, sell, quotes, graduation. |
| `src/libs/Clones.sol` | Vendored EIP-1167. |
| `src/libs/Auth.sol` | Minimal `ReentrancyGuard` + `Ownable2Step`. |

Zero external dependencies beyond `forge-std`. Nothing to audit that you did not
write.

## The math

Constant product with a **virtual ETH reserve** — Uniswap's `x·y=k` with an
imaginary starting ETH balance. No fixed-point exponentials, no power series, no
precision drift.

```
buy:   tokensOut = (dE · vTok) / (vEth + dE)          dE net of fee
sell:  ethOut    = (dT · vEth) / (vTok + dT)
price  = vEth / vTok
clamp: dE_exact  = (R · vEth) / (vTok - R)            ceil, for the final buy
```

Only ETH is virtual. `vTok` always equals the tokens the curve physically holds,
which makes the escrow invariant trivially checkable.

### Constants and what follows from them

| | Value |
| --- | --- |
| `TOTAL_SUPPLY` | 1,000,000,000e18 |
| `SALE_SUPPLY` | 800,000,000e18 |
| `LP_RESERVE` | 200,000,000e18 |
| `virtualEthStart` | 0.125 ETH |
| Total raise | **0.5 ETH** — exactly `4 × virtualEthStart` |
| Opening price | 1.25e−10 ETH/token |
| Graduation price | 3.125e−9 ETH/token — **25×**, exactly `(vTok₀/vTok_end)²` |
| Market cap at graduation | 3.125 ETH |

Because `vTok` ends at `vTok₀/5`, the raise is always `4 × virtualEthStart`. Pick
your target raise `T`, set `virtualEthStart = T/4`, and nothing else needs tuning.
0.5 ETH is chosen to fit Sepolia faucet limits.

## Three decisions worth knowing about

**Graduation triggers on supply, not on an ETH threshold.** An ETH threshold has
to sit below the total raise, stranding unsold tokens on a dead curve. The final
buy is clamped with `ethInForExactTokens` and the surplus refunded in the same
transaction, so the sale stops precisely on `LP_RESERVE`.

**The pool is seeded at the curve's closing price, not with the leftover
tokens.** Dumping the full `LP_RESERVE` into Uniswap opens the pool ~28% below
the curve's last fill — a free arb against your own buyers. Instead
`tokensForLp = ethForLp × vTok / vEth`, and everything left over is burned.

**The pair is created at launch, not at graduation.** Otherwise an attacker
creates it first, donates a lopsided balance, and your `addLiquidity` lands at
their price. Any donation into the still-virgin pair is skimmed to the treasury
before liquidity is added.

## Safety properties

- **No withdraw path for user ETH.** `sell` and `_graduate` are the only
  functions that release reserve ETH, and both are driven entirely by the curve
  formula. `claimFees` can only move `protocolFees` and can only send to the
  **immutable** `treasury` — a compromised owner key cannot redirect it.
- **All truncation favours the reserve.** `k` is non-decreasing across every
  operation; asserted directly in the invariant suite.
- **Buys pause, sells never do.** A switch that can trap holders is not a
  circuit breaker, it is a rug.
- **Fee ceilings are constants.** 2% trade, 10% graduation. The owner tunes
  within them and cannot exceed them.
- **LP is burned to `0x…dEaD`.** Nobody, owner included, can pull the liquidity.
- **Graduation cannot trap anyone.** It runs in a `try/catch` self-call inside
  the final buy. If the router reverts, the catch rolls the token *back to
  `BONDING`* rather than leaving it in `GRADUATING` — which blocks sells as well
  as buys and would otherwise freeze the whole raise behind a deterministic
  router failure. Holders can still exit, and anyone may retry `graduate(token)`.
  If somebody managed to seed the pair first, liquidity is added at the existing
  ratio rather than reverting forever.
- **The transfer gate keys on the curve being the *initiator*, not the
  counterparty.** Allowing `to == curve` would let anyone push tokens straight
  into the curve outside `sell`, desyncing `vTok` from the escrowed balance and
  stranding them with no recovery path.
- **Stray ETH is recoverable.** `receive()` credits anything it takes to
  `protocolFees`, so a donation can never inflate a token's reserve and can never
  become permanently unclaimable.

## Getting it running

```bash
forge install foundry-rs/forge-std --no-commit   # the only dependency
cp .env.example .env                             # then fill it in
forge build
forge test -vvv
```

There is a `Makefile` wrapping the common targets (`make test`, `make fuzz`,
`make invariant`, `make fork`, `make deploy`, `make abi`).

Expect the first build to surface small things — a missing import, a mutability
warning, a stack-too-deep in `_graduate` (if so, flip `via_ir = true` in
`foundry.toml`). The logic and the arithmetic are the parts worth reviewing
closely; the compiler will handle the rest.

```bash
forge test --match-path "test/unit/*"  -vvv
forge test --match-path "test/invariant/*"
FOUNDRY_PROFILE=ci forge test          # 50k fuzz runs, 1024 invariant runs
forge coverage --report summary
forge snapshot                         # gas

# against real Uniswap on Sepolia
forge test --fork-url $SEPOLIA_RPC_URL --match-path "test/fork/*" -vvv
```

## Deploy

```bash
forge script script/Deploy.s.sol:Deploy \
  --rpc-url $SEPOLIA_RPC_URL --broadcast --verify \
  --etherscan-api-key $ETHERSCAN_API_KEY -vvvv
```

**Record the `DEPLOY_BLOCK` it prints.** It becomes the indexer's starting block;
without it you backfill the whole chain.

Then export the ABIs the Go service consumes:

```bash
forge inspect BondingCurve abi > ../backend/abi/BondingCurve.json
forge inspect TokenFactory abi > ../backend/abi/TokenFactory.json
forge inspect LaunchToken  abi > ../backend/abi/LaunchToken.json
```

## Events the indexer consumes

Watch two addresses: `TokenFactory` and `BondingCurve`.

```solidity
TokenCreated(token, creator, pair, name, symbol, metadataURI, vEth0, vTok0, index)
TokenRegistered(token, creator, pair, vEth0, vTok0)
Trade(token, trader, isBuy, ethAmount, tokenAmount, fee, vEthAfter, vTokAfter, tokensSoldAfter)
GraduationStarted(token)
GraduationFailed(token, reason)
Graduated(token, pair, ethToLp, tokensToLp, tokensBurned, lpBurned)
```

`Trade` carries the **post-trade reserves**. That one decision is what lets the
Go indexer rebuild complete price history from logs alone — no archive node, no
historical `eth_call`, replayable from block zero on a free RPC tier.

### One thing the Go quote endpoint must match

Fees round **up** (`_feeOf` in `BondingCurve.sol`), so the truncation favours the
protocol rather than the trader — the same policy `CurveMath` applies to the
reserve. A `math/big` mirror that uses plain integer division will disagree by
one wei on most trades, and the differential fuzz test will catch it. Port
`_quoteBuy` whole, including the final-buy clamp branch, rather than
reimplementing the formula from the docs.

One `Trade` event with an `isBuy` flag rather than separate `Buy`/`Sell` events:
one topic to filter, one decoder, one insert path, and price history is a single
ordered scan.

## Before you trust it

- [ ] `forge build` clean
- [ ] `forge test` green, including 50k-run fuzzing
- [ ] Invariant suite green at depth 128
- [ ] Fork test graduates against the real Sepolia router
- [ ] Slither and Aderyn run, every finding triaged
- [ ] `forge coverage`: 100% on `CurveMath`, ≥95% on `BondingCurve`
- [ ] `UNISWAP_V2_ROUTER` verified on-chain, not copied from a tutorial

Sepolia money is free, so this is rehearsal for the habits rather than
permission to skip them.

## Known open item

`treasury` is immutable and `claimFees` sends to it with a plain `call`. That is
deliberate — a compromised owner key cannot redirect fees — but it means a
treasury that cannot accept ETH (a contract with a reverting or absent fallback)
bricks fee withdrawal permanently. **Set it to an EOA or a Safe, and send it one
wei before you launch.** If you would rather trade the guarantee for safety,
switch `claimFees` to a pull pattern that leaves `protocolFees` intact on a
failed send.
