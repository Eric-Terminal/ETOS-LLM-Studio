// ============================================================================
// ChatServiceImageGeneration.swift
// ============================================================================
// ETOS LLM Studio
//
// 负责 ChatService 的图片生成入口、图片结果解析与生成后消息落盘。
// ============================================================================

import Foundation
import Combine
import os.log

extension ChatService {
    public func generateImageAndProcessMessage(
        prompt: String,
        imageAttachments: [ImageAttachment] = [],
        runnableModel: RunnableModel? = nil,
        runtimeOverrideParameters: [String: JSONValue] = [:]
    ) async {
        guard var currentSession = currentSessionSubject.value else {
            let reason = NSLocalizedString("错误: 没有当前会话。", comment: "No current session error")
            addErrorMessage(reason)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: nil,
                    loadingMessageID: nil,
                    prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines),
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            let reason = NSLocalizedString("错误: 生图提示词不能为空。", comment: "Image generation prompt empty")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        guard let runnableModel = runnableModel ?? selectedModelSubject.value else {
            let reason = NSLocalizedString("错误: 没有选中的可用模型。请在设置中激活一个模型。", comment: "No active model error")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        logger.info(
            "开始生图流程: session=\(currentSession.id.uuidString), provider=\(runnableModel.provider.name), model=\(runnableModel.model.displayName), promptLength=\(trimmedPrompt.count), referenceCount=\(imageAttachments.count), runtimeOverrideCount=\(runtimeOverrideParameters.count)"
        )

        guard let adapter = adapters[runnableModel.provider.apiFormat] else {
            let reason = String(
                format: NSLocalizedString("错误: 找不到适用于 '%@' 格式的 API 适配器。", comment: "Missing API adapter error"),
                runnableModel.provider.apiFormat
            )
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        guard runnableModel.model.supportsImageGeneration else {
            let reason = NSLocalizedString("当前模型不可用于生图，请在模型设置中将用途设为图片生成，或在模型能力中开启可生成图片。", comment: "模型没有生图能力提示")
            addErrorMessage(reason, sessionID: currentSession.id)
            requestStatusSubject.send(.error)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSession.id,
                    loadingMessageID: nil,
                    prompt: trimmedPrompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        var savedImageFileNames: [String] = []
        for imageAttachment in imageAttachments {
            var targetName = imageAttachment.fileName
            if targetName.isEmpty {
                targetName = "\(UUID().uuidString).jpg"
            }
            if Persistence.imageFileExists(fileName: targetName) {
                let ext = (targetName as NSString).pathExtension
                let stem = (targetName as NSString).deletingPathExtension
                let suffix = UUID().uuidString.prefix(8)
                targetName = ext.isEmpty ? "\(stem)_\(suffix)" : "\(stem)_\(suffix).\(ext)"
            }
            if Persistence.saveImage(imageAttachment.data, fileName: targetName) != nil {
                savedImageFileNames.append(targetName)
                logger.info("生图参考图已保存: \(targetName)")
            } else {
                logger.error("生图参考图保存失败: \(targetName)")
            }
        }

        let userMessage = ChatMessage(
            role: .user,
            content: trimmedPrompt,
            requestedAt: Date(),
            imageFileNames: savedImageFileNames.isEmpty ? nil : savedImageFileNames
        )
        let loadingMessage = ChatMessage(
            role: .assistant,
            content: "",
            requestedAt: Date()
        )

        var messages = messagesSnapshot(for: currentSession.id)
        messages.append(userMessage)
        messages.append(loadingMessage)
        persistAndPublishMessages(messages, for: currentSession.id)
        scheduleUserMessageAchievementDetectionIfNeeded(
            content: trimmedPrompt,
            userMessageCount: messages.filter { $0.role == .user }.count,
            sentAt: userMessage.requestedAt ?? Date(),
            previousAssistantReply: latestAssistantReply(in: currentSession.id)
        )
        logger.info("生图占位消息已创建: loadingMessageID=\(loadingMessage.id.uuidString)")

        if currentSession.isTemporary {
            currentSession.name = String(trimmedPrompt.prefix(20))
            currentSession.isTemporary = false
            currentSessionSubject.send(currentSession)
            var updatedSessions = chatSessionsSubject.value
            if let index = updatedSessions.firstIndex(where: { $0.id == currentSession.id }) {
                updatedSessions[index] = currentSession
            }
            chatSessionsSubject.send(updatedSessions)
            Persistence.saveChatSessions(updatedSessions)
            logger.info("生图请求已跳过自动标题生成: session=\(currentSession.id.uuidString)")
        } else {
            promoteSessionToTopIfNeeded(sessionID: currentSession.id)
        }

        emitSessionRequestStatus(.started, sessionID: currentSession.id)
        imageGenerationStatusSubject.send(
            .started(
                sessionID: currentSession.id,
                loadingMessageID: loadingMessage.id,
                prompt: trimmedPrompt,
                startedAt: Date(),
                referenceCount: imageAttachments.count
            )
        )
        logger.info("生图请求即将发送: session=\(currentSession.id.uuidString)")

        let requestToken = UUID()
        setRequestContext(
            RequestExecutionContext(
                token: requestToken,
                task: nil,
                loadingMessageID: loadingMessage.id,
                imageGenerationContext: ImageGenerationContext(
                    sessionID: currentSession.id,
                    loadingMessageID: loadingMessage.id,
                    prompt: trimmedPrompt
                )
            ),
            for: currentSession.id
        )

        let requestTask = Task<Void, Error> { [weak self] in
            guard let self else { return }
            var effectiveModel = runnableModel.model
            if !runtimeOverrideParameters.isEmpty {
                effectiveModel.overrideParameters = effectiveModel.overrideParameters.merging(runtimeOverrideParameters) { _, runtime in
                    runtime
                }
            }
            let effectiveRunnableModel = RunnableModel(provider: runnableModel.provider, model: effectiveModel)
            await self.executeImageGenerationRequest(
                adapter: adapter,
                runnableModel: effectiveRunnableModel,
                prompt: trimmedPrompt,
                referenceImages: imageAttachments,
                loadingMessageID: loadingMessage.id,
                currentSessionID: currentSession.id
            )
        }
        updateRequestTask(requestTask, for: currentSession.id, token: requestToken)

        defer {
            clearRequestContextIfNeeded(for: currentSession.id, token: requestToken)
        }

        do {
            try await requestTask.value
        } catch is CancellationError {
            logger.info("生图请求已被用户取消。")
        } catch {
            if isCancellationError(error) {
                logger.info("生图请求已被用户取消 (URLError)。")
            } else {
                logger.error("生图请求执行过程中出现未预期错误: \(error.localizedDescription)")
            }
        }
    }

    func shouldRouteMessageToImageGeneration(using runnableModel: RunnableModel) -> Bool {
        runnableModel.model.supportsImageGeneration
    }

    private func executeImageGenerationRequest(
        adapter: APIAdapter,
        runnableModel: RunnableModel,
        prompt: String,
        referenceImages: [ImageAttachment],
        loadingMessageID: UUID,
        currentSessionID: UUID
    ) async {
        logger.info(
            "构建生图请求: session=\(currentSessionID.uuidString), model=\(runnableModel.model.modelName), referenceCount=\(referenceImages.count)"
        )
        if let configurationError = providerConfigurationValidationErrorMessage(
            for: runnableModel.provider,
            action: NSLocalizedString("发送生图请求", comment: "Send image generation request action")
        ) {
            addErrorMessage(configurationError, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    reason: configurationError,
                    finishedAt: Date()
                )
            )
            return
        }

        guard let request = adapter.buildImageGenerationRequest(
            for: runnableModel,
            prompt: prompt,
            referenceImages: referenceImages
        ) else {
            logger.error("生图请求构建失败: session=\(currentSessionID.uuidString)")
            let reason = NSLocalizedString("错误: 无法构建生图请求。", comment: "Failed to build image generation request")
            addErrorMessage(reason, sessionID: currentSessionID)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    reason: reason,
                    finishedAt: Date()
                )
            )
            return
        }

        logger.info("生图请求构建成功: method=\(request.httpMethod ?? "POST"), url=\(request.url?.absoluteString ?? "unknown")")

        do {
            logger.info("生图请求发送中: session=\(currentSessionID.uuidString)")
            let data = try await fetchData(for: request, provider: runnableModel.provider)
            logger.info("生图响应已返回: session=\(currentSessionID.uuidString), bytes=\(data.count)")
            let imageResults = try adapter.parseImageGenerationResponse(data: data)
            logger.info("生图响应解析完成: session=\(currentSessionID.uuidString), results=\(imageResults.count)")

            var generatedImageFileNames: [String] = []
            var revisedPrompts: [String] = []

            for (index, result) in imageResults.enumerated() {
                if let revised = result.revisedPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !revised.isEmpty {
                    revisedPrompts.append(revised)
                    logger.info("生图结果[\(index)] 包含 revised prompt: length=\(revised.count)")
                }

                guard let payload = try await resolveGeneratedImagePayload(from: result, provider: runnableModel.provider) else {
                    logger.warning("生图结果[\(index)] 未解析到有效图片数据，已跳过。")
                    continue
                }

                logger.info("生图结果[\(index)] 图片负载就绪: mime=\(payload.mimeType), bytes=\(payload.data.count)")

                let ext = imageFileExtension(for: payload.mimeType)
                let fileName = "\(UUID().uuidString).\(ext)"
                if Persistence.saveImage(payload.data, fileName: fileName) != nil {
                    generatedImageFileNames.append(fileName)
                    logger.info("生图结果[\(index)] 已保存图片: \(fileName)")
                } else {
                    logger.error("生图结果[\(index)] 保存图片失败: \(fileName)")
                }
            }

            guard !generatedImageFileNames.isEmpty else {
                logger.error("生图响应中没有可保存图片: session=\(currentSessionID.uuidString)")
                let reason = NSLocalizedString("生图响应中没有可保存的图片。", comment: "No generated image could be saved")
                addErrorMessage(reason, sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                imageGenerationStatusSubject.send(
                    .failed(
                        sessionID: currentSessionID,
                        loadingMessageID: loadingMessageID,
                        prompt: prompt,
                        reason: reason,
                        finishedAt: Date()
                    )
                )
                return
            }

            let revisedPrompt = revisedPrompts.first(where: { !$0.isEmpty })
            let content = revisedPrompt ?? NSLocalizedString("[图片]", comment: "Image message placeholder")

            var messages = messagesSnapshot(for: currentSessionID)
            if let loadingIndex = messages.firstIndex(where: { $0.id == loadingMessageID }) {
                messages[loadingIndex] = ChatMessage(
                    id: messages[loadingIndex].id,
                    role: .assistant,
                    content: content,
                    imageFileNames: generatedImageFileNames
                )
                persistAndPublishMessages(messages, for: currentSessionID)
                logger.info(
                    "生图消息已落盘: session=\(currentSessionID.uuidString), loadingMessageID=\(loadingMessageID.uuidString), imageCount=\(generatedImageFileNames.count)"
                )
            } else {
                logger.warning("未找到生图占位消息，无法替换: loadingMessageID=\(loadingMessageID.uuidString)")
            }

            emitSessionRequestStatus(.finished, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .succeeded(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    imageFileNames: generatedImageFileNames,
                    finishedAt: Date()
                )
            )
            logger.info("生图流程完成: session=\(currentSessionID.uuidString), imageCount=\(generatedImageFileNames.count)")
        } catch is CancellationError {
            logger.info("生图请求在处理中被取消。")
        } catch NetworkError.badStatusCode(let code, let bodyData) {
            let snippet = responseBodySnippet(from: bodyData)
            logger.error("生图请求失败(HTTP \(code)): \(snippet)")
            addErrorMessage(snippet, sessionID: currentSessionID, httpStatusCode: code)
            emitSessionRequestStatus(.error, sessionID: currentSessionID)
            imageGenerationStatusSubject.send(
                .failed(
                    sessionID: currentSessionID,
                    loadingMessageID: loadingMessageID,
                    prompt: prompt,
                    reason: snippet,
                    finishedAt: Date()
                )
            )
        } catch {
            if isCancellationError(error) {
                logger.info("生图请求在处理中被取消 (URLError)。")
            } else {
                logger.error("生图请求失败: \(error.localizedDescription)")
                let reason = String(
                    format: NSLocalizedString("生图请求失败: %@", comment: "Image generation request failed with reason"),
                    error.localizedDescription
                )
                addErrorMessage(reason, sessionID: currentSessionID)
                emitSessionRequestStatus(.error, sessionID: currentSessionID)
                imageGenerationStatusSubject.send(
                    .failed(
                        sessionID: currentSessionID,
                        loadingMessageID: loadingMessageID,
                        prompt: prompt,
                        reason: reason,
                        finishedAt: Date()
                    )
                )
            }
        }
    }

    private func resolveGeneratedImagePayload(
        from result: GeneratedImageResult,
        provider: Provider
    ) async throws -> (data: Data, mimeType: String)? {
        if let imageData = result.data, !imageData.isEmpty {
            let mimeType = (result.mimeType?.isEmpty == false ? result.mimeType! : detectImageMimeType(from: imageData))
            logger.info("生图结果使用内联图片数据: mime=\(mimeType), bytes=\(imageData.count)")
            return (imageData, mimeType)
        }

        guard let remoteURL = result.remoteURL else { return nil }
        logger.info("生图结果改为下载远端图片: \(remoteURL.absoluteString)")

        var request = URLRequest(url: remoteURL)
        request.httpMethod = "GET"
        let (data, response) = try await requestData(for: request, provider: provider)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            logger.error("下载生图结果失败: status=\(httpResponse.statusCode), url=\(remoteURL.absoluteString)")
            throw NetworkError.badStatusCode(code: httpResponse.statusCode, responseBody: data.isEmpty ? nil : data)
        }
        guard !data.isEmpty else {
            logger.warning("下载生图结果返回空数据: \(remoteURL.absoluteString)")
            return nil
        }
        let mimeType = result.mimeType ?? response.mimeType ?? detectImageMimeType(from: data)
        logger.info("下载生图结果成功: mime=\(mimeType), bytes=\(data.count)")
        return (data, mimeType)
    }
}
