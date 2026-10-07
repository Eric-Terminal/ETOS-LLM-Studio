import Foundation
import Testing
@testable import ETOSCore

struct ParameterExpressionRoundTripTests {
    @Test("浮点参数往返不舍入微小值，也不在整数上边界强制转换")
    func floatingPointRoundTrip() throws {
        let source: [String: JSONValue] = ["tiny": .double(1e-12), "integer": .double(1),
                                          "upper": .double(Double(Int.max)), "lower": .double(Double(Int.min)),
                                          "negative_zero": .double(-0.0)]
        let expressions = ParameterExpressionParser.serialize(parameters: source)
        let parsed = try expressions.map(ParameterExpressionParser.parse)
        #expect(ParameterExpressionParser.buildParameters(from: parsed) == source)
    }

    @Test("根键和嵌套键中的分隔符、引号及空白可以往返")
    func quotedKeysAndWhitespace() throws {
        let source: [String: JSONValue] = [
            "a=b": .dictionary(["nested,= key": .string("\n\t文本\r"), "": .bool(true)]),
            "\"quoted\"": .array([.string("\\n"), .string("true"), .null]),
            "\n spaced ": .int(1), "": .string("空键")
        ]
        let expressions = ParameterExpressionParser.serialize(parameters: source)
        let parsed = try expressions.map(ParameterExpressionParser.parse)
        #expect(ParameterExpressionParser.buildParameters(from: parsed) == source)
        #expect(try ParameterExpressionParser.parse("'a=b' = 3").key == "a=b")
    }

    @Test("非有限数不能作为请求参数，字符串形式仍可保留", arguments: ["nan", "inf", "-inf", "1e999"])
    func rejectsNonFiniteNumbers(_ value: String) throws {
        #expect(throws: ParameterExpressionParser.ParserError.self) { try ParameterExpressionParser.parse("value=\(value)") }
        #expect(try ParameterExpressionParser.parse("value=\"\(value)\"").value == .string(value))
    }
}
