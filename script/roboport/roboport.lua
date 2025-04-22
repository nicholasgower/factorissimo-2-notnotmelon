local blacklisted_names = require "script.roboport.blacklist"
local utility_constants = require "script.roboport.utility-constants"

local function add_task(tick, task)
    local tasks_at_tick = storage.tasks_at_tick[tick]
    if tasks_at_tick then
        tasks_at_tick[#tasks_at_tick + 1] = task
    else
        storage.tasks_at_tick[tick] = {task}
    end
end

local function get_tilebox(bounding_box)
    local left_top = bounding_box.left_top
    local right_bottom = bounding_box.right_bottom
    -- expand the bounding_box to the nearest integer
    left_top.x = math.floor(left_top.x)
    left_top.y = math.floor(left_top.y)
    right_bottom.x = math.ceil(right_bottom.x)
    right_bottom.y = math.ceil(right_bottom.y)

    local positions = {}

    local i = 1
    for y = left_top.y, right_bottom.y - 1 do
        for x = left_top.x, right_bottom.x - 1 do
            positions[i] = {x = x, y = y}
            i = i + 1
        end
    end

    return positions
end

-- position is expected to have a .5 decimal
local function get_piece(position, center)
    if position.x > center.x then
        return position.y < center.y and "back_right" or "front_right"
    else
        return position.y < center.y and "back_left" or "front_left"
    end
end

local function is_back_piece(piece)
    return piece == "back_left" or piece == "back_right"
end

local function get_manhattan_distance(position, center)
    local delta_x = position.x - center.x
    local delta_y = position.y - center.y

    return math.abs(delta_x) + math.abs(delta_y)
end

local function get_build_sound_path(selection_box)
    local area = (selection_box.right_bottom.x - selection_box.left_top.x) * (selection_box.right_bottom.y - selection_box.left_top.y)

    if area < utility_constants.small_area_size then return "utility/build_animated_small" end
    if area < utility_constants.medium_area_size then return "utility/build_animated_medium" end
    if area < utility_constants.large_area_size then return "utility/build_animated_large" end

    return "utility/build_animated_huge"
end

local function start_construction_animation(top_animation, bottom_animation)
    if not top_animation.valid or not bottom_animation.valid then return end
    local offset = -(game.tick * 0.5) % 32
    top_animation.visible = true
    bottom_animation.visible = true
    top_animation.animation_speed = 1
    bottom_animation.animation_speed = 1
    top_animation.animation_offset = offset
    bottom_animation.animation_offset = offset
end

local function pause_construction_animation(top_animation, bottom_animation)
    if not top_animation.valid or not bottom_animation.valid then return end
    top_animation.animation_speed = 0
    bottom_animation.animation_speed = 0
    top_animation.animation_offset = 15
    bottom_animation.animation_offset = 15
end

local function unpause_construction_animation(top_animation, bottom_animation)
    if not top_animation.valid or not bottom_animation.valid then return end
    local offset = -(game.tick * 0.5) % 32 + 16
    top_animation.animation_speed = 1
    bottom_animation.animation_speed = 1
    top_animation.animation_offset = offset
    bottom_animation.animation_offset = offset
end

factorissimo.register_delayed_function("start_construction_animation", start_construction_animation)
factorissimo.register_delayed_function("pause_construction_animation", pause_construction_animation)
factorissimo.register_delayed_function("unpause_construction_animation", unpause_construction_animation)
factorissimo.register_delayed_function("destroy_entity", function(entity) entity.destroy() end)

local TICKS_PER_FRAME = 2
local FRAMES_BEFORE_BUILT = 16
local FRAMES_BETWEEN_BUILDING = 8 * 2
local FRAMES_BETWEEN_REMOVING = 4

local function request_platform_animation_for(entity)
    if blacklisted_names[entity.name] then return end

    local tick = game.tick
    local surface = entity.surface

    surface.play_sound {
        path = get_build_sound_path(entity.selection_box),
        position = entity.position,
    }

    local tilebox = get_tilebox(entity.bounding_box)
    local largest_manhattan_distance = 0
    for _, position in ipairs(tilebox) do
        position.center = {x = position.x + 0.5, y = position.y + 0.5}
        position.manhattan_distance = get_manhattan_distance(position.center, entity.position)

        if position.manhattan_distance > largest_manhattan_distance then
            largest_manhattan_distance = position.manhattan_distance
        end
    end

    local remove_scaffold_delay = (largest_manhattan_distance + 4) * FRAMES_BETWEEN_BUILDING
    local all_scaffolding_down_at = 1 + largest_manhattan_distance * FRAMES_BETWEEN_REMOVING + remove_scaffold_delay + 16 * TICKS_PER_FRAME

    for _, position in ipairs(tilebox) do
        local piece = get_piece(position.center, entity.position)

        local up_base = 1 + position.manhattan_distance * FRAMES_BETWEEN_BUILDING
        local down_base = 1 + position.manhattan_distance * FRAMES_BETWEEN_REMOVING + remove_scaffold_delay

        local time_to_live = down_base + 16 * TICKS_PER_FRAME

        local top_animation = rendering.draw_animation {
            target = position.center,
            surface = surface,
            animation = "platform_entity_build_animations-" .. piece .. "-top",
            time_to_live = time_to_live,
            animation_offset = 0,
            animation_speed = 0,
            render_layer = entity.type == "cargo-landing-pad" and "above-inserters" or "higher-object-above",
            visible = false,
        }

        local bottom_animation = rendering.draw_animation {
            target = position.center,
            surface = surface,
            animation = "platform_entity_build_animations-" .. piece .. "-body",
            time_to_live = time_to_live,
            animation_offset = 0,
            animation_speed = 0,
            render_layer = is_back_piece(piece) and "lower-object-above-shadow" or "object",
            visible = false,
        }

        factorissimo.execute_later("start_construction_animation", up_base, top_animation, bottom_animation)
        factorissimo.execute_later("pause_construction_animation", up_base + 15 * TICKS_PER_FRAME, top_animation, bottom_animation)
        factorissimo.execute_later("unpause_construction_animation", down_base, top_animation, bottom_animation)
    end
end

-- ensure we are actually in a factory floor. prevent contraband construction robots from being created
factorissimo.on_event(defines.events.on_script_trigger_effect, function(event)
    if event.effect_id ~= "factory-hidden-construction-robot-created" then return end
    local construction_robot = event.target_entity
    assert(construction_robot and construction_robot.name == "factory-hidden-construction-robot")
    if not storage.surface_factories[construction_robot.surface_index] then
        factorissimo.execute_later("destroy_entity", 1, construction_robot)
    end
end)

local function destroy_robot_if_empty_inventory(robot)
    if not robot.valid then return end
    if robot.get_inventory(defines.inventory.robot_cargo).is_empty() and robot.get_inventory(defines.inventory.robot_repair).is_empty() then
        robot.destroy()
    end
end
factorissimo.register_delayed_function("destroy_robot_if_empty_inventory", destroy_robot_if_empty_inventory)

factorissimo.on_event(defines.events.on_robot_built_entity, function(event)
    local robot = event.robot
    if robot.name ~= "factory-hidden-construction-robot" then return end
    local unit_number = robot.unit_number
    local entity = event.entity
    if not entity.valid then return end
    request_platform_animation_for(event.entity)
    factorissimo.execute_later("destroy_robot_if_empty_inventory", 1, robot)
end)

factorissimo.build_roboport_upgrade = function(factory)
    if not factory.inside_surface.valid or not factory.outside_surface.valid then return end
    local force = factory.force
    if not force.valid then return end
    if not force.technologies["factory-interior-upgrade-roboport"].researched then return end

    local requester = factory.roboport_upgrade and factory.roboport_upgrade.requester and factory.roboport_upgrade.requester.valid and factory.roboport_upgrade.requester
    local roboport = factory.roboport_upgrade and factory.roboport_upgrade.roboport and factory.roboport_upgrade.roboport.valid and factory.roboport_upgrade.roboport
    local storage = factory.roboport_upgrade and factory.roboport_upgrade.storage and factory.roboport_upgrade.storage.valid and factory.roboport_upgrade.storage
    local hidden_roboport = factory.roboport_upgrade and factory.roboport_upgrade.hidden_roboport and factory.roboport_upgrade.hidden_roboport.valid and factory.roboport_upgrade.hidden_roboport

    if factory.building and factory.building.valid then
        requester = requester or factory.outside_surface.create_entity {
            name = factory.layout.outside_requester_chest_type or "factory-requester-chest-factory-3",
            position = factory.building.position,
            force = factory.force,
            quality = factory.quality,
        }
    else
        requester = nil
    end
    roboport = roboport or factory.inside_surface.create_entity {
        name = "factory-construction-roboport",
        position = {-factory.layout.inside_energy_x + factory.inside_x, factory.layout.inside_energy_y + factory.inside_y},
        force = factory.force,
        quality = factory.quality,
    }
    roboport.backer_name = ""

    hidden_roboport = hidden_roboport or factory.inside_surface.create_entity {
        name = "factory-hidden-construction-roboport",
        position = roboport.position,
        force = factory.force,
    }
    hidden_roboport.backer_name = ""
    hidden_roboport.get_inventory(defines.inventory.roboport_robot).insert {name = "factory-hidden-construction-robot", count = prototypes.item["factory-hidden-construction-robot"].stack_size / 2}

    storage = storage or factory.inside_surface.create_entity {
        name = "factory-construction-chest",
        position = {-factory.layout.overlays.inside_x + factory.inside_x, factory.layout.overlays.inside_y + factory.inside_y},
        force = factory.force,
        quality = factory.quality,
    }

    for _, entity in pairs {roboport, storage, requester, hidden_roboport} do
        entity.destructible = false
        entity.minable = false
        entity.rotatable = false
    end

    factory.roboport_upgrade = {
        roboport = roboport,
        storage = storage,
        requester = requester,
        hidden_roboport = hidden_roboport,
        item_request_proxies = (factory.roboport_upgrade and factory.roboport_upgrade.item_request_proxies) or {}
    }
end

factorissimo.cleanup_factory_roboport_exterior_chest = function(factory)
    local requester = factory.roboport_upgrade and factory.roboport_upgrade.requester and factory.roboport_upgrade.requester.valid and factory.roboport_upgrade.requester
    if not requester then return end
    local surface = requester.surface

    local inventory = requester.get_inventory(defines.inventory.chest)
    for i = 1, #inventory do
        local stack = inventory[i]
        if stack.valid_for_read then
            surface.spill_item_stack {
                position = requester.position,
                stack = stack,
                enable_looted = true,
                force = requester.force_index,
                allow_belts = false,
                use_start_position_on_failure = true,
            }
        end
    end
    requester.destroy()
    factory.roboport_upgrade.item_request_proxies = {}
end

local GHOST_PROTOTYPE_NAME = "entity-ghost"
local TILE_GHOST_PROTOTYPE_NAME = "tile-ghost"

local function get_construction_requests_by_factory()
    local missing_ghosts_per_factory = {}

    for surface_index, factories in pairs(storage.surface_factories) do
        if not game.get_surface(surface_index) then goto invalid_surface end

        local forces_to_check = {}
        for _, factory in pairs(factories) do
            local force = factory.force
            if force.valid and not forces_to_check[force.index] and force.technologies["factory-interior-upgrade-roboport"].researched then
                -- theres no API function to get the current construction requests
                -- so instead we are reading it from the player's alerts! (this is a bad idea)
                -- find a valid online player to check the alerts for
                -- yes this means the roboport construction feature only works if you are logged in! too bad
                local _, player = next(force.connected_players)
                if player then forces_to_check[force.index] = player end
            end
        end

        for _, player in pairs(forces_to_check) do
            local missing = (player.get_alerts {
                type = defines.alert_type.no_material_for_construction,
                surface = surface_index,
            }[surface_index] or {})[defines.alert_type.no_material_for_construction] or {}
            for _, ghost in pairs(missing) do
                ghost = ghost.target
                if not ghost then goto continue end -- this can happen if the alerts are not updated yet but the entity is invalid
                --if ghost.is_registered_for_construction() then goto continue end -- we only care about ghosts that are not already being constructed
                local factory = remote_api.find_surrounding_factory_by_surface_index(surface_index, ghost.position)
                if not factory or not factory.roboport_upgrade then goto continue end
                if factory.inactive or not factory.built or not factory.building.valid then goto continue end
                if not factory.inside_surface.valid or not factory.outside_surface.valid then goto continue end

                local missing_ghosts = missing_ghosts_per_factory[factory]
                if missing_ghosts then
                    missing_ghosts[#missing_ghosts + 1] = ghost
                else
                    missing_ghosts_per_factory[factory] = {ghost}
                end

                ::continue::
            end
        end

        ::invalid_surface::
    end

    local construction_requests_by_factory = {}
    for factory, missing_ghosts in pairs(missing_ghosts_per_factory) do
        local requests_by_itemname = {}
        for _, ghost in pairs(missing_ghosts) do
            local items_to_place
            if ghost.name == GHOST_PROTOTYPE_NAME or ghost.name == TILE_GHOST_PROTOTYPE_NAME then
                items_to_place = ghost.ghost_prototype.items_to_place_this -- collect all items_to_place_this for construction ghosts
            elseif ghost.type == "item-request-proxy" then
                items_to_place = ghost.item_requests           -- items can also be delived to the `item-request-proxy` prototype
            elseif ghost.to_be_upgraded() then
                local upgrade_target, quality = ghost.get_upgrade_target()
                items_to_place = upgrade_target.items_to_place_this -- collect all items_to_place_this for upgrade planner ghosts
                for _, item in pairs(items_to_place) do item.quality = quality.name end
            else
                goto continue
            end

            for _, item_to_place in pairs(items_to_place) do
                local item_name = item_to_place.name
                requests_by_itemname[item_name] = requests_by_itemname[item_name] or {}
                local requests_by_quality = requests_by_itemname[item_name]
                local quality = item_to_place.quality or ghost.quality.name
                requests_by_quality[quality] = requests_by_quality[quality] or 0
                requests_by_quality[quality] = requests_by_quality[quality] + item_to_place.count
            end

            ::continue::
        end

        -- dont request instantiated factories. it already requests the raw factory item
        requests_by_itemname["factory-1-instantiated"] = nil -- hardcoding these is not ideal
        requests_by_itemname["factory-2-instantiated"] = nil
        requests_by_itemname["factory-3-instantiated"] = nil

        construction_requests_by_factory[factory] = requests_by_itemname
    end

    return construction_requests_by_factory
end

local create_or_remove_item_request_proxies -- function stub
local create_new_item_request_proxies       -- function stub

factorissimo.on_nth_tick(257, function()
    local construction_requests_by_factory = get_construction_requests_by_factory()

    -- update each factory and create item-request-proxy for unfulfilled construction requests
    for _, factory in pairs(storage.factories) do
        if not factory.inactive and factory.built then
            local requests_by_itemname = construction_requests_by_factory[factory]
            if requests_by_itemname then
                create_or_remove_item_request_proxies(factory, requests_by_itemname)
            elseif factory.roboport_upgrade and next(factory.roboport_upgrade.item_request_proxies) then
                for _, proxy in pairs(factory.roboport_upgrade.item_request_proxies) do
                    proxy.destroy()
                end
                factory.roboport_upgrade.item_request_proxies = {}
            end
        end
    end
end)

create_or_remove_item_request_proxies = function(factory, requests_by_itemname)
    local roboport_upgrade = factory.roboport_upgrade

    local requester = roboport_upgrade.requester
    if not requester.valid then return end
    local storage = roboport_upgrade.storage
    if not storage.valid then return end

    for _, chest in pairs {requester, storage} do
        for _, already_has in pairs(chest.get_inventory(defines.inventory.chest).get_contents()) do
            local name, quality = already_has.name, already_has.quality -- subtract off all the items we already have in storage
            if requests_by_itemname[name] then
                requests_by_itemname[name][quality] = nil
            end
        end
    end

    local already_occupied_inventory_indexes = {}
    local proxies = {}
    for _, proxy in pairs(roboport_upgrade.item_request_proxies) do
        if not proxy.valid then goto we_are_no_longer_requesting_this_item end

        local item_requests = proxy.item_requests
        for _, request in pairs(item_requests) do
            local name, quality = request.name, request.quality -- destroy any proxies that have their requests fulfilled already
            if not requests_by_itemname[name] or not requests_by_itemname[name][quality] then
                proxy.destroy()
                goto we_are_no_longer_requesting_this_item
            end
        end

        for _, request in pairs(item_requests) do
            local name, quality = request.name, request.quality -- same logic as above. subtract off all the items we are already requesting
            requests_by_itemname[name][quality] = nil

            for _, insert_plan in pairs(proxy.insert_plan) do
                for _, inventory_locator in pairs(insert_plan.items.in_inventory) do
                    -- inventory_locator.stack is 0-indexed for some reason. adjust.
                    already_occupied_inventory_indexes[inventory_locator.stack + 1] = true
                end
            end
        end

        proxies[#proxies + 1] = proxy
        ::we_are_no_longer_requesting_this_item::
    end

    roboport_upgrade.item_request_proxies = proxies

    create_new_item_request_proxies(factory, requests_by_itemname, already_occupied_inventory_indexes)
end

create_new_item_request_proxies = function(factory, requests_by_itemname, already_occupied_inventory_indexes)
    local roboport_upgrade = factory.roboport_upgrade
    local requester = roboport_upgrade.requester
    local requester_inventory = requester.get_inventory(defines.inventory.chest)

    for item_name, requests_by_quality in pairs(requests_by_itemname) do
        for quality, count in pairs(requests_by_quality) do
            local next_available_inventory_slot
            for i = 1, #requester_inventory do
                if not already_occupied_inventory_indexes[i] and not requester_inventory[i].valid_for_read then
                    next_available_inventory_slot = i
                    already_occupied_inventory_indexes[i] = true
                    break
                end
            end
            if not next_available_inventory_slot then return end

            count = math.min(count, prototypes.item[item_name].stack_size)

            local module = {
                id = {
                    name = item_name,
                    quality = quality,
                },
                items = {
                    in_inventory = {{inventory = defines.inventory.chest, stack = next_available_inventory_slot - 1, count = count}}
                }
            }

            local proxies = roboport_upgrade.item_request_proxies
            proxies[#proxies + 1] = requester.surface.create_entity {
                name = "item-request-proxy",
                position = requester.position,
                target = requester,
                modules = {module},
                force = requester.force
            }
        end
    end
end

-- smaller update function to transfer items from the requester chest to the construction chest
factorissimo.on_nth_tick(43, function()
    for _, factory in pairs(storage.factories) do
        local roboport_upgrade = factory.roboport_upgrade
        if not roboport_upgrade then goto continue end
        local requester = roboport_upgrade.requester
        if not requester or not requester.valid then goto continue end
        local storage = roboport_upgrade.storage
        local roboport = roboport_upgrade.roboport
        if not storage.valid or not roboport.valid then goto continue end

        local requester_inventory = requester.get_inventory(defines.inventory.chest)
        if requester_inventory.is_empty() then goto continue end
        local storage_inventory = storage.get_inventory(defines.inventory.chest)

        for i = 1, #requester_inventory do
            local stack = requester_inventory[i]
            if stack.valid_for_read then
                stack.count = stack.count - storage_inventory.insert(stack)
            end
        end

        ::continue::
    end
end)

-- yet another update function to ensure the hidden roboport is always half filled.
factorissimo.on_nth_tick(367, function()
    for _, factory in pairs(storage.factories) do
        local roboport_upgrade = factory.roboport_upgrade
        if not roboport_upgrade then goto continue end
        local hidden_roboport = roboport_upgrade.hidden_roboport
        if not hidden_roboport or not hidden_roboport.valid then goto continue end
        local robot_inventory = hidden_roboport.get_inventory(defines.inventory.roboport_robot)

        robot_inventory.clear()
        robot_inventory.insert {name = "factory-hidden-construction-robot", count = prototypes.item["factory-hidden-construction-robot"].stack_size / 2}

        ::continue::
    end
end)

factorissimo.on_event(defines.events.on_gui_opened, function(event)
    local gui_type = event.gui_type
    if gui_type ~= defines.gui_type.entity then return end
    local entity = event.entity
    if not entity or not entity.valid then return end
    if entity.type ~= "roboport" then return end

    local robot_inventory = entity.get_inventory(defines.inventory.roboport_robot)
    robot_inventory.remove {name = "factory-hidden-construction-robot", count = 10000} -- bad! no contraband
end)
