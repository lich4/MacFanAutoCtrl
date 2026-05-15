# MacFanAutoCtrl

A lightweight, universal command-line tool for controlling Mac fan speeds. Unified binary supporting both CLI operations and background daemon functionality.

## Features
- **Smart Automation**: Define complex fan curves using flexible Lua expressions.
- **Set-and-Forget**: Integrated system service for automatic start-at-boot.
- **Universal Support**: Native performance on both Intel and Apple Silicon (M1/M2/M3) Macs.
- **Zero Dependencies**: Single portable binary; no environment setup required for execution.
- **Full Visibility**: Real-time CPU/GPU temperature and fan speed monitoring.

## Usage

**Note**: Commands that modify SMC registers or manage services require `sudo`.

### 1. Manual Control (CLI)
```bash
# List everything
macfan list

# Get specific values
macfan get cpu.temp
macfan get fan0.target

# Set manual speed
sudo macfan set fan0.target 3000
```

### 2. Condition-Based Control
Define rules like: "If CPU temp > 40°C, set fans to 60%".

```bash
# Add a rule (Percentage is of Max RPM)
macfan cond add "cpu.temp >= 40" 60

# List active rules
macfan cond list

# Clear all rules
macfan cond clear
```

### 3. Auto-start (System Service)
Install `macfan` as a system service to start automatically at boot:

```bash
# Install and start the service
sudo macfan service install

# Stop/Start the service without uninstalling
sudo macfan service stop
sudo macfan service start

# Uninstall the service
sudo macfan service uninstall
```

**Note**: Rules are stored globally in `/Library/Application Support/MacFanAutoCtrl/rules.txt` and are shared between the root daemon and all users.

### 4. Lua Rule Examples
The `expr` in `cond add` is a Lua expression.
- `cpu.temp`: Current CPU temperature.
- `gpu.temp`: Current GPU temperature.

**Practical Examples:**
Since the daemon doesn't automatically reset the fan speed when a condition stops being true, you should use **paired rules** to create a control loop (hysteresis).

Example: High-speed cooling when hot, and returning to quiet mode only when sufficiently cooled down.
```bash
# 1. Trigger 100% speed if either CPU or GPU hits 50°C
macfan cond add "cpu.temp >= 50 or gpu.temp >= 50" 100

# 2. Return to 10% (quiet) ONLY when BOTH are back below 40°C
macfan cond add "cpu.temp <= 40 and gpu.temp <= 40" 10
```

## Build from Source
If you wish to compile the binary yourself:
1. **Prerequisite**: Install Lua via Homebrew:
   ```bash
   brew install lua
   ```
2. **Compile**:
   ```bash
   make
   ```

## Available Properties
| Property | Description | Access |
| :--- | :--- | :--- |
| `actual` | Current real-time RPM | Read-only |
| `min` | Minimum supported RPM | Read-only |
| `max` | Maximum supported RPM | Read-only |
| `target` | User-defined target RPM | Read/Write |
| `mode` | `auto` or `manual` | Read/Write |

## Safety Warning
- **Heat Management**: Manual low speeds under load can cause overheating.
- **No Warranty**: Use at your own risk.

## License
MIT
