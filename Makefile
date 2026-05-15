CXX = clang++

# Dynamically find Lua path from Homebrew
LUA_PREFIX = $(shell brew --prefix lua 2>/dev/null || echo "/usr/local/opt/lua")

CXXFLAGS = -fobjc-arc -Wall -std=c++17 -I$(LUA_PREFIX)/include/lua
# Link statically against liblua.a for portability
LDFLAGS = -framework Foundation -framework IOKit $(LUA_PREFIX)/lib/liblua.a

SRCS = main.mm SMC.mm
OBJS = $(SRCS:.mm=.o)
TARGET = macfan

all: $(TARGET)

$(TARGET): $(OBJS)
	$(CXX) $(CXXFLAGS) -o $(TARGET) $(OBJS) $(LDFLAGS)

%.o: %.mm
	$(CXX) $(CXXFLAGS) -c $< -o $@

clean:
	rm -f *.o $(TARGET) macfan_cli macfan_daemon
