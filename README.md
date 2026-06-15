# LZ Governance Relay

Cross-chain governance relay built on LayerZero V2. Lets L1 governance (the Sky pause-proxy) submit governance actions for execution on an L2, with a configurable timelock and a guardian veto on the L2 side.

## Architecture

```
                     ┌────────────────────────┐
   L1 pause-proxy ──▶│  L1GovernanceRelay     │── relayEVM ──▶ GovernanceOAppSender ──┐
                     └────────────────────────┘                                       │
                                                                              LayerZero V2
                                                                                      │
                     ┌────────────────────────┐                                       ▼
                     │  L2GovernanceRelay     │◀── relay() ──── GovernanceOAppReceiver
                     │   queue → delay → exec │
                     │       ▲                │
                     │   bud │ cancel         │
                     └────────────────────────┘
```

## Contracts

### `L1GovernanceRelay`

Sits on L1 and is authed (`wards`) by the pause-proxy. Two ways to dispatch:

- `relayEVM(...)` — convenience wrapper that encodes the destination call as `L2GovernanceRelay.relay(target, targetData)`.
- `relayRaw(...)` — pass an arbitrary `TxParams` payload through the LZ sender, for non-EVM destinations or custom payloads.

Also exposes `reclaim` / `reclaimLzToken` so leftover native/LZ-token balance can be swept back. Forwards `nativeFee` to the LZ Endpoint at send time; does **not** attach any value to the destination call payload.

### `L2GovernanceRelay`

Receives messages from L1 via the configured `l2Oapp` (a `GovernanceOAppReceiver`). On receipt, an action is queued; it can be executed after `delay` seconds and within `gracePeriod` seconds after the `delay` has elapsed. Whitelisted guardians (`bud`) can veto.

Self-administration: `kiss`, `diss`, and `file` are gated by `onlySelf` — they can only be invoked via `delegatecall` through an action that was itself queued, delayed, and executed. There is no other path to mutate `l2Oapp`, `l1GovernanceRelay`, `delay`, `gracePeriod`, or the `bud` set.

#### Action lifecycle

```
relay() ─▶  Queued ─(block.timestamp ≥ executionTime)─▶  Ready ─exec()─▶  Executed
              │                                            │
              └──── cancel(canceledId_ ≥ id) ─────┐        └── (after gracePeriod) ─▶  Expired
                                                  ▼
                                              Canceled
```

`getActionState(id)` resolves state in priority order: `Executed` → `Canceled` → `Expired` → `Ready` → `Queued`. An action that expired but is also captured by a later cancellation reads as `Canceled`.

#### Guardian channel suppression

Beyond `cancel` (which vetoes already-queued actions), guardians can also unstick the LayerZero inbound message channel itself via `skip`, `nilify`, `burn`, and `clear`. These are thin `toll`-gated forwarders to the LZ Endpoint (the same `bud` whitelist as `cancel`). They take only the message-specific arguments (`nonce`, and where relevant `payloadHash` / `guid` + `message`); the inbound channel coordinates `(oapp, srcEid, sender)` are all derived on-chain — `oapp` is this relay's `l2Oapp`, `srcEid` is `l1Eid` (the only source `messageAuth` accepts), and `sender` is `l2Oapp.peers(l1Eid)` (the L1 source OApp). They matter because a LayerZero inbound nonce must be verified before any later nonce can execute, so a single unverifiable message — a send/receive DVN-set mismatch, a withheld attestation, an otherwise unverifiable payload — stalls the whole queue. When remote governance cannot deliver a fix (because the fix would itself have to flow through the stalled channel), a guardian can clear the blockage.

The Endpoint is read live from `l2Oapp.endpoint()` on each call, so it always tracks the currently configured `l2Oapp`. For these calls to succeed, the relay must be configured as the **delegate** of `l2Oapp` on the Endpoint. Note that `sender` resolves to the *current* peer: if the `l2Oapp` peer for `l1Eid` is re-set, a message sent under the previous peer can no longer be cleared this way.

#### Configuration parameters

| Parameter | Set by | Purpose |
|-----------|--------|---------|
| `delay` | constructor; `file("delay", …)` | Time between queueing and `Ready`. Snapshotted into each action's `executionTime` at queue time, so changing `delay` only affects actions queued from then on. |
| `gracePeriod` | constructor; `file("gracePeriod", …)` | Window after `Ready` during which `exec` is callable; must be ≥ `MINIMUM_GRACE_PERIOD` (10 minutes). Unlike `delay`, `gracePeriod` is read live by `getActionState`, so a `file("gracePeriod", …)` change retroactively shifts the expiry of every action already in the queue. |
| `bud[usr]` | constructor `bud_`; `kiss(usr)` / `diss(usr)` | Guardian whitelist; an initial set may be seeded at deploy time, otherwise set/unset only via self-call. |
| `l2Oapp` | `file("l2Oapp", …)` | Trusted LZ receiver address whose `messageOrigin` is checked on every `relay()`. |
| `l1GovernanceRelay` | `file("l1GovernanceRelay", …)` | Expected source-sender on the L1 endpoint. |

## Design rationale: cancellation

`cancel(canceledId_)` advances a single monotonic checkpoint that vetoes **every** unexecuted action with `id ≤ canceledId_`. Two consequences worth understanding:

- A single `bud` can mass-cancel the entire in-flight queue in one transaction and provoke permanent DoS to the gov relay. This is a trust assumption that the guardian will not misbehave.
- `cancel` works on `Ready` actions too, not only `Queued` ones.

The channel-suppression functions (`skip` / `nilify` / `burn` / `clear`) extend the same trust model: a guardian who can stop the channel can also be a DoS vector. This does not broaden the existing assumption — a `bud` already holds an effective freeze via mass-`cancel` — it just lets the guardian intervene one layer lower, at the LZ Endpoint, where `cancel` cannot reach.

## For spell authors

Spells are run as `delegatecall` from `exec`. Two consequences:

1. **`msg.sender` inside the spell is the address that called `exec`** — which is permissionless. Any caller can trigger execution once the timelock elapses. Do **not** write spells that read `msg.sender` for trust decisions.
2. Spells must always be stateless to prevent corruption of the `L2GovernanceRelay` storage. This is a trust assumption.

## For governance operators

- **Pick `delay` carefully.** Setting it too high will brick execution, as a recovery message itself has to flow through the same broken `relay()`. There is currently no enforced upper bound on `delay`; treat it as a one-shot footgun.
- **Seed the guardian set at deploy time.** The constructor accepts `bud_` so the relay can launch with a working veto from block one. Without it, there is no `bud` who can veto a malicious action until a `kiss(usr)` spell has flowed through the timelock — a window worth avoiding.
- **`actionId` reflects L2 receipt order, not L1 dispatch order.** LayerZero V2 does not enforce strict ordering by default. If L1 dispatches A, B, C, they may land on L2 as ids 1=B, 2=A, 3=C. When choosing what to cancel, work from the on-chain queue, not from the L1 dispatch sequence. Correlate via the inbound LZ `guid` if needed.

## Build

```bash
cd lib/sky-oapp-oft && pnpm install && cd ../..
forge build
```

## Test

```bash
ETH_RPC_URL={URL} forge test
```
