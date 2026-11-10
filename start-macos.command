#!/bin/bash
cd "$(dirname "$0")"
nohup node desktop/server.js --open >/dev/null 2>&1 &
