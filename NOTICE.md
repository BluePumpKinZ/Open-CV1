Open-CV1 is a derivative packaging of SteamVR-OpenHMD for Oculus CV1 use on Linux.

Primary upstream projects:
- SteamVR-OpenHMD by Christoph Haag and contributors
- OpenHMD by OpenHMD contributors
- OpenVR headers/sample code by Valve

This repository keeps the upstream Boost Software License from SteamVR-OpenHMD in `LICENSE`.
The bundled `subprojects/openhmd` and `subprojects/openvr` trees keep their own upstream licenses and notices inside those source trees.

Local changes in this repository focus on:
- Fedora-oriented install and launch scripts
- SteamVR registration and config wiring
- Oculus CV1 user setup notes
- configurable global pose offsets for height/origin correction
