# VoxelShift: CTB → NanoDLP Converter &nbsp;&nbsp;&nbsp; [![Discord Link](https://discordapp.com/api/guilds/1281738817417777204/widget.png?style=shield)](https://discord.gg/beFeTaPH6v)

[![GitHub license](https://img.shields.io/github/license/Open-Resin-Alliance/VoxelShift.svg?style=for-the-badge)](LICENSE)
[![GitHub release](https://img.shields.io/github/release/Open-Resin-Alliance/VoxelShift.svg?style=for-the-badge)](https://github.com/Open-Resin-Alliance/Orion/releases)

VoxelShift is a desktop utility from the Open Resin Alliance for converting resin slicer files into NanoDLP‑ready plate files. It includes a streamlined post‑processor mode for slicers, automatic material selection, and optional upload/start‑print workflows for NanoDLP devices.

VoxelShift is developed with the Concepts3D Athena 2 printers in mind, which we currently support on a voluntary basis.

> :warning: **VoxelShift is under active development.** Please test carefully before relying on it in production workflows, and avoid unattended prints during early setup.

**Disclaimer:** This tool was rapidly prototyped with the help of Copilot, but every release goes through extensive human testing, quality control, and hands‑on code review/tweaks before distribution.

## Table of Contents

- [About VoxelShift](#about-voxelshift)
- [A Necessary Workaround](#a-necessary-workaround)
- [Features](#features)
- [Supported Platforms](#platforms)
- [Getting Started](#getting-started)
	- [Variant 1: Desktop App](#variant-1-desktop-app)
	- [Variant 2: Post‑Processor Mode](#variant-2-post-processor-mode)
- [Contributing](#contributing)
- [License](#license)
- [Contact](#contact)

## About VoxelShift

VoxelShift converts CTB/CBDDLP/Photon resin files into `.nanodlp` plate archives that NanoDLP can import directly. It also exposes a post‑processor mode that slicers can call to convert, upload, and optionally start prints with minimal interaction.

## A Necessary Workaround

It is a somewhat sad reality that VoxelShift even needs to exist. Currently, this tool is the only viable way to integrate not just our printer systems, but also 3rd parties like Concepts3D with their Athena, into the existing popular resin slicers.

This is particularly true for software like **LycheeSlicer**, which is incredibly locked down and exercises complete control over which printers receive profiles and support. Because of these ecosystem limitations, the **Open Resin Alliance** is now fully committed to developing its own **Open Source Resin Slicer** to ensure true hardware independence and innovation. 

While VoxelShift currently focuses on supporting Athena printers, we plan to support **Odyssey** and the new `.lumen` format as development of the new slicer progresses.

## Features

- **Fast CTB conversion** to NanoDLP plate format.
- **Post‑processor mode** for slicer automation (env/CLI‑driven).
- **Material profile selection** for NanoDLP uploads.
- **Optional auto‑upload and auto‑start** for large conversions.
- **Branded thumbnails** with clean cropping and dark gradient styling.
- **Progress + debug visibility** (including worker counts during conversion).

## Supported Platforms
The following platforms are currently supported and have been tested:

| Platform | Support | Tested |
| --- | --- | --- |
| Windows | ✅ Supported | ✅ Tested |
| Linux | ✅ Supported | ⚠️ Not tested |
| macOS | ✅ Supported | ⚠️ Not tested |
| | | |
| Web | ❌ Not supported | ❌ Not tested |
| Android | ❌ Not supported | ❌ Not tested |
| iOS | ❌ Not supported | ❌ Not tested |

## Getting Started

### Variant 1: Desktop App

1. **Prerequisites:** Install Flutter 3.11+ and ensure desktop targets are enabled.
2. **Install dependencies:**
	 - `flutter pub get`
3. **Run the app:**
	 - `flutter run -d windows`
4. **Build release (Windows):**
	 - `flutter build windows --release`

### Variant 2: Post‑Processor Mode

VoxelShift can run as a lightweight post‑processor window when invoked with a file path.

- **Environment variable:**
	- `VOXELSHIFT_FILE=<path-to-file>`
- **CLI argument:**
	- `voxelshift.exe <path-to-file>`

When an active NanoDLP device is configured, VoxelShift can automatically upload and optionally start the print (configurable in the UI).

## Contributing

We welcome contributions! If you’d like to help improve VoxelShift:

1. Fork the repository and create a feature branch.
2. Make your changes and ensure the app builds cleanly.
3. Open a pull request with a clear description of your changes.

## License

VoxelShift is licensed under the [Apache License 2.0](LICENSE).

## Contact

Join the Open Resin Alliance community on Discord: https://discord.gg/beFeTaPH6v
