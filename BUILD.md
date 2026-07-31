# CTranslate2：Windows CUDA Wheel 构建指南

本文说明如何在 Windows 上从源码构建启用 CUDA 12.4 和 cuDNN 9.x 的 CTranslate2 wheel。

构建结果包含：

- Python 扩展 `ctranslate2/_ext.cpXXX-win_amd64.pyd`
- CTranslate2 运行库 `ctranslate2/ctranslate2.dll`
- CUDA 后端代码

默认不把 NVIDIA 的 CUDA/cuDNN DLL 打进 wheel。目标机器需要安装兼容的 CUDA 和 cuDNN，或者在构建完成后另行使用 `delvewheel` 修复 wheel。

> 所有命令都在 **Developer PowerShell for VS 2022** 中执行。除特别说明外，当前目录必须是仓库根目录，也就是包含 `CMakeLists.txt`、`python` 和 `src` 的目录。

## 1. 环境要求

- Windows x64
- Visual Studio 2022，并安装“使用 C++ 的桌面开发”工作负载和 Windows SDK
- Python 3.9 或更高版本；使用哪个 Python 构建，就会生成对应 ABI 的 wheel
- CMake（建议使用 3.26～3.28；项目仍使用旧式 `FindCUDA`）
- CUDA Toolkit 12.4，包括开发文件和 Visual Studio 集成
- cuDNN 9.x for CUDA 12
- Git

先确认工具都来自预期环境：

```powershell
where.exe cl
where.exe cmake
where.exe nvcc
where.exe python

cmake --version
nvcc --version
python --version
```

确认 CUDA 环境变量和关键文件：

```powershell
$env:CUDA_PATH
Test-Path "$env:CUDA_PATH/include/cuda.h"
Test-Path "$env:CUDA_PATH/lib/x64/cudart.lib"
Test-Path "$env:CUDA_PATH/include/cudnn.h"
Test-Path "$env:CUDA_PATH/lib/x64/cudnn.lib"
Test-Path "$env:CUDA_PATH/bin/cudnn64_9.dll"
```

这些 `Test-Path` 应全部返回 `True`。如果 cuDNN 是单独下载的压缩包，应把其中的 `bin`、`include` 和 `lib` 内容合并到 `$env:CUDA_PATH` 对应目录。

## 2. 初始化子模块

```powershell
git submodule update --init --recursive --jobs 8
git submodule status
```

`git submodule status` 的各行不应以 `-` 开头。

## 3. 创建隔离的 Python 构建环境（推荐）

```powershell
python -m venv .venv-build
& .\.venv-build\Scripts\python.exe -m pip install --upgrade pip
& .\.venv-build\Scripts\python.exe -m pip install -r python\install_requirements.txt
```

后续脚本直接调用该环境中的 `python.exe`，不需要每次激活虚拟环境。

## 4. 一次性增量构建并验证 wheel

以后每次构建都只需在仓库根目录执行下面这一个代码块。它会依次完成 CMake 配置、增量编译、安装、wheel 打包和内容检查。

脚本不会删除 `build/` 或 `python/build/`：

- CMake/MSBuild 会保留 `.obj`，只重新编译修改过的 C/C++/CUDA 源文件及受影响目标。
- setuptools 会保留 Python 扩展的中间文件，只在源文件更新时重新编译。
- 每次只删除旧的 `.whl` 输出，避免验证到上一次生成的文件；这不会触发源码重编译。

```powershell
$ErrorActionPreference = "Stop"

if (-not (Test-Path .\CMakeLists.txt) -or -not (Test-Path .\python\setup.py)) {
    throw "请先进入 CTranslate2 仓库根目录"
}
if (-not $env:CUDA_PATH) {
    throw "CUDA_PATH 未设置，请先安装完整的 CUDA Toolkit"
}

$repo = (Resolve-Path .).Path.Replace('\', '/')
$cuda = ($env:CUDA_PATH).Replace('\', '/')
$ct2Install = "$repo/python/ctranslate2"
$buildPython = "$repo/.venv-build/Scripts/python.exe"
if (-not (Test-Path $buildPython)) {
    throw "缺少 .venv-build，请先执行第 3 节"
}
$env:CTRANSLATE2_ROOT = $ct2Install
$env:CMAKE_BUILD_PARALLEL_LEVEL = "8"

cmake -S "$repo" -B "$repo/build" -G "Visual Studio 17 2022" -A x64 `
  -DCMAKE_BUILD_TYPE=Release `
  -DBUILD_SHARED_LIBS=ON `
  -DBUILD_CLI=OFF `
  -DBUILD_TESTS=OFF `
  -DWITH_CUDA=ON `
  -DWITH_CUDNN=ON `
  -DCUDA_DYNAMIC_LOADING=ON `
  -DWITH_MKL=OFF `
  -DWITH_DNNL=OFF `
  -DWITH_OPENBLAS=OFF `
  -DWITH_RUY=OFF `
  -DOPENMP_RUNTIME=NONE `
  -DENABLE_CPU_DISPATCH=OFF `
  -DCUDA_ARCH_LIST=Common `
  "-DCUDA_NVCC_FLAGS=-Xfatbin=-compress-all" `
  -DCMAKE_POLICY_VERSION_MINIMUM=3.5 `
  "-DCUDA_TOOLKIT_ROOT_DIR=$cuda" `
  "-DCMAKE_INSTALL_PREFIX=$ct2Install" `
  -DCMAKE_INSTALL_BINDIR=.
if ($LASTEXITCODE -ne 0) { throw "CMake 配置失败" }

cmake --build "$repo/build" --config Release --parallel 8
if ($LASTEXITCODE -ne 0) { throw "C++/CUDA 编译失败" }

cmake --install "$repo/build" --config Release
if ($LASTEXITCODE -ne 0) { throw "CMake 安装失败" }

$requiredFiles = @(
    "$ct2Install/ctranslate2.dll",
    "$ct2Install/lib/ctranslate2.lib",
    "$ct2Install/include/ctranslate2/translator.h"
)
$missingFiles = $requiredFiles | Where-Object { -not (Test-Path $_) }
if ($missingFiles) {
    $missingFiles
    throw "CMake 安装不完整"
}

Remove-Item "$repo/python/dist/*.whl" -Force -ErrorAction SilentlyContinue
Push-Location "$repo/python"
try {
    & $buildPython setup.py bdist_wheel
    if ($LASTEXITCODE -ne 0) { throw "wheel 构建失败" }
}
finally {
    Pop-Location
}

$wheel = Get-ChildItem "$repo/python/dist/*.whl" |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1
if (-not $wheel) { throw "没有生成 wheel" }

$wheelEntries = tar -tf "$($wheel.FullName)"
if (-not ($wheelEntries -match 'ctranslate2/_ext.*\.pyd$')) {
    throw "wheel 中缺少 Python 扩展 _ext.pyd"
}
if (-not ($wheelEntries -match 'ctranslate2/ctranslate2\.dll$')) {
    throw "wheel 中缺少 ctranslate2.dll"
}

$wheelEntries | Select-String 'ctranslate2/(_ext.*\.pyd|ctranslate2\.dll)$'
$wheel | Select-Object FullName, Length
```

`python/setup.py` 会从 `$CTRANSLATE2_ROOT/include` 和 `$CTRANSLATE2_ROOT/lib` 编译、链接扩展，并通过 `package_data = {"ctranslate2": ["*.dll"]}` 收集包根目录中的 `ctranslate2.dll`。

一个只有几百 KB、且不含上述 DLL/PYD 的 wheel 是不完整的。完整 wheel 的压缩大小会随编译器、GPU 架构和项目版本变化，因此以归档内容检查为准。

关键参数说明：

| 参数 | 作用 |
|---|---|
| `BUILD_SHARED_LIBS=ON` | 生成 `ctranslate2.dll` 和链接用的 `ctranslate2.lib` |
| `WITH_CUDA=ON` | 启用 CUDA 后端 |
| `WITH_CUDNN=ON` | 启用 cuDNN 后端 |
| `CUDA_DYNAMIC_LOADING=ON` | CTranslate2 在运行时动态加载部分 CUDA 库 |
| `WITH_MKL=OFF` | 不构建 MKL CPU 后端 |
| `OPENMP_RUNTIME=NONE` | 不依赖 Intel/LLVM OpenMP 运行库 |
| `ENABLE_CPU_DISPATCH=OFF` | 不构建多套 CPU 指令集分发代码 |
| `CUDA_ARCH_LIST=Common` | 为项目定义的常用 GPU 架构生成 CUDA 代码；wheel 会更大、构建更慢 |
| `CMAKE_INSTALL_PREFIX=$ct2Install` | 把头文件、导入库和运行库安装到 Python 包目录下 |
| `CMAKE_INSTALL_BINDIR=.` | 让 `ctranslate2.dll` 直接进入 `python/ctranslate2/`，以便 `setup.py` 收集它 |

如果只需要支持某一种 GPU，可以把 `Common` 改成 GPU 对应的计算能力，例如 `8.6`。这会显著减少首次编译时间和 DLL 大小，但生成的 wheel 不再通用。修改架构参数后，CMake 会只重建受该参数影响的 CUDA 目标。

## 5. 安装与运行验证

建议在另一个干净虚拟环境中测试，避免误导入源码目录或旧版本：

```powershell
python -m venv .venv-wheel-test
$testPython = (Resolve-Path .\.venv-wheel-test\Scripts\python.exe).Path
& $testPython -m pip install --force-reinstall "$($wheel.FullName)"
& $testPython -c "import ctranslate2; print(ctranslate2.__version__); print(ctranslate2.get_cuda_device_count())"
```

最终还应使用实际 CTranslate2 模型运行一次 `device="cuda"` 推理。能导入模块不代表 CUDA 推理路径一定正常。

## 6. 分发说明

当前 wheel 默认包含 CTranslate2 自身的 `ctranslate2.dll`，但不包含 CUDA/cuDNN 的 NVIDIA DLL。

由于本构建启用了 `WITH_CUDNN=ON`，目标机器至少需要能在 `PATH` 中找到匹配版本的 cuDNN 和 CUDA 运行库。常见位置是：

```text
%CUDA_PATH%\bin
```

若希望生成尽可能自包含的 wheel，可以在构建后使用 `delvewheel` 分析并打包依赖 DLL：

```powershell
python -m pip install delvewheel
python -m delvewheel show "$($wheel.FullName)"
python -m delvewheel repair "$($wheel.FullName)" --add-path "$env:CUDA_PATH\bin" --wheel-dir "$repo/python/wheelhouse"
```

分发 NVIDIA DLL 前，应自行确认对应组件的许可条款。修复后的 wheel 位于 `python/wheelhouse/`，也必须重新执行第 7、8 节的内容和运行验证。

## 7. 常见问题

### wheel 只有几百 KB

先检查：

```powershell
Test-Path "$ct2Install/ctranslate2.dll"
tar -tf "$($wheel.FullName)" | Select-String 'dll|pyd'
```

最常见原因是：

- CMake 仍使用旧缓存中的安装路径
- 配置 CMake 时不在仓库根目录，导致相对路径安装到了别处
- 没有执行 `cmake --install`
- `ctranslate2.dll` 被安装到了 `python/ctranslate2/bin`，而 `setup.py` 只收集包根目录的 `*.dll`
- 打包时没有设置 `CTRANSLATE2_ROOT`

本文使用由仓库根目录计算出的绝对路径，并通过 `CMAKE_INSTALL_BINDIR=.` 避免这些问题。

### 修改参数后仍使用旧配置

查看缓存中的实际值：

```powershell
cmake -N -LA "$repo/build" | Select-String 'CMAKE_INSTALL_PREFIX|CMAKE_INSTALL_BINDIR|WITH_CUDA|WITH_CUDNN|CUDA_ARCH_LIST'
```

只有切换 CMake 生成器、工具链，或者缓存已经损坏时，才在仓库根目录删除构建目录后重新执行第 4 节。普通源码更新和参数调整不要删除 `build/`，增量构建会自动处理：

```powershell
Remove-Item -Recurse -Force "$repo/build"
```

### 找不到 CUDA

确认 `$env:CUDA_PATH` 指向完整的 CUDA Toolkit，而不是仅包含运行库的目录：

```powershell
$env:CUDA_PATH
Test-Path "$env:CUDA_PATH/include/cuda.h"
Test-Path "$env:CUDA_PATH/lib/x64/cudart.lib"
```

### 找不到 cuDNN

CMake 在 CUDA 目录的 `include` 和 `lib/x64` 中查找 `cudnn.h` 和 `cudnn.lib`：

```powershell
Test-Path "$env:CUDA_PATH/include/cudnn.h"
Test-Path "$env:CUDA_PATH/lib/x64/cudnn.lib"
```

运行时还需要：

```powershell
Test-Path "$env:CUDA_PATH/bin/cudnn64_9.dll"
```

### `Intel OpenMP runtime libiomp5 not found`

确认配置命令包含：

```text
-DWITH_MKL=OFF -DOPENMP_RUNTIME=NONE -DENABLE_CPU_DISPATCH=OFF
```

### `Compatibility with CMake < 3.5 has been removed`

保留：

```text
-DCMAKE_POLICY_VERSION_MINIMUM=3.5
```

如果仍遇到旧式 `FindCUDA` 的兼容问题，使用 CMake 3.26～3.28 重新配置。

### 导入时报 DLL 加载失败

检查 wheel 是否包含 `ctranslate2.dll`，并检查目标环境的 CUDA/cuDNN DLL 是否可见：

```powershell
where.exe cudnn64_9.dll
where.exe nvcuda.dll
```

`nvcuda.dll` 由 NVIDIA 显卡驱动提供；CUDA Toolkit 不会替代显卡驱动。
