// ============================================================================
// MCPBuiltInPersonalDataHealth.swift
// ============================================================================
// ETOS LLM Studio
//
// HealthKit 类型注册表与读写执行器。
// 任何授权请求都只发生在具体工具调用时，并且只请求本次类型所需权限。
// ============================================================================

import Foundation
#if canImport(HealthKit)
import HealthKit
#endif

actor MCPBuiltInPersonalDataHealthExecutor {
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        #if canImport(HealthKit)
        switch toolName {
        case "health.list_types":
            return try await listTypes()
        case "health.query_samples":
            return try await querySamples(arguments: arguments)
        case "health.query_statistics":
            return try await queryStatistics(arguments: arguments)
        case "health.write_quantity":
            return try await writeQuantity(arguments: arguments)
        case "health.write_category":
            return try await writeCategory(arguments: arguments)
        default:
            throw MCPBuiltInPersonalDataError.unsupportedTool(toolName)
        }
        #else
        throw MCPBuiltInPersonalDataError.unavailable(NSLocalizedString("当前平台没有 HealthKit。", comment: "HealthKit unavailable"))
        #endif
    }
}

#if canImport(HealthKit)
private extension MCPBuiltInPersonalDataHealthExecutor {
    var store: HKHealthStore {
        HKHealthStore()
    }

    func listTypes() async throws -> [String: Any] {
        [
            "provider": "etos_builtin_personal_data",
            "tool_name": "health.list_types",
            "types": HealthDataTypeRegistry.all.map(\.dictionary),
            "permission_model": NSLocalizedString("工具正式调用时按单个 HealthKit 类型申请读取或写入权限。", comment: "HealthKit permission model")
        ]
    }

    func querySamples(arguments: [String: Any]) async throws -> [String: Any] {
        let typeID = try arguments.personalDataRequiredString("type")
        let startDate = try arguments.personalDataRequiredDate("start_date")
        let endDate = try arguments.personalDataRequiredDate("end_date")
        let limit = min(max(arguments.personalDataInt("limit") ?? 100, 1), 500)
        let type = try HealthDataTypeRegistry.type(for: typeID)

        guard type.canRead else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("%@ 不支持读取。", comment: "HealthKit type cannot be read"), type.id)
            )
        }
        try await requestAuthorization(read: [type.objectType()], share: [])

        switch type.kind {
        case .quantity:
            let samples = try await quantitySamples(type: type, startDate: startDate, endDate: endDate, limit: limit)
            return baseResult(toolName: "health.query_samples", type: type, startDate: startDate, endDate: endDate, items: samples)
        case .category:
            let samples = try await categorySamples(type: type, startDate: startDate, endDate: endDate, limit: limit)
            return baseResult(toolName: "health.query_samples", type: type, startDate: startDate, endDate: endDate, items: samples)
        case .workout:
            let samples = try await workoutSamples(startDate: startDate, endDate: endDate, limit: limit)
            return baseResult(toolName: "health.query_samples", type: type, startDate: startDate, endDate: endDate, items: samples)
        }
    }

    func queryStatistics(arguments: [String: Any]) async throws -> [String: Any] {
        let typeID = try arguments.personalDataRequiredString("type")
        let startDate = try arguments.personalDataRequiredDate("start_date")
        let endDate = try arguments.personalDataRequiredDate("end_date")
        let type = try HealthDataTypeRegistry.type(for: typeID)
        guard type.kind == .quantity else {
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("只有数值类型支持统计查询。", comment: "HealthKit statistics requires quantity type"))
        }
        guard type.canRead else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("%@ 不支持读取。", comment: "HealthKit type cannot be read"), type.id)
            )
        }
        let aggregation = arguments.personalDataString("aggregation")
        let option = try statisticsOption(for: aggregation, type: type)
        try await requestAuthorization(read: [type.objectType()], share: [])

        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate])
        let quantityType = try type.quantityType()
        let statistics: HKStatistics? = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HKStatistics?, Error>) in
            let query = HKStatisticsQuery(
                quantityType: quantityType,
                quantitySamplePredicate: predicate,
                options: option
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: statistics)
                }
            }
            store.execute(query)
        }

        let quantity: HKQuantity?
        if option.contains(.cumulativeSum) {
            quantity = statistics?.sumQuantity()
        } else if option.contains(.discreteMin) {
            quantity = statistics?.minimumQuantity()
        } else if option.contains(.discreteMax) {
            quantity = statistics?.maximumQuantity()
        } else {
            quantity = statistics?.averageQuantity()
        }

        var result = baseResult(toolName: "health.query_statistics", type: type, startDate: startDate, endDate: endDate, items: [])
        result["aggregation"] = aggregation ?? type.defaultAggregation.rawValue
        result["value"] = quantity?.doubleValue(for: type.unit)
        result["unit"] = type.unitLabel
        result["source_count"] = statistics?.sources?.count ?? NSNull()
        return result
    }

    func writeQuantity(arguments: [String: Any]) async throws -> [String: Any] {
        let typeID = try arguments.personalDataRequiredString("type")
        let value = try arguments.personalDataRequiredDouble("value")
        let type = try HealthDataTypeRegistry.type(for: typeID)
        guard type.kind == .quantity, type.canWrite else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("%@ 不支持通过此工具写入。", comment: "HealthKit type cannot be written"), type.id)
            )
        }

        let startDate = try arguments.personalDataDate("start_date") ?? Date()
        let endDate = try arguments.personalDataDate("end_date") ?? startDate
        let quantityType = try type.quantityType()
        let sample = HKQuantitySample(
            type: quantityType,
            quantity: HKQuantity(unit: type.unit, doubleValue: value),
            start: startDate,
            end: endDate,
            metadata: metadata(note: arguments.personalDataString("note"))
        )
        try await requestAuthorization(read: [], share: [type.sampleType()])
        try await store.save(sample)

        var result = baseWriteResult(toolName: "health.write_quantity", type: type, startDate: startDate, endDate: endDate)
        result["value"] = value
        result["unit"] = type.unitLabel
        result["sample_uuid"] = sample.uuid.uuidString
        return result
    }

    func writeCategory(arguments: [String: Any]) async throws -> [String: Any] {
        let typeID = try arguments.personalDataRequiredString("type")
        let type = try HealthDataTypeRegistry.type(for: typeID)
        guard type.kind == .category, type.canWrite else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("%@ 不支持通过此工具写入。", comment: "HealthKit type cannot be written"), type.id)
            )
        }

        let startDate = try arguments.personalDataDate("start_date") ?? Date()
        let endDate = try resolvedCategoryEndDate(arguments: arguments, startDate: startDate)
        let value = try type.categoryValue(from: arguments.personalDataString("value"))
        let categoryType = try type.categoryType()
        let sample = HKCategorySample(
            type: categoryType,
            value: value,
            start: startDate,
            end: endDate,
            metadata: metadata(note: arguments.personalDataString("note"))
        )
        try await requestAuthorization(read: [], share: [type.sampleType()])
        try await store.save(sample)

        var result = baseWriteResult(toolName: "health.write_category", type: type, startDate: startDate, endDate: endDate)
        result["value"] = type.categoryValueName(value)
        result["raw_value"] = value
        result["sample_uuid"] = sample.uuid.uuidString
        return result
    }

    func quantitySamples(type: HealthDataTypeRegistry.Entry, startDate: Date, endDate: Date, limit: Int) async throws -> [[String: Any]] {
        let samples = try await samples(
            sampleType: type.sampleType(),
            startDate: startDate,
            endDate: endDate,
            limit: limit
        )
        return samples.compactMap { sample in
            guard let quantitySample = sample as? HKQuantitySample else { return nil }
            return [
                "uuid": quantitySample.uuid.uuidString,
                "start_date": MCPBuiltInPersonalDataDateCodec.string(quantitySample.startDate) ?? "",
                "end_date": MCPBuiltInPersonalDataDateCodec.string(quantitySample.endDate) ?? "",
                "value": quantitySample.quantity.doubleValue(for: type.unit),
                "unit": type.unitLabel,
                "source": quantitySample.sourceRevision.source.name
            ]
        }
    }

    func categorySamples(type: HealthDataTypeRegistry.Entry, startDate: Date, endDate: Date, limit: Int) async throws -> [[String: Any]] {
        let samples = try await samples(
            sampleType: type.sampleType(),
            startDate: startDate,
            endDate: endDate,
            limit: limit
        )
        return samples.compactMap { sample in
            guard let categorySample = sample as? HKCategorySample else { return nil }
            return [
                "uuid": categorySample.uuid.uuidString,
                "start_date": MCPBuiltInPersonalDataDateCodec.string(categorySample.startDate) ?? "",
                "end_date": MCPBuiltInPersonalDataDateCodec.string(categorySample.endDate) ?? "",
                "value": type.categoryValueName(categorySample.value),
                "raw_value": categorySample.value,
                "duration_seconds": categorySample.endDate.timeIntervalSince(categorySample.startDate),
                "source": categorySample.sourceRevision.source.name
            ]
        }
    }

    func workoutSamples(startDate: Date, endDate: Date, limit: Int) async throws -> [[String: Any]] {
        let samples = try await samples(
            sampleType: HKObjectType.workoutType(),
            startDate: startDate,
            endDate: endDate,
            limit: limit
        )
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout else { return nil }
            return [
                "uuid": workout.uuid.uuidString,
                "start_date": MCPBuiltInPersonalDataDateCodec.string(workout.startDate) ?? "",
                "end_date": MCPBuiltInPersonalDataDateCodec.string(workout.endDate) ?? "",
                "duration_seconds": workout.duration,
                "activity_type": workoutActivityName(workout.workoutActivityType),
                "activity_raw_value": workout.workoutActivityType.rawValue,
                "total_energy_kcal": workout.totalEnergyBurned?.doubleValue(for: .kilocalorie()) ?? NSNull(),
                "total_distance_meters": workout.totalDistance?.doubleValue(for: .meter()) ?? NSNull(),
                "source": workout.sourceRevision.source.name
            ]
        }
    }

    func samples(sampleType: HKSampleType, startDate: Date, endDate: Date, limit: Int) async throws -> [HKSample] {
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: [.strictStartDate])
        let sort = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[HKSample], Error>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [sort]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }

    func requestAuthorization(read: Set<HKObjectType>, share: Set<HKSampleType>) async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw MCPBuiltInPersonalDataError.unavailable(NSLocalizedString("此设备不支持 HealthKit。", comment: "HealthKit unavailable on device"))
        }
        try await store.requestAuthorization(toShare: share, read: read)
    }

    func statisticsOption(for aggregation: String?, type: HealthDataTypeRegistry.Entry) throws -> HKStatisticsOptions {
        switch aggregation ?? type.defaultAggregation.rawValue {
        case "sum":
            return .cumulativeSum
        case "average":
            return .discreteAverage
        case "min":
            return .discreteMin
        case "max":
            return .discreteMax
        default:
            throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("aggregation 必须是 sum、average、min 或 max。", comment: "Invalid HealthKit aggregation"))
        }
    }

    func resolvedCategoryEndDate(arguments: [String: Any], startDate: Date) throws -> Date {
        if let endDate = try arguments.personalDataDate("end_date") {
            return endDate
        }
        if let minutes = arguments.personalDataDouble("duration_minutes") {
            return startDate.addingTimeInterval(minutes * 60)
        }
        return startDate
    }

    func metadata(note: String?) -> [String: Any]? {
        guard let note, !note.isEmpty else { return nil }
        return [
            HKMetadataKeyExternalUUID: UUID().uuidString,
            "ETOSNote": note
        ]
    }

    func baseResult(
        toolName: String,
        type: HealthDataTypeRegistry.Entry,
        startDate: Date,
        endDate: Date,
        items: [[String: Any]]
    ) -> [String: Any] {
        [
            "provider": "etos_builtin_personal_data",
            "tool_name": toolName,
            "type": type.id,
            "type_title": type.localizedTitle,
            "start_date": MCPBuiltInPersonalDataDateCodec.string(startDate) ?? "",
            "end_date": MCPBuiltInPersonalDataDateCodec.string(endDate) ?? "",
            "items": items,
            "count": items.count
        ]
    }

    func baseWriteResult(
        toolName: String,
        type: HealthDataTypeRegistry.Entry,
        startDate: Date,
        endDate: Date
    ) -> [String: Any] {
        [
            "provider": "etos_builtin_personal_data",
            "tool_name": toolName,
            "type": type.id,
            "type_title": type.localizedTitle,
            "start_date": MCPBuiltInPersonalDataDateCodec.string(startDate) ?? "",
            "end_date": MCPBuiltInPersonalDataDateCodec.string(endDate) ?? "",
            "saved": true
        ]
    }

    func workoutActivityName(_ type: HKWorkoutActivityType) -> String {
        switch type {
        case .running: return "running"
        case .walking: return "walking"
        case .cycling: return "cycling"
        case .swimming: return "swimming"
        case .hiking: return "hiking"
        case .yoga: return "yoga"
        case .traditionalStrengthTraining: return "strength_training"
        case .functionalStrengthTraining: return "functional_strength_training"
        case .mindAndBody: return "mind_and_body"
        case .other: return "other"
        default: return "activity_\(type.rawValue)"
        }
    }
}

private enum HealthDataTypeRegistry {
    enum Kind: String {
        case quantity
        case category
        case workout
    }

    enum DefaultAggregation: String {
        case sum
        case average
    }

    struct Entry {
        let id: String
        let title: String
        let kind: Kind
        let quantityIdentifier: HKQuantityTypeIdentifier?
        let categoryIdentifier: HKCategoryTypeIdentifier?
        let unit: HKUnit
        let unitLabel: String
        let canRead: Bool
        let canWrite: Bool
        let defaultAggregation: DefaultAggregation

        var localizedTitle: String {
            NSLocalizedString(title, comment: "HealthKit type title")
        }

        var dictionary: [String: Any] {
            [
                "id": id,
                "title": localizedTitle,
                "kind": kind.rawValue,
                "unit": unitLabel,
                "can_read": canRead,
                "can_write": canWrite,
                "default_aggregation": defaultAggregation.rawValue
            ]
        }

        func objectType() throws -> HKObjectType {
            switch kind {
            case .quantity:
                return try quantityType()
            case .category:
                return try categoryType()
            case .workout:
                return HKObjectType.workoutType()
            }
        }

        func sampleType() throws -> HKSampleType {
            let objectType = try objectType()
            guard let sampleType = objectType as? HKSampleType else {
                throw MCPBuiltInPersonalDataError.invalidArgument(NSLocalizedString("HealthKit 类型不是样本类型。", comment: "HealthKit type is not a sample type"))
            }
            return sampleType
        }

        func quantityType() throws -> HKQuantityType {
            guard let quantityIdentifier,
                  let type = HKObjectType.quantityType(forIdentifier: quantityIdentifier) else {
                throw MCPBuiltInPersonalDataError.invalidArgument(
                    String(format: NSLocalizedString("系统不支持 HealthKit 数值类型：%@", comment: "Unsupported HealthKit quantity type"), id)
                )
            }
            return type
        }

        func categoryType() throws -> HKCategoryType {
            guard let categoryIdentifier,
                  let type = HKObjectType.categoryType(forIdentifier: categoryIdentifier) else {
                throw MCPBuiltInPersonalDataError.invalidArgument(
                    String(format: NSLocalizedString("系统不支持 HealthKit 分类类型：%@", comment: "Unsupported HealthKit category type"), id)
                )
            }
            return type
        }

        func categoryValue(from rawValue: String?) throws -> Int {
            switch id {
            case "mindful_session":
                return HKCategoryValue.notApplicable.rawValue
            case "sleep_analysis":
                return sleepValue(from: rawValue)
            default:
                return severityValue(from: rawValue)
            }
        }

        func categoryValueName(_ value: Int) -> String {
            switch id {
            case "sleep_analysis":
                return sleepValueName(value)
            case "mindful_session":
                return "not_applicable"
            default:
                return severityValueName(value)
            }
        }

        private func sleepValue(from rawValue: String?) -> Int {
            switch rawValue?.lowercased() {
            case "in_bed": return HKCategoryValueSleepAnalysis.inBed.rawValue
            case "awake": return HKCategoryValueSleepAnalysis.awake.rawValue
            case "core": return HKCategoryValueSleepAnalysis.asleepCore.rawValue
            case "deep": return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
            case "rem": return HKCategoryValueSleepAnalysis.asleepREM.rawValue
            default: return HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue
            }
        }

        private func sleepValueName(_ value: Int) -> String {
            switch value {
            case HKCategoryValueSleepAnalysis.inBed.rawValue: return "in_bed"
            case HKCategoryValueSleepAnalysis.awake.rawValue: return "awake"
            case HKCategoryValueSleepAnalysis.asleepCore.rawValue: return "core"
            case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: return "deep"
            case HKCategoryValueSleepAnalysis.asleepREM.rawValue: return "rem"
            case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: return "asleep"
            default: return "unknown_\(value)"
            }
        }

        private func severityValue(from rawValue: String?) -> Int {
            switch rawValue?.lowercased() {
            case "not_present": return HKCategoryValueSeverity.notPresent.rawValue
            case "mild": return HKCategoryValueSeverity.mild.rawValue
            case "moderate": return HKCategoryValueSeverity.moderate.rawValue
            case "severe": return HKCategoryValueSeverity.severe.rawValue
            default: return HKCategoryValueSeverity.unspecified.rawValue
            }
        }

        private func severityValueName(_ value: Int) -> String {
            switch value {
            case HKCategoryValueSeverity.notPresent.rawValue: return "not_present"
            case HKCategoryValueSeverity.mild.rawValue: return "mild"
            case HKCategoryValueSeverity.moderate.rawValue: return "moderate"
            case HKCategoryValueSeverity.severe.rawValue: return "severe"
            case HKCategoryValueSeverity.unspecified.rawValue: return "unspecified"
            default: return "unknown_\(value)"
            }
        }
    }

    static let all: [Entry] = [
        quantity("heart_rate", "心率", .heartRate, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "count/min", canWrite: false, aggregation: .average),
        quantity("heart_rate_variability", "心率变异性 SDNN", .heartRateVariabilitySDNN, unit: .secondUnit(with: .milli), unitLabel: "ms", canWrite: false, aggregation: .average),
        quantity("resting_heart_rate", "静息心率", .restingHeartRate, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "count/min", canWrite: false, aggregation: .average),
        quantity("walking_heart_rate_average", "步行心率均值", .walkingHeartRateAverage, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "count/min", canWrite: false, aggregation: .average),
        quantity("oxygen_saturation", "血氧饱和度", .oxygenSaturation, unit: .percent(), unitLabel: "percent", canWrite: false, aggregation: .average),
        quantity("respiratory_rate", "呼吸频率", .respiratoryRate, unit: HKUnit.count().unitDivided(by: .minute()), unitLabel: "count/min", canWrite: false, aggregation: .average),
        quantity("body_temperature", "体温", .bodyTemperature, unit: .degreeCelsius(), unitLabel: "degC", canWrite: false, aggregation: .average),
        quantity("step_count", "步数", .stepCount, unit: .count(), unitLabel: "count", canWrite: false, aggregation: .sum),
        quantity("flights_climbed", "爬楼楼层", .flightsClimbed, unit: .count(), unitLabel: "count", canWrite: false, aggregation: .sum),
        quantity("active_energy", "活动能量", .activeEnergyBurned, unit: .kilocalorie(), unitLabel: "kcal", canWrite: false, aggregation: .sum),
        quantity("apple_stand_time", "站立时间", .appleStandTime, unit: .minute(), unitLabel: "min", canWrite: false, aggregation: .sum),
        quantity("body_mass", "体重", .bodyMass, unit: .gramUnit(with: .kilo), unitLabel: "kg", canWrite: true, aggregation: .average),
        quantity("body_fat_percentage", "体脂率", .bodyFatPercentage, unit: .percent(), unitLabel: "percent", canWrite: true, aggregation: .average),
        quantity("body_mass_index", "BMI", .bodyMassIndex, unit: .count(), unitLabel: "count", canWrite: true, aggregation: .average),
        quantity("dietary_water", "水分摄入", .dietaryWater, unit: .literUnit(with: .milli), unitLabel: "mL", canWrite: true, aggregation: .sum),
        quantity("dietary_caffeine", "咖啡因摄入", .dietaryCaffeine, unit: .gramUnit(with: .milli), unitLabel: "mg", canWrite: true, aggregation: .sum),
        quantity("dietary_energy", "膳食能量", .dietaryEnergyConsumed, unit: .kilocalorie(), unitLabel: "kcal", canWrite: true, aggregation: .sum),
        quantity("dietary_protein", "蛋白质", .dietaryProtein, unit: .gram(), unitLabel: "g", canWrite: true, aggregation: .sum),
        quantity("dietary_carbohydrates", "碳水化合物", .dietaryCarbohydrates, unit: .gram(), unitLabel: "g", canWrite: true, aggregation: .sum),
        quantity("dietary_fat_total", "脂肪", .dietaryFatTotal, unit: .gram(), unitLabel: "g", canWrite: true, aggregation: .sum),
        category("sleep_analysis", "睡眠分析", .sleepAnalysis, canWrite: false),
        category("mindful_session", "正念分钟数", .mindfulSession, canWrite: true),
        category("headache", "头痛", .headache, canWrite: true),
        category("fever", "发热", .fever, canWrite: true),
        category("coughing", "咳嗽", .coughing, canWrite: true),
        Entry(
            id: "workouts",
            title: "体能训练",
            kind: .workout,
            quantityIdentifier: nil,
            categoryIdentifier: nil,
            unit: .count(),
            unitLabel: "workout",
            canRead: true,
            canWrite: false,
            defaultAggregation: .sum
        )
    ]

    static func type(for id: String) throws -> Entry {
        guard let type = all.first(where: { $0.id == id }) else {
            throw MCPBuiltInPersonalDataError.invalidArgument(
                String(format: NSLocalizedString("不支持的 HealthKit 类型：%@", comment: "Unsupported HealthKit type"), id)
            )
        }
        return type
    }

    private static func quantity(
        _ id: String,
        _ title: String,
        _ identifier: HKQuantityTypeIdentifier,
        unit: HKUnit,
        unitLabel: String,
        canWrite: Bool,
        aggregation: DefaultAggregation
    ) -> Entry {
        Entry(
            id: id,
            title: title,
            kind: .quantity,
            quantityIdentifier: identifier,
            categoryIdentifier: nil,
            unit: unit,
            unitLabel: unitLabel,
            canRead: true,
            canWrite: canWrite,
            defaultAggregation: aggregation
        )
    }

    private static func category(
        _ id: String,
        _ title: String,
        _ identifier: HKCategoryTypeIdentifier,
        canWrite: Bool
    ) -> Entry {
        Entry(
            id: id,
            title: title,
            kind: .category,
            quantityIdentifier: nil,
            categoryIdentifier: identifier,
            unit: .count(),
            unitLabel: "category",
            canRead: true,
            canWrite: canWrite,
            defaultAggregation: .sum
        )
    }
}
#endif
