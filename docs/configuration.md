---
sidebar_position: 7
---

# Configuration

This page walks the full surface of [`WorldConfig`](/api/Hindsight#WorldConfig) and explains when to change the defaults. Every field except `actorContainer` and `definitionsModule` is optional.

## WorldConfig

```lua
local world = Hindsight.createWorld({
    actorContainer       = ServerScriptService,        -- required
    definitionsModule    = ReplicatedStorage.Defs,     -- required
    visualsContainer     = workspace.Bullets,
    excludeContainers    = { workspace.Bullets, workspace.Characters },
    threads              = 16,
    serverFrameRate      = 1 / 60,
    frameTimeBudget      = 0.5,
    interpolation        = 0.048,
    defaultRaycastFilter = raycastFilter,
    rollback             = customRollbackConfig,
    penetration          = customPenetrationConfig,
})
```

### `actorContainer: Instance` (required)

Where Hindsight parents the simulation `Actor`s. On the server, `ServerScriptService` is fine. On the client, use `Player.PlayerScripts` (so the actors die with the player).

### `definitionsModule: ModuleScript` (required)

The `ModuleScript` returning `{ [string]: ProjectileDefinition }`. Required because everything except standalone rollback queries goes through it. If you're using only standalone rollback, you can pass any module that returns `{}` — but the real shape is [defined here](./defining-projectiles).

### `visualsContainer: Instance?`

Where bullet visuals get parented on the client. The simulation only clones `options.visual` if `visualsContainer` is set. Leave it `nil` on the server.

### `excludeContainers: { Instance }?`

Containers whose descendants are **not** valid continuation parts for penetration compound walls. This is needed because the penetration overlap probe runs in parallel context, which can't use `OverlapParams` — instead, Hindsight does a bounds query and filters in Lua against this list. Typical contents: the visuals container and the characters container.

### `threads: number?` (default `16`)

How many `Actor`s the World creates. More actors = better parallel throughput, but each actor pays a fixed cost on `Initialize`. 16 is a good baseline. Bump it if you have hundreds of in-flight projectiles.

### `serverFrameRate: number?` (default `1 / 60`)

The time budget per frame each actor expects. Used together with `frameTimeBudget` to decide when to bail out of the per-frame step loop. If you're targeting 30 Hz, set to `1 / 30`.

### `frameTimeBudget: number?` (default `0.5`)

Fraction of `serverFrameRate` an actor will spend stepping projectiles before deferring leftover work to the next tick. Lower this if other server work is starving; raise it (towards `1.0`) if the actor pool has slack.

### `interpolation: number?` (default `0.048`)

Roblox's client-side replication interpolation delay in seconds. Currently this value is captured in the resolved config but consumer-side use is the typical place to apply it (your server wiring subtracts `playerPing + interpolation` from the cast timestamp — see [Wiring](./wiring)).

### `defaultRaycastFilter: RaycastParams?` (default `RaycastParams.new()`)

The `RaycastParams` used by every projectile that doesn't supply its own on the definition. Build it once at world setup with `FilterType = Exclude` and the character/bullet containers in `FilterDescendantsInstances`.

### `rollback: RollbackConfig?`

Defaults to [`Hindsight.Defaults.rollback`](/api/Defaults#rollback). See below.

### `penetration: PenetrationConfig?`

Defaults to [`Hindsight.Defaults.penetration`](/api/Defaults#penetration). See below.

## RollbackConfig

```lua
local rollback: Hindsight.RollbackConfig = {
    lifetime   = 1,
    voxelSize  = 32,
    gridCenter = Vector3.zero,
    gridSize   = Vector3.new(4096, 512, 4096),
    hitboxSize = Vector3.new(3, 3, 3),
    rigs       = Hindsight.Defaults.rigs,
}
```

- **`lifetime`** — how many seconds of snapshots to keep. Higher = tolerates higher player latency but costs more memory and slows queries. 1 s covers ~250 ms ping with margin; raise it only if your peak ping is much higher.
- **`voxelSize`** — broadphase cell size in studs. Smaller voxels mean fewer characters per cell (better query cost) but more cells touched per ray. 32 is fine for most maps.
- **`gridCenter`** / **`gridSize`** — the world-space extent of the voxel space. Characters outside this AABB are not findable via `queryRay`. Center on your map and size generously.
- **`hitboxSize`** — half-extents of the AABB used to expand each character's footprint in the voxel grid. Larger = fewer false negatives from fast movement, more candidates per query. `(3, 3, 3)` covers an R15 with margin.
- **`rigs`** — `{ [string]: Rig }` of hitbox layouts. The default set covers `R15` and `R6`. Add your own if you have non-humanoid creatures.

See [`Defaults.rigs`](/api/Defaults#rigs) for the exact part lists used by the built-in R15/R6 entries. To add a custom rig, mirror that shape:

```lua
local rollback = table.clone(Hindsight.Defaults.rollback)
rollback.rigs = table.clone(rollback.rigs)
rollback.rigs.Dragon = {
    parts = { "Head", "Neck", "Body", "Tail", "LeftWing", "RightWing" },
    sizes = {
        Vector3.new(2, 2, 3) / 2,
        Vector3.new(2, 2, 2) / 2,
        Vector3.new(6, 4, 8) / 2,
        Vector3.new(2, 2, 6) / 2,
        Vector3.new(8, 1, 4) / 2,
        Vector3.new(8, 1, 4) / 2,
    },
}
```

`parts` and `sizes` are parallel arrays — `sizes[i]` is the half-extent OBB used to test the part named `parts[i]`. The character Model is expected to contain a child BasePart per name.

## PenetrationConfig

```lua
local penetration: Hindsight.PenetrationConfig = {
    surfaceHardness        = {
        [Enum.Material.Wood]     = 2,
        [Enum.Material.Concrete] = 10,
    },
    defaultHardness        = 10,
    ricochetHardness       = 10,
    mediumGapThreshold     = 0.1,
    maxCompoundMediumParts = 32,
}
```

- **`surfaceHardness`** — hardness per `Enum.Material`. Cost to cross a medium is `thickness * hardness`. Unlisted materials fall back to `defaultHardness`.
- **`defaultHardness`** — fallback for materials not in `surfaceHardness`.
- **`ricochetHardness`** — minimum hardness for a surface to ricochet at all. Wood (`2`) never bounces bullets under defaults; concrete (`10`) can.
- **`mediumGapThreshold`** — gap size (in studs) below which two parts are merged into one compound medium. Useful for walls built out of stacked sub-parts.
- **`maxCompoundMediumParts`** — upper bound on how many parts can join one compound. Caps worst-case probe cost when a projectile enters a deeply layered structure.
