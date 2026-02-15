cmake_minimum_required(VERSION 3.20)
project(voxelshift_cuda_kernel LANGUAGES CXX CUDA)

option(VOXELSHIFT_CUDA_FAST_MATH "Enable --use_fast_math for CUDA kernel module" OFF)

add_library(voxelshift_cuda_kernel SHARED
  vs_cuda_tensor_kernel.cu
)

target_compile_features(voxelshift_cuda_kernel PRIVATE cxx_std_17)

# Keep the output filename aligned with the runtime loader expectations:
#   Windows: voxelshift_cuda_kernel.dll
#   Linux:   libvoxelshift_cuda_kernel.so
set_target_properties(voxelshift_cuda_kernel PROPERTIES
  OUTPUT_NAME "voxelshift_cuda_kernel"
)

# Good defaults for modern NVIDIA desktop GPUs (Turing/Ampere/Ada).
# Force these unconditionally — CMake 3.24+ auto-defines CMAKE_CUDA_ARCHITECTURES
# which would skip any `if(NOT DEFINED ...)` guard.
set_target_properties(voxelshift_cuda_kernel PROPERTIES
  CUDA_ARCHITECTURES "75-real;86-real;89-real;90-real;89-virtual"
)

if(VOXELSHIFT_CUDA_FAST_MATH)
  target_compile_options(voxelshift_cuda_kernel PRIVATE
    $<$<COMPILE_LANGUAGE:CUDA>:--use_fast_math>
  )
endif()
