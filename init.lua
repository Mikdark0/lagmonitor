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

-- Set up profile directory
lagmonitor.profiledir = minetest.get_worldpath() .. "/profiles"
minetest.mkdir(lagmonitor.profiledir)

-- Load dependencies
local path = minetest.get_modpath("lagmonitor")
dofile(path .. "/settings.lua")
dofile(path .. "/hud.lua")

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
            local vars = {
                date = os.date("%Y-%m-%d"),
                time = os.date("%H-%M-%S"),
                datetime = os.date("%Y-%m-%d_%H-%M-%S"),
                lag = string.format("%.0f", lag),
                interval = string.format("%.1f", lagmonitor.settings.auto_profile_interval),
                world = minetest.get_worldpath():match("([^/]+)$") or "world"
            }
            
            local filename = (lagmonitor.settings.auto_profile_pattern or "auto_$datetime_lag$lag.txt")
                :gsub("%$(%w+)", vars)
                :gsub("[^%w._-]", "_")
            
            local ok, msg = lagmonitor.start_profiling(
                lagmonitor.settings.auto_profile_interval,
                filename
            )
            
            if ok then
                minetest.log("action", "[LagMonitor] Auto-profiling started: " .. msg)
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
    
    filename = filename or os.date("profile_%Y-%m-%d_%H-%M-%S.txt")
    
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
            got_data = true
            samples_recorded = samples_recorded + samples
            file:write(
                lagmonitor.jit.profile.dumpstack(thread, "pF;", -100), 
                vmstate, " ", samples, "\n"
            )
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
    
    return true, string.format("Started profiling (%.2fs intervals)\nOutput: %s", 
           interval, filepath)
end

function lagmonitor.stop_profiling()
    if not lagmonitor.profiler.active then
        return false, "No active profiling session"
    end
    
    -- Stop profiling
    lagmonitor.jit.profile.stop()
    
    local duration = (minetest.get_us_time() - lagmonitor.profiler.start_time) / 1000000
    local filepath = lagmonitor.profiledir .. "/" .. lagmonitor.profiler.filename
    
    -- Only keep file if we got data
    if lagmonitor.profiler.got_data and lagmonitor.profiler.samples_recorded > 0 then
        lagmonitor.profiler.file:close()
        local msg = string.format("Stopped profiling after %.1fs\nSamples: %d\nFile: %s", 
               duration, lagmonitor.profiler.samples_recorded, filepath)
        
        -- Reset state
        lagmonitor.profiler = {
            active = false,
            file = nil,
            start_time = nil
        }
        return true, msg
    else
        lagmonitor.profiler.file:close()
        os.remove(filepath)
        local msg = string.format("Discarded empty profile after %.1fs (no samples recorded)", duration)
        
        -- Reset state
        lagmonitor.profiler = {
            active = false,
            file = nil,
            start_time = nil
        }
        return false, msg
    end
end

-- Chat commands
minetest.register_chatcommand("lagprofile", {
    description = "Control performance profiling\n" ..
        "Variables: $date, $time, $datetime, $lag, $interval, $world\n" ..
        "Usage:\n" ..
        "Start: /lagprofile start [interval] [filename_pattern]\n" ..
        "Stop: /lagprofile stop\n" ..
        "Status: /lagprofile status",
    params = "<start|stop|status> [interval] [filename_pattern]",
    privs = {server = true},
    func = function(name, param)
        local parts = param:split(" ")
        local action = parts[1] or "status"
        
        if action == "start" then
            local interval = tonumber(parts[2])
            local pattern = parts[3] and table.concat({select(3, unpack(parts))}, " ") or "profile_$datetime.txt"
            
            -- Replace variables in filename
            local now = os.date("*t")
            local vars = {
                date = os.date("%Y-%m-%d"),
                time = os.date("%H-%M-%S"),
                datetime = os.date("%Y-%m-%d_%H-%M-%S"),
                lag = lagmonitor.metrics.lag_percent and 
                      string.format("%.0f", lagmonitor.metrics.lag_percent) or "0",
                interval = interval and string.format("%.1f", interval) or lagmonitor.settings.default_profile_interval,
                world = minetest.get_worldpath():match("([^/]+)$") or "world"
            }
            
            local filename = pattern:gsub("%$(%w+)", vars):gsub("[^%w._-]", "_")
            if not filename:match("%.txt$") then
                filename = filename .. ".txt"
            end
            
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
                lagmonitor.profiledir,
                lagmonitor.metrics.lag_percent or 0,
                lagmonitor.jit.profile and "YES" or "NO"
            )
        end
        
        return false, "Invalid action. Use: start, stop, or status"
    end
})

minetest.register_chatcommand("autoprofile", {
    description = "Configure automatic profiling\n" ..
        "Usage:\n" ..
        "/autoprofile on <threshold> <interval> <filename_pattern>\n" ..
        "/autoprofile off\n" ..
        "/autoprofile status",
    params = "<on|off|status> [threshold] [interval] [filename_pattern]",
    privs = {server = true},
    func = function(name, param)
        local parts = param:split(" ")
        local action = parts[1] or "status"
        
        if action == "on" then
            local threshold = tonumber(parts[2]) or lagmonitor.settings.auto_profile_threshold
            local interval = tonumber(parts[3]) or lagmonitor.settings.auto_profile_interval
            local pattern = parts[4] and table.concat({select(4, unpack(parts))}, " ") or 
                          lagmonitor.settings.auto_profile_pattern or "auto_$datetime_lag$lag.txt"
            
            lagmonitor.settings.auto_profile = true
            lagmonitor.settings.auto_profile_threshold = threshold
            lagmonitor.settings.auto_profile_interval = interval
            lagmonitor.settings.auto_profile_pattern = pattern
            
            return true, string.format(
                "Auto-profiling ENABLED\n" ..
                "Threshold: %.0f%% lag\n" ..
                "Interval: %.1fs\n" ..
                "Filename: %s",
                threshold,
                interval, 
                pattern
            )
            
        elseif action == "off" then
            lagmonitor.settings.auto_profile = false
            return true, "Auto-profiling DISABLED"
            
        elseif action == "status" then
            return true, string.format(
                "Auto-profiling: %s\n" ..
                "Threshold: %.0f%% lag\n" ..
                "Interval: %.1fs\n" ..
                "Filename pattern: %s\n" ..
                "Current lag: %.1f%%",
                lagmonitor.settings.auto_profile and "ENABLED" or "DISABLED",
                lagmonitor.settings.auto_profile_threshold,
                lagmonitor.settings.auto_profile_interval,
                lagmonitor.settings.auto_profile_pattern,
                lagmonitor.metrics.lag_percent or 0
            )
        end
        
        return false, "Invalid action. Use: on, off, or status"
    end
})

-- Cleanup on shutdown
minetest.register_on_shutdown(function()
    if lagmonitor.profiler.active then
        lagmonitor.stop_profiling()
    end
end)

minetest.log("action", "[LagMonitor] Initialized")
