#!/bin/sh
# Served at farol.sh/remote.sh, which keeps the line that installs Farol Remote on a server short.
# The script itself lives with the program it installs, and this only fetches it.
set -eu
curl -fsSL https://raw.githubusercontent.com/snowztech/farol-remote/main/install.sh | sh
