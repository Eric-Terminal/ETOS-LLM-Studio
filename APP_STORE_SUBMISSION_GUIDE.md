# ETOS LLM Studio - App Store 审核准备清单

## ✅ 已完成的关键修复

### 1. 权限配置（必须）
- ✅ **iOS App**: 已添加 `NSPhotoLibraryUsageDescription` - "需要访问相册以发送图片给AI模型"
- ✅ **iOS App**: 已添加 `NSMicrophoneUsageDescription` - "语音输入需要访问麦克风"
- ✅ **iOS App**: 已添加 `NSLocalNetworkUsageDescription` - "需要访问本地网络以提供调试服务器功能"
- ✅ **watchOS App**: 已添加 `NSMicrophoneUsageDescription` - "语音输入需要访问麦克风"
- ✅ **watchOS App**: 已添加 `NSLocalNetworkUsageDescription` - "需要访问本地网络以提供调试服务器功能"

### 2. 加密合规声明（必须）
- ✅ **iOS App**: Debug 和 Release 配置均已添加 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`
- ✅ **watchOS App**: Debug 和 Release 配置均已添加 `INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO`
- 说明：应用仅使用HTTPS/TLS标准加密，不涉及自定义加密算法

### 3. 代码清理（强烈建议）
- ✅ 已将所有 `print()` 调试语句替换为 `Logger` 或移除
- ✅ 已删除所有 `TODO` 注释
- ✅ 代码已达到生产环境标准

### 4. 隐私政策（必须）
- ✅ 已生成完整的隐私政策HTML文件：`docs/privacy-policy.html`
- ⚠️ **需要操作**：将此文件上传到 `ericterminal.com/etos-privacy.html`
- 隐私政策URL: `https://ericterminal.com/etos-privacy.html`

---

## 📋 App Store Connect 提交清单

### 基本信息
- **App 名称**: ETOS LLM Studio
- **Bundle ID (iOS)**: com.etos.ETOS-LLM-Studio-iOS-App
- **Bundle ID (watchOS)**: com.etos.ETOS-LLM-Studio-Watch.watchkitapp
- **版本号**: 1.0
- **Build 号**: 1 (iOS), 7 (watchOS)
- **主要语言**: 简体中文
- **次要语言**: 英文（可选）

### App 分类
- **主要类别**: 工具（Utilities）或 生产力（Productivity）
- **次要类别**: 开发者工具

### 定价与供应
- **价格**: 免费（建议初期）
- **供应地区**: 全球（或先选择中国+美国）

### 隐私政策
- **隐私政策URL**: `https://ericterminal.com/etos-privacy.html`
- **数据收集说明**: 
  - ✅ 不收集任何用户数据
  - ✅ API密钥仅存储在用户设备本地
  - ✅ 对话内容不上传到开发者服务器
  - ✅ 用户与第三方API提供商的通信由用户自主控制

---

## 🖼️ 截图准备

### iOS App 截图要求
需要准备以下尺寸的截图：
- **6.7英寸** (iPhone 14 Pro Max / 15 Pro Max): 1290 x 2796 像素（必需）
- **6.5英寸** (iPhone 11 Pro Max / XS Max): 1242 x 2688 像素（必需）
- **5.5英寸** (可选): 1242 x 2208 像素

建议截图内容：
1. 聊天界面 - 展示AI对话功能
2. 模型设置 - 展示提供商配置
3. 记忆管理 - 展示RAG功能
4. 会话列表 - 展示多会话管理
5. 工具调用 - 展示AI智能体功能

### watchOS App 截图要求
需要准备不同手表尺寸的截图：
- **45mm/49mm**: 396 x 484 像素
- **40mm/44mm**: 368 x 448 像素

---

## 📝 审核说明（App Review Information）

### 测试账号信息
```
API 端点: https://api.ericterminal.com/v1
API 密钥: [在这里填入你的测试令牌，确保余额充足 ≥$5]
```

### 审核备注（Notes）
```
ETOS LLM Studio 审核说明
=========================

【应用概述】
本应用是一个大语言模型（LLM）客户端，允许用户配置任何兼容 OpenAI API 格式的服务商。
应用本身不提供AI服务，所有AI功能需要用户自行配置第三方API密钥。

【测试步骤】
1. 打开应用 → 点击右上角齿轮图标进入设置
2. 选择"模型设置" → "提供商列表" → 点击右上角"+"添加提供商
3. 填写以下测试凭证：
   - 提供商名称: Test Provider
   - API 基础 URL: https://api.ericterminal.com/v1
   - API 密钥: [上面提供的测试密钥]
4. 返回聊天页面，选择刚添加的提供商
5. 发送测试消息："你好，请介绍一下你自己"
6. 等待AI回复（约3-5秒）

【关于"局域网调试"功能】
应用中包含"局域网调试"功能（设置 → 拓展功能 → 局域网调试）：
- 这是为开发者和高级用户设计的文件管理工具
- 需要手动启动，使用随机6位PIN码保护
- 仅允许访问应用自身的沙盒Documents目录
- 不涉及任何越权访问或安全漏洞
- 主要用于调试和备份应用数据

【数据隐私承诺】
- 应用不收集任何用户数据
- API密钥存储在应用沙盒中，受iOS系统文件保护机制保护
- 对话内容不会上传到开发者服务器
- 所有网络通信仅在用户与其配置的API提供商之间进行
- 详细隐私政策: https://ericterminal.com/etos-privacy.html

【技术说明】
- 应用使用HTTPS/TLS标准加密，已正确配置 ITSAppUsesNonExemptEncryption = NO
- 照片库访问仅用于发送图片给支持视觉的AI模型
- 麦克风访问仅用于语音输入功能

如有任何疑问，请通过GitHub Issues联系: 
https://github.com/Eric-Terminal/ETOS-LLM-Studio/issues
```

---

## 🎯 App 描述（App Store）

### 副标题（Subtitle，30字符以内）
```
原生AI客户端 支持所有大模型
```
或
```
Your AI Assistant on Apple Watch
```

### 描述（Description，4000字符以内）

```
ETOS LLM Studio - 功能强大的原生 AI 聊天客户端

【核心特性】

🎯 完全可定制
• 动态配置任何兼容 OpenAI API 的服务商
• 支持 OpenAI、Anthropic、Google、DeepSeek 等主流模型
• 自定义参数：Temperature、Top-P、Max Tokens 等
• API Key 轮换机制，充分利用多个免费额度

🧠 智能记忆系统
• 离线 RAG（检索增强生成）技术
• 完全在设备端进行向量化，绝对隐私
• 跨会话长期记忆，AI 记住你说过的话
• 自定义记忆检索数量

🤖 AI 智能体
• 支持工具调用（Tool Use）
• AI 可自主判断并存储重要信息
• 三层提示词系统：全局、会话、单次
• 自动生成会话标题

💬 强大的会话管理
• 多会话并行管理
• 从任意节点创建对话分支
• Markdown 渲染支持
• 消息编辑与重新生成
• 消息多版本历史记录

🖼️ 多模态支持
• 发送图片给支持视觉的模型
• 语音输入转文字
• 音频附件保存

⌚ 双端协作
• iPhone 与 Apple Watch 无缝同步
• watchOS 独立运行
• iCloud 配置同步

🔧 高级功能
• MCP（Model Context Protocol）工具集成
• 局域网调试服务器
• 完全开源（GPLv3）

【隐私承诺】
• 不收集任何用户数据
• 对话内容不上传到开发者服务器
• 完全由用户掌控数据

【开源项目】
项目完全开源，欢迎贡献：
https://github.com/Eric-Terminal/ETOS-LLM-Studio

【支持与反馈】
遇到问题？有新想法？
访问 GitHub Issues 与我们交流！
```

### 关键词（Keywords，100字符以内）
```
AI,ChatGPT,Claude,Gemini,LLM,Assistant,watchOS,OpenAI,RAG,MCP
```

### 促销文本（Promotional Text，170字符，可选）
```
🎉 首发版本上线！完全免费，无内购，无广告。支持所有主流大模型，Apple Watch 独立运行。开源项目，数据完全由你掌控！
```

---

## 📧 审核可能的问询及回复话术

### 问题1: "应用需要API密钥才能使用，这是否意味着功能不完整？"
**回复模板**:
```
Thank you for your review. 

ETOS LLM Studio is designed as a client application that allows users to connect to any OpenAI-compatible API provider of their choice. This is similar to how email clients require users to configure their email accounts, or how FTP clients require server credentials.

The app is fully functional once users add their own API provider configuration. We have provided test credentials in the App Review Notes to facilitate testing.

This design ensures:
1. Users have complete control over which AI service they use
2. No vendor lock-in
3. Maximum privacy - we don't have access to user conversations
4. Support for any compatible service (OpenAI, Anthropic, Google, self-hosted, etc.)

If you need any clarification or additional test accounts, please let us know.
```

### 问题2: "局域网调试功能可能被用于不当用途"
**回复模板**:
```
Thank you for the concern.

The "Local Network Debugging" feature is designed specifically for developers and advanced users to manage their app data. Here's why it's safe:

1. **Requires Manual Activation**: The feature is disabled by default and must be manually started by the user
2. **PIN Protection**: Uses a randomly generated 6-digit PIN for each session
3. **Sandboxed Access**: Strictly limited to the app's own Documents directory - cannot access system files or other apps' data
4. **Network Scope**: Only accessible within the user's local network (not internet-accessible)
5. **Legitimate Use Cases**: Backup/restore chat sessions, import/export configurations, debugging for developers

This is similar to other developer tools available on the App Store, such as SSH clients or file management utilities.

We can add additional warnings in the UI if needed, or provide documentation explaining the feature's purpose.
```

### 问题3: "没有服务条款（Terms of Service）"
**回复模板**:
```
ETOS LLM Studio is a free, open-source client application licensed under GPLv3. 

Since we don't provide any backend services, don't collect user data, and don't have user accounts, traditional Terms of Service are not applicable. Users interact directly with their chosen third-party API providers, whose terms apply.

However, if required, we can create a simple Terms of Use document clarifying:
- The app is provided "as-is" under GPLv3
- Users are responsible for their own API usage and costs
- Users must comply with their API provider's terms

Please let us know if this is necessary for approval.
```

---

## ⚠️ 上架前最终检查

- [ ] 隐私政策HTML已上传到 ericterminal.com
- [ ] 测试API密钥余额充足（建议 ≥$5）
- [ ] 所有截图已准备并符合尺寸要求
- [ ] App 描述、关键词已填写
- [ ] 在真机（iPhone + Apple Watch）上测试过完整流程
- [ ] 确认没有崩溃或明显bug
- [ ] Xcode Archive成功，无警告
- [ ] 已在 Xcode Organizer 中上传构建版本到 App Store Connect
- [ ] App Store Connect 中选择了正确的构建版本
- [ ] 审核备注中填写了详细的测试说明和凭证

---

## 🚀 提交步骤

1. **上传隐私政策**
   ```bash
   # 将 docs/privacy-policy.html 上传到你的服务器
   scp docs/privacy-policy.html user@ericterminal.com:/path/to/webroot/etos-privacy.html
   
   # 或使用GitHub Pages托管
   ```

2. **Archive & Upload**
   - Xcode → Product → Archive
   - Organizer → Distribute App → App Store Connect
   - 等待处理完成（10-30分钟）

3. **配置App Store Connect**
   - 登录 https://appstoreconnect.apple.com
   - 填写所有必填项（截图、描述、隐私政策URL等）
   - 选择构建版本
   - 填写审核备注和测试账号

4. **提交审核**
   - 最终检查所有信息
   - 点击"提交审核"
   - 等待审核（通常1-3天）

5. **审核通过后**
   - 选择"手动发布"或"自动发布"
   - 庆祝！🎉

---

## 📞 需要帮助？

如果审核遇到问题，可以：
1. 查看Apple的审核指南: https://developer.apple.com/app-store/review/guidelines/
2. 在App Store Connect中与审核团队沟通
3. 提交申诉（如果被拒绝）

祝你上架顺利！🚀
