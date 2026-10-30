#!/bin/bash
# Builds the sqmcp MCP shim in release; prints errors only (full log: Tools/sqmcp/.build/sqmcp-build.log).
# Binary: Tools/sqmcp/.build/release/sqmcp. Register: `claude mcp add sequence-studio -- <abs path to binary>`.
cd "$(dirname "$0")" || exit 1
mkdir -p .build
/usr/bin/swift build -c release > .build/sqmcp-build.log 2>&1
status=$?
if [ $status -ne 0 ]; then
  grep -E "error:|fatal error:" .build/sqmcp-build.log | sort -u | head -40
  echo "FAILED (full log: Tools/sqmcp/.build/sqmcp-build.log)"
  exit $status
fi
echo "OK"
