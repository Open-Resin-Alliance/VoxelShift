/**
 * @file config.h
 * @brief Build-time feature flags for native VoxelShift components.
 *
 * This header centralizes compile-time switches used by native C/CUDA
 * modules. It is intentionally tiny and included by voxelshift_native.h
 * so all translation units can reference the same feature gates.
 */
#ifndef VOXELSHIFT_CONFIG_H
#define VOXELSHIFT_CONFIG_H

// Temporary safety switch: disable CUDA/Tensor acceleration until the
// RAM/VRAM overflow issue is fully resolved. OpenCL remains enabled.
#define VOXELSHIFT_DISABLE_CUDA 1

#endif // VOXELSHIFT_CONFIG_H