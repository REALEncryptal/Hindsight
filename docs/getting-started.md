---
sidebar_position: 2
---

# Getting started

This page takes you from an empty project to a working bullet that does lag-compensated hit detection. If you'd rather read the example source directly, it lives at [`example/`](https://github.com/realencryptal/hindsight/tree/main/example).

## 1. Install

Hindsight is distributed through Wally.

```toml
# wally.toml
[dependencies]
Hindsight = "realencryptal/hindsight@^0.1"
```

```bash
wally install
```

Then sync the resulting `Packages/Hindsight` into `ReplicatedStorage` via your Rojo project file (or whatever sync tool you use).

## 2. Project layout

The minimum scaffolding Hindsight needs to do anything:

```
ReplicatedStorage/
  Hindsight/                 -- synced from Packages
  Shared/
    Definitions              -- ModuleScript (you write this)
    Events/
      Simulate               -- RemoteEvent
ServerScriptService/
  Server                     -- Script that builds the server World
StarterPlayer/
  StarterPlayerScripts/
    Client                   -- LocalScript that builds the client World
workspace/
  Characters                 -- Folder (players + NPCs go here)
  Bullets                    -- Folder (visuals go here)
```

The names `Characters` and `Bullets` are conventions only — Hindsight reads instances, not names. Pass whatever instances you actually have.

## 3. Definitions

Create `ReplicatedStorage/Shared/Definitions.lua`:

```lua
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Hindsight = require(ReplicatedStorage.Hindsight)

local Bullet: Hindsight.ProjectileDefinition = {
    velocity = 100,
    gravity  = Vector3.new(0, -8, 0),
    lifetime = 5,
    power    = 50,
    angle    = 20,
    loss     = 0,

    filter = function(caster, victim, character)
        return character == caster or victim == caster
    end,

    onIntersection = function(ctx)
        local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
        if humanoid and humanoid.Health > 0 then
            humanoid:TakeDamage(10)
        end
    end,
}

return { Bullet = Bullet }
```

This is the smallest definitions module that does damage. See [Defining projectiles](./defining-projectiles) for every field.

## 4. Server

Create `ServerScriptService/Server.server.lua`:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Hindsight = require(ReplicatedStorage.Hindsight)

local Characters = workspace:WaitForChild("Characters")
local Bullets = workspace:WaitForChild("Bullets")
local SimulateEvent = ReplicatedStorage.Shared.Events.Simulate
local definitionsModule = ReplicatedStorage.Shared.Definitions

local raycastFilter = RaycastParams.new()
raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
raycastFilter.FilterDescendantsInstances = { Characters, Bullets }

local world = Hindsight.createWorld({
    actorContainer       = ServerScriptService,
    definitionsModule    = definitionsModule,
    excludeContainers    = { Bullets, Characters },
    defaultRaycastFilter = raycastFilter,
})

world.rollback:autoCaptureCharacters(Characters)

Players.PlayerAdded:Connect(function(player)
    player.CharacterAdded:Connect(function(character)
        RunService.PostSimulation:Wait()
        character.Parent = Characters
    end)
end)

SimulateEvent.OnServerEvent:Connect(function(player, origin, direction, timestamp)
    local rewind = player:GetNetworkPing() + 0.048
    SimulateEvent:FireAllClients(player, "Bullet", origin, direction)
    world:cast({
        caster    = player,
        type      = "Bullet",
        origin    = origin,
        direction = direction,
        timestamp = timestamp - rewind,
    })
end)
```

Three things to notice:

- `autoCaptureCharacters(Characters)` is what makes lag compensation work. Without it, rollback queries return `nil` and `onIntersection` never fires.
- Characters are reparented into `workspace.Characters` so a single auto-capture call covers everyone.
- The server subtracts `playerPing + 0.048` from the client's timestamp. The `0.048` covers Roblox's client-side render interpolation. Without it, shots consistently lead by ~48 ms.

A production setup would also validate `timestamp` and `origin`. See the full version in [Wiring](./wiring).

## 5. Client

Create `StarterPlayer/StarterPlayerScripts/Client.client.lua`:

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Hindsight = require(ReplicatedStorage.Hindsight)

local Player = Players.LocalPlayer
local Mouse = Player:GetMouse()
local PlayerScripts = Player:WaitForChild("PlayerScripts")
local SimulateEvent = ReplicatedStorage.Shared.Events.Simulate
local Characters = workspace:WaitForChild("Characters")
local Bullets = workspace:WaitForChild("Bullets")

local raycastFilter = RaycastParams.new()
raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
raycastFilter.FilterDescendantsInstances = { Characters, Bullets }

local world = Hindsight.createWorld({
    actorContainer       = PlayerScripts,
    definitionsModule    = ReplicatedStorage.Shared.Definitions,
    visualsContainer     = Bullets,
    excludeContainers    = { Bullets, Characters },
    defaultRaycastFilter = raycastFilter,
})

UserInputService.InputBegan:Connect(function(input, gpe)
    if gpe or input.UserInputType ~= Enum.UserInputType.MouseButton1 then return end
    local head = Player.Character and Player.Character:FindFirstChild("Head")
    if not head then return end

    local origin = head.Position
    local direction = (Mouse.Hit.Position - origin).Unit
    local timestamp = workspace:GetServerTimeNow()

    SimulateEvent:FireServer(origin, direction, timestamp)
    world:cast({
        caster    = Player,
        type      = "Bullet",
        origin    = origin,
        direction = direction,
        timestamp = timestamp,
    })
end)

SimulateEvent.OnClientEvent:Connect(function(caster, type, origin, direction)
    if caster == Player then return end
    world:cast({
        caster    = caster,
        type      = type,
        origin    = origin,
        direction = direction,
        timestamp = workspace:GetServerTimeNow(),
    })
end)
```

The client's World is for **visuals only** — no `autoCapture*` calls, no rollback writes. The reason it exists at all is to run projectile motion in parallel context so the main thread stays free.

## 6. Run it

Press F5 in Studio with two play windows. Click on the other player. The dummy or remote player loses 10 HP and the bullet vanishes. The server runs hit detection against the snapshot at the moment you fired, not against the position the dummy is in right now — that's the lag compensation half doing its job.

## Where to go next

- [Concepts](./concepts) — what's actually happening under the hood.
- [Defining projectiles](./defining-projectiles) — every field on `ProjectileDefinition`, plus per-cast modifiers.
- [Standalone rollback](./rollback) — using snapshots for melee, AoE, ability checks (or `world:hitscan` for stock single-ray hit-scans).
- [Configuration](./configuration) — every option on `WorldConfig` / `RollbackConfig` / `PenetrationConfig`.
- [API reference](/api/Hindsight) — generated reference.
