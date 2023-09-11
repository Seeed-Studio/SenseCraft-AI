#!/bin/bash

set -eo pipefail

sudo cp -f ./edge-container-update.sh -O /dev/shm/edge-container-update.sh

sudo bash /dev/shm/edge-container-update.sh
rm /dev/shm/edge-container-update.sh
