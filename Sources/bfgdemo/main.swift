import Foundation
import BFGCore
import BFGSimulator

/// Runs the real `BfgBleClient` state machine against the simulated vehicle.
///
/// This is the Linux stand-in for "app next to a vehicle": the same client
/// code, the same frames, over a transport that reproduces what a central
/// delivers. Each case below drives one flow end to end and reports whether the
/// client reached the outcome the original protocol implies.

final class Collector: BfgBleClient.Listener {
    let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _finished: BfgBleClient.Result?
    private var _failure: String?
    private var _statuses: [String] = []

    var finished: BfgBleClient.Result? { lock.lock(); defer { lock.unlock() }; return _finished }
    var failure: String? { lock.lock(); defer { lock.unlock() }; return _failure }
    var statuses: [String] { lock.lock(); defer { lock.unlock() }; return _statuses }

    func bleClient(didUpdateStatus status: String) {
        lock.lock(); _statuses.append(status); lock.unlock()
    }

    func bleClient(didLog line: String) { }

    func bleClient(didFinish result: BfgBleClient.Result) {
        lock.lock(); _finished = result; lock.unlock()
        semaphore.signal()
    }

    func bleClient(didFailWith message: String) {
        lock.lock(); _failure = message; lock.unlock()
        semaphore.signal()
    }
}

struct CaseResult {
    let name: String
    let passed: Bool
    let detail: String
}

var results: [CaseResult] = []

@discardableResult
func run(_ name: String, vehicle: VirtualVehicle, operation: BfgBleClient.Operation,
         targetProfile: Int = -1, store: InMemoryCredentialStore,
         record: DeviceRecord? = nil, timeout: TimeInterval = 90,
         dumpModules: [Int] = [],
         verify: (Collector, VirtualVehicle) -> String?) -> CaseResult {
    let link = VirtualLink(vehicle: vehicle)
    let collector = Collector()
    let device = record ?? DeviceRecord(id: -1, mac: "", sn: vehicle.config.serial,
                                        name: vehicle.config.serial, deviceType: "",
                                        password16: [UInt8](repeating: 0, count: 16),
                                        source: "simulator")
    let client = BfgBleClient(record: device, operation: operation,
                              targetProfile: targetProfile,
                              dumpModules: dumpModules,
                              transport: link, credentialStore: store,
                              listener: collector)

    print("\n──── \(name) ────")
    client.start()

    if collector.semaphore.wait(timeout: .now() + timeout) == .timedOut {
        let outcome = CaseResult(name: name, passed: false, detail: "超时未结束")
        results.append(outcome)
        print("  ✗ 超时")
        return outcome
    }

    let outcome: CaseResult
    if let problem = verify(collector, vehicle) {
        outcome = CaseResult(name: name, passed: false, detail: problem)
        print("  ✗ \(problem)")
    } else {
        outcome = CaseResult(name: name, passed: true, detail: "符合预期")
        print("  ✓ 符合预期")
    }
    results.append(outcome)
    return outcome
}

func newStore() -> InMemoryCredentialStore { InMemoryCredentialStore() }

// MARK: - 1. 车辆发现

do {
    let vehicle = VirtualVehicle()
    let store = newStore()
    run("车辆发现（列表）", vehicle: vehicle, operation: .discoverVehicles, store: store) { c, v in
        guard c.failure == nil else { return "失败：\(c.failure!)" }
        guard let r = c.finished else { return "无结果" }
        guard r.discoveredVehicles.count == 1 else {
            return "应发现 1 台，实际 \(r.discoveredVehicles.count)"
        }
        return r.discoveredVehicles[0].serial == v.config.serial ? nil
            : "车架号不符：\(r.discoveredVehicles[0].serial)"
    }
}

// MARK: - 2. 首次配对（车端未存密码）

do {
    var cfg = VirtualVehicle.Config()
    cfg.hasStoredPassword = false
    let virgin = VirtualVehicle(config: cfg)
    let store = newStore()
    run("首次配对 + 读取", vehicle: virgin, operation: .pairAndRead, store: store) { c, v in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.pairingConfirmed else { return "未确认配对" }
        guard store.storedSerials.contains(v.config.serial) else { return "凭据未保存" }
        guard v.config.hasStoredPassword else { return "车端未收到新密码" }
        return nil
    }
}

// MARK: - 3. 常规读取（凭据已存在）

let pairedVehicle = VirtualVehicle()
let pairedStore = newStore()
_ = run("预置配对（为后续用例准备凭据）", vehicle: pairedVehicle,
        operation: .pairAndRead, store: pairedStore) { c, _ in
    c.failure == nil ? nil : "准备失败：\(c.failure!)"
}

/// The negotiated password is the shared secret between client and vehicle;
/// every later vehicle has to hold the same one or AUTH cannot succeed.
let sharedPassword = pairedStore.load(serial: pairedVehicle.config.serial)

func makeVehicle(_ mutate: (inout VirtualVehicle.Config) -> Void = { _ in }) -> VirtualVehicle {
    var cfg = VirtualVehicle.Config()
    cfg.storedPassword32 = sharedPassword
    mutate(&cfg)
    return VirtualVehicle(config: cfg)
}

do {
    let vehicle = makeVehicle()
    run("常规读取（完整 DIS 链 + 模式判定）", vehicle: vehicle,
        operation: .readOnly, store: pairedStore) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        // 原版在只读流程里同样走完整条 DIS 识别链
        guard r.disDashboardVersion != -1 else { return "未读到仪表版本（DIS 链被跳过）" }
        guard r.dashboardFirmware != -1 else { return "未读到仪表固件" }
        guard r.disVrlaVoltage != -1 else { return "未读到 DIS 电压" }
        guard r.colorDisplayVersion != -1, r.centreControllerVersion != -1 else {
            return "彩屏/中控版本缺失"
        }
        // Profile and capacity agree in the default vehicle, so this has to
        // resolve as the standard path rather than falling into compatibility.
        guard r.mode == .standard else {
            return "应判定为标准模式，实际 \(CommunicationModeResolver.label(r.mode))"
        }
        guard r.writeSupported else { return "writeSupported 为假，后续写入会被拒" }
        return nil
    }
}

// MARK: - 4. 写入 Profile（车端正常回 ACK）

do {
    let vehicle = makeVehicle()
    run("写入 Profile（ACK 正常）", vehicle: vehicle, operation: .writeProfile,
        targetProfile: 0x21, store: pairedStore) { c, v in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.profileReadbackVerified else { return "未回读确认" }
        guard v.config.profile == 0x21 else { return "车端档位未变为 0x21（实际 0x\(String(v.config.profile, radix: 16))）" }
        return nil
    }
}

// MARK: - 5. 写入 Profile（ACK 丢失，必须靠回读完成）

do {
    let vehicle = makeVehicle { $0.sendWriteAck = false }
    run("写入 Profile（ACK 丢失 → 必须靠回读成功）", vehicle: vehicle,
        operation: .writeProfile, targetProfile: 0x21, store: pairedStore) { c, v in
        if let f = c.failure { return "失败：\(f)（ACK 丢失不应导致失败）" }
        guard let r = c.finished else { return "无结果" }
        guard r.profileReadbackVerified else { return "未回读确认" }
        guard v.config.profile == 0x21 else { return "车端档位未生效" }
        return nil
    }
}

// MARK: - 6. 写入 Profile（车端延迟 2 次回读才生效）

do {
    let vehicle = makeVehicle { $0.writeAppliesAfterReads = 2 }
    run("写入 Profile（延迟生效 → 重试后成功）", vehicle: vehicle,
        operation: .writeProfile, targetProfile: 0x21, store: pairedStore) { c, v in
        if let f = c.failure { return "失败：\(f)（应在重试上限内成功）" }
        guard let r = c.finished else { return "无结果" }
        guard r.verificationRetried else { return "未发生重试，与预期不符" }
        guard r.profileReadbackVerified, v.config.profile == 0x21 else { return "最终未生效" }
        return nil
    }
}

// MARK: - 7. 写入 Profile（车端始终不生效 → 4 次后失败）

do {
    let vehicle = makeVehicle { $0.writeAppliesAfterReads = 99 }
    run("写入 Profile（始终不生效 → 必须失败）", vehicle: vehicle,
        operation: .writeProfile, targetProfile: 0x21, store: pairedStore) { c, _ in
        guard c.failure != nil else { return "应失败但成功了（会掩盖真实写入失败）" }
        return nil
    }
}

// MARK: - 8. N 开头序列号 → 只读

do {
    let vehicle = makeVehicle { $0.serial = "NINEB000000001" }
    let store = newStore()
    run("N 开头序列号 → 拒绝写入", vehicle: vehicle, operation: .writeProfile,
        targetProfile: 0x21, store: store) { c, _ in
        guard let f = c.failure, f.contains("N 开头") else {
            return "应因只读序列号被拒，实际：\(c.failure ?? "成功")"
        }
        return nil
    }
}

// MARK: - 9. 固件不在白名单 → 拒绝写入

do {
    // The dashboard allowlist gates a *dashboard* write only; a meter-profile
    // write is gated by writeSupported instead. 0x0999 is outside the list.
    let vehicle = makeVehicle { $0.dashboardVersion = 0x0999 }
    run("仪表固件不在白名单 → 拒绝仪表盘写入", vehicle: vehicle,
        operation: .writeDisVoltage, targetProfile: 72, store: pairedStore) { c, _ in
        guard let f = c.failure else { return "应被拒但成功了" }
        guard f.contains("仪表盘") else { return "拒绝原因不符：\(f)" }
        return nil
    }
}

// MARK: - 10. 容量兼容扫描（非白名单固件 + 常规容量异常）

do {
    // An unrecognised meter version and an implausible capacity together are
    // what make the client run the compatibility scan.
    let vehicle = makeVehicle {
        $0.meterVersion = 0x0100
        $0.capacityMah = 12345
        $0.compatRegisters = [0x0E: 26000, 0x0F: 26000, 0x1A: 26000, 0x1C: 26000, 0x1E: 26000]
    }
    run("容量兼容扫描 → 判定为兼容模式", vehicle: vehicle, operation: .readOnly,
        store: pairedStore) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.mode == .capacityScanCompat else {
            return "应判定为兼容模式，实际 \(CommunicationModeResolver.label(r.mode))"
        }
        guard r.scannedCapacity == 26000 else { return "扫描选值不符：\(r.scannedCapacity)" }
        return nil
    }
}

// MARK: - 11. 容量扫描寄存器全部无响应 → 不致命

do {
    // The compatibility registers go silent, but 0x1C still answers: the scan
    // must tolerate silence rather than treat it as fatal. (Silencing 0x1C
    // itself would instead fail the earlier capacity read, which is also what
    // the original does, so it is not a scan-tolerance case.)
    let vehicle = makeVehicle {
        $0.meterVersion = 0x0100
        $0.silentRegisters = [VirtualVehicle.Register(0x10, 0x0E),
                              VirtualVehicle.Register(0x10, 0x0F),
                              VirtualVehicle.Register(0x10, 0x1A),
                              VirtualVehicle.Register(0x10, 0x1E)]
    }
    run("容量兼容扫描（部分寄存器无响应）→ 不致命", vehicle: vehicle,
        operation: .readOnly, store: pairedStore, timeout: 180) { c, _ in
        guard let r = c.finished else { return "应完成而非崩溃：\(c.failure ?? "无结果")" }
        guard r.mode == .capacityScanCompat else {
            return "应回退到 0x1C 并判为兼容模式，实际 \(CommunicationModeResolver.label(r.mode))"
        }
        guard r.scannedCapacity == 26000 else { return "回退取值不符：\(r.scannedCapacity)" }
        return nil
    }
}

// MARK: - 12. 寄存器只读扫描

do {
    let vehicle = makeVehicle()
    run("寄存器只读扫描（仪表盘）", vehicle: vehicle, operation: .registerScan,
        targetProfile: RegisterReadPlan.dashboard, store: pairedStore, timeout: 180) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.registerScanReplies > 0 else { return "未收到任何应答" }
        guard r.registerScanTimeouts + r.registerScanReplies > 0 else { return "计数未回填" }
        return nil
    }
}

// MARK: - 13. 寄存器快照（写前备份的底座）

do {
    let vehicle = makeVehicle()
    run("寄存器快照：两遍读取与静态表一致性", vehicle: vehicle,
        operation: .dumpRegisters, store: pairedStore, timeout: 300,
        dumpModules: [RegisterDump.dashboardModule, 0x09, RegisterDump.meterModule]) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished, let dump = r.registerDump else { return "未产出快照" }
        guard dump.entries.count == 256 * 3 else {
            return "条目数应为 \(256 * 3)，实际 \(dump.entries.count)"
        }
        guard dump.fingerprint.isComplete else { return "固件指纹不完整" }
        // 车端 profile 与容量自洽，静态表应当被认为成立
        guard dump.agreement() == .agrees else {
            return "静态表一致性判定异常：\(dump.agreement())"
        }
        guard let profile = dump.entry(module: RegisterDump.meterModule, index: 0x00),
              profile.value == vehicle.config.profile else { return "profile 地址读取不符" }
        guard let capacity = dump.entry(module: RegisterDump.meterModule, index: 0x1C),
              capacity.value == vehicle.config.capacityMah else { return "容量地址读取不符" }
        return nil
    }
}

// MARK: - 14. 静态表与车辆不符时必须能检出

do {
    // 车端容量落在一个静态表根本叫不出名字的值上，才是「这版固件与静态表不一致」。
    //
    // 这里不能用表内的值（例如早先用的 18000）：桩位与容量脱节、而容量本身在表内，
    // 说明这张表恰恰描述得了这台车 —— 那个状态可以被一次正确写入修复。把它判成
    // "表不适用"会把唯一的出路堵死，真机上就是这么卡住的。
    let vehicle = makeVehicle { $0.capacityMah = 21000 }
    run("静态表一致性：车端容量不在表内时必须检出", vehicle: vehicle,
        operation: .dumpRegisters, store: pairedStore, timeout: 300,
        dumpModules: [RegisterDump.meterModule]) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished, let dump = r.registerDump else { return "未产出快照" }
        guard case .disagrees(let expected, let reported) = dump.agreement() else {
            return "应判为不一致，实际 \(dump.agreement())"
        }
        guard expected == 26000, reported == 21000 else {
            return "不一致详情不符：期望 26000 / 实际 \(reported)"
        }
        return nil
    }
}

// MARK: - 14b. 数值重叠但表不适用：仍必须判不一致

do {
    // 复刻真机数字：档位字节 0x50（表说 26000），容量寄存器 20000 —— 而 20000 恰好
    // 是本表索引 0 的值。曾经有一版据此放行，结果那次写入把车的容量改成了没人要
    // 求的数字（真机实测：表说 0xC0 = 46000，车回 26000）。
    // 数值重叠不等于两张表一致 —— 判不一致才是正确的。
    let vehicle = makeVehicle { $0.capacityMah = 20000 }
    run("静态表一致性：数值重叠但仍不符时必须判不一致", vehicle: vehicle,
        operation: .dumpRegisters, store: pairedStore, timeout: 300,
        dumpModules: [RegisterDump.meterModule]) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished, let dump = r.registerDump else { return "未产出快照" }
        guard case .disagrees(let expected, let reported) = dump.agreement() else {
            return "应判为不一致，实际 \(dump.agreement())"
        }
        guard expected == 26000, reported == 20000 else {
            return "不一致详情不符：期望 26000 / 实际 \(reported)"
        }
        return nil
    }
}

// MARK: - 15. 未适配车型：读到车辆自报值（并仍拒绝写入）

do {
    // 档位字节 0x5F 的电压位非法，静态表无法解释它 —— 这正是「没适配」
    // 的情形。车端仍然会报自己的容量，重复探测也能测出来；这两条路都不
    // 依赖静态表。
    let vehicle = makeVehicle { $0.profile = 0x5F }
    run("未适配档位：读出车辆自报容量并标注未验证", vehicle: vehicle,
        operation: .readOnly, store: pairedStore) { c, _ in
        if let f = c.failure { return "失败：\(f)" }
        guard let r = c.finished else { return "无结果" }
        guard r.mode == .unsupported else { return "应判为未验证组合，实际 \(r.mode)" }
        guard r.displayBeforeCapacity > 0 else { return "没有显示车辆自报的容量" }
        guard r.capacityIsUnverified else { return "未标注为未验证" }
        guard !r.writeSupported else { return "未验证组合绝不能允许写入" }
        guard r.profileRaw == 0x5F else { return "档位读数不符：\(r.profileRaw)" }
        return nil
    }
}

// MARK: - 汇总

print("\n" + String(repeating: "═", count: 62))
print("结果汇总")
print(String(repeating: "═", count: 62))
for r in results {
    print(String(format: "  %@ %-38@ %@", r.passed ? "✓" : "✗", r.name as NSString, r.detail))
}
let failed = results.filter { !$0.passed }.count
print(String(repeating: "─", count: 62))
print("  \(results.count - failed)/\(results.count) 通过")
if failed > 0 {
    print("  失败 \(failed) 项")
    exit(1)
}
