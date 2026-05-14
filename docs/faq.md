---
sidebar_position: 8
---

# FAQ

### Does Hindsight handle replication?

No. You decide how a client-initiated cast reaches the server, and how the server tells other clients about a cast. The example uses a single `RemoteEvent`. See [Wiring](./wiring).

### Does Hindsight do damage?

No. Damage happens in your `onIntersection` callback. Hindsight tells you who got hit, where, and with what `extra` payload — you decide how the world reacts.

### Why does my filter break when I read `Humanoid.Health`?

Filters run in parallel context. Humanoid state reads aren't safe in parallel. Move the check to `onIntersection` (which runs on the main thread after `task.synchronize()`), or precompute a "is dead" flag and read it from `extra`.

### Why isn't my hit registering?

Walk this list:

1. Are you capturing poses? `world.rollback:autoCapturePlayers()` or one of the other helpers must be running on the server.
2. Is the cast timestamp within `RollbackConfig.lifetime` of "now"? Default lifetime is 1 second.
3. Is the character inside the configured voxel space (`gridCenter` / `gridSize`)?
4. Does the character's part count match the configured rig? Mismatches are silently dropped on `capture`.
5. Is your raycast filter excluding the character container? The world raycast happens first; if it hits a character collider it'll go through `onImpact`, not `onIntersection`.

### Why does the server use `timestamp - playerPing - interpolation`?

The shooter's client renders other players ~48 ms behind their real authoritative position because of replication interpolation. Without subtracting that delay, every snapshot read on the server happens at "now", and the shooter consistently has to lead.

`playerPing` covers the network round-trip. `interpolation` covers the render delay. Together they put the snapshot read at the moment that, from the shooter's perspective, they pulled the trigger.

### Can I create more than one World?

Yes — one per client (for visuals) and one on the server is the standard pattern. There's nothing stopping you from having multiple Worlds in one peer (e.g. one for player weapons, one for AI projectiles with a different actor budget). They don't share state.

### Do clients need to call `autoCapture*`?

No. The client World is purely for visuals. Rollback writes only happen on the server.

### Why are my callbacks not firing?

Callbacks live on the **definition** — if `onImpact` is `nil`, no callback fires. Verify your definitions module returns a table that points at the right functions, and that `world:cast({ type = "Bullet" })` matches a key in that table.

### How do I stop a projectile mid-flight?

There's no public `:cancel` API. Set `lifetime` shorter or, on the next cast for that caster, use `modifier.lifetime = 0`. If you need fine-grained cancellation, file a feature request — most games are fine letting the existing projectile expire naturally.

### Where can I see a complete working setup?

The [`example/`](https://github.com/realencryptal/hindsight/tree/main/example) folder is a full server + client setup with patrolling dummies and a debug rewind RemoteEvent for visualizing what the server "saw" when it ran hit detection.
