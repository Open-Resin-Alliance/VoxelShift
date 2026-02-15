param(
  [string]$BuildType = "Release",
  [string]$AppBinDir = "",
  [string]$Generator = ""
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$CudaSrc = Join-Path $RepoRoot "native/cuda_kernel"
$BuildDir = Join-Path $RepoRoot "build/cuda-kernel"

function Resolve-Nvcc {
  $cmd = Get-Command nvcc -ErrorAction SilentlyContinue
  if ($cmd -and (Test-Path $cmd.Source)) {
    return $cmd.Source
  }

  $candidates = @()
  $base = "C:/Program Files/NVIDIA GPU Computing Toolkit/CUDA"

  if ($env:CUDA_PATH) {
    if ([System.IO.Path]::IsPathRooted($env:CUDA_PATH)) {
      $candidates += (Join-Path $env:CUDA_PATH "bin/nvcc.exe")
    } else {
      $candidates += (Join-Path (Join-Path $base $env:CUDA_PATH) "bin/nvcc.exe")
    }
  }

  if (Test-Path $base) {
    $dirs = Get-ChildItem $base -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending
    foreach ($d in $dirs) {
      $candidates += (Join-Path $d.FullName "bin/nvcc.exe")
    }
  }

  foreach ($c in $candidates) {
    if (Test-Path $c) {
      return $c
    }
  }

  return $null
}

$nvcc = Resolve-Nvcc
if (-not $nvcc) {
  throw "Could not locate nvcc.exe. Ensure CUDA Toolkit is installed (including compiler tools)."
}

$cudaRoot = Split-Path -Parent (Split-Path -Parent $nvcc)
$nvccForCmake = ($nvcc -replace '\\', '/')
$cudaRootForCmake = ($cudaRoot -replace '\\', '/')
Write-Host "[cuda-kernel] Using nvcc: $nvcc"
Write-Host "[cuda-kernel] CUDA root: $cudaRoot"

if (Test-Path $BuildDir) {
  Remove-Item -Recurse -Force $BuildDir
}
New-Item -ItemType Directory -Path $BuildDir | Out-Null

Write-Host "[cuda-kernel] Configuring in $BuildDir"
$cfgArgs = @(
  "-S", $CudaSrc,
  "-B", $BuildDir,
  "-DCMAKE_BUILD_TYPE=$BuildType",
  "-DCMAKE_CUDA_COMPILER=$nvccForCmake",
  "-DCUDAToolkit_ROOT=$cudaRootForCmake"
)

if ($Generator -ne "") {
  $cfgArgs += @("-G", $Generator)
}

cmake @cfgArgs

Write-Host "[cuda-kernel] Building ($BuildType)"
cmake --build $BuildDir --config $BuildType

$dll = Join-Path $BuildDir "$BuildType/voxelshift_cuda_kernel.dll"
if (!(Test-Path $dll)) {
  $dll = Join-Path $BuildDir "voxelshift_cuda_kernel.dll"
}

if (!(Test-Path $dll)) {
  throw "CUDA kernel build completed but DLL not found."
}

Write-Host "[cuda-kernel] Built: $dll"

if ($AppBinDir -ne "") {
  if (!(Test-Path $AppBinDir)) {
    throw "AppBinDir does not exist: $AppBinDir"
  }
  $dest = Join-Path $AppBinDir "voxelshift_cuda_kernel.dll"
  Copy-Item -Force $dll $dest
  Write-Host "[cuda-kernel] Staged to: $dest"
}
