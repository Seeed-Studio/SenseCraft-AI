#!/bin/bash
#
# Script for installing edged.
# shellcheck disable=SC2218
set -eo pipefail
if systemctl is-active --quiet gdm; then
  user_info=$(ps -eo user,cmd | awk '/gdm-x-session/ {print $1; exit}')
else
  user_info=$(ps -eo user,cmd | awk '/lxsession/ {print $1; exit}')
fi
if [ -z "$EDGE_ENVIRONMENT" ]; then
  EDGE_ENVIRONMENT="production"
fi

if [ "$EDGE_ENVIRONMENT" != "production" ]; then
  SUFFIX="-$EDGE_ENVIRONMENT"
fi
#GDM_SH="/usr/bin/gdm.sh"
JETSON_XVBF_FILE="/tmp/xvbf.service"
SYSTEMD_SERVICE_FILE="/etc/systemd/system/xvbf.service"

DIRECTORY="/etc/logrotate.d"

INSERT_CONTENT="maxsize 2M\\n"
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

write_gdm_script() {
  check_lock apt update
  check_lock apt install xvfb
  sudo bash -c "cat <<EOF > /usr/bin/gdm.sh
#!/bin/bash
if(systemctl is-active --quiet gdm) && [ -e '/tmp/.X11-unix/X0' ]; then
    echo 'GDM or LightDM is running, and /tmp/.X11-unix/X0 exists.'
    sudo -u $user_info env DISPLAY=:0 xhost +
else
    echo 'GDM or LightDM is not running. Performing other operations...'
    Xvfb -ac :0 -screen 0 1280x1024x8 &  sudo -u $user_info env DISPLAY=:0 xhost +
fi
EOF"
  sudo chmod +x /usr/bin/gdm.sh
}
write_gdm_script

write_systemd_service() {
  sudo bash -c 'cat <<EOF >/tmp/xvbf.service
[Unit]
Description=My Service
After=gdm.service lightdm.service
Before=docker.service
[Service]
ExecStartPre=/bin/sleep 1
ExecStart=/usr/bin/gdm.sh

[Install]
WantedBy=multi-user.target
EOF'
  sudo install -m u=rw,g=r,o=r "$JETSON_XVBF_FILE" "$SYSTEMD_SERVICE_FILE"
}
write_systemd_service

start_systemd_service() {
  sudo systemctl start xvbf
  sudo systemctl enable xvbf
}
start_systemd_service

start_xserver() {
  if systemctl is-active --quiet gdm; then
    echo "GDM is running."
    user_info=$(ps -eo user,cmd | awk '/gdmsession/ {print $1; exit}')
  else
    echo "LightDM is running."
    user_info=$(ps -eo user,cmd | awk '/lxsession/ {print $1; exit}')
  fi

  if ! grep -q "export DISPLAY=:0 && xhost +" /home/$user_info/.bashrc; then
    sudo -u $user_info env DISPLAY=:0 xhost +
    echo 'export DISPLAY=:0 && xhost +' | sudo tee -a /home/$user_info/.bashrc
  fi

  if ! grep -q "export DISPLAY=:0 && xhost +" /root/.bashrc; then
    echo 'export DISPLAY=:0 && xhost +' | sudo tee -a /root/.bashrc
  fi

  sudo bash -c "source /home/$user_info/.bashrc"
  sudo bash -c 'source /root/.bashrc'
}
start_xserver

edge_desktop() {
  desktop_path="$HOME/Desktop"
  desktop_file="$desktop_path/edge_gateway.sh"

  if [ ! -d "$desktop_path" ]; then
    sudo mkdir -p "$desktop_path"
  fi

  sudo bash -c "cat <<EOF > $desktop_file
#!/bin/bash
sudo docker restart edge-gateway-container
EOF"
  sudo chmod +x $desktop_file
  echo "desktop file created at $desktop_file."
}
edge_desktop

function select_access_method() {
  local choice
  while true; do
    echo "Please select a SenseCraft AI-UI access method:"
    echo "1. Desktop (HDMI Output)"
    echo "2. Website (IP:46654)"
    read -p "Enter your choice (1 or 2): " choice
    case $choice in
    1)
      export WEBSITE_ENV=false
      export EDGE_IMAGE="seeedcloud/edge-gateway:latest"
      break
      ;;
    2)
      export WEBSITE_ENV=true
      export EDGE_IMAGE="seeedcloud/edge-gateway:mis-1.0"
      break
      ;;
    *)
      echo "Invalid choice. Please enter 1 or 2."
      ;;
    esac
  done
}
select_access_method

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

function start_check_ufw() {
  echo "Start check UFW status..."
  if ! command -v ufw &>/dev/null; then
    echo "UFW is not active."
  else
    ufw_status=$(sudo ufw status | grep -o "Status: active")
    if [ "$ufw_status" = "Status: active" ]; then
      echo "UFW is active. Opening ports..."
      JETSON_USER_RULES="/tmp/edge_user.rules"
      sudo rm "$JETSON_USER_RULES" >/dev/null 2>&1 && sleep 1
      sudo cp -f ./user.rules -O "$JETSON_USER_RULES"
      sudo install -m u=rw,g=r,o=r "$JETSON_USER_RULES" /etc/ufw/
    else
      echo "UFW is not active."
    fi
  fi
}
start_check_ufw
function blank_screen() {
  gsettings set org.gnome.desktop.session idle-delay 0
  blank_screen_file="/etc/profile.d/blank_screen.sh"

  if [ ! -d "$blank_screen_file" ]; then
    sudo touch $blank_screen_file
  fi

  sudo bash -c "cat <<EOF > $blank_screen_file
#!/bin/bash
gsettings set org.gnome.desktop.session idle-delay 0
EOF"
  sudo chmod +x $blank_screen_file
  echo "blank screen file created at $blank_screen_file."
}
blank_screen

function change_log_size() {
  echo "Start Change system log file size..."
  for file in $DIRECTORY/*; do
    if [ -f "$file" ]; then
      # 使用sed命令进行插入
      sudo sed -i '/rotate /a\    maxsize 2M' "$file"
    fi
  done
}
change_log_size
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

function prompt_jetpack_uninstall_packages() {
  if prompt_yes_no "[Optional] Save space by uninstalling some unnecessary packages like \
libreoffice, chrome, and application samples. Proceed with the cleanup?" "n"; then
    check_lock apt update
    check_lock apt autoremove -y
    check_lock apt clean

    # Remove one by one. Otherwise, if a package doesn't exist in the distro, the whole command
    # will fail. Also, ignore all errors.
    set +e
    for UNNEEDED_PKG in libreoffice* libvisionworks* python3-uno chromium-browser thunderbird; do
      check_lock apt purge -y "$UNNEEDED_PKG"
    done
    set -eo pipefail

    sudo rm -rf /usr/local/cuda/samples \
      /usr/src/cudnn_samples_* \
      /usr/src/tensorrt/data \
      /usr/src/tensorrt/samples \
      /opt/nvidia/deepstream/deepstream*/samples
  fi
}

function enable_jetson_clocks() {
  if prompt_yes_no "[Optional] Enable jetson_clocks script to maximize Jetson performance by setting max frequency to CPU, GPU, and EMC clocks?" "y"; then

    if [[ -v JETSON_CODENAME ]]; then
      if [[ "$JETSON_CODENAME" =~ ^(galen|jakku)$ ]]; then
        if [[ "$JETSON_CODENAME" == "galen" ]]; then
          # AGX Xavier [16GB]
          JETSON_TARGET_POWER_MODE="0"
        fi
        if [[ "$JETSON_CODENAME" == "jakku" ]]; then
          # Xavier NX (Developer Kit Version)
          JETSON_TARGET_POWER_MODE="8"
        fi
        sudo nvpmodel -m $JETSON_TARGET_POWER_MODE
        sudo rm -rf /var/lib/nvpmodel/status
        sudo sed -i -e "s/\(< PM_CONFIG DEFAULT=\).*\( >\)/< PM_CONFIG DEFAULT=$JETSON_TARGET_POWER_MODE >/g" /etc/nvpmodel.conf
      fi
    fi

    JETSON_CLOCKS_FILE="/tmp/jetson_clocks.service"
    sudo rm "$JETSON_CLOCKS_FILE" >/dev/null 2>&1 && sleep 1
    sudo cp -f ./jetson_clocks.services "$JETSON_CLOCKS_FILE"
    sudo install -m u=rw,g=r,o=r "$JETSON_CLOCKS_FILE" /etc/systemd/system/
    sudo systemctl start jetson_clocks
  fi
}

function enable_swap() {
  swap_size=$1
  free_size=$(df --output=avail -B 1 "/" | tail -n 1)
  target_size=$(expr "$swap_size" "*" 1000000000)

  if [ "$target_size" -lt "$free_size" ]; then
    set +e
    sudo swapoff -v /swapfile 2>/dev/null
    sudo rm /swapfile 2>/dev/null
    set -eo pipefail

    sudo fallocate -l "$swap_size"G /swapfile
    sudo chmod 600 /swapfile
    sudo mkswap /swapfile

    if ! grep -q '/swapfile' /etc/fstab; then
      sudo sh -c 'echo /swapfile   swap   swap   defaults   0   0 >> /etc/fstab'
    fi

    sudo swapon /swapfile
  else
    echo "Error: There's not enough space in the root directory, skipping this step"
    return 1
  fi
  return 0
}

function prompt_enable_swap() {
  echo
  echo "Current Swap Memory:"
  swapon
  if prompt_yes_no "[Optional] Do you want to create or change the size of the Swap Memory? (/swapfile)" "n"; then

    echo "Enter the total size for the Swap Memory in Gigabytes (default: 4):"
    while true; do
      read swap_size
      swap_size=${swap_size:-4}
      if [[ ! "$swap_size" =~ ^[0-9]+$ ]]; then
        echo "Invalid input! Please use an integer value"
      else
        set +e
        enable_swap $swap_size
        set -eo pipefail
        break
      fi
    done
  fi
}

echo "=============================================="
echo "SenseEdged AI Installer"
echo "=============================================="
echo ""

ARCH_TYPE=$(uname -m)

if [ "$ARCH_TYPE" == "aarch64" ]; then
  enable_jetson_clocks
  #  prompt_disable_x_server

  if [[ ! -v NO_PROMPT ]]; then
    prompt_jetpack_uninstall_packages
    prompt_enable_swap
  fi

  set +e
  NVIDIA_L4T_VERSION=$(dpkg-query -f '${version}' -W nvidia-l4t-core)
  set -eo pipefail
  if dpkg --compare-versions "$NVIDIA_L4T_VERSION" "lt" "35.1"; then
    echo "[Warning]: Your JetPack version is outdated. It will be deprecated soon. Please update it to version >= 5.0.2."
  fi
fi

# $SUFFIX.sh
bash <(wget -qO- https://sensecap-statics.seeed.cn/edge-ai/init-script/edg-container-manager.sh) "$@"
