# 本地 LLM C 桥接层

这个目录负责把 Swift 的 `LocalLLMEngine` 接到 llama.cpp。它不是 Swift Package，也不直接暴露 C++ 类型给业务层；Shared target 通过 umbrella header 引入这里的 C ABI，再由 `ETOSLocalLLMBridge.cpp` 在内部调用 llama.cpp。

## 边界

- `ETOSLocalLLMBridge.h` 是 Swift 可见的稳定 C ABI，只放 POD 结构体、函数指针和 `extern "C"` 函数声明。
- `ETOSLocalLLMBridge.cpp` 是底层执行器，只负责模型加载、采样器创建、token/embedding 运行循环和内存释放。
- `../LocalLLM/LocalLLMChatMessageBuilder.swift` 负责 Prompt 渲染、工具定义 JSON 组装和工具调用解析。
- `../LocalLLM/LocalLLMGenerationConfig.swift` 负责解析用户输入的高级参数，并映射为 `etos_local_llm_generation_config`。不要把 CLI 字符串解析和大段参数 if-else 塞回 C++。
- `ETOSGGMLCPUArchQuants.c` 与 `ETOSGGMLCPUArchRepack.cpp` 只用于补齐预编译静态库没有直接产出的 CPU arch 源文件。

## 构建方式

llama.cpp 位于 `Dependencies/llama.cpp` 子模块。Xcode 构建 Shared target 前会运行 `scripts/build-llama-static-library.sh`，按当前 SDK/架构生成 `Dependencies/llama-build/products/<platform>-<configuration>/libetos-llama.a`，Shared 再通过 `-letos-llama` 链接。

iOS、macOS 和 visionOS 启用 `GGML_USE_METAL=1`；watchOS 和模拟器运行期强制 `n_gpu_layers = 0`，避免把不支持的 Metal 路径带进受限平台。watchOS 的 `arm64_32` 风险主要关注指针与整数互转，工程里保留了 `-Wpointer-to-int-cast` 与 `-Wint-to-pointer-cast` 诊断。

## 修改约束

- 不在 submodule 内直接改上游源码，除非明确要维护 fork 补丁。
- 新增 C ABI 字段时要同步修改 Swift 侧镜像结构体，并保持字段顺序一致。
- C++ 返回给 Swift 的内存必须由本目录提供的 `etos_local_llm_free*` 函数释放。
- 高级参数新增时优先改 Swift 映射和对应测试，C++ 只消费结构化结果。
