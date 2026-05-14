---
sidebar_position: 1
---

# Introduction

Hindsight is a hit-detection and lag-compensated rollback library for Roblox gun systems.

It exposes two primitives:

1. **Projectile simulation** — a server-authoritative, parallelized projectile engine with penetration, ricochet, and snapshot-based hit detection.
2. **Standalone rollback** — the snapshot system on its own. Query a ray, retrieve a character's interpolated pose, or build hit-scan / melee / ability checks on top of it without touching the projectile path.

Hindsight does **not** look anything up on its own. It does not auto-create folders, does not scan the workspace for characters, does not load projectile definitions from a folder. Every input is passed in.

## Install

```toml
# wally.toml
[dependencies]
Hindsight = "realencryptal/hindsight@^0.1"
```

## Quick start

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local Hindsight = require(ReplicatedStorage.Hindsight)

local world = Hindsight.createWorld({
    actorContainer    = ServerScriptService,
    definitionsModule = ReplicatedStorage.Shared.Definitions,
    visualsContainer  = workspace.Bullets,
})

world.rollback:autoCapturePlayers()

world:cast({
    caster    = player,
    type      = "Bullet",
    origin    = origin,
    direction = direction,
    timestamp = workspace:GetServerTimeNow(),
})
```

A complete server + client setup lives in [`example/`](https://github.com/realencryptal/hindsight/tree/main/example).

## Where to go next

- [Getting started](./getting-started) — end-to-end setup in under five minutes.
- [Concepts](./concepts) — how the snapshot model, actor pool, and definitions fit together.
- [Wiring](./wiring) — what server and client scripts need to do.
- [Defining projectiles](./defining-projectiles) — the definitions module.
- [Standalone rollback](./rollback) — using the snapshot store without projectiles.
- [Configuration](./configuration) — every knob on [`WorldConfig`](/api/Hindsight#WorldConfig).
