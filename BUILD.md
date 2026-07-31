# CTranslate2 Windows CUDA Wheel 构建

构建逻辑、环境检查、错误提示和 wheel 验证都在 [build.ps1](./build.ps1) 中。

## 环境要求

- Windows x64
- Visual Studio 2022，并安装“使用 C++ 的桌面开发”工作负载
- CUDA Toolkit 12.4
- cuDNN 9.x for CUDA 12，并合并到 `%CUDA_PATH%` 的 `bin`、`include`、`lib/x64`
- CMake 3.26～3.28
- Python 3.9 或更高版本
- Git

## 构建

打开 **Developer PowerShell for VS 2022**，进入仓库根目录，只执行：

```powershell
.\build.ps1
```

如果 PowerShell 阻止本地脚本运行，可仅为当前进程放行后构建：

```powershell
Set-ExecutionPolicy -Scope Process Bypass; .\build.ps1
```

默认使用 8 个并行任务，并为常用 GPU 架构构建。可选参数：

```powershell
.\build.ps1 -Jobs 16
```

脚本会一次完成：

1. 检查 VS、CMake、CUDA、cuDNN、Git 和 Python。
2. 仅在缺失时初始化 Git 子模块和 Python 构建环境。
3. 配置 CMake，并复用已有缓存。
4. 增量编译 C++/CUDA；未更新的 `.obj` 不会重新编译。
5. 安装 `ctranslate2.dll`、头文件和导入库。
6. 增量构建 wheel。
7. 检查 wheel 同时包含 `_ext*.pyd` 和 `ctranslate2.dll`。

生成的 wheel 位于：

```text
python\dist\
```

脚本不会删除 `build/` 或 `python/build/`。只有源文件、头文件或构建参数发生变化时，相关目标才会重新编译。它只删除旧的最终 `.whl`，避免把旧文件误认为本次构建结果。

CUDA/cuDNN 自身的 NVIDIA DLL 默认不会打进 wheel，目标机器仍需安装兼容的 CUDA 和 cuDNN。
