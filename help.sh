#!/usr/bin/env bash

# # # # # # # # # # # # # # # # # # # #
# show share commands
if [ -f "$PROJECT_CONFIG" ]; then
    printf "SHARE COMMANDS:\n"
    printf "    ${BLUE}share${NORMAL}${HELP_SPACE:5}Share application in your local network.\n"
fi
