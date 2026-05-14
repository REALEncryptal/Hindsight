--!strict

--> Server-side wiring for the Hindsight example. Builds the authoritative
--> world with default rollback + penetration, lets Hindsight auto-capture
--> player poses every PostSimulation, validates client cast requests, and
--> replicates them.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local Hindsight = require(ReplicatedStorage:WaitForChild("Hindsight"))

local MAXIMUM_LATENCY = 0.8
local INTERPOLATION = 0.048

local CharactersFolder = workspace:WaitForChild("Characters")
local BulletsFolder = workspace:WaitForChild("Bullets")
local EventsFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Events")
local SimulateEvent = EventsFolder:WaitForChild("Simulate") :: RemoteEvent
local definitionsModule = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Definitions") :: ModuleScript

--> Debug rewind feed for client-side visualization. Fires every server cast
--> with two poses per character: the rewound (what hit detection tested) and
--> the current (what hit detection WOULD have tested without rollback).
--> Flip DEBUG_REWIND off in prod.
local DEBUG_REWIND = true
local DebugRewind = Instance.new("RemoteEvent")
DebugRewind.Name = "DebugRewind"
DebugRewind.Parent = EventsFolder

local function rigNameForHumanoid(humanoid: Humanoid): string?
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return "R15"
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return "R6"
	end
	return nil
end

--> Reads the live BasePart CFrames straight off the character. This is the
--> pose hit detection would have used with no lag compensation at all.
local function currentPoseOf(character: Model): { [string]: CFrame }?
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return nil
	end
	local rigName = rigNameForHumanoid(humanoid)
	if not rigName then
		return nil
	end
	local rig = Hindsight.Defaults.rigs[rigName]
	if not rig then
		return nil
	end
	local pose: { [string]: CFrame } = {}
	for _, partName in rig.parts do
		local part = character:FindFirstChild(partName)
		if part and part:IsA("BasePart") then
			pose[partName] = part.CFrame
		end
	end
	return pose
end

local raycastFilter = RaycastParams.new()
raycastFilter.FilterType = Enum.RaycastFilterType.Exclude
raycastFilter.FilterDescendantsInstances = { CharactersFolder, BulletsFolder }

local world = Hindsight.createWorld({
	actorContainer = ServerScriptService,
	definitionsModule = definitionsModule,
	visualsContainer = BulletsFolder,
	excludeContainers = { BulletsFolder, CharactersFolder },
	defaultRaycastFilter = raycastFilter,
})

--> Capture every Model in workspace.Characters — catches both players
--> (reparented below) and NPCs (`spawnDummy` further down).
world.rollback:autoCaptureCharacters(CharactersFolder)

local RESPAWN_DELAY = 3
local DUMMY_HEALTH = 100

--> Spawns an R15 dummy that patrols between two named parts. Drops into
--> workspace.Characters so the auto-capture loop picks it up and the world
--> raycast filter excludes it. Walks fast + jumps at random intervals so the
--> rewind gap is visually obvious. On death, despawns and respawns at pointA
--> after RESPAWN_DELAY seconds.
local function spawnDummy(pointA: BasePart, pointB: BasePart)
	--> Empty HumanoidDescription leaves body Color3 at (0,0,0) — fully black.
	--> Set every body region explicitly so the dummy looks like a default Roblox character.
	local description = Instance.new("HumanoidDescription")
	description.HeadColor = Color3.fromRGB(255, 204, 153)
	description.LeftArmColor = description.HeadColor
	description.RightArmColor = description.HeadColor
	description.TorsoColor = Color3.fromRGB(13, 105, 172)
	description.LeftLegColor = Color3.fromRGB(40, 127, 71)
	description.RightLegColor = description.LeftLegColor

	local dummy = Players:CreateHumanoidModelFromDescription(description, Enum.HumanoidRigType.R15)
	dummy.Name = "Dummy"
	dummy.Parent = CharactersFolder
	dummy:PivotTo(CFrame.new(pointA.Position + Vector3.new(0, 3, 0)))

	local humanoid = dummy:FindFirstChildOfClass("Humanoid") :: Humanoid
	humanoid.WalkSpeed = 32
	humanoid.JumpPower = 50
	humanoid.MaxHealth = DUMMY_HEALTH
	humanoid.Health = DUMMY_HEALTH

	--> Pin the assembly to the server. By default Roblox auto-reassigns network
	--> ownership based on proximity; for an AI-driven NPC that can hand the
	--> physics over to a nearby client, which then runs its own prediction and
	--> drifts from the server's authoritative pose over time. Pinning here means
	--> the client only ever interpolates from received CFrames — no prediction.
	local rootPart = dummy.PrimaryPart or dummy:FindFirstChild("HumanoidRootPart")
	if rootPart and rootPart:IsA("BasePart") then
		rootPart:SetNetworkOwner(nil)
	end

	task.spawn(function()
		local target = pointA
		while dummy.Parent and humanoid.Health > 0 do
			target = if target == pointA then pointB else pointA
			humanoid:MoveTo(target.Position)
			humanoid.MoveToFinished:Wait()
		end
	end)

	task.spawn(function()
		while dummy.Parent and humanoid.Health > 0 do
			task.wait(math.random(40, 180) / 100) --> 0.4–1.8s between jump attempts
			if humanoid.FloorMaterial ~= Enum.Material.Air then
				humanoid.Jump = true
			end
		end
	end)

	humanoid.Died:Once(function()
		task.wait(RESPAWN_DELAY)
		if dummy.Parent then
			dummy:Destroy()
		end
		spawnDummy(pointA, pointB)
	end)
end

local pointA = workspace:WaitForChild("A") :: BasePart
local pointB = workspace:WaitForChild("B") :: BasePart
spawnDummy(pointA, pointB)

Players.PlayerAdded:Connect(function(player)
	player.CharacterAdded:Connect(function(character)
		RunService.PostSimulation:Wait()
		character.Parent = CharactersFolder
	end)

	player.CharacterAppearanceLoaded:Connect(function(character)
		for _, child in character:GetChildren() do
			if child:IsA("Accessory") then
				local handle = child:FindFirstChild("Handle")
				if handle and handle:IsA("BasePart") then
					handle.CanQuery = false
				end
			end
		end
	end)
end)

SimulateEvent.OnServerEvent:Connect(function(player: Player, origin: Vector3, direction: Vector3, timestamp: number)
	local latency = workspace:GetServerTimeNow() - timestamp
	if latency < 0 or latency > MAXIMUM_LATENCY then
		return
	end

	local character = player.Character
	local head = character and character:FindFirstChild("Head") :: BasePart?
	if not head or not head:IsA("BasePart") then
		return
	end
	--> Split the origin check on horizontal vs vertical. Horizontal stays
	--> tight (lateral teleport detection); vertical is loose because jumps,
	--> falls, and platform drops legitimately move the head several studs
	--> between client click and server receive.
	local offset = origin - head.Position
	local horizontal = Vector3.new(offset.X, 0, offset.Z).Magnitude
	local vertical = math.abs(offset.Y)
	if horizontal > 5 or vertical > 20 then
		warn(`{player} is too far from the projectile origin.`)
		return
	end

	local rewindOffset = player:GetNetworkPing() + INTERPOLATION
	local rewindTime = timestamp - rewindOffset
	SimulateEvent:FireAllClients(player, "Bullet", origin, direction)
	world:cast({
		caster = player,
		type = "Bullet",
		origin = origin,
		direction = direction,
		timestamp = rewindTime,
	})

	if DEBUG_REWIND then
		local entries = {}
		for _, character in CharactersFolder:GetChildren() do
			if not character:IsA("Model") then
				continue
			end
			local rewound = world.rollback:characterPoseAt(rewindTime, character)
			local current = currentPoseOf(character)
			if rewound or current then
				table.insert(entries, { character = character, rewound = rewound, current = current })
			end
		end
		if #entries > 0 then
			local meta = {
				rewindOffsetMs = rewindOffset * 1000,
				rewindTime = rewindTime,
				serverTime = workspace:GetServerTimeNow(),
			}
			DebugRewind:FireAllClients(meta, entries)
		end
	end
end)
