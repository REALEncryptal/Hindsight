---
sidebar_position: 4
---

# Wiring server and client

Hindsight gives you a `World` and lets you decide everything around it. This page is the smallest end-to-end setup that yields a working server-authoritative weapon. The [`example/`](https://github.com/realencryptal/hindsight/tree/main/example) folder is a fleshed-out version of this.

## Project layout

```
ReplicatedStorage/
  Hindsight/                  -- the library
  Shared/
    Definitions               -- ModuleScript: { Bullet = { ... } }
    Events/
      Simulate                -- RemoteEvent
ServerScriptService/
  Server                      -- Script (or your own framework's entry point)
StarterPlayer/
  StarterPlayerScripts/
    Client                    -- LocalScript
workspace/
  Characters                  -- where player + NPC Models live
  Bullets                     -- where bullet visuals are parented
```

`Characters` and `Bullets` are conventions — Hindsight doesn't require those names. You hand the actual instances to `createWorld`.

## Server

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local Hindsight = require(ReplicatedStorage.Hindsight)

local MAX_LATENCY = 0.8
local INTERPOLATION = 0.048

local Characters = workspace.Characters
local Bullets = workspace.Bullets
local SimulateEvent = ReplicatedStorage.Shared.Events.Simulate

local raycastFilter = RaycastParams.new()
raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
raycastFilter.FilterDescendantsInstances = { Characters, Bullets }

local world = Hindsight.createWorld({
    actorContainer    = ServerScriptService,
    definitionsModule = ReplicatedStorage.Shared.Definitions,
    visualsContainer  = Bullets,
    excludeContainers = { Bullets, Characters },
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
    local latency = workspace:GetServerTimeNow() - timestamp
    if latency < 0 or latency > MAX_LATENCY then
        return
    end

    local head = player.Character and player.Character:FindFirstChild("Head")
    if not head or (origin - head.Position).Magnitude > 5 then
        return
    end

    local rewindOffset = player:GetNetworkPing() + INTERPOLATION
    SimulateEvent:FireAllClients(player, "Bullet", origin, direction)
    world:cast({
        caster    = player,
        type      = "Bullet",
        origin    = origin,
        direction = direction,
        timestamp = timestamp - rewindOffset,
    })
end)
```

The two non-obvious bits:

- **Reparenting Characters under `workspace.Characters`** — only so `autoCaptureCharacters` and the raycast filter can target one place. If your game already has a character container, skip the reparenting and point `autoCaptureCharacters` at it.
- **`timestamp - playerPing - INTERPOLATION`** — pulls the snapshot read back by the shooter's render delay. Roblox renders other players ~48 ms behind their real position; without this offset, the shot would consistently lead its target by that amount.

## Client

```lua
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")
local Hindsight = require(ReplicatedStorage.Hindsight)

local Player = Players.LocalPlayer
local PlayerScripts = Player:WaitForChild("PlayerScripts")
local Mouse = Player:GetMouse()

local SimulateEvent = ReplicatedStorage.Shared.Events.Simulate
local Characters = workspace.Characters
local Bullets = workspace.Bullets
local bulletVisual = ReplicatedStorage.Bullet

local raycastFilter = RaycastParams.new()
raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
raycastFilter.FilterDescendantsInstances = { Characters, Bullets }

local world = Hindsight.createWorld({
    actorContainer    = PlayerScripts,
    definitionsModule = ReplicatedStorage.Shared.Definitions,
    visualsContainer  = Bullets,
    excludeContainers = { Bullets, Characters },
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
        visual    = bulletVisual,
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
        visual    = bulletVisual,
    })
end)
```

Clients run a World for **visuals only** — `omit autoCapture*`, no rollback writes happen client-side. The client World still owns its own actor pool because rendering N projectiles in parallel keeps the main thread free for everything else.

## The remote contract

The example uses a single `RemoteEvent` carrying `(origin, direction, timestamp)`. That's enough. The server validates:

- `timestamp` is within `MAX_LATENCY` of `GetServerTimeNow()`.
- `origin` is within ~5 studs of the player's head (or wherever the muzzle should be).
- Anything else your game cares about — ammo, weapon equipped, dead-state.

Then the server fires the same cast on every other client (sans visuals data) so they see the bullet flying.
