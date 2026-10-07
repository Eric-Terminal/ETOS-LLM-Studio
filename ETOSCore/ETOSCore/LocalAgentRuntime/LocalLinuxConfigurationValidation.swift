import Foundation

public enum LocalLinuxConfigurationValidation {
    public static func variable(_ value: LocalLinuxEnvironmentVariable) throws -> LocalLinuxEnvironmentVariable {
        var result = value
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard LocalLinuxProcessEnvironmentProvider.isValidName(result.name), !result.value.utf8.contains(0) else {
            throw LocalLinuxConfigurationError.invalid
        }
        return result
    }

    public static func rule(_ value: LocalLinuxCommandRule) throws -> LocalLinuxCommandRule {
        var result = value
        result.name = result.name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.pattern = result.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.pattern.isEmpty else { throw LocalLinuxConfigurationError.invalid }
        if result.matchKind == .regularExpression {
            do { _ = try NSRegularExpression(pattern: result.pattern) } catch { throw LocalLinuxConfigurationError.invalid }
        }
        if result.name.isEmpty { result.name = result.pattern }
        return result
    }
}
