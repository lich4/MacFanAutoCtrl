#import <Foundation/Foundation.h>
#import "SMC.h"
#include <lua.hpp>
#include "ipc/protocol.h"
#include <iostream>
#include <fstream>
#include <string>
#include <vector>
#include <map>
#include <sstream>
#include <iomanip>
#include <csignal>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>

#define APP_VERSION "1.0.0"

// --- Common Logic ---

struct FanProps {
    int id;
    std::string name;
    double actual;
    double min;
    double max;
    double target;
    std::string mode;
};

FanProps getFanProps(SMC *smc, int i) {
    NSString *name = [smc getStringValue:[NSString stringWithFormat:@"F%dID", i]];
    double actual = [smc getValue:[NSString stringWithFormat:@"F%dAc", i]];
    double min = [smc getValue:[NSString stringWithFormat:@"F%dMn", i]];
    double max = [smc getValue:[NSString stringWithFormat:@"F%dMx", i]];
    double target = [smc getValue:[NSString stringWithFormat:@"F%dTg", i]];
    double modeVal = [smc getValue:[smc fanModeKey:i]];
    
    return {
        i,
        name ? [name UTF8String] : "Fan " + std::to_string(i),
        actual,
        min,
        max,
        target,
        (modeVal == 0 ? "automatic" : "manual")
    };
}

// --- Daemon Logic ---

struct Rule {
    std::string expr;
    int act;
};

std::vector<Rule> loadRules() {
    std::vector<Rule> rules;
    std::ifstream infile(RULES_PATH);
    std::string line;
    while (std::getline(infile, line)) {
        size_t sep = line.find('|');
        if (sep != std::string::npos) {
            Rule r;
            r.expr = line.substr(0, sep);
            r.expr.erase(0, r.expr.find_first_not_of(" \t\n\r"));
            r.expr.erase(r.expr.find_last_not_of(" \t\n\r") + 1);
            std::string actStr = line.substr(sep + 1);
            try {
                r.act = std::stoi(actStr);
                rules.push_back(r);
            } catch (...) {}
        }
    }
    return rules;
}

int l_set_fans(lua_State *L) {
    int percent = (int)lua_tonumber(L, 1);
    SMC *smc = [SMC shared];
    double count = [smc getValue:@"FNum"];
    for (int i = 0; i < (int)count; i++) {
        double max = [smc getValue:[NSString stringWithFormat:@"F%dMx", i]];
        if (max > 0) {
            int speed = (int)(max * percent / 100.0);
            [smc setFanMode:i mode:FanModeForced];
            [smc setFanSpeed:i speed:speed];
        }
    }
    return 0;
}

int setup_socket() {
    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) return -1;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    unlink(SOCKET_PATH);
    if (bind(server_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        perror("bind");
        return -1;
    }
    chmod(SOCKET_PATH, 0666);
    if (listen(server_fd, 5) < 0) {
        perror("listen");
        return -1;
    }
    int flags = fcntl(server_fd, F_GETFL, 0);
    fcntl(server_fd, F_SETFL, flags | O_NONBLOCK);
    return server_fd;
}

void handle_ipc(int server_fd, SMC *smc) {
    int client_fd = accept(server_fd, NULL, NULL);
    if (client_fd < 0) return;
    Command cmd;
    if (read(client_fd, &cmd, sizeof(cmd)) == sizeof(cmd)) {
        if (cmd.type == CMD_SET_MODE) {
            [smc setFanMode:cmd.fanId mode:(FanMode)cmd.value];
        } else if (cmd.type == CMD_SET_SPEED) {
            [smc setFanSpeed:cmd.fanId speed:cmd.value];
        } else if (cmd.type == CMD_RESET) {
            [smc resetMacFanAutoCtrl];
        }
    }
    close(client_fd);
}

int runDaemon() {
    SMC *smc = [SMC shared];
    lua_State *L = luaL_newstate();
    luaL_openlibs(L);
    lua_pushcfunction(L, l_set_fans);
    lua_setglobal(L, "set_fans");
    int server_fd = setup_socket();
    if (server_fd < 0) fprintf(stderr, "Failed to setup IPC socket\n");
    printf("MacFanAutoCtrl Daemon started...\n");
    while (true) {
        if (server_fd >= 0) handle_ipc(server_fd, smc);
        auto rules = loadRules();
        double cpuTemp = [smc getCPUTemp];
        double gpuTemp = [smc getGPUTemp];
        std::string vars = "cpu = { temp = " + std::to_string(cpuTemp) + " }; " +
                           "gpu = { temp = " + std::to_string(gpuTemp) + " }; ";
        luaL_dostring(L, vars.c_str());
        for (const auto& rule : rules) {
            std::string script = "if (" + rule.expr + ") then set_fans(" + std::to_string(rule.act) + ") end";
            if (luaL_dostring(L, script.c_str()) != LUA_OK) {
                fprintf(stderr, "Lua Error: %s\n", lua_tostring(L, -1));
                lua_pop(L, 1);
            }
        }
        usleep(1000000);
    }
    if (server_fd >= 0) { close(server_fd); unlink(SOCKET_PATH); }
    lua_close(L);
    return 0;
}

// --- CLI Logic ---

void signalHandler(int signum) {
    printf("\033[?25h\n");
    exit(signum);
}

void printFan(std::ostream& os, const FanProps& p) {
    os << "Fan #" << p.id << ": " << p.name << "\n";
    os << "  Actual Speed: " << std::fixed << std::setprecision(0) << p.actual << " RPM\n";
    os << "  Min Speed:    " << p.min << " RPM\n";
    os << "  Max Speed:    " << p.max << " RPM\n";
    os << "  Target Speed: " << p.target << " RPM\n";
    os << "  Mode:         " << p.mode << "\n\n";
}

bool sendIPCCommand(Command cmd) {
    int client_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (client_fd < 0) return false;
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, SOCKET_PATH, sizeof(addr.sun_path) - 1);
    if (connect(client_fd, (struct sockaddr*)&addr, sizeof(addr)) < 0) {
        close(client_fd);
        return false;
    }
    ssize_t sent = write(client_fd, &cmd, sizeof(cmd));
    close(client_fd);
    return sent == sizeof(cmd);
}

int parseFanId(const std::string& str) {
    if (str.find("fan") != 0) return -1;
    try {
        size_t dotPos = str.find('.');
        std::string idPart = (dotPos == std::string::npos) ? str.substr(3) : str.substr(3, dotPos - 3);
        return std::stoi(idPart);
    } catch (...) { return -1; }
}

std::string parseProperty(const std::string& str) {
    size_t dotPos = str.find('.');
    if (dotPos == std::string::npos) return "";
    return str.substr(dotPos + 1);
}

void performList(SMC *smc, std::string target, std::ostream& os) {
    double count = [smc getValue:@"FNum"];
    if (count == -1) { os << "Error: Could not get fan count\n"; return; }
    if (target == "" || target == "cpu" || target == "gpu") {
        if (target == "" || target == "cpu") {
            double cpuTemp = [smc getCPUTemp];
            if (cpuTemp > 0) os << "CPU Temperature: " << std::fixed << std::setprecision(1) << cpuTemp << "°C\n";
        }
        if (target == "" || target == "gpu") {
            double gpuTemp = [smc getGPUTemp];
            if (gpuTemp > 0) os << "GPU Temperature: " << std::fixed << std::setprecision(1) << gpuTemp << "°C\n";
        }
        if (target == "") os << "\nNumber of fans: " << (int)count << "\n\n";
    }
    if (target == "" || target.find("fan") == 0) {
        int targetId = -1;
        if (target.find("fan") == 0) {
            targetId = parseFanId(target);
            if (targetId == -1 || targetId >= count) {
                os << "Error: Invalid fan ID '" << target << "'\n";
                return;
            }
        }
        if (targetId == -1) {
            for (int i = 0; i < (int)count; i++) printFan(os, getFanProps(smc, i));
        } else {
            printFan(os, getFanProps(smc, targetId));
        }
    }
}

void handleCond(int argc, const char * argv[]) {
    std::string sub = (argc >= 3) ? argv[2] : "";
    const char* rulesPath = RULES_PATH;
    if (sub == "add") {
        if (argc < 5) {
            printf("Usage: macfan cond add <expr> <act>\n");
            return;
        }
        std::string expr = argv[3];
        std::string act = argv[4];
        
        // Ensure directory exists (it should if service install was run, but for safety)
        mkdir(RULES_DIR, 0777);
        
        FILE* f = fopen(rulesPath, "a");
        if (f) {
            fprintf(f, "%s | %s\n", expr.c_str(), act.c_str());
            fclose(f);
            chmod(rulesPath, 0666); // Ensure anyone can edit rules
            printf("Added rule: If '%s' then set fans to %s%%\n", expr.c_str(), act.c_str());
        } else {
            perror("fopen rules");
        }
    } else if (sub == "clear") {
        remove(rulesPath);
        printf("All rules cleared.\n");
    } else if (sub == "list") {
        auto rules = loadRules();
        if (rules.empty()) {
            printf("No rules defined. (File: %s)\n", rulesPath);
        } else {
            printf("Active Rules (from %s):\n", rulesPath);
            printf("%-40s | %s\n", "Lua Expression", "Fan Speed (%)");
            printf("-----------------------------------------+---------------\n");
            for (const auto& r : rules) {
                printf("%-40s | %d%%\n", r.expr.c_str(), r.act);
            }
        }
    } else {
        printf("Usage: macfan cond [add|clear|list]\n");
    }
}

void handleService(int argc, const char * argv[]) {
    std::string sub = (argc >= 3) ? argv[2] : "";
    NSString *plistPath = @"/Library/LaunchDaemons/com.user.macfanautoctrl.plist";
    NSString *binPath = @"/usr/local/bin/macfan";

    if (sub == "install") {
        if (getuid() != 0) { printf("Error: 'service install' requires sudo\n"); return; }
        
        // Use the path of the currently running executable as the source
        NSString *srcPath = [[NSBundle mainBundle] executablePath];
        if (!srcPath) {
            printf("Error: Could not determine executable path\n");
            return;
        }

        if ([[NSFileManager defaultManager] fileExistsAtPath:binPath]) {
            // If the source is already the destination, we don't need to copy
            if ([srcPath isEqualToString:binPath]) {
                printf("Binary already in destination: %s\n", [binPath UTF8String]);
            } else {
                [[NSFileManager defaultManager] removeItemAtPath:binPath error:nil];
                NSError *error = nil;
                if (![[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:binPath error:&error]) {
                    printf("Error copying binary: %s\n", [[error localizedDescription] UTF8String]);
                    return;
                }
            }
        } else {
            NSError *error = nil;
            if (![[NSFileManager defaultManager] copyItemAtPath:srcPath toPath:binPath error:&error]) {
                printf("Error copying binary: %s\n", [[error localizedDescription] UTF8String]);
                return;
            }
        }
        chmod([binPath UTF8String], 0755);
        
        // 1.5 Create rules directory and set permissions so any user can write rules
        mkdir(RULES_DIR, 0777);
        chmod(RULES_DIR, 0777);

        // 2. Create symlink for daemon compatibility
        NSString *daemonPath = @"/usr/local/bin/macfan_daemon";
        if ([[NSFileManager defaultManager] fileExistsAtPath:daemonPath]) [[NSFileManager defaultManager] removeItemAtPath:daemonPath error:nil];
        [[NSFileManager defaultManager] createSymbolicLinkAtPath:daemonPath withDestinationPath:binPath error:nil];

        NSString *plistContent = [NSString stringWithFormat:
            @"<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n"
            "<plist version=\"1.0\">\n"
            "<dict>\n"
            "    <key>Label</key>\n"
            "    <string>com.user.macfanautoctrl</string>\n"
            "    <key>ProgramArguments</key>\n"
            "    <array>\n"
            "        <string>%@</string>\n"
            "    </array>\n"
            "    <key>RunAtLoad</key>\n"
            "    <true/>\n"
            "    <key>KeepAlive</key>\n"
            "    <true/>\n"
            "    <key>StandardOutPath</key>\n"
            "    <string>/var/log/macfan.log</string>\n"
            "    <key>StandardErrorPath</key>\n"
            "    <string>/var/log/macfan.log</string>\n"
            "</dict>\n"
            "</plist>", daemonPath]; // Use daemonPath link to trigger daemon mode
        
        NSError *writeError = nil;
        [plistContent writeToFile:plistPath atomically:YES encoding:NSUTF8StringEncoding error:&writeError];
        if (writeError) {
            printf("Error creating plist: %s\n", [[writeError localizedDescription] UTF8String]);
            return;
        }
        system([[NSString stringWithFormat:@"launchctl load -w %@", plistPath] UTF8String]);
        printf("Service installed and started.\n");
    } else if (sub == "start") {
        if (getuid() != 0) { printf("Error: 'service start' requires sudo\n"); return; }
        system("launchctl start com.user.macfanautoctrl");
        printf("Service start command sent.\n");
    } else if (sub == "stop") {
        if (getuid() != 0) { printf("Error: 'service stop' requires sudo\n"); return; }
        system("launchctl stop com.user.macfanautoctrl");
        printf("Service stop command sent.\n");
    } else if (sub == "uninstall") {
        if (getuid() != 0) { printf("Error: 'service uninstall' requires sudo\n"); return; }
        system([[NSString stringWithFormat:@"launchctl unload -w %@", plistPath] UTF8String]);
        
        NSError *error = nil;
        if ([[NSFileManager defaultManager] fileExistsAtPath:plistPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:plistPath error:&error];
        }
        
        NSString *daemonPath = @"/usr/local/bin/macfan_daemon";
        if ([[NSFileManager defaultManager] fileExistsAtPath:daemonPath]) {
            [[NSFileManager defaultManager] removeItemAtPath:daemonPath error:nil];
        }
        
        printf("Service and daemon link removed. Main binary at %s preserved.\n", [binPath UTF8String]);
    } else {
        printf("Usage: macfan service [install|uninstall]\n");
    }
}

void print_help() {
    printf("MacFanAutoCtrl v%s\n", APP_VERSION);
    printf("Usage:\n");
    printf("  macfan list [fanX|cpu|gpu]\n");
    printf("  macfan watch\n");
    printf("  macfan get fanX[.property]|cpu[.temp]|gpu[.temp]\n");
    printf("  macfan set fanX.property <value>\n");
    printf("  macfan cond add <expr> <act>\n");
    printf("  macfan cond clear\n");
    printf("  macfan cond list\n");
    printf("  sudo macfan service [install|uninstall|start|stop]\n");
    printf("  macfan daemon (run as background process)\n\n");
}

int main(int argc, const char * argv[]) {
    std::string execName = argv[0];
    if (execName.find("macfan_daemon") != std::string::npos) {
        return runDaemon();
    }

    signal(SIGINT, signalHandler);
    @autoreleasepool {
        if (argc < 2) { print_help(); return 0; }
        SMC *smc = [SMC shared];
        std::string cmd = argv[1];

        if (cmd == "daemon") return runDaemon();
        if (cmd == "cond") { handleCond(argc, argv); return 0; }
        if (cmd == "service") { handleService(argc, argv); return 0; }
        if (cmd == "list") {
            std::string target = (argc >= 3) ? argv[2] : "";
            performList(smc, target, std::cout);
        } 
        else if (cmd == "watch") {
            printf("\033[?25l\033[H\033[2J");
            while (true) {
                std::ostringstream oss;
                oss << "\033[H";
                time_t now = time(0);
                struct tm *ltm = localtime(&now);
                oss << "Monitoring MacFanAutoCtrl - " << std::setfill('0') << std::setw(2) << ltm->tm_hour << ":" << std::setfill('0') << std::setw(2) << ltm->tm_min << ":" << std::setfill('0') << std::setw(2) << ltm->tm_sec << "\n";
                performList(smc, "", oss);
                oss << "\nPress Ctrl+C to stop...\n\033[J";
                std::cout << oss.str() << std::flush;
                usleep(1000000);
            }
        }
        else if (cmd == "get") {
            if (argc < 3) return 1;
            std::string arg = argv[2];
            if (arg == "cpu" || arg == "cpu.temp") {
                double temp = [smc getCPUTemp];
                if (temp > 0) { if (arg == "cpu") printf("CPU Temperature: %.1f°C\n", temp); else printf("%.1f\n", temp); }
                else return 1;
            } else if (arg == "gpu" || arg == "gpu.temp") {
                double temp = [smc getGPUTemp];
                if (temp > 0) { if (arg == "gpu") printf("GPU Temperature: %.1f°C\n", temp); else printf("%.1f\n", temp); }
                else return 1;
            } else {
                int fanId = parseFanId(arg);
                std::string prop = parseProperty(arg);
                double count = [smc getValue:@"FNum"];
                if (fanId == -1 || fanId >= count) return 1;
                FanProps p = getFanProps(smc, fanId);
                if (prop == "") printFan(std::cout, p);
                else if (prop == "actual") printf("%.0f\n", p.actual);
                else if (prop == "min") printf("%.0f\n", p.min);
                else if (prop == "max") printf("%.0f\n", p.max);
                else if (prop == "target") printf("%.0f\n", p.target);
                else if (prop == "mode") printf("%s\n", p.mode.c_str());
            }
        }
        else if (cmd == "set") {
            if (argc < 4) return 1;
            std::string arg = argv[2];
            std::string val = argv[3];
            int fanId = parseFanId(arg);
            std::string prop = parseProperty(arg);
            if (fanId == -1) return 1;
            if (prop == "mode") {
                Command cmd; cmd.type = CMD_SET_MODE; cmd.fanId = fanId;
                cmd.value = (val == "manual" || val == "forced") ? FanModeForced : FanModeAutomatic;
                sendIPCCommand(cmd);
            } else if (prop == "target") {
                Command cmd; cmd.type = CMD_SET_SPEED; cmd.fanId = fanId; cmd.value = std::stoi(val);
                sendIPCCommand(cmd);
            }
        }
        else print_help();
    }
    return 0;
}
