// ============================================================================
// OpenAIAdapterModels.swift
// ============================================================================
// ETOS LLM Studio
//
// 承接 OpenAIAdapter 的内部解码模型与响应数据结构。
// ============================================================================

import Foundation

extension OpenAIAdapter {
    struct OpenAIToolCall: Decodable {
        let id: String?
        let type: String
        let index: Int?
        let providerSpecificFields: [String: JSONValue]?
        struct Function: Decodable {
            let name: String?
            let arguments: String?
        }
        let function: Function

        enum CodingKeys: String, CodingKey {
            case id
            case type
            case index
            case function
            case providerSpecificFields
            case provider_specific_fields
            case extraContent
            case extra_content
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decodeIfPresent(String.self, forKey: .id)
            type = try container.decode(String.self, forKey: .type)
            index = try container.decodeIfPresent(Int.self, forKey: .index)
            function = try container.decode(Function.self, forKey: .function)
            var mergedProviderSpecificFields = try container.decodeIfPresent([String: JSONValue].self, forKey: .providerSpecificFields)
                ?? (try container.decodeIfPresent([String: JSONValue].self, forKey: .provider_specific_fields))
                ?? [:]
            let extraContent = try container.decodeIfPresent([String: JSONValue].self, forKey: .extraContent)
                ?? (try container.decodeIfPresent([String: JSONValue].self, forKey: .extra_content))
            if let extraContent,
               let googleValue = extraContent["google"],
               case let .dictionary(googleDict) = googleValue,
               let thoughtSignatureValue = googleDict["thought_signature"],
               case let .string(thoughtSignature) = thoughtSignatureValue,
               !thoughtSignature.isEmpty {
                mergedProviderSpecificFields["thought_signature"] = .string(thoughtSignature)
            }
            providerSpecificFields = mergedProviderSpecificFields.isEmpty ? nil : mergedProviderSpecificFields
        }
    }

    struct OpenAIResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let role: String?
                let content: String?
                let tool_calls: [OpenAIToolCall]?
                let reasoning_content: String?
            }
            let message: Message?
            let delta: Message?
        }
        let choices: [Choice]
        struct Usage: Decodable {
            struct PromptTokensDetails: Decodable {
                let cached_tokens: Int?
            }
            struct CompletionTokensDetails: Decodable {
                let reasoning_tokens: Int?
            }
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
            let prompt_tokens_details: PromptTokensDetails?
            let completion_tokens_details: CompletionTokensDetails?
        }
        let usage: Usage?
    }

    struct OpenAITranscriptionResponse: Decodable {
        let text: String
    }

    struct OpenAIEmbeddingResponse: Decodable {
        struct DataEntry: Decodable {
            let embedding: [Double]
        }
        let data: [DataEntry]
    }

    struct OpenAIImageResponse: Decodable {
        struct DataEntry: Decodable {
            let b64_json: String?
            let url: String?
            let revised_prompt: String?
        }
        let data: [DataEntry]
    }
    
    struct OpenAIFileUploadResponse: Decodable {
        let id: String
        let object: String?
    }
    
    struct OpenAIBatchJobResponse: Decodable {
        let id: String
        let status: String
        let input_file_id: String?
        let output_file_id: String?
        let error_file_id: String?
        let endpoint: String?
    }
}
