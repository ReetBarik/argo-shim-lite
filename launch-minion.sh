#!/bin/bash
# Wrapper for launchd — loads secrets then starts minion.py.
source /Users/rbarik/.minion-secrets
exec /Users/rbarik/argo-shim-lite/.venv/bin/python3 /Users/rbarik/argo-shim-lite/minion.py
