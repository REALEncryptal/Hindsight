--!strict

--> The projectile definitions module. Hindsight requires this to be a single
--> ModuleScript returning a `{ [string]: ProjectileDefinition }` table. Both
--> the main thread and every simulation actor `require` it from their own VM,
--> which is why functions can live here but cannot live in a per-cast
--> Modifier.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Hindsight = require(ReplicatedStorage:WaitForChild("Hindsight"))

--> Reference filter: skip the caster and friendly teammates. Runs in parallel
--> context — read-only and thread-safe.
local function bulletFilter(
	caster: Hindsight.Caster,
	victim: Player?,
	character: Model,
	_extra: Hindsight.Extra
): boolean
	if victim == caster or character == caster then
		return true
	end
	if victim and caster:IsA("Player") and caster.Team ~= nil and caster.Team == victim.Team then
		return true
	end
	return false
end

local function onImpact(_ctx: Hindsight.ImpactCtx)
	--> Decals / sound / etc. go here. Debug rendering lives in the client
	--> visuals layer.
end

local function onIntersection(ctx: Hindsight.IntersectionCtx)
	--> Serial context — Humanoid state is safe to read here, unlike in
	--> `bulletFilter`.
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end
	humanoid:TakeDamage(10)
	print(`Intersected {ctx.player or ctx.character}'s {ctx.part}`)
end

local function onDestroyed(_ctx: Hindsight.DestroyedCtx) end

local Bullet: Hindsight.ProjectileDefinition = {
	velocity = 1000,
	gravity = Vector3.new(0, -196.2, 0),
	lifetime = 5,
	power = 50,
	angle = 20,
	loss = 0,
	collaterals = false,
	filter = bulletFilter,
	onImpact = onImpact,
	onIntersection = onIntersection,
	onDestroyed = onDestroyed,
}

return { Bullet = Bullet }
