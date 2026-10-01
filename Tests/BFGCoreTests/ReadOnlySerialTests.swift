import XCTest
@testable import BFGCore
import BFGSimulator

/// The N-prefix rule is a **write** rule, and only that.
///
/// The original guards exactly \`WRITE_PROFILE\` and \`WRITE_DIS_VOLTAGE\`. The port
/// first expressed it the other way round — "allow readOnly / compareRead /
/// registerScan" — which also swallowed pairing and the register sweep. An
/// N-prefixed vehicle then could not negotiate the credential that reading
/// requires at all: the app was unusable on it, not read-only. These tests pin
/// the guard to the original's shape.
final class ReadOnlySerialTests: XCTestCase {

    private static let serial = "NFDB02619J0740"

    private final class Recorder: BfgBleClient.Listener {
        let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var _failure: String?
        private var _finished: BfgBleClient.Result?

        var failure: String? { lock.lock(); defer { lock.unlock() }; return _failure }
        var finished: BfgBleClient.Result? { lock.lock(); defer { lock.unlock() }; return _finished }

        func bleClient(didUpdateStatus status: String) { }
        func bleClient(didLog line: String) { }
        func bleClient(didFinish result: BfgBleClient.Result) {
            lock.lock(); _finished = result; lock.unlock(); done.signal()
        }
        func bleClient(didFailWith message: String) {
            lock.lock(); _failure = message; lock.unlock(); done.signal()
        }
    }

    private func makeClient(_ operation: BfgBleClient.Operation,
                            targetProfile: Int = -1,
                            dumpModules: [Int] = [],
                            hasStoredPassword: Bool = true,
                            store: CredentialStore = InMemoryCredentialStore())
        -> (BfgBleClient, VirtualLink, Recorder) {
        var config = VirtualVehicle.Config()
        config.serial = Self.serial
        config.hasStoredPassword = hasStoredPassword
        let link = VirtualLink(vehicle: VirtualVehicle(config: config))
        let recorder = Recorder()
        let record = DeviceRecord(id: -1, mac: "", sn: Self.serial, name: Self.serial,
                                  deviceType: "",
                                  password16: [UInt8](repeating: 0, count: 16),
                                  source: "simulator")
        let client = BfgBleClient(record: record, operation: operation,
                                  targetProfile: targetProfile,
                                  dumpModules: dumpModules,
                                  transport: link,
                                  credentialStore: store,
                                  listener: recorder)
        return (client, link, recorder)
    }

    private func assertWriteRefused(_ operation: BfgBleClient.Operation,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let (client, link, recorder) = makeClient(operation)
        client.start()
        XCTAssertEqual(.success, recorder.done.wait(timeout: .now() + 5),
                       "写入应当立即被拒，而不是等超时", file: file, line: line)
        XCTAssertTrue(recorder.failure?.contains("N 开头") ?? false,
                      "应当以 N 开头规则拒绝：\(recorder.failure ?? "没有失败")", file: file, line: line)
        XCTAssertEqual(0, link.connectCalls, "拒绝写入时不应该连接车辆", file: file, line: line)
        XCTAssertTrue(link.writes.isEmpty, "拒绝写入时不应该发出任何指令", file: file, line: line)
    }

    func testProfileWriteIsRefusedOnAnNPrefixedSerial() {
        assertWriteRefused(.writeProfile)
    }

    func testDashboardWriteIsRefusedOnAnNPrefixedSerial() {
        assertWriteRefused(.writeDisVoltage)
    }

    /// Pairing negotiates its own credential, so the rule must not stop it.
    /// Without pairing there is no key, and on this platform no key means no
    /// read either.
    func testPairingIsNotRefusedOnAnNPrefixedSerial() {
        let (client, link, recorder) = makeClient(.pairAndRead, hasStoredPassword: false)
        client.start()
        _ = recorder.done.wait(timeout: .now() + 20)
        XCTAssertGreaterThan(link.connectCalls, 0, "配对被 N 前缀规则误伤")
        XCTAssertFalse(link.writes.isEmpty, "配对应当已经发出 PRE_COMM")
    }

    /// A sweep sends read frames only, so the rule has nothing to say about it.
    /// The assertion is on the *reason*: with no stored credential it still
    /// stops, but for the credential — not for the serial.
    func testRegisterSweepIsNotRefusedByTheSerialRule() {
        let (client, _, recorder) = makeClient(.registerScan,
                                               targetProfile: RegisterReadPlan.dashboard)
        client.start()
        _ = recorder.done.wait(timeout: .now() + 5)
        XCTAssertFalse(recorder.failure?.contains("N 开头") ?? false,
                       "只读扫描被 N 前缀规则误伤：\(recorder.failure ?? "")")
    }

    /// Same for the register dump, which is what the adaptation work reads.
    func testRegisterDumpIsNotRefusedByTheSerialRule() {
        let (client, _, recorder) = makeClient(.dumpRegisters,
                                               dumpModules: [RegisterDump.dashboardModule])
        client.start()
        _ = recorder.done.wait(timeout: .now() + 5)
        XCTAssertFalse(recorder.failure?.contains("N 开头") ?? false,
                       "寄存器快照被 N 前缀规则误伤：\(recorder.failure ?? "")")
    }
}
