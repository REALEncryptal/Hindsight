--!strict

--> Client-side wiring. Mirrors the server's world setup; no rollback captures
--> happen here (clients don't push poses).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local Hindsight = require(ReplicatedStorage:WaitForChild("Hindsight"))

local Player = Players.LocalPlayer
local PlayerScripts = Player:WaitForChild("PlayerScripts")
local Mouse = Player:GetMouse()

local SimulateEvent = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Events"):WaitForChild("Simulate") :: RemoteEvent
local CharactersFolder = workspace:WaitForChild("Characters")
local BulletsFolder = workspace:WaitForChild("Bullets")
local definitionsModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Definitions") :: ModuleScript
local bulletVisual = ReplicatedStorage:WaitForChild("Bullet") :: PVInstance

local raycastFilter = RaycastParams.new()
raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
raycastFilter.FilterDescendantsInstances = { CharactersFolder, BulletsFolder }

local world = Hindsight.createWorld({
	actorContainer = PlayerScripts,
	definitionsModule = definitionsModule,
	visualsContainer = BulletsFolder,
	excludeContainers = { BulletsFolder, CharactersFolder },
	defaultRaycastFilter = raycastFilter,
})

local Visuals = require(script:WaitForChild("visuals"))

UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
	if gpe or input.UserInputType ~= Enum.UserInputType.MouseButton1 then
		return
	end

	local character = Player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head or not head:IsA("BasePart") then
		return
	end

	local origin = head.Position
	local direction = (Mouse.Hit.Position - origin).Unit
	local timestamp = workspace:GetServerTimeNow()

	SimulateEvent:FireServer(origin, direction, timestamp)
	world:cast({
		caster = Player,
		type = "Bullet",
		origin = origin,
		direction = direction,
		timestamp = timestamp,
		visual = bulletVisual,
	})
	Visuals.ShowCast(origin, direction)
end)

SimulateEvent.OnClientEvent:Connect(function(caster: Player, type: string, origin: Vector3, direction: Vector3)
	if caster == Player then
		return
	end
	world:cast({
		caster = caster,
		type = type,
		origin = origin,
		direction = direction,
		timestamp = workspace:GetServerTimeNow(),
		visual = bulletVisual,
	})
	Visuals.ShowCast(origin, direction)
end)
