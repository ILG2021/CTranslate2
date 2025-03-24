[![CI](https://github.com/OpenNMT/CTranslate2/workflows/CI/badge.svg)](https://github.com/OpenNMT/CTranslate2/actions?query=workflow%3ACI) [![PyPI version](https://badge.fury.io/py/ctranslate2.svg)](https://badge.fury.io/py/ctranslate2) [![Documentation](https://img.shields.io/badge/docs-latest-blue.svg)](https://opennmt.net/CTranslate2/) [![Gitter](https://badges.gitter.im/OpenNMT/CTranslate2.svg)](https://gitter.im/OpenNMT/CTranslate2?utm_source=badge&utm_medium=badge&utm_campaign=pr-badge) [![Forum](https://img.shields.io/discourse/status?server=https%3A%2F%2Fforum.opennmt.net%2F)](https://forum.opennmt.net/)

# CTranslate2

|This is a fork for fixing whisper max decoding length, which is discuss on: 
https://github.com/OpenNMT/CTranslate2/issues/1856

## How to use

CUDA version: 12.4
CUDNN version: 9.6.0

For windows:

Preparation:

1. install visual studio 2022 community

2. install [intel mkl library](https://www.intel.com/content/www/us/en/developer/tools/oneapi/onemkl-download.html)

Build:

```bash
cmake -DCMAKE_BUILD_TYPE=Release `
      -DBUILD_CLI=OFF `
      -DWITH_CUDA=ON `
      -DWITH_CUDNN=ON `
      -DCUDA_DYNAMIC_LOADING=ON `
      -A x64 `
      -DCUDA_NVCC_FLAGS="-Xfatbin=-compress-all" `
      -DCUDA_ARCH_LIST="Common" ..

cmake --build . --config Release --parallel 8 --verbose
```
Then replace the ctranslate2.dll in the pip package with the new compiled one in Release folder

For linux:

```bash
cmake -DBUILD_CLI=OFF -DWITH_CUDA=ON -DWITH_CUDNN=ON -DCUDA_DYNAMIC_LOADING=ON -DCUDA_NVCC_FLAGS="-Xfatbin=-compress-all" -DCUDA_ARCH_LIST="Common" -DOPENMP_RUNTIME=NONE -DWITH_MKL=OFF ..

cmake --build . --config Release --parallel 8 --verbose
```
