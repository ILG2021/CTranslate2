[CmdletBinding()]
param(
    [ValidateRange(1, 128)]
    [int]$Jobs = 8,

    [ValidateNotNullOrEmpty()]
    [string]$CudaArch = "Common"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Assert-NativeCommand {
    param([string]$Step)
    if ($LASTEXITCODE -ne 0) {
        throw "$Step failed (exit code: $LASTEXITCODE)"
    }
}

function Require-Command {
    param(
        [string]$Name,
        [string]$Hint
    )
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Command '$Name' was not found. $Hint"
    }
}

function Require-File {
    param(
        [string]$Path,
        [string]$Hint
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required file was not found: $Path`n$Hint"
    }
}

function Import-VisualStudioEnvironment {
    if (Get-Command "cl.exe" -ErrorAction SilentlyContinue) {
        Write-Host "Visual Studio C++ environment is already available."
        return
    }

    Write-Step "Locating Visual Studio 2022 C++ tools"
    $vsDevCmd = $null
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path -LiteralPath $vswhere -PathType Leaf) {
        $installationPath = & $vswhere -latest -products * `
            -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath
        if ($LASTEXITCODE -eq 0 -and $installationPath) {
            $candidate = Join-Path ($installationPath | Select-Object -First 1) "Common7\Tools\VsDevCmd.bat"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $vsDevCmd = $candidate
            }
        }
    }

    if (-not $vsDevCmd) {
        $editions = @("Community", "Professional", "Enterprise", "BuildTools")
        foreach ($edition in $editions) {
            $candidate = "${env:ProgramFiles}\Microsoft Visual Studio\2022\$edition\Common7\Tools\VsDevCmd.bat"
            if (Test-Path -LiteralPath $candidate -PathType Leaf) {
                $vsDevCmd = $candidate
                break
            }
        }
    }

    if (-not $vsDevCmd) {
        throw "Visual Studio 2022 C++ tools were not found. Install the 'Desktop development with C++' workload."
    }

    $cmdLine = "call `"$vsDevCmd`" -no_logo -arch=x64 -host_arch=x64 >nul && set"
    $environmentLines = & $env:ComSpec /d /s /c $cmdLine
    Assert-NativeCommand "Visual Studio environment initialization"

    foreach ($line in $environmentLines) {
        $separator = $line.IndexOf('=')
        if ($separator -gt 0) {
            $name = $line.Substring(0, $separator)
            $value = $line.Substring($separator + 1)
            [Environment]::SetEnvironmentVariable($name, $value, "Process")
        }
    }

    Require-Command "cl.exe" "Visual Studio was found, but its x64 C++ environment could not be initialized."
    Write-Host "Visual Studio x64 C++ environment was loaded for this build process only."
}

$repoPath = $PSScriptRoot
$repo = $repoPath.Replace('\', '/')
$buildDir = "$repo/build"
$pythonDir = "$repo/python"
$installDir = "$pythonDir/ctranslate2"
$venvPython = "$repo/.venv-build/Scripts/python.exe"

Write-Step "Checking build environment"
if (-not [Environment]::Is64BitOperatingSystem) {
    throw "A 64-bit Windows installation is required."
}

Import-VisualStudioEnvironment
Require-Command "cmake.exe" "Install CMake and add it to PATH."
Require-Command "nvcc.exe" "Install CUDA Toolkit 12.4 and add its bin directory to PATH."
Require-Command "git.exe" "Install Git and add it to PATH."
Require-Command "python.exe" "Install a supported 64-bit Python (3.9 or newer)."

if (-not $env:CUDA_PATH) {
    throw "CUDA_PATH is not set. Install the complete CUDA Toolkit and reopen Developer PowerShell."
}

$cudaPath = $env:CUDA_PATH
$cuda = $cudaPath.Replace('\', '/')
Require-File "$cudaPath/include/cuda.h" "The CUDA development headers are missing."
Require-File "$cudaPath/lib/x64/cudart.lib" "The CUDA development libraries are missing."
Require-File "$cudaPath/include/cudnn.h" "Install cuDNN 9.x headers into CUDA_PATH/include."
Require-File "$cudaPath/lib/x64/cudnn.lib" "Install cuDNN 9.x libraries into CUDA_PATH/lib/x64."
Require-File "$cudaPath/bin/cudnn64_9.dll" "Install the cuDNN 9.x runtime into CUDA_PATH/bin."
$cudnnRuntime = "$cudaPath/bin/cudnn64_9.dll"

if (($env:PATH -split ';') -notcontains "$cudaPath\bin") {
    $env:PATH = "$cudaPath\bin;$env:PATH"
}

Write-Host "Repository : $repoPath"
Write-Host "CUDA       : $cudaPath"
Write-Host "Architecture: $CudaArch"
Write-Host "Parallelism : $Jobs"

$submoduleMarkers = @(
    "$repoPath/third_party/cxxopts/include/cxxopts.hpp",
    "$repoPath/third_party/thrust/thrust/version.h",
    "$repoPath/third_party/cutlass/include/cutlass/cutlass.h",
    "$repoPath/third_party/spdlog/include/spdlog/spdlog.h"
)
if ($submoduleMarkers | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }) {
    Write-Step "Initializing Git submodules"
    & git.exe -C $repoPath submodule update --init --recursive --jobs $Jobs
    Assert-NativeCommand "Git submodule initialization"
}
else {
    Write-Host "Git submodules are already initialized; skipping download."
}

if (-not (Test-Path -LiteralPath $venvPython -PathType Leaf)) {
    Write-Step "Creating the Python build environment"
    & python.exe -m venv "$repoPath/.venv-build"
    Assert-NativeCommand "Python virtual environment creation"
}

& $venvPython -c "import pybind11, setuptools, wheel; assert pybind11.__version__ == '2.11.1'" 2>$null
if ($LASTEXITCODE -ne 0) {
    Write-Step "Installing Python build requirements"
    & $venvPython -m pip install -r "$pythonDir/install_requirements.txt"
    Assert-NativeCommand "Python requirement installation"
}
else {
    Write-Host "Python build requirements are already installed; skipping installation."
}

Write-Step "Configuring CMake (the existing cache will be reused)"
$cmakeArgs = @(
    "-S", $repo,
    "-B", $buildDir,
    "-G", "Visual Studio 17 2022",
    "-A", "x64",
    "-DCMAKE_BUILD_TYPE=Release",
    "-DBUILD_SHARED_LIBS=ON",
    "-DBUILD_CLI=OFF",
    "-DBUILD_TESTS=OFF",
    "-DWITH_CUDA=ON",
    "-DWITH_CUDNN=ON",
    "-DCUDA_DYNAMIC_LOADING=ON",
    "-DWITH_MKL=OFF",
    "-DWITH_DNNL=OFF",
    "-DWITH_OPENBLAS=OFF",
    "-DWITH_RUY=OFF",
    "-DOPENMP_RUNTIME=NONE",
    "-DENABLE_CPU_DISPATCH=OFF",
    "-DCUDA_ARCH_LIST=$CudaArch",
    "-DCUDA_NVCC_FLAGS=-Xfatbin=-compress-all",
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5",
    "-DCUDA_TOOLKIT_ROOT_DIR=$cuda",
    "-DCMAKE_INSTALL_PREFIX=$installDir",
    "-DCMAKE_INSTALL_BINDIR=."
)
& cmake.exe @cmakeArgs
Assert-NativeCommand "CMake configuration"

Write-Step "Building C++ and CUDA targets incrementally"
& cmake.exe --build $buildDir --config Release --parallel $Jobs
Assert-NativeCommand "C++/CUDA build"

Write-Step "Installing CTranslate2 into the Python package"
& cmake.exe --install $buildDir --config Release
Assert-NativeCommand "CMake installation"

$requiredOutputs = @(
    "$installDir/ctranslate2.dll",
    "$installDir/lib/ctranslate2.lib",
    "$installDir/include/ctranslate2/translator.h"
)
$missingOutputs = $requiredOutputs | Where-Object { -not (Test-Path -LiteralPath $_ -PathType Leaf) }
if ($missingOutputs) {
    Write-Host ($missingOutputs -join "`n") -ForegroundColor Red
    throw "The CMake installation is incomplete; wheel packaging was stopped."
}

Write-Step "Copying the required cuDNN runtime into the Python package"
Copy-Item -LiteralPath $cudnnRuntime -Destination "$installDir/cudnn64_9.dll" -Force
Require-File "$installDir/cudnn64_9.dll" "The required cuDNN runtime could not be copied into the package."

Write-Step "Building the wheel incrementally"
$env:CTRANSLATE2_ROOT = $installDir
$env:CMAKE_BUILD_PARALLEL_LEVEL = [string]$Jobs

$distDir = "$pythonDir/dist"
if (Test-Path -LiteralPath $distDir) {
    Get-ChildItem -LiteralPath $distDir -Filter "*.whl" -File | Remove-Item -Force
}

Push-Location $pythonDir
try {
    & $venvPython setup.py bdist_wheel
    Assert-NativeCommand "Wheel build"
}
finally {
    Pop-Location
}

$wheel = Get-ChildItem -LiteralPath $distDir -Filter "*.whl" -File |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $wheel) {
    throw "No wheel was generated in $distDir."
}

Write-Step "Verifying wheel contents"
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [System.IO.Compression.ZipFile]::OpenRead($wheel.FullName)
try {
    $entries = @($archive.Entries | ForEach-Object { $_.FullName })
}
finally {
    $archive.Dispose()
}

$extensionEntry = $entries | Where-Object { $_ -match '^ctranslate2/_ext.*\.pyd$' } | Select-Object -First 1
$runtimeEntry = $entries | Where-Object { $_ -eq 'ctranslate2/ctranslate2.dll' } | Select-Object -First 1
$cudnnEntry = $entries | Where-Object { $_ -eq 'ctranslate2/cudnn64_9.dll' } | Select-Object -First 1
if (-not $extensionEntry) {
    throw "The wheel is incomplete: ctranslate2/_ext*.pyd is missing."
}
if (-not $runtimeEntry) {
    throw "The wheel is incomplete: ctranslate2/ctranslate2.dll is missing."
}
if (-not $cudnnEntry) {
    throw "The wheel is incomplete: cudnn64_9.dll is missing."
}

Write-Step "Checking runtime DLL dependencies"
$runtimeCheck = @"
import ctypes
import os

cuda_bin = os.path.join(os.environ["CUDA_PATH"], "bin")
handle = os.add_dll_directory(cuda_bin)
ctypes.CDLL(r"$installDir/ctranslate2.dll")
print("ctranslate2.dll and its direct dependencies loaded successfully")
"@
& $venvPython -c $runtimeCheck
Assert-NativeCommand "Runtime DLL dependency check"

Write-Host "`nBuild completed successfully." -ForegroundColor Green
Write-Host "Wheel: $($wheel.FullName)"
Write-Host ("Size : {0:N2} MB" -f ($wheel.Length / 1MB))
Write-Host "Found: $extensionEntry"
Write-Host "Found: $runtimeEntry"
Write-Host "Found: $cudnnEntry"
Write-Host "Existing object files were preserved; unchanged sources will not be recompiled."
