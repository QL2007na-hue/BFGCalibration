import Foundation
import CoreBluetooth
import BFGCore

/// Thin CoreBluetooth wrapper for the Ninebot Legacy UART service.
///
/// Differences from the Android transport this replaces, all forced by the
/// platform rather than chosen:
///
///   * **No MAC address.** CoreBluetooth never exposes one. Devices are
///     identified by `CBPeripheral.identifier` (stable per app install) and by
///     the 14-character serial broadcast in the advertised name.
///   * **No MTU negotiation.** `requestMtu(512)` has no iOS equivalent; the OS
///     negotiates. Callers must respect `maximumWriteValueLength(for:)`.
///   * **No raw advertisement bytes.** Matching is done on the advertised
///     local name instead of searching the raw scan record for the serial.
///   * **No CCCD descriptor write.** `setNotifyValue` performs it implicitly.
///   * Scanning is unfiltered because the vehicle does not advertise the UART
///     service UUID. The OS throttles scans in the background, so pairing is
///     expected to happen in the foreground.
/// CoreBluetooth conformer to `BFGCore.BleTransport`, so the state machine
/// can be driven by a simulated vehicle in tests.
///
/// Every callback and every write runs on `queue`. The state machine calls in
/// from its own queue, so `write` hops across rather than sharing its chunk
/// buffer — two queues touching one `pending` array is how a frame gets half
/// sent.
final class CoreBluetoothTransport: NSObject, BFGCore.BleTransport {
    static let serviceUUID = CBUUID(string: "6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    static let txUUID = CBUUID(string: "6e400002-b5a3-f393-e0a9-e50e24dcca9e")
    static let rxUUID = CBUUID(string: "6e400003-b5a3-f393-e0a9-e50e24dcca9e")

    weak var delegate: BleTransportDelegate?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    /// Scan results are keyed by identifier: the client only ever knows the
    /// opaque identity string, never the CBPeripheral itself.
    private var scanned: [String: CBPeripheral] = [:]
    private var txCharacteristic: CBCharacteristic?

    private let queue = DispatchQueue(label: "com.bfgtools.calibration.ble")
    private var poweredOn = false
    private var connected = false

    /// The write type the discovered characteristic actually supports. Resolved
    /// once, when the characteristic is discovered, and never guessed: see
    /// `BleWritePolicy` for why hard-coding this breaks a working vehicle.
    private var writeType: BleWriteType?
    /// Frames are split at the negotiated limit and then drained one at a time.
    /// Bluetooth allows one acknowledged write in flight, and a without-response
    /// write only when the radio's buffer has room, so the tail of a long frame
    /// is dropped if it is handed over all at once.
    private var pending: [Data] = []
    private var writeInFlight = false
    /// Service discovery gets more than one attempt: the first discovery on a
    /// freshly connected peripheral is exactly where a single silent ATT request
    /// leaves the rider with nothing but a spinner.
    private var discoveryRetry: DispatchWorkItem?
    private var servicesDiscovered = false
    private var discoveryAttempts = 0

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: queue)
    }

    var isPoweredOn: Bool {
        queue.sync { poweredOn }
    }

    /// The largest chunk the platform will accept for the write type in use.
    /// Before the characteristic is known there is no negotiated value to
    /// report, so the guaranteed minimum is used.
    private func writeLimit() -> Int {
        guard let peripheral else { return 20 }
        switch writeType ?? .withResponse {
        case .withResponse: return peripheral.maximumWriteValueLength(for: .withResponse)
        case .withoutResponse: return peripheral.maximumWriteValueLength(for: .withoutResponse)
        }
    }

    private func log(_ line: String) { delegate?.bleTransport(log: line) }

    func startScan() {
        queue.async { [weak self] in
            guard let self, self.central.state == .poweredOn else { return }
            // A peripheral stops advertising the moment anything holds a
            // connection, and a phone whose official app is still in the picture
            // holds exactly that. Scanning alone can then never surface the
            // vehicle — which matches the observed "no 14-character name at all"
            // exports. CoreBluetooth will still hand over whatever the *system*
            // already has connected, by service UUID, and those arrive through
            // the same delegate call a scan result does.
            let connected = self.central.retrieveConnectedPeripherals(
                withServices: [CoreBluetoothTransport.serviceUUID])
            for peripheral in connected {
                let name = peripheral.name ?? ""
                self.log("BLE_RETRIEVED name=\(name.isEmpty ? "(空)" : name) "
                         + "id=\(peripheral.identifier.uuidString)")
                self.scanned[peripheral.identifier.uuidString] = peripheral
                self.delegate?.bleTransport(didDiscover: peripheral.identifier.uuidString,
                                            name: name)
            }
            self.central.scanForPeripherals(withServices: nil,
                                            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
        }
    }

    func stopScan() {
        central.stopScan()
    }

    func connect(identifier: String) {
        queue.async { [weak self] in
            guard let self else { return }
            guard let peripheral = self.scanned[identifier] else {
                // Waiting out the client's connect timeout would hide the one
                // thing worth knowing: this identifier is not in the scan cache.
                self.log("BLE_CONNECT_FAILED 未在扫描结果中找到该车辆")
                self.delegate?.bleTransport(didDisconnect: BleError.deviceNotFound)
                return
            }
            self.peripheral = peripheral
            peripheral.delegate = self
            self.central.connect(peripheral, options: nil)
        }
    }

    /// Asks for the whole service table, not just the Nordic UART UUID.
    ///
    /// The original called `g.discoverServices()` with no filter. Filtering is
    /// the one thing that can turn "this vehicle says something unexpected" into
    /// "nothing came back at all", so the table is requested in full and the log
    /// records it. A silent attempt is retried while the client's own timeout
    /// still has room.
    private func startServiceDiscovery() {
        guard connected, let peripheral else { return }
        discoveryAttempts += 1
        servicesDiscovered = false
        log("BLE_DISCOVER_SERVICES attempt=\(discoveryAttempts)")
        peripheral.discoverServices(nil)
        discoveryRetry?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.connected, !self.servicesDiscovered,
                  self.discoveryAttempts < 3 else { return }
            self.log("BLE_DISCOVER_SERVICES 第 \(self.discoveryAttempts) 次没有回调，重试")
            self.startServiceDiscovery()
        }
        discoveryRetry = item
        queue.asyncAfter(deadline: .now() + 3, execute: item)
    }

    func disconnect() {
        queue.async { [weak self] in
            guard let self else { return }
            if let peripheral = self.peripheral {
                self.central.cancelPeripheralConnection(peripheral)
            }
            self.peripheral = nil
            self.txCharacteristic = nil
            self.writeType = nil
            self.pending = []
            self.writeInFlight = false
            self.connected = false
            self.servicesDiscovered = false
            self.discoveryAttempts = 0
            self.discoveryRetry?.cancel()
            self.discoveryRetry = nil
        }
    }

    /// Queues a frame. The transport splits it at the negotiated limit and sends
    /// the pieces in order, each waiting for the previous one to be accepted.
    func write(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            guard self.connected, self.peripheral != nil else {
                self.delegate?.bleTransport(didWrite: BleError.txNotReady)
                return
            }
            guard self.txCharacteristic != nil, self.writeType != nil else {
                self.delegate?.bleTransport(didWrite: BleError.txNotReady)
                return
            }
            let limit = max(1, self.writeLimit())
            var offset = 0
            while offset < data.count {
                let end = min(offset + limit, data.count)
                self.pending.append(data.subdata(in: offset..<end))
                offset = end
            }
            self.pump()
        }
    }

    /// Sends what is queued as far as the platform currently allows.
    private func pump() {
        guard connected, let peripheral, let tx = txCharacteristic, let writeType else {
            return
        }
        while !pending.isEmpty {
            switch writeType {
            case .withResponse:
                // One acknowledged write at a time; `didWriteValueFor` resumes.
                guard !writeInFlight else { return }
                let chunk = pending.removeFirst()
                writeInFlight = true
                log("BLE_TX len=\(chunk.count) type=withResponse")
                peripheral.writeValue(chunk, for: tx, type: .withResponse)

            case .withoutResponse:
                // No callback acknowledges these, so the only back-pressure
                // signal is the radio itself.
                guard peripheral.canSendWriteWithoutResponse else {
                    queue.asyncAfter(deadline: .now() + 0.02) { [weak self] in self?.pump() }
                    return
                }
                let chunk = pending.removeFirst()
                log("BLE_TX len=\(chunk.count) type=withoutResponse")
                peripheral.writeValue(chunk, for: tx, type: .withoutResponse)
            }
        }
    }
}

extension CoreBluetoothTransport: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        poweredOn = central.state == .poweredOn
        log("BLE_STATE poweredOn=\(poweredOn) raw=\(central.state.rawValue)")
        delegate?.bleTransportDidUpdateState(poweredOn: poweredOn)
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        let localName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let name = localName ?? peripheral.name ?? ""
        scanned[peripheral.identifier.uuidString] = peripheral
        // Whether the serial arrives as the local name or only as the cached
        // device name decides if pairing can find the vehicle at all.
        log("BLE_DISCOVER name=\(name.isEmpty ? "(空)" : name) "
            + "localName=\(localName == nil ? "无" : "有") rssi=\(RSSI)")
        delegate?.bleTransport(didDiscover: peripheral.identifier.uuidString, name: name)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connected = true
        log("BLE_CONNECTED name=\(peripheral.name ?? "(空)")")
        delegate?.bleTransportDidConnect()
        startServiceDiscovery()
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connected = false
        log("BLE_CONNECT_FAILED \(error.map { "err=\($0.localizedDescription)" } ?? "err=nil")")
        delegate?.bleTransport(didDisconnect: error)
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connected = false
        txCharacteristic = nil
        writeType = nil
        pending = []
        writeInFlight = false
        servicesDiscovered = false
        discoveryAttempts = 0
        discoveryRetry?.cancel()
        discoveryRetry = nil
        log("BLE_DISCONNECTED \(error.map { "err=\($0.localizedDescription)" } ?? "err=nil")")
        delegate?.bleTransport(didDisconnect: error)
    }
}

extension CoreBluetoothTransport: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        servicesDiscovered = true
        discoveryRetry?.cancel()
        guard error == nil else {
            log("BLE_SERVICES err=\(error!.localizedDescription)")
            delegate?.bleTransport(didDiscoverServices: error)
            return
        }
        // The whole table goes into the log. A vehicle carrying something other
        // than the Nordic UART service is exactly the case a filter hides, and it
        // is indistinguishable from "no reply" without this line.
        let discovered = (peripheral.services ?? []).map { $0.uuid.uuidString }
        log("BLE_SERVICES 共 \(discovered.count) 个：\(discovered.joined(separator: ","))")
        guard let service = peripheral.services?.first(where: { $0.uuid == CoreBluetoothTransport.serviceUUID })
        else {
            log("BLE_SERVICES 未找到 6E400001")
            delegate?.bleTransport(didDiscoverServices: BleError.serviceNotFound)
            return
        }
        // Unfiltered for the same reason as the services above.
        peripheral.discoverCharacteristics(nil, for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else {
            log("BLE_CHARS err=\(error!.localizedDescription)")
            delegate?.bleTransport(didDiscoverServices: error)
            return
        }
        let found = (service.characteristics ?? []).map {
            "\($0.uuid.uuidString)(0x\(String($0.properties.rawValue, radix: 16)))"
        }
        log("BLE_CHARS 共 \(found.count) 个：\(found.joined(separator: ","))")
        guard let tx = service.characteristics?.first(where: { $0.uuid == CoreBluetoothTransport.txUUID }),
              let rx = service.characteristics?.first(where: { $0.uuid == CoreBluetoothTransport.rxUUID })
        else {
            log("BLE_CHARS 缺少 0002/0003 特征")
            delegate?.bleTransport(didDiscoverServices: BleError.characteristicNotFound)
            return
        }

        let properties = tx.properties
        let supportsWrite = properties.contains(.write)
        let supportsWriteWithoutResponse = properties.contains(.writeWithoutResponse)
        // The single most useful line in this file: it records what the vehicle
        // actually advertises, and which write type was chosen from it.
        log("BLE_CHARS props=\(properties.rawValue) write=\(supportsWrite) "
            + "writeNoRsp=\(supportsWriteWithoutResponse) "
            + "notify=\(rx.properties.contains(.notify))")

        writeType = BleWritePolicy.writeType(supportsWrite: supportsWrite,
                                             supportsWriteWithoutResponse: supportsWriteWithoutResponse)
        guard writeType != nil else {
            log("BLE_CHARS 写入特征不可写")
            delegate?.bleTransport(didWrite: BleError.writeNotPermitted)
            return
        }

        txCharacteristic = tx
        log("BLE_WRITE_LIMIT withResponse=\(peripheral.maximumWriteValueLength(for: .withResponse)) "
            + "withoutResponse=\(peripheral.maximumWriteValueLength(for: .withoutResponse)) "
            + "chosen=\(writeType!.label)")
        // Android wrote the CCCD descriptor by hand; iOS does it here.
        peripheral.setNotifyValue(true, for: rx)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        log("BLE_NOTIFY \(error.map { "err=\($0.localizedDescription)" } ?? "ok")")
        delegate?.bleTransport(didUpdateNotificationState: error)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let data = characteristic.value
        log("BLE_RX len=\(data?.count ?? 0) "
            + (error.map { "err=\($0.localizedDescription)" } ?? "err=nil"))
        guard error == nil, let data else { return }
        delegate?.bleTransport(didReceive: data)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        writeInFlight = false
        if let error {
            log("BLE_TX_FAIL err=\(error.localizedDescription)")
            pending = []
        } else {
            log("BLE_TX_OK")
            pump()
        }
        delegate?.bleTransport(didWrite: error)
    }
}
