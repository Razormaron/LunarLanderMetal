#!/usr/bin/env bash
cd "$(dirname "$0")"
swift build -c release 2>&1 | grep -v "^Build complete"
exec .build/release/LunarLanderMetal
