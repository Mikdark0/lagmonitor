lagmonitor.hud_ids = {}

function lagmonitor.update_hud(player)
    local name = player:get_player_name()
    
    -- Only show HUD to admins
    if not minetest.check_player_privs(name, {server=true}) then
        if lagmonitor.hud_ids[name] then
            player:hud_remove(lagmonitor.hud_ids[name])
            lagmonitor.hud_ids[name] = nil
        end
        return
    end

    local data = lagmonitor.players[name] or {}
    
    local hud_text = string.format("FPS: %d | Lag: %.1f%% | Ent: %d%s",
        data.fps or 0,
        lagmonitor.metrics.lag_percent or 0,
        data.nearby_entities or 0,
        lagmonitor.profiler.active and " | PROFILING" or "")

if not lagmonitor.hud_ids[name] then
        lagmonitor.hud_ids[name] = player:hud_add({
            type = "text",
            position = lagmonitor.settings.hud_position,
            offset = {x = 0, y = -120},  -- Changed from -20 to -60 to move 3cm up
            text = hud_text,
            alignment = {x = 0, y = 0},
            scale = {x = 100, y = 30},
            number = 0xFFFFFF
        })
    else
        player:hud_change(lagmonitor.hud_ids[name], "text", hud_text)
    end
	
end

minetest.register_on_leaveplayer(function(player)
    lagmonitor.hud_ids[player:get_player_name()] = nil
end)
