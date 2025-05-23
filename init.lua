lagmonitor = {}
lagmonitor.metrics = {}
lagmonitor.players = {}
lagmonitor.profiler = {
    active = false,
    start_time = nil,
    filename = nil
}

-- Initialize JIT profiling
lagmonitor.jit = {
    available = minetest.global_exists("jit"),
    insecure_env = minetest.request_insecure_environment()
}

-- Set up profile directory with date-time folder
local now = os.date("*t")
local profile_subdir = string.format("autoprofile_%04d-%02d-%02d_%02d-%02d-%02d", 
    now.year, now.month, now.day, now.hour, now.min, now.sec)
lagmonitor.profiledir = minetest.get_worldpath() .. "/profiles/" .. profile_subdir
minetest.mkdir(lagmonitor.profiledir)

-- Load dependencies
local path = minetest.get_modpath("lagmonitor")
dofile(path .. "/settings.lua")
dofile(path .. "/hud.lua")

-- Helper function for colored chat messages
function lagmonitor.colored_chat_message(name, message, color)
    if not name or not minetest.check_player_privs(name, {server=true}) then
        return
    end
    minetest.chat_send_player(name, minetest.colorize(color, message))
end

-- Initialize JIT profiling if available
if lagmonitor.jit.available and lagmonitor.jit.insecure_env then
    local ok, profile = pcall(lagmonitor.jit.insecure_env.require, "jit.profile")
    if ok then
        lagmonitor.jit.profile = {
            start = profile.start,
            stop = profile.stop,
            dumpstack = profile.dumpstack,
            tonumber = lagmonitor.jit.insecure_env.tonumber
        }
    end
end

-- Core lag measurement
local function measure_lag()
    local now = minetest.get_us_time()
    lagmonitor.metrics.server_step = now
    
    if lagmonitor.metrics.last_step then
        local elapsed = now - lagmonitor.metrics.last_step
        local lag_percent = math.max(0, (elapsed - 1000000/lagmonitor.settings.target_fps) / 
                          (1000000/lagmonitor.settings.target_fps) * 100)
        lagmonitor.metrics.lag_percent = math.floor(lag_percent * 10) / 10
    end
    lagmonitor.metrics.last_step = now
end

-- HUD update for admins only
local function update_all_huds()
    if not lagmonitor.settings.show_hud then return end
    
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        if minetest.check_player_privs(name, {server=true}) then
            lagmonitor.update_hud(player)
        end
    end
end

-- Global step callback
minetest.register_globalstep(function(dtime)
    measure_lag()
    
    -- Update player metrics
    for _, player in ipairs(minetest.get_connected_players()) do
        local name = player:get_player_name()
        lagmonitor.players[name] = lagmonitor.players[name] or {}
        local data = lagmonitor.players[name]
        
        data.fps = math.floor(1/math.max(0.001, dtime))
        local pos = player:get_pos()
        data.nearby_entities = #minetest.get_objects_inside_radius(pos, lagmonitor.settings.scan_radius)
    end
    
    -- Auto-profiling logic
    if lagmonitor.settings.auto_profile and lagmonitor.jit.profile then
        local lag = lagmonitor.metrics.lag_percent or 0
        local threshold = lagmonitor.settings.auto_profile_threshold
        
        -- Start profiling if lag exceeds threshold
        if lag >= threshold and not lagmonitor.profiler.active then
            local now = os.date("*t")
            local current_lag = string.format("%.0f", lag)
            local filename = string.format("auto_%04d-%02d-%02d_%02d-%02d-%02d_lag%s_STARTED.txt",
                now.year, now.month, now.day,
                now.hour, now.min, now.sec,
                current_lag)
            
            local ok, msg = lagmonitor.start_profiling(
                lagmonitor.settings.auto_profile_interval,
                filename
            )
            
            if ok then
                minetest.log("action", "[LagMonitor] Auto-profiling started. File: " .. filename)
            end
        end
        
        -- Stop profiling when lag drops below threshold
        if lagmonitor.profiler.active and lag < threshold then
            local ok, msg = lagmonitor.stop_profiling()
            if ok then
                minetest.log("action", "[LagMonitor] Auto-profiling stopped: " .. msg)
            end
        end
    end
    
    update_all_huds()
end)

-- Profiler control functions
function lagmonitor.start_profiling(interval, filename)
    -- Validate inputs
    interval = tonumber(interval) or lagmonitor.settings.default_profile_interval
    if interval < lagmonitor.settings.min_profile_interval then
        return false, string.format("Interval too small (minimum %.2fs)", 
                   lagmonitor.settings.min_profile_interval)
    end
    
    -- Check if profiling is available
    if not lagmonitor.jit.profile then
        return false, "JIT profiling not available (check secure.trusted_mods)"
    end
    
    -- Check if already running
    if lagmonitor.profiler.active then
        return false, "Profiler already running"
    end
    
    -- Open output file
    local filepath = lagmonitor.profiledir .. "/" .. filename
    local file, err = io.open(filepath, "w")
    if not file then
        return false, "Could not create file: " .. tostring(err)
    end
    
    -- Track if we get any profile data
    local got_data = false
    local samples_recorded = 0
    
    local function record(thread, samples, vmstate)
        if samples > 0 then
            local ok, err = pcall(function()
                file:write(
                    lagmonitor.jit.profile.dumpstack(thread, "pF;", -100), 
                    vmstate, " ", samples, "\n"
                )
                file:flush()
            end)
            if ok then
                got_data = true
                samples_recorded = samples_recorded + samples
            else
                minetest.log("error", "[LagMonitor] Error writing profile data: " .. tostring(err))
            end
        end
    end
    
    -- Start profiling
    lagmonitor.jit.profile.start("vfi" .. math.floor(interval * 1000), record)
    
    -- Update state
    lagmonitor.profiler = {
        active = true,
        start_time = minetest.get_us_time(),
        filename = filename,
        file = file,
        interval = interval,
        got_data = got_data,
        samples_recorded = samples_recorded
    }
    
    -- Send colored notification to admins
    local notice = string.format("[LagMonitor] Profiling started. File: %s/%s", 
        profile_subdir, filename)
    for _, player in ipairs(minetest.get_connected_players()) do
        local pname = player:get_player_name()
        if minetest.check_player_privs(pname, {server=true}) then
            lagmonitor.colored_chat_message(pname, notice, lagmonitor.settings.chat_colors.admin_notice)
        end
    end
    
    return true, string.format("Started profiling (%.2fs intervals)\nLocation: %s/%s", 
           interval, profile_subdir, filename)
end

function lagmonitor.stop_profiling()
    if not lagmonitor.profiler.active then
        return false, "No active profiling session"
    end
    
    -- Calculate duration
    local duration_sec = (minetest.get_us_time() - lagmonitor.profiler.start_time) / 1000000
    local duration_str = string.format("%.1f", duration_sec)
    
    -- Stop profiling
    lagmonitor.jit.profile.stop()
    
    local filepath = lagmonitor.profiledir .. "/" .. lagmonitor.profiler.filename
    
    -- Flush and check file contents
    lagmonitor.profiler.file:flush()
    local current_pos = lagmonitor.profiler.file:seek("cur")
    local file_size = lagmonitor.profiler.file:seek("end")
    lagmonitor.profiler.file:seek("set", current_pos)

    if file_size > 0 then
        -- Create final filename with single 's' suffix
        local base_name = lagmonitor.profiler.filename:gsub("_STARTED.txt$", "")
        local new_filename = base_name .. "_" .. duration_str .. "s.txt"
        local new_filepath = lagmonitor.profiledir .. "/" .. new_filename
        
        -- Close and rename
        lagmonitor.profiler.file:close()
        os.rename(filepath, new_filepath)
        
        -- Write autoprofile folder path to server_tools.txt
        local worldpath = minetest.get_worldpath()
        local command_file = worldpath .. "/server_tools.txt"
        local relative_path = lagmonitor.profiledir:gsub("^"..worldpath.."/", "")
        
        local file, err = io.open(command_file, "w")
        if file then
            file:write("# autoprofile " .. relative_path)
            file:close()
            minetest.log("action", "[LagMonitor] Saved autoprofile path to server_tools.txt: " .. relative_path)
        else
            minetest.log("error", "[LagMonitor] Failed to write server_tools.txt: " .. tostring(err))
        end
        
        -- Notify admins
        local notice = string.format("[LagMonitor] Profile saved: %s/%s", 
            profile_subdir, new_filename)
        for _, player in ipairs(minetest.get_connected_players()) do
            local pname = player:get_player_name()
            if minetest.check_player_privs(pname, {server=true}) then
                lagmonitor.colored_chat_message(pname, notice, lagmonitor.settings.chat_colors.admin_notice)
            end
        end
        
        local msg = string.format("Profiling complete\nDuration: %ss\nLocation: %s/%s\n" ..
               "Path saved to server_tools.txt",
               duration_str, profile_subdir, new_filename)
        
        -- Reset state
        lagmonitor.profiler = {active = false, file = nil, start_time = nil}
        return true, msg
    else
        -- Close and delete empty file
        lagmonitor.profiler.file:close()
        os.remove(filepath)
        
        -- Send colored notification to admins
        local notice = string.format("[LagMonitor] Discarded empty profile after %ss", duration_str)
        for _, player in ipairs(minetest.get_connected_players()) do
            local pname = player:get_player_name()
            if minetest.check_player_privs(pname, {server=true}) then
                lagmonitor.colored_chat_message(pname, notice, lagmonitor.settings.chat_colors.admin_notice)
            end
        end
        
        local msg = string.format("Discarded empty profile after %ss (no samples recorded)", duration_str)
        
        -- Reset state
        lagmonitor.profiler = {active = false, file = nil, start_time = nil}
        return false, msg
    end
end

-- Chat commands
minetest.register_chatcommand("lagprofile", {
    description = "Control performance profiling\n" ..
        "Usage:\n" ..
        "Start: /lagprofile start [interval]\n" ..
        "Stop: /lagprofile stop\n" ..
        "Status: /lagprofile status",
    params = "<start|stop|status> [interval]",
    privs = {server = true},
    func = function(name, param)
        local parts = param:split(" ")
        local action = parts[1] or "status"
        
        if action == "start" then
            local interval = tonumber(parts[2])
            local now = os.date("*t")
            local current_lag = string.format("%.0f", lagmonitor.metrics.lag_percent or 0)
            local filename = string.format("auto_%04d-%02d-%02d_%02d-%02d-%02d_lag%s_STARTED.txt",
                now.year, now.month, now.day,
                now.hour, now.min, now.sec,
                current_lag)
            
            return lagmonitor.start_profiling(interval, filename)
            
        elseif action == "stop" then
            return lagmonitor.stop_profiling()
            
        elseif action == "status" then
            local status = lagmonitor.profiler.active and 
                string.format("ACTIVE (%.2fs intervals, running %.1fs)", 
                    lagmonitor.profiler.interval,
                    (minetest.get_us_time() - lagmonitor.profiler.start_time) / 1000000) 
                or "INACTIVE"
            
            return true, string.format(
                "=== Profiler Status ===\n" ..
                "Status: %s\n" ..
                "Location: %s\n" ..
                "Current lag: %.1f%%\n" ..
                "JIT available: %s",
                status,
                lagmonitor.profiledir:gsub("^"..minetest.get_worldpath().."/", ""),
                lagmonitor.metrics.lag_percent or 0,
                lagmonitor.jit.profile and "YES" or "NO"
            )
        end
        
        return false, "Invalid action. Use: start, stop, or status"
    end
})

minetest.register_chatcommand("autoprofile", {
    description = "Control automatic profiling\n" ..
        "Usage:\n" ..
        "Start: /autoprofile start <threshold> <interval>\n" ..
        "Stop: /autoprofile stop\n" ..
        "Status: /autoprofile status",
    params = "<start|stop|status> [threshold] [interval]",
    privs = {server = true},
    func = function(name, param)
        local parts = param:split(" ")
        local action = parts[1] or "status"
        
        if action == "start" then
            local threshold = tonumber(parts[2]) or lagmonitor.settings.auto_profile_threshold
            local interval = tonumber(parts[3]) or lagmonitor.settings.auto_profile_interval
            
            lagmonitor.settings.auto_profile = true
            lagmonitor.settings.auto_profile_threshold = threshold
            lagmonitor.settings.auto_profile_interval = interval
            
            lagmonitor.colored_chat_message(name, "Auto-profiling STARTED", 
                lagmonitor.settings.chat_colors.admin_notice)
            
            return true, string.format(
                "Auto-profiling STARTED\n" ..
                "Threshold: %.0f%% lag\n" ..
                "Interval: %.1fs",
                threshold,
                interval
            )
            
        elseif action == "stop" then
            lagmonitor.settings.auto_profile = false
            
            -- Write autoprofile folder path to server_tools.txt
            local worldpath = minetest.get_worldpath()
            local command_file = worldpath .. "/server_tools.txt"
            local relative_path = lagmonitor.profiledir:gsub("^"..worldpath.."/", "")
            
            local file, err = io.open(command_file, "w")
            if file then
                file:write("# autoprofile " .. relative_path)
                file:close()
                minetest.log("action", "[LagMonitor] Saved autoprofile path to server_tools.txt: " .. relative_path)
            else
                minetest.log("error", "[LagMonitor] Failed to write server_tools.txt: " .. tostring(err))
            end
            
            lagmonitor.colored_chat_message(name, "Auto-profiling STOPPED", 
                lagmonitor.settings.chat_colors.admin_notice)
            return true, string.format(
                "Auto-profiling STOPPED\n" ..
                "Profile folder: %s\n" ..
                "Path saved to server_tools.txt",
                relative_path
            )
            
        elseif action == "status" then
            return true, string.format(
                "Auto-profiling: %s\n" ..
                "Threshold: %.0f%% lag\n" ..
                "Interval: %.1fs\n" ..
                "Current lag: %.1f%%\n" ..
                "Profile folder: %s",
                lagmonitor.settings.auto_profile and "ACTIVE" or "INACTIVE",
                lagmonitor.settings.auto_profile_threshold,
                lagmonitor.settings.auto_profile_interval,
                lagmonitor.metrics.lag_percent or 0,
                lagmonitor.profiledir:gsub("^"..minetest.get_worldpath().."/", "")
            )
        end
        
        return false, "Invalid action. Use: start, stop, or status"
    end
})

-- Cleanup on shutdown
minetest.register_on_shutdown(function()
    if lagmonitor.profiler.active then
        lagmonitor.stop_profiling()
    end
end)

minetest.log("action", "[LagMonitor] Initialized")
