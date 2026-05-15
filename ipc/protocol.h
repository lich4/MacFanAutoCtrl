#define RULES_DIR "/Library/Application Support/MacFanAutoCtrl"
#define RULES_PATH RULES_DIR "/rules.txt"
#define SOCKET_PATH "/tmp/macfan.sock"
enum CommandType { CMD_SET_MODE, CMD_SET_SPEED, CMD_RESET };
struct Command { CommandType type; int fanId; int value; };
