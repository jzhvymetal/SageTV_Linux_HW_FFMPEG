#!/usr/bin/env bash
#
# start_ffmpeg_daemon.sh
# Ensure the persistent ffmpeg_daemon container exists and is running.
set -e

# Make sure we have a sane PATH when run from my_init
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

###############################################################################
# Logging helpers (console only)
###############################################################################
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  echo "$(timestamp) $*"
}

###############################################################################
# Mode selection by command line only
#   start_ffmpeg_daemon.sh docker  -> use docker/containerd and ffmpeg_daemon
#   start_ffmpeg_daemon.sh         -> native ffmpeg, skip all docker work
#   start_ffmpeg_daemon.sh anything_else -> also native ffmpeg
###############################################################################
USE_DOCKER_FFMPEG="false"
if [[ "$1" == "docker" ]]; then
  USE_DOCKER_FFMPEG="true"
  shift
  log "[INFO] CLI: docker mode selected (USE_DOCKER_FFMPEG=true)"
else
  log "[INFO] CLI: native mode selected (no docker)"
fi

###############################################################################
# safe_symlink TARGET LINK_PATH
# - If LINK_PATH is a symlink, replace it.
# - If LINK_PATH is a regular file, move it to LINK_PATH.backupNN.
# - Then create LINK_PATH -> TARGET.
###############################################################################
safe_symlink() {
  local target="$1"
  local link_path="$2"

  if [[ -z "$target" || -z "$link_path" ]]; then
    echo "Usage: safe_symlink TARGET LINK_PATH" >&2
    return 1
  fi

  # Existing symlink -> just replace
  if [ -L "$link_path" ]; then
    log "[INFO] Existing symlink at $link_path, replacing it"
    ln -sfn "$target" "$link_path"
    return 0
  fi

  # Existing non-symlink -> rotate backups
  if [ -e "$link_path" ]; then
    log "[INFO] Existing non-symlink at $link_path, backing it up"

    local n=1
    local backup

    while :; do
      backup=$(printf "%s.backup%02d" "$link_path" "$n")
      if [ ! -e "$backup" ] && [ ! -L "$backup" ]; then
        mv "$link_path" "$backup"
        log "[INFO] Moved $link_path to $backup"
        break
      fi
      n=$((n+1))
    done
  fi

  log "[INFO] Creating symlink: $link_path -> $target"
  ln -sfn "$target" "$link_path"
}

###############################################################################
# Script start
###############################################################################
log "[INFO] Starting start_ffmpeg_daemon.sh"

# Ensure ffmpeg wrapper symlink
log "[INFO] Ensuring SageTV ffmpeg wrapper symlink exists"
/bin/chmod 755 /opt/sagetv/server/ffmpeg.sh 2>/dev/null || true
safe_symlink /opt/sagetv/server/ffmpeg.sh /opt/sagetv/server/ffmpeg
/bin/chmod 755 /opt/sagetv/server/ffmpeg 2>/dev/null || true

###############################################################################
# If not in docker mode, skip all containerd / docker / ffmpeg_daemon setup
###############################################################################
if [ "$USE_DOCKER_FFMPEG" != "true" ]; then
  log "[INFO] USE_DOCKER_FFMPEG=false, skipping containerd/docker/ffmpeg_daemon setup"
  log "[INFO] start_ffmpeg_daemon.sh completed (native ffmpeg mode)"
  exit 0
fi

###############################################################################
# Docker daemon: behave like your manual "dockerd &", but in a script
###############################################################################

# If Docker is already up, do not start another dockerd
if docker info >/dev/null 2>&1; then
  log "[INFO] Docker daemon already running"
else
  log "[INFO] Docker daemon not running, starting dockerd"

  # Kill stray dockerd and containerd from previous bad attempts
  pkill dockerd 2>/dev/null || true
  pkill containerd >/dev/null 2>&1 || true
  
  # Clean only Docker pid/socket, not containerd stuff
  for path in /var/run/docker.pid /var/run/docker.sock /run/docker.pid /run/docker.sock; do
    if [ -e "$path" ]; then
      log "[WARN] Removing stale Docker file $path"
      rm -f "$path" || true
    fi
  done
  
  sudo containerd &
  ready=false
  for i in $(seq 1 90); do
    if sudo ctr --connect-timeout 1s info >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done

  # Start dockerd exactly like you do manually
  sudo dockerd --host=unix:///var/run/docker.sock --storage-driver=overlay2 &
  dpid=$!
  log "[INFO] dockerd started with pid $dpid, waiting for it to become ready..."

  # Wait up to 90 seconds
  ready=false
  for i in $(seq 1 90); do
    if sudo docker info >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done

  if [ "$ready" = true ]; then
    log "[INFO] Docker daemon is ready"
  else
    log "[WARN] Docker did not report ready after 90s (dockerd may still be starting)"
  fi
fi

###############################################################################
# Ensure ffmpeg_daemon container exists and is running
###############################################################################
log "[INFO] Checking ffmpeg_daemon container state..."

if docker ps -a --format '{{.Names}}' | grep -q '^ffmpeg_daemon$'; then
  # Exists (running or exited)
  if docker ps --format '{{.Names}}' | grep -q '^ffmpeg_daemon$'; then
    log "[INFO] ffmpeg_daemon already running."
  else
    log "[INFO] ffmpeg_daemon exists but is stopped, starting it..."
    docker start ffmpeg_daemon >/dev/null
    log "[INFO] ffmpeg_daemon started."
  fi
else
  # Create the daemon container once
  log "[INFO] ffmpeg_daemon does not exist, creating it..."

  docker run -d \
    --name ffmpeg_daemon \
    --entrypoint /bin/bash \
    --device=/dev/dri:/dev/dri \
    -e LIBVA_MESSAGING_LEVEL=1 \
    -v /var/media:/var/media \
    linuxserver/ffmpeg \
    -c "while true; do sleep 3600; done" >/dev/null

  log "[INFO] ffmpeg_daemon created and started."
fi

log "[INFO] start_ffmpeg_daemon.sh completed successfully"
