#!/usr/bin/env python3
import socket
import apt
import argparse
import docker
import petname
import os
import requests
import subprocess
import sys
from tabulate import tabulate
import json

# Container versions:
# 1. Initial version
# 2. `--gpus all` on x86_64` vs `--runtime nvidia` on `aarch64`
EDGE_CONTAINER_VERSION = "2"
EDGE_WATCHTOWER_VERSION = "1"
EDGE_NAME_PREFIX = "edge-gateway-container"
DOCKER_CLIENT = docker.from_env()

WEBSITE_ENV = os.getenv("WEBSITE_ENV")
OUTPUT_FORMAT = os.getenv("OUTPUT_FORMAT")
NO_PROMPT = os.getenv("NO_PROMPT")
NO_PROVISION = os.getenv("NO_PROVISION")
EDGE_IMAGE = os.getenv("EDGE_IMAGE")
EDGE_APP_ID = os.getenv("EDGE_APP_ID")
EDGE_API_KEY = os.getenv("EDGE_API_KEY")
EDGE_ENVIRONMENT = os.getenv("EDGE_ENVIRONMENT")
EDGE_GATEWAY_NAME = os.getenv("EDGE_GATEWAY_NAME")


# get local ip
def get_local_ip():
    try:
        host_name = socket.gethostname()
        local_ip = socket.gethostbyname(host_name)
        return local_ip
    except socket.error:
        return None


# Helper scripts to output as table or JSON
def output_data(headers, rows, title):
    if OUTPUT_FORMAT == 'json':
        # Convert headers and rows into a list of dictionaries
        output = {'status': 'success', 'data': []}
        headers_fixed = [header.replace(" ", "_").lower() for header in headers]
        for row in rows:
            output['data'].append(dict(zip(headers_fixed, row)))
        print(json.dumps(output))
    else:
        print(title)
        print(tabulate(rows, headers=headers, tablefmt="fancy_grid"))


def output_message(message, status, title=''):
    if OUTPUT_FORMAT == 'json':
        output = {'status': status, 'message': message}
        print(json.dumps(output))
    else:
        print(title)
        print(message)


# Get the information of current OS platform
os_platform_info = os.uname().machine

if not EDGE_IMAGE:
    if os_platform_info == "aarch64":
        # TODO
        EDGE_IMAGE = "seeedcloud/edge-gateway:latest"
    else:
        sys.exit("Unsupported platform")


def print_containers_info(status):
    if status == "running":
        show_all = False
    else:
        show_all = True

    containers_list = list_edge_containers(show_all=show_all)

    containers_names = []

    if containers_list:
        container_full_info = []
        for (idx, container) in enumerate(containers_list):
            containers_names.append(container.name)
            container_full_info.append(
                [
                    idx + 1,
                    container.name,
                    container.status,
                    container.attrs["Config"]["Labels"]["edge.gateway_id"],
                    # container.attrs["Config"]["Labels"]["edge.application_id"],
                    # container.labels["edge.container_version"],
                    ",".join(container.image.tags)
                ]
            )

        headers = ["Index", "Name", "Status", "Gateway ID", "Application ID", "Version", "Image"]
        output_data(headers=headers, rows=container_full_info, title="\nList of containers installed:")
    else:
        output_message("No edge containers found", "info", title="\nList of containers installed:")
    return containers_names


def choose_container_with_prompt(status, action_description):
    containers_list = print_containers_info(status)
    if not containers_list:
        return None

    print("Insert the index or the name of the container to {}:".format(action_description))

    index_or_container_name = input().strip()

    try:
        index = int(index_or_container_name)
        if 1 <= index <= len(containers_list):
            return containers_list[index - 1]
        else:
            print("Invalid index")
            return None
    except ValueError:
        # If we couldn't parse input as a number, use the original string as a container name.
        container_name = index_or_container_name
        if container_name in containers_list:
            return container_name
        else:
            print("Container not found")
            return None


def usb_cameras():
    usb_cameras_list = []
    try:
        list_of_cameras = (
            subprocess.check_output("ls /dev/video* -R 2>/dev/null", shell=True)
            .decode("ascii")
            .split()
        )

        for usb_cam in list_of_cameras:
            usb_cameras_list.append("{}:{}:rwm".format(usb_cam, usb_cam))
    except:
        pass

    if len(usb_cameras_list) == 0:
        usb_cameras_list = None

    return usb_cameras_list


def runtime():
    if os_platform_info == "aarch64":
        if l4t_version() < "35.1":
            return None
        else:
            # "nvidia" runtime is required starting from JetPack 5.0.
            return "nvidia"
    elif os_platform_info == "x86_64":
        return None
    else:
        raise RuntimeError("Unsupported platform: {}".format(os_platform_info))


def device_requests():
    if os_platform_info == "aarch64":
        if l4t_version() < "35.1":
            # "--gpus all" was required before JetPack 5.0.
            return [docker.types.DeviceRequest(count=-1, capabilities=[["gpu"]])]
        else:
            return None
    else:
        raise RuntimeError("Unsupported platform: {}".format(os_platform_info))


def start_watchtower():
    watchtower_name = "edge-watchtower"
    if not DOCKER_CLIENT.containers.list(all=True, filters={"name": watchtower_name}):
        watchtower_labels = {
            "edge.container_version": EDGE_WATCHTOWER_VERSION,
            "edge.container_type": "containrrr/watchtower",
        }
        DOCKER_CLIENT.containers.run(
            "containrrr/watchtower:1.4.0",
            command=["--http-api-update", "--http-api-token", "edge-container-update-watchtower-token",
                     "--label-enable", "--include-stopped", "--cleanup", "--interval", "300"],
            volumes=["/var/run/docker.sock:/var/run/docker.sock"],
            restart_policy={"MaximumRetryCount": 0, "Name": "always"},
            name=watchtower_name,
            labels=watchtower_labels,
            ports={'8080/tcp': 46655},
            detach=True,
        )


def print_containers_list():
    print_containers_info("all")


def list_edge_containers(show_all=True, version=None):
    labels = []

    if version:
        labels.append("edge.container_version={}".format(version))

    containers_list = DOCKER_CLIENT.containers.list(
        all=show_all,
        filters={"label": labels},
    )

    # Filter the containers manually, because `filters` in docker client doesn't filter by just
    # presence of a label key, it needs a concrete value. But we want to get all edge containers
    # each of which can have a different label.
    return list(filter(is_edge_container, containers_list))


def is_edge_container(container):
    return "edge.gateway_id" in container.attrs["Config"]["Labels"]


def download():
    # The only thing we do for OEM installs is to pull the latest
    # version of edge image. The rest will be done when the user
    # links a container to their account. 
    os.system("sudo docker pull {}".format(EDGE_IMAGE))
    output_message("Latest container version downloaded.", "success")


def install():
    # Pull the latest version of edge image
    print("Start downloading and running the edge gateway program, which may take 5 to 30 minutes.")
    os.system("sudo docker pull {}".format(EDGE_IMAGE))

    auto_provision = EDGE_APP_ID and EDGE_API_KEY

    container_name = EDGE_GATEWAY_NAME or (EDGE_NAME_PREFIX)

    if not DOCKER_CLIENT.containers.list(all=True, filters={"name": container_name}):
        container_env = []
        if EDGE_ENVIRONMENT:
            container_env.append("--env EDGE_ENVIRONMENT=\'{}\'".format(EDGE_ENVIRONMENT))
        if not auto_provision:
            container_env.append("--env CONTAINER_MODEL=\'Container {}\'".format(EDGE_IMAGE))
        else:
            print(
                "Performing the provision of edge container '{}' using the provided EDGE_APP_ID & EDGE_API_KEY):".format(
                    container_name))
            container_env.append("--env CONTAINER_MODEL=\'Container {}\'".format(EDGE_IMAGE))
            container_env.append("--env EDGE_API_KEY=\'{}\'".format(EDGE_API_KEY))
            container_env.append("--env EDGE_APP_ID=\'{}\'".format(EDGE_APP_ID))

        # Got to perform this with system call as docker-py does not support interactive container execution
        if auto_provision:
            docker_cmd = "docker run -d  --privileged --restart=always --label com.centurylinklabs.watchtower.enable=true --net=host --ipc=bridge --ipc=host --pid=host --runtime nvidia --gpus all -e DISPLAY=:0  -e EDGEAI_WEB_DIST_PATH=/usr/bin/dist/ -e EDGEAI_PORT=46654 -e EDGEAI_MODELS_PATH=/var/lib/edge/models -e EDGEAI_SOURCES_PATH=/var/lib/edge/sources -e EDGEAI_CONFIGS_PATH=/var/lib/edge/configs -v {container}:/var/lib/edge -v /dev:/dev -v /tmp/.X11-unix/:/tmp/.X11-unix -v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket --name {container} {env_str} --hostname {container} {image}"
            # docker_cmd = "docker run -d -v {container}:/var/lib/edge --name {container} {env_str} --hostname {container} {image} "
        else:
            docker_cmd = "docker run -d  --privileged --restart=always --label com.centurylinklabs.watchtower.enable=true --net=host --ipc=bridge --ipc=host --pid=host --runtime nvidia --gpus all -e DISPLAY=:0 -e EDGEAI_WEB_DIST_PATH=/usr/bin/dist/ -e EDGEAI_PORT=46654 -e EDGEAI_MODELS_PATH=/var/lib/edge/models -e EDGEAI_SOURCES_PATH=/var/lib/edge/sources -e EDGEAI_CONFIGS_PATH=/var/lib/edge/configs -v {container}:/var/lib/edge -v /dev:/dev -v /tmp/.X11-unix/:/tmp/.X11-unix -v /var/run/dbus/system_bus_socket:/var/run/dbus/system_bus_socket --name {container} {env_str} --hostname {container} {image}"
        if (
                os.system(
                    docker_cmd.format(
                        container=container_name, env_str=" ".join(container_env), image=EDGE_IMAGE
                    )
                )
                == 0
        ):
            output_message("Container started! ", "success")
            if WEBSITE_ENV == "true":
                ip_address = get_local_ip()
                print("Sensecarf AI Website========>:", "http://" + ip_address + ":46654")
    else:
        output_message("Error: A container with name '{}' already exists".format(container_name), "error")


def stop(container_name=None):
    container_name = container_name or choose_container_with_prompt("running", "stop")
    if container_name:
        DOCKER_CLIENT.api.kill(container_name)
        output_message("Container stopped!", "success")


def restart(container_name=None):
    if os_platform_info == "aarch64" and l4t_version() < "35.1":
        output_message(
            "Couldn't restart the container because JetPack is outdated. Please, update JetPack or contact Edge support.",
            "error")
        return

    if container_name is None:
        # If no explicit `container_name` is given, prompt the user.
        container_name = choose_container_with_prompt("all", "restart")
        if container_name is None:
            return

    # Pull the latest version of Edge image
    os.system("sudo docker pull {}".format(EDGE_IMAGE))

    current_container = DOCKER_CLIENT.containers.get(container_name)
    if not current_container:
        output_message("Container not found", "error")
        return

    network_mode = current_container.attrs["HostConfig"]["NetworkMode"]
    port_mapping = current_container.attrs["HostConfig"]["PortBindings"]
    container_labels = current_container.attrs["Config"]["Labels"]

    container_labels["edge.container_version"] = EDGE_CONTAINER_VERSION
    container_labels["edge.container_type"] = EDGE_IMAGE

    DOCKER_CLIENT.api.remove_container(container_name, force=True)
    if not DOCKER_CLIENT.containers.run(
            EDGE_IMAGE,
            volumes=[container_name + ":/var/lib/edge"],
            restart_policy={"MaximumRetryCount": 0, "Name": "always"},
            name=container_name,
            hostname=container_name,
            network_mode=network_mode,
            ports=port_mapping,
            device_requests=device_requests(),
            runtime=runtime(),
            labels=container_labels,
            detach=True,
    ):
        output_message("Failed to restart container", "error")
        return

    output_message("Container {} restarted!".format(container_name), "success")


def l4t_version():
    cache = apt.Cache()
    pkg = cache['nvidia-l4t-core']
    return pkg.versions[0].version


def dgpu_driver_version():
    version_string = subprocess.check_output('nvidia-smi --query-gpu=driver_version --format=csv,'
                                             'noheader', shell=True).decode("ascii").strip()
    return int(version_string.split('.')[0])


def restart_v1_containers():
    # Restart would change container version from v1 to v2.
    # Restart affects
    # - `x86` v1 containers with up-to-date NVIDIA driver
    # - Jetson v1 containers with up-to-date Jetpack
    if os_platform_info == "aarch64" and l4t_version() < "35.1":
        output_message("Skipping v1 containers restart because JetPack is outdated", "error")
        return False

    try:
        if os_platform_info == "x86_64" and dgpu_driver_version() < 515:
            output_message("Skipping v1 containers restart because NVIDIA dGPU driver is outdated", "error")
            return False
    except:
        output_message(
            "[edge-container-update] Can't check dGPU driver version. Please make sure GPU drivers and nvidia-smi are installed",
            "error")
        return False

    v1_containers = list_edge_containers(version=1)

    for container in v1_containers:
        restart(container.name)

    return True


def remove(container_name=None):
    container_name = container_name or choose_container_with_prompt("all", "remove")
    if container_name:
        DOCKER_CLIENT.api.remove_container(container_name, force=True)
        DOCKER_CLIENT.api.remove_volume(container_name, force=True)
        output_message("Container removed!", "success")


def deprovision_containers():
    containers_list = list_edge_containers()

    for container in containers_list:
        try:
            if container.name != "edge-watchtower":
                # Read provision info from volume
                volume = DOCKER_CLIENT.volumes.get(container.name)
                mountpoint = volume.attrs.get("Mountpoint")
        except Exception as err:
            output_message("[edge-container-update] Exception: {}".format(err), "error")


def update_containers():
    print("[edge-container-update] Checking for updates in Edge containers images")
    # Ask watchtower to check for container image updates
    token = "edge-container-update-watchtower-token"
    final_url = "http://localhost:46655/v1/update"
    headers_api = {
        "Authorization": "Bearer " + token
    }
    try:
        requests.get(url=final_url, headers=headers_api)
    except Exception as err:
        output_message("[edge-container-update] Exception: {}".format(err), "error")


def update():
    deprovision_containers()
    if restart_v1_containers():
        update_containers()


def logs(container_name=None):
    container_name = container_name or choose_container_with_prompt("all", "print logs")
    if container_name:
        print(DOCKER_CLIENT.api.logs(container_name).decode("ascii"))


def shell(container_name=None):
    container_name = container_name or choose_container_with_prompt("running", "access with interactive shell")
    if container_name:
        os.system("docker exec -it {} bash".format(container_name))


def print_usage():
    print("\n▄▀▄▀▄▀▄▀   Edge Container Manager   ▀▄▀▄▀▄▀▄\n")
    print("Commands:\n")
    print("  list         List the currently installed containers")
    print("  install      Install a new container")
    print("  download     Download the latest container image (OEM use only)")
    print("  stop         Kills a running container")
    print("  restart      Restart a container & update to the latest version")
    print("  remove       Remove a container")
    print("  logs         Print the logs of a container")
    print("  shell        Open an interactive shell in a running container")
    print("  exit         Quits this script")


FUNCTION_MAP = {
    "loop_menu": print_usage,
    "start_watchtower": start_watchtower,
    "list": print_containers_list,
    "install": install,
    "download": download,
    "stop": stop,
    "restart": restart,
    "remove": remove,
    "update": update,
    "logs": logs,
    "shell": shell,
}

parser = argparse.ArgumentParser()
parser.add_argument("command", choices=FUNCTION_MAP.keys(), nargs="?", default="loop_menu")
parser.add_argument("--container-name")
parser.add_argument("output", choices=['json', 'table'], nargs="?", default="table")

args = parser.parse_args()

if args.command == "loop_menu":
    OUTPUT_FORMAT = args.output
    containers_list = list_edge_containers()

    if not containers_list:
        if NO_PROVISION:
            # pull the latest version of edge image, but not attempt to install it
            os.system("sudo docker pull {}".format(EDGE_IMAGE))
        else:
            # start a new container installation if no containers are found
            FUNCTION_MAP["install"]()
            sys.exit(0)

    # if Edge containers are found, we list them
    FUNCTION_MAP["list"]()

    # show up the menu with options
    print_usage()

    while True:
        try:
            print("\nEnter the command: ")
            user_option = input().strip().lower()

            if user_option in FUNCTION_MAP:
                FUNCTION_MAP[user_option]()
            elif user_option == "exit":
                sys.exit(0)
            else:
                print("Error: Command is not recognized! Please select a valid command\n")
                print_usage()
        except KeyboardInterrupt:
            sys.exit(0)
else:
    OUTPUT_FORMAT = "json"
    # Perform a single operation and exit
    if args.container_name and args.command in ["stop", "restart", "remove", "logs", "shell"]:
        FUNCTION_MAP[args.command](args.container_name)
    else:
        FUNCTION_MAP[args.command]()
