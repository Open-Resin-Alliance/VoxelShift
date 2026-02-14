# VoxelShift Conversion Pipeline

This document explains how VoxelShift converts resin slicer files into NanoDLP plate archives.

## Overview

VoxelShift reads CTB/CBDDLP/Photon files, extracts metadata and layer data, converts layer images into PNG slices, and packages everything into a NanoDLP-compatible .nanodlp archive.

The conversion is optimized for performance and uses isolates to keep the UI responsive.

## Step-by-step flow

1) Read file header
- Open the source file and parse metadata such as resolution, layer count, layer height, exposure times, and previews.
- Extract preview thumbnails if present.
- Generate a branded thumbnail by removing black borders and applying a dark gradient.

2) Validate printer profile
- Detect or select a target printer profile based on resolution and board type.
- Validate that the source resolution matches supported target profiles.

3) Read raw layer data
- Layer data is read sequentially from the source file.
- Raw layer data is stored in memory for parallel processing.

4) Layer processing (parallel isolates)
Each layer is processed in a worker isolate:
- Decrypt layer data if required.
- Decode RLE-compressed pixels to a greyscale buffer.
- Compute layer area statistics for metadata and bounding boxes.
- Encode into PNG using a custom encoder optimized for speed.

5) PNG recompression pass
- Initial layer PNGs are encoded at a fast compression level for speed.
- After all layers are processed, a second pass recompresses PNG IDAT data at level 9.
- This significantly reduces final .nanodlp file size.

6) Metadata construction
- Plate metadata is generated including dimensions, layer counts, exposure parameters, and bounding box information.
- Optional per-layer area statistics are prepared for inclusion.

7) NanoDLP packaging
- A .nanodlp archive is created with:
  - plate.json
  - profile.json
  - options.json
  - info.json (if available)
  - 3d.png (thumbnail)
  - Layer PNG files (1.png, 2.png, ...)
- PNGs are stored without ZIP recompression to avoid double compression overhead.

8) Final output
- The output archive is written to disk and its size recorded.
- Conversion results include output path, duration, and layer count.

## Performance notes

- Conversion runs in a background isolate to keep the UI responsive.
- Layer processing uses adaptive worker concurrency based on file size.
- Progress reporting is debounced to avoid UI churn.

## Post-processor mode

When launched in post-processor mode, VoxelShift can:
- Auto-detect the active NanoDLP device
- Convert the file
- Upload the resulting .nanodlp archive
- Optionally start the print after upload

This mode is intended for slicer integration and automation workflows.
