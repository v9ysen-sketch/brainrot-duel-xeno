-- Steal a Brainrot and its Duel Server (universe 7709344486) / Xeno
-- Paste the whole file into Xeno. No HTTP requests or remote code are used.
-- Client movement and prompt calls still depend on the game's server rules.

if game.PlaceId ~= 109983668079237 and game.PlaceId ~= 99606176102979
    and game.GameId ~= 7709344486 then
    warn("[Brainrot Xeno] This script is for Steal a Brainrot / Duel Server only.")
    return
end

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
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
    carrySpeedValue = 24,
    originalSpeed = nil,
    originalHumanoid = nil,
    movementId = 0,
    connections = {},
    attempted = setmetatable({}, { __mode = "k" }),
    gui = nil,
    ui = nil,
    markedBase = nil,
    markedHitbox = nil,
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
    return owner == player.UserId or owner == player.Name or owner == tostring(player.UserId)
end

local function ownPlot()
    plots = workspace:FindFirstChild("Plots")
    if not plots then return nil end
    for _, plot in ipairs(plots:GetChildren()) do
        if ownsPlot(plot) then return plot end
    end
    if state.markedBase then
        for _, plot in ipairs(plots:GetChildren()) do
            local hitbox = plot:FindFirstChild("DeliveryHitbox", true)
            if hitbox and hitbox:IsA("BasePart")
                and (hitbox.Position - state.markedBase).Magnitude <= 10 then
                return plot
            end
        end
    end
    return nil
end

local function animalSnapshot(plot)
    local channel = plotChannel(plot)
    if not channel then return nil end
    local ok, list = pcall(function() return channel:Get("AnimalList") end)
    if not ok or type(list) ~= "table" then return nil end
    local snapshot = {}
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
        end
    end
    return snapshot
end

local function animalListChanged(before, plot)
    if not before then return nil end
    local current = animalSnapshot(plot)
    if not current then return nil end
    for slot, signature in pairs(current) do
        if before[slot] ~= signature then return true end
    end
    return false
end

local function carrying()
    return player:GetAttribute("Stealing") == true
end

local function carrySignalAvailable()
    return player:GetAttributes().Stealing ~= nil
end

local function waitForCarry(timeout, id)
    local deadline = os.clock() + timeout
    while state.alive and state.movementId == id do
        if carrying() then return true end
        if os.clock() >= deadline then break end
        task.wait(0.05)
    end
    return false
end

local function deliveryResult(before, plot, timeout, id)
    local deadline = os.clock() + timeout
    local carryStopped = false
    local seenCarry = carrying()
    while state.alive and state.movementId == id and os.clock() < deadline do
        if carrying() then
            seenCarry = true
        elseif seenCarry then
            carryStopped = true
            local changed = animalListChanged(before, plot)
            if changed == true then return "confirmed" end
        end
        task.wait(0.05)
    end
    if not state.alive or state.movementId ~= id then return "cancelled" end
    if carryStopped then return before and plot and "lost" or "unknown" end
    return seenCarry and "carrying" or "unknown"
end

local function deliveryPart()
    if state.markedHitbox and state.markedHitbox.Parent then
        return state.markedHitbox
    end
    local plot = ownPlot()
    if plot then
        local hitbox = plot:FindFirstChild("DeliveryHitbox", true)
        if hitbox and hitbox:IsA("BasePart") then return hitbox end
    end
    return nil
end

local function deliveryHitbox()
    if state.markedBase then return state.markedBase end
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
    return pcall(function()
        firetouchinterest(root, hitbox, 0)
        task.wait()
        firetouchinterest(root, hitbox, 1)
    end)
end

local function tryDeliveryRemote()
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

local function podiumPrompt(podium)
    local base = podium:FindFirstChild("Base")
    local spawn = base and base:FindFirstChild("Spawn")
    local attachment = spawn and spawn:FindFirstChild("PromptAttachment")
    local prompt = attachment and attachment:FindFirstChildOfClass("ProximityPrompt")
    if prompt and prompt.Enabled then return prompt end
    return nil
end

local function isStealPrompt(prompt)
    if not prompt or not prompt.Enabled then return false end
    local action = string.lower(prompt.ActionText or "")
    local phase = string.lower(tostring(prompt:GetAttribute("State") or ""))
    return string.find(action, "steal", 1, true) ~= nil
        or string.find(phase, "steal", 1, true) ~= nil
end

local function nearestTarget()
    local _, _, root = characterParts()
    if not root then return nil end
    local own = ownPlot()
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
    local speed = math.max(humanoid.WalkSpeed, 12)
    local timeout = os.clock() + math.clamp(distance / speed * 2 + 2, 2, 12)
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

local function shortTeleport(position, maxDistance)
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
    local _, _, currentRoot = characterParts()
    if not currentRoot then return false end
    local accepted = (currentRoot.Position - destination).Magnitude <= maxDistance
    if not accepted then
        pcall(function() currentRoot.AssemblyLinearVelocity = oldVelocity end)
    end
    return accepted
end

local function replayPromptCallbacks(prompt)
    if type(getconnections) ~= "function" then return false end
    local replayed = false
    for _, signal in ipairs({
        prompt.PromptButtonHoldBegan,
        prompt.Triggered,
        prompt.PromptButtonHoldEnded,
    }) do
        local ok, list = pcall(getconnections, signal)
        if ok and type(list) == "table" then
            for _, connection in ipairs(list) do
                local got, callback = pcall(function() return connection.Function end)
                if got and type(callback) == "function" then
                    replayed = pcall(callback, player) or replayed
                end
            end
        end
    end
    return replayed
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
    local replayed = false
    if not carrying() and movementActive(id) then
        replayed = replayPromptCallbacks(prompt)
    end
    return triggered or replayed
end

local function attemptDelivery(basePosition, before, plot, id)
    if not movementActive(id) then return "cancelled" end
    if carrying() then
        setStatus("trying delivery remote")
        if tryDeliveryRemote() then
            local result = deliveryResult(before, plot, 1.2, id)
            if result ~= "carrying" then return result end
        end
        if not movementActive(id) then return "cancelled" end
        setStatus("trying delivery pad event")
        if tryDeliveryTouch() then
            local result = deliveryResult(before, plot, 1.2, id)
            if result ~= "carrying" then return result end
        end
    end
    if not movementActive(id) then return "cancelled" end
    setStatus("teleporting to own base")
    local accepted = shortTeleport(basePosition, 3.5)
    if not movementActive(id) then return "cancelled" end
    if not carrySignalAvailable() then
        if not accepted and movementActive(id) then
            setStatus("server corrected teleport; walking to base")
            walkTo(basePosition, id, 3.5)
        end
        return "unknown"
    end
    local result = deliveryResult(before, plot, 1.5, id)
    if result ~= "carrying" then return result end
    if accepted and movementActive(id) then
        local _, humanoid = characterParts()
        if humanoid then humanoid:MoveTo(basePosition) end
        result = deliveryResult(before, plot, 1, id)
        if result ~= "carrying" then return result end
    end
    if not accepted and movementActive(id) then
        setStatus("server corrected teleport; walking to base")
        walkTo(basePosition, id, 3.5)
        result = deliveryResult(before, plot, 2, id)
    end
    return result
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
                local before = animalSnapshot(plot)
                if carrying() then
                    state.diagnostics.carry = "verified"
                    state.diagnostics.target = "base"
                    local result = attemptDelivery(basePosition, before, plot, id)
                    if not movementActive(id) then break end
                    state.diagnostics.delivery = result
                    setStatus("delivery: " .. result)
                    task.wait(0.5)
                else
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
                            if hasCarry or (triggered and not carrySignalAvailable()) then
                                state.diagnostics.carry = hasCarry and "verified" or "unverified"
                                local result = attemptDelivery(basePosition, before, plot, id)
                                if not movementActive(id) then break end
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

local function setSpeed(enabled)
    state.speed = enabled
    local _, humanoid = characterParts()
    if enabled and humanoid then
        if state.originalHumanoid ~= humanoid then
            state.originalHumanoid = humanoid
            state.originalSpeed = humanoid.WalkSpeed
        end
        humanoid.WalkSpeed = carrying() and math.min(state.speedValue, state.carrySpeedValue)
            or state.speedValue
    elseif not enabled and state.originalHumanoid and state.originalHumanoid.Parent then
        pcall(function()
            state.originalHumanoid.WalkSpeed = state.originalSpeed or 16
        end)
        state.originalHumanoid = nil
        state.originalSpeed = nil
    end
    if state.ui then state.ui.update() end
    setStatus(enabled and ("speed " .. state.speedValue) or "speed off")
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
        setStatus("teleporting to base")
        local accepted = shortTeleport(basePosition, 3.5)
        if not movementActive(id) then return end
        if accepted then
            setStatus("base reached")
            return
        end
        -- Server correction: use character movement from the corrected position.
        if not movementActive(id) then return end
        setStatus("server corrected teleport; walking to base")
        local reached = walkTo(basePosition, id, 3.5)
        if movementActive(id) then
            setStatus(reached and "base reached" or "base route failed")
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
    state.markedHitbox = nearest
    state.markedBase = nearest and nearest.Position or root.Position - Vector3.new(0, 2, 0)
    state.diagnostics.base = nearest and "own pad" or "manual spot"
    setStatus(nearest and "own delivery pad marked" or "current spot marked as base")
end

local function buildUI(state, actions)
    local Players = game:GetService("Players")
    local UserInputService = game:GetService("UserInputService")
    local CoreGui = game:GetService("CoreGui")
    local player = Players.LocalPlayer

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
        Name = "BrainrotDuelUI",
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
        Name = "DuelPanel",
        Active = true,
        BackgroundColor3 = C.ink,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 28, 0.5, -196),
        Size = UDim2.fromOffset(332, 392),
    })
    round(panel, 13)
    outline(panel, C.line)

    -- A scoreboard header gives the panel a recognizable 1v1 silhouette.
    local header = create("Frame", panel, {
        Active = true,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 0),
        Size = UDim2.fromOffset(332, 104),
    })
    textLabel(header, "DUEL", 16, 11, 165, 39, Enum.Font.FredokaOne, 31, C.white)
    textLabel(header, "Steal a Brainrot", 17, 49, 182, 21, Enum.Font.GothamMedium, 12, C.slate)
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
    local rivalLabel = textLabel(header, "Rival", 250, 66, 66, 15,
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

    local restoreButton = textButton(gui, "DUEL", 24, 200, 66, 32,
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
        dot.BackgroundColor3 = problem and C.coral or C.mint
    end

    function ui.setDiagnostics(info)
        info = info or {}
        local base = info.base or (state.markedBase and "marked" or "auto")
        local target = info.target or "scanning"
        detailLabel.Text = "Base: " .. tostring(base) .. "  ·  Target: " .. tostring(target)
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

local function setSpeedValue(value)
    state.speedValue = math.clamp(math.floor(tonumber(value) or state.speedValue), 16, 100)
    if state.speed then
        local _, humanoid = characterParts()
        if humanoid then
            humanoid.WalkSpeed = carrying() and math.min(state.speedValue, state.carrySpeedValue)
                or state.speedValue
        end
    end
    if state.ui then state.ui.update() end
end

state.ui = buildUI(state, {
    setAuto = setAuto,
    setSpeed = setSpeed,
    setSpeedValue = setSpeedValue,
    teleportBase = teleportBase,
    markBase = markBase,
    unload = function() state.Unload() end,
})
state.gui = state.ui.gui
state.ui.setDiagnostics(state.diagnostics)

connect(player.CharacterAdded, function()
    state.originalHumanoid = nil
    state.originalSpeed = nil
    if state.auto then
        setAuto(false)
        setStatus("respawned; restart auto steal")
    end
end)

task.spawn(function()
    while state.alive do
        if state.speed then
            local _, humanoid = characterParts()
            if humanoid then
                if state.originalHumanoid ~= humanoid then
                    state.originalHumanoid = humanoid
                    state.originalSpeed = humanoid.WalkSpeed
                end
                local wanted = carrying() and math.min(state.speedValue, state.carrySpeedValue)
                    or state.speedValue
                if humanoid.WalkSpeed ~= wanted then
                    humanoid.WalkSpeed = wanted
                end
            end
        end
        task.wait(0.2)
    end
end)

function state.Unload()
    if not state.alive then return end
    state.alive = false
    state.auto = false
    state.movementId = state.movementId + 1
    if state.originalHumanoid and state.originalHumanoid.Parent then
        pcall(function() state.originalHumanoid.WalkSpeed = state.originalSpeed or 16 end)
    end
    for _, connection in ipairs(state.connections) do connection:Disconnect() end
    local ui = state.ui
    state.ui = nil
    if ui then ui.destroy() end
    state.gui = nil
    if env.BrainrotXeno == state then env.BrainrotXeno = nil end
    print("[Brainrot Xeno] unloaded")
end

setStatus("ready; F6 auto, F7 return, RightCtrl hide")
