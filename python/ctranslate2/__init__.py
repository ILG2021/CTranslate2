import sys

if sys.platform == "win32":
    import ctypes
    import glob
    import os

    from importlib.resources import files

    module_name = sys.modules[__name__].__name__
    package_dir = str(files(module_name))

    # Keep the handles alive for as long as this module is loaded. Closing an
    # add_dll_directory handle removes the directory from the DLL search path.
    _dll_directory_handles = []
    _dll_directories = [
        package_dir,
        f"{package_dir}/../_rocm_sdk_core/bin",
        f"{package_dir}/../_rocm_sdk_libraries_custom/bin",
    ]

    for name, value in os.environ.items():
        if name == "CUDA_PATH" or name.startswith("CUDA_PATH_V"):
            _dll_directories.append(os.path.join(value, "bin"))

    # Python 3.8+ no longer uses PATH for resolving extension-module
    # dependencies. Add only PATH entries that actually contain cuDNN.
    for path in os.environ.get("PATH", "").split(os.pathsep):
        if path and os.path.isfile(os.path.join(path, "cudnn64_9.dll")):
            _dll_directories.append(path)

    for dll_directory in dict.fromkeys(map(os.path.normcase, _dll_directories)):
        try:
            _dll_directory_handles.append(os.add_dll_directory(dll_directory))
        except (FileNotFoundError, OSError):
            pass

    for library in glob.glob(os.path.join(package_dir, "*.dll")):
        ctypes.CDLL(library)

try:
    from ctranslate2._ext import (
        AsyncGenerationResult,
        AsyncScoringResult,
        AsyncTranslationResult,
        DataType,
        Device,
        Encoder,
        EncoderForwardOutput,
        ExecutionStats,
        GenerationResult,
        GenerationStepResult,
        Generator,
        MpiInfo,
        ScoringResult,
        StorageView,
        TranslationResult,
        Translator,
        contains_model,
        get_cuda_device_count,
        get_supported_compute_types,
        set_random_seed,
    )
    from ctranslate2.extensions import register_extensions
    from ctranslate2.logging import get_log_level, set_log_level

    register_extensions()
    del register_extensions
except ImportError as e:
    # Allow using the Python package without the compiled extension.
    if "No module named" in str(e):
        pass
    else:
        raise

from ctranslate2 import converters, models, specs
from ctranslate2.version import __version__
