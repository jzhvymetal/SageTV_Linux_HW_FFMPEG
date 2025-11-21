Man-in-the-middle script that intercepts the FFmpeg command SageTV sends and decides per request whether to use plain SageTV FFmpeg, a copy-only path, or a hardware transcode with an external FFmpeg. The behavior is controlled by a set of options (hardware trigger, copy trigger, external FFmpeg location, hardware init, encoder choice, and so on), and all of these settings are documented directly in the script so you can retarget it to Intel QSV, NVENC, VAAPI, or a native FFmpeg binary without changing the core logic.

When the Android client requests hardware accelerated transcoding, the script routes that job through an external FFmpeg. By default this runs inside a persistent `ffmpeg_daemon` Docker container that has the GPU device passed in from the host, which avoids starting a new container for each stream and removes the old Docker inside Docker requirement. For live TV, the script detects SageTV’s `-activefile` flag and enables following of the growing recording file, and it emulates SageTV’s `stdinctrl` behavior by tagging each hardware session and stopping the correct FFmpeg process when STOP or QUIT is sent on stdin.

If the request is copy only, the script instead builds a pipeline using SageTV’s own `ffmpeg.run` with stream copy settings and keeps `-stdinctrl` in place so startup is fast and compatibility with SageTV’s existing logic is preserved. Any other transcoding request that does not match the hardware trigger is simply passed through to `ffmpeg.run` unchanged, so the wrapper is transparent in those cases.

A small helper script, `ffmpeg_init.sh`, prepares the environment at boot. It can start the optional `ffmpeg_daemon` container, copy and back up the FFmpeg binary, and create a symbolic link so SageTV always calls a stable `ffmpeg.sh` entry point while the wrapper and external FFmpeg can be updated behind the scenes. `ffmpeg_init.sh` is intended to be launched by `sagetv-user-script.sh`, which is provided by the SageTV Linux Docker image. If you only want native or copy only operation you can run `ffmpeg_init.sh` without the Docker option and skip the daemon entirely.

In the future I would like to simplify this by using a static FFmpeg build inside the SageTV Docker instead of running Docker inside Docker. That would require updating the base SageTV Docker image to Ubuntu 22.x or newer so that the necessary Intel QSV drivers and libraries are available. The interception script would still be valid in that setup, only the way FFmpeg is launched would change.


# How to install

1. Pass device `/dev/dri` into the SageTV Docker container:

```bash
--device=/dev/dri:/dev/dri
```

2. Install Docker inside the SageTV Docker container:

```bash
# Update package index and install prerequisites
sudo apt-get update
sudo apt-get install ca-certificates curl gnupg

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# Add the Docker repository to Apt sources
echo \
  "deb [arch="$(dpkg --print-architecture)" signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu \
  "$(. /etc/os-release && echo "$VERSION_CODENAME")" stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Update package index and install Docker Engine
sudo apt-get update
sudo apt-get install docker-ce docker-ce-cli containerd.io docker-buildx-plugin
```

3. Install the SageTVTranscoder-FFmpeg plugin from:

```text
https://github.com/jvl711/SageTVTranscoder-FFmpeg
```

4. In the `/opt/sagetv/server` directory, rename `ffmpeg` to `ffmpeg.run`:

```bash
cd /opt/sagetv/server
mv ffmpeg ffmpeg.run
```

5. Either copy to `sagetv-user-script.sh` to  `/opt/sagetv/server` directory or edit `sagetv-user-script.sh` and add the following lines:

```bash
chmod 777 /opt/sagetv/server/ffmpeg_init.sh
#Remove docker if ffmpeg is native installed as it will start docker and ffmpeg daemon
sudo bash /opt/sagetv/server/ffmpeg_init.sh docker
```

6. Copy `ffmpeg_init.sh` and  `ffmpeg.sh` into the `/opt/sagetv/server` directory:

7. Restart the SageTV Docker container.

8. Test the ffmpeg demaon Docker  image inside the SageTV Docker container:

```bash
sudo docker exec ffmpeg_daemon ffmpeg
```
