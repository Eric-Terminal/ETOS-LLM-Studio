# 第三方致谢与许可证

ETOS LLM Studio 的本地推理能力使用或改编了以下开源项目。感谢这些项目的作者与贡献者。

## llama.cpp

ETOS LLM Studio 使用 llama.cpp 提供 GGUF 模型加载、本地推理及相关底层能力。

MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

## iSH 与 Alpine Linux RootFS

ETOS LLM Studio 的“本地 Linux”使用 `ish-multiarch` 提供 AArch64 Linux
用户态解释执行，并随 iOS/watchOS App 内置一个固定版本的最小 Alpine
RootFS seed。App 不会默认安装 Bash、Python、Node.js、编译器或第三方 MCP
Server。

完整 iSH 项目许可证、精确 Alpine 包版本、包许可证、第三方声明、对应源码
资产索引与 SPDX SBOM 随 App 的 `LocalLinux` 资源一同分发。iSH 修改源码入口：
<https://github.com/Eric-Terminal/ish-multiarch>。

## FunASR llama.cpp runtime

ETOS LLM Studio 的本地语音转写实现改编自 FunASR llama.cpp runtime v0.1.9。

MIT License

Copyright (c) 2025 FunASR

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
