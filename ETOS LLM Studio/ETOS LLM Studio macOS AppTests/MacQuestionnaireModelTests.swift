import ETOSCore
import Testing
@testable import ETOS_LLM_Studio_macOS_App

@MainActor
struct MacQuestionnaireModelTests {
    @Test("必答问题有答案后才能提交，单选自定义文本会清除选项")
    func requiredAnswerAndCustomText() async throws {
        let question = AppToolAskUserInputQuestion(
            id: "q", question: "选择格式", type: .singleSelect,
            options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")],
            allowOther: true, required: true
        )
        let request = AppToolAskUserInputRequest(requestID: "q1", title: nil, description: nil, submitLabel: "提交", questions: [question])
        let model = MacQuestionnaireModel(request: request)
        await model.prepare()
        #expect(!model.canSubmit)
        model.select("a", selected: true, for: question)
        model.select("b", selected: true, for: question)
        #expect(model.selections[question.id] == ["b"])
        #expect(model.canSubmit)
        model.setCustomText("  自定义  ", for: question)
        #expect(model.selections[question.id]?.isEmpty == true)
        #expect(model.customTextBlocksSelection.contains(question.id))
        model.select("a", selected: true, for: question)
        #expect(model.selections[question.id]?.isEmpty == true)
        let answers = try #require(await model.makeAnswers(cancelled: false))
        #expect(answers.first?.otherText == "自定义")
        #expect(answers.first?.selectedOptionIDs.isEmpty == true)
        let duplicate = await model.makeAnswers(cancelled: false)
        #expect(duplicate == nil)
    }

    @Test("多选允许附加说明，重新显示时保持已填答案")
    func multipleAnswersSurvivePreparation() async throws {
        let question = AppToolAskUserInputQuestion(
            id: "q", question: "选择内容", type: .multiSelect,
            options: [.init(id: "a", label: "A"), .init(id: "b", label: "B")],
            allowOther: true, required: false
        )
        let request = AppToolAskUserInputRequest(requestID: "q2", title: nil, description: nil, submitLabel: "提交", questions: [question])
        let model = MacQuestionnaireModel(request: request)
        await model.prepare()
        #expect(model.canSubmit)
        model.select("b", selected: true, for: question)
        model.select("a", selected: true, for: question)
        model.setCustomText("补充", for: question)
        await model.prepare()
        let answers = try #require(await model.makeAnswers(cancelled: false))
        #expect(answers.first?.selectedOptionIDs == ["a", "b"])
        #expect(answers.first?.otherText == "补充")
    }
}
