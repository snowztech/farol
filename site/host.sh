#!/bin/sh
# Served at farol.sh/host.sh, which keeps the line that installs farol-host on a server short.
# The script itself lives with the program it installs, and this only fetches it.
set -eu
curl -fsSL https://raw.githubusercontent.com/snowztech/farol-remote/main/host/install.sh | sh
