--!strict

--> Debug visualization layer for the example. Renders Hindsight's broadphase
--> AABB, narrowphase OBBs, the local voxel cell, and the predicted bullet path
--> using ImGizmo. Gated by the `GizmosEnabled` workspace attribute (default
--> off). Toggle with V; clear pending paths with C.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Gizmo = require(ReplicatedStorage:WaitForChild("DevPackages"):WaitForChild("ImGizmo"))
local Hindsight = require(ReplicatedStorage:WaitForChild("Hindsight"))
local Definitions = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Definitions"))

local LocalPlayer = Players.LocalPlayer
local CharactersFolder = workspace:WaitForChild("Characters")
local BulletsFolder = workspace:WaitForChild("Bullets")
local EventsFolder = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Events")
local SimulateEvent = EventsFolder:WaitForChild("Simulate") :: RemoteEvent
local DebugRewind = EventsFolder:WaitForChild("DebugRewind") :: RemoteEvent

local ATTRIBUTE = "GizmosEnabled"
local TOGGLE_KEY = Enum.KeyCode.V
local CLEAR_KEY = Enum.KeyCode.C
local SELF_KEY = Enum.KeyCode.H

local showSelf = true
local selfStateLabel: TextLabel? = nil
local rewindOffsetLabel: TextLabel? = nil
local rewindFrameLabel: TextLabel? = nil

local COLOR_OBB = Color3.fromRGB(255, 80, 80)
local COLOR_AABB = Color3.fromRGB(255, 215, 0)
local COLOR_VOXEL = Color3.fromRGB(80, 255, 200)
local COLOR_LABEL = Color3.fromRGB(220, 220, 220)
local COLOR_REWIND = Color3.fromRGB(0, 220, 255) --> cyan: server's rewound hitbox (lag-comp target)
local COLOR_LIVE_SERVER = Color3.fromRGB(255, 60, 220) --> magenta: server's live pose (no-rollback target)
local COLOR_HIT = Color3.fromRGB(255, 60, 60)
local COLOR_INSIDE = Color3.fromRGB(255, 165, 0)
local COLOR_EXIT = Color3.fromRGB(80, 255, 100)
local COLOR_AIR = Color3.fromRGB(255, 255, 255)
local COLOR_DATA = Color3.fromRGB(255, 235, 150)
local COLOR_BLOCKED = Color3.fromRGB(255, 110, 110)
local COLOR_INDEX = Color3.fromRGB(140, 220, 255)
local COLOR_NORMAL = Color3.fromRGB(190, 140, 255)
local COLOR_ZONE = Color3.fromRGB(180, 180, 180)

local MAX_PENETRATIONS = 10
local SCAN_DISTANCE = 1000

local HIT_RADIUS = 0.15
local EXIT_RADIUS = 0.15
local NORMAL_LENGTH = 1.5
local NORMAL_RADIUS = 0.05
local NORMAL_TIP = 0.3
local NORMAL_SUBDIVISIONS = 6

local TEXT_SIZE_INDEX = 24
local TEXT_SIZE_DATA = 14
local TEXT_SIZE_ZONE = 12
local LABEL_BASE_Y = 0.9
local LABEL_LINE_HEIGHT = 0.55
local AIR_LABEL_OFFSET = Vector3.new(0, 0.4, 0)

local PENETRATION_CONFIG = Hindsight.Defaults.penetration
local ROLLBACK_CONFIG = Hindsight.Defaults.rollback
local RIGS = Hindsight.Defaults.rigs
local VOXEL_SIZE = ROLLBACK_CONFIG.voxelSize
local VOXEL_GRID_CORNER = ROLLBACK_CONFIG.gridCenter - ROLLBACK_CONFIG.gridSize / 2
local HITBOX_SIZE = ROLLBACK_CONFIG.hitboxSize

type Segment = {
	HitPosition: Vector3,
	HitNormal: Vector3,
	ExitPosition: Vector3?,
	Material: Enum.Material,
	SurfaceName: string,
	Penetrated: boolean,
	Terminal: boolean,
	Hardness: number?,
	Depth: number?,
	PowerBefore: number?,
	PowerRequired: number?,
	PowerAfter: number?,
}

type LabelLine = { Text: string, Color: Color3, Size: number }

--> Debug poses received from the server per shot. Each entry carries two
--> per-part CFrame maps: `rewound` (what hit detection tested = lag-comp
--> target) and `current` (live server pose = where hit detection would have
--> tested with no rollback). Persists until the next shot replaces it.
type RewindEntry = {
	character: Model,
	rewound: { [string]: CFrame }?,
	current: { [string]: CFrame }?,
}

type RewindMetadata = {
	rewindOffsetMs: number,
	rewindTime: number,
	serverTime: number,
}

type RewindBatch = {
	time: number,
	meta: RewindMetadata?,
	entries: { RewindEntry },
}

local Visuals = {}
local pendingPaths: { { Segment } } = {}
local pendingRewinds: { RewindBatch } = {}

local legendGui: ScreenGui? = nil

local function isEnabled(): boolean
	return workspace:GetAttribute(ATTRIBUTE) == true
end

local function setEnabled(value: boolean)
	workspace:SetAttribute(ATTRIBUTE, value)
end

local function applyEnabled()
	local enabled = isEnabled()
	Gizmo.SetEnabled(enabled)
	if legendGui then
		legendGui.Enabled = enabled
	end
end

local function selfLabelText(): string
	return if showSelf then "H — show self: ON" else "H — show self: OFF"
end

local function buildLegend(): ScreenGui
	local screen = Instance.new("ScreenGui")
	screen.Name = "HindsightLegend"
	screen.IgnoreGuiInset = true
	screen.ResetOnSpawn = false

	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0, 1)
	frame.Position = UDim2.new(0, 12, 1, -12)
	frame.Size = UDim2.new(0, 260, 0, 0)
	frame.AutomaticSize = Enum.AutomaticSize.Y
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 0.5
	frame.BorderSizePixel = 0
	frame.Parent = screen

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = frame

	local padding = Instance.new("UIPadding")
	padding.PaddingTop = UDim.new(0, 8)
	padding.PaddingBottom = UDim.new(0, 8)
	padding.PaddingLeft = UDim.new(0, 10)
	padding.PaddingRight = UDim.new(0, 10)
	padding.Parent = frame

	local list = Instance.new("UIListLayout")
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Padding = UDim.new(0, 4)
	list.Parent = frame

	local function header(order: number, label: string)
		local text = Instance.new("TextLabel")
		text.LayoutOrder = order
		text.BackgroundTransparency = 1
		text.Size = UDim2.new(1, 0, 0, 16)
		text.Text = label
		text.Font = Enum.Font.GothamBold
		text.TextColor3 = Color3.fromRGB(200, 200, 200)
		text.TextSize = 11
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.Parent = frame
	end

	local function divider(order: number)
		local line = Instance.new("Frame")
		line.LayoutOrder = order
		line.BackgroundColor3 = Color3.fromRGB(120, 120, 120)
		line.BackgroundTransparency = 0.5
		line.BorderSizePixel = 0
		line.Size = UDim2.new(1, 0, 0, 1)
		line.Parent = frame
	end

	local function keybind(order: number, label: string): TextLabel
		local text = Instance.new("TextLabel")
		text.LayoutOrder = order
		text.BackgroundTransparency = 1
		text.Size = UDim2.new(1, 0, 0, 16)
		text.Text = label
		text.Font = Enum.Font.Gotham
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextSize = 13
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.Parent = frame
		return text
	end

	local function swatchRow(order: number, color: Color3, label: string)
		local item = Instance.new("Frame")
		item.LayoutOrder = order
		item.BackgroundTransparency = 1
		item.Size = UDim2.new(1, 0, 0, 16)
		item.Parent = frame

		local swatch = Instance.new("Frame")
		swatch.AnchorPoint = Vector2.new(0, 0.5)
		swatch.Position = UDim2.new(0, 0, 0.5, 0)
		swatch.Size = UDim2.new(0, 14, 0, 14)
		swatch.BackgroundColor3 = color
		swatch.BorderSizePixel = 0
		swatch.Parent = item

		local swatchCorner = Instance.new("UICorner")
		swatchCorner.CornerRadius = UDim.new(0, 3)
		swatchCorner.Parent = swatch

		local text = Instance.new("TextLabel")
		text.AnchorPoint = Vector2.new(0, 0.5)
		text.Position = UDim2.new(0, 22, 0.5, 0)
		text.Size = UDim2.new(1, -22, 1, 0)
		text.BackgroundTransparency = 1
		text.Text = label
		text.Font = Enum.Font.GothamMedium
		text.TextColor3 = Color3.new(1, 1, 1)
		text.TextSize = 13
		text.TextXAlignment = Enum.TextXAlignment.Left
		text.Parent = item
	end

	header(1, "HINDSIGHT — DEBUG")
	divider(2)
	keybind(3, "V — toggle gizmos")
	keybind(4, "C — clear paths")
	selfStateLabel = keybind(5, selfLabelText())
	divider(6)
	swatchRow(7, COLOR_OBB, "Client live — narrowphase OBBs")
	swatchRow(8, COLOR_AABB, "Client live — broadphase AABB")
	swatchRow(9, COLOR_LIVE_SERVER, "Server live — no-rollback target")
	swatchRow(10, COLOR_REWIND, "Server rewound — lag-comp target")
	swatchRow(11, COLOR_VOXEL, "Voxel cell")
	divider(12)
	header(13, "LAST SHOT")
	rewindOffsetLabel = keybind(14, "Rewind: —")
	rewindFrameLabel = keybind(15, "Server frame: —")

	return screen
end

local function rigForHumanoid(humanoid: Humanoid)
	if humanoid.RigType == Enum.HumanoidRigType.R15 then
		return RIGS.R15
	end
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return RIGS.R6
	end
	return nil
end

local function drawPoseSet(pose: { [string]: CFrame }?, rig: { parts: { string }, sizes: { Vector3 } })
	if type(pose) ~= "table" then
		return
	end
	for index, partName in rig.parts do
		local cframe = pose[partName]
		if cframe then
			Gizmo.Box:Draw(cframe, rig.sizes[index] * 2, false)
		end
	end
end

--> Renders two per-part OBB sets per shot:
--> - magenta: server's live pose at the shot (what would have been tested without rollback)
--> - cyan:    server's rewound pose (what hit detection actually tested)
--> Compare against the live red OBBs from `drawCharacter` for the full picture
--> of lag compensation. Stays on screen until the next shot replaces it.
local function drawRewinds()
	Gizmo.PushProperty("AlwaysOnTop", false)

	for _, batch in pendingRewinds do
		for _, entry in batch.entries do
			if type(entry) ~= "table" then
				continue
			end
			local character = entry.character
			if typeof(character) ~= "Instance" or not character:IsA("Model") or character.Parent == nil then
				continue
			end
			if not showSelf and character == LocalPlayer.Character then
				continue
			end
			local humanoid = character:FindFirstChildOfClass("Humanoid")
			if not humanoid then
				continue
			end
			local rig = rigForHumanoid(humanoid)
			if not rig then
				continue
			end

			if type(entry.current) == "table" then
				Gizmo.PushProperty("Color3", COLOR_LIVE_SERVER)
				drawPoseSet(entry.current, rig)
			end
			if type(entry.rewound) == "table" then
				Gizmo.PushProperty("Color3", COLOR_REWIND)
				drawPoseSet(entry.rewound, rig)
			end

			--> Floating label above the rewound head: ties the rewind offset
			--> directly to the cyan box visually, no scanning to the legend.
			local meta = batch.meta
			local headCFrame = if type(entry.rewound) == "table" then entry.rewound.Head else nil
			if meta and headCFrame then
				local deltaMs = (meta.serverTime - meta.rewindTime) * 1000
				Gizmo.PushProperty("Color3", COLOR_REWIND)
				Gizmo.PushProperty("AlwaysOnTop", true)
				Gizmo.Text:Draw(
					headCFrame.Position + Vector3.new(0, 1.8, 0),
					string.format("rewind %.0f ms", meta.rewindOffsetMs),
					14
				)
				Gizmo.Text:Draw(
					headCFrame.Position + Vector3.new(0, 1.35, 0),
					string.format("t = %.3f  (%.0f ms behind)", meta.rewindTime, deltaMs),
					12
				)
				Gizmo.PushProperty("AlwaysOnTop", false)
			end
		end
	end
end

local function drawCharacter(character: Model)
	if not showSelf and character == LocalPlayer.Character then
		return
	end
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return
	end

	local rig = rigForHumanoid(humanoid)
	if rig then
		Gizmo.PushProperty("Color3", COLOR_OBB)
		Gizmo.PushProperty("AlwaysOnTop", false)
		for index, name in rig.parts do
			local part = character:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				Gizmo.Box:Draw(part.CFrame, rig.sizes[index] * 2, false)
			end
		end
	end

	local root = character.PrimaryPart or character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	Gizmo.PushProperty("Color3", COLOR_AABB)
	Gizmo.Box:Draw(CFrame.new(root.Position), HITBOX_SIZE * 2, false)

	Gizmo.PushProperty("Color3", COLOR_LABEL)
	Gizmo.PushProperty("AlwaysOnTop", true)
	Gizmo.Text:Draw(root.Position + Vector3.new(0, 4.7, 0), character.Name, 16)
end

local function drawLocalVoxelCell()
	local character = LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end

	local relative = root.Position - VOXEL_GRID_CORNER
	local center = VOXEL_GRID_CORNER
		+ Vector3.new(
			(math.floor(relative.X / VOXEL_SIZE) + 0.5) * VOXEL_SIZE,
			(math.floor(relative.Y / VOXEL_SIZE) + 0.5) * VOXEL_SIZE,
			(math.floor(relative.Z / VOXEL_SIZE) + 0.5) * VOXEL_SIZE
		)

	Gizmo.PushProperty("Color3", COLOR_VOXEL)
	Gizmo.PushProperty("AlwaysOnTop", false)
	Gizmo.Box:Draw(CFrame.new(center), Vector3.new(VOXEL_SIZE, VOXEL_SIZE, VOXEL_SIZE), false)

	Gizmo.PushProperty("AlwaysOnTop", true)
	Gizmo.Text:Draw(center + Vector3.new(0, VOXEL_SIZE / 2 + 0.7, 0), "Voxel Cell", TEXT_SIZE_ZONE)
end

--> HUD intentionally removed — the bottom-left legend now owns all keybind /
--> state display, so the 3D billboard text is dead weight.

local function isCharacter(instance: Instance): boolean
	return instance:IsDescendantOf(CharactersFolder)
end

local function buildExcludeParams(extra: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list: { Instance } = { BulletsFolder }
	for _, instance in extra do
		table.insert(list, instance)
	end
	params.FilterDescendantsInstances = list
	return params
end

--> Mirrors Hindsight's penetration formula: depth × hardness ≤ remaining power.
--> Each surface contact records the entry, surface normal, and (on penetration)
--> the exit position; the running power decreases per merged medium.
local function predictPath(origin: Vector3, direction: Vector3): { Segment }
	local segments: { Segment } = {}
	local excludes: { Instance } = {}
	local currentOrigin = origin
	local currentDirection = direction.Unit
	local power = Definitions.Bullet.power

	for _ = 1, MAX_PENETRATIONS do
		local result = workspace:Raycast(currentOrigin, currentDirection * SCAN_DISTANCE, buildExcludeParams(excludes))
		if not result then
			break
		end

		local hitPosition = result.Position
		local instance = result.Instance

		if instance == workspace.Terrain or isCharacter(instance) then
			table.insert(segments, {
				HitPosition = hitPosition,
				HitNormal = result.Normal,
				Material = result.Material,
				SurfaceName = if instance == workspace.Terrain then "Terrain" else "Character",
				Penetrated = false,
				Terminal = true,
			})
			break
		end

		local include = RaycastParams.new()
		include.FilterType = Enum.RaycastFilterType.Include
		include.FilterDescendantsInstances = { instance }

		local reverseDirection = -currentDirection * instance.Size.Magnitude
		local reverseOrigin = hitPosition - reverseDirection
		local reverseResult = workspace:Raycast(reverseOrigin, reverseDirection, include)
		local exitPosition: Vector3 = if reverseResult then reverseResult.Position else (reverseOrigin + reverseDirection)

		local depth = (exitPosition - hitPosition).Magnitude
		local hardness = PENETRATION_CONFIG.surfaceHardness[result.Material] or PENETRATION_CONFIG.defaultHardness
		local required = depth * hardness
		local penetrated = power >= required
		local powerBefore = power

		table.insert(segments, {
			HitPosition = hitPosition,
			HitNormal = result.Normal,
			ExitPosition = exitPosition,
			Material = result.Material,
			SurfaceName = instance.Name,
			Penetrated = penetrated,
			Terminal = false,
			Hardness = hardness,
			Depth = depth,
			PowerBefore = powerBefore,
			PowerRequired = required,
			PowerAfter = if penetrated then (powerBefore - required) else powerBefore,
		})

		if not penetrated then
			break
		end
		power -= required
		table.insert(excludes, instance)
		currentOrigin = exitPosition + currentDirection * 0.01
	end

	return segments
end

local function buildSegmentLines(index: number, segment: Segment): { LabelLine }
	local lines: { LabelLine } = {
		{ Text = string.format("#%d", index), Color = COLOR_INDEX, Size = TEXT_SIZE_INDEX },
	}

	if segment.Terminal then
		table.insert(lines, { Text = segment.SurfaceName, Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = "Material: " .. tostring(segment.Material.Name), Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		return lines
	end

	local material = tostring(segment.Material.Name)
	local depth = segment.Depth or 0
	local hardness = segment.Hardness or 0
	local before = segment.PowerBefore or 0
	local required = segment.PowerRequired or 0
	local after = segment.PowerAfter or 0

	if segment.Penetrated then
		table.insert(lines, { Text = "Material: " .. material, Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = string.format("Depth: %.2f", depth), Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = string.format("Hardness: %.0f", hardness), Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = string.format("Power: %.0f -> %.0f", before, after), Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
	else
		table.insert(lines, { Text = "BLOCKED", Color = COLOR_BLOCKED, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = "Material: " .. material, Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = string.format("Depth: %.2f", depth), Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = string.format("Hardness: %.0f", hardness), Color = COLOR_DATA, Size = TEXT_SIZE_DATA })
		table.insert(lines, { Text = string.format("Need %.0f / Have %.0f", required, before), Color = COLOR_BLOCKED, Size = TEXT_SIZE_DATA })
	end

	return lines
end

local function drawLabelStack(basePosition: Vector3, lines: { LabelLine })
	local count = #lines
	for i, line in lines do
		local y = LABEL_BASE_Y + (count - i) * LABEL_LINE_HEIGHT
		Gizmo.PushProperty("Color3", line.Color)
		Gizmo.Text:Draw(basePosition + Vector3.new(0, y, 0), line.Text, line.Size)
	end
end

local function drawPath(segments: { Segment })
	Gizmo.PushProperty("AlwaysOnTop", true)
	local penetrationCount = 0

	for index, segment in segments do
		if index > 1 then
			local previous = segments[index - 1]
			if previous.Penetrated and previous.ExitPosition then
				Gizmo.PushProperty("Color3", COLOR_AIR)
				Gizmo.Ray:Draw(previous.ExitPosition, segment.HitPosition)
				local midpoint = (previous.ExitPosition + segment.HitPosition) / 2
				Gizmo.PushProperty("Color3", COLOR_INDEX)
				Gizmo.Text:Draw(midpoint + AIR_LABEL_OFFSET, tostring(penetrationCount), TEXT_SIZE_DATA)
			end
		end

		Gizmo.PushProperty("Color3", COLOR_HIT)
		Gizmo.Sphere:Draw(CFrame.new(segment.HitPosition), HIT_RADIUS, 12, 360)

		Gizmo.PushProperty("Color3", COLOR_NORMAL)
		Gizmo.Arrow:Draw(
			segment.HitPosition,
			segment.HitPosition + segment.HitNormal * NORMAL_LENGTH,
			NORMAL_RADIUS,
			NORMAL_TIP,
			NORMAL_SUBDIVISIONS
		)

		if segment.Penetrated and segment.ExitPosition then
			penetrationCount += 1
			Gizmo.PushProperty("Color3", COLOR_INSIDE)
			Gizmo.Ray:Draw(segment.HitPosition, segment.ExitPosition)
			Gizmo.PushProperty("Color3", COLOR_EXIT)
			Gizmo.Sphere:Draw(CFrame.new(segment.ExitPosition), EXIT_RADIUS, 12, 360)
		end

		drawLabelStack(segment.HitPosition, buildSegmentLines(index, segment))
	end
end

function Visuals.ShowCast(origin: Vector3, direction: Vector3)
	if not isEnabled() then
		return
	end
	local segments = predictPath(origin, direction)
	if #segments == 0 then
		return
	end
	--> Each shot replaces the previous one. Pair with the DebugRewind reset
	--> below so paths + rewind boxes turn over together.
	table.clear(pendingPaths)
	table.insert(pendingPaths, segments)
end

function Visuals.ClearPaths()
	table.clear(pendingPaths)
end

Gizmo.Init()
if workspace:GetAttribute(ATTRIBUTE) == nil then
	setEnabled(true)
end

legendGui = buildLegend()
legendGui.Parent = LocalPlayer:WaitForChild("PlayerGui")

applyEnabled()

workspace:GetAttributeChangedSignal(ATTRIBUTE):Connect(applyEnabled)

UserInputService.InputBegan:Connect(function(input: InputObject, gpe: boolean)
	if gpe then
		return
	end
	if input.KeyCode == TOGGLE_KEY then
		setEnabled(not isEnabled())
	elseif input.KeyCode == CLEAR_KEY then
		Visuals.ClearPaths()
	elseif input.KeyCode == SELF_KEY then
		showSelf = not showSelf
		if selfStateLabel then
			selfStateLabel.Text = selfLabelText()
		end
	end
end)

RunService.RenderStepped:Connect(function()
	if not isEnabled() then
		return
	end

	for _, child in CharactersFolder:GetChildren() do
		if child:IsA("Model") then
			drawCharacter(child)
		end
	end

	drawLocalVoxelCell()
	drawRewinds()

	for _, segments in pendingPaths do
		drawPath(segments)
	end
end)

DebugRewind.OnClientEvent:Connect(function(meta: RewindMetadata, entries: { any })
	--> Newest shot wins. Previous batch's cyan/magenta boxes drop immediately
	--> instead of layering on top — keeps the visual clean.
	table.clear(pendingRewinds)
	table.insert(pendingRewinds, { time = os.clock(), meta = meta, entries = entries })

	if rewindOffsetLabel then
		rewindOffsetLabel.Text = string.format("Rewind: %.1f ms", meta.rewindOffsetMs)
	end
	if rewindFrameLabel then
		--> Show the absolute server time the rollback resolved to, plus the
		--> delta from server-now so you can see "X ms behind".
		local deltaMs = (meta.serverTime - meta.rewindTime) * 1000
		rewindFrameLabel.Text = string.format("Server frame: t=%.3f (%.1f ms behind)", meta.rewindTime, deltaMs)
	end
end)

SimulateEvent.OnClientEvent:Connect(function(caster: Player, _type: string, origin: Vector3, direction: Vector3)
	if caster ~= LocalPlayer then
		Visuals.ShowCast(origin, direction)
	end
end)

return Visuals
