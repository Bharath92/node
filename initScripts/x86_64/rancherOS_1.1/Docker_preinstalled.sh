#!/bin/bash
set -e
set -o pipefail

# initScript for rancherOS. Docker is preinstalled. So, we don't install docker
# in this script.
# ------------------------------------------------------------------------------

readonly DOCKER_VERSION="docker version --format '{{.Server.Version}}'"
readonly NODE_VERSION="4.8.7"
readonly SWAP_FILE_PATH="/root/.__sh_swap__"

check_init_input() {
  local expected_envs=(
    'NODE_SHIPCTL_LOCATION'
    'NODE_ARCHITECTURE'
    'NODE_OPERATING_SYSTEM'
    'LEGACY_CI_CEXEC_LOCATION_ON_HOST'
    'SHIPPABLE_RELEASE_VERSION'
    'EXEC_IMAGE'
    'REQKICK_DIR'
    'IS_SWAP_ENABLED'
  )

  check_envs "${expected_envs[@]}"
}

create_shippable_dir() {
  create_dir_cmd="mkdir -p /home/shippable"
  exec_cmd "$create_dir_cmd"
}

check_swap() {
  echo "Checking for swap space"

  swap_available=$(free | grep Swap | awk '{print $2}')
  if [ $swap_available -eq 0 ]; then
    echo "No swap space available, adding swap"
    is_swap_required=true
  else
    echo "Swap space available, not adding"
  fi
}

add_swap() {
  echo "Adding swap file"
  echo "Creating Swap file at: $SWAP_FILE_PATH"
  add_swap_file="touch $SWAP_FILE_PATH"
  exec_cmd "$add_swap_file"

  swap_size=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
  swap_size=$(($swap_size/1024))
  echo "Allocating swap of: $swap_size MB"
  initialize_file="dd if=/dev/zero of=$SWAP_FILE_PATH bs=1M count=$swap_size"
  exec_cmd "$initialize_file"

  echo "Updating Swap file permissions"
  update_permissions="chmod -c 600 $SWAP_FILE_PATH"
  exec_cmd "$update_permissions"

  echo "Setting up Swap area on the device"
  initialize_swap="mkswap $SWAP_FILE_PATH"
  exec_cmd "$initialize_swap"

  echo "Turning on Swap"
  turn_swap_on="swapon $SWAP_FILE_PATH"
  exec_cmd "$turn_swap_on"

}

check_fstab_entry() {
  echo "Checking fstab entries"

  if grep -q $SWAP_FILE_PATH /etc/fstab; then
    exec_cmd "echo /etc/fstab updated, swap check complete"
  else
    echo "No entry in /etc/fstab, updating ..."
    add_swap_to_fstab="echo $SWAP_FILE_PATH none swap sw 0 0 | tee -a /etc/fstab"
    exec_cmd "$add_swap_to_fstab"
    exec_cmd "echo /etc/fstab updated"
  fi
}

initialize_swap() {
  check_swap
  if [ "$is_swap_required" == true ]; then
    add_swap
  fi
  check_fstab_entry
}

pull_cexec() {
  __process_marker "Pulling cexec"
  if [ -d "$LEGACY_CI_CEXEC_LOCATION_ON_HOST" ]; then
    exec_cmd "rm -rf $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  fi
  exec_cmd "git clone https://github.com/Shippable/cexec.git $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  __process_msg "Checking out tag: $SHIPPABLE_RELEASE_VERSION in $LEGACY_CI_CEXEC_LOCATION_ON_HOST"
  pushd $LEGACY_CI_CEXEC_LOCATION_ON_HOST
  exec_cmd "git checkout $SHIPPABLE_RELEASE_VERSION"
  popd
}

pull_reqProc() {
  __process_marker "Pulling reqProc..."
  docker pull $EXEC_IMAGE
}

prep_reqKick() {
  __process_marker "Prepping reqKick service..."
  pushd /tmp
  wget https://github.com/Shippable/reqKick/archive/reqKick-$SHIPPABLE_RELEASE_VERSION.zip
  unzip -o LE_RELEASE_VERSION.zip -d /home/shippable/reqKick
  reqkick_service_dir="$REQKICK_DIR/init/$NODE_ARCHITECTURE/$NODE_OPERATING_SYSTEM"
  local tmpReqkickDockerfile=Dockerfile-$SHIPPABLE_RELEASE_VERSION
  cp $reqkick_service_dir/Dockerfile-shippable-reqkick.template $tmpReqkickDockerfile
  sed -i "s#{{NODE_VERSION}}#$NODE_VERSION#g" $tmpReqkickDockerfile
  sed -i "s#{{SHIPPABLE_NODE_VERSION}}#$SHIPPABLE_NODE_VERSION#g" $tmpReqkickDockerfile
  docker build -t=shippable-reqKick:$SHIPPABLE_RELEASE_VERSION -f Dockerfile-$SHIPPABLE_RELEASE_VERSION
  sudo rm -rf *
  popd
}

before_exit() {
  echo $1
  echo $2

  echo "Node init script completed"
}

main() {
  check_init_input

  trap before_exit EXIT
  exec_grp "create_shippable_dir"

  if [ "$IS_SWAP_ENABLED" == "true" ]; then
    trap before_exit EXIT
    exec_grp "initialize_swap"
  fi

  trap before_exit EXIT
  exec_grp "pull_cexec"

  trap before_exit EXIT
  exec_grp "pull_reqProc"

  trap before_exit EXIT
  exec_grp "prep_reqKick"
}

main
