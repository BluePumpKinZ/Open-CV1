# Open-CV1

Open-CV1 packages a working Oculus CV1 + SteamVR + OpenHMD setup for Linux, with a focus on Fedora and user-space installation.

It is a derivative of:
- `thaytan/SteamVR-OpenHMD`
- `OpenHMD/OpenHMD`

This repository keeps the upstream source layout so the driver can still be built directly, but adds:
- a one-shot installer for SteamVR registration and local config
- a launcher script that starts SteamVR against this driver tree
- a pose-offset helper for height and origin correction
- a CV1 sensor calibration helper with persistent pose caches
- a faster async pose update loop for SteamVR delivery
- CV1-oriented documentation and setup notes

## Current status

What works in the current setup:
- CV1 display output in SteamVR
- HMD tracking through OpenHMD
- Touch controllers appearing in SteamVR
- SteamVR compositor on NVIDIA Vulkan

Current limitations:
- positional tracking can still jitter
- presence/proximity detection is not implemented correctly in this driver path
- there is no proper room-setup UI for CV1 sensors
- controller bindings are still inherited from SteamVR-OpenHMD and remain imperfect

## Requirements

Expected on Fedora 44:
- Steam
- SteamVR
- `meson`
- `ninja-build`
- `gcc-c++`
- `pkgconf-pkg-config`
- `hidapi-devel`
- `libusb1-devel`
- `opencv-devel`
- `libjpeg-turbo-devel`
- working OpenHMD USB access, preferably through `xr-hardware` udev rules

Install the build dependencies with:

```bash
sudo dnf install meson ninja-build gcc-c++ pkgconf-pkg-config \
  hidapi-devel libusb1-devel opencv-devel libjpeg-turbo-devel
```

## Install

1. Clone this repository.
2. Make sure Steam and SteamVR are already installed under `~/.local/share/Steam`.
3. Run:

   ```bash
   ./install.sh
   ```

What `install.sh` does:
- builds the driver into `build/` and generates `driver_openhmd/`
- registers `driver_openhmd/` with SteamVR through `vrpathreg`
- creates `~/.ohmd_config.txt` if it does not already exist
- backs up, then merges the Open-CV1 SteamVR performance profile into `~/.local/share/Steam/config/steamvr.vrsettings`
- disables the native SteamVR Oculus drivers for this setup
- installs user-local launch helpers in `~/bin/`

Installed helpers:
- `~/bin/start-steamvr-openhmd.sh`
- `~/bin/set-open-cv1-pose-offset.sh`
- `~/bin/calibrate-open-cv1-sensors.sh`

## Launch

Use either:

```bash
~/bin/start-steamvr-openhmd.sh
```

or run the desktop entry:

`SteamVR OpenHMD`

The launcher keeps the same user-space behavior as the current working setup:
- registers the driver if needed
- sets `OHMD_VENDOR_OVERRIDE=Oculus`
- injects the local `libdrm.so` shim when present
- starts SteamVR through Steam if Steam is not already running

## Beat Saber profile

For the tested Beat Saber setup:
- force compatibility tool `Proton 9` in Steam's Beat Saber Properties > Compatibility
- start SteamVR before starting Beat Saber
- leave SteamVR render resolution at the installed manual `100%` scale
- keep Linux Vulkan async disabled; it caused substantially worse frame pacing on this CV1 setup
- SteamVR Home is disabled by the installer to keep the VR session lighter

The driver synthesizes angular acceleration from the CV1's valid angular
velocity stream. This is enabled by default and is bounded and filtered to
avoid prediction spikes. To compare without it, set
`driver_openhmd.synthesizeAngularAcceleration` to `false` in
`steamvr.vrsettings`, then restart SteamVR.

Controller vibration is enabled by default. For controller radio diagnosis,
it can be disabled independently with `driver_openhmd.enableHaptics`.

### Prediction timing trials

The compositor exposes a runtime-only timing offset for testing the final
vsync-to-photon prediction horizon. The default `0 ms` offset keeps the
driver's `0.011 s` 90 Hz value unchanged. With SteamVR running, compare one
setting at a time while moving your head in Beat Saber:

```bash
~/bin/set-steamvr-photon-offset.sh --offset 0
~/bin/set-steamvr-photon-offset.sh --offset 0.5
~/bin/set-steamvr-photon-offset.sh --offset -0.5
~/bin/set-steamvr-photon-offset.sh --reset
```

The command does not alter SteamVR configuration and resets when SteamVR
exits. Keep trials within `+/-3 ms`; a wrong value can make head motion feel
worse.

Proton games obtain the SteamVR OpenXR runtime through SteamVR. There is no
separate system OpenXR JSON file to install for this setup. If Beat Saber says
the OpenXR runtime is missing, close the game, start SteamVR first, wait until
the headset is detected, and then launch Beat Saber from Steam.

## Device selection

OpenHMD device selection still comes from `~/.ohmd_config.txt`.

The repository ships this example in `config/ohmd_config.txt.example`:

```text
hmddisplay 0
hmdtracker 0
leftcontroller 3
rightcontroller 2
```

Those values match one working CV1 setup, not every machine. If device ordering changes, edit `~/.ohmd_config.txt`.

## Height and origin correction

This repository adds global pose offsets to the SteamVR driver config:
- `poseOffsetX`
- `poseOffsetY`
- `poseOffsetZ`
- `poseYawDegrees`

The easiest way to change them is:

```bash
~/bin/set-open-cv1-pose-offset.sh --y 0.18
```

Examples:

```bash
~/bin/set-open-cv1-pose-offset.sh --y 0.18
~/bin/set-open-cv1-pose-offset.sh --x 0.05 --z -0.10 --yaw 15
~/bin/set-open-cv1-pose-offset.sh --x 0 --y 0 --z 0 --yaw 0
```

Notes:
- positive `--y` raises you in VR
- values are in meters
- `--yaw` rotates the entire playspace in degrees
- this is an origin correction, not true sensor calibration

## Tracking notes

The CV1 tracking path here does not use the original Oculus room setup flow. OpenHMD reads calibration data from the sensor hardware and estimates sensor pose dynamically from camera observations and IMU fusion.

That means:
- startup visibility matters
- sensor placement still matters
- origin correction can be handled with the pose offset settings above
- sensor-to-world calibration is still fundamentally rougher than the official stack

This repository adds persistent CV1 sensor pose caches under `~/.config/openhmd/rift-sensor-pose-*.txt`.
They are automatically loaded on startup and saved after the tracker learns a sensor pose.

To force a fresh relearn:

```bash
~/bin/calibrate-open-cv1-sensors.sh --relearn
```

First close SteamVR. The helper backs up and clears the old caches, then waits
while you start SteamVR yourself. Enter the height that Beat Saber should
report, wear the headset, stand upright in the center of the play area, and
face forward. Keep your head and both sensors still until both sensor poses and
a stable headset height sample are saved. The helper calculates `poseOffsetY`
from that raw sample. Restart SteamVR afterward to load the offset; the helper
does not start or stop SteamVR.

The height can also be provided non-interactively:

```bash
~/bin/calibrate-open-cv1-sensors.sh --relearn --height-cm 172
```

To correct height without discarding good sensor poses, start SteamVR, wear the
headset, stand upright and still, then run:

```bash
~/bin/calibrate-open-cv1-sensors.sh --height-cm 172
```

Restart SteamVR once the sample completes.

To inspect current cached sensor poses:

```bash
~/bin/calibrate-open-cv1-sensors.sh --show
```

To manually shift all saved sensors upward by 10 cm:

```bash
~/bin/calibrate-open-cv1-sensors.sh --offset 0 0.10 0
```

To set one sensor to an explicit position while keeping its saved orientation:

```bash
~/bin/calibrate-open-cv1-sensors.sh --set-pos WMTD305L40075G 0.10 -0.20 1.55
```

To write a complete quaternion + position pose for one sensor:

```bash
~/bin/calibrate-open-cv1-sensors.sh --set WMTD305L40075G -0.92 -0.15 0.34 -0.01 0.14 -0.28 1.56
```

The cache format is:
- `qx qy qz qw px py pz`
- quaternion first, then position in meters
- edit carefully and restart SteamVR after manual changes

## GPU note

In the tested working setup, SteamVR compositor logs showed:
- Vulkan renderer
- NVIDIA GeForce RTX 4070 Ti SUPER

So this setup was not running on the wrong GPU when the CV1 was connected to NVIDIA.

## Attribution

See `NOTICE.md` for project attribution.

Main upstream source/license files kept here:
- `LICENSE`
- `subprojects/openhmd`
- `subprojects/openvr`

## Known next steps

The most promising technical follow-ups are:
- better CV1-specific tracking calibration tooling
- real proximity/presence support
