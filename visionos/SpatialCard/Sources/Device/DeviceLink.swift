import CoreBluetooth
import Foundation

/// What a device link reports to the coordinator.
enum DeviceEvent {
    case connected(name: String)
    case disconnected
    case message(DeviceMessage, raw: String)
}

/// A BLE link to the AI Passport, or its scripted stand-in for the simulator.
@MainActor
protocol DeviceLinking: AnyObject {
    var events: AsyncStream<DeviceEvent> { get }
    var isConnected: Bool { get }
    func start()
    func stop()
    /// Scan again if not connected (the link drops across Safari round-trips).
    func rescan()
    func send(_ command: DeviceCommand)
}

/// CoreBluetooth central for the device's Nordic UART Service (plan §8 C3, `docs/protocol.md`): scans for the
/// NUS service UUID (advertised in the ADV packet; the name `SpatialCard-XXXX` is in the scan response and only
/// a fallback), subscribes to TX, reassembles lines on `\n`, writes RX in MTU-sized chunks, reconnects with a
/// backoff that caps at 5 s. The firmware sends its `hello` only once the central has enabled notifications on
/// TX, so "connected" is the moment that `hello` arrives (3 s fallback if it never does). Every callback arrives
/// on the main queue (`queue: .main`) and is hopped onto the main actor with `assumeIsolated`.
@MainActor
final class DeviceLink: NSObject, DeviceLinking {
    static let serviceUUID = CBUUID(string: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E")
    static let rxUUID = CBUUID(string: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")   // VP → device (write)
    static let txUUID = CBUUID(string: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E")   // device → VP (notify)
    static let namePrefix = "SpatialCard"

    let events: AsyncStream<DeviceEvent>
    private var continuation: AsyncStream<DeviceEvent>.Continuation?
    private(set) var isConnected = false

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var rx: CBCharacteristic?
    private var tx: CBCharacteristic?
    private var buffer = Data()
    private var started = false
    private var scanning = false
    private var scanUnfiltered = false
    private var reconnectDelay: TimeInterval = 0.5
    private var reconnectTask: Task<Void, Never>?
    private var scanFallbackTask: Task<Void, Never>?
    private var helloTask: Task<Void, Never>?
    private var subscribed = false
    /// Without a `hello` this long after subscribing, the link counts as connected anyway.
    static let helloTimeout: TimeInterval = 3

    override init() {
        var continuation: AsyncStream<DeviceEvent>.Continuation?
        events = AsyncStream { continuation = $0 }
        self.continuation = continuation
        super.init()
    }

    func start() {
        guard !started else { return }
        started = true
        central = CBCentralManager(delegate: self, queue: .main)
        print("[ble] central created")
    }

    func stop() {
        reconnectTask?.cancel()
        scanFallbackTask?.cancel()
        helloTask?.cancel()
        if let peripheral, let central { central.cancelPeripheralConnection(peripheral) }
        central?.stopScan()
        scanning = false
        started = false
        central = nil
    }

    func rescan() {
        guard started, !isConnected, peripheral == nil else { return }
        reconnectDelay = 0.5
        beginScan()
    }

    func send(_ command: DeviceCommand) {
        let line = command.line
        guard let data = line.data(using: .utf8) else { return }
        guard isConnected, let peripheral, let rx else {
            print("[ble] not connected; dropping \(command.typeName)")
            return
        }
        let type: CBCharacteristicWriteType = rx.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        let mtu = max(20, peripheral.maximumWriteValueLength(for: type))
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + mtu)
            peripheral.writeValue(data.subdata(in: offset..<end), for: rx, type: type)
            offset = end
        }
        print("[ble] send \(line.trimmingCharacters(in: .newlines))")
    }

    // MARK: - Scanning / connecting

    private func beginScan() {
        guard let central, central.state == .poweredOn, !scanning else { return }
        scanning = true
        scanUnfiltered = false
        central.scanForPeripherals(withServices: [DeviceLink.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        print("[ble] scanning for NUS \(DeviceLink.serviceUUID.uuidString.lowercased())")
        // Fallback: advertisements without the 128-bit UUID (older firmware) — scan everything, match by name.
        scanFallbackTask?.cancel()
        scanFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.scanning, self.peripheral == nil, let central = self.central else { return }
            self.scanUnfiltered = true
            central.stopScan()
            central.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            print("[ble] no NUS advertisement yet; scanning by name prefix \(DeviceLink.namePrefix)")
        }
    }

    private func connect(_ found: CBPeripheral) {
        guard let central else { return }
        central.stopScan()
        scanning = false
        scanFallbackTask?.cancel()
        peripheral = found
        found.delegate = self
        print("[ble] connecting to \(found.name ?? found.identifier.uuidString)")
        central.connect(found, options: nil)
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        let delay = reconnectDelay
        reconnectDelay = min(5, reconnectDelay * 2)
        print(String(format: "[ble] rescan in %.1f s", delay))
        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delay * 1000)))
            guard let self, !Task.isCancelled else { return }
            self.beginScan()
        }
    }

    private func handleDisconnect() {
        let wasConnected = isConnected
        isConnected = false
        subscribed = false
        helloTask?.cancel()
        helloTask = nil
        peripheral = nil
        rx = nil
        tx = nil
        buffer.removeAll()
        if wasConnected {
            print("[ble] disconnected")
            continuation?.yield(.disconnected)
        }
        scheduleReconnect()
    }

    /// The device is talking to us: `hello` after the TX subscription (or the fallback timeout).
    private func markConnected(reason: String) {
        guard !isConnected, subscribed else { return }
        helloTask?.cancel()
        helloTask = nil
        isConnected = true
        reconnectDelay = 0.5
        let name = peripheral?.name ?? DeviceLink.namePrefix
        print("[ble] connected (\(reason)): \(name)")
        continuation?.yield(.connected(name: name))
    }

    private func handleIncoming(_ data: Data) {
        // A TX notification is proof of the subscription even if its state callback has not arrived yet.
        if !subscribed {
            subscribed = true
            print("[ble] TX notification before the subscribe callback: treating as subscribed")
        }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8), !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let message = DeviceMessage.parse(line: line) {
                print("[ble] recv \(line)")
                continuation?.yield(.message(message, raw: line))
                if case .hello = message, !isConnected { markConnected(reason: "hello") }
            } else {
                print("[ble] unparsable line: \(line)")
            }
        }
        if buffer.count > 4096 { buffer.removeAll() }
    }
}

// MARK: - CBCentralManagerDelegate

extension DeviceLink: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            print("[ble] central state \(central.state.rawValue)")
            switch central.state {
            case .poweredOn:
                beginScan()
            case .poweredOff, .unauthorized, .unsupported:
                scanning = false
                handleDisconnect()
            default:
                break
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard self.peripheral == nil else { return }
            let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? ""
            let services = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? []
            let matches = services.contains(DeviceLink.serviceUUID) || name.hasPrefix(DeviceLink.namePrefix) || !scanUnfiltered
            guard matches else { return }
            print("[ble] found \(name.isEmpty ? peripheral.identifier.uuidString : name) rssi \(RSSI)")
            connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            print("[ble] connected to \(peripheral.name ?? "?"); discovering services")
            peripheral.discoverServices([DeviceLink.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            print("[ble] connect failed: \(error?.localizedDescription ?? "?")")
            handleDisconnect()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            if let error { print("[ble] disconnect: \(error.localizedDescription)") }
            handleDisconnect()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension DeviceLink: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: { $0.uuid == DeviceLink.serviceUUID }) else {
                print("[ble] NUS service missing: \(error?.localizedDescription ?? "no services")")
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.discoverCharacteristics([DeviceLink.rxUUID, DeviceLink.txUUID], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            for characteristic in service.characteristics ?? [] {
                if characteristic.uuid == DeviceLink.rxUUID { rx = characteristic }
                if characteristic.uuid == DeviceLink.txUUID { tx = characteristic }
            }
            guard let tx, rx != nil else {
                print("[ble] RX/TX characteristics missing")
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            peripheral.setNotifyValue(true, for: tx)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == DeviceLink.txUUID else { return }
            if let error {
                print("[ble] notify failed: \(error.localizedDescription)")
                central?.cancelPeripheralConnection(peripheral)
                return
            }
            subscribed = true
            print("[ble] subscribed to TX: \(peripheral.name ?? "?"), mtu \(peripheral.maximumWriteValueLength(for: .withoutResponse)); waiting for hello")
            helloTask?.cancel()
            helloTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(DeviceLink.helloTimeout))
                guard let self, !Task.isCancelled else { return }
                self.markConnected(reason: "no hello within \(Int(DeviceLink.helloTimeout)) s")
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard characteristic.uuid == DeviceLink.txUUID, let data = characteristic.value else { return }
            handleIncoming(data)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            if let error { print("[ble] write failed: \(error.localizedDescription)") }
        }
    }
}
