require("robolib.Squad")
require("stdlib/log/logger")
require("stdlib/game")


function bootstrap_migration_on_first_tick(event)


    -- substitute the 'normal' tick handler, and run it manually this time
    script.on_event(defines.events.on_tick, handleTick)
    handleTick(event)
end


function global_ensureTablesExist()
    if not storage.updateTable then storage.updateTable = {} end
    if not storage.Squads then storage.Squads = {} end
    if not storage.AssemblerRetreatTables then storage.AssemblerRetreatTables = {} end
    if not storage.AssemblerNearestEnemies then storage.AssemblerNearestEnemies = {} end
    if not storage.DroidAssemblers then storage.DroidAssemblers = {} end
    if not storage.droidGuardStations then storage.droidGuardStations = {} end
end



-- migration helper: when this mod takes over from the original robotarmy mod (or is first added
-- to an existing save), the storage tables start out empty, so all placed buildings are untracked
-- and deployed droids are orphaned stragglers with no squad. this re-registers the buildings and
-- adopts orphaned droids into squads, mirroring what happens when they are first placed/spawned.
-- migration helper: runOnceCheck calls force.reset_recipes() when storage is fresh, which resets
-- every recipe to its prototype default. tech-locked recipes default to disabled, and the engine
-- does not re-apply unlock effects for already-researched technologies, so recipes for techs that
-- were researched before the migration would stay locked (empty recipe menu on assemblers).
-- this re-enables every recipe unlocked by a technology the force has already researched.
-- note: in Factorio 2.0 the effects list lives on LuaTechnology.prototype, not the technology.
function reEnableRecipesForResearchedTechnologies(force)
    local enabled_count = 0
    for _, tech in pairs(force.technologies) do
        if tech.researched then
            for _, effect in pairs(tech.prototype.effects) do
                if effect.type == "unlock-recipe" and force.recipes[effect.recipe] then
                    if not force.recipes[effect.recipe].enabled then
                        force.recipes[effect.recipe].enabled = true
                        enabled_count = enabled_count + 1
                    end
                end
            end
        end
    end
    if enabled_count > 0 then
        LOGGER.log(string.format("Migration for force %s: re-enabled %d recipe(s) unlocked by researched technologies",
                                 force.name, enabled_count))
    end
end

function migrateOrphanedDroidsAndBuildings(force)
    local force_name = force.name
    local adopted = 0
    local registered = 0

    if not storage.settingsModule then storage.settingsModule = {} end
    if not storage.units then storage.units = {} end

    for _, surface in pairs(game.surfaces) do
        -- re-register droid assemblers
        local assemblers = surface.find_entities_filtered{name = "droid-assembling-machine", force = force}
        for _, assembler in pairs(assemblers) do
            if not storage.DroidAssemblers[force_name] or not storage.DroidAssemblers[force_name][assembler.unit_number] then
                handleDroidAssemblerPlaced({entity = assembler})
                registered = registered + 1
            end
        end

        -- re-register guard stations, avoiding duplicate entries for the same station
        local stations = surface.find_entities_filtered{name = "droid-guard-station", force = force}
        for _, station in pairs(stations) do
            local known = false
            if storage.droidGuardStations[force_name] then
                for _, tracked in pairs(storage.droidGuardStations[force_name]) do
                    if tracked.unit_number == station.unit_number then known = true end
                end
            end
            if not known then
                handleGuardStationPlaced({entity = station})
                registered = registered + 1
            end
        end

        -- re-register the single-per-force buildings, same rules as when they are placed by hand
        local chests = surface.find_entities_filtered{name = "loot-chest", force = force}
        for _, chest in pairs(chests) do
            if not storage.lootChests[force_name] or not storage.lootChests[force_name].valid then
                handleBuiltLootChest({entity = chest})
                registered = registered + 1
            end
        end

        local settingsModules = surface.find_entities_filtered{name = "droid-settings", force = force}
        for _, settingsModule in pairs(settingsModules) do
            if not storage.settingsModule[force_name] or not storage.settingsModule[force_name].valid then
                handleBuiltDroidSettings({entity = settingsModule})
                registered = registered + 1
            end
        end

        -- re-register droid counters, avoiding duplicate entries for the same counter
        local counters = surface.find_entities_filtered{name = "droid-counter", force = force}
        for _, counter in pairs(counters) do
            local known = false
            if storage.droidCounters[force_name] then
                for _, tracked in pairs(storage.droidCounters[force_name]) do
                    if tracked.unit_number == counter.unit_number then known = true end
                end
            end
            if not known then
                handleBuiltDroidCounter({entity = counter})
                registered = registered + 1
            end
        end

        -- adopt orphaned droids into squads, only when the automated squad behaviours are enabled
        if not script.active_mods["Unit_Controll"] then
            local droids = surface.find_entities_filtered{type = "unit", force = force, name = squadCapable}
            for _, droid in pairs(droids) do
                if not storage.units[droid.unit_number] then
                    processSpawnedDroid(droid)
                    adopted = adopted + 1
                end
            end
        end
    end

    if adopted > 0 or registered > 0 then
        LOGGER.log(string.format("Migration for force %s: registered %d building(s), adopted %d orphaned droid(s) into squads",
                                 force_name, registered, adopted))
        Game.print_force(force, string.format("Robot Army: re-registered %d building(s) and adopted %d droid(s) back into squads",
                                              registered, adopted))
    end
    return adopted
end


-- migration helper: adoption joins each orphan to the nearest squad (or makes a new one), which
-- leaves lots of small squads scattered around the assemblers. small squads below the hunting
-- squad size will never attack, and merging in normal play only happens between squads near the
-- same assembler, so these fragments can sit around forever. this consolidates them: every
-- squad is merged into the nearest other squad, largest first, until nothing more can combine.
-- distance cap for migration-time merges: merging squads whose members are far apart would get
-- the far members kicked out of the merged squad by validateSquadIntegrity (they orphan again),
-- so only pool squads within this range of each other
MIGRATION_MERGE_MAX_DISTANCE = 150

-- migration helper: adoption joins each orphan to the nearest squad (or makes a new one), which
-- leaves lots of small squads scattered around the assemblers. small squads below the hunting
-- squad size will never attack, and merging in normal play only happens between squads near the
-- same assembler, so these fragments can sit around forever. this consolidates the idle ones:
-- each squad is merged into its nearest eligible neighbour, largest first, until nothing more
-- can combine. guard/patrol/follow squads are left alone, only idle waiting squads are pooled.
function consolidateMigratedSquads(force)
    local merged_count = 0
    local merging = true
    while merging do
        merging = false
        -- build a fresh list each pass, squads get deleted as they merge away
        local squads = {}
        for _, squad in pairs(storage.Squads[force.name]) do
            if squad and not squad.deleted and squad.numMembers and squad.numMembers > 0
                and (squad.command.type == commands.assemble or squad.command.type == commands.hunt) then
                table.insert(squads, squad)
            end
        end
        -- largest first so big squads absorb the small ones, keeping their unit group positions
        table.sort(squads, function(a, b) return a.numMembers > b.numMembers end)
        for i, squad in pairs(squads) do
            if squad and not squad.deleted then
                local other = nil
                local other_dist = nil
                for j = i + 1, #squads do
                    local candidate = squads[j]
                    if candidate and not candidate.deleted
                        and candidate.surface == squad.surface
                        and candidate.unitGroup and candidate.unitGroup.valid
                        and squad.unitGroup and squad.unitGroup.valid then
                        local dist = util.distance(squad.unitGroup.position, candidate.unitGroup.position)
                        if dist <= MIGRATION_MERGE_MAX_DISTANCE and (other == nil or dist < other_dist) then
                            other = candidate
                            other_dist = dist
                        end
                    end
                end
                if other then
                    local merged = mergeSquads(squad, other)
                    if merged then
                        merged_count = merged_count + 1
                        merging = true -- something merged, another pass might find more
                    end
                end
            end
        end
    end
    if merged_count > 0 then
        LOGGER.log(string.format("Migration for force %s: consolidated squads in %d merge(s)",
                                 force.name, merged_count))
    end
    return merged_count
end

function migrateForce(fkey, force)
    LOGGER.log(string.format("Migrating force %s...", force.name))
    global_fixupTickTablesForForceName(force.name)
    for skey, squad in pairs(storage.Squads[force.name]) do
        migrateSquad(skey, squad)
    end

    migrateDroidAssemblersTo_0_2_4(force)
    reEnableRecipesForResearchedTechnologies(force) -- reset_recipes() locked tech-locked recipes, see function comment
    local adopted_count = migrateOrphanedDroidsAndBuildings(force) -- re-register buildings and adopt orphaned droids (see function comment)
    -- consolidate the many small squads adoption creates, so they can reach hunting size and fight
    if adopted_count and adopted_count > 0 then consolidateMigratedSquads(force) end
end


function migrateSquad(skey, squad)
    migrateSquadTo_0_2_4(squad)
end


function migrateSquadTo_0_2_4(squad)
    squad.members.size = nil -- removing old 'size' table entry

    if not squad.command then
        -- this shouldn't happen, but just in case...
        squad.command = makeCommandTable(commands.hunt)
    elseif type(squad.command) ~= "table" then
        -- this is the normal migration path
        LOGGER.log(string.format("Migrating squad %d command table", squad.squadID))
        local pos = getSquadPos(squad)
        squad.command = makeCommandTable(squad.command, pos, pos)
    end

    squad.unitGroupFailures = squad.unitGroupFailures or 0
    squad.numMembers = squad.numMembers or 0

    if not squad.mostRecentUnitGroupRemovalTick then
        squad.mostRecentUnitGroupRemovalTick = {}
        for key, soldier in pairs(squad.members) do
            squad.mostRecentUnitGroupRemovalTick[key] = 1
        end
    end

    if not squad.nextUnitGroupFailureResponse then
        squad.nextUnitGroupFailureResponse = ugFailureResponses.repeatOrder
        squad.unitGroupFailureTick = 0
    end

    -- put squad in tick tables if not there already
    local found = false
    for tkey, tickTable in pairs(storage.updateTable[squad.force.name]) do
        if table.contains(tickTable, squad.squadID) then
            found = true
            break
        end
    end
    if not found then
        squad = validateSquadIntegrity(squad)
        if squad then
            LOGGER.log(string.format("Inserting squad %d of size %d into tickTables", squad.squadID, squad.numMembers))
            table.insert(storage.updateTable[squad.force.name][squad.squadID % 60 + 1], squad.squadID)
        end
    end
end


function migrateDroidAssemblersTo_0_2_4(force)
    -- index these by their globally unique "unit_number" instead.
    local forceAssemblers = storage.DroidAssemblers[force.name]
    local assemblerNearestEnemies = storage.AssemblerNearestEnemies[force.name]
    for dkey, assembler in pairs(forceAssemblers) do
        if not assembler or not assembler.valid then
            forceAssemblers[dkey] = nil
        elseif dkey ~= assembler.unit_number then
            forceAssemblers[dkey] = nil
            LOGGER.log(string.format("Moving assembler to new index %d from %d", assembler.unit_number, dkey))
            forceAssemblers[assembler.unit_number] = assembler
        end
        if assembler and assembler.valid and not assemblerNearestEnemies[assembler.unit_number] then
            assemblerNearestEnemies[assembler.unit_number] = {lastChecked = 0,
                                                              enemy = nil,
                                                              distance = 0}
        end
    end
end


function global_fixupTickTablesForForceName(force_name)
    if not storage.updateTable[force_name] then storage.updateTable[force_name] = {} end

    --check if the table has the 1st tick in it. if not, then go through and fill the table
    if not storage.updateTable[force_name][1] then
        fillTableWithTickEntries(storage.updateTable[force_name]) -- make sure it has got the 1-60 tick entries initialized
    end

    if not storage.DroidAssemblers[force_name] then
        storage.DroidAssemblers[force_name] = {}
    end
    if not storage.AssemblerRetreatTables[force_name] then
        storage.AssemblerRetreatTables[force_name] = {}
    end
    if not storage.AssemblerNearestEnemies[force_name] then
        storage.AssemblerNearestEnemies[force_name] = {}
    end
    if not storage.droidGuardStations[force_name] then
        storage.droidGuardStations[force_name] = {}
    end
    if not storage.droidCounters[force_name] then
        storage.droidCounters[force_name] = {}
    end
    if not storage.lootChests[force_name] then
        storage.lootChests[force_name] = {}
    end
    if not storage.uniqueSquadId[force_name] then
        storage.uniqueSquadId[force_name] = {}
    end

    if not storage.updateTable[force_name] or not storage.Squads[force_name]  then
        -- this is a more-or-less fatal error
        -- in the condition of a new game, and you haven't placed a squad yet, can have issues with player force not having the squad table init yet.
        storage.Squads[force_name] = {}
        return false

        --disabling below code for now
        --[[Game.print_all("Update Table or squad table for force is missing! Can't run update functions - force name:")
        Game.print_all(force_name)
        if not storage.updateTable[force_name] then
            Game.print_all("missing update table...")
        end

        if not storage.Squads[force_name] then
            Game.print_all("missing squad table...")
        end
        return false]]--
    end
    return true
end
