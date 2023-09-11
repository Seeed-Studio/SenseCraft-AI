#!/bin/bash

set -eo pipefail

ARCH_TYPE=$(uname -m)
PYTHON_ENV="/usr/local/share/.edge-container-env"

if [ -z "$EDGE_ENVIRONMENT" ]; then
  EDGE_ENVIRONMENT="production"
fi

if [ "$EDGE_ENVIRONMENT" != "production" ]; then
  SUFFIX="-$EDGE_ENVIRONMENT"
fi

function check_lock() {
  i=0
  while sudo fuser /var/{lib/{dpkg,apt/lists},cache/apt/archives}/lock >/dev/null 2>&1; do
    case $((i % 4)) in
    0) l="-" ;;
    1) l="\\" ;;
    2) l="|" ;;
    3) l="/" ;;
    esac
    echo -en "\r[$l] Another process is using dpkg/apt, waiting for it to release locks..."
    sleep 1.0
    ((i = i + 1))
    if [ $i -gt 300 ]; then
      echo
      echo "More than 5 minutes passed, please make sure there's no other software manager running in parallel."
      echo "Installation aborted!"
      exit 1
    fi
  done
  app="$1"
  shift
  args="$@"
  sudo /usr/bin/"$app" $args
}

function prompt_yes_no() {
  # Usage: prompt_yes_no "message to prompt" "default_value" (can be either "y" or "n")
  local msg=$1
  local default_value=$2
  while true; do
    if [[ -v NO_PROMPT ]]; then
      # in this case we use the defaults without waiting for the user input
      echo "$msg (using default: $default_value)"
      yn=$default_value
    else
      read -p "$msg [y/n] (default: $default_value): " yn
    fi

    if [[ "$default_value" == "n" ]]; then
      case $yn in
      [Yy]) return 0 ;;
      [Nn]) return 1 ;;
      "") return 1 ;;
      esac
    else
      case $yn in
      [Nn]) return 1 ;;
      [Yy]) return 0 ;;
      "") return 0 ;;
      esac
    fi
  done
}

function update_docker_data_directory() {
  sudo DOCKER_DATA_FOLDER=$1 -E python3 <<'EOF'
import json
import os

print("[edge-container-manager] Updating docker daemon data-root")

DOCKER_CONFIG_FILE = "/etc/docker/daemon.json"
DOCKER_DATA_FOLDER = os.getenv('DOCKER_DATA_FOLDER')

with open(DOCKER_CONFIG_FILE, "r") as json_file:
    docker_config = json.load(json_file)
    docker_config["data-root"] = DOCKER_DATA_FOLDER

with open(DOCKER_CONFIG_FILE, "w") as json_file:
    json.dump(docker_config, json_file)

EOF
}

function set_docker_data_dir() {
  local external_folder=$1
  local original_folder=$(sudo docker info -f '{{ .DockerRootDir}}')

  if [ ! -d "$external_folder" ]; then
    echo "Error: Directory '$external_folder' does not exist. Please make sure the external drive is correctly mounted."
    exit 1
  fi

  sudo systemctl stop docker
  sudo systemctl stop docker.socket
  sudo systemctl stop containerd

  if [ -d "$original_folder" ]; then
    # Docker daemon was previously installed so lets move the folder contents to the external drive if there's enough space
    available_space=$(sudo df -P "$external_folder" | awk 'END{print $4}')
    original_folder_size=$(sudo du -s "$original_folder" | awk '{print $1}')

    if ((original_folder_size > available_space)); then
      echo "Error: There's not enough space on '$external_folder' to move the contents of '$original_folder'"
      sudo systemctl start docker
      exit 1
    else
      echo "Moving the contents of '$original_folder' to '$external_folder/docker'. Please wait a moment..."
      sudo cp -rp "$original_folder" "$external_folder"
    fi
  else
    echo "Error: Directory '$original_folder' does not exist. Please make sure Docker is correctly installed."
    sudo systemctl start docker
    exit 1
  fi

  # Create backup of the old docker data folder
  sudo mv "$original_folder" "$original_folder".old

  # Update docker daemon config file with the new "data-root" directory
  update_docker_data_directory "$external_folder"/docker
  echo "Successfully updated docker daemon data folder to '$external_folder/docker'. Backups can be found in '$original_folder.old' directory"
  sudo systemctl start docker
}

function check_disk_space() {
  local docker_data_folder=$(sudo docker info -f '{{ .DockerRootDir}}')
  if [ -d "$docker_data_folder" ]; then

    if [ "$ARCH_TYPE" == "aarch64" ]; then
      # aarch64 / Jetsons | 8*1024^2 KB (8 GB)
      local required_size_KB=8388608
    else
      # x86_64 / dGPU | 20*1024^2 KB (20 GB)
      local required_size_KB=20971520
    fi

    local available_space_KB=$(sudo df -P "$docker_data_folder" | awk 'END{print $4}')

    if ((available_space_KB < required_size_KB)); then
      local required_size_GB=$(echo $required_size_KB | awk '{$1=$1/(1024^2); print $1;}')
      local available_space_GB=$(echo $available_space_KB | awk '{$1=$1/(1024^2); print $1;}')
      echo "Error: There's not enough space on the partition of '$docker_data_folder' to install the container."
      echo "Disk space available: $available_space_GB GB | Disk space required: $required_size_GB GB"
      exit 1
    fi
  fi
}

check_install_with_pip() {
  PKG_NAME=$1
  VERSION=$2

  if ! pip3 show "$PKG_NAME" &>/dev/null; then
    pip3 install --upgrade pip
    pip3 install "$PKG_NAME==$VERSION"
  fi
}

install_deps() {
  echo "Checking for updates..."
  sudo cp -f ./edge-container-manager$SUFFIX.py -O /dev/shm/edge-container-manager.py
  sudo cp -f ./edge-container-update-cron$SUFFIX.sh -O /dev/shm/edge-container-update-cron.sh

  if [[ ! -f /dev/shm/edge-container-manager.py ]] || [[ ! -f /dev/shm/edge-container-update-cron.sh ]]; then
    echo "Can't download the latest version of edge-container-manager, please check your internet connection"
    exit 1
  fi

  sudo install -m u=rwx,g=rx,o=rx /dev/shm/edge-container-update-cron.sh /etc/cron.hourly/edge-container-update

  if ! [ -x "$(command -v docker)" ]; then
    check_lock apt update
    check_lock apt install -y docker.io containerd
  fi
  sudo systemctl start docker

  if [ "$ARCH_TYPE" == "aarch64" ]; then
    if ! [[ $(dpkg -l nvidia-docker2) ]]; then
      check_lock apt update
      check_lock apt install -y nvidia-docker2
      sudo systemctl restart docker
    fi
  fi

  check_lock apt -qq update
  check_lock apt -qq install -y python3 python3-apt python3-pip python3-venv

  check_install_with_pip "docker" "5.0.*"
  check_install_with_pip "petname" "2.6"
  check_install_with_pip "requests" "2.18.*"
  check_install_with_pip "tabulate" "0.8.*"
}

install_deps

init_mosquitto() {
  check_lock apt install -y mosquitto
  mosquitto_conf="/etc/mosquitto/conf.d/edge.conf"
  passwd_conf="/etc/mosquitto/mosquitto.passwd"
  if [ ! -d "$mosquitto_conf" ]; then
    sudo touch "$mosquitto_conf"
  fi

  if [ ! -d "$passwd_conf" ]; then
    sudo touch "$passwd_conf"
  fi

  if [ ! -f "$mosquitto_conf" ]; then
    cat <<EOF | sudo tee "$mosquitto_conf" >/dev/null
listener 9001
protocol websockets
port 1883

password_file /etc/mosquitto/mosquitto.passwd

allow_anonymous false
EOF
  fi
  if [ ! -f "$passwd_conf" ]; then
    cat <<EOF | sudo tee "$passwd_conf" >/dev/null
seeed:\$6\$D+Z+5Uluxb48iRrm\$QPt/n9iPFysa7dAHGwpnGEc+TWn5d6qIJOFjo/+MPLmLUXlrg==
EOF
  fi
  sudo systemctl restart mosquitto
  sudo systemctl enable mosquitto
  echo "init mosquitto info finished"
}

init_mosquitto

remove_edge() {
  echo "Start remove edge container."
  sudo docker rm -f edge-gateway-container >/dev/null 2>&1
  sudo docker rm -f edge-watchtower >/dev/null 2>&1
}
remove_edge

if [ "$ARCH_TYPE" == "aarch64" ]; then
  if prompt_yes_no "[Optional] Use external · to store the Docker data directory? (for docker images & volumes)?
(Recommended if your root partition is smaller than 32 GB)." "n"; then
    echo "Insert the path of external drive mount (example: /mnt/sdcard):"
    read mounting_folder
    set_docker_data_dir "$mounting_folder"
  fi
fi

if [[ ! -v DISABLE_CHECK_DISK_SPACE ]]; then
  check_disk_space
fi

sudo -E python3 /dev/shm/edge-container-manager.py start_watchtower
sudo -E python3 /dev/shm/edge-container-manager.py "$@"
