# MacFanAutoCtrl

一个轻量级的、通用的 Mac 风扇转速控制命令行工具。采用统一二进制设计，支持命令行操作和后台守护进程（Daemon）功能。

## 功能特性
- **智能自动化**: 使用灵活的 Lua 表达式定义复杂的风扇曲线。
- **一劳永逸**: 集成系统服务，支持开机自动启动，后台静默运行。
- **全面兼容**: 原生支持 Intel 和 Apple Silicon (M1/M2/M3) 架构的 Mac。
- **零依赖**: 静态链接的单一二进制文件，无需安装环境即可运行。
- **实时监控**: 集成 CPU/GPU 温度及风扇转速的实时追踪。

## 使用说明

**注意**: 修改 SMC 寄存器或管理服务的命令需要 `sudo` 权限。

### 1. 手动控制 (CLI)
```bash
# 列出所有风扇和温度
macfan list

# 获取特定属性
macfan get cpu.temp
macfan get fan0.target

# 设置手动转速
sudo macfan set fan0.target 3000
```

### 2. 基于条件的自动化控制
你可以定义规则，例如：“如果 CPU 温度 > 40°C，则设置风扇转速为 60%”。

```bash
# 添加规则 (百分比基于最大转速)
macfan cond add "cpu.temp >= 40" 60

# 查看当前活跃规则
macfan cond list

# 清除所有规则
macfan cond clear
```

### 3. 开机自启 (系统服务)
将 `macfan` 安装为系统服务，使其在开机时自动运行：

```bash
# 安装并启动服务
sudo macfan service install

# 在不卸载的情况下停止/启动服务
sudo macfan service stop
sudo macfan service start

# 卸载服务
sudo macfan service uninstall
```

**注意**: 规则文件存储在全局路径 `/Library/Application Support/MacFanAutoCtrl/rules.txt`，由 root 守护进程和所有用户共享。

### 4. Lua 规则示例
`cond add` 中的 `expr` 是 Lua 表达式。可用变量：
- `cpu.temp`: 当前 CPU 温度。
- `gpu.temp`: 当前 GPU 温度。

**实战示例：**
由于守护进程在条件不再满足时不会自动重置风扇速度，建议使用**成对规则**来创建控制回路（滞后控制）。

示例：高温时强制散热，降温后返回静音模式。
```bash
# 1. 升温触发：CPU 或 GPU 达到 50°C 时，开启 100% 全速
macfan cond add "cpu.temp >= 50 or gpu.temp >= 50" 100

# 2. 降温恢复：只有当两者都降至 40°C 以下时，才返回 10% 静音转速
macfan cond add "cpu.temp <= 40 and gpu.temp <= 40" 10
```

## 源码编译
如果你希望自行从源码构建二进制文件：
1. **前置条件**: 通过 Homebrew 安装 Lua：
   ```bash
   brew install lua
   ```
2. **编译**:
   ```bash
   make
   ```

## 可用属性
| 属性 | 描述 | 访问权限 |
| :--- | :--- | :--- |
| `actual` | 实时当前转速 (RPM) | 只读 |
| `min` | 支持的最小转速 (RPM) | 只读 |
| `max` | 支持的最大转速 (RPM) | 只读 |
| `target` | 用户定义的目录转速 (RPM) | 读/写 |
| `mode` | `auto` (自动) 或 `manual` (手动) | 读/写 |

## 安全警告
- **散热管理**: 在高负载下手动设置低转速可能导致 Mac 过热。
- **免责声明**: 使用该工具风险自担。

## 开源协议
MIT
