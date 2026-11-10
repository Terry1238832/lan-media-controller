#!/bin/bash
cd "$(dirname "$0")"
export PATH="/usr/local/bin:/opt/homebrew/bin:/Library/Frameworks/Python.framework/Versions/Current/bin:/Library/Frameworks/Python.framework/Versions/3.14/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

OLD_PID=$(lsof -ti tcp:19889 2>/dev/null)
if [ -n "$OLD_PID" ]; then
  kill -9 $OLD_PID 2>/dev/null
fi

if command -v node >/dev/null 2>&1; then
  nohup node desktop/server.js --open >/dev/null 2>&1 &
elif command -v python3 >/dev/null 2>&1; then
  nohup python3 desktop/server.py --open >/dev/null 2>&1 &
fi

