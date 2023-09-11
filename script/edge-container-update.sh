#!/bin/bash

set -eo pipefail

if [ -z "$EDGE_ENVIRONMENT" ]; then
  EDGE_ENVIRONMENT="production"
fi

if [ "$EDGE_ENVIRONMENT" != "production" ]; then
  SUFFIX="-$EDGE_ENVIRONMENT"
fi

PYTHON_ENV="/usr/local/share/.edge-container-env"

# `apt` was missing in the older version of installer, so let's make sure it's installed.
sudo apt update
sudo apt install -y python3-apt

# --system-site-packages were disabled in the older version of installer.
python3 -m venv --system-site-packages "$PYTHON_ENV"

sudo cp -f ./edge-container-manager.py -O /dev/shm/edge-container-manager.py
sudo -E python3 /dev/shm/edge-container-manager.py update
