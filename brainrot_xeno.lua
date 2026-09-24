-- Steal a Brainrot main place (duel compatibility) / Xeno
-- Paste the whole file into Xeno, or use the public one-line loader.
-- Client movement and prompt calls still depend on the game's server rules.

if game.PlaceId ~= 109983668079237 and game.PlaceId ~= 99606176102979
    and game.GameId ~= 7709344486 then
    warn("[Brainrot Xeno] This script is for Steal a Brainrot / Duel Server only.")
    return
end

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")
local player = Players.LocalPlayer
local plots = workspace:FindFirstChild("Plots")

if not player then
    warn("[Brainrot Xeno] LocalPlayer is unavailable.")
    return
end

local env = _G
if type(getgenv) == "function" then
    local ok, result = pcall(getgenv)
    if ok and type(result) == "table" then env = result end
end

if env.BrainrotXeno and type(env.BrainrotXeno.Unload) == "function" then
    pcall(env.BrainrotXeno.Unload)
end

local state = {
    alive = true,
    auto = false,
    speed = false,
    speedValue = 32,
    carryStartedAt = nil,
    nextDeliveryAt = 0,
    nextCloneArmAt = 0,
    clonePreflightDone = false,
    movementId = 0,
    connections = {},
    attempted = setmetatable({}, { __mode = "k" }),
    gui = nil,
    ui = nil,
    markedBase = nil,
    markedHitbox = nil,
    markedPlot = nil,
    manualPlot = nil,
    diagnostics = { base = "auto", target = "scanning", carry = "idle", delivery = "idle", remote = "unknown" },
}
env.BrainrotXeno = state

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    table.insert(state.connections, connection)
    return connection
end

local function characterParts()
    local character = player.Character
    if not character then return nil end
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local root = character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or humanoid.Health <= 0 then return nil end
    return character, humanoid, root
end

local function setStatus(message)
    if state.ui then
        state.ui.setStatus(message)
        state.ui.setDiagnostics(state.diagnostics)
    end
    print("[Brainrot Xeno] " .. message)
end

local synchronizer
local function getSynchronizer()
    if synchronizer then return synchronizer end
    local packages = ReplicatedStorage:FindFirstChild("Packages")
    local module = packages and packages:FindFirstChild("Synchronizer")
    if not module then return nil end
    local ok, value = pcall(require, module)
    if ok and type(value) == "table" then synchronizer = value end
    return synchronizer
end

local function plotChannel(plot)
    local sync = getSynchronizer()
    if not sync or not plot then return nil end
    local ok, channel = pcall(function() return sync:Get(plot.Name) end)
    return ok and channel or nil
end

local function ownsPlot(plot)
    local channel = plotChannel(plot)
    if channel then
        local ok, owner = pcall(function() return channel:Get("Owner") end)
        if ok and owner ~= nil then
            if typeof(owner) == "Instance" and owner:IsA("Player") then
                return owner == player
            elseif type(owner) == "table" then
                return tostring(owner.UserId) == tostring(player.UserId)
                    or owner.Name == player.Name
            elseif type(owner) == "number" or type(owner) == "string" then
                return tostring(owner) == tostring(player.UserId) or owner == player.Name
            end
        end
    end
    local sign = plot:FindFirstChild("PlotSign")
    local marker = sign and sign:FindFirstChild("YourBase", true)
    if marker then
        local ok, enabled = pcall(function() return marker.Enabled end)
        if ok and enabled == true then return true end
    end
    -- The marker is the primary check; attributes cover variants of the plot model.
    local owner = plot:GetAttribute("OwnerUserId") or plot:GetAttribute("Owner")
    if owner == nil then return nil end
    return owner == player.UserId or owner == player.Name or owner == tostring(player.UserId)
end

local function ownPlot()
    plots = workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, plot in ipairs(plots:GetChildren()) do
        if ownsPlot(plot) then return plot end
    end
    if state.manualPlot and state.manualPlot.Parent == plots
        and ownsPlot(state.manualPlot) ~= false then
        return state.manualPlot
    end
    return nil
end

local function animalSnapshot(plot)
    local channel = plotChannel(plot)
    if not channel then return nil end
    local ok, list = pcall(function() return channel:Get("AnimalList") end)
    if not ok or type(list) ~= "table" then return nil end
    local snapshot = {}
    local indices = {}
    for slot, animal in pairs(list) do
        if type(animal) == "table" then
            local traits = animal.Traits
            local traitsText = tostring(traits)
            if type(traits) == "table" then
                local parts = {}
                for name, value in pairs(traits) do
                    parts[#parts + 1] = tostring(name) .. "=" .. tostring(value)
                end
                table.sort(parts)
                traitsText = table.concat(parts, ",")
            end
            snapshot[tostring(slot)] = table.concat({
                tostring(animal.Id or animal.UniqueId or ""),
                tostring(animal.Index),
                tostring(animal.Mutation),
                traitsText,
            }, ":")
            indices[tostring(slot)] = tostring(animal.Index)
        end
    end
    return snapshot, indices
end

local function animalListChanged(before, plot, expectedIndex)
    if not before then return nil end
    local current, indices = animalSnapshot(plot)
    if not current then return nil end
    for slot, signature in pairs(current) do
        if before[slot] ~= signature
            and (expectedIndex == nil or indices[slot] == tostring(expectedIndex)) then
            return true
        end
    end
    return false
end

local function carrying()
    return player:GetAttribute("Stealing") == true
end

local function carrySignalAvailable()
    return player:GetAttributes().Stealing ~= nil
end

connect(player:GetAttributeChangedSignal("Stealing"), function()
    state.carryStartedAt = carrying() and os.clock() or nil
end)
if carrying() then state.carryStartedAt = os.clock() end

local function waitForCarry(timeout, id)
    local deadline = os.clock() + timeout
    while state.alive and state.movementId == id do
        if carrying() then return true end
        if os.clock() >= deadline then break end
        task.wait(0.05)
    end
    return false
end

local function deliveryResult(before, plot, timeout, id, wasCarrying, stolenIndex, carryProbe)
    local currentCarry = carryProbe or carrying
    local deadline = os.clock() + timeout
    local seenCarry = wasCarrying or currentCarry()
    local carryStopped = seenCarry and not currentCarry()
    while state.alive and state.movementId == id and os.clock() < deadline do
        if currentCarry() then
            seenCarry = true
            carryStopped = false
        elseif seenCarry then
            if not carryStopped then
                carryStopped = true
                deadline = math.max(deadline, os.clock() + 0.7)
            end
        end
        if carryStopped and animalListChanged(before, plot, stolenIndex) == true then
            return "confirmed"
        end
        task.wait(0.1)
    end
    if not state.alive or state.movementId ~= id then return "cancelled" end
    if carryStopped then
        if before and plot and stolenIndex ~= nil
            and animalListChanged(before, plot) == true then
            return "delivery changed; index unverified"
        end
        return before and plot and "lost" or "unknown"
    end
    return seenCarry and "carrying" or "unknown"
end

local function deliveryPart()
    local plot = ownPlot()
    if not plot then
        state.markedBase = nil
        state.markedHitbox = nil
        state.markedPlot = nil
        state.manualPlot = nil
        return nil
    end
    if state.markedPlot ~= plot then
        state.markedBase = nil
        state.markedHitbox = nil
        state.markedPlot = nil
    end
    if state.markedHitbox and state.markedHitbox:IsDescendantOf(plot) then
        return state.markedHitbox
    end
    local hitbox = plot:FindFirstChild("DeliveryHitbox", true)
    if hitbox and hitbox:IsA("BasePart") then return hitbox end
    return nil
end

local function deliveryHitbox()
    local part = deliveryPart()
    return part and part.Position or nil
end

-- Some servers accept a touch event from the delivery pad without a position
-- change. This is only a probe; pcall success does not mean server acceptance.
local function tryDeliveryTouch()
    if type(firetouchinterest) ~= "function" then return false end
    local hitbox = deliveryPart()
    local _, _, root = characterParts()
    if not hitbox or not root then return false end
    if (root.Position - hitbox.Position).Magnitude > 12 then return false end
    return pcall(function()
        firetouchinterest(root, hitbox, 0)
        task.wait()
        firetouchinterest(root, hitbox, 1)
    end)
end

local function hasCarryWeld()
    local character, _, root = characterParts()
    if not root then return false end
    local ok, connectedParts = pcall(function() return root:GetConnectedParts(true) end)
    if not ok or type(connectedParts) ~= "table" then return false end
    for _, part in ipairs(connectedParts) do
        if part:IsA("BasePart") and part.Name == "RootPart"
            and part:IsDescendantOf(workspace) and not part:IsDescendantOf(character) then
            local model = part:FindFirstAncestorOfClass("Model")
            if model then
                for _, child in ipairs(part:GetChildren()) do
                    if child:IsA("WeldConstraint")
                        and (child.Part0 == root or child.Part1 == root) then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function tryDeliveryRemote(id)
    if not carrying() then return false end
    local packages = ReplicatedStorage:FindFirstChild("Packages")
    local net = packages and packages:FindFirstChild("Net")
    local remote = net and net:FindFirstChild("RE/StealService/DeliverySteal")
    if not remote then
        state.diagnostics.remote = "absent"
        return false
    end
    if not remote:IsA("RemoteEvent") then
        state.diagnostics.remote = "wrong type"
        return false
    end
    local deadline = os.clock() + 2.8
    while state.alive and state.movementId == id and carrying()
        and os.clock() < deadline do
        local age = os.clock() - (state.carryStartedAt or os.clock())
        if age >= 2.5 and hasCarryWeld() then break end
        task.wait(0.1)
    end
    if not state.alive or state.movementId ~= id or not carrying()
        or not hasCarryWeld() then
        state.diagnostics.remote = "not ready"
        return false
    end
    state.diagnostics.remote = "named"
    return pcall(function() remote:FireServer() end)
end
local function promptPosition(prompt)
    local parent = prompt.Parent
    if parent and parent:IsA("Attachment") then return parent.WorldPosition end
    if parent and parent:IsA("BasePart") then return parent.Position end
    if parent and parent:IsA("Model") then return parent:GetPivot().Position end
    return nil
end

local function isStealPrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local action = string.lower(prompt.ActionText or "")
    local phase = string.lower(tostring(prompt:GetAttribute("State") or ""))
    return string.find(action, "steal", 1, true) ~= nil
        or string.find(phase, "steal", 1, true) ~= nil
end

local function podiumPrompt(podium)
    local base = podium:FindFirstChild("Base")
    local spawn = base and base:FindFirstChild("Spawn")
    local attachment = spawn and spawn:FindFirstChild("PromptAttachment")
    if not attachment then return nil end
    for _, prompt in ipairs(attachment:GetChildren()) do
        if prompt:IsA("ProximityPrompt") and isStealPrompt(prompt) then
            return prompt
        end
    end
    return nil
end

local function nearestTarget()
    local _, _, root = characterParts()
    if not root then return nil end
    local own = ownPlot()
    if game.PlaceId == 109983668079237 and not own then return nil end
    local bestPrompt, bestPosition, bestDistance
    local now = os.clock()
    if plots then
        for _, plot in ipairs(plots:GetChildren()) do
            if plot ~= own then
                local podiums = plot:FindFirstChild("AnimalPodiums")
                if podiums then
                    for _, podium in ipairs(podiums:GetChildren()) do
                        local prompt = podiumPrompt(podium)
                        if isStealPrompt(prompt)
                            and (not state.attempted[prompt] or now - state.attempted[prompt] > 8) then
                            local position = promptPosition(prompt)
                            if position then
                                local distance = (position - root.Position).Magnitude
                                if not bestDistance or distance < bestDistance then
                                    bestPrompt, bestPosition, bestDistance = prompt, position, distance
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    -- Some Duel Server layouts do not expose the normal Plots folder.
    -- In that case use only prompts explicitly labelled "Steal".
    if not bestPrompt then
        for _, item in ipairs(workspace:GetDescendants()) do
            if item:IsA("ProximityPrompt") and isStealPrompt(item)
                and (not state.attempted[item] or now - state.attempted[item] > 8)
                and (not own or not item:IsDescendantOf(own)) then
                local position = promptPosition(item)
                if position then
                    local distance = (position - root.Position).Magnitude
                    if not bestDistance or distance < bestDistance then
                        bestPrompt, bestPosition, bestDistance = item, position, distance
                    end
                end
            end
        end
    end
    return bestPrompt, bestPosition
end

local function movementActive(id)
    return state.alive and state.movementId == id
end

local function walkPoint(point, id, stopDistance)
    local _, humanoid, root = characterParts()
    if not humanoid then return false end
    if not movementActive(id) then return false end
    local distance = (root.Position - point).Magnitude
    -- Local WalkSpeed may be higher than the speed accepted by the server.
    local timeout = os.clock() + math.clamp(distance / 14 * 2 + 3, 3, 30)
    humanoid:MoveTo(point)
    local nextMove = os.clock() + 1.5
    while movementActive(id) and os.clock() < timeout do
        local _, currentHumanoid, currentRoot = characterParts()
        if not currentHumanoid then return false end
        if (currentRoot.Position - point).Magnitude <= stopDistance then return true end
        if os.clock() >= nextMove then
            currentHumanoid:MoveTo(point)
            nextMove = os.clock() + 1.5
        end
        task.wait(0.1)
    end
    return false
end

local function walkTo(position, id, stopDistance)
    local _, _, root = characterParts()
    if not root then return false end
    local route = nil
    local ok = pcall(function()
        route = PathfindingService:CreatePath({
            AgentRadius = 2,
            AgentHeight = 5,
            AgentCanJump = true,
            WaypointSpacing = 4,
        })
        route:ComputeAsync(root.Position, position)
    end)
    if ok and route and route.Status == Enum.PathStatus.Success then
        for _, waypoint in ipairs(route:GetWaypoints()) do
            if not movementActive(id) then return false end
            local _, humanoid = characterParts()
            if not humanoid then return false end
            if waypoint.Action == Enum.PathWaypointAction.Jump then humanoid.Jump = true end
            if not walkPoint(waypoint.Position, id, 3.5) then break end
            local _, _, currentRoot = characterParts()
            if currentRoot and (currentRoot.Position - position).Magnitude <= stopDistance then
                return true
            end
        end
    end
    -- A direct MoveTo is useful when pathfinding fails on a moving or open target.
    return walkPoint(position, id, stopDistance)
end

local function shortTeleport(position, maxDistance, id)
    if not movementActive(id) then return false end
    local character, _, root = characterParts()
    if not character then return false end
    local destination = position + Vector3.new(0, 2, 0)
    local oldVelocity = root.AssemblyLinearVelocity
    local ok = pcall(function()
        root.CFrame = CFrame.new(destination) * (root.CFrame - root.Position)
        root.AssemblyLinearVelocity = Vector3.zero
    end)
    if not ok then return false end
    task.wait(1)
    if not movementActive(id) then return false end
    local _, _, currentRoot = characterParts()
    if not currentRoot then return false end
    local accepted = (currentRoot.Position - destination).Magnitude <= maxDistance
    if not accepted then
        pcall(function() currentRoot.AssemblyLinearVelocity = oldVelocity end)
    end
    return accepted
end

local function activatePrompt(prompt, id)
    if not prompt or not prompt.Parent or not prompt.Enabled then return false end
    local _, _, root = characterParts()
    local position = promptPosition(prompt)
    if not root or not position then return false end
    if (root.Position - position).Magnitude > math.max(0.5, prompt.MaxActivationDistance - 0.5) then
        return false
    end
    local triggered = false
    local eventConnection = prompt.Triggered:Connect(function(triggeringPlayer)
        if triggeringPlayer == nil or triggeringPlayer == player then
            triggered = true
        end
    end)
    local started = pcall(function() prompt:InputHoldBegin() end)
    if started then
        local deadline = os.clock() + math.max(prompt.HoldDuration, 0) + 0.2
        while movementActive(id) and os.clock() < deadline do task.wait(0.05) end
        pcall(function() prompt:InputHoldEnd() end)
    end
    if not movementActive(id) then
        eventConnection:Disconnect()
        return false
    end
    task.wait(0.15)
    if not carrying() and type(fireproximityprompt) == "function" then
        pcall(fireproximityprompt, prompt)
        task.wait(0.15)
    end
    eventConnection:Disconnect()
    return triggered
end

local function buildReturnMethods(deps)
    local player = assert(deps.player, "player required")
    local ownPlot = assert(deps.ownPlot, "ownPlot required")
    local characterParts = assert(deps.characterParts, "characterParts required")
    local carrying = assert(deps.carrying, "carrying required")
    local isActive = assert(deps.isActive, "isActive required")

    local methods = {}
    local CLONE_RADIUS = 14

    local function active(id)
        return isActive(id) == true
    end

    local function ownPad()
        local plot = ownPlot()
        if not plot then return nil, "own plot missing" end
        local pad = plot:FindFirstChild("DeliveryHitbox", true)
        if not pad or not pad:IsA("BasePart") then
            return nil, "own delivery pad missing"
        end
        return pad
    end

    local function clonePosition(clone)
        if not clone or not clone.Parent then return nil end
        local ok, pivot = pcall(function() return clone:GetPivot() end)
        if ok and pivot then return pivot.Position end
        local part = clone:FindFirstChild("HumanoidRootPart", true)
        if part and part:IsA("BasePart") then return part.Position end
        return nil
    end

    local function cloneNearPad(clone, pad)
        local position = clonePosition(clone)
        if not position then return false end
        local offset = position - pad.Position
        local flatDistance = Vector3.new(offset.X, 0, offset.Z).Magnitude
        return flatDistance <= CLONE_RADIUS and math.abs(offset.Y) <= 12
    end

    local function findClone()
        return workspace:FindFirstChild(tostring(player.UserId) .. "_Clone")
    end

    local function ownedTool(name)
        local character = player.Character
        local backpack = player:FindFirstChildOfClass("Backpack")
        local tool = (character and character:FindFirstChild(name))
            or (backpack and backpack:FindFirstChild(name))
        if tool and tool:IsA("Tool") then return tool end
        return nil
    end

    local function hasCarryWeld(root)
        if not root then return false end
        for _, item in ipairs(workspace:GetChildren()) do
            if item:IsA("Model") then
                local part = item:FindFirstChild("RootPart")
                if part and part:IsA("BasePart") then
                    for _, child in ipairs(part:GetChildren()) do
                        if child:IsA("WeldConstraint")
                            and (child.Part0 == root or child.Part1 == root) then
                            return true
                        end
                    end
                end
            end
        end
        return false
    end

    local function carryIntact(root, weldWasPresent, requireCarry)
        if not requireCarry then return true end
        if not carrying() then return false end
        if weldWasPresent and not hasCarryWeld(root) then return false end
        return true
    end

    -- Creates a server-owned clone near your pad while NOT carrying. A clone
    -- outside your base is deliberately rejected: it is unsafe as a return.
    function methods.armClone(id)
        if game.PlaceId ~= 109983668079237 then
            return "unavailable", "main game only"
        end
        if not active(id) then return "unavailable", "cancelled" end
        if carrying() then return "unavailable", "arm before stealing" end

        local pad, padError = ownPad()
        if not pad then return "unavailable", padError end
        local clone = findClone()
        if clone then
            if cloneNearPad(clone, pad) then return "ready", "clone at base" end
            return "unavailable", "existing clone outside base"
        end

        local character, humanoid, root = characterParts()
        local tool = ownedTool("Quantum Cloner")
        if not character or not root then return "unavailable", "character missing" end
        if not tool then return "unavailable", "Quantum Cloner missing" end
        if (root.Position - pad.Position).Magnitude > 12 then
            return "unavailable", "stand by your own delivery pad"
        end

        local previousTool = character:FindFirstChildOfClass("Tool")
        local function finish(result, detail)
            if previousTool ~= tool then
                pcall(function() humanoid:UnequipTools() end)
                if previousTool and previousTool.Parent then
                    pcall(function() humanoid:EquipTool(previousTool) end)
                end
            end
            return result, detail
        end

        if tool.Parent ~= character then
            local equipOK = pcall(function() humanoid:EquipTool(tool) end)
            if not equipOK then return finish("unavailable", "cloner equip failed") end
            task.wait(0.12)
        end
        if not active(id) then return finish("unavailable", "cancelled") end
        if tool.Parent ~= character then return finish("unavailable", "cloner not equipped") end

        local activated = pcall(function() tool:Activate() end)
        if not activated then return finish("unavailable", "cloner activation failed") end
        local deadline = os.clock() + 3
        repeat
            if not active(id) then return finish("unavailable", "cancelled") end
            clone = findClone()
            if clone then break end
            task.wait(0.1)
        until os.clock() >= deadline
        if not clone then return finish("unavailable", "clone did not spawn") end
        if not cloneNearPad(clone, pad) then
            return finish("unavailable", "clone spawned outside delivery area")
        end
        return finish("ready", "clone at base")
    end

    local function cloneButton()
        local gui = player:FindFirstChildOfClass("PlayerGui")
        local frames = gui and gui:FindFirstChild("ToolsFrames")
        local quantum = frames and frames:FindFirstChild("QuantumCloner")
        local button = quantum and quantum:FindFirstChild("TeleportToClone")
        if button and button:IsA("GuiButton") then return button end
        return nil
    end

    -- Uses the already placed clone's GUI control. Never equips gear while
    -- carrying. Clicking is only an attempt; caller must check AnimalList.
    function methods.attemptClone(id, allowEmpty)
        if game.PlaceId ~= 109983668079237 then
            return "unavailable", "main game only"
        end
        if not active(id) then return "unavailable", "cancelled" end
        if not carrying() and not allowEmpty then return "unavailable", "not carrying" end
        local pad, padError = ownPad()
        if not pad then return "unavailable", padError end
        local clone = findClone()
        if not clone or not cloneNearPad(clone, pad) then
            return "unavailable", "armed clone not at own base"
        end
        local button = cloneButton()
        if not button then return "unavailable", "clone swap GUI missing" end

        -- Xeno variants expose different click APIs. Prefer a real UI click;
        -- a firesignal stub may return successfully without invoking anything.
        local vimOK, vim = pcall(function()
            return game:GetService("VirtualInputManager")
        end)
        if not vimOK or not vim then
            vimOK, vim = pcall(function() return Instance.new("VirtualInputManager") end)
        end

        local screen = button:FindFirstAncestorOfClass("ScreenGui")
        local oldEnabled = screen and screen.Enabled
        local oldDisplayOrder = screen and screen.DisplayOrder
        local visibility = {}
        local clicked = false
        local ok = vimOK and vim and pcall(function()
            local current = button
            while current and current ~= screen do
                if current:IsA("GuiObject") then
                    visibility[#visibility + 1] = {current, current.Visible, current.ZIndex}
                    current.Visible = true
                    current.ZIndex = math.max(current.ZIndex, 100)
                end
                current = current.Parent
            end
            if screen then
                screen.Enabled = true
                screen.DisplayOrder = 1001
            end
            task.wait()
            if not active(id) or (not carrying() and not allowEmpty) then return end
            local size = button.AbsoluteSize
            if size.X <= 0 or size.Y <= 0 then return end
            local center = button.AbsolutePosition + size / 2
            local x, y = center.X, center.Y
            local hitOK, hits = pcall(function()
                return player.PlayerGui:GetGuiObjectsAtPosition(x, y)
            end)
            if hitOK and hits and #hits > 0
                and hits[1] ~= button and not hits[1]:IsDescendantOf(button) then
                return
            end
            local inset = game:GetService("GuiService"):GetGuiInset()
            local mouseX, mouseY = x + inset.X, y + inset.Y
            local function sendClick(manager)
                return pcall(function()
                    manager:SendMouseButtonEvent(mouseX, mouseY, 0, true, game, 1)
                    task.wait(0.05)
                    manager:SendMouseButtonEvent(mouseX, mouseY, 0, false, game, 1)
                end)
            end
            clicked = sendClick(vim)
            if not clicked then
                local alternateOK, alternate = pcall(function()
                    return Instance.new("VirtualInputManager")
                end)
                if alternateOK and alternate then
                    clicked = sendClick(alternate)
                end
            end
        end)
        for _, item in ipairs(visibility) do
            pcall(function()
                item[1].Visible = item[2]
                item[1].ZIndex = item[3]
            end)
        end
        if screen then pcall(function()
            screen.Enabled = oldEnabled
            screen.DisplayOrder = oldDisplayOrder
        end) end
        if ok and clicked then return "attempted", "clone GUI click" end

        if type(firesignal) == "function" then
            local probe = Instance.new("BindableEvent")
            local fired = false
            local connection = probe.Event:Connect(function() fired = true end)
            local probeOK = pcall(firesignal, probe.Event)
            if probeOK then task.wait() end
            connection:Disconnect()
            probe:Destroy()
            if probeOK and fired then
                local signalOK = pcall(firesignal, button.MouseButton1Up)
                if signalOK then return "attempted", "clone GUI signal" end
            end
        end
        return "unavailable", "GUI click API missing or blocked"
    end

    -- Experimental: the published carpet ascent/snap was used for travel TO
    -- a target, not for delivery while carrying. This routine performs one
    -- bounded attempt and verifies the carried object survives gear equip.
    function methods.attemptCarpet(id, allowEmpty)
        if game.PlaceId ~= 109983668079237 then
            return "unavailable", "main game only"
        end
        if not active(id) then return "unavailable", "cancelled" end
        local requireCarry = carrying()
        if not requireCarry and not allowEmpty then return "unavailable", "not carrying" end
        local pad, padError = ownPad()
        if not pad then return "unavailable", padError end
        local character, humanoid, root = characterParts()
        if not character then return "unavailable", "character missing" end
        local tool = ownedTool("Flying Carpet")
        if not tool then return "unavailable", "Flying Carpet missing" end
        if requireCarry and tool.Parent ~= character then
            return "unavailable", "carpet must already be equipped while carrying"
        end

        local hold
        local ascentStarted = false
        local function finish(result, detail)
            if hold then pcall(function() hold:Destroy() end) end
            if ascentStarted and root.Parent then
                pcall(function()
                    local velocity = root.AssemblyLinearVelocity
                    root.AssemblyLinearVelocity = Vector3.new(
                        velocity.X, math.min(velocity.Y, 0), velocity.Z
                    )
                end)
            end
            return result, detail
        end

        local weldWasPresent = hasCarryWeld(root)
        if tool.Parent ~= character then
            local equipped = pcall(function() humanoid:EquipTool(tool) end)
            if not equipped then return finish("unavailable", "carpet equip failed") end
            task.wait(0.12)
        end
        if not active(id) then return finish("unavailable", "cancelled") end
        if tool.Parent ~= character then return finish("unavailable", "carpet not equipped") end
        if not carryIntact(root, weldWasPresent, requireCarry) then
            return finish("attempted", "carry lost on carpet equip")
        end

        local targetY = math.max(40, pad.Position.Y + 20)
        local started = os.clock()
        while active(id) and root.Parent and root.Position.Y < targetY
            and os.clock() - started < 2 do
            if not carryIntact(root, weldWasPresent, requireCarry) then
                return finish("attempted", "carry lost during ascent")
            end
            local velocity = root.AssemblyLinearVelocity
            local applied = pcall(function()
                root.AssemblyLinearVelocity = Vector3.new(velocity.X, 200, velocity.Z)
            end)
            if not applied then return finish("unavailable", "ascent velocity rejected") end
            ascentStarted = true
            task.wait()
        end
        if not active(id) then return finish("unavailable", "cancelled") end
        if not root.Parent or root.Position.Y < targetY - 3 then
            return finish("attempted", "ascent rejected")
        end
        if not carryIntact(root, weldWasPresent, requireCarry) then
            return finish("attempted", "carry lost after ascent")
        end

        local snapped = false
        local ok = pcall(function()
            local destination = pad.Position + Vector3.new(0, 4, 0)
            local rotation = root.CFrame - root.Position
            root.AssemblyLinearVelocity = Vector3.zero
            root.AssemblyAngularVelocity = Vector3.zero
            root.CFrame = CFrame.new(destination) * rotation
            hold = Instance.new("BodyPosition")
            hold.Name = "BrainrotReturnHold"
            hold.MaxForce = Vector3.new(1e9, 1e9, 1e9)
            hold.P = 50000
            hold.D = 5000
            hold.Position = destination
            hold.Parent = root
            snapped = true
            local stop = os.clock() + 0.3
            while active(id) and os.clock() < stop do task.wait(0.03) end
        end)
        if not ok or not snapped then return finish("unavailable", "carpet snap failed") end
        if not active(id) then return finish("unavailable", "cancelled") end
        return finish("attempted", "carpet ascent and snap")
    end

    return methods
end

local returnMethods = buildReturnMethods({
    player = player,
    ownPlot = ownPlot,
    characterParts = characterParts,
    carrying = carrying,
    isActive = movementActive,
})

local function attemptDelivery(basePosition, before, plot, id)
    if not movementActive(id) then return "cancelled" end
    local function carryPresent() return carrying() or hasCarryWeld() end
    local wasCarrying = carryPresent()
    local stolenIndex = player:GetAttribute("StealingIndex")

    local function checkAfter(timeout)
        local result = deliveryResult(
            before, plot, timeout, id, wasCarrying, stolenIndex, carryPresent
        )
        if result ~= "carrying" and result ~= "unknown" then
            return result
        end
        return nil
    end

    local function completeAtPad()
        local _, humanoid, root = characterParts()
        if not root or (root.Position - basePosition).Magnitude > 25 then return nil end
        if (root.Position - basePosition).Magnitude > 5 then
            walkTo(basePosition, id, 4)
            if not movementActive(id) then return "cancelled" end
        end
        _, humanoid, root = characterParts()
        if not root then return "character missing" end
        if (root.Position - basePosition).Magnitude > 12 then return "return route failed" end
        if humanoid then humanoid:MoveTo(basePosition) end
        task.wait(0.35)
        if not movementActive(id) then return "cancelled" end
        tryDeliveryTouch()
        return checkAfter(1.7) or "still carrying at base"
    end

    if carrying() then
        state.diagnostics.returnMethod = "remote"
        setStatus("checking instant delivery remote")
        if tryDeliveryRemote(id) then
            local result = checkAfter(1.3)
            if result then return result end
        end
        if not movementActive(id) then return "cancelled" end
    end

    if game.PlaceId == 109983668079237 and carrying() then
        local attempted, detail = returnMethods.attemptClone(id)
        state.diagnostics.clone = detail
        if attempted == "attempted" then
            state.diagnostics.returnMethod = "clone"
            setStatus("clone return attempted")
            local result = checkAfter(1.7)
            if result then return result end
            result = completeAtPad()
            if result then return result end
        end
        if not movementActive(id) then return "cancelled" end

        attempted, detail = returnMethods.attemptCarpet(id)
        state.diagnostics.carpet = detail
        if attempted == "attempted" then
            state.diagnostics.returnMethod = "carpet"
            setStatus("carpet return attempted")
            local result = checkAfter(1.7)
            if result then return result end
            result = completeAtPad()
            if result then return result end
        end
        if not movementActive(id) then return "cancelled" end
    elseif game.PlaceId ~= 109983668079237 then
        state.diagnostics.returnMethod = "direct"
        setStatus("trying direct return")
        shortTeleport(basePosition, 3.5, id)
        if not movementActive(id) then return "cancelled" end
        local result = checkAfter(1.5)
        if result then return result end
    end

    local _, _, root = characterParts()
    if not root then return "character missing" end
    if (root.Position - basePosition).Magnitude > 5 then
        state.diagnostics.returnMethod = "route"
        setStatus("returning to own delivery pad")
        walkTo(basePosition, id, 4)
        if not movementActive(id) then return "cancelled" end
    end

    local _, humanoid, finalRoot = characterParts()
    if not finalRoot then return "character missing" end
    if (finalRoot.Position - basePosition).Magnitude > 12 then
        return "return route failed"
    end
    if humanoid then humanoid:MoveTo(basePosition) end
    task.wait(0.35)
    if not movementActive(id) then return "cancelled" end
    tryDeliveryTouch()
    local result = deliveryResult(
        before, plot, 2, id, wasCarrying, stolenIndex, carryPresent
    )
    if result ~= "carrying" and result ~= "unknown" then
        return result
    end
    return carryPresent() and "still carrying" or result
end

local function setAuto(enabled)
    state.auto = enabled
    state.movementId = state.movementId + 1
    if state.ui then state.ui.update() end
    if not enabled then
        local _, humanoid, root = characterParts()
        if humanoid and root then humanoid:MoveTo(root.Position) end
        setStatus("auto steal off")
        return
    end
    state.nextDeliveryAt = 0
    state.nextCloneArmAt = 0
    state.clonePreflightDone = false
    setStatus("auto steal on")
    local id = state.movementId
    task.spawn(function()
        while state.auto and movementActive(id) do
            local basePosition = deliveryHitbox()
            if not basePosition then
                state.diagnostics.base = "missing"
                setStatus("own plot / DeliveryHitbox not found")
                task.wait(1)
            else
                state.diagnostics.base = state.markedBase and "marked" or "own pad"
                local plot = ownPlot()
                if carrying() then
                    if os.clock() < state.nextDeliveryAt then
                        task.wait(0.3)
                    else
                        state.diagnostics.carry = "verified"
                        state.diagnostics.target = "base"
                        local result = attemptDelivery(
                            basePosition, animalSnapshot(plot), plot, id
                        )
                        if not movementActive(id) then break end
                        state.nextDeliveryAt = os.clock() + 3
                        state.diagnostics.delivery = result
                        setStatus("delivery: " .. result)
                        task.wait(0.5)
                    end
                else
                    if game.PlaceId == 109983668079237
                        and not state.clonePreflightDone then
                        state.clonePreflightDone = true
                        local pad = deliveryPart()
                        local character, _, root = characterParts()
                        local backpack = player:FindFirstChildOfClass("Backpack")
                        local cloner = (character and character:FindFirstChild("Quantum Cloner"))
                            or (backpack and backpack:FindFirstChild("Quantum Cloner"))
                        local clone = workspace:FindFirstChild(tostring(player.UserId) .. "_Clone")
                        if pad and root and cloner and not clone
                            and (root.Position - pad.Position).Magnitude > 12 then
                            setStatus("going to own base to arm clone")
                            walkTo(pad.Position, id, 7)
                            if not movementActive(id) then break end
                        end
                    end
                    if game.PlaceId == 109983668079237
                        and os.clock() >= state.nextCloneArmAt then
                        local pad = deliveryPart()
                        local _, _, root = characterParts()
                        if pad and root and (root.Position - pad.Position).Magnitude <= 12 then
                            state.nextCloneArmAt = os.clock() + 10
                            local result, detail = returnMethods.armClone(id)
                            state.diagnostics.clone = detail
                            if not movementActive(id) then break end
                            if result == "ready" then setStatus("home clone ready") end
                        end
                    end
                    local prompt, position = nearestTarget()
                    if not prompt then
                        state.diagnostics.target = "missing"
                        setStatus("no steal prompt found")
                        task.wait(1)
                    else
                        state.attempted[prompt] = os.clock()
                        state.diagnostics.target = "podium"
                        setStatus("moving to steal prompt")
                        local _, _, root = characterParts()
                        local range = math.max(0.5, prompt.MaxActivationDistance - 0.5)
                        if root and (root.Position - position).Magnitude > range then
                            walkTo(position, id, range)
                        end
                        if state.auto and movementActive(id) then
                            local triggered = activatePrompt(prompt, id)
                            if not movementActive(id) then break end
                            local hasCarry = waitForCarry(2.5, id)
                            if not movementActive(id) then break end
                            if not hasCarry and not triggered and movementActive(id) then
                                setStatus("prompt missed; moving closer")
                                if walkTo(position, id, math.max(0.5, range - 1)) then
                                    triggered = activatePrompt(prompt, id)
                                    if not movementActive(id) then break end
                                    hasCarry = waitForCarry(2.5, id)
                                    if not movementActive(id) then break end
                                end
                            end
                            if hasCarry or hasCarryWeld() then
                                state.diagnostics.carry = hasCarry and "attribute" or "weld"
                                local result = attemptDelivery(
                                    basePosition, animalSnapshot(plot), plot, id
                                )
                                if not movementActive(id) then break end
                                state.nextDeliveryAt = os.clock() + 3
                                state.diagnostics.delivery = result
                                setStatus("delivery: " .. result)
                            else
                                state.diagnostics.carry = "absent"
                                setStatus("server did not confirm pickup")
                            end
                        end
                        task.wait(0.2)
                    end
                end
            end
        end
    end)
end

local function createVelocitySpeedController(state, player, report)
    local RunService = game:GetService("RunService")
    local controller = {}
    local savedSpeed = setmetatable({}, { __mode = "k" })
    local heartbeat
    local mode
    local previousRoot
    local previousPosition
    local measuredDistance = 0
    local measuredTime = 0
    local slowWindows = 0
    local fastWindows = 0

    state.diagnostics = state.diagnostics or {}
    state.diagnostics.speed = state.speed and "waiting" or "off"

    local function resetMeasurement()
        previousRoot = nil
        previousPosition = nil
        measuredDistance = 0
        measuredTime = 0
        slowWindows = 0
        fastWindows = 0
    end

    local function setMode(nextMode, message)
        state.diagnostics.speed = nextMode
        if mode ~= nextMode then
            mode = nextMode
            if type(report) == "function" and message then report(message) end
        end
    end

    local function restoreWalkSpeeds()
        for humanoid, original in pairs(savedSpeed) do
            if humanoid and humanoid.Parent then
                pcall(function() humanoid.WalkSpeed = original end)
            end
            savedSpeed[humanoid] = nil
        end
    end

    local function disconnect()
        if heartbeat then
            heartbeat:Disconnect()
            heartbeat = nil
        end
        resetMeasurement()
        restoreWalkSpeeds()
    end

    local function onHeartbeat(dt)
        if not state.alive then
            disconnect()
            state.speed = false
            setMode("off")
            return
        end
        if not state.speed then return end

        local character = player.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local root = character and character:FindFirstChild("HumanoidRootPart")
        if not humanoid or not root or humanoid.Health <= 0 then
            resetMeasurement()
            setMode("waiting", "speed: waiting for character")
            return
        end

        local target = math.clamp(tonumber(state.speedValue) or 32, 16, 100)
        state.diagnostics.requestedSpeed = math.floor(target + 0.5)

        if savedSpeed[humanoid] == nil then
            savedSpeed[humanoid] = humanoid.WalkSpeed
        end
        -- Keep the normal Humanoid controller in step with the physics boost.
        -- Do not apply the old 24-stud carrying cap: it made the slider misleading.
        if humanoid.WalkSpeed ~= target then
            local ok = pcall(function() humanoid.WalkSpeed = target end)
            if not ok then
                setMode("write failed", "speed: cannot set WalkSpeed")
                return
            end
        end

        local move = humanoid.MoveDirection
        local usable = move.Magnitude > 0.08
            and not humanoid.Sit
            and not humanoid.PlatformStand
            and not root.Anchored
            and humanoid.FloorMaterial ~= Enum.Material.Air

        if not usable then
            resetMeasurement()
            setMode("idle", "speed: waiting for ground movement")
            return
        end

        local direction = Vector3.new(move.X, 0, move.Z)
        if direction.Magnitude <= 0.08 then
            resetMeasurement()
            setMode("idle", "speed: waiting for ground movement")
            return
        end
        direction = direction.Unit

        -- Measure signed progress along input. A server rubberband goes backward
        -- and must never count as successful speed.
        if previousRoot == root and previousPosition and dt > 0 and dt <= 0.15 then
            local delta = root.Position - previousPosition
            local horizontal = Vector3.new(delta.X, 0, delta.Z)
            local projected = horizontal:Dot(direction)
            if horizontal.Magnitude <= target * dt * 2 + 2 then
                if projected < -math.max(2, target * dt * 1.5) then
                    measuredDistance = 0
                    measuredTime = 0
                    slowWindows = 0
                    fastWindows = 0
                    state.diagnostics.actualSpeed = 0
                    setMode("corrected", "speed: server corrected movement")
                else
                    measuredDistance = measuredDistance + projected
                    measuredTime = measuredTime + dt
                end
            elseif projected < 0 then
                measuredDistance = 0
                measuredTime = 0
                slowWindows = 0
                fastWindows = 0
                state.diagnostics.actualSpeed = 0
                setMode("corrected", "speed: server corrected movement")
            else
                measuredDistance = 0
                measuredTime = 0
                fastWindows = 0
            end
        else
            measuredDistance = 0
            measuredTime = 0
        end
        previousRoot = root
        previousPosition = root.Position

        -- Accelerate along the player's real MoveDirection. Preserve vertical
        -- velocity so jumping and gravity still use the game's own physics.
        -- The write can be ignored or corrected by the server.
        local velocity = root.AssemblyLinearVelocity
        local horizontal = Vector3.new(velocity.X, 0, velocity.Z)
        local along = horizontal:Dot(direction)
        local lateral = horizontal - direction * along
        local nextAlong = math.min(target, along + 150 * math.min(dt, 0.1))
        local nextHorizontal = direction * nextAlong + lateral * 0.25
        local ok = pcall(function()
            root.AssemblyLinearVelocity = Vector3.new(nextHorizontal.X, velocity.Y, nextHorizontal.Z)
        end)
        if not ok then
            setMode("write failed", "speed: velocity write failed")
            return
        end

        if measuredTime >= 1.2 then
            local actual = math.max(0, measuredDistance / measuredTime)
            state.diagnostics.actualSpeed = math.floor(actual + 0.5)
            measuredDistance = 0
            measuredTime = 0
            if actual < target * 0.65 then
                slowWindows = slowWindows + 1
                fastWindows = 0
                if slowWindows >= 2 then
                    setMode("limited", string.format(
                        "speed limited: %.0f observed / %.0f requested", actual, target
                    ))
                end
            else
                slowWindows = 0
                fastWindows = fastWindows + 1
                if fastWindows >= 2 then
                    setMode("active", string.format(
                        "speed active: %.0f observed / %.0f requested", actual, target
                    ))
                end
            end
            if state.ui then state.ui.setDiagnostics(state.diagnostics) end
        end
    end

    function controller.setEnabled(enabled)
        state.speed = not not enabled
        if state.speed then
            if not heartbeat then heartbeat = RunService.Heartbeat:Connect(onHeartbeat) end
            setMode("waiting", "speed: measuring movement")
        else
            disconnect()
            state.diagnostics.actualSpeed = nil
            setMode("off", "speed off")
        end
        if state.ui then state.ui.update() end
    end

    function controller.setValue(value)
        state.speedValue = math.clamp(math.floor(tonumber(value) or state.speedValue or 32), 16, 100)
        resetMeasurement()
        if state.speed then setMode("waiting", "speed: measuring movement") end
        if state.ui then state.ui.update() end
    end

    function controller.unload()
        state.speed = false
        disconnect()
        state.diagnostics.actualSpeed = nil
        setMode("off")
    end

    return controller
end

local speedController = createVelocitySpeedController(state, player, setStatus)
local setSpeed = speedController.setEnabled

local function showDiagnostics()
    local character, humanoid, root = characterParts()
    local plot = ownPlot()
    local pad = deliveryPart()
    local packages = ReplicatedStorage:FindFirstChild("Packages")
    local net = packages and packages:FindFirstChild("Net")
    local remote = net and net:FindFirstChild("RE/StealService/DeliverySteal")
    local backpack = player:FindFirstChildOfClass("Backpack")
    local function hasTool(name)
        return (character and character:FindFirstChild(name) ~= nil)
            or (backpack and backpack:FindFirstChild(name) ~= nil) or false
    end
    local clone = workspace:FindFirstChild(tostring(player.UserId) .. "_Clone")
    local cloneDistance = nil
    if clone and pad then
        local ok, position = pcall(function()
            return clone:IsA("Model") and clone:GetPivot().Position or clone.Position
        end)
        if ok and position then
            cloneDistance = math.floor((position - pad.Position).Magnitude + 0.5)
        end
    end
    local report = {
        version = "main-v2",
        placeId = game.PlaceId,
        plot = plot and plot.Name or "none",
        pad = pad ~= nil,
        padDistance = root and pad and math.floor((root.Position - pad.Position).Magnitude + 0.5) or nil,
        stealing = carrying(),
        carrySignal = carrySignalAvailable(),
        carryWeld = hasCarryWeld(),
        speedRequested = state.speed and state.speedValue or nil,
        speedObserved = state.diagnostics.actualSpeed,
        speedMode = state.diagnostics.speed,
        walkSpeed = humanoid and humanoid.WalkSpeed or nil,
        deliveryRemote = remote and remote.ClassName or "none",
        carpet = hasTool("Flying Carpet"),
        cloner = hasTool("Quantum Cloner"),
        cloneDistance = cloneDistance,
        lastDelivery = state.diagnostics.delivery,
    }
    local encoded = HttpService:JSONEncode(report)
    print("[Brainrot Xeno DIAG] " .. encoded)
    local copied = false
    if type(setclipboard) == "function" then
        copied = pcall(setclipboard, encoded)
    end
    setStatus(copied and "diagnostics copied" or "diagnostics printed to console")
    return report
end
state.Diagnostics = showDiagnostics

local function stableNearBase(position, id)
    for _ = 1, 2 do
        task.wait(0.7)
        if not movementActive(id) then return false end
        local _, _, root = characterParts()
        if not root or (root.Position - position).Magnitude > 6 then return false end
    end
    return true
end

local function teleportBase()
    local basePosition = deliveryHitbox()
    if not basePosition then
        setStatus("own plot / DeliveryHitbox not found")
        return
    end
    if state.auto then setAuto(false) end
    state.movementId = state.movementId + 1
    local id = state.movementId
    task.spawn(function()
        if carrying() then
            local plot = ownPlot()
            local result = attemptDelivery(basePosition, animalSnapshot(plot), plot, id)
            if movementActive(id) then
                state.diagnostics.delivery = result
                state.diagnostics.target = "base"
                setStatus("delivery: " .. result)
            end
            return
        end
        if game.PlaceId == 109983668079237 then
            local attempted, detail = returnMethods.attemptClone(id, true)
            state.diagnostics.clone = detail
            if attempted == "attempted" then
                state.diagnostics.returnMethod = "clone"
                setStatus("trying clone return")
                if stableNearBase(basePosition, id) then
                    setStatus("at base via clone")
                    return
                end
            end
            if not movementActive(id) then return end
            attempted, detail = returnMethods.attemptCarpet(id, true)
            state.diagnostics.carpet = detail
            if attempted == "attempted" then
                state.diagnostics.returnMethod = "carpet"
                setStatus("trying carpet return")
                if stableNearBase(basePosition, id) then
                    setStatus("at base via carpet")
                    return
                end
            end
        end
        if not movementActive(id) then return end
        state.diagnostics.returnMethod = "direct"
        setStatus("trying direct return")
        local accepted = shortTeleport(basePosition, 3.5, id)
        if not movementActive(id) then return end
        if accepted and stableNearBase(basePosition, id) then
            setStatus("at base")
            return
        end
        setStatus("server corrected return; walking to base")
        local reached = walkTo(basePosition, id, 3.5)
        if movementActive(id) then
            setStatus(reached and "at base by route" or "base route failed")
        end
    end)
end

local function markBase()
    local _, _, root = characterParts()
    if not root then
        setStatus("character is not ready")
        return
    end
    local plot = ownPlot()
    local nearest = plot and plot:FindFirstChild("DeliveryHitbox", true)
    if nearest and not nearest:IsA("BasePart") then nearest = nil end
    local manual = false
    if not nearest then
        plots = workspace:FindFirstChild("Plots")
        local candidates = {}
        for _, candidate in ipairs(plots and plots:GetChildren() or {}) do
            if ownsPlot(candidate) ~= false then
                local pad = candidate:FindFirstChild("DeliveryHitbox", true)
                if pad and pad:IsA("BasePart") then
                    local offset = pad.Position - root.Position
                    local flat = Vector3.new(offset.X, 0, offset.Z).Magnitude
                    if flat <= 5 and math.abs(offset.Y) <= 10 then
                        candidates[#candidates + 1] = {candidate, pad}
                    end
                end
            end
        end
        if #candidates == 1 then
            plot, nearest = candidates[1][1], candidates[1][2]
            state.manualPlot = plot
            manual = true
        end
    end
    if not nearest then
        setStatus("stand on your own delivery pad to mark it")
        return
    end
    state.markedHitbox = nearest
    state.markedBase = nearest.Position
    state.markedPlot = plot
    state.diagnostics.base = manual and "manual pad" or "marked pad"
    setStatus(manual and "manual pad marked; ownership unverified" or "delivery pad marked")
    if game.PlaceId == 109983668079237 and not carrying()
        and not state.cloneArming then
        state.cloneArming = true
        local id = state.movementId
        task.spawn(function()
            local result, detail = returnMethods.armClone(id)
            state.cloneArming = false
            state.diagnostics.clone = detail
            if movementActive(id) and result == "ready" then
                setStatus("delivery pad marked; clone armed")
            elseif movementActive(id) and detail ~= "Quantum Cloner missing" then
                setStatus("pad marked; clone: " .. detail)
            end
        end)
    end
end

local function buildUI(state, actions)
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local CoreGui = game:GetService("CoreGui")
    local player = Players.LocalPlayer
    local mainPlace = game.PlaceId == 109983668079237

    local function rgb(hex)
        return Color3.fromRGB(
            tonumber(hex:sub(2, 3), 16),
            tonumber(hex:sub(4, 5), 16),
            tonumber(hex:sub(6, 7), 16)
        )
    end

    local C = {
        ink = rgb("#151625"),
        panel = rgb("#202234"),
        raised = rgb("#2B2D43"),
        line = rgb("#44465C"),
        white = rgb("#F5F3EE"),
        violet = rgb("#A988FF"),
        coral = rgb("#FF7666"),
        slate = rgb("#9297A9"),
        mint = rgb("#76D7A4"),
    }

    local connections = {}
    local function connect(signal, callback)
        local connection = signal:Connect(callback)
        connections[#connections + 1] = connection
        return connection
    end

    local function create(kind, parent, props)
        local object = Instance.new(kind)
        for key, value in pairs(props) do object[key] = value end
        object.Parent = parent
        return object
    end

    local function round(parent, radius)
        create("UICorner", parent, { CornerRadius = UDim.new(0, radius) })
    end

    local function outline(parent, color, thickness)
        create("UIStroke", parent, {
            ApplyStrokeMode = Enum.ApplyStrokeMode.Border,
            Color = color,
            Thickness = thickness or 1,
        })
    end

    local function textLabel(parent, value, x, y, width, height, font, size, color)
        return create("TextLabel", parent, {
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(width, height),
            Text = value,
            TextColor3 = color,
            TextSize = size,
            Font = font,
            TextXAlignment = Enum.TextXAlignment.Left,
            TextYAlignment = Enum.TextYAlignment.Center,
            TextTruncate = Enum.TextTruncate.AtEnd,
        })
    end

    local function textButton(parent, value, x, y, width, height, background, color, font, size)
        local button = create("TextButton", parent, {
            AutoButtonColor = false,
            BackgroundColor3 = background,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(x, y),
            Size = UDim2.fromOffset(width, height),
            Text = value,
            TextColor3 = color,
            TextSize = size,
            Font = font,
        })
        round(button, 8)
        return button
    end

    local gui = create("ScreenGui", nil, {
        Name = "BrainrotXenoUI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        DisplayOrder = 1000,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
    })
    local parented = pcall(function()
        if type(gethui) == "function" then
            gui.Parent = gethui()
        else
            gui.Parent = CoreGui
        end
    end)
    if not parented or not gui.Parent then
        gui.Parent = player:WaitForChild("PlayerGui")
    end

    local panel = create("Frame", gui, {
        Name = "MainPanel",
        Active = true,
        BackgroundColor3 = C.ink,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 28, 0.5, -196),
        Size = UDim2.fromOffset(332, 392),
    })
    round(panel, 13)
    outline(panel, C.line)

    -- Compact scoreboard header keeps the main-place controls easy to scan.
    local header = create("Frame", panel, {
        Active = true,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromOffset(332, 104),
    })
    textLabel(header, mainPlace and "STEAL" or "DUEL", 16, 11, 165, 39,
        Enum.Font.FredokaOne, 31, C.white)
    textLabel(header, mainPlace and "Main server / Xeno" or "Steal a Brainrot",
        17, 49, 182, 21, Enum.Font.GothamMedium, 12, C.slate)
    local hideButton = textButton(header, "−", 291, 16, 25, 25, C.raised, C.white,
        Enum.Font.GothamBold, 17)
    hideButton.Name = "Hide"

    local youBar = create("Frame", header, {
        BackgroundColor3 = C.mint,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(16, 83),
        Size = UDim2.fromOffset(145, 5),
    })
    round(youBar, 3)
    local rivalBar = create("Frame", header, {
        BackgroundColor3 = C.coral,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(171, 83),
        Size = UDim2.fromOffset(145, 5),
    })
    round(rivalBar, 3)
    textLabel(header, "You", 16, 66, 66, 15, Enum.Font.GothamBold, 10, C.mint)
    local rivalLabel = textLabel(header, mainPlace and "Targets" or "Rival", 250, 66, 66, 15,
        Enum.Font.GothamBold, 10, C.coral)
    rivalLabel.TextXAlignment = Enum.TextXAlignment.Right

    local autoCard = create("Frame", panel, {
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 101),
        Size = UDim2.fromOffset(308, 64),
    })
    round(autoCard, 9)
    outline(autoCard, C.line)
    textLabel(autoCard, "Auto steal", 13, 9, 165, 23, Enum.Font.GothamBold, 16, C.white)
    textLabel(autoCard, "Find a podium and return", 13, 34, 191, 17,
        Enum.Font.Gotham, 11, C.slate)
    local autoButton = textButton(autoCard, "OFF", 235, 15, 59, 34,
        C.raised, C.white, Enum.Font.GothamBold, 12)
    autoButton.Name = "AutoSteal"

    local speedCard = create("Frame", panel, {
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 174),
        Size = UDim2.fromOffset(308, 88),
    })
    round(speedCard, 9)
    outline(speedCard, C.line)
    textLabel(speedCard, "Speed", 13, 9, 100, 21, Enum.Font.GothamBold, 14, C.white)
    local speedValueLabel = textLabel(speedCard, "32", 124, 8, 48, 22,
        Enum.Font.GothamBold, 14, C.violet)
    speedValueLabel.TextXAlignment = Enum.TextXAlignment.Right
    local speedButton = textButton(speedCard, "OFF", 235, 8, 59, 28,
        C.raised, C.white, Enum.Font.GothamBold, 11)
    speedButton.Name = "SpeedToggle"

    local speedTrack = create("Frame", speedCard, {
        Active = true,
        BackgroundColor3 = C.line,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(14, 58),
        Size = UDim2.fromOffset(280, 6),
    })
    round(speedTrack, 3)
    local speedFill = create("Frame", speedTrack, {
        BackgroundColor3 = C.violet,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(0, 1),
    })
    round(speedFill, 3)
    local speedKnob = create("Frame", speedTrack, {
        Active = true,
        BackgroundColor3 = C.white,
        BorderSizePixel = 0,
        AnchorPoint = Vector2.new(0.5, 0.5),
        Position = UDim2.fromScale(0, 0.5),
        Size = UDim2.fromOffset(14, 14),
    })
    round(speedKnob, 7)
    outline(speedKnob, C.violet, 2)
    textLabel(speedCard, "16", 14, 69, 30, 13, Enum.Font.Gotham, 9, C.slate)
    local maxSpeed = textLabel(speedCard, "100", 261, 69, 33, 13,
        Enum.Font.Gotham, 9, C.slate)
    maxSpeed.TextXAlignment = Enum.TextXAlignment.Right

    local returnButton = textButton(panel, "Return home  [F7]", 12, 272, 150, 37,
        C.coral, C.ink, Enum.Font.GothamBold, 12)
    returnButton.Name = "ReturnHome"
    local markButton = textButton(panel, "Mark base", 170, 272, 150, 37,
        C.raised, C.white, Enum.Font.GothamBold, 12)
    markButton.Name = "MarkBase"
    outline(markButton, C.line)

    local statusBox = create("Frame", panel, {
        BackgroundColor3 = C.panel,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 319),
        Size = UDim2.fromOffset(308, 45),
    })
    round(statusBox, 7)
    local dot = create("Frame", statusBox, {
        BackgroundColor3 = C.mint,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(11, 12),
        Size = UDim2.fromOffset(7, 7),
    })
    round(dot, 4)
    local statusLabel = textLabel(statusBox, "Ready", 25, 5, 270, 20,
        Enum.Font.GothamMedium, 11, C.white)
    local detailLabel = textLabel(statusBox, "Base: auto  ·  Target: scanning", 11, 24,
        285, 15, Enum.Font.Gotham, 10, C.slate)

    local hotkeys = textLabel(panel, "F6 Auto    RightCtrl Hide", 13, 370,
        240, 15, Enum.Font.Gotham, 10, C.slate)
    hotkeys.TextYAlignment = Enum.TextYAlignment.Top
    local unloadButton = textButton(panel, "Unload", 265, 369, 54, 16,
        C.ink, C.slate, Enum.Font.GothamMedium, 10)
    unloadButton.Name = "Unload"
    local diagnosticsButton = textButton(panel, "Diag", 213, 369, 45, 16,
        C.ink, C.slate, Enum.Font.GothamMedium, 10)
    diagnosticsButton.Name = "Diagnostics"

    local restoreButton = textButton(gui, mainPlace and "SAB" or "DUEL", 24, 200, 66, 32,
        C.ink, C.white, Enum.Font.FredokaOne, 17)
    restoreButton.Name = "Restore"
    restoreButton.Visible = false
    outline(restoreButton, C.violet)

    local ui = { gui = gui, panel = panel }

    function ui.update()
        local auto = state.auto == true
        autoButton.Text = auto and "ON" or "OFF"
        autoButton.BackgroundColor3 = auto and C.mint or C.raised
        autoButton.TextColor3 = auto and C.ink or C.white
        autoCard.UIStroke.Color = auto and C.mint or C.line

        local enabled = state.speed == true
        speedButton.Text = enabled and "ON" or "OFF"
        speedButton.BackgroundColor3 = enabled and C.violet or C.raised
        speedButton.TextColor3 = enabled and C.ink or C.white
        local value = math.clamp(tonumber(state.speedValue) or 32, 16, 100)
        local fraction = (value - 16) / 84
        speedValueLabel.Text = tostring(math.floor(value + 0.5))
        speedFill.Size = UDim2.fromScale(fraction, 1)
        speedKnob.Position = UDim2.fromScale(fraction, 0.5)
    end

    function ui.setStatus(message)
        statusLabel.Text = tostring(message or "Ready")
        local lower = string.lower(statusLabel.Text)
        local problem = string.find(lower, "failed", 1, true)
            or string.find(lower, "miss", 1, true)
            or string.find(lower, "not found", 1, true)
            or string.find(lower, "corrected", 1, true)
            or string.find(lower, "limited", 1, true)
            or string.find(lower, "lost", 1, true)
            or string.find(lower, "rejected", 1, true)
        dot.BackgroundColor3 = problem and C.coral or C.mint
    end

    function ui.setDiagnostics(info)
        info = info or {}
        local base = info.base or (state.markedBase and "marked" or "auto")
        local target = info.target or "scanning"
        local speed = info.actualSpeed and (tostring(info.actualSpeed) .. "/"
            .. tostring(info.requestedSpeed or state.speedValue)) or (info.speed or "off")
        detailLabel.Text = "B:" .. tostring(base) .. "  T:" .. tostring(target)
            .. "  S:" .. tostring(speed)
    end

    local visible = true
    local function setVisible(show)
        visible = show
        if not show then
            local position = panel.AbsolutePosition
            restoreButton.Position = UDim2.fromOffset(position.X, position.Y)
        end
        panel.Visible = show
        restoreButton.Visible = not show
    end
    ui.setVisible = setVisible

    connect(hideButton.MouseButton1Click, function() setVisible(false) end)
    connect(restoreButton.MouseButton1Click, function() setVisible(true) end)
    connect(autoButton.MouseButton1Click, function()
        actions.setAuto(not state.auto)
        ui.update()
    end)
    connect(speedButton.MouseButton1Click, function()
        actions.setSpeed(not state.speed)
        ui.update()
    end)
    connect(returnButton.MouseButton1Click, function() actions.teleportBase() end)
    connect(markButton.MouseButton1Click, function()
        actions.markBase()
        ui.setDiagnostics()
    end)
    connect(unloadButton.MouseButton1Click, function() actions.unload() end)
    connect(diagnosticsButton.MouseButton1Click, function() actions.diagnostics() end)

    local sliding = false
    local function speedFromPointer(pointerX)
        local width = math.max(speedTrack.AbsoluteSize.X, 1)
        local fraction = math.clamp((pointerX - speedTrack.AbsolutePosition.X) / width, 0, 1)
        local value = math.floor(16 + fraction * 84 + 0.5)
        if state.speedValue ~= value then
            actions.setSpeedValue(value)
            ui.update()
        end
    end
    connect(speedTrack.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            speedFromPointer(input.Position.X)
        end
    end)
    connect(speedKnob.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = true
            speedFromPointer(input.Position.X)
        end
    end)

    local dragging = false
    local dragStart = nil
    local panelStart = nil
    connect(header.InputBegan, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            panelStart = panel.AbsolutePosition
        end
    end)

    connect(UserInputService.InputChanged, function(input)
        if sliding and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            speedFromPointer(input.Position.X)
        end
        if dragging and (input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch) then
            local delta = input.Position - dragStart
            local viewport = workspace.CurrentCamera and workspace.CurrentCamera.ViewportSize
            local x = panelStart.X + delta.X
            local y = panelStart.Y + delta.Y
            if viewport then
                x = math.clamp(x, 0, math.max(0, viewport.X - panel.AbsoluteSize.X))
                y = math.clamp(y, 0, math.max(0, viewport.Y - panel.AbsoluteSize.Y))
            end
            panel.Position = UDim2.fromOffset(x, y)
        end
    end)
    connect(UserInputService.InputEnded, function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            sliding = false
            dragging = false
        end
    end)
    connect(UserInputService.InputBegan, function(input, consumed)
        if consumed or UserInputService:GetFocusedTextBox() then return end
        if input.KeyCode == Enum.KeyCode.F6 then
            actions.setAuto(not state.auto)
            ui.update()
        elseif input.KeyCode == Enum.KeyCode.F7 then
            actions.teleportBase()
        elseif input.KeyCode == Enum.KeyCode.RightControl then
            setVisible(not visible)
        end
    end)

    function ui.destroy()
        for _, connection in ipairs(connections) do connection:Disconnect() end
        gui:Destroy()
    end

    ui.update()
    return ui
end

local setSpeedValue = speedController.setValue

state.ui = buildUI(state, {
    setAuto = setAuto,
    setSpeed = setSpeed,
    setSpeedValue = setSpeedValue,
    teleportBase = teleportBase,
    markBase = markBase,
    diagnostics = showDiagnostics,
    unload = function() state.Unload() end,
})
state.gui = state.ui.gui
state.ui.setDiagnostics(state.diagnostics)

connect(player.CharacterAdded, function()
    if state.auto then
        setAuto(false)
        setStatus("respawned; restart auto steal")
    end
end)

function state.Unload()
    if not state.alive then return end
    state.alive = false
    state.auto = false
    state.movementId = state.movementId + 1
    speedController.unload()
    for _, connection in ipairs(state.connections) do connection:Disconnect() end
    local ui = state.ui
    state.ui = nil
    if ui then ui.destroy() end
    state.gui = nil
    if env.BrainrotXeno == state then env.BrainrotXeno = nil end
    print("[Brainrot Xeno] unloaded")
end

setStatus("ready; F6 auto, F7 return, RightCtrl hide")
