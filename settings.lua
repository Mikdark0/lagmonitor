lagmonitor.settings = {
    -- Basic monitoring
    target_fps = 20,
    scan_radius = 50,
    
    -- HUD display
    show_hud = true,
    hud_refresh = 0.5,
    hud_position = {x = 0.5, y = 0.95},
    
    -- Profiler settings
    default_profile_interval = 1.0,
    min_profile_interval = 0.05,
    max_profile_duration = 300,
    
    -- Auto-profiling
    auto_profile = false,
    auto_profile_threshold = 80,
    auto_profile_interval = 1.0,
    auto_profile_pattern = "auto_$datetime_lag$lag_$lag_duration.txt",
    -- Chat colors
    chat_colors = {
        admin_notice = "#FFA500",  -- Orange color for admin notifications
    },
}
