// ============================================================================
// MCPNativeBluetoothExecutor.swift
// ============================================================================
// ETOS LLM Studio
//
// BLE 连接按可信会话或 Agent Run 归属；Run 结束、空闲超时或显式断开都会清理订阅与连接。
// ============================================================================

import Foundation
#if canImport(CoreBluetooth)
@preconcurrency import CoreBluetooth
#endif
#if os(iOS) && canImport(UIKit)
import UIKit
#elseif canImport(WatchKit)
import WatchKit
#endif

#if canImport(CoreBluetooth)
@MainActor
final class MCPNativeBluetoothExecutor: NSObject, @preconcurrency CBCentralManagerDelegate, @preconcurrency CBPeripheralDelegate {
    static let shared = MCPNativeBluetoothExecutor()

    private var central: CBCentralManager?
    private var stateWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var discovered: [UUID: (peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber)] = [:]
    private var connectionsByScope: [UUID: Set<UUID>] = [:]
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var connectWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var discoveryWaiters: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var pendingServiceDiscoveries: [UUID: Set<CBUUID>] = [:]
    private var readWaiters: [String: CheckedContinuation<Data?, Error>] = [:]
    private var writeWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var subscriptionWaiters: [String: CheckedContinuation<Void, Error>] = [:]
    private var scanning = false
    private var lifecycleObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        let center = NotificationCenter.default
        #if os(iOS) && canImport(UIKit)
        lifecycleObservers.append(center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanupAll() }
        })
        #elseif canImport(WatchKit)
        lifecycleObservers.append(center.addObserver(
            forName: WKExtension.applicationDidEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.cleanupAll() }
        })
        #endif
    }

    deinit {
        lifecycleObservers.forEach(NotificationCenter.default.removeObserver)
    }

    func execute(toolName: String, arguments: [String: Any], scopeID: UUID?) async throws -> [String: Any] {
        switch toolName {
        case "bluetooth.scan":
            return try await scan(arguments)
        case "bluetooth.connect":
            let scopeID = try requiredScope(scopeID)
            return try await connect(arguments, scopeID: scopeID)
        case "bluetooth.discover_services":
            let scopeID = try requiredScope(scopeID)
            return try await discoverServices(arguments, scopeID: scopeID)
        case "bluetooth.read_characteristic":
            let scopeID = try requiredScope(scopeID)
            return try await readCharacteristic(arguments, scopeID: scopeID)
        case "bluetooth.write_characteristic":
            let scopeID = try requiredScope(scopeID)
            return try await writeCharacteristic(arguments, scopeID: scopeID)
        case "bluetooth.subscribe":
            let scopeID = try requiredScope(scopeID)
            return try await subscribe(arguments, scopeID: scopeID)
        case "bluetooth.disconnect":
            let scopeID = try requiredScope(scopeID)
            return try disconnect(arguments, scopeID: scopeID)
        default:
            throw MCPNativeCapabilityError.unsupportedTool(toolName)
        }
    }

    func finishRun(id: UUID) {
        cleanupScope(id)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state != .unknown && central.state != .resetting else { return }
        let result: Result<Void, Error> = central.state == .poweredOn
            ? .success(())
            : .failure(stateError(central.state))
        let waiters = stateWaiters.values
        stateWaiters.removeAll()
        waiters.forEach { $0.resume(with: result) }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        discovered[peripheral.identifier] = (peripheral, advertisementData, RSSI)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        connectWaiters.removeValue(forKey: peripheral.identifier)?.resume()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectWaiters.removeValue(forKey: peripheral.identifier)?.resume(
            throwing: error ?? MCPNativeCapabilityError.unavailable(NSLocalizedString("蓝牙连接失败。", comment: "Bluetooth connection failed"))
        )
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        for scopeID in Array(connectionsByScope.keys) {
            connectionsByScope[scopeID]?.remove(peripheral.identifier)
        }
        cancelOperations(
            for: peripheral.identifier,
            error: error ?? MCPNativeCapabilityError.unavailable(
                NSLocalizedString("蓝牙外设已断开。", comment: "Bluetooth peripheral disconnected")
            )
        )
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            finishDiscovery(peripheral.identifier, result: .failure(error))
            return
        }
        let services = peripheral.services ?? []
        guard !services.isEmpty else {
            finishDiscovery(peripheral.identifier, result: .success(()))
            return
        }
        pendingServiceDiscoveries[peripheral.identifier] = Set(services.map(\.uuid))
        services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            finishDiscovery(peripheral.identifier, result: .failure(error))
            return
        }
        pendingServiceDiscoveries[peripheral.identifier]?.remove(service.uuid)
        if pendingServiceDiscoveries[peripheral.identifier]?.isEmpty != false {
            finishDiscovery(peripheral.identifier, result: .success(()))
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = operationKey(peripheral.identifier, characteristic.uuid)
        guard let waiter = readWaiters.removeValue(forKey: key) else { return }
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume(returning: characteristic.value) }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = operationKey(peripheral.identifier, characteristic.uuid)
        guard let waiter = writeWaiters.removeValue(forKey: key) else { return }
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = operationKey(peripheral.identifier, characteristic.uuid)
        guard let waiter = subscriptionWaiters.removeValue(forKey: key) else { return }
        if let error { waiter.resume(throwing: error) }
        else { waiter.resume() }
    }
}

@MainActor
private extension MCPNativeBluetoothExecutor {
    func scan(_ arguments: [String: Any]) async throws -> [String: Any] {
        try await ensurePoweredOn()
        guard !scanning else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("已有蓝牙扫描正在进行。", comment: "Bluetooth scan already running")
            )
        }
        let duration = min(max(arguments.nativeDouble("duration_seconds") ?? 5, 1), 15)
        let serviceUUIDs = (arguments["service_uuids"] as? [String])?.map(CBUUID.init(string:))
        discovered.removeAll()
        scanning = true
        central?.scanForPeripherals(withServices: serviceUUIDs, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        do {
            try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
        } catch {
            stopScan()
            throw error
        }
        stopScan()
        let peripherals = discovered.values.map(peripheralPayload).sorted {
            (($0["rssi"] as? Int) ?? Int.min) > (($1["rssi"] as? Int) ?? Int.min)
        }
        return ["peripherals": peripherals, "count": peripherals.count, "duration_seconds": duration]
    }

    func connect(_ arguments: [String: Any], scopeID: UUID) async throws -> [String: Any] {
        try await ensurePoweredOn()
        let identifier = try peripheralIdentifier(arguments)
        let peripheral = try findPeripheral(identifier)
        touch(scopeID)
        if peripheral.state != .connected {
            guard connectWaiters[identifier] == nil else {
                throw MCPNativeCapabilityError.unavailable(
                    NSLocalizedString("该外设正在连接。", comment: "Bluetooth peripheral already connecting")
                )
            }
            peripheral.delegate = self
            try await withCheckedThrowingContinuation { continuation in
                connectWaiters[identifier] = continuation
                central?.connect(peripheral)
                scheduleTimeout(seconds: 15) { [weak self] in
                    guard let self,
                          let waiter = self.connectWaiters.removeValue(forKey: identifier) else { return }
                    waiter.resume(throwing: MCPNativeCapabilityError.unavailable(
                        NSLocalizedString("蓝牙连接超时。", comment: "Bluetooth connection timed out")
                    ))
                    self.central?.cancelPeripheralConnection(peripheral)
                }
            }
        }
        connectionsByScope[scopeID, default: []].insert(identifier)
        return ["connected": true, "peripheral": peripheralPayload(peripheral: peripheral, advertisement: [:], rssi: 0)]
    }

    func discoverServices(_ arguments: [String: Any], scopeID: UUID) async throws -> [String: Any] {
        let peripheral = try connectedPeripheral(arguments, scopeID: scopeID)
        touch(scopeID)
        guard discoveryWaiters[peripheral.identifier] == nil else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("该外设正在发现蓝牙服务。", comment: "Bluetooth service discovery already running")
            )
        }
        try await withCheckedThrowingContinuation { continuation in
            discoveryWaiters[peripheral.identifier] = continuation
            peripheral.discoverServices(nil)
            scheduleTimeout(seconds: 15) { [weak self] in
                self?.finishDiscovery(peripheral.identifier, result: .failure(
                    MCPNativeCapabilityError.unavailable(NSLocalizedString("发现蓝牙服务超时。", comment: "Bluetooth discovery timed out"))
                ))
            }
        }
        return ["peripheral_id": peripheral.identifier.uuidString, "services": servicesPayload(peripheral), "count": peripheral.services?.count ?? 0]
    }

    func readCharacteristic(_ arguments: [String: Any], scopeID: UUID) async throws -> [String: Any] {
        let peripheral = try connectedPeripheral(arguments, scopeID: scopeID)
        let characteristic = try findCharacteristic(arguments, peripheral: peripheral)
        touch(scopeID)
        let key = operationKey(peripheral.identifier, characteristic.uuid)
        guard readWaiters[key] == nil else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("该蓝牙特征正在读取。", comment: "Bluetooth characteristic read already running")
            )
        }
        let data = try await withCheckedThrowingContinuation { continuation in
            readWaiters[key] = continuation
            peripheral.readValue(for: characteristic)
            scheduleTimeout(seconds: 10) { [weak self] in
                self?.readWaiters.removeValue(forKey: key)?.resume(
                    throwing: MCPNativeCapabilityError.unavailable(NSLocalizedString("读取蓝牙特征超时。", comment: "Bluetooth read timed out"))
                )
            }
        }
        return characteristicResult(peripheral, characteristic, data: data)
    }

    func writeCharacteristic(_ arguments: [String: Any], scopeID: UUID) async throws -> [String: Any] {
        let peripheral = try connectedPeripheral(arguments, scopeID: scopeID)
        let characteristic = try findCharacteristic(arguments, peripheral: peripheral)
        let rawValue = try arguments.nativeRequiredString("value_base64")
        guard let data = Data(base64Encoded: rawValue) else {
            throw MCPNativeCapabilityError.invalidArgument(
                NSLocalizedString("value_base64 不是有效 Base64。", comment: "Invalid Bluetooth base64 value")
            )
        }
        touch(scopeID)
        let key = operationKey(peripheral.identifier, characteristic.uuid)
        guard writeWaiters[key] == nil else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("该蓝牙特征正在写入。", comment: "Bluetooth characteristic write already running")
            )
        }
        try await withCheckedThrowingContinuation { continuation in
            writeWaiters[key] = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
            scheduleTimeout(seconds: 10) { [weak self] in
                self?.writeWaiters.removeValue(forKey: key)?.resume(
                    throwing: MCPNativeCapabilityError.unavailable(NSLocalizedString("写入蓝牙特征超时。", comment: "Bluetooth write timed out"))
                )
            }
        }
        return ["written": true, "bytes": data.count, "peripheral_id": peripheral.identifier.uuidString, "characteristic_uuid": characteristic.uuid.uuidString]
    }

    func subscribe(_ arguments: [String: Any], scopeID: UUID) async throws -> [String: Any] {
        let peripheral = try connectedPeripheral(arguments, scopeID: scopeID)
        let characteristic = try findCharacteristic(arguments, peripheral: peripheral)
        let enabled = arguments.nativeBool("enabled") ?? false
        touch(scopeID)
        let key = operationKey(peripheral.identifier, characteristic.uuid)
        guard subscriptionWaiters[key] == nil else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("该蓝牙特征正在更新订阅。", comment: "Bluetooth subscription update already running")
            )
        }
        try await withCheckedThrowingContinuation { continuation in
            subscriptionWaiters[key] = continuation
            peripheral.setNotifyValue(enabled, for: characteristic)
            scheduleTimeout(seconds: 10) { [weak self] in
                self?.subscriptionWaiters.removeValue(forKey: key)?.resume(
                    throwing: MCPNativeCapabilityError.unavailable(NSLocalizedString("更新蓝牙订阅超时。", comment: "Bluetooth subscription timed out"))
                )
            }
        }
        return ["subscribed": enabled, "peripheral_id": peripheral.identifier.uuidString, "characteristic_uuid": characteristic.uuid.uuidString]
    }

    func disconnect(_ arguments: [String: Any], scopeID: UUID) throws -> [String: Any] {
        let identifier = try peripheralIdentifier(arguments)
        connectionsByScope[scopeID]?.remove(identifier)
        disconnectIfUnowned(identifier)
        return ["disconnected": true, "peripheral_id": identifier.uuidString]
    }

    func ensurePoweredOn() async throws {
        if central == nil { central = CBCentralManager(delegate: self, queue: nil) }
        guard let central else { return }
        if central.state == .poweredOn { return }
        if central.state != .unknown && central.state != .resetting { throw stateError(central.state) }
        let id = UUID()
        try await withCheckedThrowingContinuation { continuation in
            stateWaiters[id] = continuation
            scheduleTimeout(seconds: 10) { [weak self] in
                self?.stateWaiters.removeValue(forKey: id)?.resume(
                    throwing: MCPNativeCapabilityError.unavailable(NSLocalizedString("等待蓝牙状态超时。", comment: "Bluetooth state timed out"))
                )
            }
        }
    }

    func stateError(_ state: CBManagerState) -> MCPNativeCapabilityError {
        let message: String
        switch state {
        case .poweredOff: message = NSLocalizedString("蓝牙当前已关闭。", comment: "Bluetooth powered off")
        case .unauthorized: message = NSLocalizedString("蓝牙权限不足。", comment: "Bluetooth unauthorized")
        case .unsupported: message = NSLocalizedString("当前设备不支持 BLE。", comment: "Bluetooth unsupported")
        default: message = NSLocalizedString("蓝牙当前不可用。", comment: "Bluetooth unavailable")
        }
        return .unavailable(message)
    }

    func requiredScope(_ scopeID: UUID?) throws -> UUID {
        guard let scopeID else {
            throw MCPNativeCapabilityError.unavailable(
                NSLocalizedString("有状态蓝牙工具需要可信聊天会话或 Agent Run 上下文。", comment: "Bluetooth requires trusted scope")
            )
        }
        return scopeID
    }

    func peripheralIdentifier(_ arguments: [String: Any]) throws -> UUID {
        let raw = try arguments.nativeRequiredString("peripheral_id")
        guard let id = UUID(uuidString: raw) else { throw MCPNativeCapabilityError.invalidArgument(NSLocalizedString("peripheral_id 必须是 UUID。", comment: "Invalid Bluetooth peripheral UUID")) }
        return id
    }

    func findPeripheral(_ identifier: UUID) throws -> CBPeripheral {
        if let peripheral = discovered[identifier]?.peripheral { return peripheral }
        if let peripheral = central?.retrievePeripherals(withIdentifiers: [identifier]).first { return peripheral }
        throw MCPNativeCapabilityError.invalidArgument(NSLocalizedString("找不到指定 BLE 外设，请先扫描。", comment: "Bluetooth peripheral not found"))
    }

    func connectedPeripheral(_ arguments: [String: Any], scopeID: UUID) throws -> CBPeripheral {
        let id = try peripheralIdentifier(arguments)
        guard connectionsByScope[scopeID]?.contains(id) == true else {
            throw MCPNativeCapabilityError.unavailable(NSLocalizedString("该 BLE 外设不属于当前会话或 Run。", comment: "Bluetooth peripheral outside scope"))
        }
        let peripheral = try findPeripheral(id)
        guard peripheral.state == .connected else { throw MCPNativeCapabilityError.unavailable(NSLocalizedString("BLE 外设尚未连接。", comment: "Bluetooth peripheral not connected")) }
        return peripheral
    }

    func findCharacteristic(_ arguments: [String: Any], peripheral: CBPeripheral) throws -> CBCharacteristic {
        let serviceUUID = CBUUID(string: try arguments.nativeRequiredString("service_uuid"))
        let characteristicUUID = CBUUID(string: try arguments.nativeRequiredString("characteristic_uuid"))
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }),
              let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            throw MCPNativeCapabilityError.invalidArgument(NSLocalizedString("找不到指定 BLE 特征，请先发现服务。", comment: "Bluetooth characteristic not found"))
        }
        return characteristic
    }

    func finishDiscovery(_ id: UUID, result: Result<Void, Error>) {
        pendingServiceDiscoveries.removeValue(forKey: id)
        discoveryWaiters.removeValue(forKey: id)?.resume(with: result)
    }

    func stopScan() { central?.stopScan(); scanning = false }

    func touch(_ scopeID: UUID) {
        cleanupTasks[scopeID]?.cancel()
        cleanupTasks[scopeID] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled else { return }
            self?.cleanupScope(scopeID)
        }
    }

    func cleanupScope(_ scopeID: UUID) {
        cleanupTasks.removeValue(forKey: scopeID)?.cancel()
        let identifiers = connectionsByScope.removeValue(forKey: scopeID) ?? []
        identifiers.forEach(disconnectIfUnowned)
    }

    func disconnectIfUnowned(_ identifier: UUID) {
        guard !connectionsByScope.values.contains(where: { $0.contains(identifier) }),
              let peripheral = try? findPeripheral(identifier) else { return }
        cancelOperations(for: identifier, error: CancellationError())
        peripheral.services?.flatMap { $0.characteristics ?? [] }
            .filter(\.isNotifying)
            .forEach { peripheral.setNotifyValue(false, for: $0) }
        central?.cancelPeripheralConnection(peripheral)
    }

    func cleanupAll() {
        stopScan()
        cleanupTasks.values.forEach { $0.cancel() }
        cleanupTasks.removeAll()
        let identifiers = Set(connectionsByScope.values.flatMap { $0 })
        connectionsByScope.removeAll()
        identifiers.forEach(disconnectIfUnowned)
    }

    func cancelOperations(for identifier: UUID, error: Error) {
        connectWaiters.removeValue(forKey: identifier)?.resume(throwing: error)
        finishDiscovery(identifier, result: .failure(error))
        let prefix = identifier.uuidString + "|"
        for key in readWaiters.keys.filter({ $0.hasPrefix(prefix) }) {
            readWaiters.removeValue(forKey: key)?.resume(throwing: error)
        }
        for key in writeWaiters.keys.filter({ $0.hasPrefix(prefix) }) {
            writeWaiters.removeValue(forKey: key)?.resume(throwing: error)
        }
        for key in subscriptionWaiters.keys.filter({ $0.hasPrefix(prefix) }) {
            subscriptionWaiters.removeValue(forKey: key)?.resume(throwing: error)
        }
    }

    func scheduleTimeout(seconds: TimeInterval, action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            action()
        }
    }

    func operationKey(_ peripheralID: UUID, _ characteristicID: CBUUID) -> String { "\(peripheralID.uuidString)|\(characteristicID.uuidString)" }

    func servicesPayload(_ peripheral: CBPeripheral) -> [[String: Any]] {
        (peripheral.services ?? []).map { service in
            ["uuid": service.uuid.uuidString, "primary": service.isPrimary, "characteristics": (service.characteristics ?? []).map { characteristic in
                ["uuid": characteristic.uuid.uuidString, "properties": characteristic.properties.rawValue, "notifying": characteristic.isNotifying, "value_base64": characteristic.value?.base64EncodedString() ?? NSNull()] as [String: Any]
            }] as [String: Any]
        }
    }

    func characteristicResult(_ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, data: Data?) -> [String: Any] {
        ["peripheral_id": peripheral.identifier.uuidString, "characteristic_uuid": characteristic.uuid.uuidString, "value_base64": data?.base64EncodedString() ?? NSNull(), "bytes": data?.count ?? 0]
    }

    func peripheralPayload(_ value: (peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber)) -> [String: Any] {
        peripheralPayload(peripheral: value.peripheral, advertisement: value.advertisement, rssi: value.rssi)
    }

    func peripheralPayload(peripheral: CBPeripheral, advertisement: [String: Any], rssi: NSNumber) -> [String: Any] {
        let name: Any
        if let value = peripheral.name ?? advertisement[CBAdvertisementDataLocalNameKey] as? String {
            name = value
        } else {
            name = NSNull()
        }
        return [
            "id": peripheral.identifier.uuidString,
            "name": name,
            "rssi": rssi.intValue,
            "connectable": advertisement[CBAdvertisementDataIsConnectable] as? NSNumber ?? NSNull(),
            "service_uuids": (advertisement[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? [],
            "manufacturer_data_base64": (advertisement[CBAdvertisementDataManufacturerDataKey] as? Data)?.base64EncodedString() ?? NSNull(),
            "state": peripheral.state.rawValue
        ]
    }
}
#else
actor MCPNativeBluetoothExecutor {
    static let shared = MCPNativeBluetoothExecutor()
    func execute(toolName: String, arguments: [String: Any], scopeID: UUID?) async throws -> [String: Any] {
        throw MCPNativeCapabilityError.unavailable(NSLocalizedString("当前平台没有 CoreBluetooth。", comment: "CoreBluetooth unavailable"))
    }
    func finishRun(id: UUID) {}
}
#endif
