---
sidebar_position: 5
---

# Defining projectiles

Every cast names a `type`. The World resolves that name against the [`definitionsModule`](/api/Hindsight#WorldConfig) — a `ModuleScript` you pass to `createWorld` that returns `{ [string]: ProjectileDefinition }`.

```lua
-- ReplicatedStorage/Shared/Definitions.lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hindsight = require(ReplicatedStorage.Hindsight)

local Bullet: Hindsight.ProjectileDefinition = {
    velocity    = 100,
    gravity     = Vector3.new(0, -8, 0),
    lifetime    = 5,
    power       = 50,
    angle       = 20,
    loss        = 0,
    collaterals = false,

    filter         = function(caster, victim, character, extra)
        if victim == caster or character == caster then return true end
        if victim and caster:IsA("Player") and caster.Team == victim.Team then
            return true
        end
        return false
    end,

    onImpact       = function(ctx) end,
    onIntersection = function(ctx) ctx.character.Humanoid:TakeDamage(10) end,
    onDestroyed    = function(ctx) end,
}

return { Bullet = Bullet }
```

## Field reference

See the [`ProjectileDefinition`](/api/Hindsight#ProjectileDefinition) API page for the exact type.

| Field | Meaning |
| --- | --- |
| `velocity` | Initial speed in studs/second. |
| `gravity` | World-space gravity vector applied every step. |
| `lifetime` | Seconds before the projectile self-destructs. |
| `power` | Penetration budget. Spent against material hardness when crossing surfaces. |
| `angle` | Maximum impact angle (in degrees) that allows a ricochet. `360` always bounces; `0` never does. |
| `loss` | Speed lost per ricochet. |
| `collaterals` | If `true`, continues through players instead of stopping on the first intersection. |
| `raycastFilter` | Optional `RaycastParams` overriding `world.defaultRaycastFilter` for this type. |
| `filter` | **Parallel-context** per-character skip predicate. Read-only — no instance writes, no Humanoid reads. |
| `onImpact` | Called on the main thread when the projectile hits world geometry. |
| `onIntersection` | Called on the main thread when the projectile intersects a captured character. |
| `onDestroyed` | Called on the main thread when the projectile expires or is fully consumed. |

## Why callbacks must live in the definitions module

The simulation runs in an Actor — its own Lua VM. Functions can't cross VM boundaries as data: if you tried to send `filter` inside a `modifier` table to `world:cast`, Roblox would strip it.

Each actor `require`s `definitionsModule` in its own VM. So the function value exists in every VM that needs it without ever being marshalled. This is also why definitions are immutable after `createWorld` — changing the module at runtime won't update the actors.

## Per-cast tweaks: ProjectileModifier

You can override any **numeric / data** field per cast:

```lua
world:cast({
    caster    = player,
    type      = "Bullet",
    origin    = origin,
    direction = direction,
    timestamp = workspace:GetServerTimeNow(),
    modifier  = {
        velocity = 250,            -- this shot is faster
        power    = 100,            -- more penetration
        extra    = { weapon = "rifle", damage = 30 },
    },
})
```

`extra` is an open `{ [string]: any }` table that travels with the projectile. It surfaces on every callback's `ctx.extra`, and your `filter` sees it too — use it for damage tables, weapon ids, or anything else the callback needs to know.

Functions cannot live on `modifier` — they'd be stripped at the actor boundary. Put alternate behaviour on a different `type` instead.

See [`ProjectileModifier`](/api/Hindsight#ProjectileModifier).

## Filter rules in detail

`filter` runs inside the simulation actor in parallel context. The rules:

- **Read-only on Instances.** No `:Destroy()`, no property writes, no `SetAttribute`.
- **No Humanoid reads.** `humanoid.Health`, `humanoid.RootPart`, etc. are not safe in parallel. If you need Humanoid state, do it in `onIntersection`, which runs after `task.synchronize()`.
- **Returning `true` skips the candidate.** The projectile continues past that character. Returning `false` (or `nil`) accepts the hit.
- **The arguments you get:** `caster`, `victim` (the `Player?` if the character is owned by one), `character`, and `extra` (the modifier's table or `{}`).

A common shape:

```lua
filter = function(caster, victim, character, extra)
    -- skip self
    if character == caster or victim == caster then return true end
    -- skip teammates
    if victim and caster:IsA("Player") and caster.Team ~= nil and caster.Team == victim.Team then
        return true
    end
    -- skip on a per-shot whitelist (rocket marker, friendly-fire override, ...)
    if extra.ignore and extra.ignore[character] then return true end
    return false
end
```

## Penetration and ricochet recap

Both behaviours fall out of three numbers on the definition:

- **`power`** is the total penetration budget. When the projectile crosses a medium, it spends `thickness * averageHardness`, where hardness is per-material (see [`PenetrationConfig.surfaceHardness`](/api/Hindsight#PenetrationConfig)). When `power` drops below the cost of the next medium, the projectile dies on the surface.
- **`angle`** sets the maximum impact angle (in degrees, measured between the surface normal and the ray) that allows a ricochet. Glancing hits bounce; head-on hits don't. `angle = 360` always bounces; `angle = 0` never does.
- **`loss`** is how much speed the projectile loses per ricochet.

Ricochet additionally requires the surface to be hard enough — see [`PenetrationConfig.ricochetHardness`](/api/Hindsight#PenetrationConfig). Wood doesn't bounce bullets; concrete does.
