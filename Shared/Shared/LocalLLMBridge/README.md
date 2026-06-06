# 本地 LLM C 桥接层

这个目录负责把 Swift 的 `LocalLLMEngine` 接到 llama.cpp。它不是 Swift Package，也不直接暴露 C++ 类型给业务层；Shared target 通过 umbrella header 引入这里的 C ABI，再由 `ETOSLocalLLMBridge.cpp` 在内部调用 llama.cpp。

## 边界

- `ETOSLocalLLMBridge.h` 是 Swift 可见的稳定 C ABI，只放 POD 结构体、函数指针和 `extern "C"` 函数声明。
- `ETOSLocalLLMBridge.cpp` 是 C ABI 出入口，只做参数检查、调用内部分层实现和内存释放。
- `ETOSLocalLLMBridgeGeneration.cpp` 负责模型缓存、上下文创建和 token 生成循环。
- `ETOSLocalLLMBridgeGenerationSupport.cpp` 负责生成配置映射、采样器创建、分词、stop 处理和流式文本输出。
- `ETOSLocalLLMBridgeChatTemplate.cpp` 负责 GGUF Jinja 聊天模板应用，以及使用 llama.cpp parser 解析工具调用响应。
- `../LocalLLM/LocalLLMChatMessageBuilder.swift` 负责结构化消息转换和工具定义组装；`../LocalLLM/LocalLLMChatTemplatePayload.swift` 负责把这些内容编码为传给 C++ 的 OpenAI 兼容 JSON。
- `../LocalLLM/LocalLLMGenerationConfig.swift` 负责解析用户输入的高级参数，并映射为 `etos_local_llm_generation_config`。不要把 CLI 字符串解析和大段参数 if-else 塞回 C++。
- `ETOSGGMLCPUArchQuants.c` 与 `ETOSGGMLCPUArchRepack.cpp` 只用于补齐预编译静态库没有直接产出的 CPU arch 源文件。

## 构建方式

llama.cpp 位于 `Dependencies/llama.cpp` 子模块。Shared 不在 Xcode 构建阶段自动编译 llama.cpp；构建 App 前需要先手动生成匹配当前 SDK 和配置的 `libetos-llama.a`，产物路径为：

```sh
Dependencies/llama-build/products/<platform>-<configuration>/libetos-llama.a
```

本机 Debug 模拟器通常只需要 Apple Silicon 架构：

```sh
SDK_NAME=iphonesimulator PLATFORM_NAME=iphonesimulator CONFIGURATION=Debug ARCHS=arm64 scripts/build-llama-static-library.sh
SDK_NAME=watchsimulator PLATFORM_NAME=watchsimulator CONFIGURATION=Debug ARCHS=arm64 scripts/build-llama-static-library.sh
```

真机 Debug：

```sh
SDK_NAME=iphoneos PLATFORM_NAME=iphoneos CONFIGURATION=Debug ARCHS=arm64 scripts/build-llama-static-library.sh
SDK_NAME=watchos PLATFORM_NAME=watchos CONFIGURATION=Debug ARCHS=arm64 scripts/build-llama-static-library.sh
```

如果 Xcode 报 `library 'etos-llama' not found`、`file not found: libetos-llama.a` 或某个平台链接不到 llama.cpp 符号，就按报错里的 SDK/Configuration 先运行对应命令，再重新构建 App。Shared 通过 `-letos-llama` 链接这个静态库。

iOS、macOS 和 visionOS 启用 `GGML_USE_METAL=1`；watchOS 和模拟器运行期强制 `n_gpu_layers = 0`，避免把不支持的 Metal 路径带进受限平台。watchOS 归档当前使用 `arm64` 设备 slice；如果后续重新支持 legacy `arm64_32`，需要重新确认静态库与 Xcode 链接架构一致。

## 修改约束

- 不在 submodule 内直接改上游源码，除非明确要维护 fork 补丁。
- 新增 C ABI 字段时要同步修改 Swift 侧镜像结构体，并保持字段顺序一致。
- C++ 返回给 Swift 的内存必须由本目录提供的 `etos_local_llm_free*` 函数释放。
- 高级参数新增时优先改 Swift 映射和对应测试，C++ 只消费结构化结果。
