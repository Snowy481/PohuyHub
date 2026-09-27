local SL2_CLEANUPS = rawget(_G, "SL2_CLEANUPS")
if type(SL2_CLEANUPS) ~= "table" then
    SL2_CLEANUPS = {}
    rawset(_G, "SL2_CLEANUPS", SL2_CLEANUPS)
end

local function OnUnload(fn)
    if type(fn) == "function" then
        SL2_CLEANUPS[#SL2_CLEANUPS + 1] = fn
    end
end

local previousUnload = rawget(_G, "SL2_Unload")
if type(previousUnload) == "function" then
    pcall(previousUnload)
end

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local CollectionService = game:GetService("CollectionService")
local VirtualInputManager = game:GetService("VirtualInputManager")
local CoreGui = game:GetService("CoreGui")

local LocalPlayer = Players.LocalPlayer

local requireCache = {}

local function RequireCached(key, getter)
    local hit = requireCache[key]
    if hit ~= nil then
        return hit or nil
    end
    local ok, mod = pcall(getter)
    requireCache[key] = (ok and typeof(mod) == "table") and mod or false
    return requireCache[key] or nil
end

do

    local NPC_FOLDER_PATH = { "Humanoids", "Regions" }

    local function GetRegionsRoot()
        local humanoids = workspace:FindFirstChild("Humanoids")
        return humanoids and humanoids:FindFirstChild("Regions") or nil
    end

    local function GetAliveMobs()
        local result = {}
        local regions = GetRegionsRoot()
        if not regions then
            return result
        end

        for _, region in ipairs(regions:GetChildren()) do
            local active = region:FindFirstChild("ActiveNpcs")
            if active then
                for _, controller in ipairs(active:GetChildren()) do

                    local body = controller:FindFirstChild(controller.Name)
                    if not body or not body:IsA("Model") then
                        body = nil
                        for _, child in ipairs(controller:GetChildren()) do
                            if child:IsA("Model") then
                                body = child
                                break
                            end
                        end
                    end

                    if body then
                        local humanoid = body:FindFirstChildOfClass("Humanoid")
                        local root = body:FindFirstChild("HumanoidRootPart")

                        if humanoid and root and humanoid.Health > 0 then
                            result[#result + 1] = {
                                Name = controller.Name,
                                Model = body,
                                Humanoid = humanoid,
                                Root = root,
                                Region = region.Name,
                                Path = body:GetFullName(),
                            }
                        end
                    end
                end
            end
        end

        return result
    end

    local function Normalize(text)
        if type(text) ~= "string" then
            return ""
        end
        return (string.gsub(string.lower(text), "%s+", ""))
    end

    local function NameMatches(candidate, pattern)
        if type(candidate) ~= "string" or type(pattern) ~= "string" then
            return false
        end
        if pattern == "" then
            return true
        end
        return string.find(Normalize(candidate), Normalize(pattern), 1, true) ~= nil
    end

    local function FindClosestMob(filter)
        local character = LocalPlayer.Character
        local myRoot = character and character:FindFirstChild("HumanoidRootPart")
        if not myRoot then
            return nil
        end

        local best, bestDistance
        for _, mob in ipairs(GetAliveMobs()) do
            if filter == nil or filter == "" or NameMatches(mob.Name, filter) then
                local distance = (mob.Root.Position - myRoot.Position).Magnitude
                if not best or distance < bestDistance then
                    best, bestDistance = mob, distance
                end
            end
        end
        return best, bestDistance
    end

    local function GetBruteForceModels()
        local found = {}
        for _, descendant in ipairs(workspace:GetDescendants()) do
            if descendant:IsA("Model") then
                local humanoid = descendant:FindFirstChildOfClass("Humanoid")
                local root = descendant:FindFirstChild("HumanoidRootPart")
                if humanoid and root and humanoid.Health > 0 then
                    if Players:GetPlayerFromCharacter(descendant) == nil
                        and descendant ~= LocalPlayer.Character then
                        found[#found + 1] = descendant
                    end
                end
            end
        end
        return found
    end

    local function VerifyMobCoverage()
        local mobs = GetAliveMobs()
        local byName = {}
        for _, mob in ipairs(mobs) do
            byName[mob.Name] = (byName[mob.Name] or 0) + 1
        end

        local brute = GetBruteForceModels()
        local missing, extra = {}, {}
        local bruteNames = {}

        for _, model in ipairs(brute) do
            bruteNames[model.Name] = (bruteNames[model.Name] or 0) + 1
        end
        for name in pairs(bruteNames) do
            if not byName[name] then
                missing[#missing + 1] = name
            end
        end
        for name in pairs(byName) do
            if not bruteNames[name] then
                extra[#extra + 1] = name
            end
        end
        table.sort(missing)
        table.sort(extra)

        return {
            viaRegistry = #mobs,
            viaBruteForce = #brute,
            match = #mobs == #brute and #missing == 0 and #extra == 0,
            missingFromRegistry = missing,
            phantomInRegistry = extra,
            byRegion = (function()
                local counts = {}
                for _, mob in ipairs(mobs) do
                    counts[mob.Region] = (counts[mob.Region] or 0) + 1
                end
                return counts
            end)(),
        }
    end

    local function GetNpcRoster()
        local seen = {}
        local roster = {}
        local regions = GetRegionsRoot()
        if not regions then
            return roster
        end

        for _, region in ipairs(regions:GetChildren()) do
            local active = region:FindFirstChild("ActiveNpcs")
            if active then
                for _, controller in ipairs(active:GetChildren()) do
                    local key = region.Name .. "/" .. controller.Name
                    if not seen[key] then
                        seen[key] = true
                        roster[#roster + 1] = {
                            name = controller.Name,
                            region = region.Name,
                        }
                    end
                end
            end
        end

        table.sort(roster, function(a, b)
            if a.name == b.name then
                return a.region < b.region
            end
            return a.name < b.name
        end)
        return roster
    end

    local function GetSpawnableNpcNames()
        local alive = {}
        for _, mob in ipairs(GetAliveMobs()) do
            alive[mob.Name] = true
        end

        local known = {}
        for _, entry in ipairs(GetNpcRoster()) do
            local name = entry.name
            local isService = string.sub(name, 1, 1) == "*"
                or string.sub(name, -1) == "*"
            if not isService then
                known[name] = alive[name] == true
            end
        end
        return known
    end

    local function GetBossList()
        local result = {}
        local ok, tagged = pcall(function()
            return CollectionService:GetTagged("BossTag")
        end)
        if not ok then
            return result
        end
        for _, info in ipairs(tagged) do
            local code = info:GetAttribute("NpcCode")
            if type(code) == "string" and code ~= "" then
                result[#result + 1] = {
                    Name = code,
                    Title = info:GetAttribute("Title"),
                    Chest = info:GetAttribute("Chest"),
                    Center = info:GetAttribute("Center"),
                    SpawnTime = info:GetAttribute("SpawnTime"),
                }
            end
        end
        table.sort(result, function(a, b) return a.Name < b.Name end)
        return result
    end

    local function IsBossName(name)
        if type(name) ~= "string" or name == "" then
            return false
        end
        for _, boss in ipairs(GetBossList()) do
            if boss.Name == name then
                return true
            end
        end
        return false
    end

    local function GetNormalMobRoster()
        local alive = {}
        for _, mob in ipairs(GetAliveMobs()) do
            alive[mob.Name] = true
        end

        local seen = {}
        local result = {}
        for _, entry in ipairs(GetNpcRoster()) do
            local name = entry.name
            local isService = string.sub(name, 1, 1) == "*"
                or string.sub(name, -1) == "*"
            if not isService and not seen[name] and not IsBossName(name) then
                seen[name] = true
                result[#result + 1] = {
                    name = name,
                    region = entry.region,
                    alive = alive[name] == true,
                }
            end
        end
        table.sort(result, function(a, b) return a.name < b.name end)
        return result
    end

    local function GetSpawnableBosses()
        local registered = {}
        for _, entry in ipairs(GetNpcRoster()) do
            registered[entry.name] = true
        end
        local alive = {}
        for _, mob in ipairs(GetAliveMobs()) do
            alive[mob.Name] = true
        end

        local result = {}
        for _, boss in ipairs(GetBossList()) do
            result[#result + 1] = {
                Name = boss.Name,
                Title = boss.Title,
                Chest = boss.Chest,
                Center = boss.Center,
                registered = registered[boss.Name] == true,
                alive = alive[boss.Name] == true,
            }
        end
        return result
    end

    local function GetBossHunts()
        local result = {}
        local folder = ReplicatedStorage:FindFirstChild("BossHunts")
        if not folder then
            return result
        end
        for _, entry in ipairs(folder:GetChildren()) do
            local boss = entry:GetAttribute("Boss")
            if type(boss) == "string" and boss ~= "" then
                result[#result + 1] = {
                    Id = entry.Name,
                    Boss = boss,
                    Quest = entry:GetAttribute("Quest"),
                    Side = entry:GetAttribute("Side"),
                    Tier = entry:GetAttribute("Tier"),
                    ExpiresAt = entry:GetAttribute("ExpiresAt"),
                }
            end
        end
        table.sort(result, function(a, b)
            return (a.Tier or "") < (b.Tier or "")
        end)
        return result
    end

    local function HuntLabel(hunt)
        return string.format("%s - %s (%s)", hunt.Boss, tostring(hunt.Tier), hunt.Id)
    end

    local function GetRegionsTable()
        return RequireCached("GetRegionsTable", function()
            return require(ReplicatedStorage:FindFirstChild("Regions"))
        end)
    end

    local function GetNpcSpawnPoint(name)
        if type(name) ~= "string" or name == "" then
            return nil
        end
        local regions = GetRegionsTable()
        if not regions or type(regions.NpcSpawns) ~= "table" then
            return nil
        end
        local point = regions.NpcSpawns[name]
        if typeof(point) == "Vector3" then
            return point
        end
        return nil
    end

    local function GetSpawnPointCoverage()
        local regions = GetRegionsTable()
        if not regions or type(regions.NpcSpawns) ~= "table" then
            return { available = false, total = 0 }
        end
        local total = 0
        local covered = {}
        for name, value in pairs(regions.NpcSpawns) do
            if typeof(value) == "Vector3" then
                total = total + 1
                covered[name] = true
            end
        end
        return { available = true, total = total, names = covered }
    end

    local Settings = {
        Position = "Overhead (Safe - Recommended)",
        Distance = 2.0,
        Height = 2.5,

        LockTarget = true,

        AutoLoad = true,

        AutoLoadCooldown = 3.0,

        AutoSkills = true,

        AutoEquip = false,
        EquipItem = "",

        InstantKill = false,

        KillThreshold = 10,

        WaitLoot = false,

        LootWait = 4.0,

        AutoOpenChest = true,

        AutoCollectDrop = true,

        FarmMethod = "VirtualInput",

        MultiHitCount = 1,

        AttackInterval = 0.28,
        LastAttackAt = 0,

        ESPPlayers = false,
        ESPMobs = false,

        ESPHighlight = true,
        ESPBoxes = false,
        ESPNames = false,

        ESPColorPlayers = Color3.fromRGB(96, 200, 255),
        ESPColorMobs = Color3.fromRGB(255, 96, 96),

        MovementInfStamina = false,

        MovementInfDashes = false,

        MovementInfJumps = false,

        MovementNoclip = false,
        MovementFly = false,

        MovementFlySpeed = 70,

        ESPDistance = 1500.0,

        AutoSkills = true,

        SkillInterval = 1.0,
        LastSkillAt = 0,
        HoverNpc = nil,
    }

    local EXPORTS = {
        Settings = Settings,
        GetRegionsRoot = GetRegionsRoot,
        GetAliveMobs = GetAliveMobs,
        FindClosestMob = FindClosestMob,
        NameMatches = NameMatches,
        Normalize = Normalize,
        VerifyMobCoverage = VerifyMobCoverage,
        GetBruteForceModels = GetBruteForceModels,
        GetNpcRoster = GetNpcRoster,
        GetSpawnableNpcNames = GetSpawnableNpcNames,
        GetBossList = GetBossList,
        GetSpawnableBosses = GetSpawnableBosses,
        IsBossName = IsBossName,
        GetNormalMobRoster = GetNormalMobRoster,
        GetBossHunts = GetBossHunts,
        HuntLabel = HuntLabel,
        GetRegionsTable = GetRegionsTable,
        GetNpcSpawnPoint = GetNpcSpawnPoint,
        GetSpawnPointCoverage = GetSpawnPointCoverage,
    }

    _G.Core = _G.Core or {}
    for name, value in pairs(EXPORTS) do
        _G.Core[name] = value
    end

end

local Core = _G.Core
if type(Core) ~= "table" then
    error("core_world.luau не выполнился: нет _G.Core")
end

local Settings = Core.Settings
if type(Settings) ~= "table" then
    error("core_world.luau не выполнился: нет _G.Core.Settings")
end

do

    local function GetRootPart()
        local character = LocalPlayer.Character
        return character and character:FindFirstChild("HumanoidRootPart") or nil
    end

    local function SafeDestination(point)
        return point + Vector3.new(0, 3, 0)
    end

    local function LookHorizontal(destination, lookAtPoint)
        local flat = Vector3.new(lookAtPoint.X, destination.Y, lookAtPoint.Z)
        if (flat - destination).Magnitude < 0.01 then
            return CFrame.new(destination) * CFrame.Angles(0, 0, 0)
        end
        return CFrame.new(destination, flat)
    end

    local function TeleportTo(point, lookAtPoint, heightOffset)
        local root = GetRootPart()
        if not root or not point then
            return false, "no character or no point"
        end
        local destination = point + Vector3.new(0, heightOffset or 0, 0)
        local cframe = (lookAtPoint and CFrame.new(destination, lookAtPoint))
            or (destination * root.CFrame.Rotation)
        root.CFrame = cframe
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        return true, destination
    end

    local function NameKey(value)
        if type(value) ~= "string" then
            return nil
        end
        local key = string.lower(value):gsub("[^%a%d]", "")
        if key == "" then
            return nil
        end
        return key
    end

    local function MatchNpcName(requested, candidates)
        local key = NameKey(requested)
        if not key then
            return nil
        end

        for _, candidate in ipairs(candidates) do
            if NameKey(candidate) == key then
                return candidate
            end
        end

        for _, candidate in ipairs(candidates) do
            local other = NameKey(candidate)
            if other then
                if string.sub(other, 1, #key) == key
                    or string.sub(key, 1, #other) == other then
                    return candidate
                end
            end
        end
        return nil
    end

    local function RegistryRegionMap()
        local map = {}
        local regionsFolder = workspace:FindFirstChild("Humanoids")
        regionsFolder = regionsFolder and regionsFolder:FindFirstChild("Regions")
        if not regionsFolder then
            return map
        end
        for _, region in ipairs(regionsFolder:GetChildren()) do
            local active = region:FindFirstChild("ActiveNpcs")
            if active then
                for _, entry in ipairs(active:GetChildren()) do
                    map[tostring(entry.Name)] = tostring(region.Name)
                end
            end
        end
        return map
    end

    local function RegionHopTarget(name)
        local map = RegistryRegionMap()
        if next(map) == nil then
            return nil, nil
        end

        local names = {}
        for key in pairs(map) do
            names[#names + 1] = key
        end
        local realName = MatchNpcName(name, names)
        if not realName then
            return nil, nil
        end
        local regionOf = map[realName]
        if not regionOf then
            return nil, nil
        end

        local alive = _G.Core.GetAliveMobs()
        local best, bestDistance
        for _, mob in ipairs(alive) do
            local matched = MatchNpcName(mob.Name, names)
            local mobRegion = matched and map[matched] or nil
            if mobRegion == regionOf and mob.Root then
                local distance = mob.Root.Position.Magnitude
                if not bestDistance or distance < bestDistance then
                    best, bestDistance = mob, distance
                end
            end
        end
        if not best then
            return nil, nil
        end
        return best.Root.Position, best.Name
    end

    local function FindNpcTarget(name)
        if type(name) ~= "string" or name == "" then
            return nil
        end

        local alive = _G.Core.GetAliveMobs()
        for _, mob in ipairs(alive) do
            if mob.Name == name then
                return { point = mob.Root.Position, source = "body", mob = mob }
            end
        end

        local spawnPoint = _G.Core.GetNpcSpawnPoint(name)
        if spawnPoint then
            return { point = spawnPoint, source = "spawn" }
        end

        local candidates = {}
        local regions = _G.Core.GetRegionsTable()
        if type(regions) == "table" and type(regions.NpcSpawns) == "table" then
            for key in pairs(regions.NpcSpawns) do
                candidates[#candidates + 1] = tostring(key)
            end
        end
        for _, entry in ipairs(_G.Core.GetNormalMobRoster()) do
            candidates[#candidates + 1] = entry.name
        end
        for _, boss in ipairs(_G.Core.GetBossList()) do
            candidates[#candidates + 1] = boss.Name
        end

        local matched = MatchNpcName(name, candidates)
        if matched and matched ~= name then
            for _, mob in ipairs(alive) do
                if mob.Name == matched then
                    return {
                        point = mob.Root.Position,
                        source = "body-normalized",
                        mob = mob,
                        matched = matched,
                    }
                end
            end
            local point = _G.Core.GetNpcSpawnPoint(matched)
            if point then
                return {
                    point = point,
                    source = "spawn-normalized",
                    matched = matched,
                }
            end
        end

        local hopPoint, hopVia = RegionHopTarget(name)
        if hopPoint then
            return {
                point = hopPoint,
                source = "region-hop",
                matched = hopVia,
            }
        end

        return nil
    end

    local function NormalizePosition(position)
        local value = type(position) == "string" and position or ""

        if string.find(value, "Behind", 1, true) then
            return "Behind"
        end

        if string.find(value, "In Front", 1, true) then
            return "Behind"
        end
        if string.find(value, "Underground", 1, true)
            or string.find(value, "Below", 1, true) then
            return "Underground"
        end
        return "Overhead"
    end

    local function GetCombatOffset(position, targetPosition, distance, targetFacing)
        distance = distance or 2.0
        local mode = NormalizePosition(position)
        local mode = NormalizePosition(position)

        if mode == "Behind" then

            local flat = targetFacing and Vector3.new(targetFacing.X, 0, targetFacing.Z)
                or Vector3.new(0, 0, 1)
            if flat.Magnitude > 0.001 then
                flat = flat.Unit
            else
                flat = Vector3.new(0, 0, 1)
            end
            return -flat * distance
        end

        if mode == "Underground" then
            return Vector3.new(0, -distance, 0)
        end

        return Vector3.new(0, distance, 0)
    end

    local function GetTargetFacing(target)
        if target.mob and target.mob.Model then
            local ok, facing = pcall(function()
                return target.mob.Model:GetPivot().LookVector
            end)
            if ok then
                return facing
            end
        end
        return nil
    end

    local function HoverNpc(name)
        local target = FindNpcTarget(name)
        if not target then
            return {
                name = name,
                ok = false,
                reason = "no live body, no spawn point, no region hop",
            }
        end

        local root = GetRootPart()
        if not root then
            return { name = name, ok = false, reason = "no character" }
        end

        local mode = NormalizePosition(Settings.Position)
        local offset = GetCombatOffset(mode, target.point,
            Settings.Distance or 2.0, GetTargetFacing(target))

        local desired = target.point + offset

        local cframe
        if mode == "Behind" then

            cframe = LookHorizontal(desired, target.point)
        else
            cframe = CFrame.new(desired, target.point)
        end

        root.CFrame = cframe
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero

        Settings.HoverNpc = name
        return {
            name = name,
            ok = true,
            source = target.source,
            position = mode,
            distance = Settings.Distance,
            deviation = (root.Position - target.point).Magnitude,
            target = target.point,

            humanoid = target.mob and target.mob.Humanoid or nil,
        }
    end

    local function PickHuntTarget()

        local questModule = _G.Core.Quest
        if questModule and type(questModule.GetActiveHuntTarget) == "function" then
            local questTarget = questModule.GetActiveHuntTarget()
            if questTarget then
                local target = FindNpcTarget(questTarget.Boss)
                if target then
                    return questTarget, string.format("quest: %s (%s)",
                        questTarget.Boss, tostring(target.source))
                end
            end
        end

        local hunts = _G.Core.GetBossHunts()
        if #hunts == 0 then
            return nil, "no active hunts"
        end

        local root = GetRootPart()
        local myPosition = root and root.Position or Vector3.zero

        local aliveBestDistance, spawnBestDistance
        local aliveHunt, spawnHunt

        for _, hunt in ipairs(hunts) do
            local target = FindNpcTarget(hunt.Boss)
            if target then
                local distance = (target.point - myPosition).Magnitude
                if target.source == "body" then
                    if not aliveHunt or distance < aliveBestDistance then
                        aliveBestDistance, aliveHunt = distance, hunt
                    end
                else
                    if not spawnHunt or distance < spawnBestDistance then
                        spawnBestDistance, spawnHunt = distance, hunt
                    end
                end
            end
        end

        if aliveHunt then
            return aliveHunt, string.format("alive: %s (%.0fm)",
                aliveHunt.Boss, aliveBestDistance)
        end
        if spawnHunt then
            return spawnHunt, string.format("to spawn: %s (%.0fm)",
                spawnHunt.Boss, spawnBestDistance)
        end
        return nil, string.format("%d hunt(s), none reachable", #hunts)
    end

    local function TeleportToNpc(name)
        local target = FindNpcTarget(name)
        if not target then
            return {
                name = name,
                ok = false,
                reason = "no live body, no spawn point, no region hop",
            }
        end
        local moved, result = TeleportTo(SafeDestination(target.point), target.point)
        return {
            name = name,
            ok = moved and true or false,
            source = target.source,
            point = target.point,
            reason = moved and nil or tostring(result),
        }
    end

    local function TeleportToNpcs(names, mode)
        local results = {}
        local list = {}
        for _, name in ipairs(names or {}) do
            list[#list + 1] = name
        end

        for _, name in ipairs(list) do
            local result = mode == "all" and TeleportToNpc(name) or HoverNpc(name)
            results[#results + 1] = result
            if result.ok and mode ~= "all" then
                break
            end
        end
        return results
    end

    local EXPORTS = {
        Settings = Settings,
        TeleportTo = TeleportTo,
        HoverNpc = HoverNpc,
        TeleportToNpc = TeleportToNpc,
        TeleportToNpcs = TeleportToNpcs,
        FindNpcTarget = FindNpcTarget,
        PickHuntTarget = PickHuntTarget,
        SafeDestination = SafeDestination,
        GetRootPart = GetRootPart,
        GetCombatOffset = GetCombatOffset,
        NormalizePosition = NormalizePosition,
    }

    _G.Core = _G.Core or {}
    for name, value in pairs(EXPORTS) do
        _G.Core[name] = value
    end

end

do

    local combatPresets
    local collectibleItems
    local characterInfo

    local function GetSignalEvent()
        return RequireCached("GetSignalEvent", function()
            return require(ReplicatedStorage.Communication.ServerAndClient.Signals.SignalEvent)
        end)
    end

    local function GetInputHandler()
        return RequireCached("GetInputHandler", function()
            return require(ReplicatedStorage.CAM.Client.Components.Client.InputHandler)
        end)
    end

    local function GetCombatPresets()
        if combatPresets == nil then
            pcall(function()
                combatPresets = require(ReplicatedStorage.CAM.Global.Combat_presets).Presets
            end)
        end
        return combatPresets
    end

    local function GetCollectibleItems()
        if collectibleItems == nil then
            pcall(function()
                collectibleItems = require(ReplicatedStorage.CAM.Global.Collectibles.Items)
            end)
        end
        return collectibleItems
    end

    local function GetCharacterInfo()
        if characterInfo == nil then
            pcall(function()
                characterInfo = require(ReplicatedStorage.CAM.Global.Character_info_provider)
            end)
        end
        return characterInfo
    end

    local function ResolveCombatWeapon()
        local ok, weapon = pcall(function()
            local info = GetCharacterInfo()
            if not info or type(info.Get_equipped_tool) ~= "function" then
                return "Regular Katana"
            end
            local tool = info.Get_equipped_tool(LocalPlayer)
            if not tool then
                return "Regular Katana"
            end
            local toolName = tostring(tool.Name or "")
            local presets = GetCombatPresets()
            if presets and presets[toolName] ~= nil then
                return toolName
            end
            local items = GetCollectibleItems()
            local item = items and items[toolName]
            if item and item.CombatPreset and item.CombatPreset ~= "" then
                return item.CombatPreset
            end
            return "Regular Katana"
        end)
        return (ok and type(weapon) == "string" and weapon ~= "") and weapon or "Regular Katana"
    end

    local function GetMaxCombo(weapon)
        local maxCombo = 5
        local presets = GetCombatPresets()
        local preset = presets and presets[weapon]
        if preset and tonumber(preset.Max) then
            maxCombo = math.clamp(math.floor(tonumber(preset.Max)), 1, 10)
        end
        return maxCombo
    end

    local function CanAttack()
        local character = LocalPlayer.Character
        if not character then
            return false, "no character"
        end
        local root = character:FindFirstChild("HumanoidRootPart")
        local humanoid = character:FindFirstChildOfClass("Humanoid")
        if not root or not humanoid then
            return false, "no root or humanoid"
        end
        if humanoid.Health <= 0 then
            return false, "dead"
        end

        local state = humanoid:GetState()
        if state == Enum.HumanoidStateType.Physics
            or state == Enum.HumanoidStateType.Ragdoll
            or state == Enum.HumanoidStateType.FallingDown then
            return false, "stunned"
        end
        return true
    end

    local function CleanSwingTracks()
        local character = LocalPlayer.Character
        local humanoid = character and character:FindFirstChildOfClass("Humanoid")
        local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
        if not animator then
            return
        end
        pcall(function()
            for _, track in ipairs(animator:GetPlayingAnimationTracks()) do
                local trackName = track.Name or ""
                if string.find(trackName, "Swing")
                    or string.find(trackName, "Punch")
                    or string.find(trackName, "Slash")
                    or string.find(trackName, "React")
                then
                    pcall(function()
                        track:Stop(0)
                        track:Destroy()
                    end)
                end
            end
        end)
    end

    local function AttackVirtualInput(hits)
        local sent = 0
        for index = 1, hits do
            local handler = GetInputHandler()
            if handler and handler.VirtualPress and handler.VirtualRelease then
                local ok = pcall(function()
                    handler.VirtualPress("Combat")
                    task.wait(0.015)
                    handler.VirtualRelease("Combat")
                end)
                if ok then
                    sent = sent + 1
                end
            else
                local okMouse = pcall(function()
                    local root = LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
                    local head = LocalPlayer.Character and LocalPlayer.Character:FindFirstChild("Head")
                    local mouse = LocalPlayer:GetMouse()
                    if mouse and root and head then

                        local pressed = pcall(function()
                            VirtualInputManager:SendMouseButtonEvent(
                                600, 400, 0, true, game, 0)
                        end)
                        task.wait(0.02)
                        pcall(function()
                            VirtualInputManager:SendMouseButtonEvent(
                                600, 400, 0, false, game, 0)
                        end)
                        return pressed
                    end
                    return false
                end)
                if okMouse then
                    sent = sent + 1
                end
            end
            if hits > 1 and index < hits then
                task.wait(0.04)
            end
        end
        return sent
    end

    local function AttackEvents(hits)
        local signal = GetSignalEvent()
        if not signal or type(signal.ToServer) ~= "function" then
            return 0
        end
        local weapon = ResolveCombatWeapon()
        local maxCombo = GetMaxCombo(weapon)

        local comboCount = math.clamp(hits, 1, maxCombo)
        local sent = 0
        for pass = 1, 2 do
            for combo = 1, comboCount do
                local ok = pcall(function()
                    signal.ToServer("Combat_Service", weapon, combo,
                        false, 0.01, false, nil)
                end)
                if ok then
                    sent = sent + 1
                end
                task.wait(0.012)
            end
            if pass < 2 then
                task.wait(0.025)
            end
        end
        return sent
    end

    local function PerformAttack(hits)
        local can, reason = CanAttack()
        if not can then
            return false, reason
        end
        CleanSwingTracks()

        local count = hits or tonumber(Settings.MultiHitCount) or 1
        count = math.clamp(math.floor(tonumber(count) or 1), 1, 5)

        local method = Settings.FarmMethod or "VirtualInput"
        local sent
        if method == "Events" then
            sent = AttackEvents(count)
        else
            sent = AttackVirtualInput(count)
        end
        return sent > 0, string.format("%s: %d/%d sent", method, sent, count)
    end

    _G.Core = _G.Core or {}
    _G.Core.Combat = {
        PerformAttack = PerformAttack,
        AttackVirtualInput = AttackVirtualInput,
        AttackEvents = AttackEvents,
        ResolveCombatWeapon = ResolveCombatWeapon,
        GetMaxCombo = GetMaxCombo,
        CanAttack = CanAttack,
        CleanSwingTracks = CleanSwingTracks,
        GetSignalEvent = GetSignalEvent,
        GetInputHandler = GetInputHandler,
    }

end

do

    local function GetQuestsModule()
        return RequireCached("GetQuestsModule", function()
            return require(ReplicatedStorage.CAM.Global.Subsets.Gameplay.Quests)
        end)
    end

    local function GetBossHuntsModule()
        return RequireCached("GetBossHuntsModule", function()
            return require(ReplicatedStorage.CAM.Global.Subsets.Gameplay.Quests.BossHunts)
        end)
    end

    local function GetUtility()
        return RequireCached("GetUtility", function()
            return require(ReplicatedStorage.CAM.Global.Utility)
        end)
    end

    local function GetSignalEvent()
        return RequireCached("GetSignalEvent", function()
            return require(ReplicatedStorage.Communication.ServerAndClient.Signals.SignalEvent)
        end)
    end

    local function GetQuestDataFolder()
        local utility = GetUtility()
        if utility and type(utility.GetData) == "function" then
            local ok, slot, account = pcall(function()
                return utility.GetData(LocalPlayer, true)
            end)
            if ok then
                local fromSlot = slot and slot:FindFirstChild("Quests")
                if fromSlot then
                    return fromSlot
                end
                local fromAccount = account and account:FindFirstChild("Quests")
                if fromAccount then
                    return fromAccount
                end
            end
        end

        local data = ReplicatedStorage.Player_Service:FindFirstChild("Data")
        local mine = data and data:FindFirstChild(LocalPlayer.Name)
        if not mine then
            return nil
        end
        local slots = mine:FindFirstChild("slots")
        if not slots then
            return nil
        end
        local slotValue = mine:FindFirstChild("slotEquipped")
        local slotNum = slotValue and tostring(slotValue.Value) or "1"
        local slot = slots:FindFirstChild("Slot" .. slotNum)
            or slots:FindFirstChild(slotNum)
            or slots:GetChildren()[1]
        return slot and slot:FindFirstChild("Quests") or mine
    end

    local function NormalizeCategory(category)
        local key = string.lower(tostring(category or "")):gsub("%s+", "")
        if key == "bosshunt" or key == "bosshunts" then
            return "BossHunt"
        end
        if key == "combat" then
            return "Combat"
        end
        return tostring(category or "")
    end

    local function IsBossHuntKey(key)
        if type(key) ~= "string" or key == "" then
            return false
        end

        for _, hunt in ipairs(Core.GetBossHunts()) do
            if hunt.Quest == key or hunt.Boss == key then
                return true
            end
        end

        local module = GetBossHuntsModule()
        if module and type(module.Hunts) == "table"
            and type(module.Npc) == "function"
            and type(module.QuestName) == "function"
        then
            for _, entry in ipairs(module.Hunts) do
                local npcName = module.Npc(entry)
                if type(npcName) == "string" and module.QuestName(npcName) == key then
                    return true
                end
            end
        end
        return false
    end

    local function GetQuestCategory(questString)
        local quests = GetQuestsModule()
        local category
        if quests and type(quests.GetQuestCategory) == "function" then
            local ok, result = pcall(quests.GetQuestCategory, tostring(questString or ""))
            if ok then
                category = result
            end
        end

        local normalized = NormalizeCategory(category)
        if normalized == "BossHunt" then
            return normalized
        end
        if IsBossHuntKey(questString) then
            return "BossHunt"
        end
        if normalized ~= "" then
            return normalized
        end
        return "Combat"
    end

    local function GetActiveQuest(categoryFilter)
        local wanted = categoryFilter and NormalizeCategory(categoryFilter) or nil
        local folder = GetQuestDataFolder()
        local holder = folder and folder:FindFirstChild("Holder")
        if not holder then
            return nil
        end

        local best
        for _, quest in ipairs(holder:GetChildren()) do
            local stringValue = quest:FindFirstChild("QuestString")
            local questString = (stringValue and stringValue.Value) or quest.Name
            local category = GetQuestCategory(questString)
            if wanted and category ~= wanted then
                continue
            end

            local tasks = {}
            local allDone = true
            local hasAny = false
            local tasksFolder = quest:FindFirstChild("Tasks")
            if tasksFolder then
                for _, task in ipairs(tasksFolder:GetChildren()) do
                    hasAny = true
                    local currentValue = task:FindFirstChild("Value")
                    local maxValue = task:FindFirstChild("Max")
                    local current = currentValue and currentValue.Value or 0
                    local maximum = maxValue and maxValue.Value or 1
                    tasks[task.Name] = { Current = current, Max = maximum }
                    if current < maximum then
                        allDone = false
                    end
                end
            end

            local entry = {
                Name = quest.Name,
                QuestString = questString,
                Category = category,
                Tasks = tasks,
                HasTasks = hasAny,
                IsFinished = hasAny and allDone,
                Instance = quest,
            }
            if hasAny then
                if not allDone then
                    return entry
                end
                best = best or entry
            end
        end
        return best
    end

    local function GetQuestCooldownRemaining()
        local folder = GetQuestDataFolder()
        local lastTime = folder and folder:FindFirstChild("LastTime")
        if not lastTime or type(lastTime.Value) ~= "number" then
            return nil, false
        end
        local quests = GetQuestsModule()
        local cooldown = tonumber(quests and quests.QuestCD) or 30
        local utility = GetUtility()
        local nowTick = (utility and type(utility.Tick) == "function")
            and utility.Tick() or os.time()
        if type(nowTick) ~= "number" then
            return nil, false
        end
        return math.max(0, cooldown - (nowTick - lastTime.Value)), true
    end

    local function ClaimHuntQuest(hunt)
        if type(hunt) ~= "table" or not hunt.Boss then
            return false, "bad hunt"
        end

        if hunt.Id == nil or tostring(hunt.Id) == "nil" or tostring(hunt.Id) == "" then
            return false, "no hunt id (not in world)"
        end

        local existing = GetActiveQuest("BossHunt")
        if existing then
            if not existing.HasTasks then
                return false, "awaiting_tasks"
            end
            if existing.IsFinished then
                return false, "already_finished"
            end
            return true, "already_active"
        end

        local cooldown, known = GetQuestCooldownRemaining()
        if not known then
            return false, "cooldown_unknown"
        end
        if cooldown > 0.25 then
            return false, string.format("cooldown %.0fs", cooldown)
        end

        local quests = GetQuestsModule()
        if not quests then
            return false, "quest_module"
        end

        if type(quests.CanAddQuest) == "function" then
            local canOk, canAdd = pcall(quests.CanAddQuest, LocalPlayer, hunt.Quest)
            if canOk and canAdd == false and not IsBossHuntKey(hunt.Quest) then
                return false, "unavailable"
            end
        end

        local module = GetBossHuntsModule()
        if module and type(module.Entry) == "function" then
            local defOk, definition = pcall(module.Entry, hunt.Boss)
            if not defOk or definition == nil then
                return false, "unknown_boss"
            end
        end

        local signal = GetSignalEvent()
        if not signal or type(signal.ToServer) ~= "function" then
            return false, "no_signal"
        end

        local sent = pcall(function()
            signal.ToServer("BossHuntsRequest", {
                action = "Claim",
                id = tostring(hunt.Id),
            })
        end)
        if not sent then
            return false, "send_failed"
        end

        local deadline = os.clock() + 3.0
        while os.clock() < deadline do
            task.wait(0.1)
            local current = GetActiveQuest("BossHunt")
            if current and current.HasTasks then
                local questString = tostring(current.QuestString or "")
                if questString == tostring(hunt.Quest or "")
                    or string.find(string.lower(questString),
                        string.lower(tostring(hunt.Quest or "")), 1, true) then
                    return true, "accepted"
                end
            end
        end
        return false, "timeout"
    end

    local function GetQuestBossName(quest)
        if type(quest) ~= "table" then
            return nil
        end

        local questKey = tostring(quest.QuestString or quest.Name or "")
        local bossName = string.match(questKey, "^[Ee]liminate%s+(.+)$")
        if not bossName then
            for taskName in pairs(quest.Tasks or {}) do
                bossName = string.match(tostring(taskName), "^[Dd]efeat%s+(.+)$")
                if bossName then
                    break
                end
            end
        end
        if type(bossName) ~= "string" or bossName == "" then
            return nil
        end

        local module = GetBossHuntsModule()
        if module then
            if type(module.Entry) == "function" then
                local defOk, definition = pcall(module.Entry, bossName)
                if defOk and definition ~= nil and type(module.Npc) == "function" then
                    local npcOk, npcName = pcall(module.Npc, definition)
                    if npcOk and type(npcName) == "string" and npcName ~= "" then
                        bossName = npcName
                    end
                end
            end
            if type(module.QuestName) == "function" then
                local qOk, questName = pcall(module.QuestName, bossName)
                if qOk and type(questName) == "string" and questName ~= "" then
                    return bossName, questName
                end
            end
        end
        return bossName, questKey
    end

    local function GetActiveHuntTarget()
        local active = GetActiveQuest("BossHunt")
        if not active then
            return nil, "no hunt quest"
        end
        if not active.HasTasks then
            return nil, "awaiting_tasks"
        end
        if active.IsFinished then
            return nil, "quest finished"
        end

        local bossName, questName = GetQuestBossName(active)
        if not bossName then
            return nil, "cannot parse boss from " .. tostring(active.QuestString)
        end

        local target = {
            Boss = bossName,
            Quest = questName or tostring(active.QuestString or ""),
            FromQuest = true,
        }

        for _, hunt in ipairs(Core.GetBossHunts()) do
            if hunt.Boss == bossName or hunt.Quest == target.Quest then
                target.Id = hunt.Id
                target.Tier = hunt.Tier
                target.Side = hunt.Side
                target.ExpiresAt = hunt.ExpiresAt
                break
            end
        end

        return target
    end

    local function DescribeQuestState()
        local state = {
            ok = false,
            why = "?",
            hunts = 0,
            picked = nil,
            cooldown = nil,
            cooldownKnown = false,
            canAddQuest = nil,
            canAddError = nil,
            eligible = nil,
            eligibleError = nil,
            questModule = false,
            signalModule = false,
            activeQuest = nil,
            activeCategory = nil,
        }

        local okHunts, hunts = pcall(function() return Core.GetBossHunts() end)
        if okHunts and type(hunts) == "table" then
            state.hunts = #hunts
        end
        local okPick, picked = pcall(function() return Core.PickHuntTarget() end)
        if okPick then
            state.picked = picked
        end

        local okActive, active = pcall(function() return GetActiveQuest("BossHunt") end)
        if okActive then
            state.activeQuest = active and active.QuestString or nil
        end

        local okAny, any = pcall(function() return GetActiveQuest() end)
        if okAny and any then
            state.activeCategory = any.Category
        end

        local cooldown, known = GetQuestCooldownRemaining()
        state.cooldown = cooldown
        state.cooldownKnown = known

        local quests = GetQuestsModule()
        state.questModule = quests ~= nil
        state.signalModule = GetSignalEvent() ~= nil

        if state.picked then
            if quests and type(quests.CanAddQuest) == "function" then
                local canOk, canAdd = pcall(quests.CanAddQuest, LocalPlayer,
                    state.picked.Quest)
                if canOk then
                    state.canAddQuest = canAdd
                else
                    state.canAddError = tostring(canAdd)
                end
            end
            local module = GetBossHuntsModule()
            if module and type(module.Entry) == "function" then
                local defOk, definition = pcall(module.Entry, state.picked.Boss)
                if defOk and definition ~= nil and type(module.Eligible) == "function" then
                    local elOk, eligible = pcall(module.Eligible, definition, LocalPlayer)
                    if elOk then
                        state.eligible = eligible
                    else
                        state.eligibleError = tostring(eligible)
                    end
                end
            end
        end

        if state.activeQuest then
            state.ok, state.why = true, "уже активен: " .. tostring(state.activeQuest)
        elseif state.picked and (state.picked.Id == nil or tostring(state.picked.Id) == "nil") then
            state.ok, state.why = false, "у ханта нет Id - заявлять нечего"
        elseif state.hunts == 0 then
            state.ok, state.why = false, "нет активных хантов"
        elseif not state.picked then
            state.ok, state.why = false, "ханты есть, но цель не выбрана"
        elseif not known then
            state.ok, state.why = false, "кулдаун неизвестен (нет LastTime)"
        elseif (cooldown or 0) > 0.25 then
            state.ok, state.why = false, string.format("кулдаун %.0fs", cooldown)
        elseif not state.questModule then
            state.ok, state.why = false, "модуль Quests недоступен"
        elseif state.canAddError then
            state.ok, state.why = false, "CanAddQuest упал: " .. state.canAddError
        elseif state.eligible == false then

            state.ok, state.why = true, "можно пробовать, но Eligible=false: "
                .. tostring(state.picked.Boss)
        elseif state.canAddQuest == false and not IsBossHuntKey(state.picked.Quest) then
            state.ok, state.why = false, "CanAddQuest=false, квест не хантовый"
        elseif not state.signalModule then
            state.ok, state.why = false, "нет SignalEvent"
        else
            state.ok, state.why = true, "можно брать: " .. tostring(state.picked.Boss)
        end

        return state
    end

    _G.Core = _G.Core or {}
    _G.Core.Quest = {
        GetQuestDataFolder = GetQuestDataFolder,
        GetQuestsModule = GetQuestsModule,
        GetBossHuntsModule = GetBossHuntsModule,
        GetUtility = GetUtility,
        GetSignalEvent = GetSignalEvent,
        GetActiveQuest = GetActiveQuest,
        GetQuestCategory = GetQuestCategory,
        IsBossHuntKey = IsBossHuntKey,
        NormalizeCategory = NormalizeCategory,
        GetQuestCooldownRemaining = GetQuestCooldownRemaining,
        ClaimHuntQuest = ClaimHuntQuest,
        GetQuestBossName = GetQuestBossName,
        GetActiveHuntTarget = GetActiveHuntTarget,
        DescribeQuestState = DescribeQuestState,
    }

end

do

    local State = {
        FarmMobs = false,
        FarmBosses = false,
        Hunt = false,

        Interval = 0,

        Ticks = 0,
        LastTickAt = 0,
        LastTarget = nil,
        LastResult = "idle",
        LastAttack = nil,
        LastQuest = nil,
        LastQuestTry = 0,

        LastHumanoid = nil,
        LastTargetPoint = nil,

        LockedTarget = nil,

        LastLoot = nil,

        LastSkill = nil,

        LastEquip = nil,

        LastKill = nil,

        PendingLoad = nil,

        LoadTried = nil,

        LastLoadAt = 0,
        LastLoad = nil,
        Connected = false,
    }

    local function SetMode(mode, value)
        if State[mode] == nil then
            return false
        end
        State[mode] = value == true
        return true
    end

    local function IsAnyActive()
        return State.FarmMobs or State.FarmBosses or State.Hunt
    end

    local function ActiveModes()
        local modes = {}
        if State.FarmMobs then
            table.insert(modes, "mobs")
        end
        if State.FarmBosses then
            table.insert(modes, "bosses")
        end
        if State.Hunt then
            table.insert(modes, "hunts")
        end
        return modes
    end

    local function LootEligibleKind(name)
        if type(name) ~= "string" or name == "" then
            return nil
        end
        if type(Core.IsBossName) == "function" then
            local ok, isBoss = pcall(Core.IsBossName, name)
            if ok and isBoss then
                return "boss"
            end
        end
        local quest = _G.Core.Quest
        if quest and type(quest.GetActiveHuntTarget) == "function" then
            local ok, target = pcall(quest.GetActiveHuntTarget)
            if ok and target and target.Boss == name then
                return "hunt"
            end
        end
        return nil
    end

    local function StartLootIfEligible(name, point)
        if not Settings.WaitLoot then
            return false
        end
        local kind = LootEligibleKind(name)
        if not kind then
            return false
        end
        local loot = _G.Core.Loot
        if not loot or type(loot.Start) ~= "function" then
            return false
        end
        local ok, reason = loot.Start(point, Settings.LootWait)
        if ok then
            State.LastLoot = kind .. " kill: " .. tostring(name)
        end
        return ok, reason
    end

    local function IsHumanoidDead(humanoid)
        if typeof(humanoid) ~= "Instance" then
            return true
        end
        if humanoid.Parent == nil then
            return true
        end
        if humanoid.Health <= 0 then
            return true
        end
        return humanoid:GetAttribute("IsDead") == true
    end

    local function StepAutoLoad(pending)

        local snapshot = {}
        for index = 1, #pending do
            snapshot[index] = pending[index]
        end
        State.PendingLoad = snapshot

        if not Settings.AutoLoad then
            return false
        end
        if #pending == 0 then
            return false
        end
        if type(Core.TeleportToNpc) ~= "function" then
            return false
        end

        local now = os.clock()
        local cooldown = tonumber(Settings.AutoLoadCooldown) or 3.0
        if (now - (State.LastLoadAt or 0)) < cooldown then
            return false
        end
        State.LastLoadAt = now

        local tried = State.LoadTried
        if type(tried) ~= "table" then
            tried = {}
            State.LoadTried = tried
        end

        local untried = 0
        for index = 1, #pending do
            if not tried[pending[index]] then
                untried = untried + 1
            end
        end
        if untried == 0 then
            State.LoadTried = {}
            tried = State.LoadTried
        end

        local name
        for index = 1, #pending do
            if not tried[pending[index]] then
                name = pending[index]
                break
            end
        end
        if name == nil then
            return false
        end
        tried[name] = true

        local ok, result = pcall(Core.TeleportToNpc, name)
        if not ok then
            State.LastLoad = string.format("%s: error %s", tostring(name), tostring(result))
            return false
        end

        if result and result.ok then
            State.LastLoad = string.format("%s -> %s",
                tostring(name), tostring(result.source))
        else

            State.LastLoad = string.format("%s: %s", tostring(name),
                tostring(result and result.reason or "unknown"))
        end
        return true
    end

    local function Tick()
        if not IsAnyActive() then
            State.LastTarget = nil
            State.LastHumanoid = nil

            State.PendingLoad = nil
            State.LoadTried = nil
            State.LastResult = "idle"
            return
        end

        State.Ticks = State.Ticks + 1

        local loot = _G.Core.Loot
        if loot and type(loot.Update) == "function" and loot.IsBusy() then
            loot.Update()
            State.LastResult = "loot: " .. loot.Status()
            State.LastLoot = loot.Status()
            return
        end

        if State.LastHumanoid and State.LastTarget
            and State.LastTargetPoint
            and IsHumanoidDead(State.LastHumanoid) then
            StartLootIfEligible(State.LastTarget, State.LastTargetPoint)
            State.LastHumanoid = nil
        end

        local names = {}
        if type(Core.SelectTargets) == "function" then
            local ok, result = pcall(Core.SelectTargets, ActiveModes())
            if ok and type(result) == "table" then
                names = result
            end
        end

        if State.Hunt and _G.Core.Quest then
            local now = os.clock()
            if (now - (State.LastQuestTry or 0)) >= 2.0 then
                State.LastQuestTry = now
                local okQuest, questErr = pcall(function()
                    local quest = _G.Core.Quest
                    if quest.GetActiveQuest("BossHunt") then
                        State.LastQuest = "already active"
                        return
                    end
                    local hunt = _G.Core.PickHuntTarget()
                    if not hunt then
                        State.LastQuest = "no hunts"
                        return
                    end
                    local okClaim, reason = quest.ClaimHuntQuest(hunt)
                    State.LastQuest = hunt.Boss .. ": " .. tostring(reason)
                end)
                if not okQuest then
                    State.LastQuest = "error: " .. tostring(questErr)
                end
            end
        end
        if #names == 0 then
            State.LastTarget = nil
            State.LockedTarget = nil
            State.PendingLoad = nil
            State.LoadTried = nil
            State.LastResult = "nothing selected"
            return
        end

        if Settings.LockTarget and State.LockedTarget then
            local stillWanted = false
            for _, name in ipairs(names) do
                if name == State.LockedTarget then
                    stillWanted = true
                    break
                end
            end
            if not stillWanted then

                State.LockedTarget = nil
            end
        end

        local order = names
        if Settings.LockTarget and State.LockedTarget then
            order = { State.LockedTarget }
        end

        local failures = {}
        local pending = {}
        for _, name in ipairs(order) do

            local target = Core.FindNpcTarget and Core.FindNpcTarget(name)
            if not target then
                failures[#failures + 1] = name .. " (нет данных)"
            elseif not target.mob then
                failures[#failures + 1] = name .. " (не заспавнен)"

                pending[#pending + 1] = name

                if State.LockedTarget == name then
                    State.LockedTarget = nil
                end
            else
                local result = Core.HoverNpc(name)
                if result and result.ok then

                    if State.LastTarget and State.LastTarget ~= name
                        and State.LastTargetPoint then
                        StartLootIfEligible(State.LastTarget, State.LastTargetPoint)
                    end
                    State.LastTarget = name
                    State.LastTargetPoint = result.target
                    State.LastHumanoid = result.humanoid

                    State.PendingLoad = nil
                    State.LoadTried = nil

                    if Settings.LockTarget then
                        State.LockedTarget = name
                    end
                    State.LastResult = string.format("%s [%s d=%s]",
                        name, tostring(result.position), tostring(result.distance))

                    if Core.InstantKill
                        and type(Core.InstantKill.MaybeKill) == "function" then
                        local okKill, killInfo = pcall(
                            Core.InstantKill.MaybeKill, result.humanoid, name)

                        if not okKill then
                            State.LastKill = "fail: " .. tostring(killInfo)
                        elseif type(killInfo) == "table" and killInfo.ok then
                            State.LastKill = string.format("%s добит (снято %.0f%%)",
                                tostring(killInfo.name), killInfo.dealt or 0)
                        elseif type(killInfo) == "table" then
                            State.LastKill = string.format("%s: %s",
                                tostring(killInfo.name or name),
                                tostring(killInfo.reason or "отказ"))
                        else
                            State.LastKill = tostring(killInfo)
                        end
                    end

                    if Core.Combat and type(Core.Combat.PerformAttack) == "function" then
                        local now = os.clock()
                        if (now - (Settings.LastAttackAt or 0))
                            >= (Settings.AttackInterval or 0.28) then
                            Settings.LastAttackAt = now
                            local ok, info = pcall(Core.Combat.PerformAttack)
                            State.LastAttack = ok and tostring(info)
                                or ("fail: " .. tostring(info))
                        end
                    end

                    if Core.Skills and type(Core.Skills.CastAvailableSkill) == "function" then
                        if Settings.AutoSkills then
                            local okCast, castInfo = pcall(Core.Skills.CastAvailableSkill)
                            State.LastSkill = okCast and tostring(castInfo)
                                or ("fail: " .. tostring(castInfo))
                        end
                    end

                    if Core.Equip and type(Core.Equip.EnsureEquipped) == "function" then
                        if Settings.AutoEquip then
                            local okEquip, equipInfo = pcall(
                                Core.Equip.EnsureEquipped, Settings.EquipItem)
                            State.LastEquip = okEquip and tostring(equipInfo)
                                or ("fail: " .. tostring(equipInfo))
                        end
                    end
                    return
                end
                failures[#failures + 1] = name
            end
        end

        State.LastHumanoid = nil
        State.LastTarget = nil

        local moved = StepAutoLoad(pending)

        if moved and State.LastLoad then
            State.LastResult = string.format("%s | load: %s",
                table.concat(failures, ", "), State.LastLoad)
        else
            State.LastResult = string.format("unreachable: %s",
                table.concat(failures, ", "))
        end
    end

    local connection

    local previous = _G.Core and _G.Core.Loop
    if type(previous) == "table" and type(previous.Stop) == "function" then
        pcall(previous.Stop)
    end

    local function Start()

        if connection then
            if connection.Connected then
                return false
            end
            connection = nil
        end
        connection = RunService.Heartbeat:Connect(function()
            local now = os.clock()

            if State.Interval > 0 and (now - State.LastTickAt) < State.Interval then
                return
            end
            State.LastTickAt = now
            local ok, err = pcall(Tick)
            if not ok then
                State.LastResult = "error: " .. tostring(err)
            end
        end)
        State.Connected = true
        return true
    end

    local function SetModeAndRun(mode, value)
        local accepted = SetMode(mode, value)
        if not accepted then
            return false
        end
        if State[mode] == true and not State.Connected then
            Start()
        end
        return true
    end

    local function Stop()
        if connection then
            connection:Disconnect()
            connection = nil
        end
        State.Connected = false
        State.LastTarget = nil
        State.PendingLoad = nil
        State.LoadTried = nil
        State.LastResult = "stopped"
    end

    OnUnload(Stop)

    local function Status()

        local result = tostring(State.LastResult)
        if State.Connected and (os.clock() - (State.LastTickAt or 0)) > 1.0 then
            result = string.format("STALLED (no tick for %.1fs)",
                os.clock() - (State.LastTickAt or 0))
        end

        local loadNote = ""
        if State.LastLoad then

            local left = (tonumber(Settings.AutoLoadCooldown) or 3.0)
                - (os.clock() - (State.LastLoadAt or 0))
            if left > 0 then
                loadNote = string.format(" | load: %s (%.1fs)",
                    tostring(State.LastLoad), left)
            else
                loadNote = string.format(" | load: %s", tostring(State.LastLoad))
            end
        end
        if State.PendingLoad and #State.PendingLoad > 0 then
            local triedCount = 0
            if type(State.LoadTried) == "table" then
                for _ in pairs(State.LoadTried) do
                    triedCount = triedCount + 1
                end
            end
            loadNote = loadNote .. string.format(" | waiting: %d/%d",
                #State.PendingLoad - triedCount, #State.PendingLoad)
        end

        return string.format("%s | target: %s | ticks: %d | modes: %s%s%s%s%s%s%s%s",
            result,
            tostring(State.LastTarget),
            State.Ticks,
            (#ActiveModes() > 0 and table.concat(ActiveModes(), "+") or "none"),
            State.Connected and "" or " | DISCONNECTED",
            State.LastAttack and (" | atk: " .. tostring(State.LastAttack)) or "",
            (State.LastQuest and (" | quest: " .. tostring(State.LastQuest)) or ""),
            (State.LastLoot and (" | loot: " .. tostring(State.LastLoot)) or ""),
            (State.LastSkill and (" | skill: " .. tostring(State.LastSkill)) or ""),
            (State.LastEquip and (" | equip: " .. tostring(State.LastEquip)) or ""),
            (State.LastKill and (" | kill: " .. tostring(State.LastKill)) or ""),
            loadNote)
    end

    _G.Core = _G.Core or {}
    _G.Core.Loop = {
        State = State,
        SetMode = SetModeAndRun,
        IsAnyActive = IsAnyActive,
        ActiveModes = ActiveModes,
        Tick = Tick,
        Start = Start,
        Stop = Stop,
        Status = Status,
    }

end

do

    local firetouchinterest
    local fireProximityPrompt
    local getConnections
    local canSignalReplicate
    do
        local env = (getgenv and getgenv()) or _G
        if type(env.firetouchinterest) == "function" then
            firetouchinterest = env.firetouchinterest
        elseif type(_G.firetouchinterest) == "function" then
            firetouchinterest = _G.firetouchinterest
        end

        if type(env.fireproximityprompt) == "function" then
            fireProximityPrompt = env.fireproximityprompt
        elseif type(_G.fireproximityprompt) == "function" then
            fireProximityPrompt = _G.fireproximityprompt
        end

        if type(env.getconnections) == "function" then
            getConnections = env.getconnections
        elseif type(_G.getconnections) == "function" then
            getConnections = _G.getconnections
        end

        if type(env.cansignalreplicate) == "function" then
            canSignalReplicate = env.cansignalreplicate
        elseif type(_G.cansignalreplicate) == "function" then
            canSignalReplicate = _G.cansignalreplicate
        end
    end

    local function PromptReachability(prompt)
        local result = { clients = -1, replicates = nil }
        if not prompt then
            return nil
        end

        if getConnections then
            local ok, list = pcall(getConnections, prompt.Triggered)
            if ok and type(list) == "table" then
                result.clients = #list
            end
        end

        if canSignalReplicate then
            local ok, value = pcall(canSignalReplicate, prompt.Triggered)
            if ok and type(value) == "boolean" then
                result.replicates = value
            end
        end

        if result.clients == 0 and result.replicates == false then
            result.canFire = false
        else

            result.canFire = nil
        end

        return result
    end

    local function GetDropPart(item)
        if not item then
            return nil
        end
        if item:IsA("BasePart") then
            return item
        end
        return item:FindFirstChild("Handle")
            or item:FindFirstChildWhichIsA("BasePart", true)
    end

    local Session = {
        Active = false,
        Status = "idle",
        KillPosition = nil,
        StartedAt = 0,
        ReadyAt = 0,
        EndedAt = 0,
        OpenedChests = 0,
        CollectedDrops = 0,
        ChestChecked = false,
        LastChest = nil,
        LastDrop = nil,

        SeenDrops = {},
    }

    local MAX_SESSION = 12.0

    local SETTLE = 0.8

    local COLLECT_WINDOW = 5.0

    local SEARCH_RADIUS = 60

    local DROP_GRACE = 2.5

    local function GetRootPart()
        if Core.GetRootPart then
            return Core.GetRootPart()
        end
        local character = LocalPlayer.Character
        return character and character:FindFirstChild("HumanoidRootPart") or nil
    end

    local function MoveTo(point, lookAtPoint)
        local root = GetRootPart()
        if not root or not point then
            return false, "no character or no point"
        end
        if Core.TeleportTo then
            return Core.TeleportTo(point, lookAtPoint or point)
        end
        local target = lookAtPoint or point
        local flat = Vector3.new(target.X, point.Y, target.Z)
        if (flat - point).Magnitude < 0.01 then
            root.CFrame = CFrame.new(point)
        else
            root.CFrame = CFrame.new(point, flat)
        end
        root.AssemblyLinearVelocity = Vector3.zero
        return true
    end

    local PROMPT_ACTION_BLOCKLIST = {
        "chat", "talk", "speak", "train", "buy", "shop",
        "quest", "dialogue", "talk to", "speak to",
    }
    local PROMPT_OBJECT_BLOCKLIST = {
        "trainer", "urokodaki", "muzan", "npc", "station",
        "corps", "slayer", "shop", "merchant", "vendor",
    }

    table.freeze(PROMPT_ACTION_BLOCKLIST)
    table.freeze(PROMPT_OBJECT_BLOCKLIST)

    local function ContainsAny(haystack, list)
        local value = string.lower(tostring(haystack or ""))
        for _, needle in ipairs(list) do
            if string.find(value, needle, 1, true) then
                return true
            end
        end
        return false
    end

    local function GetPromptPosition(prompt)
        local parent = prompt and prompt.Parent
        if not parent then
            return nil
        end
        if parent:IsA("Attachment") then
            return parent.WorldPosition
        end
        if parent:IsA("BasePart") then
            return parent.Position
        end
        if parent:IsA("Model") then
            local ok, position = pcall(function() return parent:GetPivot().Position end)
            return ok and position or nil
        end
        return nil
    end

    local function IsValidChest(prompt, position, referencePosition)
        if not prompt or not prompt:IsA("ProximityPrompt") then
            return false
        end
        if not prompt.Parent or not position then
            return false
        end

        local root = GetRootPart()
        local myPosition = (root and root.Position) or position
        if (position - myPosition).Magnitude > 400
            and referencePosition
            and (position - referencePosition).Magnitude > 400 then
            return false
        end

        local action = tostring(prompt.ActionText or "")
        local object = tostring(prompt.ObjectText or "")
        local name = tostring(prompt.Name or "")
        if ContainsAny(action, PROMPT_ACTION_BLOCKLIST)
            or ContainsAny(object, PROMPT_OBJECT_BLOCKLIST) then
            return false
        end

        local chestModel = nil
        local chestsFolder = workspace:FindFirstChild("Chests")
        local current = prompt.Parent
        while current and current ~= workspace do
            if (chestsFolder and current.Parent == chestsFolder)
                or current:GetAttribute("ChestState") ~= nil
                or current:GetAttribute("IsOpen") ~= nil
                or current:GetAttribute("ChestId") ~= nil
                or current:GetAttribute("ChestGuid") ~= nil then
                chestModel = current
                break
            end
            current = current.Parent
        end

        if not chestModel then
            local lowerName = string.lower(name)
            local lowerObject = string.lower(object)
            local lowerAction = string.lower(action)
            if not (string.find(lowerName, "chest", 1, true)
                or string.find(lowerObject, "chest", 1, true)
                or string.find(lowerObject, "cache", 1, true)
                or string.find(lowerAction, "open", 1, true)) then
                return false
            end
            return true, nil
        end

        local state = chestModel:GetAttribute("ChestState")
        if chestModel:GetAttribute("IsOpen") == true
            or state == "Opened" or state == "Despawned" then
            return false
        end

        if state == "Locked" and prompt.Enabled == false then
            return false
        end
        if string.find(string.lower(chestModel.Name or ""), "mound", 1, true) then
            return false
        end

        return true, chestModel
    end

    local function FindChest(referencePosition)
        local root = GetRootPart()
        local myPosition = (root and root.Position) or referencePosition
        local best, bestDistance = nil, nil

        local function consider(prompt)
            local position = GetPromptPosition(prompt)
            if not position then
                return
            end
            if referencePosition
                and (position - referencePosition).Magnitude > SEARCH_RADIUS then
                return
            end
            local ok = IsValidChest(prompt, position, referencePosition)
            if not ok then
                return
            end
            local distance = (position - (myPosition or position)).Magnitude
            if not bestDistance or distance < bestDistance then
                best, bestDistance = prompt, distance
            end
        end

        local folder = workspace:FindFirstChild("Chests")
        if folder then
            for _, descendant in ipairs(folder:GetDescendants()) do
                if descendant:IsA("ProximityPrompt") then
                    consider(descendant)
                end
            end
        end

        for _, tagged in ipairs(CollectionService:GetTagged("Chest")) do
            for _, descendant in ipairs(tagged:GetDescendants()) do
                if descendant:IsA("ProximityPrompt") then
                    consider(descendant)
                end
            end
        end

        return best
    end

    local function ChestStateOf(prompt)
        local current = prompt and prompt.Parent
        while current and current ~= workspace do
            local state = current:GetAttribute("ChestState")
            local isOpen = current:GetAttribute("IsOpen")
            if state ~= nil or isOpen ~= nil then
                return state, isOpen
            end
            current = current.Parent
        end
        return nil, nil
    end

    local function OpenChest(prompt)
        if not prompt then
            return false, "no chest"
        end
        local position = GetPromptPosition(prompt)
        if not position then
            return false, "no position"
        end

        local standAt = position + Vector3.new(0, 1.5, 2.5)
        local moved, moveError = MoveTo(standAt, position)
        if not moved then
            return false, moveError
        end

        local previousHold = prompt.HoldDuration
        local previousDistance = prompt.MaxActivationDistance
        local previousEnabled = prompt.Enabled

        prompt.MaxActivationDistance = math.max(previousDistance, 60)
        prompt.Enabled = true

        local reach = PromptReachability(prompt)

        local fired = false
        local watch
        watch = prompt.Triggered:Connect(function()
            fired = true
        end)

        local triedFire = false
        if type(fireProximityPrompt) == "function"
            and not (reach and reach.canFire == false) then
            triedFire = true
            pcall(fireProximityPrompt, prompt)
            task.wait(0.08)
        end

        if prompt.Parent then
            local key = prompt.KeyboardKeyCode or Enum.KeyCode.E
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, key, false, game)
            end)
            task.wait(0.05)
            pcall(function()
                VirtualInputManager:SendKeyEvent(false, key, false, game)
            end)
            task.wait(0.05)
        end

        pcall(function() watch:Disconnect() end)

        if prompt.Parent then
            prompt.HoldDuration = previousHold
            prompt.MaxActivationDistance = previousDistance
            prompt.Enabled = previousEnabled
        end

        if reach and reach.canFire == false then
            local detail = string.format(
                "Triggered has no client connections (%d) and no replication path",
                reach.clients or 0)
            return false, "chest cannot be opened from client: " .. detail
        end

        if not fired then
            local detail = triedFire
                and "no client handler reached"
                or "fireproximityprompt unavailable"
            return false, "prompt did not fire: " .. detail
        end

        return true
    end

    local function GetDropPosition(item)
        if not item then
            return nil
        end
        local dropTarget = item:GetAttribute("DropTarget")
        if typeof(dropTarget) == "Vector3" then
            return dropTarget
        end
        if item:IsA("BasePart") then
            return item.Position
        end
        local part = item:FindFirstChild("Handle")
            or (item:IsA("Model") and item:FindFirstChildWhichIsA("BasePart", true))
        if part and part:IsA("BasePart") then
            return part.Position
        end
        if item:IsA("Model") then
            local ok, position = pcall(function() return item:GetPivot().Position end)
            return ok and position or nil
        end
        return nil
    end

    local function CanClaimDrop(item)
        local userId = LocalPlayer.UserId
        local ownerId = item:GetAttribute("DropOwnerUserId")
        if ownerId ~= nil and ownerId ~= 0 and ownerId ~= userId then
            return false
        end
        local reserved = item:GetAttribute("DropReservedFor")
        if reserved ~= nil and tostring(reserved) ~= "" then

            if not string.find(tostring(reserved), "," .. tostring(userId) .. ",", 1, true) then
                return false
            end
        end
        return true
    end

    local function IsDrop(item, lootFolder)
        if not item or not item.Parent then
            return false
        end
        if item:GetAttribute("DropClaimedBy") ~= nil then
            return false
        end
        if item:FindFirstAncestor("Regions")
            or item:FindFirstAncestor("StationaryNpcs") then
            return false
        end
        if item.Name == "Regions" or item.Name == "Debree" then
            return false
        end

        local isDrop = (item:GetAttribute("DropItemId") ~= nil)
            or (lootFolder and item.Parent == lootFolder)
            or CollectionService:HasTag(item, "LootDrop")
        if not isDrop then
            return false
        end

        return CanClaimDrop(item)
    end

    local function GetDrops(referencePosition)
        local result = {}
        local folder = workspace:FindFirstChild("LootDrops")
        local seen = {}

        local function consider(item)
            if seen[item] then
                return
            end
            if not IsDrop(item, folder) then
                return
            end
            local position = GetDropPosition(item)
            if not position then
                return
            end
            if referencePosition
                and (position - referencePosition).Magnitude > SEARCH_RADIUS then
                return
            end
            seen[item] = true
            result[#result + 1] = { instance = item, position = position }
        end

        if folder then
            for _, item in ipairs(folder:GetChildren()) do
                consider(item)
            end
        end
        for _, item in ipairs(CollectionService:GetTagged("LootDrop")) do
            consider(item)
        end

        return result
    end

    local function CollectDrop(drop)
        local instance = drop.instance
        if not instance or not instance.Parent then
            return false
        end

        local root = GetRootPart()
        if not root then
            return false
        end

        local position = drop.position
        local standAt = position + Vector3.new(0, 1.2, 0)
        root.CFrame = CFrame.new(standAt)
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero

        local function claimed()
            return instance.Parent == nil
                or instance:GetAttribute("DropClaimedBy") ~= nil
        end

        local prompt = instance:FindFirstChildWhichIsA("ProximityPrompt", true)
        if prompt then
            local oldHold = prompt.HoldDuration
            local oldDistance = prompt.MaxActivationDistance
            prompt.Enabled = true
            prompt.HoldDuration = 0
            prompt.MaxActivationDistance = 60
            if type(fireProximityPrompt) == "function" then
                pcall(fireProximityPrompt, prompt, 0)
                pcall(fireProximityPrompt, prompt)
            end
            local key = prompt.KeyboardKeyCode
            if key == nil or key == Enum.KeyCode.Unknown then
                key = Enum.KeyCode.T
            end
            pcall(function()
                VirtualInputManager:SendKeyEvent(true, key, false, game)
            end)
            task.wait(0.05)
            pcall(function()
                VirtualInputManager:SendKeyEvent(false, key, false, game)
            end)
            pcall(function()
                prompt.HoldDuration = oldHold
                prompt.MaxActivationDistance = oldDistance
            end)
        end

        local function touch()
            local part = GetDropPart(instance)
            if not part or type(firetouchinterest) ~= "function" then
                return
            end
            pcall(firetouchinterest, root, part, 0)
            task.wait(0.02)
            pcall(firetouchinterest, root, part, 1)
        end

        touch()

        task.wait(0.14)

        if not claimed() then
            if prompt and prompt.Parent then
                prompt.Enabled = true
                if type(fireProximityPrompt) == "function" then
                    pcall(fireProximityPrompt, prompt, 0)
                    pcall(fireProximityPrompt, prompt)
                end
            end
            touch()
            task.wait(0.08)
        end

        return claimed()
    end

    local function CollectDrops(referencePosition)
        local fresh = 0
        local deadline = os.clock() + COLLECT_WINDOW

        while os.clock() < deadline do
            local drops = GetDrops(referencePosition)
            if #drops == 0 then
                break
            end

            local touchedAny = false
            for _, drop in ipairs(drops) do
                if not Session.SeenDrops[drop.instance] then
                    Session.SeenDrops[drop.instance] = true
                    fresh = fresh + 1
                end
                if CollectDrop(drop) then
                    touchedAny = true
                end
            end

            if not touchedAny then

                break
            end
            task.wait(0.08)
        end

        return fresh
    end

    local function IsBusy()
        return Session.Active == true
    end

    local function Start(killPosition, waitSeconds)
        if typeof(killPosition) ~= "Vector3" then
            return false, "no kill position"
        end
        local now = os.clock()
        local wait = math.max(0, tonumber(waitSeconds) or 0)
        Session.Active = true
        Session.Status = "waiting"
        Session.KillPosition = killPosition
        Session.StartedAt = now
        Session.ReadyAt = now + wait
        Session.Deadline = Session.ReadyAt + MAX_SESSION
        Session.EndedAt = 0
        Session.OpenedChests = 0
        Session.CollectedDrops = 0
        Session.ChestChecked = false
        Session.LastChest = nil
        Session.LastDrop = nil
        Session.SeenDrops = {}
        Session.SettleUntil = nil
        return true
    end

    local function Stop(status)
        Session.Active = false
        Session.Status = status or "done"
        Session.EndedAt = os.clock()
    end

    local function Update()
        if not Session.Active then
            return false
        end

        local now = os.clock()
        local reference = Session.KillPosition

        if now >= (Session.Deadline or 0) then
            Stop("timeout")
            return false
        end

        if Settings.AutoOpenChest and not Session.ChestChecked then
            local chest = FindChest(reference)
            Session.LastChest = chest
            if chest then
                local opened = OpenChest(chest)
                if opened then
                    Session.OpenedChests = Session.OpenedChests + 1
                    Session.Status = "chest"
                    Session.ChestChecked = true
                end
            end

            if not Session.ChestChecked
                and (now - Session.StartedAt) >= (math.max(0, Session.ReadyAt - Session.StartedAt) + DROP_GRACE) then
                Session.ChestChecked = true
            end
        end

        if Settings.AutoCollectDrop then
            local collected = CollectDrops(reference)
            if collected > 0 then
                Session.CollectedDrops = Session.CollectedDrops + collected
                Session.Status = "drops"
            end
        end

        if now < Session.ReadyAt then
            Session.Status = "waiting"
            return true
        end

        if Settings.AutoCollectDrop then
            local hasNew = false
            for _, drop in ipairs(GetDrops(reference)) do
                if not Session.SeenDrops[drop.instance] then
                    hasNew = true
                    break
                end
            end
            if hasNew then
                Session.Status = "drops"
                return true
            end
            if Session.SettleUntil == nil then
                Session.SettleUntil = now + SETTLE
            end
            if now < Session.SettleUntil then
                Session.Status = "settle"
                return true
            end
        end
        if Settings.AutoOpenChest and not Session.ChestChecked then
            Session.Status = "chest"
            return true
        end

        Stop("done")
        return false
    end

    local function Reset()
        Session.Active = false
        Session.Status = "idle"
        Session.KillPosition = nil
        Session.OpenedChests = 0
        Session.CollectedDrops = 0
        Session.ChestChecked = false
        Session.SeenDrops = {}
        Session.Deadline = 0
        Session.SettleUntil = nil
    end

    local function Status()
        return string.format(
            "%s | chests: %d | drops: %d%s",
            tostring(Session.Status),
            Session.OpenedChests,
            Session.CollectedDrops,
            Session.Active and " | busy" or "")
    end

    _G.Core = _G.Core or {}
    _G.Core.Loot = {
        Session = Session,
        IsBusy = IsBusy,
        Start = Start,
        Stop = Stop,
        Update = Update,
        Reset = Reset,
        Status = Status,
        FindChest = FindChest,
        OpenChest = OpenChest,
        GetDrops = GetDrops,
        CollectDrops = CollectDrops,
        CollectDrop = CollectDrop,
        CanClaimDrop = CanClaimDrop,
        IsDrop = IsDrop,
        IsValidChest = IsValidChest,
        HasFireTouch = function() return type(firetouchinterest) == "function" end,
        HasFirePrompt = function() return type(fireProximityPrompt) == "function" end,

        PromptReachability = PromptReachability,
    }

end

do

    local function GetProvider()
        return RequireCached("GetProvider", function()
            return require(ReplicatedStorage.CAM.Client.Controllers.Skills_Provider)
        end)
    end

    local function GetController()
        return RequireCached("GetController", function()
            return require(ReplicatedStorage.CAM.Client.Controllers.Skill_Controller)
        end)
    end

    local function GetAvailableSkills()
        local result = {}
        local provider = GetProvider()
        if not provider or type(provider.get_current_keys) ~= "function" then
            return result
        end
        local ok, keys = pcall(provider.get_current_keys)
        if not ok or type(keys) ~= "table" then
            return result
        end
        for _, entry in ipairs(keys) do
            local name = type(entry) == "table" and entry.Name or nil
            local key = type(entry) == "table" and entry.Key or nil
            if type(name) == "string" and name ~= "" and name ~= "Blocking"
                and type(key) == "string" and key ~= ""
                and not (type(entry) == "table" and entry.RequiresModeBar) then
                result[#result + 1] = {
                    Name = name,
                    Key = key,
                }
            end
        end
        return result
    end

    local function CastViaController(skill)
        local controller = GetController()
        if not controller or type(controller.Attempt_Hold) ~= "function" then
            return false
        end
        local setIdentity = _G.setthreadidentity
        local getIdentity = _G.getthreadidentity
        if type(setIdentity) ~= "function" then
            return false
        end
        local oldIdentity = (type(getIdentity) == "function" and getIdentity()) or 8

        local held = false
        pcall(function()
            setIdentity(2)
            held = controller.Attempt_Hold(skill.Name) == true
            if held then

                task.delay(0.08, function()
                    pcall(function()
                        setIdentity(2)
                        if type(controller.StopHold) == "function" then
                            controller.StopHold(skill.Name)
                        end
                    end)
                end)
            end
        end)
        pcall(function() setIdentity(oldIdentity) end)

        return held == true
    end

    local function CastViaButton(skill)
        local playerGui = LocalPlayer:FindFirstChild("PlayerGui")
        local components = playerGui and playerGui:FindFirstChild("ComponentsHolder")
        local bottom = components and components:FindFirstChild("BottomHolder")
        local holder = bottom and bottom:FindFirstChild("SkillsHolder")
        if not holder then
            return false
        end
        for _, frame in ipairs(holder:GetChildren()) do
            local keyLabel = frame:FindFirstChild("KeyLabel", true)
            if keyLabel and keyLabel.Text == skill.Key then

                local button = frame:FindFirstChildWhichIsA("GuiButton", true)
                    or frame.Parent
                if button and button:IsA("GuiButton") then
                    local fired = pcall(function()
                        button.MouseButton1Down:Fire()
                    end)
                    task.wait(0.04)
                    pcall(function()
                        button.MouseButton1Up:Fire()
                    end)
                    return fired
                end
            end
        end
        return false
    end

    local function CastViaKey(skill)
        if type(skill.Key) ~= "string" then
            return false
        end
        local keyEnum = Enum.KeyCode[skill.Key]
        if not keyEnum then
            return false
        end
        local pressed = pcall(function()
            VirtualInputManager:SendKeyEvent(true, keyEnum, false, game)
        end)
        task.wait(0.04)
        pcall(function()
            VirtualInputManager:SendKeyEvent(false, keyEnum, false, game)
        end)
        return pressed
    end

    local State = {
        Index = 0,
        LastCast = 0,

        Bucket = 1,
        BucketAt = 0,
        LastName = nil,
        LastMethod = nil,
        CastCount = 0,
    }

    local function TakeToken(now, interval)
        if interval <= 0 then
            State.Bucket = 1
            State.BucketAt = now
            return true
        end

        if State.BucketAt == 0 then
            State.Bucket = 1
            State.BucketAt = now
            return true
        end

        local elapsed = now - State.BucketAt
        if elapsed > 0 then
            State.Bucket = State.Bucket + (elapsed / interval)
            State.BucketAt = now
        end
        if State.Bucket > 1 then
            State.Bucket = 1
        end

        if State.Bucket < 1 then
            return false
        end
        State.Bucket = State.Bucket - 1
        return true
    end

    local function CastAvailableSkill()
        if not Settings.AutoSkills then
            return false, "off"
        end

        local skills = GetAvailableSkills()
        if #skills == 0 then
            return false, "no skills"
        end

        local now = os.clock()
        local interval = tonumber(Settings.SkillInterval) or 1.0
        if not TakeToken(now, interval) then
            return false, "cooldown"
        end

        State.Index = State.Index + 1
        if State.Index > #skills then
            State.Index = 1
        end
        local skill = skills[State.Index]
        if not skill then
            return false, "no skill at index"
        end

        local method, casted
        if CastViaController(skill) then
            method, casted = "controller", true
        elseif CastViaButton(skill) then
            method, casted = "button", true
        elseif CastViaKey(skill) then
            method, casted = "key", true
        else
            method, casted = "none", false
        end

        if not casted then
            return false, skill.Name .. " (все способы молчат)"
        end

        State.LastCast = now
        State.LastName = skill.Name
        State.LastMethod = method
        State.CastCount = State.CastCount + 1

        return true, string.format("%s [%s]", skill.Name, method)
    end

    local function CastByName(name)
        for _, skill in ipairs(GetAvailableSkills()) do
            if skill.Name == name then
                local casted = CastViaController(skill) or CastViaButton(skill)
                    or CastViaKey(skill)
                if casted then
                    local now = os.clock()
                    State.LastCast = now
                    State.LastName = skill.Name
                    State.CastCount = State.CastCount + 1
                    return true, skill.Name
                end
                return false, skill.Name .. " (не применился)"
            end
        end
        return false, "skill not found"
    end

    local function Reset()
        State.Index = 0
        State.LastCast = 0
        State.Bucket = 1
        State.BucketAt = 0
        State.LastName = nil
        State.LastMethod = nil
        State.CastCount = 0
    end

    local function Status()
        local skills = GetAvailableSkills()
        local names = {}
        for _, skill in ipairs(skills) do
            names[#names + 1] = skill.Key .. "=" .. skill.Name
        end
        return string.format("skills: %d | last: %s (%s) | cast: %d | %s",
            #skills,
            tostring(State.LastName or "-"),
            tostring(State.LastMethod or "-"),
            State.CastCount,
            table.concat(names, ", "))
    end

    _G.Core = _G.Core or {}
    _G.Core.Skills = {
        State = State,
        GetAvailableSkills = GetAvailableSkills,
        CastAvailableSkill = CastAvailableSkill,
        CastByName = CastByName,
        Reset = Reset,
        Status = Status,
        HasProvider = function() return GetProvider() ~= nil end,
        HasController = function() return GetController() ~= nil end,
    }

end

do

    local HOTBAR_SLOTS = { "One", "Two", "Three", "Four", "Five" }

    local function GetUtility()
        return RequireCached("GetUtility", function()
            return require(ReplicatedStorage.CAM.Global.Utility)
        end)
    end

    local function GetSlotData()
        local utility = GetUtility()
        if not utility or type(utility.GetData) ~= "function" then
            return nil
        end
        local ok, slot = pcall(utility.GetData, LocalPlayer, true)
        if not ok then
            return nil
        end
        return slot
    end

    local function GetSignalEvent()
        return RequireCached("GetSignalEvent", function()
            return require(ReplicatedStorage.Communication.ServerAndClient.Signals.SignalEvent)
        end)
    end

    local function BuildNamesById(slot)
        local names = {}
        local inventory = slot and slot:FindFirstChild("Inventory")
        local sources = {}
        if inventory then
            sources[#sources + 1] = inventory:FindFirstChild("Inventory")
            sources[#sources + 1] = inventory
        end
        for _, folder in ipairs(sources) do
            if folder then
                for _, item in ipairs(folder:GetChildren()) do
                    local id = item:FindFirstChild("Id")
                    if id and id.Value ~= nil then
                        names[tostring(id.Value)] = item.Name
                    end
                end
            end
        end
        return names
    end

    local function CollectFrom(source, namesById, sourceName, result)
        if not source then
            return false
        end
        local before = #result
        for index, slotName in ipairs(HOTBAR_SLOTS) do
            local value = source:FindFirstChild(slotName)
            local itemId = value and value.Value or nil

            if itemId ~= nil and tostring(itemId) ~= "0" then
                result[#result + 1] = {
                    Name = namesById[tostring(itemId)] or ("Item " .. tostring(itemId)),
                    Id = itemId,
                    Slot = index,
                    SlotName = slotName,
                    Source = sourceName,
                }
            end
        end
        return #result > before
    end

    local function GetHotbarItems()
        local result = {}
        local slot = GetSlotData()
        if not slot then
            return result
        end

        local namesById = BuildNamesById(slot)

        local inventory = slot:FindFirstChild("Inventory")
        local toolbar = inventory and inventory:FindFirstChild("Toolbar")
        if toolbar and CollectFrom(toolbar, namesById, "Toolbar", result) then
            return result
        end

        local loadouts = slot:FindFirstChild("ItemLoadouts")
        if loadouts then
            for _, loadout in ipairs(loadouts:GetChildren()) do
                if loadout:IsA("Folder") then
                    local tools = loadout:FindFirstChild("Tools")
                    if CollectFrom(tools, namesById,
                        "ItemLoadout " .. tostring(loadout.Name), result) then
                        return result
                    end
                end
            end
        end

        return result
    end

    local function GetHotbarNames()
        local names = {}
        local seen = {}
        for _, item in ipairs(GetHotbarItems()) do
            if item.Name and item.Name ~= "" and not seen[item.Name] then
                seen[item.Name] = true
                names[#names + 1] = item.Name
            end
        end
        return names
    end

    local function GetEquippedSlot()
        local config = LocalPlayer:FindFirstChild("Items_Config")
        local equipped = config and config:FindFirstChild("Equipped")
        if equipped and equipped:IsA("ValueBase") then
            return tonumber(equipped.Value) or 0
        end
        return 0
    end

    local function GetEquippedName()
        local slotNumber = GetEquippedSlot()
        if slotNumber == 0 then
            return nil
        end
        for _, item in ipairs(GetHotbarItems()) do
            if item.Slot == slotNumber then
                return item.Name
            end
        end
        return nil
    end

    local function EquipHotbarItem(itemName)
        if type(itemName) ~= "string" or itemName == "" then
            return false, "no_item"
        end

        local selected
        for _, item in ipairs(GetHotbarItems()) do
            if item.Name == itemName then
                selected = item
                break
            end
        end
        if not selected then
            return false, "not_in_hotbar"
        end

        local config = LocalPlayer:FindFirstChild("Items_Config")
        local equipped = config and config:FindFirstChild("Equipped")
        if equipped then
            pcall(function() equipped.Value = selected.Slot end)
        end

        local signal = GetSignalEvent()
        if not signal or type(signal.ToServer) ~= "function" then
            return false, "no_signal"
        end

        local sent, err = pcall(function()
            signal.ToServer("Item_Equip", selected.Slot)
        end)
        if not sent then
            return false, tostring(err)
        end

        return true, string.format("%s (slot %d)", selected.Name, selected.Slot)
    end

    local State = {
        LastName = nil,
        LastResult = nil,
        LastAt = 0,
        Count = 0,
    }

    local EQUIP_INTERVAL = 1.5

    local function EnsureEquipped(itemName)
        if not Settings.AutoEquip then
            return false, "off"
        end
        if type(itemName) ~= "string" or itemName == "" then
            return false, "no_item"
        end

        local current = GetEquippedName()
        if current == itemName then
            return true, "already"
        end

        local now = os.clock()
        if (now - (State.LastAt or 0)) < EQUIP_INTERVAL then
            return false, "cooldown"
        end
        State.LastAt = now

        local ok, info = EquipHotbarItem(itemName)
        State.LastName = itemName
        State.LastResult = info
        if ok then
            State.Count = State.Count + 1
        end
        return ok, info
    end

    local function Reset()
        State.LastName = nil
        State.LastResult = nil
        State.LastAt = 0
        State.Count = 0
    end

    local function Status()
        return string.format("equipped: %s | want: %s | tries: %d | hotbar: %d",
            tostring(GetEquippedName() or "-"),
            tostring(State.LastName or "-"),
            State.Count,
            #GetHotbarItems())
    end

    _G.Core = _G.Core or {}
    _G.Core.Equip = {
        State = State,
        GetHotbarItems = GetHotbarItems,
        GetHotbarNames = GetHotbarNames,
        GetEquippedSlot = GetEquippedSlot,
        GetEquippedName = GetEquippedName,
        EquipHotbarItem = EquipHotbarItem,
        EnsureEquipped = EnsureEquipped,
        Reset = Reset,
        Status = Status,
    }

end

do

    local Camera = workspace.CurrentCamera

    local function ColorOr(fallback, value)
        if typeof(value) == "Color3" then
            return value
        end
        return fallback
    end

    local DEFAULT_COLORS = {
        Mobs = Color3.fromRGB(255, 96, 96),
        Players = Color3.fromRGB(96, 200, 255),
    }

    local NAME_GAP = 6

    local MIN_BOX_HALF = 4

    local BOX_THICKNESS = 1

    local BOX_OUTLINE = Color3.fromRGB(0, 0, 0)

    local NAME_SIZE = 18

    local NAME_OUTLINE = Color3.fromRGB(0, 0, 0)

    local PAINT_ZINDEX = 1

    local POOL_SIZE = 96

    local HAS_DRAWING = (
        type(DrawingImmediate) == "table"
        and type(DrawingImmediate.GetPaint) == "function"
        and type(DrawingImmediate.Rectangle) == "function"
        and type(DrawingImmediate.OutlinedText) == "function"
    )

    local FOLDER_STASH = "SL2ESPFolder"
    local CONN_STASH = "SL2ESPConnection"
    local POOL_STASH = "SL2ESPPool"

    local function CleanupPrevious()
        local previousConnection = rawget(_G, CONN_STASH)
        if previousConnection then
            pcall(function() previousConnection:Disconnect() end)
        end
        rawset(_G, CONN_STASH, nil)

        local previousPool = rawget(_G, POOL_STASH)
        if type(previousPool) == "table" then
            for index = 1, #previousPool do
                local highlight = previousPool[index]
                if highlight and highlight.Destroy then
                    pcall(function() highlight:Destroy() end)
                end
            end
        end
        rawset(_G, POOL_STASH, nil)

        local previousFolder = rawget(_G, FOLDER_STASH)
        if previousFolder and previousFolder.Destroy then
            pcall(function() previousFolder:Destroy() end)
        end
        rawset(_G, FOLDER_STASH, nil)
    end

    CleanupPrevious()

    local guiHostCache
    local function GuiHost()
        if guiHostCache then
            return guiHostCache
        end
        local okHui, hui = pcall(function()
            return gethui and gethui()
        end)
        if okHui and typeof(hui) == "Instance" then
            guiHostCache = hui
            return guiHostCache
        end
        local okGui, gui = pcall(function()
            return game:GetService("CoreGui").RobloxGui
        end)
        if okGui and typeof(gui) == "Instance" then
            guiHostCache = gui
            return guiHostCache
        end
        local okPg, pg = pcall(function()
            return LocalPlayer:WaitForChild("PlayerGui")
        end)
        if okPg and typeof(pg) == "Instance" then
            guiHostCache = pg
            return guiHostCache
        end
        return nil
    end

    local Pool = {}
    local Pooled = 0
    local LiveCount = 0
    local espFolder

    local function AcquireHighlight()
        if Pooled >= POOL_SIZE then
            return nil
        end
        if not espFolder then
            espFolder = Instance.new("Folder")
            espFolder.Name = "SL2ESP"
            espFolder.Parent = GuiHost()
            rawset(_G, FOLDER_STASH, espFolder)
        end
        Pooled = Pooled + 1
        local highlight = Instance.new("Highlight")
        highlight.Adornee = nil
        highlight.FillTransparency = 0.7
        highlight.OutlineTransparency = 0

        highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
        highlight.Parent = espFolder
        Pool[Pooled] = highlight

        rawset(_G, POOL_STASH, Pool)
        return highlight
    end

    local function Collect()
        local result = {}
        if not Settings.ESPPlayers and not Settings.ESPMobs then
            return result
        end

        local maxDistance = tonumber(Settings.ESPDistance) or 1500
        local localRoot = LocalPlayer and LocalPlayer.Character
            and LocalPlayer.Character:FindFirstChild("HumanoidRootPart")
        if not localRoot then
            return result
        end
        local origin = localRoot.Position

        local function add(model, root, name, color)
            local distance = (root.Position - origin).Magnitude
            if distance <= maxDistance then
                result[#result + 1] = {
                    Name = name,
                    Model = model,
                    Root = root,
                    Color = color,
                    Distance = distance,
                }
            end
        end

        if Settings.ESPPlayers then
            for _, player in Players:GetPlayers() do
                if player ~= LocalPlayer then
                    local character = player.Character
                    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
                    local root = character and character:FindFirstChild("HumanoidRootPart")
                    if humanoid and root and humanoid.Health > 0 then
                        add(character, root,
                            (player.DisplayName ~= "" and player.DisplayName) or player.Name,
                            ColorOr(DEFAULT_COLORS.Players, Settings.ESPColorPlayers))
                    end
                end
            end
        end

        if Settings.ESPMobs then

            for _, mob in Core.GetAliveMobs() do
                if mob.Model and mob.Root then
                    add(mob.Model, mob.Root, mob.Name,
                        ColorOr(DEFAULT_COLORS.Mobs, Settings.ESPColorMobs))
                end
            end
        end

        return result
    end

    local function NameLabel(entity)
        return string.format("%s  %dm", entity.Name, math.floor(entity.Distance))
    end

    local envelopeCache = setmetatable({}, { __mode = "k" })

    local ENVELOPE_DECAY = 0.95

    local function ScreenRect(model)
        local minX, minY, maxX, maxY = nil, nil, nil, nil

        for _, part in ipairs(model:GetChildren()) do
            if part:IsA("BasePart") and part.Transparency < 1 then
                local frame = part.CFrame
                local name = part.Name
                if part.Name == "HumanoidRootPart" then
                    frame = frame * CFrame.new(0, 0, -part.Size.Z)
                elseif name == "Head" then
                    frame = frame * CFrame.new(0, part.Size.Y / 2, part.Size.Z / 1.25)
                elseif string.find(name, "Left", 1, true) then
                    frame = frame * CFrame.new(-part.Size.X / 2, 0, 0)
                elseif string.find(name, "Right", 1, true) then
                    frame = frame * CFrame.new(part.Size.X / 2, 0, 0)
                end

                local screen, onScreen = Camera:WorldToViewportPoint(frame.Position)
                if onScreen then
                    if minX then
                        if screen.X < minX then minX = screen.X end
                        if screen.Y < minY then minY = screen.Y end
                        if screen.X > maxX then maxX = screen.X end
                        if screen.Y > maxY then maxY = screen.Y end
                    else
                        minX, minY, maxX, maxY = screen.X, screen.Y, screen.X, screen.Y
                    end
                end
            end
        end

        if not minX then
            return nil
        end

        local minSide = MIN_BOX_HALF * 2
        local width = maxX - minX
        local height = maxY - minY
        if width < minSide then width = minSide end
        if height < minSide then height = minSide end

        local envelope = envelopeCache[model]
        if not envelope then
            envelope = { Width = width, Height = height }
            envelopeCache[model] = envelope
        else
            envelope.Width = math.max(width, envelope.Width * ENVELOPE_DECAY)
            envelope.Height = math.max(height, envelope.Height * ENVELOPE_DECAY)
        end

        local centerX = (minX + maxX) / 2
        local centerY = (minY + maxY) / 2

        return centerX - envelope.Width / 2, centerY - envelope.Height / 2,
            envelope.Width, envelope.Height
    end

    local function Paint()
        local wantHighlight = Settings.ESPHighlight
        local wantBoxes = Settings.ESPBoxes
        local wantNames = Settings.ESPNames
        local wantAny = wantHighlight or wantBoxes or wantNames

        Camera = workspace.CurrentCamera
        if not Camera or not wantAny then
            LiveCount = 0
            for index = 1, Pooled do
                Pool[index].Adornee = nil
            end
            return
        end

        local entities = Collect()
        LiveCount = #entities

        local font = (Drawing and Drawing.Fonts and Drawing.Fonts.UI) or 0

        for index, entity in ipairs(entities) do
            local alive = entity.Model and entity.Model.Parent ~= nil

            if wantHighlight and alive then
                local highlight = Pool[index]
                if not highlight then
                    highlight = AcquireHighlight()
                end
                if highlight then
                    highlight.Adornee = entity.Model
                    highlight.FillColor = entity.Color
                    highlight.OutlineColor = entity.Color
                end
            elseif Pool[index] then
                Pool[index].Adornee = nil
            end

            if alive and (wantBoxes or wantNames) then
                local rectX, rectY, rectW, rectH = ScreenRect(entity.Model)
                if rectX then
                    local centerX = rectX + rectW / 2

                    if wantBoxes then

                        DrawingImmediate.Rectangle(
                            Vector2.new(rectX, rectY),
                            Vector2.new(rectW, rectH),
                            BOX_OUTLINE, 1, 0, BOX_THICKNESS * 2)

                        DrawingImmediate.Rectangle(
                            Vector2.new(rectX, rectY),
                            Vector2.new(rectW, rectH),
                            entity.Color, 1, 0, BOX_THICKNESS)
                    end

                    if wantNames then

                        DrawingImmediate.OutlinedText(
                            Vector2.new(centerX, rectY - NAME_GAP - NAME_SIZE / 2),
                            font, NAME_SIZE,
                            entity.Color, 1,
                            NAME_OUTLINE, 1,
                            NameLabel(entity), true)
                    end
                end
            end
        end

        for index = #entities + 1, Pooled do
            Pool[index].Adornee = nil
        end
    end

    local connection

    local function OnPaint()
        local ok, err = pcall(Paint)
        if not ok then

            pcall(print, "[core_esp] Paint failed: " .. tostring(err))
        end
    end

    local function Start()
        if connection then
            return false
        end
        if not HAS_DRAWING then
            pcall(print, "[core_esp] DrawingImmediate недоступен: "
                .. "рамки и имена рисовать нечем")
            return false
        end

        local ok, err = pcall(function()
            local paint = DrawingImmediate.GetPaint(PAINT_ZINDEX)
            connection = paint:Connect(OnPaint)
        end)
        if not ok then
            pcall(print, "[core_esp] не удалось подключиться: " .. tostring(err))
            return false
        end

        rawset(_G, CONN_STASH, connection)
        return true
    end

    local function Stop()
        if connection then
            pcall(function() connection:Disconnect() end)
            connection = nil
        end
        rawset(_G, CONN_STASH, nil)
        for index = 1, Pooled do
            pcall(function() Pool[index]:Destroy() end)
        end
        Pool = {}
        Pooled = 0
        LiveCount = 0
        rawset(_G, POOL_STASH, nil)
        if espFolder and espFolder.Destroy then
            pcall(function() espFolder:Destroy() end)
        end
        espFolder = nil
        rawset(_G, FOLDER_STASH, nil)
    end

    local function Count()
        return LiveCount
    end

    _G.Core.ESP = {
        Start = Start,
        Stop = Stop,
        Update = function() Paint() end,
        Count = Count,
        DefaultColors = DEFAULT_COLORS,
        HasDrawing = HAS_DRAWING,
    }

    OnUnload(Stop)

end

do

    local TICK_STASH = "SL2MovementTick"
    local JUMP_STASH = "SL2MovementJump"
    local SAVED_STASH = "SL2MovementSaved"

    local function DisconnectStash(key)
        local connection = rawget(_G, key)
        if connection then
            pcall(function() connection:Disconnect() end)
        end
        rawset(_G, key, nil)
    end

    DisconnectStash(TICK_STASH)
    DisconnectStash(JUMP_STASH)

    local function CleanupPrevious()
        DisconnectStash(TICK_STASH)
        DisconnectStash(JUMP_STASH)

        local previousSaved = rawget(_G, SAVED_STASH)
        rawset(_G, SAVED_STASH, nil)
        if type(previousSaved) ~= "table" then
            return
        end
        for part, previous in pairs(previousSaved) do
            pcall(function() part.CanCollide = previous end)
        end
    end

    CleanupPrevious()

    local staminaValue

    local function ResolveStamina(force)
        if staminaValue and not force then
            return staminaValue
        end
        staminaValue = nil

        local playerService = ReplicatedStorage:FindFirstChild("Player_Service")
        local values = playerService and playerService:FindFirstChild("Values")
        if not values then
            return nil
        end

        local candidates = { LocalPlayer.Name }
        local display = LocalPlayer.DisplayName
        if display and display ~= LocalPlayer.Name then
            candidates[#candidates + 1] = display
        end

        for _, folderName in ipairs(candidates) do
            local folder = values:FindFirstChild(folderName)
            local candidate = folder and folder:FindFirstChild("Stamina")
            if candidate and candidate:IsA("ValueBase") then
                staminaValue = candidate
                return staminaValue
            end
        end

        return nil
    end

    local dashCooldownSaved
    local dashSkillEntry
    local dashEntryFoundAt = 0

    local function ScanDashSkill()
        local sc = RequireCached("SkillController", function()
            return require(ReplicatedStorage.CAM.Client.Controllers.Skill_Controller)
        end)
        if type(sc) ~= "table" then
            return nil
        end
        for _, member in pairs(sc) do
            if type(member) == "function" then
                local ok, upvalues = pcall(function() return debug.getupvalues(member) end)
                if ok and type(upvalues) == "table" then
                    for _, upvalue in ipairs(upvalues) do
                        if type(upvalue) == "table"
                            and type(upvalue.skill_info) == "table"
                            and type(upvalue.skill_info.Dash) == "table" then
                            return upvalue.skill_info.Dash
                        end
                    end
                end
            end
        end
        return nil
    end

    local DASH_RESCAN_INTERVAL = 5.0

    local function ResolveDashSkill()
        local now = os.clock()
        if dashSkillEntry and (now - dashEntryFoundAt) < DASH_RESCAN_INTERVAL then
            return dashSkillEntry
        end
        local fresh = ScanDashSkill()
        if fresh ~= dashSkillEntry then

            if dashSkillEntry and dashCooldownSaved ~= nil then
                pcall(function() dashSkillEntry.Cooldown = dashCooldownSaved end)
            end
            dashCooldownSaved = nil
        end
        dashSkillEntry = fresh
        dashEntryFoundAt = now
        return dashSkillEntry
    end

    local function ApplyNoDashCooldown()
        local entry = ResolveDashSkill()
        if not entry then
            return
        end
        if dashCooldownSaved == nil then
            dashCooldownSaved = entry.Cooldown
        end
        entry.Cooldown = 0
    end

    local function RestoreDashCooldown()
        local entry = ResolveDashSkill()
        if entry and dashCooldownSaved ~= nil then
            entry.Cooldown = dashCooldownSaved
        end
        dashCooldownSaved = nil

    end

    local noclipApplied = false

    local noclipSaved = {}
    rawset(_G, SAVED_STASH, noclipSaved)

    local function RestoreCollisions()
        for part, previous in pairs(noclipSaved) do
            pcall(function() part.CanCollide = previous end)
        end
        for part in pairs(noclipSaved) do
            noclipSaved[part] = nil
        end
        noclipApplied = false
    end

    local function Character()
        return LocalPlayer.Character
    end

    local function HumanoidOf(char)
        return char and char:FindFirstChildOfClass("Humanoid")
    end

    local function RootOf(char)
        return char and char:FindFirstChild("HumanoidRootPart")
    end

    local function ApplyNoclip(char)
        for _, part in ipairs(char:GetDescendants()) do
            if part:IsA("BasePart") then

                if noclipSaved[part] == nil then
                    noclipSaved[part] = part.CanCollide
                end
                part.CanCollide = false
            end
        end
        noclipApplied = true
    end

    local FLY_KEYS_UP = Enum.KeyCode.Space
    local FLY_KEYS_DOWN = Enum.KeyCode.LeftShift

    local function FlyVelocity(char)
        local root = RootOf(char)
        if not root then
            return nil
        end

        local camera = workspace.CurrentCamera
        local look = camera and camera.CFrame.LookVector or Vector3.new(0, 0, -1)

        local move = Vector3.zero
        if UserInputService:IsKeyDown(Enum.KeyCode.W) then
            move += look
        end
        if UserInputService:IsKeyDown(Enum.KeyCode.S) then
            move -= look
        end

        local flatLook = Vector3.new(look.X, 0, look.Z)
        if flatLook.Magnitude > 0.001 then
            local side = flatLook.Unit:Cross(Vector3.yAxis)
            if UserInputService:IsKeyDown(Enum.KeyCode.D) then
                move += side
            end
            if UserInputService:IsKeyDown(Enum.KeyCode.A) then
                move -= side
            end
        end

        if UserInputService:IsKeyDown(FLY_KEYS_UP) then
            move += Vector3.yAxis
        end
        if UserInputService:IsKeyDown(FLY_KEYS_DOWN) then
            move -= Vector3.yAxis
        end

        if move.Magnitude < 0.001 then
            return Vector3.zero
        end

        local speed = tonumber(Settings.MovementFlySpeed) or 70
        return move.Unit * speed
    end

    local flying = false

    local function SetFlyState(enabled)
        enabled = enabled and true or false
        if enabled == flying then
            return
        end
        flying = enabled

        if enabled then
            return
        end

        local root = RootOf(Character())
        if root then
            pcall(function() root.AssemblyLinearVelocity = Vector3.zero end)
        end
    end

    local AIR_JUMP_UP = 45
    local AIR_JUMP_MIN_FALL = -0.5

    local function IsJumpInput(input)
        if type(input) ~= "table" and typeof(input) ~= "Instance" then
            return false
        end
        local ok, keyCode = pcall(function() return input.KeyCode end)
        if not ok then
            return false
        end
        return keyCode == Enum.KeyCode.Space or keyCode == Enum.KeyCode.ButtonA
    end

    local function OnJumpInput(input)
        if not Settings.MovementInfJumps then
            return
        end

        if not IsJumpInput(input) then
            return
        end

        local char = Character()
        local humanoid = HumanoidOf(char)
        local root = RootOf(char)
        if not humanoid or not root then
            return
        end

        if humanoid:GetState() ~= Enum.HumanoidStateType.Freefall then
            return
        end

        local vertical = root.AssemblyLinearVelocity.Y
        if vertical > AIR_JUMP_MIN_FALL then
            return
        end

        pcall(function()
            humanoid:ChangeState(Enum.HumanoidStateType.Jumping)
            root.AssemblyLinearVelocity = Vector3.new(
                root.AssemblyLinearVelocity.X, AIR_JUMP_UP, root.AssemblyLinearVelocity.Z
            )
        end)
    end

    local lastCharacter

    local function Tick()
        local char = Character()
        if not char then

            RestoreCollisions()
            lastCharacter = nil
            SetFlyState(false)
            return
        end

        if char ~= lastCharacter then
            if lastCharacter then

                RestoreCollisions()
            end
            lastCharacter = char
        end

        if Settings.MovementInfStamina then
            local stamina = ResolveStamina()
            if stamina then
                local max = stamina.MaxValue
                if type(max) == "number" and stamina.Value < max then
                    stamina.Value = max
                end
            end
        end

        if Settings.MovementInfDashes then
            ApplyNoDashCooldown()
        elseif dashCooldownSaved ~= nil then
            RestoreDashCooldown()
        end

        if Settings.MovementNoclip then
            ApplyNoclip(char)
        elseif noclipApplied or next(noclipSaved) ~= nil then
            RestoreCollisions()
        end

        if Settings.MovementFly then
            local root = RootOf(char)
            if root then
                local velocity = FlyVelocity(char)
                if velocity then
                    pcall(function() root.AssemblyLinearVelocity = velocity end)
                end
                flying = true
            end
        else
            SetFlyState(false)
        end
    end

    local function Start()
        if rawget(_G, TICK_STASH) then
            return false
        end

        ResolveStamina()
        ResolveDashSkill()

        local okTick, tickConnection = pcall(function()
            return RunService.Heartbeat:Connect(Tick)
        end)
        if not okTick then
            pcall(print, "[core_movement] Heartbeat не подключился: "
                .. tostring(tickConnection))
            return false
        end
        rawset(_G, TICK_STASH, tickConnection)

        local okJump, jumpConnection = pcall(function()
            return UserInputService.InputBegan:Connect(OnJumpInput)
        end)
        if not okJump then

            pcall(print, "[core_movement] InputBegan не подключился: "
                .. tostring(jumpConnection))
        else
            rawset(_G, JUMP_STASH, jumpConnection)
        end

        return true
    end

    local function Stop()
        DisconnectStash(TICK_STASH)
        DisconnectStash(JUMP_STASH)
        RestoreCollisions()
        staminaValue = nil
        RestoreDashCooldown()
        SetFlyState(false)
    end

    local function Status()
        local stamina = ResolveStamina()
        local dash = ResolveDashSkill()
        return {
            Stamina = stamina and tostring(stamina.Value) or "нет",
            StaminaMax = stamina and tostring(stamina.MaxValue) or "нет",
            DashCooldown = dash and tostring(dash.Cooldown) or "нет",
            DashSaved = dashCooldownSaved ~= nil and tostring(dashCooldownSaved) or "нет",
            Noclip = noclipApplied,
            Fly = flying,
        }
    end

    _G.Core.Movement = {
        Start = Start,
        Stop = Stop,
        Status = Status,

        SetNoclip = function(value) Settings.MovementNoclip = value and true or false end,
        SetFly = function(value) Settings.MovementFly = value and true or false end,
        SetInfStamina = function(value) Settings.MovementInfStamina = value and true or false end,
        SetInfDashes = function(value) Settings.MovementInfDashes = value and true or false end,
        SetInfJumps = function(value) Settings.MovementInfJumps = value and true or false end,
    }

    OnUnload(Stop)

end

do

    local CONFIRM_DELAY = 0.25

    local State = {

        LastKill = nil,
        LastKillAt = 0,

        LastRefusal = nil,

        Reverted = 0,

        Kills = 0,
    }

    local function ThresholdRatio()
        local required = tonumber(Settings.KillThreshold) or 10
        if required < 0 then
            required = 0
        elseif required > 100 then
            required = 100
        end
        return required
    end

    local function OwnershipProbe()
        if type(isnetworkowner) == "function" then
            return isnetworkowner
        end
        if type(getgenv) == "function" then
            local env = getgenv()
            local probe = type(env) == "table"
                and rawget(env, "isnetworkowner") or nil
            if type(probe) == "function" then
                return probe
            end
        end
        return nil
    end

    local function OwnershipKnown(root)
        if not root then
            return nil
        end
        local probe = OwnershipProbe()
        if not probe then
            return nil
        end
        local ok, owned = pcall(probe, root)
        if not ok or type(owned) ~= "boolean" then
            return nil
        end
        return owned
    end

    local function ConfirmKill(humanoid, wasOwned)
        task.delay(CONFIRM_DELAY, function()

            if humanoid.Parent == nil then
                return
            end
            if humanoid.Health > 0 then
                State.Reverted = State.Reverted + 1
                State.LastRefusal = (wasOwned == false)
                    and "нет владения, сервер откатил"
                    or "сервер откатил запись"
            end
        end)
    end

    local function KillNpc(target)
        local humanoid = target.humanoid
        if not humanoid or humanoid.Parent == nil then
            State.LastRefusal = "нет гуманоида"
            return { ok = false, reason = "нет гуманоида" }
        end
        if humanoid.Health <= 0 then
            State.LastRefusal = "уже мёртв"
            return { ok = false, name = target.name, reason = "уже мёртв" }
        end

        local ratio = humanoid.MaxHealth > 0
            and (humanoid.Health / humanoid.MaxHealth) or 0

        local dealt = (1 - ratio) * 100

        local required = ThresholdRatio()
        if dealt + 0.0001 < required then
            State.LastRefusal = string.format("порог: снято %.0f%% < надо %.0f%%",
                dealt, required)
            return { ok = false, name = target.name, dealt = dealt,
                     required = required, reason = "порог не достигнут" }
        end

        local model = humanoid.Parent
        local root = model and model:FindFirstChild("HumanoidRootPart") or nil
        local owned = OwnershipKnown(root)
        if owned ~= true then

            State.LastRefusal = (owned == false)
                and "нет владения"
                or "владение неизвестно, запись не проверена"
            return { ok = false, name = target.name, owned = owned,
                     reason = State.LastRefusal }
        end

        local before = humanoid.Health

        humanoid.Health = 0
        humanoid:ChangeState(Enum.HumanoidStateType.Dead)

        State.LastKill = target.name
        State.LastKillAt = os.clock()
        State.LastRefusal = nil
        State.Kills = State.Kills + 1
        ConfirmKill(humanoid, owned)

        return { ok = true, name = target.name, before = before,
                 dealt = dealt, owned = owned }
    end

    local function MaybeKill(human, name)
        if not Settings.InstantKill then
            return nil
        end
        if not human or typeof(human) ~= "Instance" then
            State.LastRefusal = "нет гуманоида"
            return { ok = false, reason = "нет гуманоида" }
        end
        return KillNpc({ humanoid = human, name = name })
    end

    local function Status()
        local parts = {}
        if State.LastKill then
            parts[#parts + 1] = string.format("last: %s (%.1fs ago)",
                tostring(State.LastKill), os.clock() - (State.LastKillAt or 0))
        end
        parts[#parts + 1] = "kills: " .. State.Kills
        if State.LastRefusal then
            parts[#parts + 1] = "refused: " .. tostring(State.LastRefusal)
        end
        if State.Reverted > 0 then
            parts[#parts + 1] = "reverted: " .. State.Reverted
        end
        return table.concat(parts, " | ")
    end

    local EXPORTS = {
        MaybeKill = MaybeKill,
        KillNpc = KillNpc,
        OwnershipKnown = OwnershipKnown,
        OwnershipProbe = OwnershipProbe,
        ThresholdRatio = ThresholdRatio,
        Status = Status,
        State = State,
    }

    _G.Core = _G.Core or {}
    _G.Core.InstantKill = EXPORTS

end

do

    local Loop = _G.Core.Loop
        or error("core_loop.luau должен быть загружен раньше ui_auto.luau")

    local function AsCallback(fn)
        if type(fn) ~= "function" then
            return fn
        end
        local maker = rawget(_G, "newcclosure") or (type(getgenv) == "function"
            and rawget(getgenv(), "newcclosure") or nil)
        if type(maker) ~= "function" then
            return fn
        end
        local ok, wrapped = pcall(maker, fn)
        if not ok or typeof(wrapped) ~= "function" then
            return fn
        end
        return wrapped
    end

    local function BuildMobValues()
        local aliveList, idleList = {}, {}
        for _, entry in ipairs(Core.GetNormalMobRoster()) do
            if entry.alive then
                aliveList[#aliveList + 1] = entry.name
            else
                idleList[#idleList + 1] = entry.name
            end
        end
        table.sort(aliveList)
        table.sort(idleList)
        for _, name in ipairs(idleList) do
            aliveList[#aliveList + 1] = name
        end
        return aliveList
    end

    local function BuildBossValues()
        local aliveList, readyList, idleList = {}, {}, {}
        for _, boss in ipairs(Core.GetSpawnableBosses()) do
            local label = string.format("%s  -  %s", boss.Name, tostring(boss.Chest))
            if boss.alive then
                table.insert(aliveList, label)
            elseif boss.registered then
                table.insert(readyList, label)
            else
                table.insert(idleList, label .. "  (не зарегистрирован)")
            end
        end
        local result = {}
        for _, group in ipairs({ aliveList, readyList, idleList }) do
            table.sort(group)
            for _, label in ipairs(group) do
                table.insert(result, label)
            end
        end
        return result
    end

    local function BuildHuntValues()
        local names = {}
        for _, hunt in ipairs(Core.GetBossHunts()) do
            names[#names + 1] = Core.HuntLabel(hunt)
        end
        return names
    end

    local function StripBossLabel(label)
        if type(label) ~= "string" then
            return nil
        end
        return (string.match(label, "^(.-)%s+%-%s+") or label)
    end

    local function HuntIdFromLabel(label)
        if type(label) ~= "string" then
            return nil
        end
        return string.match(label, "%((%d+)%)")
    end

    local OBSIDIAN_REPO = _G.ObsidianRepo
        or "https://raw.githubusercontent.com/deividcomsono/Obsidian/refs/heads/main/"

    local function LoadRemote(path)
        local chunk, err = loadstring(game:HttpGet(OBSIDIAN_REPO .. path))
        if type(chunk) ~= "function" then
            return nil, tostring(err)
        end
        local ok, result = pcall(chunk)
        if not ok then
            return nil, tostring(result)
        end
        return result
    end

    local Library, libraryError = LoadRemote("Library.lua")
    if type(Library) ~= "table" then
        error("Obsidian Library не загрузился: " .. tostring(libraryError))
    end

    local LIB_STASH = "SL2ObsidianLibrary"
    local PICKER_STASH = "SL2ObsidianKeypickers"

    local keypickers = {}

    local function RegisterKeyPicker(picker)
        if type(picker) == "table" and type(picker.Connections) == "table" then
            keypickers[#keypickers + 1] = picker
        end
        return picker
    end

    local function DisconnectKeypickers(list)
        if type(list) ~= "table" then
            return
        end
        for _, picker in ipairs(list) do
            for _, connection in ipairs(picker.Connections or {}) do
                if connection and connection.Connected then
                    pcall(function() connection:Disconnect() end)
                end
            end
        end
    end

    do
        local previousPickers = rawget(_G, PICKER_STASH)
        if previousPickers then
            DisconnectKeypickers(previousPickers)
        end
        rawset(_G, PICKER_STASH, nil)

        local previous = rawget(_G, LIB_STASH)
        if previous and type(previous.Unload) == "function" then

            pcall(function() previous:Unload() end)
        end
        rawset(_G, LIB_STASH, Library)
    end

    local libraryToggleOriginal = nil

    local function UnloadInterface()
        DisconnectKeypickers(rawget(_G, PICKER_STASH))
        rawset(_G, PICKER_STASH, nil)
        keypickers = {}

        local library = rawget(_G, LIB_STASH)
        if library and libraryToggleOriginal then
            library.Toggle = libraryToggleOriginal
        end
        libraryToggleOriginal = nil

        if library and type(library.Unload) == "function" then
            pcall(function() library:Unload() end)
        end
        rawset(_G, LIB_STASH, nil)
    end

    OnUnload(UnloadInterface)

    Library.ShowToggleFrameInKeybinds = true

    local ThemeManager, themeError = LoadRemote("addons/ThemeManager.lua")
    local SaveManager, saveError = LoadRemote("addons/SaveManager.lua")

    local WINDOW_ICON = "17210785932"

    local Window = Library:CreateWindow({
        Title = "SL2 pohuyhub",
        Footer = "version: 0.0.1",
        Icon = WINDOW_ICON,
        NotifySide = "Right",
    })

    local NOTIFY_COLORS = {
        warning = Color3.fromRGB(255, 165, 60),
        error = Color3.fromRGB(220, 38, 38),
        success = Color3.fromRGB(125, 233, 125),
    }

    table.freeze(NOTIFY_COLORS)

    local function Notify(title, message, kind, seconds)
        pcall(function()
            Library:Notify({
                Title = tostring(title or ""),
                Description = tostring(message or ""),
                Time = tonumber(seconds) or 5,
                IconColor = NOTIFY_COLORS[kind],
            })
        end)
    end

    local controlErrors = {}
    local controlTimeline = {}
    local startedAt = os.clock()

    local function AddControl(create, label)
        local result = table.pack(pcall(create))
        local elapsed = os.clock() - startedAt
        local name = tostring(label or "?")
        if not result[1] then

            local message = tostring(result[2])
            local line = string.format("FAIL %-18s %.2fs  %s", name, elapsed, message)
            controlErrors[#controlErrors + 1] = line
            controlTimeline[#controlTimeline + 1] = line
            pcall(print, "[ui_auto] control failed: " .. name .. " -> " .. message
                .. string.format(" (%.2fs)", elapsed))
            return nil
        end
        controlTimeline[#controlTimeline + 1] =
            string.format("ok   %-16s %.2fs", name, elapsed)

        local control = result[2]
        if typeof(control) == "table" then
            if type(control.Callback) == "function" then
                control.Callback = AsCallback(control.Callback)
            end
            if type(control.Func) == "function" then
                control.Func = AsCallback(control.Func)
            end
        end
        return control
    end

    local FLAG = {
        FarmMobs     = "FarmMobs",
        FarmBosses   = "FarmBosses",
        FarmHunt     = "FarmHunt",
        SelectMobs   = "SelectMobs",
        SelectBosses = "SelectBosses",
        LockTarget   = "LockTarget",
        AutoSkills   = "AutoSkills",
        AutoLoad     = "AutoLoad",
        AutoLoadCooldown = "AutoLoadCooldown",
        InstantKill  = "InstantKill",
        KillThreshold = "KillThreshold",
        Distance     = "Distance",
        LootWait     = "LootWait",
        Position     = "Position",
        FarmMethod   = "FarmMethod",
        MultiHitCount = "MultiHitCount",
        RefreshHunts = "RefreshHunts",
        WaitLoot     = "WaitLoot",
        AutoOpenChest = "AutoOpenChest",
        AutoCollectDrop = "AutoCollectDrop",
        SkillInterval = "SkillInterval",
        AutoEquip = "AutoEquip",
        EquipItem = "EquipItem",
        ESPPlayers   = "ESPPlayers",
        ESPMobs      = "ESPMobs",
        ESPHighlight = "ESPHighlight",
        ESPBoxes     = "ESPBoxes",
        ESPNames     = "ESPNames",
        ESPDistance  = "ESPDistance",
        ESPColorPlayers = "ESPColorPlayers",
        ESPColorMobs    = "ESPColorMobs",
        MovementInfStamina = "MovementInfStamina",
        MovementInfDashes  = "MovementInfDashes",
        MovementInfJumps   = "MovementInfJumps",
        MovementNoclip     = "MovementNoclip",
        MovementFly        = "MovementFly",
        MovementNoclipKey  = "MovementNoclipKey",
        MovementFlyKey     = "MovementFlyKey",
    }

    local TAB_ICONS = {
        Auto = "bot",
        Travel = "map",
        World = "eye",
        Movement = "footprints",
        Settings = "cog",
    }

    table.freeze(TAB_ICONS)

    local Tabs = {
        Auto = Window:AddTab("Auto", TAB_ICONS.Auto),
        Travel = Window:AddTab("Travel", TAB_ICONS.Travel),
        World = Window:AddTab("World", TAB_ICONS.World),
        Movement = Window:AddTab("Movement", TAB_ICONS.Movement),
    }

    local UI = {
        FarmMobs = nil,
        FarmBosses = nil,
        SelectMobs = nil,
        SelectBosses = nil,
        FarmHunt = nil,
        LockTarget = nil,
        AutoSkills = nil,
        AutoLoad = nil,
        AutoLoadCooldown = nil,
        InstantKill = nil,
        KillThreshold = nil,
        Distance = nil,
        LootWait = nil,
        Position = nil,
        FarmMethod = nil,
        MultiHitCount = nil,
        WaitLoot = nil,
        AutoOpenChest = nil,
        AutoCollectDrop = nil,
        SkillInterval = nil,
        AutoEquip = nil,
        EquipItem = nil,
        ESPPlayers = nil,
        ESPMobs = nil,
        ESPHighlight = nil,
        ESPBoxes = nil,
        ESPNames = nil,
        ESPDistance = nil,
        ESPColorPlayers = nil,
        ESPColorMobs = nil,
        MovementInfStamina = nil,
        MovementInfDashes = nil,
        MovementInfJumps = nil,
        MovementNoclip = nil,
        MovementFly = nil,
    }

    local FarmBox = Tabs.Auto:AddTabbox({
        Side = "Left",
        Name = "Auto Farm",
    })

    local FarmSubTabs = {
        Mobs = FarmBox:AddTab("Mobs"),
        Bosses = FarmBox:AddTab("Bosses"),
    }

    local function NotifyFarm(kind, enabled)
        Notify(kind, enabled and "enabled" or "disabled",
            enabled and "success" or "warning", 2.5)
    end

    UI.FarmMobs = FarmSubTabs.Mobs:AddToggle(FLAG.FarmMobs, {
        Text = "Auto farm mobs",
        Default = false,
        Risky = true,
        Callback = function(value)
            Loop.SetMode("FarmMobs", value)
            NotifyFarm("Mobs farm", value)
        end,
    })

    UI.SelectMobs = FarmSubTabs.Mobs:AddDropdown(FLAG.SelectMobs, {
        Text = "Select mobs",
        Values = BuildMobValues(),
        Multi = true,
        Searchable = true,
        AllowNull = true,
    })

    UI.FarmBosses = FarmSubTabs.Bosses:AddToggle(FLAG.FarmBosses, {
        Text = "Auto farm bosses",
        Default = false,
        Risky = true,
        Callback = function(value)
            Loop.SetMode("FarmBosses", value)
            NotifyFarm("Bosses farm", value)
        end,
    })

    UI.SelectBosses = FarmSubTabs.Bosses:AddDropdown(FLAG.SelectBosses, {
        Text = "Select bosses",
        Values = BuildBossValues(),
        Multi = true,
        Searchable = true,
        AllowNull = true,
    })

    local HuntGroup = Tabs.Auto:AddGroupbox({
        Side = "Left",
        Name = "Hunt",
    })

    UI.FarmHunt = HuntGroup:AddToggle(FLAG.FarmHunt, {
        Text = "Auto hunt",
        Default = false,
        Risky = true,
        Tooltip = "Охота на активные ханты из ReplicatedStorage.BossHunts",
        Callback = function(value)
            Loop.SetMode("Hunt", value)
        end,
    })

    local CollectionsGroup = Tabs.Auto:AddGroupbox({
        Side = "Left",
        Name = "Collections",
    })

    UI.WaitLoot = CollectionsGroup:AddToggle(FLAG.WaitLoot, {
        Text = "Wait loot after kill",
        Default = false,
        Risky = true,
        Tooltip = "Ждать лут после босса или ханта. Обычные мобы лута не роняют",
        Callback = function(value)
            Settings.WaitLoot = value
            if not value and _G.Core.Loot then
                _G.Core.Loot.Reset()
            end
        end,
    })

    UI.LootWait = CollectionsGroup:AddSlider(FLAG.LootWait, {
        Text = "Loot wait (sec)",
        Default = 4.0,
        Min = 1.5,
        Max = 8.0,
        Rounding = 1,
        Tooltip = "Сколько ждать выпадения лута после смерти цели",
        Callback = function(value) Settings.LootWait = value end,
    })

    UI.AutoOpenChest = CollectionsGroup:AddToggle(FLAG.AutoOpenChest, {
        Text = "Auto open chest",
        Default = true,
        Callback = function(value) Settings.AutoOpenChest = value end,
    })

    UI.AutoCollectDrop = CollectionsGroup:AddToggle(FLAG.AutoCollectDrop, {
        Text = "Auto collect drop",
        Default = true,
        Callback = function(value) Settings.AutoCollectDrop = value end,
    })

    local KillGroup = Tabs.Auto:AddGroupbox({
        Side = "Left",
        Name = "Instant kill",
    })

    UI.InstantKill = AddControl(function()
        return KillGroup:AddToggle(FLAG.InstantKill, {
            Text = "Instant kill",
            Default = false,
            Risky = true,
            Tooltip = "Добивать цель автоматически, как только у неё снято "
                .. "не меньше указанного ниже процента здоровья. Нажатий не нужно",
            Callback = function(value) Settings.InstantKill = value end,
        })
    end, "InstantKill")

    UI.KillThreshold = AddControl(function()
        return KillGroup:AddSlider(FLAG.KillThreshold, {
            Text = "Kill threshold %",
            Default = 10,
            Min = 0,
            Max = 100,
            Rounding = 0,
            Tooltip = "Сколько процентов здоровья надо снять, чтобы сработало. "
                .. "0 - можно добить с полного здоровья",
            Callback = function(value) Settings.KillThreshold = value end,
        })
    end, "KillThreshold")

    local SettingsTab = Tabs.Auto:AddGroupbox({
        Side = "Right",
        Name = "Settings",
    })

    UI.Position = SettingsTab:AddDropdown(FLAG.Position, {
        Text = "Position",
        Values = {
            "Overhead (Safe - Recommended)",
            "Behind",
            "Underground",
        },
        Default = "Overhead (Safe - Recommended)",
        Callback = function(value) Settings.Position = value end,
    })

    UI.FarmMethod = SettingsTab:AddDropdown(FLAG.FarmMethod, {
        Text = "Farm method",
        Values = { "VirtualInput", "Events" },
        Default = "VirtualInput",
        Callback = function(value) Settings.FarmMethod = value end,
    })

    UI.LockTarget = SettingsTab:AddToggle(FLAG.LockTarget, {
        Text = "Lock Target",
        Default = true,
        Callback = function(value) Settings.LockTarget = value end,
    })

    UI.AutoSkills = SettingsTab:AddToggle(FLAG.AutoSkills, {
        Text = "Auto Use Skills",
        Default = true,
        Callback = function(value) Settings.AutoSkills = value end,
    })

    UI.AutoLoad = AddControl(function()
        return SettingsTab:AddToggle(FLAG.AutoLoad, {
            Text = "Auto load targets",
            Default = true,
            Callback = function(value) Settings.AutoLoad = value end,
        })
    end, "AutoLoad")

    UI.AutoLoadCooldown = AddControl(function()
        return SettingsTab:AddSlider(FLAG.AutoLoadCooldown, {
            Text = "Load cooldown (sec)",
            Default = 3.0,
            Min = 1,
            Max = 15,
            Decimals = 1,
            Callback = function(value) Settings.AutoLoadCooldown = value end,
        })
    end, "AutoLoadCooldown")

    UI.Distance = AddControl(function()
        return SettingsTab:AddSlider(FLAG.Distance, {
            Text = "Distance to npc",
            Default = 2.0,
            Min = 0.5,
            Max = 10,
            Rounding = 1,
            Callback = function(value) Settings.Distance = value end,
        })
    end, "Distance")

    UI.MultiHitCount = AddControl(function()
        return SettingsTab:AddSlider(FLAG.MultiHitCount, {
            Text = "Hits per cycle",
            Default = 1,
            Min = 1,
            Max = 5,
            Rounding = 0,

            Callback = function(value) Settings.MultiHitCount = value end,
        })
    end, "MultiHitCount")

    UI.SkillInterval = AddControl(function()
        return SettingsTab:AddSlider(FLAG.SkillInterval, {
            Text = "Skill interval (sec)",
            Default = 1.0,
            Min = 0.3,
            Max = 5.0,
            Rounding = 1,
            Tooltip = "How long between skills",
            Callback = function(value) Settings.SkillInterval = value end,
        })
    end, "SkillInterval")

    local function SelectedFrom(dropdown)
        if not dropdown or type(dropdown.GetActiveValues) ~= "function" then
            return {}
        end
        local ok, values = pcall(dropdown.GetActiveValues, dropdown)
        if not ok or type(values) ~= "table" then
            return {}
        end
        local result = {}
        for _, value in ipairs(values) do
            if type(value) == "string" and value ~= "" then
                result[#result + 1] = value
            end
        end
        return result
    end

    local BossNameFromHuntLabel = StripBossLabel

    local function CollectSelectedNpcs()
        local names = {}
        local sources = {}

        for _, label in ipairs(SelectedFrom(UI.SelectMobs)) do
            names[#names + 1] = label
            sources[#sources + 1] = "mobs"
        end
        for _, label in ipairs(SelectedFrom(UI.SelectBosses)) do
            local name = StripBossLabel(label)
            if name then
                names[#names + 1] = name
                sources[#sources + 1] = "bosses"
            end
        end
        local picked = Core.PickHuntTarget()
        if picked and picked.Boss then
            names[#names + 1] = picked.Boss
            sources[#sources + 1] = "hunts"
        end

        return names, sources
    end

    local function DoHoverSelected()
        local names = CollectSelectedNpcs()
        if #names == 0 then
            return
        end
        Core.TeleportToNpcs(names, "first")
    end

    local ESPBox = Tabs.World:AddTabbox({
        Side = "Left",
        Name = "ESP",
    })

    local ESPSubTabs = {
        Esp = ESPBox:AddTab("ESP"),
        Settings = ESPBox:AddTab("Settings"),
    }

    UI.ESPPlayers = ESPSubTabs.Esp:AddToggle(FLAG.ESPPlayers, {
        Text = "Players",
        Default = Settings.ESPPlayers,
        Callback = function(value) Settings.ESPPlayers = value end,
    })

    UI.ESPColorPlayers = UI.ESPPlayers:AddColorPicker(FLAG.ESPColorPlayers, {
        Default = Settings.ESPColorPlayers,
        Title = "Players color",
        Callback = function(value) Settings.ESPColorPlayers = value end,
    })

    UI.ESPMobs = ESPSubTabs.Esp:AddToggle(FLAG.ESPMobs, {
        Text = "Mobs",
        Default = Settings.ESPMobs,
        Callback = function(value) Settings.ESPMobs = value end,
    })

    UI.ESPColorMobs = UI.ESPMobs:AddColorPicker(FLAG.ESPColorMobs, {
        Default = Settings.ESPColorMobs,
        Title = "Mobs color",
        Callback = function(value) Settings.ESPColorMobs = value end,
    })

    UI.ESPHighlight = ESPSubTabs.Settings:AddToggle(FLAG.ESPHighlight, {
        Text = "Highlight",
        Default = Settings.ESPHighlight,
        Callback = function(value) Settings.ESPHighlight = value end,
    })

    UI.ESPBoxes = ESPSubTabs.Settings:AddToggle(FLAG.ESPBoxes, {
        Text = "Boxes",
        Default = Settings.ESPBoxes,
        Callback = function(value) Settings.ESPBoxes = value end,
    })

    UI.ESPNames = ESPSubTabs.Settings:AddToggle(FLAG.ESPNames, {
        Text = "Names",
        Default = Settings.ESPNames,
        Callback = function(value) Settings.ESPNames = value end,
    })

    UI.ESPDistance = ESPSubTabs.Settings:AddSlider(FLAG.ESPDistance, {
        Text = "Max distance",
        Default = Settings.ESPDistance,

        Min = 50,
        Max = 5000,
        Rounding = 0,

        Tooltip = "Draw ESP only for entities closer than this",
        Callback = function(value) Settings.ESPDistance = value end,
    })

    local MoveGroup = Tabs.Movement:AddGroupbox({
        Side = "Left",
        Name = "Player",
    })

    UI.MovementInfStamina = MoveGroup:AddToggle(FLAG.MovementInfStamina, {
        Text = "Infinite stamina",
        Default = Settings.MovementInfStamina,
        Tooltip = "Keep stamina at max",
        Callback = function(value) Settings.MovementInfStamina = value end,
    })

    UI.MovementInfDashes = MoveGroup:AddToggle(FLAG.MovementInfDashes, {
        Text = "Infinite dashes",
        Default = Core.Settings.MovementInfDashes,
        Tooltip = "Remove the dash cooldown",
        Callback = function(value) Core.Settings.MovementInfDashes = value end,
    })

    UI.MovementInfJumps = MoveGroup:AddToggle(FLAG.MovementInfJumps, {
        Text = "Infinite jumps",
        Default = Settings.MovementInfJumps,
        Tooltip = "Jump again while falling",
        Callback = function(value) Settings.MovementInfJumps = value end,
    })

    local function NotifySwitch(label, enabled)
        Notify(label, enabled and "enabled" or "disabled",
            enabled and "success" or "warning", 2.5)
    end

    UI.MovementNoclip = MoveGroup:AddToggle(FLAG.MovementNoclip, {
        Text = "Noclip",
        Default = Settings.MovementNoclip,
        Risky = true,
        Tooltip = "Walk through everything",
        Callback = function(value)
            Settings.MovementNoclip = value
            NotifySwitch("Noclip", value)
        end,
    })

    UI.MovementNoclip:AddKeyPicker(FLAG.MovementNoclipKey, {
        Text = "Noclip keybind",
        Default = "N",
        Mode = "Toggle",
        SyncToggleState = true,
    })
    RegisterKeyPicker(Library.Options and Library.Options[FLAG.MovementNoclipKey])

    UI.MovementFly = MoveGroup:AddToggle(FLAG.MovementFly, {
        Text = "Fly",
        Default = Settings.MovementFly,
        Risky = true,
        Tooltip = "WASD to move, Space up, LeftShift down",
        Callback = function(value)
            Settings.MovementFly = value
            NotifySwitch("Fly", value)
        end,
    })

    UI.MovementFly:AddKeyPicker(FLAG.MovementFlyKey, {
        Text = "Fly keybind",
        Default = "F",
        Mode = "Toggle",
        SyncToggleState = true,
    })
    RegisterKeyPicker(Library.Options and Library.Options[FLAG.MovementFlyKey])

    AddControl(function()
        return SettingsTab:AddButton({
            Text = "Unload",
            Tooltip = "Stop everything and remove the hub from the game",

            Callback = function()
                local unload = rawget(_G, "SL2_Unload")
                if type(unload) == "function" then
                    pcall(unload)
                end
            end,
        })
    end, "Unload")

    _G.AutoUI = {
        Library = Library,
        Window = Window,
        Tabs = Tabs,
        UI = UI,
        FarmBox = FarmBox,
        FarmSubTabs = FarmSubTabs,
        HuntGroup = HuntGroup,
        CollectionsGroup = CollectionsGroup,

        KillGroup = KillGroup,

        ESPBox = ESPBox,
        ESPSubTabs = ESPSubTabs,

        MoveGroup = MoveGroup,
        SettingsTab = SettingsTab,

        MenuKeybind = Library.Options and Library.Options.MenuKeybind,
        Flags = FLAG,

        SaveManager = SaveManager,
        ThemeManager = ThemeManager,
        Notify = Notify,

        StripBossLabel = StripBossLabel,
        HuntIdFromLabel = HuntIdFromLabel,
        BuildMobValues = BuildMobValues,
        BuildBossValues = BuildBossValues,
        BuildHuntValues = BuildHuntValues,

        SelectedFrom = SelectedFrom,
        CollectSelectedNpcs = CollectSelectedNpcs,
        BossNameFromHuntLabel = BossNameFromHuntLabel,
        DoHoverSelected = DoHoverSelected,
        Loop = Loop,

        Errors = controlErrors,

        Timeline = controlTimeline,
    }

    local ConfigTab, MenuGroup

    do
        local built, buildError = pcall(function()
            ConfigTab = Window:AddTab("Settings", TAB_ICONS.Settings)

            MenuGroup = ConfigTab:AddGroupbox({
                Side = "Left",
                Name = "Menu",
            })

            MenuGroup:AddToggle("KeybindMenuOpen", {
                Text = "Open keybind menu",
                Default = Library.KeybindFrame and Library.KeybindFrame.Visible or false,
                Callback = function(value)
                    if Library.KeybindFrame then
                        Library.KeybindFrame.Visible = value
                    end
                end,
            })

            MenuGroup:AddLabel("Menu keybind"):AddKeyPicker("MenuKeybind", {
                Default = "RightControl",
                NoUI = true,
                Text = "Menu keybind",
            })
            RegisterKeyPicker(Library.Options and Library.Options.MenuKeybind)

            Library.ToggleKeybind = Library.Options and Library.Options.MenuKeybind

            local function MenuKeyName()
                local picker = rawget(Library, "ToggleKeybind")
                if type(picker) ~= "table" then
                    picker = type(Library.Options) == "table"
                        and rawget(Library.Options, "MenuKeybind") or nil
                end
                if type(picker) ~= "table" then
                    return nil
                end
                local name = picker.DisplayValue
                if type(name) ~= "string" or name == "" then
                    name = picker.Value
                end
                if type(name) ~= "string" or name == "" then
                    return nil
                end
                return name
            end

            if type(Library.Toggle) == "function" then
                libraryToggleOriginal = Library.Toggle
                local originalToggle = libraryToggleOriginal
                Library.Toggle = function(self, value)
                    local result = originalToggle(self, value)
                    if rawget(Library, "Toggled") == false then
                        local key = MenuKeyName()
                        Notify("UI hidden",
                            key and ("press " .. key .. " to show")
                                or "press the menu keybind to show",
                            "warning", 4)
                    end
                    return result
                end
            end

            if type(SaveManager) == "table" and type(ThemeManager) == "table" then
                ThemeManager:SetLibrary(Library)
                SaveManager:SetLibrary(Library)

                SaveManager:IgnoreThemeSettings()

                SaveManager:SetIgnoreIndexes({ "MenuKeybind" })

                ThemeManager:SetFolder("SL2HUB")
                SaveManager:SetFolder("SL2HUB/Ouwland")

                SaveManager:BuildConfigSection(ConfigTab)
                ThemeManager:ApplyToTab(ConfigTab)

                SaveManager:LoadAutoloadConfig()
            else

                local problems = {}
                if type(ThemeManager) ~= "table" then
                    problems[#problems + 1] = "ThemeManager: " .. tostring(themeError)
                end
                if type(SaveManager) ~= "table" then
                    problems[#problems + 1] = "SaveManager: " .. tostring(saveError)
                end
                ConfigTab:AddGroupbox({ Side = "Left", Name = "Unavailable" })
                    :AddLabel("Config/Theme unavailable:\n" .. table.concat(problems, "\n"), true)
            end
        end)

        if not built then

            local message = tostring(buildError)
            controlErrors[#controlErrors + 1] = "Settings tab -> " .. message
            pcall(print, "[ui_auto] Settings tab failed: " .. message)
            ConfigTab, MenuGroup = nil, nil
        end
    end

    local function SelectTargets(modes)
        local active = {}
        for _, mode in ipairs(modes or {}) do
            active[mode] = true
        end

        local names, seen = {}, {}

        local function add(name)
            if type(name) == "string" and name ~= "" and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end

        if active.mobs then
            for _, label in ipairs(SelectedFrom(UI.SelectMobs)) do
                add(label)
            end
        end
        if active.bosses then
            for _, label in ipairs(SelectedFrom(UI.SelectBosses)) do
                add(StripBossLabel(label))
            end
        end
        if active.hunts then

            local picked = Core.PickHuntTarget()
            if picked and picked.Boss then
                add(picked.Boss)
            end
        end

        return names
    end

    Core.SelectTargets = SelectTargets

    local function ApplySettingsOrder()
        local order = {
            UI.Position,
            UI.FarmMethod,
            UI.LockTarget,
            UI.AutoSkills,
            UI.AutoEquip,
            UI.EquipItem,
            UI.Distance,
            UI.MultiHitCount,
            UI.SkillInterval,
        }

        for index, control in ipairs(order) do

            local holder = type(control) == "table" and control.Holder or nil
            if holder ~= nil then
                pcall(function() holder.LayoutOrder = index end)
            end
        end

        if type(SettingsTab) == "table" and type(SettingsTab.Resize) == "function" then
            pcall(function() SettingsTab:Resize() end)
        end
    end

    local function FinalizeSettingsColumn()
        pcall(ApplySettingsOrder)
    end

    if _G.SkipEquipBlock then
        controlTimeline[#controlTimeline + 1] = "блок AutoEquip пропущен (_G.SkipEquipBlock)"
    else
    do
        local okEquipBlock, equipError = pcall(function()
            local Equip = _G.Core and _G.Core.Equip

            local function BuildEquipValues()
                if not Equip or type(Equip.GetHotbarNames) ~= "function" then
                    return {}
                end
                local ok, names = pcall(Equip.GetHotbarNames)
                if not ok or type(names) ~= "table" then
                    return {}
                end
                return names
            end

            UI.AutoEquip = SettingsTab:AddToggle(FLAG.AutoEquip, {
                Text = "Auto equip",
                Default = false,
                Risky = true,
                Tooltip = "Equip the selected hotbar item when another is in hand",
                Callback = function(value)
                    Settings.AutoEquip = value

                    if Equip and value and type(Equip.Reset) == "function" then
                        Equip.Reset()
                    end
                end,
            })

            local equipValues = BuildEquipValues()
            local emptyHotbar = "(hotbar is empty)"

            local values = {}
            for _, name in ipairs(equipValues) do
                values[#values + 1] = tostring(name)
            end
            if #values == 0 then
                values[1] = emptyHotbar
            end

            task.spawn(function()
                UI.EquipItem = AddControl(function()
                    return SettingsTab:AddDropdown(FLAG.EquipItem, {
                        Text = "Equip item",
                        Values = values,
                        Default = values[1],
                        Callback = function(value)

                            if type(value) ~= "string" or value == emptyHotbar then
                                Settings.EquipItem = ""
                                return
                            end
                            Settings.EquipItem = value
                        end,
                    })
                end, "EquipItem")

                pcall(FinalizeSettingsColumn)

                if #equipValues > 0 then
                    Settings.EquipItem = tostring(equipValues[1])
                end

                local previousCount = -1
                while _G.Core and UI.EquipItem do
                    task.wait(60)
                    if not Equip or type(Equip.GetHotbarNames) ~= "function" then
                        continue
                    end
                    local ok, names = pcall(Equip.GetHotbarNames)
                    if not ok or type(names) ~= "table" then
                        continue
                    end
                    if #names == previousCount then
                        continue
                    end
                    previousCount = #names

                    local fresh = {}
                    for _, name in ipairs(names) do
                        fresh[#fresh + 1] = tostring(name)
                    end
                    if #fresh == 0 then
                        fresh[1] = emptyHotbar
                    end

                    local keep = Settings.EquipItem
                    if type(UI.EquipItem.SetValues) == "function" then
                        pcall(function() UI.EquipItem:SetValues(fresh) end)
                    end

                    if keep and keep ~= "" and not table.find(fresh, keep) then
                        Settings.EquipItem = ""
                    elseif keep and keep ~= ""
                        and type(UI.EquipItem.SetValue) == "function" then
                        pcall(function() UI.EquipItem:SetValue(keep) end)
                    end
                end
            end)
        end)

        if not okEquipBlock then

            pcall(print, "[ui_auto] AutoEquip block failed: " .. tostring(equipError))
        end
    end
    end
    Loop.Start()

    if Core.ESP and type(Core.ESP.Start) == "function" then
        pcall(function() Core.ESP.Start() end)
    end

    if Core.Movement and type(Core.Movement.Start) == "function" then
        pcall(function() Core.Movement.Start() end)
    end

    _G.AutoUI.ConfigTab = ConfigTab
    _G.AutoUI.MenuGroup = MenuGroup
    _G.AutoUI.SelectTargets = SelectTargets

    _G.AutoUI.UnloadButton = nil
    for _, element in ipairs(SettingsTab.Elements or {}) do
        if element.Type == "Button" and element.Text == "Unload" then
            _G.AutoUI.UnloadButton = element
            break
        end
    end

    local function HardenControlCallbacks(controls)
        local wrappedTotal, skippedTotal = 0, 0
        for _, control in pairs(controls) do
            if typeof(control) == "table" then
                local changedFlag = false

                for _, fieldName in ipairs({ "Callback", "Func" }) do
                    local handler = control[fieldName]
                    if type(handler) == "function" then
                        local alreadyHidden = type(isnewcclosure) == "function"
                            and isnewcclosure(handler) or false
                        if not alreadyHidden then
                            local wrappedHandler = AsCallback(handler)
                            if wrappedHandler ~= handler then
                                control[fieldName] = wrappedHandler
                                wrappedTotal = wrappedTotal + 1
                                changedFlag = true
                            end
                        end
                    end
                end
                if not changedFlag then
                    skippedTotal = skippedTotal + 1
                end
            end
        end
        return wrappedTotal, skippedTotal
    end

    _G.AutoUI.Hardened, _G.AutoUI.HardenedSkipped = HardenControlCallbacks(UI)

    rawset(_G, PICKER_STASH, keypickers)

    pcall(FinalizeSettingsColumn)

    pcall(FinalizeSettingsColumn)
end

local function SL2_Unload()
    local cleanups = SL2_CLEANUPS

    for index = #cleanups, 1, -1 do
        pcall(cleanups[index])
    end
    for index = #cleanups, 1, -1 do
        cleanups[index] = nil
    end

    rawset(_G, "Core", nil)
    rawset(_G, "AutoUI", nil)
    rawset(_G, "SL2_Unload", nil)
    rawset(_G, "SL2Unload", nil)
    return true
end

rawset(_G, "SL2_Unload", SL2_Unload)
rawset(_G, "SL2Unload", SL2_Unload)

return _G.AutoUI
