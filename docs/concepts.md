---
sidebar_position: 3
---

# Concepts

Hindsight is built on four ideas. Reading this page makes everything else easier to navigate.

## 1. The World owns the actor pool

[`Hindsight.createWorld`](/api/Hindsight#createWorld) returns a [`World`](/api/World). Internally the World spins up N `Actor` instances under your `actorContainer`, each running an isolated copy of the simulation in its own Lua VM. Casts dispatch to the least-loaded actor; rollback captures broadcast to all of them.

You can create a World on the server, the client, or both. The example does both — the server runs authoritative hit detection, and each client runs a local World purely to render its own projectiles.

## 2. Definitions live in a ModuleScript, not in code

`definitionsModule` is a `ModuleScript` that returns `{ [string]: ProjectileDefinition }`. Each actor `require`s this module in its own VM, which is how callbacks (`onImpact`, `onIntersection`, `onDestroyed`, `filter`) and `RaycastParams` end up on every actor without crossing the actor boundary as data.

Per-cast tweaks happen through a [`ProjectileModifier`](/api/Hindsight#ProjectileModifier) — a plain table you pass to `world:cast({ modifier = ... })`. Modifiers can only carry numeric / data fields; functions stay in the definition.

See [Defining projectiles](./defining-projectiles).

## 3. Rollback is snapshot-based

Every server tick you push a [`CharacterPoses`](/api/Hindsight#CharacterPoses) map to `world.rollback:capture(time, poses)`. The snapshot store keeps the last `lifetime` seconds of poses in a voxel grid keyed on root position.

When a cast arrives with a `timestamp`, the simulation queries the snapshot store at that timestamp, brackets it between two snapshots, and interpolates each character's pose. The query is a ray test against per-part OBBs after a voxel broadphase + AABB midphase.

You almost never want to build the `CharacterPoses` map yourself. Use the auto-capture helpers:

- [`autoCapturePlayers()`](/api/Rollback#autoCapturePlayers) — every player's `.Character`.
- [`autoCaptureCharacters(folder)`](/api/Rollback#autoCaptureCharacters) — every Model in a folder (players + NPCs in the same place).
- [`autoCaptureCharacter(character)`](/api/Rollback#autoCaptureCharacter) — one specific Model.

Each returns a disconnect function. Calls compose — sources merge into one snapshot per tick.

See [Standalone rollback](./rollback).

## 4. Projectiles run in parallel context

The simulation hot loop runs under `ConnectParallel`. Two consequences:

- **Filters must be thread-safe.** A [`Filter`](/api/Hindsight#Filter) is a function on the definition that decides whether to skip a candidate hit (e.g. "ignore caster, ignore teammates"). It runs in parallel context and cannot read Humanoid state or write to instances. Callbacks (`onImpact`, `onIntersection`, `onDestroyed`) run on the main thread after `task.synchronize()` and can do whatever they want.
- **Callbacks fire positionally across the actor boundary.** Hindsight handles this for you — your `onImpact` receives a typed [`ImpactCtx`](/api/Hindsight#ImpactCtx), not a flat arg list. The wire format is an internal detail.

## How a cast flows end-to-end

```
client:    UserInputService → world:cast(...) → render visual
              │
              └─→ RemoteEvent → server

server:    OnServerEvent → validate → world:cast({ timestamp = t - latency - interp })
              │
              └─→ Dispatcher → least-loaded Actor:SendMessage("Dispatch", options)

actor VM:  spawn projectile state
              │
           PostSimulation (parallel):
              ├─ raycast world geometry
              ├─ rollback:queryRay at projectile.timestamp + elapsed
              ├─ on hit → resolve penetration / ricochet
              └─ task.synchronize() → Output:Fire("onImpact" | "onIntersection" | "onDestroyed", ...)

main thread: Definitions:dispatch reassembles the ctx → user callback fires
```

## Why timestamps matter

`world:cast` takes a `timestamp` — the server time at which the shooter believed they fired. The simulation uses this to:

1. Index the rollback snapshot when the projectile is checked against players.
2. Advance the projectile forward in time as it steps each frame.

On the server, set `timestamp = clientTimestamp - playerPing - interpolation`. On the client (for own-shooter feedback), `timestamp = workspace:GetServerTimeNow()` is enough — there's no rollback path on the client.
