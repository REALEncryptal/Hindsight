---
sidebar_position: 6
---

# Standalone rollback

The rollback half of Hindsight is exposed independently. You can use it to build:

- Hit-scan weapons (no projectile body, instant ray test).
- Melee or AoE checks ("who's inside my swing arc at the timestamp of this attack?").
- Ability-validation gates ("was this character actually within line-of-sight 80 ms ago?").

All of these go through the same [`Rollback`](/api/Rollback) object hanging off your World:

```lua
local rollback = world.rollback
```

## Capturing poses

Hindsight does not poll the workspace. You either let an auto-capture helper do it, or you push poses yourself.

### Auto-capture (recommended)

```lua
-- every player's .Character, every server tick
local stop = rollback:autoCapturePlayers()

-- or: every Model under workspace.Characters
local stop = rollback:autoCaptureCharacters(workspace.Characters)

-- or: one specific Model
local stop = rollback:autoCaptureCharacter(npc)

stop() -- when you want to disconnect
```

Helpers compose. Calling [`autoCapturePlayers`](/api/Rollback#autoCapturePlayers) and [`autoCaptureCharacters`](/api/Rollback#autoCaptureCharacters) at the same time merges both sources into one snapshot per tick. They are server-only — invoking from a LocalScript asserts.

### Manual capture

If your characters live somewhere unusual, or you want to capture at a different cadence, build the pose table yourself:

```lua
local RunService = game:GetService("RunService")

RunService.PostSimulation:Connect(function()
    local poses: Hindsight.CharacterPoses = {}
    for _, character in workspace.MyContainer:GetChildren() do
        if not character:IsA("Model") then continue end
        local rig = Hindsight.Defaults.rigs.R15
        local parts: { CFrame } = {}
        for index, name in rig.parts do
            parts[index] = character[name].CFrame
        end
        poses[character] = {
            rig          = "R15",
            rootPosition = character.HumanoidRootPart.Position,
            parts        = parts,
            player       = game.Players:GetPlayerFromCharacter(character),
        }
    end
    rollback:capture(workspace:GetServerTimeNow(), poses)
end)
```

The shape is fixed: see [`CharacterPose`](/api/Hindsight#CharacterPose). Any character whose `parts` length doesn't match the configured rig is silently dropped at push time.

## Querying

### Ray against the snapshot

```lua
local hit: Hindsight.RollbackHit? = rollback:queryRay(
    timestamp,         -- server time the shot was fired
    origin,            -- Vector3
    direction.Unit,    -- normalized Vector3
    500                -- length in studs
)

if hit then
    print(hit.player, hit.character, hit.part, hit.position, hit.distance)
end
```

Optional filter — same shape as the projectile [`Filter`](/api/Hindsight#Filter):

```lua
local hit = rollback:queryRay(
    timestamp, origin, direction.Unit, 500,
    function(caster, victim, character, extra)
        if character == caster then return true end
        return false
    end,
    player,                      -- caster
    { weapon = "shotgun" }       -- extra
)
```

Passing a `filter` requires passing a `caster`. The function runs **on the main thread** here (no parallel-context restrictions) but the signature is identical to the projectile filter so the same function works in both places.

### One character's pose at a past time

```lua
local pose: { [string]: CFrame }? = rollback:characterPoseAt(timestamp, character)
if pose then
    print(pose.Head, pose.UpperTorso)
end
```

Returns `nil` if the snapshot store doesn't cover that timestamp for that character. Useful for debug rendering (the example fires a `DebugRewind` remote that visualizes where each character was at the rewound time vs. where they are right now).

## When does rollback not return a hit?

- The timestamp is older than [`RollbackConfig.lifetime`](/api/Hindsight#RollbackConfig) (default 1 second).
- The timestamp is newer than the most recent snapshot (no extrapolation).
- The character moved outside the configured `gridCenter` / `gridSize` voxel space.
- The character's `parts` count didn't match the configured rig — it was dropped on push.
- The filter returned `true` for every candidate.
- The ray simply missed every OBB.

## Clearing

`rollback:clear()` drops every snapshot. Use it on round transitions if your game's "now" and "earlier" should not bracket the boundary.
