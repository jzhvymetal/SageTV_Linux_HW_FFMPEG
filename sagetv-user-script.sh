#!/bin/bash
chmod 777 /opt/sagetv/comskip/*

chmod 777 /opt/sagetv/server/ffmpeg_init.sh
#Remove docker if ffmpeg is native installed as it will start docker and ffmpeg daemon
sudo bash /opt/sagetv/server/ffmpeg_init.sh docker