# VoxelShift: CTB → NanoDLP Converter &nbsp;&nbsp;&nbsp; [![Discord Link](https://discordapp.com/api/guilds/1281738817417777204/widget.png?style=shield)](https://discord.gg/beFeTaPH6v)

[![GitHub license](https://img.shields.io/github/license/Open-Resin-Alliance/VoxelShift.svg?style=for-the-badge)](LICENSE)
[![GitHub release](https://img.shields.io/github/release/Open-Resin-Alliance/VoxelShift.svg?style=for-the-badge)](https://github.com/Open-Resin-Alliance/Orion/releases)

VoxelShift is a desktop utility from the Open Resin Alliance for converting resin slicer files into NanoDLP‑ready plate files. It includes a streamlined post‑processor mode for slicers, automatic material selection, and optional upload/start‑print workflows for NanoDLP devices.

VoxelShift is developed with the Concepts3D Athena 2 printers in mind, which we currently support on a voluntary basis.

> :warning: **VoxelShift is under active development.** Please test carefully before relying on it in production workflows, and avoid unattended prints during early setup.

> **Disclaimer:** This tool was rapidly prototyped with the help of Copilot, but every release goes through extensive human testing, quality control, and hands‑on code review/tweaks before distribution.

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

## Legal Notice: Reverse Engineering

This software includes reverse engineering of CTB and related resin file formats undertaken for interoperability purposes. We assume this work operates within the scope of:

- **EU Directive 2009/24/EG** – Legal protection of computer programs (reverse engineering for interoperability)
- **DMCA Section 1201(f)** (USA) – Exemption for reverse engineering to achieve interoperability
- **Fair Use / Fair Dealing** – Copyright law exceptions for transformative reverse engineering work

VoxelShift builds upon findings from the open-source **UVTools** project and employs clean-room reverse engineering principles to ensure independent verification of format specifications. We make a good-faith effort to respect intellectual property rights while enabling hardware-independent interoperability. Users are responsible for ensuring their use of this software complies with applicable laws in their jurisdiction.

> **Disclaimer:** This is general information only and not legal advice. Users with jurisdiction-specific concerns should consult with qualified legal counsel regarding their particular use case and location.

## Features

- **Fast CTB conversion** to NanoDLP plate format.
- **Post‑processor mode** for slicer automation (env/CLI‑driven).
- **Material profile selection** for NanoDLP uploads.
- **Optional auto‑upload and auto‑start** for large conversions.
- **Branded thumbnails** with clean cropping and dark gradient styling.
- **Progress + debug visibility** (including worker counts during conversion).
- **Optional compute auto-tuner** (CPU vs GPU path on sample layers).
- **Optional external CUDA/Tensor kernel hook** for NVIDIA systems.

## Supported Platforms
The following platforms are currently supported and have been tested:

| Platform | Support | Tested |
| --- | --- | --- |
| Windows | ✅ Supported | ✅ Tested |
| macOS | ✅ Supported | ✅ Tested |
| Linux | ✅ Supported | ⚠️ Not tested |
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
	- `voxelshift.exe --file <path-to-file>`
	- `voxelshift.exe -h` (show CLI help)
	
Windows terminal logging helpers:

- `--attach-console` force attach/create a console so stdout/stderr logs stay visible.
- `--new-console` force opening a dedicated console window.

When an active NanoDLP device is configured, VoxelShift can automatically upload and optionally start the print (configurable in the UI).

## Notes for Post-Processor Mode

Post-Processor Mode can for example be used as part of the External Tools function in LycheeSlicer.
To do so, the program can be added using the following paths:
- **Windows:**
	- `"C:\Program Files (x86)\VoxelShift\voxelshift.exe" ((file))`
- **macOS:**
	- `"/Applications/Voxelshift.app/Contents/MacOS/voxelshift" ((file))`

## Optional Performance Modes

VoxelShift supports optional runtime tuning controls through environment variables:

- `VOXELSHIFT_GPU_MODE=auto|cpu|gpu`
	- `auto` (default): allow runtime auto-selection.
	- `cpu`: force CPU path.
	- `gpu`: force GPU-eligible path.
- `VOXELSHIFT_FAST_MODE=1`
	- Enables speed-first defaults for post-processing runs.
	- Sets initial processing PNG level to `0` and, unless explicitly overridden,
	  disables recompression (`VOXELSHIFT_RECOMPRESS_MODE=off`).
- `VOXELSHIFT_PROCESS_PNG_LEVEL=0..9`
	- Override PNG compression level used during the main processing phase
	  (default `1`, or `0` when fast mode is enabled).
- `VOXELSHIFT_AUTOTUNE=1`
	- Explicitly enable warmup benchmark selection (CPU vs GPU) on sample layers.
	- In `auto` mode this is enabled by default unless set to `0`.
- `VOXELSHIFT_GPU_HOST_WORKERS=<N>`
	- Override host worker count for hybrid GPU processing.
- `VOXELSHIFT_RECOMPRESS_WORKERS=<N>`
	- Override worker count for the adaptive PNG recompression pass.
- `VOXELSHIFT_RECOMPRESS_LEVEL=0..9`
	- Override zlib level used by recompression pass (default: `7`).
	- Lower values are faster, higher values are smaller.
	- For large jobs, VoxelShift now defaults to faster levels automatically
	  (`4` for very large, `5` for medium) unless overridden.
- `VOXELSHIFT_RECOMPRESS_MODE=adaptive|off|on`
	- `adaptive` (default): run recompression only when estimated savings are meaningful.
	- `off`: skip recompression entirely (fastest conversion, larger files).
	- `on`: always run recompression.
- `VOXELSHIFT_RECOMPRESS_CHUNKS=<N>`
	- Split native recompression into coarse chunks for smoother progress updates.
	- Lower values maximize throughput, higher values give more frequent progress updates.

### Optional CUDA/Tensor Kernel Module

VoxelShift can optionally load a separate kernel module for backend `CUDA/Tensor`.

Expected module and symbol:

- Windows: `voxelshift_cuda_kernel.dll`
- Linux: `libvoxelshift_cuda_kernel.so`
- Exported symbol: `vs_cuda_tensor_build_scanlines`

The repository now includes a starter module in:

- `native/cuda_kernel/`

Build helper (Windows PowerShell):

- `tool/build_cuda_kernel.ps1`

Example staging to release binary directory:

- `tool/build_cuda_kernel.ps1 -BuildType Release -AppBinDir "build/windows/x64/runner/Release"`

If the module is not present, VoxelShift automatically falls back to OpenCL/CPU paths.

## Contributing

We welcome contributions! If you’d like to help improve VoxelShift:

1. Fork the repository and create a feature branch.
2. Make your changes and ensure the app builds cleanly.
3. Open a pull request with a clear description of your changes.

## License

VoxelShift is licensed under the [Apache License 2.0](LICENSE).

## Trademarks and Third-Party Software

This software and documentation may reference third-party products and brand names for informational and compatibility purposes only. All trademarks, service marks, and trade names referenced herein remain the property of their respective owners:

- **LycheeSlicer** is owned and trademarked by Mango3D
- **NanoDLP** is owned by its respective rights holders
- **UVTools** is an open-source project developed by Tiago Conceição
- **Concepts3D Athena** printers are supported with explicit permission from Concepts3D
- Other product names mentioned are trademarks or registered trademarks of their respective companies

VoxelShift is an independent project developed by the Open Resin Alliance and is not affiliated with, endorsed by, or sponsored by any of the aforementioned parties (except where explicitly noted). References to third-party software are made solely for the purpose of describing interoperability and compatibility.

## Contact

Join the Open Resin Alliance community on Discord: https://discord.gg/beFeTaPH6v
