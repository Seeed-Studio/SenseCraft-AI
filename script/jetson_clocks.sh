#!/bin/bash
# Copyright (c) 2015-2023, NVIDIA CORPORATION. All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
#  * Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
#  * Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#  * Neither the name of NVIDIA CORPORATION nor the names of its
#    contributors may be used to endorse or promote products derived
#    from this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS ``AS IS'' AND ANY
# EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE COPYRIGHT OWNER OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
# EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
# PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
# PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY
# OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

JETSON_CLOCKS="$(basename ${0})"
FAN_SPEED_OVERRIDE=0
CONF_FILE="${HOME}/.jetsonclocks_conf.txt"
FAN_STATUS_FILE="${HOME}/.jetsonclocks_fan.txt"
gpu_type="unknown"
has_igpu_devfreq=0
RED='\e[0;31m'
GREEN='\e[0;32m'
BLUE='\e[0;34m'
BRED='\e[1;31m'
BGREEN='\e[1;32m'
BBLUE='\e[1;34m'
NC='\e[0m' # No Color

usage() {
  if [ "$1" != "" ]; then
    echo -e ${RED}"$1"${NC}
  fi

  cat >&2 <<EOF
Maximize jetson performance by setting static max frequency to CPU, GPU and EMC clocks.
Usage:
${JETSON_CLOCKS} [options]
  options,
  --help, -h         show this help message
  --show             display current settings
  --fan              set PWM fan speed to maximal
  --store [file]     store current settings to a file (default: \${HOME}/l4t_dfs.conf)
  --restore [file]   restore saved settings from a file (default: \${HOME}/l4t_dfs.conf)
  run ${JETSON_CLOCKS} without any option to set static max frequency to CPU, GPU and EMC clocks.
EOF

  exit 0
}

detect_gpu_type() {
  iGPU_DEV_NODES=(/dev/nvhost-gpu /dev/nvhost-power-gpu)
  dGPU_DEV_NODES=(/dev/nvidiactl /dev/nvgpu-pci/*)

  for dev_node in ${iGPU_DEV_NODES[@]}; do
    if [ -e $dev_node ]; then
      gpu_type="iGPU"
      return
    fi
  done

  for dev_node in ${dGPU_DEV_NODES[@]}; do
    if [ -e $dev_node ]; then
      gpu_type="dGPU"
      return
    fi
  done
}

detect_igpu_devfreq() {
  igpu_name="$(tr -d '\0' </sys/devices/platform/gpu.0/of_node/compatible)"
  if [ "${igpu_name}" != "nvidia,gv11b" ] && [ "${igpu_name}" != "nvidia,gp10b" ] &&
    [ "${igpu_name}" != "nvidia,ga10b" ]; then
    echo "Error! Unknown GPU!"
    exit 1
  fi

  for devfreq in /sys/class/devfreq/*; do
    if [ ! -f "${devfreq}/device/of_node/compatible" ]; then
      continue
    fi

    devfreq_name=$(tr -d '\0' <${devfreq}/device/of_node/compatible)
    if [ "${igpu_name}" == "${devfreq_name}" ]; then
      GPU_MIN_FREQ="${devfreq}/min_freq"
      GPU_MAX_FREQ="${devfreq}/max_freq"
      GPU_CUR_FREQ="${devfreq}/cur_freq"
      GPU_SET_FREQ="${devfreq}/min_freq"
      has_igpu_devfreq=1
      break
    fi
  done
}

check_nvidia_smi() {
  nvidia-smi &>/dev/null
  ret=$?
  if [ ${ret} -ne 0 ]; then
    case ${ret} in
    127)
      echo "Error: nvidia-smi not found."
      exit 1
      ;;
    *)
      echo "Error: fail to do nvidia-smi operation." \
        "The exit code of nvidia-smi is ${ret}"
      exit 1
      ;;
    esac
  fi
}

host1x_get_node() {
  HOST1X_KSTABLE_NODE="/sys/devices/platform/bus@0/13e00000.host1x"
  case "${SOCFAMILY}" in
  tegra194)
    HOST1X_NODE="/sys/devices/platform/13e10000.host1x"
    ;;
  tegra234)
    HOST1X_NODE="/sys/devices/platform/13e40000.host1x"
    ;;
  *) ;;

  esac

}

dla_get_state() {
  DLA0_STATE=0
  DLA1_STATE=0
  DLA0_NODE="15880000.nvdla0"
  DLA1_NODE="158c0000.nvdla1"

  host1x_get_node
  if [ -d "${HOST1X_NODE}/${DLA0_NODE}" ] ||
    [ -d "${HOST1X_KSTABLE_NODE}/${DLA0_NODE}" ]; then
    DLA0_STATE=1
  fi

  if [ -d "${HOST1X_NODE}/${DLA1_NODE}" ] ||
    [ -d "${HOST1X_KSTABLE_NODE}/${DLA1_NODE}" ]; then
    DLA1_STATE=1
  fi
}

pva_get_state() {
  PVA0_STATE=0
  PVA1_STATE=0
  PVA0_NODE="16000000.pva0"
  PVA1_NODE="16800000.pva1"

  host1x_get_node
  if [ -d "${HOST1X_NODE}/${PVA0_NODE}" ] ||
    [ -d "${HOST1X_KSTABLE_NODE}/${PVA0_NODE}" ]; then
    PVA0_STATE=1
  fi

  if [ -d "${HOST1X_NODE}/${PVA1_NODE}" ] ||
    [ -d "${HOST1X_KSTABLE_NODE}/${PVA1_NODE}" ]; then
    PVA1_STATE=1
  fi
}

dgpu_restore() {
  if [[ "${gpu_type}" == "dGPU" ]]; then
    nvidia-smi -rac -i 0 >/dev/null
    ret=$?
    if [ ${ret} -ne 0 ]; then
      echo "Error: Failed to restore dGPU application clocks frequency!"
    fi
  fi
}

fan_restore() {
  if [ -e "${FAN_STATUS_FILE}" ]; then
    NVFANCONTROL_STATUS="$(cat ${FAN_STATUS_FILE})"
    if [ "${NVFANCONTROL_STATUS}" == "active" ]; then
      systemctl start nvfancontrol
    else
      systemctl stop nvfancontrol
    fi
  fi
}

restore() {
  for conf in $(cat "${CONF_FILE}"); do
    file="$(echo $conf | cut -f1 -d :)"
    data="$(echo $conf | cut -f2 -d :)"
    case "${file}" in
    /sys/devices/system/cpu/cpu*/online | \
      /sys/kernel/debug/clk/override*/state)
      if [ $(cat $file) -ne $data ]; then
        echo "${data}" >"${file}"
      fi
      ;;
    /sys/devices/system/cpu/cpu*/cpufreq/scaling_min_freq)
      echo "${data}" >"${file}" 2>/dev/null
      ;;
    *)
      echo "${data}" >"${file}"
      ret=$?
      if [ ${ret} -ne 0 ]; then
        echo "Error: Failed to restore $file"
      fi
      ;;
    esac
  done

  fan_restore
  dgpu_restore
}

store() {
  for file in $@; do
    if [ -e "${file}" ]; then
      echo "${file}:$(cat ${file})" >>"${CONF_FILE}"
    fi
  done
}

do_nvpmodel() {
  case "${ACTION}" in
  show)
    NVPMODEL_BIN="/usr/sbin/nvpmodel"
    NVPMODEL_CONF="/etc/nvpmodel.conf"
    if [ -e "${NVPMODEL_BIN}" ]; then
      if [ -e "${NVPMODEL_CONF}" ]; then
        POWER_MODE="$(nvpmodel -q | grep "NV Power Mode")"
        echo "${POWER_MODE}"
      fi
    fi
    ;;
  esac
}

do_fan() {
  NVFANCONTROL_STATUS="$(systemctl is-active nvfancontrol)"
  FAN_MAX_PWM=255
  FAN_NODES=(
    /sys/devices/platform/pwm-fan*/hwmon/hwmon*/pwm*
    /sys/bus/i2c/drivers/f75308/*/hwmon/hwmon*/pwm*
  )

  case "${ACTION}" in
  show)
    for file in "${FAN_NODES[@]}"; do
      if [ -e "${file}" ]; then
        hwmon_id="$(dirname ${file} | xargs basename)"
        pwm_id="$(basename ${file})"
        pwm="$(cat ${file})"
        echo "FAN Dynamic Speed control=${NVFANCONTROL_STATUS} ${hwmon_id}_${pwm_id}=${pwm}"
      fi
    done
    ;;
  store)
    echo "${NVFANCONTROL_STATUS}" >"${FAN_STATUS_FILE}"
    store "${FAN_STATUS_FILE}"
    ;;
  *)
    if [ "${FAN_SPEED_OVERRIDE}" -eq "1" ]; then
      systemctl stop nvfancontrol

      for file in "${FAN_NODES[@]}"; do
        if [ -e "${file}" ]; then
          echo "${FAN_MAX_PWM}" >"${file}"
        fi
      done
    fi
    ;;
  esac
}

do_hotplug() {
  case "${ACTION}" in
  show)
    echo "Online CPUs: $(cat /sys/devices/system/cpu/online)"
    ;;
  store)
    for file in /sys/devices/system/cpu/cpu[0-9]*/online; do
      store "${file}"
    done
    ;;
  *) ;;

  esac
}

do_cpu() {
  FREQ_GOVERNOR="cpufreq/scaling_governor"
  CPU_MIN_FREQ="cpufreq/scaling_min_freq"
  CPU_MAX_FREQ="cpufreq/scaling_max_freq"
  CPU_CUR_FREQ="cpufreq/scaling_cur_freq"
  CPU_SYSFS="/sys/devices/system/cpu"

  if [ ! -d "${CPU_SYSFS}/cpu0/cpuidle" ]; then
    echo "WARNING! CPUIDLE is not supported!"
  fi

  if [ ! -d "${CPU_SYSFS}/cpu0/cpufreq" ]; then
    echo "WARNING! CPUFREQ is not supported!"
  fi

  case "${ACTION}" in
  show)
    for folder in ${CPU_SYSFS}/cpu[0-9]*; do
      CPU=$(basename ${folder})
      if [ -d "${folder}/cpuidle" ]; then
        idle_states=""
        for idle in ${folder}/cpuidle/state[0-9]*; do
          idle_states+="$(cat ${idle}/name)"
          idle_disable="$(cat ${idle}/disable)"
          idle_states+="=$((idle_disable == 0)) "
        done
      fi
      if [ -e "${folder}/${FREQ_GOVERNOR}" ]; then
        echo "$CPU: Online=$(cat ${folder}/online)" \
          "Governor=$(cat ${folder}/${FREQ_GOVERNOR})" \
          "MinFreq=$(cat ${folder}/${CPU_MIN_FREQ})" \
          "MaxFreq=$(cat ${folder}/${CPU_MAX_FREQ})" \
          "CurrentFreq=$(cat ${folder}/${CPU_CUR_FREQ})" \
          "IdleStates: $idle_states"
      fi
    done
    ;;
  store)
    if [ -d "${CPU_SYSFS}/cpu0/cpufreq" ]; then
      for file in ${CPU_SYSFS}/cpu[0-9]*/cpufreq/scaling_min_freq; do
        store "${file}"
      done
    fi

    if [ -d "${CPU_SYSFS}/cpu0/cpuidle" ]; then
      for file in ${CPU_SYSFS}/cpu[0-9]*/cpuidle/state[0-9]*/disable; do
        store "${file}"
      done
    fi
    ;;
  *)
    if [ -d "${CPU_SYSFS}/cpu0/cpufreq" ]; then
      for folder in ${CPU_SYSFS}/cpu[0-9]*; do
        cat "${folder}/${CPU_MAX_FREQ}" >"${folder}/${CPU_MIN_FREQ}" 2>/dev/null
      done
    fi

    if [ -d "${CPU_SYSFS}/cpu0/cpuidle" ]; then
      for file in ${CPU_SYSFS}/cpu[0-9]*/cpuidle/state[0-9]*/disable; do
        echo 1 >"${file}"
      done
    fi
    ;;
  esac
}

do_igpu() {
  if [ ! -f "/sys/devices/platform/gpu.0/of_node/compatible" ]; then
    echo "Error! No GPU found!"
    exit 1
  fi

  GPU_RAIL_GATE="/sys/devices/platform/gpu.0/railgate_enable"

  detect_igpu_devfreq
  if [ ${has_igpu_devfreq} -eq 0 ]; then
    # The GPU needs to be powered up once to register with DEVFREQ
    GPU_RAIL_GATE_STATE="$(cat ${GPU_RAIL_GATE})"
    echo 0 >"${GPU_RAIL_GATE}"

    # Detect GPU DEVFREQ again (once only)
    detect_igpu_devfreq

    # Restore the GPU rail gate state
    echo "${GPU_RAIL_GATE_STATE}" >"${GPU_RAIL_GATE}"
  fi

  if [ ${has_igpu_devfreq} -eq 0 ]; then
    echo "Error! GPU frequency scaling not supported!"
    exit 1
  fi

  case "${ACTION}" in
  show)
    echo "GPU MinFreq=$(cat ${GPU_MIN_FREQ})" \
      "MaxFreq=$(cat ${GPU_MAX_FREQ})" \
      "CurrentFreq=$(cat ${GPU_CUR_FREQ})"
    ;;
  store)
    store "${GPU_MIN_FREQ}"
    store "${GPU_RAIL_GATE}"
    ;;
  *)
    echo 0 >"${GPU_RAIL_GATE}"
    cat "${GPU_MAX_FREQ}" >"${GPU_SET_FREQ}"
    ret=$?
    if [ ${ret} -ne 0 ]; then
      echo "Error: Failed to max GPU frequency!"
    fi
    ;;
  esac
}

do_dgpu() {
  NV_SMI_QUERY_GPU="nvidia-smi --format=csv,noheader,nounits --query-gpu"
  dGPU_DEF_MEM="$(${NV_SMI_QUERY_GPU}=clocks.default_applications.memory)"
  dGPU_MAX_MEM="$(${NV_SMI_QUERY_GPU}=clocks.max.memory)"
  dGPU_CUR_MEM="$(${NV_SMI_QUERY_GPU}=clocks.applications.memory)"
  dGPU_DEF_GRA="$(${NV_SMI_QUERY_GPU}=clocks.default_applications.graphics)"
  dGPU_MAX_GRA="$(${NV_SMI_QUERY_GPU}=clocks.max.graphics)"
  dGPU_CUR_GRA="$(${NV_SMI_QUERY_GPU}=clocks.applications.graphics)"

  case "${ACTION}" in
  show)
    echo "dGPU DefaultMemFreq=${dGPU_DEF_MEM}MHz" \
      "MaxMemFreq=${dGPU_MAX_MEM}MHz" \
      "CurrentMemFreq=${dGPU_CUR_MEM}MHz"
    echo "dGPU DefaultGraFreq=${dGPU_DEF_GRA}MHz" \
      "MaxGraFreq=${dGPU_MAX_GRA}MHz" \
      "CurrentGraFreq=${dGPU_CUR_GRA}MHz"
    ;;
  *)
    nvidia-smi -pm ENABLED -i 0 >/dev/null
    nvidia-smi -ac ${dGPU_MAX_MEM},${dGPU_MAX_GRA} -i 0 >/dev/null
    ret=$?
    if [ ${ret} -ne 0 ]; then
      echo "Error: Failed to max dGPU application clocks frequency!"
    fi
    ;;
  esac
}

do_emc() {
  case "${SOCFAMILY}" in
  tegra186 | tegra194 | tegra234)
    EMC_ISO_CAP="/sys/kernel/nvpmodel_emc_cap/emc_iso_cap"
    EMC_MIN_FREQ="/sys/kernel/debug/bpmp/debug/clk/emc/min_rate"
    EMC_MAX_FREQ="/sys/kernel/debug/bpmp/debug/clk/emc/max_rate"
    EMC_CUR_FREQ="/sys/kernel/debug/bpmp/debug/clk/emc/rate"
    EMC_UPDATE_FREQ="/sys/kernel/debug/bpmp/debug/clk/emc/rate"
    EMC_FREQ_OVERRIDE="/sys/kernel/debug/bpmp/debug/clk/emc/mrq_rate_locked"
    ;;
  tegra210)
    EMC_MIN_FREQ="/sys/kernel/debug/tegra_bwmgr/emc_min_rate"
    EMC_MAX_FREQ="/sys/kernel/debug/tegra_bwmgr/emc_max_rate"
    EMC_CUR_FREQ="/sys/kernel/debug/clk/override.emc/clk_rate"
    EMC_UPDATE_FREQ="/sys/kernel/debug/clk/override.emc/clk_update_rate"
    EMC_FREQ_OVERRIDE="/sys/kernel/debug/clk/override.emc/clk_state"
    ;;
  *)
    echo "Error! unsupported SOC ${SOCFAMILY}"
    exit 1
    ;;

  esac

  if [ "${SOCFAMILY}" = "tegra186" -o "${SOCFAMILY}" = "tegra194" -o "${SOCFAMILY}" = "tegra234" ]; then
    if [ -f "${EMC_ISO_CAP}" ]; then
      emc_cap="$(cat "${EMC_ISO_CAP}")"
    else
      emc_cap="0"
    fi
    emc_fmax="$(cat "${EMC_MAX_FREQ}")"
    if [ "$emc_cap" -gt 0 ] && [ "$emc_cap" -lt "$emc_fmax" ]; then
      EMC_MAX_FREQ="${EMC_ISO_CAP}"
    fi
  fi

  case "${ACTION}" in
  show)
    echo "EMC MinFreq=$(cat ${EMC_MIN_FREQ})" \
      "MaxFreq=$(cat ${EMC_MAX_FREQ})" \
      "CurrentFreq=$(cat ${EMC_CUR_FREQ})" \
      "FreqOverride=$(cat ${EMC_FREQ_OVERRIDE})"
    ;;
  store)
    store "${EMC_FREQ_OVERRIDE}"
    ;;
  *)
    echo 1 >"${EMC_FREQ_OVERRIDE}"
    cat "${EMC_MAX_FREQ}" >"${EMC_UPDATE_FREQ}"
    ;;
  esac
}

do_dla() {
  dla_get_state
  case "${SOCFAMILY}" in
  tegra194 | tegra234)
    DLA0_CORE_MIN_FREQ="/sys/kernel/debug/clk/dla0_core/clk_min_rate"
    DLA0_CORE_MAX_FREQ="/sys/kernel/debug/clk/dla0_core/clk_max_rate"
    DLA0_CORE_CUR_FREQ="/sys/kernel/debug/clk/dla0_core/clk_rate"
    DLA0_FALCON_MIN_FREQ="/sys/kernel/debug/clk/dla0_falcon/clk_min_rate"
    DLA0_FALCON_MAX_FREQ="/sys/kernel/debug/clk/dla0_falcon/clk_max_rate"
    DLA0_FALCON_CUR_FREQ="/sys/kernel/debug/clk/dla0_falcon/clk_rate"
    DLA1_CORE_MIN_FREQ="/sys/kernel/debug/clk/dla1_core/clk_min_rate"
    DLA1_CORE_MAX_FREQ="/sys/kernel/debug/clk/dla1_core/clk_max_rate"
    DLA1_CORE_CUR_FREQ="/sys/kernel/debug/clk/dla1_core/clk_rate"
    DLA1_FALCON_MIN_FREQ="/sys/kernel/debug/clk/dla1_falcon/clk_min_rate"
    DLA1_FALCON_MAX_FREQ="/sys/kernel/debug/clk/dla1_falcon/clk_max_rate"
    DLA1_FALCON_CUR_FREQ="/sys/kernel/debug/clk/dla1_falcon/clk_rate"
    ;;
  *) ;;

  esac

  case "${ACTION}" in
  show)
    if [ -e "${DLA0_CORE_MAX_FREQ}" ]; then
      echo "DLA0_CORE:   Online=${DLA0_STATE}" \
        "MinFreq=$(cat ${DLA0_CORE_MIN_FREQ})" \
        "MaxFreq=$(cat ${DLA0_CORE_MAX_FREQ})" \
        "CurrentFreq=$(cat ${DLA0_CORE_CUR_FREQ})"
    fi
    if [ -e "${DLA0_FALCON_MAX_FREQ}" ]; then
      echo "DLA0_FALCON: Online=${DLA0_STATE}" \
        "MinFreq=$(cat ${DLA0_FALCON_MIN_FREQ})" \
        "MaxFreq=$(cat ${DLA0_FALCON_MAX_FREQ})" \
        "CurrentFreq=$(cat ${DLA0_FALCON_CUR_FREQ})"
    fi
    if [ -e "${DLA1_CORE_MAX_FREQ}" ]; then
      echo "DLA1_CORE:   Online=${DLA1_STATE}" \
        "MinFreq=$(cat ${DLA1_CORE_MIN_FREQ})" \
        "MaxFreq=$(cat ${DLA1_CORE_MAX_FREQ})" \
        "CurrentFreq=$(cat ${DLA1_CORE_CUR_FREQ})"
    fi
    if [ -e "${DLA1_FALCON_MAX_FREQ}" ]; then
      echo "DLA1_FALCON: Online=${DLA1_STATE}" \
        "MinFreq=$(cat ${DLA1_FALCON_MIN_FREQ})" \
        "MaxFreq=$(cat ${DLA1_FALCON_MAX_FREQ})" \
        "CurrentFreq=$(cat ${DLA1_FALCON_CUR_FREQ})"
    fi
    ;;
  *) ;;

  esac
}

do_pva() {
  pva_get_state
  case "${SOCFAMILY}" in
  tegra194)
    PVA0_VPS0_MIN_FREQ="/sys/kernel/debug/clk/pva0_vps0/clk_min_rate"
    PVA0_VPS0_MAX_FREQ="/sys/kernel/debug/clk/pva0_vps0/clk_max_rate"
    PVA0_VPS0_CUR_FREQ="/sys/kernel/debug/clk/pva0_vps0/clk_rate"
    PVA0_VPS1_MIN_FREQ="/sys/kernel/debug/clk/pva0_vps1/clk_min_rate"
    PVA0_VPS1_MAX_FREQ="/sys/kernel/debug/clk/pva0_vps1/clk_max_rate"
    PVA0_VPS1_CUR_FREQ="/sys/kernel/debug/clk/pva0_vps1/clk_rate"
    PVA0_AXI_MIN_FREQ="/sys/kernel/debug/clk/pva0_axi/clk_min_rate"
    PVA0_AXI_MAX_FREQ="/sys/kernel/debug/clk/pva0_axi/clk_max_rate"
    PVA0_AXI_CUR_FREQ="/sys/kernel/debug/clk/pva0_axi/clk_rate"
    PVA1_VPS0_MIN_FREQ="/sys/kernel/debug/clk/pva1_vps0/clk_min_rate"
    PVA1_VPS0_MAX_FREQ="/sys/kernel/debug/clk/pva1_vps0/clk_max_rate"
    PVA1_VPS0_CUR_FREQ="/sys/kernel/debug/clk/pva1_vps0/clk_rate"
    PVA1_VPS1_MIN_FREQ="/sys/kernel/debug/clk/pva1_vps1/clk_min_rate"
    PVA1_VPS1_MAX_FREQ="/sys/kernel/debug/clk/pva1_vps1/clk_max_rate"
    PVA1_VPS1_CUR_FREQ="/sys/kernel/debug/clk/pva1_vps1/clk_rate"
    PVA1_AXI_MIN_FREQ="/sys/kernel/debug/clk/pva1_axi/clk_min_rate"
    PVA1_AXI_MAX_FREQ="/sys/kernel/debug/clk/pva1_axi/clk_max_rate"
    PVA1_AXI_CUR_FREQ="/sys/kernel/debug/clk/pva1_axi/clk_rate"
    ;;
  tegra234)
    PVA0_VPS0_MIN_FREQ="/sys/kernel/debug/clk/pva0_vps/clk_min_rate"
    PVA0_VPS0_MAX_FREQ="/sys/kernel/debug/clk/pva0_vps/clk_max_rate"
    PVA0_VPS0_CUR_FREQ="/sys/kernel/debug/clk/pva0_vps/clk_rate"
    PVA0_AXI_MIN_FREQ="/sys/kernel/debug/clk/pva0_cpu_axi/clk_min_rate"
    PVA0_AXI_MAX_FREQ="/sys/kernel/debug/clk/pva0_cpu_axi/clk_max_rate"
    PVA0_AXI_CUR_FREQ="/sys/kernel/debug/clk/pva0_cpu_axi/clk_rate"
    ;;
  *) ;;

  esac

  case "${ACTION}" in
  show)
    if [ -e "${PVA0_VPS0_MAX_FREQ}" ]; then
      echo "PVA0_VPS0: Online=${PVA0_STATE}" \
        "MinFreq=$(cat ${PVA0_VPS0_MIN_FREQ})" \
        "MaxFreq=$(cat ${PVA0_VPS0_MAX_FREQ})" \
        "CurrentFreq=$(cat ${PVA0_VPS0_CUR_FREQ})"
    fi
    if [ -e "${PVA0_VPS1_MAX_FREQ}" ]; then
      echo "PVA0_VPS1: Online=${PVA0_STATE}" \
        "MinFreq=$(cat ${PVA0_VPS1_MIN_FREQ})" \
        "MaxFreq=$(cat ${PVA0_VPS1_MAX_FREQ})" \
        "CurrentFreq=$(cat ${PVA0_VPS1_CUR_FREQ})"
    fi
    if [ -e "${PVA0_AXI_MAX_FREQ}" ]; then
      echo "PVA0_AXI:  Online=${PVA0_STATE}" \
        "MinFreq=$(cat ${PVA0_AXI_MIN_FREQ})" \
        "MaxFreq=$(cat ${PVA0_AXI_MAX_FREQ})" \
        "CurrentFreq=$(cat ${PVA0_AXI_CUR_FREQ})"
    fi
    if [ -e "${PVA1_VPS0_MAX_FREQ}" ]; then
      echo "PVA1_VPS0: Online=${PVA1_STATE}" \
        "MinFreq=$(cat ${PVA1_VPS0_MIN_FREQ})" \
        "MaxFreq=$(cat ${PVA1_VPS0_MAX_FREQ})" \
        "CurrentFreq=$(cat ${PVA1_VPS0_CUR_FREQ})"
    fi
    if [ -e "${PVA1_VPS1_MAX_FREQ}" ]; then
      echo "PVA1_VPS1: Online=${PVA1_STATE}" \
        "MinFreq=$(cat ${PVA1_VPS1_MIN_FREQ})" \
        "MaxFreq=$(cat ${PVA1_VPS1_MAX_FREQ})" \
        "CurrentFreq=$(cat ${PVA1_VPS1_CUR_FREQ})"
    fi
    if [ -e "${PVA1_AXI_MAX_FREQ}" ]; then
      echo "PVA1_AXI:  Online=${PVA1_STATE}" \
        "MinFreq=$(cat ${PVA1_AXI_MIN_FREQ})" \
        "MaxFreq=$(cat ${PVA1_AXI_MAX_FREQ})" \
        "CurrentFreq=$(cat ${PVA1_AXI_CUR_FREQ})"
    fi
    ;;
  *) ;;

  esac
}

do_cvnas() {
  case "${SOCFAMILY}" in
  tegra194)
    CVNAS_MIN_FREQ="/sys/kernel/debug/clk/cvnas/clk_min_rate"
    CVNAS_MAX_FREQ="/sys/kernel/debug/clk/cvnas/clk_max_rate"
    CVNAS_CUR_FREQ="/sys/kernel/debug/clk/cvnas/clk_rate"
    ;;
  *) ;;

  esac

  case "${ACTION}" in
  show)
    if [ -e "${CVNAS_MAX_FREQ}" ]; then
      echo "CVNAS MinFreq=$(cat ${CVNAS_MIN_FREQ})" \
        "MaxFreq=$(cat ${CVNAS_MAX_FREQ})" \
        "CurrentFreq=$(cat ${CVNAS_CUR_FREQ})"
    fi
    ;;
  *) ;;

  esac
}

main() {
  while [ -n "$1" ]; do
    case "$1" in
    --show)
      echo "SOC family:${SOCFAMILY}  Machine:${machine}"
      ACTION=show
      ;;
    --store)
      [ -n "$2" ] && CONF_FILE=$2
      ACTION=store
      shift 1
      ;;
    --restore)
      [ -n "$2" ] && CONF_FILE=$2
      ACTION=restore
      shift 1
      ;;
    --fan)
      FAN_SPEED_OVERRIDE=1
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage "Unknown option: $1"
      exit 1
      ;;
    esac
    shift 1
  done

  [ "$(whoami)" != "root" ] &&
    echo Error: Run this script\($0\) as a root user && exit 1

  case $ACTION in
  store)
    if [ -e "${CONF_FILE}" ]; then
      echo "File $CONF_FILE already exists. Can I overwrite it? Y/N:"
      read answer
      case $answer in
      y | Y)
        rm -f $CONF_FILE
        ;;
      *)
        echo "Error: file $CONF_FILE already exists!"
        exit 1
        ;;
      esac
    fi
    echo "Storing system configuration in ${CONF_FILE}"
    ;;
  restore)
    if [ ! -e "${CONF_FILE}" ]; then
      echo "Error: $CONF_FILE file not found !"
      exit 1
    fi
    echo "Restoring system configuration from ${CONF_FILE}"
    restore
    exit 0
    ;;
  esac

  do_hotplug
  do_cpu
  detect_gpu_type
  if [[ "${gpu_type}" == "iGPU" ]]; then
    do_igpu
  elif [[ "${gpu_type}" == "dGPU" ]]; then
    check_nvidia_smi
    do_dgpu
  else
    echo "Error: Unknown GPU Type!"
    exit 1
  fi
  do_emc
  do_dla
  do_pva
  do_cvnas
  do_fan
  do_nvpmodel
}

if [ -e "/proc/device-tree/compatible" ]; then
  if [ -e "/proc/device-tree/model" ]; then
    machine="$(tr -d '\0' </proc/device-tree/model)"
  fi
  CHIP="$(tr -d '\0' </proc/device-tree/compatible)"
  if [[ "${CHIP}" =~ "tegra186" ]]; then
    SOCFAMILY="tegra186"
  elif [[ "${CHIP}" =~ "tegra210" ]]; then
    SOCFAMILY="tegra210"
  elif [[ "${CHIP}" =~ "tegra194" ]]; then
    SOCFAMILY="tegra194"
  elif [[ "${CHIP}" =~ "tegra234" ]]; then
    SOCFAMILY="tegra234"
  fi
fi

main $@
exit 0
