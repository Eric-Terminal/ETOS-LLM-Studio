// ============================================================================
// SurveyManagerTests.swift
// ============================================================================
// 意见征集模型解码与结构化问答转换测试。
// ============================================================================

import Foundation
import Testing
@testable import ETOSCore

@Suite("意见征集模型测试")
struct SurveyManagerTests {
    @Test("服务端征集定义可转换为结构化问答")
    func testSurveyDefinitionDecodingAndInputRequest() throws {
        let data = Data(
            """
            {
              "key": "survey-key",
              "id": 2026072401,
              "title": "界面方案征集",
              "description": "选择更喜欢的布局。",
              "language": "zh-Hans",
              "platform": "iOS",
              "questions": [{
                "id": "layout",
                "question": "你更喜欢哪种布局？",
                "type": "single_select",
                "allow_other": true,
                "required": true,
                "options": [
                  {"id": "compact", "label": "紧凑"},
                  {"id": "relaxed", "label": "宽松"}
                ]
              }]
            }
            """.utf8
        )

        let survey = try JSONDecoder().decode(SurveyDefinition.self, from: data)
        let request = survey.inputRequest

        #expect(survey.key == "survey-key")
        #expect(request.requestID == "survey-key")
        #expect(request.questions.count == 1)
        #expect(request.questions[0].type == .singleSelect)
        #expect(request.questions[0].allowOther)
        #expect(request.questions[0].required)
        #expect(request.questions[0].options.map(\.id) == ["compact", "relaxed"])
    }

    @Test("省略可选布尔字段时默认关闭")
    func testSurveyQuestionOptionalFlagsDefaultToFalse() throws {
        let data = Data(
            """
            {
              "key": "survey-key",
              "id": 1,
              "title": "测试",
              "questions": [{
                "id": "choice",
                "question": "请选择",
                "type": "multi_select",
                "options": [{"id": "one", "label": "一"}]
              }]
            }
            """.utf8
        )

        let survey = try JSONDecoder().decode(SurveyDefinition.self, from: data)

        #expect(survey.questions[0].allowOther == false)
        #expect(survey.questions[0].required == false)
    }
}
