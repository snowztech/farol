#!/bin/sh
# Served at farol.sh/remote.sh, so installing Farol Remote on a server is one short line:
#   curl -fsSL https://farol.sh/remote.sh | sh
# The script itself lives with the program it installs, and this only fetches it.
set -eu
curl -fsSL https://raw.githubusercontent.com/snowztech/farol-remote/main/install.sh | sh
