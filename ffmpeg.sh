#!/bin/bash
########################################################################
#  
# ffmpeg.sh Overview
#   Wrapper around /opt/sagetv/server/ffmpeg.run to:
#     * Selectively use hardware decode/encode (QSV etc) via Docker.
#     * Preserve SageTV stdinctrl behavior when ffmpeg runs in a container.
#     * Provide a copy only mode for special formats (for example DVD).
#
# Modes
#   1) Passthrough
#      * If HW_TRIGGER_VCODEC is empty or does not match the Sage -vcodec,
#        execs:
#          /opt/sagetv/server/ffmpeg.run -fflags +genpts "$@"
#
#   2) Copy only
#      * If HW_TRIGGER_VCODEC matches and -f equals COPY_ONLY_F_TRIGGER:
#        - Uses ffmpeg.run with:
#            -activefile when present
#            -c:v copy -c:a copy
#            -f OUTPUT_FORMAT (default mpegts)
#        - Sage stdinctrl is used directly on ffmpeg.run.
#
#   3) Hardware transcode
#      * If HW_TRIGGER_VCODEC matches and -f != COPY_ONLY_F_TRIGGER:
#        - Runs ffmpeg inside Docker via FFMPEG_TRANSCODE_BIN
#          (default: sudo docker exec ffmpeg_daemon ffmpeg).
#        - Applies HW_INIT_ARGS for hwaccel setup.
#        - Optional deinterlace/scale via:
#            DEINT_FILTER
#            DEINT_SCALE_FILTER_TEMPLATE (with %w% and %h% from Sage -s).
#        - Encodes with VIDEO_CODEC and preset:
#            VIDEO_CODEC
#            VIDEO_PRESET_OPT / VIDEO_PRESET_VALUE
#            VIDEO_EXTRA_ARGS
#        - Uses Sage -b as target and derives:
#            -maxrate  = V_MAXRATE_MULTI * -b
#            -bufsize  = V_BUFSIZE_MULTI * -b
#        - GOP is clamped to 60 if larger for lower latency.
#        - Audio:
#            AUDIO_REENCODE="no" -> c:a copy
#            AUDIO_REENCODE="yes" -> AC3 with Sage bitrates/channels.
#        - Stream mapping:
#            AUDIO_TRACK_MODE="all"     -> map 0:v and all 0:a?
#            AUDIO_TRACK_MODE="default" -> no -map (ffmpeg defaults).
#        - Output format:
#            -f OUTPUT_FORMAT, writes to stdout.
#
# Stdinctrl emulation
#   * Sage sends STOP/QUIT over stdin to control ffmpeg.
#   * Hardware path:
#       - Wrapper starts container ffmpeg in background.
#       - stdin_watcher reads stdin and logs commands.
#       - On STOP/QUIT:
#           - Calls stop_ffmpeg, which uses pkill inside Docker on a
#             unique session_tag metadata, then falls back to filename.
#           - Sends TERM to the local ffmpeg_pid.
#
# Logging
#   * Controlled by ENABLE_LOGGING.
#   * All key steps logged to LOGFILE with prefixes:
#       [SAGETV/ORIG], [SAGETV/COPY], [FFMPEG CMD], [STDINCTRL RAW],
#       [STDINCTRL HEX], [INFO].
#   * DEBUG_STDINCTRL_HEX can hex dump stdin control lines.
########################################################################



########################################################################
# Hardware encoder / decoder configuration
########################################################################

# Where to run ffmpeg for the transcode path
# For docker:
#FFMPEG_TRANSCODE_BIN=(sudo docker exec ffmpeg_daemon ffmpeg)
#
# For local ffmpeg you could do:
# FFMPEG_TRANSCODE_BIN=(/opt/sagetv/ffmpeg)
# For docker:
FFMPEG_TRANSCODE_BIN=(sudo docker exec ffmpeg_daemon ffmpeg)

# Hardware init / acceleration options (decoder side)
# QSV example:
HW_INIT_ARGS=(
  -init_hw_device qsv=hw:/dev/dri/renderD128
  -hwaccel qsv
  -hwaccel_device hw
  -hwaccel_output_format qsv
)

# Deinterlace / scale filter templates
# Use %w% and %h% as placeholders that will be replaced with actual width/height.

# For NVENC you might set:
# DEINT_FILTER="yadif"
# DEINT_SCALE_FILTER_TEMPLATE="yadif,scale=w=%w%:h=%h%"

# For QSV:
DEINT_FILTER="deinterlace_qsv"  # leave empty "" to disable
DEINT_SCALE_FILTER_TEMPLATE="deinterlace_qsv,scale_qsv=w=%w%:h=%h%"

# Video encoder and tuning
# Examples:
#   QSV: hevc_qsv, h264_qsv
#   NVENC: hevc_nvenc, h264_nvenc
#   SW: libx264, libx265
VIDEO_CODEC="hevc_qsv"
VIDEO_PRESET_OPT="-preset"       # set to "" to omit preset
VIDEO_PRESET_VALUE="fast"        # for NVENC: p1..p7, for x264: fast, medium, slow
VIDEO_EXTRA_ARGS=()              # extra encoder specific args, for example ( -look_ahead 1 )

# Bitrate multipliers for maxrate and bufsize
V_MAXRATE_MULTI="1.5"            # example 1.5 for 1.5x peak
V_BUFSIZE_MULTI="3.0"            # example 3.0 for 3x buffer

# GOP clamping
#   If GOP_CLAMP_MAX is numeric, any Sage gop larger than this
#   will be clamped down to GOP_CLAMP_MAX.
#   Set empty to disable clamping.
GOP_CLAMP_MAX="60"

# Final output container format for both copy and transcode paths
OUTPUT_FORMAT="mpegts"           # examples: mpegts, matroska, mp4

# Transcode / hardware trigger based on -vcodec value
#   "mpeg4" -> only transcode when Sage passes "-vcodec mpeg4"
#   ""      -> never transcode; always run original SageTV ffmpeg.run (no HW)
HW_TRIGGER_VCODEC="mpeg4"

########################################################################
# User options (common to all hardware modes)
########################################################################

# Should audio be re-encoded to AC3, or copied from source?
#   "yes" -> reencode AC3, using SageTV-provided bitrate / channels
#   "no"  -> copy audio as-is (no decode / reencode)
AUDIO_REENCODE="no"

# Which audio tracks to include (for transcode path):
#   "default" -> no explicit -map, ffmpeg picks default audio
#   "all"     -> map 0:v and all 0:a?
AUDIO_TRACK_MODE="all"

# Demux probing knobs (startup latency vs robustness)
DEMUX_PROBESIZE="300000"
DEMUX_ANALYZEDURATION="300000"

# Copy-only trigger:
#   If non-empty and SageTV sends exactly this as the -f value
#   (for example "-f dvd"), we:
#     - Skip hardware transcode
#     - Use ffmpeg.run with -c:v copy -c:a copy
COPY_ONLY_F_TRIGGER="dvd"

########################################################################
# Logging configuration
########################################################################

# Set to "true" to enable logging to LOGFILE, "false" to disable all file logging
ENABLE_LOGGING="true"

# Control for hex dump of stdin control messages
DEBUG_STDINCTRL_HEX=true  # set to false to disable

#Location of logfile
LOGFILE="/opt/sagetv/server/ffmpeg-commands.log"


########################################################################
# SCRIPT START
########################################################################
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

log() {
  if [ "$ENABLE_LOGGING" != "true" ]; then
    return
  fi
  printf '%s %s\n' "$(timestamp)" "$*" >>"$LOGFILE"
}

###################################################################
# Derive VBR-ish params from SageTV's -b value (for example "4M")
###################################################################
scale_bitrate() {
  local val="$1"
  local factor="$2"
  local num suf

  if [[ "$val" =~ ^([0-9]+)([kKmM]?)$ ]]; then
    num="${BASH_REMATCH[1]}"
    suf="${BASH_REMATCH[2]}"
    local newnum
    newnum=$(awk -v n="$num" -v f="$factor" 'BEGIN { printf "%.0f", n*f }')
    echo "${newnum}${suf}"
  else
    echo "$val"
  fi
}

# Log original command
log "[SAGETV/ORIG  ]: /opt/sagetv/server/ffmpeg $*"

args=("$@")

convert=false         # becomes true if HW_TRIGGER_VCODEC matched
live_activefile=false

# Defaults for parameters we care about
input_file=""
start_time=""
format=""
bitrate="4M"
framerate="30000/1001"
size="1920x1080"
gop="300"
bf="0"
abitrate="128k"
arate="48000"
achannels="2"
size_set=false
packet_size=""
aspect=""

###################################################################
# Single pass: detect vcodec trigger, activefile, and grab params
###################################################################
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[i]}" in
    -vcodec)
      if (( i + 1 < ${#args[@]} )); then
        vcodec_arg="${args[i+1]}"
        # Hardware / transcode trigger:
        # Only set convert=true if HW_TRIGGER_VCODEC is non-empty
        # AND matches the -vcodec value from SageTV.
        if [[ -n "$HW_TRIGGER_VCODEC" && "$vcodec_arg" == "$HW_TRIGGER_VCODEC" ]]; then
          convert=true
        fi
      fi
      ;;
    -activefile)
      live_activefile=true
      ;;
    -i)
      (( i + 1 < ${#args[@]} )) && input_file="${args[i+1]}"
      ;;
    -ss)
      (( i + 1 < ${#args[@]} )) && start_time="${args[i+1]}"
      ;;
    -b)
      (( i + 1 < ${#args[@]} )) && bitrate="${args[i+1]}"
      ;;
    -r)
      (( i + 1 < ${#args[@]} )) && framerate="${args[i+1]}"
      ;;
    -s)
      if (( i + 1 < ${#args[@]} )); then
        size="${args[i+1]}"
        size_set=true
      fi
      ;;
    -g)
      (( i + 1 < ${#args[@]} )) && gop="${args[i+1]}"
      ;;
    -bf)
      (( i + 1 < ${#args[@]} )) && bf="${args[i+1]}"
      ;;
    -ab)
      (( i + 1 < ${#args[@]} )) && abitrate="${args[i+1]}"
      ;;
    -ar)
      (( i + 1 < ${#args[@]} )) && arate="${args[i+1]}"
      ;;
    -ac)
      (( i + 1 < ${#args[@]} )) && achannels="${args[i+1]}"
      ;;
    -f)
      (( i + 1 < ${#args[@]} )) && format="${args[i+1]}"
      ;;
    -packetsize)
      (( i + 1 < ${#args[@]} )) && packet_size="${args[i+1]}"
      ;;
    -aspect)
      (( i + 1 < ${#args[@]} )) && aspect="${args[i+1]}"
      ;;
  esac
done

###################################################################
# Case 1: no HW-triggered vcodec -> run original SageTV ffmpeg.run
###################################################################
if ! "$convert"; then
  exec /opt/sagetv/server/ffmpeg.run -fflags +genpts "${args[@]}"
fi

###################################################################
# convert == true here
# Decide if this is copy-only based on -f
###################################################################
copy_only=false
if [[ -n "$COPY_ONLY_F_TRIGGER" && "$format" == "$COPY_ONLY_F_TRIGGER" ]]; then
  copy_only=true
fi

###################################################################
# Case 2: copy-only -> simple copy via ffmpeg.run, no session mgmt
###################################################################
if "$copy_only"; then
  # Optional argument chunks as arrays
  arg_ss=()
  arg_activefile=()

  # Honor SageTV -ss
  if [[ -n "$start_time" ]]; then
    arg_ss=(-ss "$start_time")
  fi

  # Live TV: follow growing file
  if "$live_activefile"; then
    arg_activefile=(-activefile)
  fi

  # Build final ffmpeg.run command
  copy_cmd=(
    /opt/sagetv/server/ffmpeg.run
    -v 3
    -y
    -threads 2
    -sn
    -fflags +genpts+nobuffer+flush_packets
    -probesize "$DEMUX_PROBESIZE"
    -analyzeduration "$DEMUX_ANALYZEDURATION"
    -max_delay 0
    "${arg_ss[@]}"
    "${arg_activefile[@]}"
    -stdinctrl
    -i "$input_file"
    -threads 5
    -f "$OUTPUT_FORMAT"
    -map 0:v
    -map 0:a?
    -c:v copy
    -c:a copy
  )

  if [[ -n "$packet_size" ]]; then
    copy_cmd+=(-packetsize "$packet_size")
  fi
  if [[ -n "$aspect" ]]; then
    copy_cmd+=(-aspect "$aspect")
  fi

  copy_cmd+=(
    -muxpreload 0
    -muxdelay 0
    -
  )

  log "[SAGETV/COPY  ]: ${copy_cmd[*]}"

  # Sage manages STOP via -stdinctrl; we just exec and exit
  exec "${copy_cmd[@]}"
fi

###################################################################
# Case 3: HARDWARE TRANSCODE PATH (HW-trigger vcodec, not copy-only)
###################################################################

SESSION_ID="sage$$_$RANDOM"

# Clamp GOP for quicker startup / lower latency (configurable)
if [[ -n "$GOP_CLAMP_MAX" ]]; then
  if [[ "$GOP_CLAMP_MAX" =~ ^[0-9]+$ && "$gop" =~ ^[0-9]+$ ]]; then
    if (( gop > GOP_CLAMP_MAX )); then
      log "[INFO         ] gop $gop too large for low latency playback, clamping to $GOP_CLAMP_MAX"
      gop="$GOP_CLAMP_MAX"
    fi
  else
    log "[INFO         ] GOP_CLAMP_MAX='$GOP_CLAMP_MAX' or gop='$gop' not numeric, skipping clamp"
  fi
fi

[[ -z "$input_file" ]] && input_file="/var/media/unknown.ts"

w="${size%x*}"
h="${size#*x}"

# Build video filter chain based on configuration
video_filters=()
if $size_set; then
  if [[ -n "$DEINT_SCALE_FILTER_TEMPLATE" ]]; then
    vf_expanded=${DEINT_SCALE_FILTER_TEMPLATE//%w%/$w}
    vf_expanded=${vf_expanded//%h%/$h}
    video_filters=(-vf "$vf_expanded")
  fi
else
  if [[ -n "$DEINT_FILTER" ]]; then
    video_filters=(-vf "$DEINT_FILTER")
  fi
fi

# Detect if FFMPEG_TRANSCODE_BIN is docker-based for stop_ffmpeg
using_docker=false
if [[ "${FFMPEG_TRANSCODE_BIN[*]}" == sudo\ docker\ exec* ]]; then
  using_docker=true
fi

run_cmd=(
  "${FFMPEG_TRANSCODE_BIN[@]}"
  "${HW_INIT_ARGS[@]}"
  -y
  -fflags +genpts+nobuffer+flush_packets
  -sn
  -probesize "$DEMUX_PROBESIZE"
  -analyzeduration "$DEMUX_ANALYZEDURATION"
  -max_delay 0
)

# Live TV: follow growing file
if "$live_activefile"; then
  run_cmd+=(-follow 1)
  log "[INFO         ] LIVE activefile detected for input $input_file, adding -follow 1 (HW path)"
fi

# Honor SageTV -ss
if [[ -n "$start_time" ]]; then
  run_cmd+=(-ss "$start_time")
  log "[INFO         ] applying seek -ss $start_time (HW path, live_activefile=$live_activefile)"
fi

# Input file
run_cmd+=(
  -i "$input_file"
)

# Deinterlace / scale filter chain
run_cmd+=("${video_filters[@]}")

# Video bitrate: original -b as target, derive maxrate / bufsize
v_bitrate="$bitrate"
v_maxrate="$(scale_bitrate "$bitrate" "$V_MAXRATE_MULTI")"
v_bufsize="$(scale_bitrate "$bitrate" "$V_BUFSIZE_MULTI")"

# Video encoder configuration
run_cmd+=(
  -c:v "$VIDEO_CODEC"
)

if [[ -n "$VIDEO_PRESET_OPT" && -n "$VIDEO_PRESET_VALUE" ]]; then
  run_cmd+=("$VIDEO_PRESET_OPT" "$VIDEO_PRESET_VALUE")
fi

run_cmd+=(
  -b:v "$v_bitrate"
  -maxrate "$v_maxrate"
  -bufsize "$v_bufsize"
  -r "$framerate"
  -g "$gop"
  -bf "$bf"
  "${VIDEO_EXTRA_ARGS[@]}"
)

# Audio handling in HW path
if [[ "$AUDIO_REENCODE" == "yes" ]]; then
  run_cmd+=(
    -c:a ac3
    -b:a "$abitrate"
    -ar "$arate"
    -ac "$achannels"
  )
else
  run_cmd+=(
    -c:a copy
  )
fi

# Stream mapping based on AUDIO_TRACK_MODE
map_args=()
case "$AUDIO_TRACK_MODE" in
  default|DEFAULT|"")
    log "[INFO         ] AUDIO_TRACK_MODE=default -> using ffmpeg default stream selection (no -map)"
    ;;
  all|ALL)
    map_args+=("-map" "0:v")
    map_args+=("-map" "0:a?")
    log "[INFO         ] AUDIO_TRACK_MODE=all -> mapping 0:v and all 0:a?"
    ;;
esac
run_cmd+=("${map_args[@]}")

# Optional container knobs from original Sage args
if [[ -n "$packet_size" ]]; then
  run_cmd+=(-packetsize "$packet_size")
fi
if [[ -n "$aspect" ]]; then
  run_cmd+=(-aspect "$aspect")
fi

# Final mux and output
run_cmd+=(
  -metadata "session_tag=${SESSION_ID}"
  -muxpreload 0
  -muxdelay 0
  -f "$OUTPUT_FORMAT"
  -
)

log "[FFMPEG CMD (${VIDEO_CODEC})]: ${run_cmd[*]} (live_activefile=$live_activefile, session_tag=${SESSION_ID})"

###################################################################
# HW transcode: stop_ffmpeg + stdinctrl emulation
###################################################################
stop_ffmpeg() {
  log "[INFO         ] stop_ffmpeg called for input=$input_file session_tag=${SESSION_ID} using_docker=$using_docker"

  if [ "$using_docker" = true ]; then
    sudo docker exec ffmpeg_daemon \
      pkill -TERM -f "session_tag=${SESSION_ID}" >/dev/null 2>&1
    rc1=$?
    log "[INFO         ] pkill by session_tag rc=$rc1"

    if [[ $rc1 -ne 0 && -n "$input_file" ]]; then
      sudo docker exec ffmpeg_daemon \
        pkill -TERM -f "$input_file" >/dev/null 2>&1
      rc2=$?
      log "[INFO         ] pkill by input_file rc=$rc2"

      if [[ $rc2 -ne 0 ]]; then
        sudo docker exec ffmpeg_daemon \
          pkill -KILL -f "$input_file" >/dev/null 2>&1 || true
        log "[INFO         ] pkill -KILL by input_file issued"
      fi
    fi
  fi
}

ffmpeg_pid=""
stdin_watcher_pid=""

forward_sig() {
  stop_ffmpeg
  if [[ -n "$ffmpeg_pid" ]]; then
    kill -TERM "$ffmpeg_pid" 2>/dev/null || true
  fi
}
trap forward_sig INT TERM


if [ "$ENABLE_LOGGING" == "true" ]; then
  (
    "${run_cmd[@]}" 2> >(
      while IFS= read -r line; do
        printf '%s [DOCKER/FFMPEG] %s\n' "$(timestamp)" "$line" >>"$LOGFILE"
        printf '%s\n' "$line" >&2
      done
    ) < /dev/null
  ) &
else
  # No file logging; just run ffmpeg and let stderr pass through normally
  (
    "${run_cmd[@]}"
  ) &
fi

ffmpeg_pid=$!

stdin_watcher() {
  while IFS= read -r line; do
    log "[STDINCTRL RAW] $line"

    if [ "$DEBUG_STDINCTRL_HEX" = true ] && [ "$ENABLE_LOGGING" == "true" ]; then
      printf '%s\n' "$line" | od -An -tx1 | sed 's/^/'"$(timestamp) [STDINCTRL HEX] "'/' >> "$LOGFILE"
    fi

    case "$line" in
      STOP*|Stop*|stop*|QUIT*|Quit*|quit*|Q|q)
        log "[STDINCTRL HANDLED] stop command detected, calling stop_ffmpeg"
        stop_ffmpeg
        kill -TERM "$ffmpeg_pid" 2>/dev/null || true
        ;;
      *)
        log "[STDINCTRL UNHANDLED] command='$line'"
        ;;
    esac
  done

  log "[INFO         ] STDINCTRL EOF detected (no automatic stop)"
}

stdin_watcher &
stdin_watcher_pid=$!

wait "$ffmpeg_pid"
status=$?

log "[INFO         ] ffmpeg (session_tag=${SESSION_ID}) exited with status $status"

stop_ffmpeg
kill "$stdin_watcher_pid" 2>/dev/null || true

exit "$status"
