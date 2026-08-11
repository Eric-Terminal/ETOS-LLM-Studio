// ============================================================================
// MCPNativeHomeExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// HomeKit 对象由系统主线程模型管理；首次工具调用后才创建 HMHomeManager。
// ============================================================================

import Foundation
#if canImport(HomeKit)
@preconcurrency import HomeKit
#endif

#if canImport(HomeKit)
@MainActor
final class MCPNativeHomeExecutor: NSObject, @preconcurrency HMHomeManagerDelegate {
    static let shared = MCPNativeHomeExecutor()

    private var manager: HMHomeManager?
    private var homesReady = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await ensureHomesReady()
        switch toolName {
        case "home.list_homes":
            let homes = manager?.homes ?? []
            return ["homes": homes.map(homePayload), "count": homes.count]
        case "home.list_accessories":
            let home = try findHome(arguments)
            return ["home_id": home.uniqueIdentifier.uuidString, "accessories": home.accessories.map(accessoryPayload), "count": home.accessories.count]
        case "home.list_scenes":
            let home = try findHome(arguments)
            let scenes = home.actionSets.map(scenePayload)
            return ["home_id": home.uniqueIdentifier.uuidString, "scenes": scenes, "count": scenes.count]
        case "home.read_characteristic":
            let characteristic = try findCharacteristic(arguments)
            try await read(characteristic)
            return ["characteristic": characteristicPayload(characteristic)]
        case "home.write_characteristic":
            let characteristic = try findCharacteristic(arguments)
            guard let value = arguments["value"], value is String || value is NSNumber else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("HomeKit 特征值必须是布尔值、数字或字符串。", comment: "Invalid HomeKit characteristic value")
                )
            }
            try await write(value, to: characteristic)
            return ["written": true, "characteristic": characteristicPayload(characteristic)]
        case "home.execute_scene":
            let home = try findHome(arguments)
            let sceneID = try uuidArgument("scene_id", arguments)
            guard let scene = home.actionSets.first(where: { $0.uniqueIdentifier == sceneID }) else {
                throw MCPNativeCapabilityError.invalidArgument(
                    NSLocalizedString("找不到指定 HomeKit 场景。", comment: "HomeKit scene not found")
                )
            }
            try await execute(scene, in: home)
            return ["executed": true, "scene": scenePayload(scene)]
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
    }

    func homeManagerDidUpdateHomes(_ manager: HMHomeManager) {
        homesReady = true
        finishWaiters(with: .success(()))
    }

    func homeManager(
        _ manager: HMHomeManager,
        didUpdate status: HMHomeManagerAuthorizationStatus
    ) {
        if status.contains(.restricted) {
            finishWaiters(with: .failure(MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("HomeKit 访问被系统限制。", comment: "HomeKit access restricted")
            )))
        }
    }
}

@MainActor
private extension MCPNativeHomeExecutor {
    func ensureHomesReady() async throws {
        if homesReady {
            try validateAuthorization()
            return
        }
        if manager == nil {
            let manager = HMHomeManager()
            manager.delegate = self
            self.manager = manager
        }
        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
                Task { @MainActor [weak self] in
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    self?.finishWaiter(
                        id: waiterID,
                        result: .failure(MCPNativeCapabilityError.unavailable(
                            NSLocalizedString("等待 HomeKit 家庭数据超时。", comment: "HomeKit loading timed out")
                        ))
                    )
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishWaiter(id: waiterID, result: .failure(CancellationError()))
            }
        }
        try validateAuthorization()
    }

    func validateAuthorization() throws {
        guard let manager else { return }
        if manager.authorizationStatus.contains(.restricted) {
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("HomeKit 访问被系统限制。", comment: "HomeKit access restricted")
            )
        }
        guard manager.authorizationStatus.contains(.authorized) else {
            throw MCPNativeCapabilityError.permissionDenied(
                NSLocalizedString("HomeKit 访问权限不足。", comment: "HomeKit permission insufficient")
            )
        }
    }

    func finishWaiter(id: UUID, result: Result<Void, Error>) {
        guard let continuation = waiters.removeValue(forKey: id) else { return }
        continuation.resume(with: result)
    }

    func finishWaiters(with result: Result<Void, Error>) {
        let continuations = waiters.values
        waiters.removeAll()
        continuations.forEach { $0.resume(with: result) }
    }

    func findHome(_ arguments: [String: Any]) throws -> HMHome {
        let identifier = try uuidArgument("home_id", arguments)
        guard let home = manager?.homes.first(where: { $0.uniqueIdentifier == identifier }) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("找不到指定 HomeKit 家庭。", comment: "HomeKit home not found")
            )
        }
        return home
    }

    func findCharacteristic(_ arguments: [String: Any]) throws -> HMCharacteristic {
        let home = try findHome(arguments)
        let accessoryID = try uuidArgument("accessory_id", arguments)
        let serviceID = try uuidArgument("service_id", arguments)
        let characteristicID = try uuidArgument("characteristic_id", arguments)
        guard let accessory = home.accessories.first(where: { $0.uniqueIdentifier == accessoryID }),
              let service = accessory.services.first(where: { $0.uniqueIdentifier == serviceID }),
              let characteristic = service.characteristics.first(where: { $0.uniqueIdentifier == characteristicID }) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("找不到指定 HomeKit 特征。", comment: "HomeKit characteristic not found")
            )
        }
        return characteristic
    }

    func uuidArgument(_ key: String, _ arguments: [String: Any]) throws -> UUID {
        let raw = try arguments.nativeRequiredString(key)
        guard let identifier = UUID(uuidString: raw) else {
            throw MCPNativeCapabilityError.invalidArgument(
                String(format: NSLocalizedString("%@ 必须是 UUID。", comment: "Invalid HomeKit UUID"), key)
            )
        }
        return identifier
    }

    func read(_ characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.readValue { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func write(_ value: Any, to characteristic: HMCharacteristic) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            characteristic.writeValue(value) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func execute(_ scene: HMActionSet, in home: HMHome) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            home.executeActionSet(scene) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    func homePayload(_ home: HMHome) -> [String: Any] {
        ["id": home.uniqueIdentifier.uuidString, "name": home.name, "accessory_count": home.accessories.count, "scene_count": home.actionSets.count]
    }

    func accessoryPayload(_ accessory: HMAccessory) -> [String: Any] {
        [
            "id": accessory.uniqueIdentifier.uuidString,
            "name": accessory.name,
            "manufacturer": accessory.manufacturer ?? NSNull(),
            "model": accessory.model ?? NSNull(),
            "room": accessory.room?.name ?? NSNull(),
            "reachable": accessory.isReachable,
            "services": accessory.services.map { service in
                [
                    "id": service.uniqueIdentifier.uuidString,
                    "name": service.name,
                    "type": service.serviceType,
                    "characteristics": service.characteristics.map(characteristicPayload)
                ] as [String: Any]
            }
        ]
    }

    func scenePayload(_ scene: HMActionSet) -> [String: Any] {
        ["id": scene.uniqueIdentifier.uuidString, "name": scene.name, "type": scene.actionSetType, "action_count": scene.actions.count]
    }

    func characteristicPayload(_ characteristic: HMCharacteristic) -> [String: Any] {
        [
            "id": characteristic.uniqueIdentifier.uuidString,
            "type": characteristic.characteristicType,
            "properties": characteristic.properties,
            "notification_enabled": characteristic.isNotificationEnabled,
            "value": jsonValue(characteristic.value),
            "format": characteristic.metadata?.format ?? NSNull(),
            "unit": characteristic.metadata?.units ?? NSNull()
        ]
    }

    func jsonValue(_ value: Any?) -> Any {
        guard let value else { return NSNull() }
        if value is String || value is NSNumber { return value }
        if let data = value as? Data { return ["base64": data.base64EncodedString()] }
        if let date = value as? Date { return MCPBuiltInPersonalDataDateCodec.string(date) ?? "" }
        return String(describing: value)
    }
}
#else
actor MCPNativeHomeExecutor {
    static let shared = MCPNativeHomeExecutor()
    func execute(toolName: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await MCPNativeCapabilityCompanionRelay.shared.execute(toolName: toolName, arguments: arguments)
    }
}
#endif
