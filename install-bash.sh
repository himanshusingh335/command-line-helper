#!/bin/sh
# Kept for old instructions: install.sh now handles bash too.
exec sh "$(dirname "$0")/install.sh" --shell bash "$@"
