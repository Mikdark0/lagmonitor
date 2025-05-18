LagMonitor Mod v1.0
==================

A comprehensive server performance monitoring tool with built-in JIT profiling capabilities.

# LagMonitor Mod

Advanced server performance monitoring with integrated JIT profiling.

## Features

- Real-time HUD display showing:
  - Current FPS
  - Server lag percentage
  - Nearby entity count
  - Profiling status

- Integrated JIT profiler:
  - Low-overhead performance sampling
  - Customizable sampling interval
  - Automatic file management

- Commands:
  - `/lagprofile start [interval] [filename]` - Begin profiling
  - `/lagprofile stop` - Stop profiling
  - `/lagprofile status` - Show current status

## Installation

1. Place the `lagmonitor` folder in your `mods` directory
2. Add to `minetest.conf`:
   ```ini
   secure.trusted_mods = lagmonitor

HUD Display:
The HUD shows:
- FPS: Current frames per second
- Lag: Percentage over target step time
- Ent: Nearby entity count
- PROFILING: Indicator when active

Profiling Tips:
- For general monitoring: 1.0s interval
- For lag spikes: 0.3-0.5s interval
- For micro-optimization: 0.1s interval (short durations)
- Output files are saved in world_dir/profiles/

Technical Notes:
- Minimum interval: 0.05s
- Max profile duration: 300s (auto-stop)
- Requires LuaJIT and insecure environment
- HUD updates every 0.5s

## Automatic Profiling

### How Auto-Profiling Works

1. **Start Condition**:  
   Profiling automatically starts when server lag exceeds your configured threshold.  
   - *Lag* is calculated as the percentage by which server steps exceed their target time  
   - Example: At target 20 FPS (50ms/step), a 100ms step = 100% lag  
   - Typical healthy servers show <20% lag, while >80% indicates performance issues

2. **Stop Condition**:  
   Profiling stops when lag drops below the same threshold where it started  
   - This creates clear "lag spike" profiles  
   - Avoids frequent start/stop cycles during borderline conditions

3. **Optimal Interval Settings**:
   | Interval | Best For | File Size/Min | CPU Impact |
   |----------|----------|--------------|------------|
   | 1.0s     | General monitoring | ~100KB | Low |
   | 0.3-0.5s | Lag spikes | ~300KB | Moderate |
   | 0.1s     | Micro-optimization | ~1MB | High |

### Configuration Examples

1. Basic setup for significant lag spikes:

/autoprofile on 80 1.0 profile_datetime.txt
2. More sensitive profiling:
/autoprofile on 60 0.5 debug_$time.txt
3. Check current settings:
/autoprofile status
