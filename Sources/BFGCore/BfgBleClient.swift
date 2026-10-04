import Foundation

/// Port of the Android `BfgBleClient`.
///
/// The protocol layer — frame format, Encryption2, the state sequence, retry
/// and timeout policy — is byte-identical to Android. The transport and the
/// credential store are injected (see `BleTransport` and `CredentialStore`), so
/// this state machine runs unchanged against CoreBluetooth on device and
/// against a simulated vehicle under `swift test`.
///
/// Credential source differs by design: Android read the official Ninebot
/// app's database (via root or a virtualised container). iOS reads the Keychain
/// entry written by this app's own pairing flow. See `KeychainCredentialStore`.
public final class BfgBleClient: NSObject {

    // MARK: - Public surface

    public enum Operation {
        case readOnly
        case compareRead
        case writeProfile
        case writeDisVoltage
        case pairAndRead
        case registerScan
        /// Collects nearby vehicles for the user to confirm before pairing,
        /// rather than connecting to the first match.
        case discoverVehicles
        /// Sweeps a module's whole register space twice, so a write can be
        /// measured against what the vehicle held beforehand.
        case dumpRegisters
        /// Writes the rated-capacity word at 0x0E — the second and only other
        /// write site. Separate from `.writeProfile` on purpose: it carries its
        /// own policy flag, its own rollback slot and its own watch window.
        case writeCapacity
        /// Asks which capacity candidates accept a write at all.
        ///
        /// Each address is written its OWN current value back, so a successful
        /// probe changes nothing on the vehicle — it only distinguishes "this
        /// register accepts a write" from "this register is read-only", which is
        /// the question 0x0E answered with silence.
        case probeRegisterWrites
        /// Walks the firmware table's capacities upward from the vehicle's own
        /// value, asking which ones this module will accept.
        ///
        /// The only mode where the tool deliberately writes a value it did not
        /// read: every candidate is written and then immediately reverted, and the
        /// revert is verified before the next candidate starts. If a revert cannot
        /// be confirmed the run stops rather than continuing to drift.
        case sweepCapacityValues
    }

    public protocol Listener: AnyObject {
        func bleClient(didUpdateStatus status: String)
        func bleClient(didLog line: String)
        func bleClient(didFinish result: Result)
        func bleClient(didFailWith message: String)
    }

    /// Failure text for a central that reports Bluetooth as unavailable. The
    /// host compares against it to offer the system Bluetooth settings, so it is
    /// a shared constant rather than a string written twice.
    public static let bluetoothOffMessage = "系统蓝牙未开启"

    public final class Result {
        public var serial = ""
        public var profileRaw = -1
        public var bfgSoc = -1
        public var bfgCapacity = -1
        public var disBatterySoc = -1
        public var disEnergyWh = -1
        public var disRemainingCapacity = -1
        public var disVrlaVoltage = -1
        public var disBfgVersion = -1
        public var disDashboardVersion = -1
        public var colorDisplayVersion = -1
        public var centreControllerVersion = -1
        public var disConfigRaw = -1
        public var dashboardFirmware = -1
        public var meterFirmware = -1
        public var pairingConfirmed = false
        public var writeCommandSent = false
        public var disConfigReadbackVerified = false
        public var profileReadbackVerified = false
        public var mode: CommunicationModeResolver.Mode = .unsupported
        public var writeSupported = false
        public struct DiscoveredVehicle {
            public let serial: String
            public let identifier: String
        }

        public var discoveredVehicles: [DiscoveredVehicle] = []
        public var scannedCapacity = -1
        public var scannedCapacityRegister = -1
        public var capacityScanReason = ""
        public var registerScanReplies = 0
        public var registerScanTimeouts = 0
        public var registerScanModule = -1
        /// Populated by `.dumpRegisters`.
        public var registerDump: RegisterDump?

        // Write path, mirroring the Android `Result` fields of the same role.
        public var writeAckSeen = false
        public var writeAckFrame = ""
        public var afterProfile = -1
        public var afterCapacityRaw = -1
        public var capacityReadbackVerified = false
        public var verificationRetried = false
        public var disConfigTargetRaw = -1
        public var disConfigAfterRaw = -1
        public var resolvedBeforeSoc = -1
        public var resolvedBeforeCapacityRaw = -1
        public var resolvedAfterCapacityRaw = -1
        /// The rated-capacity register (0x0E) as it stood before and after a
        /// capacity write. Exposed so the coordinator can persist both: the
        /// before value is the rollback target, the after value is the evidence.
        /// Which capacity candidates accepted a probe write, and which stayed
        /// silent. The second list is the more useful one: it says the capacity
        /// route needs a different mechanism, not a different value.
        /// Which firmware-table capacities the module accepted, and which it
        /// refused. Together they bound the range this module will honour, which
        /// is the question the probe left open.
        public var sweepAccepted: [Int] = []
        public var sweepRefused: [Int] = []
        public var probeWritable: [Int] = []
        public var probeReadOnly: [Int] = []
        public var capacityRatedBefore = -1
        public var capacityRatedAfter = -1

        /// Android substitutes the scanned capacity for the raw 0x1C reading when
        /// the vehicle only resolved in compatibility mode. An unsupported
        /// combination reports no capacity rather than a misleading raw value.
        public var displayBeforeCapacity: Int {
            if resolvedBeforeCapacityRaw >= 0 { return resolvedBeforeCapacityRaw }
            guard mode == .unsupported else { return bfgCapacity }
            // An unrecognised firmware still reports its own capacity. Withholding
            // it says less than showing it labelled for what it is: the number
            // comes from the vehicle, and only its interpretation is unconfirmed.
            // Nothing about the write gate changes — an unsupported combination
            // still refuses to write.
            if CapacityCompatibilityResolver.isPlausible(scannedCapacity) { return scannedCapacity }
            return CapacityCompatibilityResolver.isPlausible(bfgCapacity) ? bfgCapacity : -1
        }

        /// True when `displayBeforeCapacity` is the vehicle's own figure on a
        /// combination the tool could not resolve. The page labels it rather than
        /// presenting it as a confirmed reading.
        public var capacityIsUnverified: Bool {
            mode == .unsupported && resolvedBeforeCapacityRaw < 0 && displayBeforeCapacity > 0
        }
        /// Counterpart of `displayBeforeCapacity` for a completed write: the
        /// value the vehicle reported back, or nothing when the combination was
        /// unsupported and no trustworthy reading exists.
        public var displayAfterCapacity: Int {
            if resolvedAfterCapacityRaw >= 0 { return resolvedAfterCapacityRaw }
            return mode == .unsupported ? -1 : afterCapacityRaw
        }

        public var displaySoc: Int { resolvedBeforeSoc >= 0 ? resolvedBeforeSoc : bfgSoc }

        public var meterNominalVoltage: Int {
            profileRaw < 0 ? -1 : BfgProfileCatalog.nominalVoltage(profileRaw)
        }
        public var dashboardNominalVoltage: Int {
            let configured = DisVoltageConfig.nominalVoltage(disConfigRaw)
            return configured >= 0 ? configured : DashboardVoltageResolver
                .resolve(energyWh: disEnergyWh, remainingCapacityMah: disRemainingCapacity)
                .nominalVoltage
        }
    }

    // MARK: - State

    private enum State {
        case idle, scanning, connecting, discovering, subscribing
        case waitPreComm, waitPairAuthRetries, waitPairConfirm, waitAuth
        case waitBeforeProfile, waitBeforeSoc, waitBeforeCapacity
        case waitDisDashboardVersion, waitDisEnergyWh, waitDisRemainingCapacity
        case waitDisBattery, waitDisVrlaVoltage, waitDisBfgVersion
        case waitColorDisplayVersion, waitCentreControllerVersion
        case waitDisConfig, waitDisWriteAck, waitDisAfter
        case waitCapacityCompatScan, waitRegisterScan, waitDumpScan
        case waitWriteAck, waitAfterProfile, waitAfterCapacity
        case watchAfterWrite
        case waitCapacityPreRead, waitCapacityWriteAck, waitAfterCapacityWrite, watchCapacity
        case probePreRead, probeWrite, probeVerify
        case sweepPreRead, sweepTryWrite, sweepVerify, sweepRestore, sweepRestoreVerify
        case done
    }

    private weak var listener: Listener?
    private let operation: Operation
    private let targetProfile: Int
    /// Target for `.writeCapacity`. Zero means "not a capacity write".
    private let targetCapacity: Int
    private let record: DeviceRecord
    private let result = Result()

    private let transport: BleTransport
    private let credentialStore: CredentialStore
    private var crypto: Encryption2?
    private var state: State = .idle
    private var finished = false

    private var password16: [UInt8] = []
    private var pairingPassword32: [UInt8] = []
    private var pairingChallenge16: [UInt8] = []
    private var pairingSerial14: [UInt8] = []
    private var nextCounter = 1

    private var profileVerifyAttempts = 0
    private var capacityVerifyAttempts = 0
    private var disVerifyAttempts = 0
    private var readsCompleted = 0

    private var registerScanModule = 0
    private var registerScanIndex = 0

    /// Capacity compatibility scan: `[register][repeat]`, rows initialised to -1
    /// so a register that never answered cannot be mistaken for a zero reading.
    private var capacityScanValues = [[Int]](repeating: [Int](repeating: -1, count: 3), count: 5)
    private var capacityScanLastFrames = [String](repeating: "", count: 5)
    private var capacityScanRegisterIndex = 0
    private var capacityScanRepeatIndex = 0

    /// Verification is driven by its own work item rather than `timeout`, because
    /// a lost write ACK must fall through to a read-back instead of failing.
    private var verifyWork: DispatchWorkItem?
    private var verifyScheduled = false
    private var profileRetryPending = false

    /// DIS config the user was shown when the write was confirmed, so a value
    /// that moved underneath us aborts instead of being overwritten.
    private let expectedDisConfigRaw: Int
    /// Set once the user accepted an unvalidated dashboard voltage encoding.
    private let allowUnverifiedDis: Bool

    /// Identifies the client's own queue, so a callback that already runs on it
    /// is not dispatched onto itself.
    private static let queueKey = DispatchSpecificKey<UInt8>()

    private var timeoutWork: DispatchWorkItem?

    // MARK: - Post-write watch
    //
    // The write path used to end the instant the byte read back correctly —
    // which is exactly where the interesting part starts. On the real vehicle
    // the write is accepted (WRITE_ACK), reads back as the target, and is then
    // silently restored a few seconds later; because the client disconnected
    // immediately afterwards, no export has ever contained the revert itself,
    // only its aftermath. Re-reading the one byte while still connected turns
    // "it goes back after a while" into "it went back at T+4.20s".
    //
    // Read-only: this re-sends NinebotFrame.readProfile and nothing else. No
    // write frame is constructible from here, and targetProfile is only ever
    // compared against, never re-sent.
    private var watchTimer: DispatchWorkItem?
    private var watchStart = DispatchTime.now()
    private var watchChangedAt: Double = -1
    private var watchLastValue = -1
    /// Every transition seen during the window, in order.
    ///
    /// Reporting only the first one is what made a configuration rewrite look
    /// like a single revert: the real vehicle went 0xD0 -> 0x50 -> 0x00 -> 0x50
    /// inside seven seconds, and the summary named only the first hop. The shape
    /// is the finding — three hops is an upstream module rewriting the register,
    /// one hop is a restore — so the whole trace is kept and reported.
    private var watchTransitions: [String] = []

    // MARK: - Capacity-register write (0x0E) and its watch
    //
    // Why this exists: the profile byte declares a capacity that 0x0E also
    // holds, and a vehicle that finds the two disagreeing restores the
    // declaration about 6.5 s later — measured, not guessed (write 0xD0 at
    // T+164.41, applied T+166.57, held until T+173.14, reverted to the byte
    // that agrees with the 26000 still in 0x0E). A tool that can only write
    // the declaration can therefore never make a change survive.
    //
    // The watch samples THREE registers in rotation rather than one. The
    // question is not only "did 0x0E stick" but "did the profile follow it, and
    // did the mirror at 0x0F agree" — that triple is what distinguishes a
    // self-consistent vehicle from one whose registers have drifted apart.
    private var capacityRegVerifyAttempts = 0
    private var capacityWatchTick = 0
    private var capacityWatchStart = DispatchTime.now()
    private var capacityWatchTimer: DispatchWorkItem?
    private var capacityBefore = -1
    private var capacityAfter = -1
    private var capacityMirror = -1
    private var capacityProfileSeen = -1
    private var capacityChangedAt: Double = -1
    private var capacityReverted = false

    /// Probed in strict rotation so a three-register round still samples the
    /// primary register often enough to timestamp a revert to within ~1.5 s.
    private static let capacityProbeRotation = [0x0E, 0x0F, 0x00]

    // MARK: - Register-write probe
    //
    // 0x0E answered a well-formed write frame with total silence: no BLE_RX, no
    // WRITE_ACK, and the value unchanged across three re-reads. That is a
    // different failure from the profile byte, which ACKs in ~13 ms and is then
    // reverted by an upstream module. So before giving up on the capacity route,
    // the tool asks the only question that matters: do ANY of the capacity
    // registers accept a write?
    //
    // Every probe writes back the value it just read, so the vehicle ends where
    // it started. What is being measured is the ACK, not the value.
    private var probeQueue: [Int] = []
    private var probeCursor = 0
    private var probeRegister = -1
    private var probeValue = -1
    private var probeAckSeen = false
    private var probeWritable: [Int] = []
    private var probeReadOnly: [Int] = []

    // MARK: - Capacity sweep
    //
    // The probe answered the binary question — 0x0E accepts writes — and left the
    // real one open: it accepted 26000 and refused 55000, so the module has a
    // range, not a lock. This walks that range using values the firmware table
    // already names, smallest first, so the boundary is found in steps.
    //
    // Every candidate is reverted before the next one is attempted, and the
    // revert is read back. sweepOriginal is captured once and never rewritten:
    // if any step cannot restore it, the run stops with the register wherever it
    // is rather than walking further away from where it started.
    private var sweepCandidates: [Int] = []
    private var sweepCursor = 0
    private var sweepOriginal = -1
    private var sweepValue = -1
    private var sweepAckSeen = false
    private var sweepAccepted: [Int] = []
    private var sweepRefused: [Int] = []

    private func capacityWatchElapsed() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- capacityWatchStart.uptimeNanoseconds)
            / 1_000_000_000
    }
    /// From policy, not a constant: expert mode watches longer, because a
    /// vehicle nobody has validated is exactly where a forced revert shows up.
    private var watchDuration: Double { WriteAccessPolicy.watchSeconds() }
    private static let watchInterval: Double = 0.5
    private let queue = DispatchQueue(label: "com.bfgtools.calibration.client")

    /// Modules to sweep for a register dump, in order.
    private let dumpModules: [Int]
    private var dumpModuleCursor = 0
    private var dumpIndex = 0
    /// 0 records the first reading, 1 re-reads to establish stability.
    private var dumpPass = 0
    private var dumpFirstPass: [String: Int] = [:]
    private var dumpEntries: [RegisterDump.Entry] = []

    /// How long the vehicle list scans before reporting what it found. Public so
    /// the host can show the rider the same countdown it is actually waiting on,
    /// instead of a number of its own.
    public static let discoveryWindow: Double = 8
    /// Vehicles seen during a `.discoverVehicles` scan, de-duplicated by the
    /// peripheral identifier iOS assigns.
    private var discoveredVehicles: [(serial: String, identifier: String)] = []

    /// Serial broadcast in the advertised name, learned during the scan.
    private var discoveredSerial = ""
    /// Set when `start()` ran before CoreBluetooth reported its state.
    private var awaitingCentralState = false

    public init(record: DeviceRecord, operation: Operation, targetProfile: Int = -1,
             targetCapacity: Int = 0,
         expectedDisConfigRaw: Int = -1, allowUnverifiedDis: Bool = false,
         dumpModules: [Int] = [],
         transport: BleTransport, credentialStore: CredentialStore,
         listener: Listener) {
        self.record = record
        self.operation = operation
        self.targetProfile = targetProfile
        self.targetCapacity = targetCapacity
        self.expectedDisConfigRaw = expectedDisConfigRaw
        self.allowUnverifiedDis = allowUnverifiedDis
        self.dumpModules = dumpModules
        self.transport = transport
        self.credentialStore = credentialStore
        self.listener = listener
        super.init()
        queue.setSpecific(key: BfgBleClient.queueKey, value: 1)
        transport.delegate = self
    }

    // MARK: - Lifecycle

    /// Operations that authenticate with a credential this app stored earlier.
    /// Pairing negotiates a fresh one, and discovery never authenticates at all.
    private var needsStoredCredential: Bool {
        operation != .pairAndRead && operation != .discoverVehicles
    }

    public func start() {
        do {
            // The original guards exactly the two write operations:
            //
            //     if ((operation == WRITE_PROFILE || operation == WRITE_DIS_VOLTAGE)
            //             && isReadOnlySerial(record.effectiveSn)) throw ...
            //
            // Written the other way round — "allow these three" — the rule also
            // swallowed pairing and the register sweep. An N-prefixed vehicle then
            // could not negotiate the credential that reading requires at all, so
            // the app was unusable on it rather than read-only. A read-only serial
            // means "send no writes", not "run no operations".
            if (operation == .writeProfile || operation == .writeDisVoltage),
               WriteAccessPolicy.isReadOnlySerial(record.effectiveSn) {
                throw NSError(domain: "bfg", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "该序列号以 N 开头，仅允许读取，不发送任何写入指令。"])
            }

            // Keychain replaces the Android database read. Pairing deliberately
            // ignores any stored key and negotiates a fresh one.
            let stored = operation == .pairAndRead
                ? nil
                : credentialStore.load(serial: record.effectiveSn)

            // The original always had a fallback password: it could read one out
            // of the Ninebot database. The Keychain entry this app's own pairing
            // wrote is the only source here, and without it AUTH cannot succeed —
            // the vehicle only answers once the handshake proves we hold the key.
            // Failing here says which of the two it is; failing later reads as
            // "AUTH无回复" and sends the rider looking at the vehicle instead of
            // at the missing pairing.
            if needsStoredCredential, stored == nil {
                throw NSError(domain: "bfg", code: 12, userInfo: [NSLocalizedDescriptionKey:
                    record.effectiveSn.isEmpty
                        ? "尚未选择车辆。请先完成一次配对，或在设置中选择已配对的车辆。"
                        : "本机没有这辆车的配对凭据（未配对，或凭据已失效）。"
                          + "请先在设置中完成「临时密钥配对」，之后才能读取或写入。"])
            }

            // The store keeps the full 32-byte pairing password; the session key
            // is derived from its first half only. The original truncates here
            // with `Arrays.copyOf(locallyPaired, 16)`; passing all 32 through
            // makes every non-pairing session fail with an invalid key length.
            password16 = stored.map { Array($0.prefix(16)) } ?? record.passwordCopy()

            // CBCentralManager starts in `.unknown` and only reports
            // `.poweredOn` asynchronously. Treating that initial state as
            // "Bluetooth is off" would fail every first launch, so the scan
            // waits for the delegate callback instead — but not indefinitely: a
            // state report that never arrives would otherwise leave the page
            // spinning with nothing to show for it.
            if transport.isPoweredOn {
                beginScan()
            } else {
                awaitingCentralState = true
                status("正在等待蓝牙就绪…")
                timeout(.idle, 6, "系统没有报告蓝牙状态。请确认蓝牙已开启、本应用已获蓝牙权限，然后重试。")
            }
        } catch {
            fail(describe(error))
        }
    }

    private func beginScan() {
        state = .scanning
        transport.startScan()
        if operation == .discoverVehicles {
            status("正在搜索附近车辆…")
            // Running the window out is a normal outcome here, not a failure:
            // "nothing found" is still an answer the page can show.
            let item = DispatchWorkItem { [weak self] in
                guard let self, !self.finished, self.state == .scanning else { return }
                self.finishDiscovery()
            }
            timeoutWork = item
            queue.asyncAfter(deadline: .now() + Self.discoveryWindow, execute: item)
            return
        }
        status("正在扫描车辆蓝牙…")
        // 15 s is generous for a foreground scan; the vehicle advertises
        // continuously once awake.
        timeout(.scanning, 10, "未扫描到车辆；请唤醒车辆后重试")
    }

    private func finishDiscovery() {
        result.discoveredVehicles = discoveredVehicles.map {
            Result.DiscoveredVehicle(serial: $0.serial, identifier: $0.identifier)
        }
        // How many of the devices seen were even candidates. Zero says the
        // vehicle never advertised a 14-character name — a different problem
        // from a connection that gets made and then stalls.
        log("SCAN_DONE 候选=\(discoveredVehicles.count) "
            + "名字=\(discoveredVehicles.map { $0.serial }.joined(separator: ","))")
        finish(discoveredVehicles.isEmpty
               ? "未搜索到车辆；请唤醒车辆后重试。"
               : "已找到 \(discoveredVehicles.count) 台车辆。")
    }

    public func cancel() {
        finishNow()
    }

    private func finishNow() {
        finished = true
        timeoutWork?.cancel()
        transport.stopScan()
        transport.disconnect()
    }

    private func finish(_ message: String) {
        guard !finished else { return }
        finishNow()
        state = .done
        status(message)
        listener?.bleClient(didFinish: result)
    }

    private func fail(_ message: String) {
        guard !finished else { return }
        finishNow()
        listener?.bleClient(didFailWith: message)
    }

    private func status(_ text: String) { listener?.bleClient(didUpdateStatus: text) }
    private func log(_ text: String) { listener?.bleClient(didLog: text) }

    // MARK: - Timeouts

    private func timeout(_ expected: State, _ seconds: Double, _ message: String) {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, self.state == expected else { return }
            self.handleTimeout(expected, message)
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    /// Decides what a silent register means.
    ///
    /// Most registers are optional: the original keeps walking the chain and
    /// lets the communication-mode resolver weigh whatever did arrive. Only the
    /// states with nothing to fall back on end the run — which is why one
    /// unanswered address must not abort an entire read.
    private func handleTimeout(_ expected: State, _ message: String) {
        switch expected {
        case .waitDisDashboardVersion, .waitDisEnergyWh, .waitDisRemainingCapacity,
             .waitDisBattery, .waitDisVrlaVoltage, .waitDisBfgVersion,
             .waitColorDisplayVersion, .waitCentreControllerVersion:
            log("识别阶段某寄存器无回复；继续后续读取。")
            advanceDisChain()

        case .waitDisConfig:
            // A dashboard write cannot go ahead without knowing the current
            // value; every other operation carries on with what it has.
            if operation == .writeDisVoltage {
                fail("仪表配置未读取到，本次没有发送写入。")
            } else {
                log("仪表配置无回复；使用已有读数继续。")
                afterDisConfigRead()
            }

        case .sweepPreRead:
            // Without a baseline there is nothing to revert to, so this one stops
            // before any write rather than carrying on.
            fail("试探前无法读取 0x0E 原值；本次没有发送任何写入指令。")

        case .sweepTryWrite:
            // Silent is a result here too: fall through to the read-back, which
            // decides by the register rather than by the ACK.
            log(String(format: "SWEEP_ACK v=%d 无（车沉默）", sweepValue))
            readBackSweepValue()

        case .sweepVerify:
            // Still has to be reverted: an unreadable value is not a reason to
            // leave the register holding a candidate.
            log(String(format: "SWEEP_RESULT v=%d 回读无回复 → 拒绝", sweepValue))
            sweepRefused.append(sweepValue)
            restoreSweepValue()

        case .sweepRestore:
            fail(String(format: "恢复写入无回复；0x0E 可能仍停留在 %d，请重新连接核对后再试。",
                        sweepValue))

        case .sweepRestoreVerify:
            fail(String(format: "恢复后无法回读确认；0x0E 状态未知（原值 %d，最后一次写入 %d）。"
                        + "请重新连接并核对。", sweepOriginal, sweepValue))

        case .probePreRead:
            log(String(format: "PROBE_RESULT 0x%02X 预读无回复，跳过", probeRegister))
            advanceProbe()

        case .probeVerify:
            // A silent re-read after a silent write is the read-only signature,
            // not an error: 0x0E behaved exactly this way.
            log(String(format: "PROBE_RESULT 0x%02X 回读无回复 → 只读", probeRegister))
            probeReadOnly.append(probeRegister)
            advanceProbe()

        case .waitCapacityPreRead:
            // No pre-read, no backup, no write. This is the one timeout in the
            // capacity path that must terminate rather than retry into a write.
            fail("写入前未能读到 0x0E 原值，没有可回滚的备份；本次没有发送写入指令。")

        case .waitAfterCapacityWrite:
            if capacityRegVerifyAttempts < NinebotFrame.maxCapacityVerifyAttempts {
                result.verificationRetried = true
                requestCapacityWriteVerify()
            } else {
                fail("容量写入指令已发送，但多次回读无回复；请重新连接读取当前配置。")
            }

        case .watchCapacity:
            // A dropped reply during a 90 s rotation is not a reason to stop:
            // the gap is itself part of the shape being measured.
            log(String(format: "CAP_WATCH T+%6.2fs 回读无回复", capacityWatchElapsed()))
            scheduleCapacityWatchTick(after: Self.watchInterval)

        case .watchAfterWrite:
            // One unanswered sample must not end the watch: the point is the
            // shape of the value over thirty seconds, and a dropped reply is
            // itself part of that shape.
            log(String(format: "WATCH T+%6.2fs 回读无回复", watchElapsed()))
            scheduleWatchTick(after: Self.watchInterval)

        case .waitDumpScan:
            // A silent address is a normal part of sweeping 256 of them.
            recordDumpTimeout(dumpModules[dumpModuleCursor], dumpIndex)
            advanceDumpScan()

        case .waitCapacityCompatScan:
            capacityScanValues[capacityScanRegisterIndex][capacityScanRepeatIndex] = -1
            log("兼容容量地址无回复；继续扫描。")
            advanceCapacityCompatibilityScan()

        case .waitDisAfter where result.writeCommandSent:
            if disVerifyAttempts < NinebotFrame.maxDisVerifyAttempts {
                result.verificationRetried = true
                retryDisVerificationSafely()
            } else {
                fail("仪表写入指令已发送，但多次回读无回复；请重新连接读取当前配置。")
            }

        case .waitAfterProfile where result.writeCommandSent
            && profileVerifyAttempts < NinebotFrame.maxProfileVerifyAttempts:
            result.verificationRetried = true
            retryProfileVerificationSafely()

        case .waitAfterCapacity where result.profileReadbackVerified:
            if capacityVerifyAttempts < NinebotFrame.maxCapacityVerifyAttempts {
                result.verificationRetried = true
                status("Profile已确认；再次读取容量参数"
                    + "（\(capacityVerifyAttempts + 1)/\(NinebotFrame.maxCapacityVerifyAttempts)）…")
                requestCapacityVerification()
            } else {
                finish("Profile已回读确认；容量参数多次无响应，按Profile确认写入成功。")
            }

        case .waitAfterProfile where result.writeCommandSent:
            fail("写入指令已发送，但连续\(profileVerifyAttempts)次未收到Profile回读，"
                + "暂时无法完成回读确认；这不代表写入失败，请重新连接读取当前参数。")

        default:
            fail(message)
        }
    }

    private func clearTimeout() { timeoutWork?.cancel() }

    // MARK: - Sending

    private func send(_ plain: [UInt8]) {
        guard let crypto else {
            fail("加密会话未建立")
            return
        }
        do {
            let counter = nextCounter
            nextCounter += 1
            let encrypted = try crypto.encryptSn(plain, counter: counter)
            log(NinebotFrame.isFrame(plain, src: 0x3E, dst: 0x04, cmd: 0x5D)
                ? "TX ctr=\(counter) AUTH 身份数据已隐藏"
                : "TX ctr=\(counter) plain=\(Hex.encode(plain))")
            transport.write(Data(encrypted))
        } catch {
            fail("发送失败：\(describe(error))")
        }
    }

    private func sendRaw(_ bytes: [UInt8]) {
        transport.write(Data(bytes))
    }

    // MARK: - Notify handling

    private func handleNotify(_ encrypted: [UInt8]) {
        guard !finished, !encrypted.isEmpty else { return }
        do {
            switch state {
            case .waitPreComm:
                try handlePreComm(encrypted)
            case .waitPairConfirm:
                try handlePairConfirm(encrypted)
            case .waitAuth, .waitBeforeProfile, .waitBeforeSoc, .waitBeforeCapacity,
                 .waitDisDashboardVersion, .waitDisEnergyWh, .waitDisRemainingCapacity,
                 .waitDisBattery, .waitDisVrlaVoltage, .waitDisBfgVersion,
                 .waitColorDisplayVersion, .waitCentreControllerVersion,
                 .waitDisConfig, .waitDisWriteAck, .waitDisAfter,
                 .waitCapacityCompatScan, .waitRegisterScan, .waitDumpScan,
                 .waitWriteAck, .waitAfterProfile, .waitAfterCapacity,
                 .watchAfterWrite,
                 .waitCapacityPreRead, .waitCapacityWriteAck, .waitAfterCapacityWrite, .watchCapacity,
                 .probePreRead, .probeWrite, .probeVerify,
                 .sweepPreRead, .sweepTryWrite, .sweepVerify, .sweepRestore, .sweepRestoreVerify:
                try handleSessionReply(encrypted)
            default:
                break
            }
        } catch {
            fail(describe(error))
        }
    }

    private func handlePreComm(_ encrypted: [UInt8]) throws {
        guard let crypto else { throw BleError.txNotReady }
        let plain = try crypto.decryptPreComm(encrypted)
        log("PRE_COMM 回复已收到；车辆身份数据已隐藏")

        guard NinebotFrame.isFrame(plain, src: 0x04, dst: 0x3E, cmd: 0x5B) else {
            throw NSError(domain: "bfg", code: 2, userInfo: [NSLocalizedDescriptionKey:
                "PRE_COMM回复格式不符"])
        }
        guard plain.count >= 37 else {
            throw NSError(domain: "bfg", code: 3, userInfo: [NSLocalizedDescriptionKey:
                "PRE_COMM回复过短"])
        }

        let index = Int(plain[6])
        let authParam = Array(plain[7..<23])
        let serialBytes = Array(plain[23..<37])
        let serial = String(decoding: serialBytes, as: UTF8.self)
            .trimmingCharacters(in: .whitespaces)
        guard !serial.isEmpty else {
            throw NSError(domain: "bfg", code: 4, userInfo: [NSLocalizedDescriptionKey:
                "PRE_COMM未返回车辆SN"])
        }

        result.serial = serial
        clearTimeout()

        if operation == .pairAndRead {
            if !record.effectiveSn.isEmpty,
               record.effectiveSn.caseInsensitiveCompare(serial) != .orderedSame {
                throw NSError(domain: "bfg", code: 5, userInfo: [NSLocalizedDescriptionKey:
                    "车辆序列号与所选设备不一致，已停止配对"])
            }
            pairingChallenge16 = authParam
            pairingSerial14 = serialBytes
            pairingPassword32 = BfgBleClient.randomBytes(32)
            try crypto.establishSession(password16: Array(pairingPassword32.prefix(16)),
                                        authParam16: authParam)
            state = .waitPairAuthRetries
            nextCounter = 2
            status("车辆已识别；正在请求配对…")
            sendPairAuthRetry(0)
            return
        }

        guard index != 0 else {
            throw NSError(domain: "bfg", code: 6, userInfo: [NSLocalizedDescriptionKey:
                "车辆没有已保存BLE密码；请先完成车辆配对"])
        }
        try crypto.establishSession(password16: password16, authParam16: authParam)
        wipePassword()
        state = .waitAuth
        nextCounter = 2
        status("PRE_COMM成功；AUTH…")
        send(try NinebotFrame.authenticate(serial14: serialBytes))
        timeout(.waitAuth, 5, "AUTH无回复")
    }

    /// Mirrors `sendPairAuthRetry`: probe with three AUTH frames, then send
    /// SET_PWD carrying the freshly generated password, then wait for the
    /// rider to press the button on the vehicle.
    private func sendPairAuthRetry(_ attempt: Int) {
        let delay = attempt == 0 ? 0.0 : 0.51
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.finished, self.state == .waitPairAuthRetries else { return }
            guard let crypto = self.crypto else { return }
            do {
                if attempt < 3 {
                    self.send(try NinebotFrame.authenticate(serial14: self.pairingSerial14))
                    self.sendPairAuthRetry(attempt + 1)
                } else {
                    try crypto.establishNameSession(authParam16: self.pairingChallenge16)
                    let plain = NinebotFrame.setPassword(password32: self.pairingPassword32)
                    self.state = .waitPairConfirm
                    self.log("TX ctr=\(self.nextCounter) SET_PWD 内容已隐藏")
                    self.send(plain)
                    self.status("配对请求已发出；请在车辆上按键确认")
                    self.timeout(.waitPairConfirm, 60, "配对确认超时；请唤醒车辆后重试")
                }
            } catch {
                self.fail("配对请求未完成：\(self.describe(error))")
            }
        }
    }

    private func handlePairConfirm(_ encrypted: [UInt8]) throws {
        guard let crypto else { throw BleError.txNotReady }
        let decoded = try crypto.decryptSn(encrypted)
        let plain = decoded.plain
        guard NinebotFrame.isFrame(plain, src: 0x04, dst: 0x3E, cmd: 0x5C), plain.count == 7 else {
            return
        }
        let code = Int(plain[6])
        if code == 0 {
            status("请在车辆上按键确认配对（60 秒内）")
            return
        }
        guard code == 1 else {
            throw NSError(domain: "bfg", code: 7, userInfo: [NSLocalizedDescriptionKey:
                "车辆拒绝了配对请求"])
        }

        clearTimeout()
        let serial = String(decoding: pairingSerial14, as: UTF8.self)
        guard credentialStore.save(serial: serial, password32: pairingPassword32) else {
            throw NSError(domain: "bfg", code: 11, userInfo: [NSLocalizedDescriptionKey:
                "车端已确认，但临时密钥建立失败；请重新配对"])
        }
        result.pairingConfirmed = true
        try crypto.establishSession(password16: Array(pairingPassword32.prefix(16)),
                                    authParam16: pairingChallenge16)

        // The original verifies the vehicle actually stored the new password
        // before reading anything, by authenticating again under it. Going
        // straight to a read would only surface a bad credential later, as an
        // unrelated-looking failure.
        status("车端已确认；正在验证新配对凭据…")
        state = .waitAuth
        send(try NinebotFrame.authenticate(serial14: pairingSerial14))
        timeout(.waitAuth, 6, "车端已确认，但新凭据认证无回复；请重新连接验证")
    }

    // MARK: - Reply handling

    private func handleSessionReply(_ encrypted: [UInt8]) throws {
        guard let crypto else { throw BleError.txNotReady }
        let decoded = try crypto.decryptSn(encrypted)
        guard decoded.macOk else {
            throw NSError(domain: "bfg", code: 8, userInfo: [NSLocalizedDescriptionKey:
                "回包校验失败"])
        }
        let plain = decoded.plain

        switch state {
        case .waitAuth:
            guard NinebotFrame.isFrame(plain, src: 0x04, dst: 0x3E, cmd: 0x5D) else { return }
            clearTimeout()
            if operation == .dumpRegisters {
                // The sweep needs the session AUTH established first, so it
                // starts here rather than at connect time.
                guard !dumpModules.isEmpty else {
                    fail("未指定要读取的寄存器模块。")
                    return
                }
                beginDumpSweep()
                return
            }
            if operation == .registerScan {
                // A read-only sweep needs no vehicle identification first; it
                // walks every address of the chosen module.
                guard RegisterReadPlan.supports(targetProfile) else {
                    fail("只读扫描只支持仪表盘和计量模块。")
                    return
                }
                registerScanModule = targetProfile
                result.registerScanModule = registerScanModule
                registerScanIndex = RegisterReadPlan.first
                requestRegisterScan()
                return
            }
            status("认证完成；开始读取车辆参数…")
            state = .waitBeforeProfile
            send(NinebotFrame.readProfile)
            timeout(.waitBeforeProfile, 4, "读取Profile无回复")

        case .waitBeforeProfile:
            let index = try requireReadAck(plain, src: 0x10, len: 8)
            guard index == 0x00, plain.count >= 8 else { return }
            result.profileRaw = Int(plain[7])
            clearTimeout()
            state = .waitBeforeSoc
            send(NinebotFrame.readSoc)
            timeout(.waitBeforeSoc, 4, "读取SOC无回复")

        case .waitBeforeSoc:
            let index = try requireReadAck(plain, src: 0x10, len: 8)
            guard index == 0x02, plain.count >= 8 else { return }
            result.bfgSoc = Int(plain[7])
            clearTimeout()
            state = .waitBeforeCapacity
            send(NinebotFrame.readCapacity)
            timeout(.waitBeforeCapacity, 4, "读取容量无回复")

        case .waitBeforeCapacity:
            let index = try requireReadAck(plain, src: 0x10, len: 9)
            guard index == 0x1C, plain.count >= 9 else { return }
            result.bfgCapacity = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            try continueAfterCapacityRead()

        case .waitDisDashboardVersion:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0x1A, plain.count >= 9 else { return }
            result.dashboardFirmware = NinebotFrame.readLe16(plain, offset: 7)
            result.disDashboardVersion = result.dashboardFirmware
            clearTimeout()
            advanceDisChain()

        case .waitDisEnergyWh:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0x1E, plain.count >= 9 else { return }
            result.disEnergyWh = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisRemainingCapacity:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0x44, plain.count >= 9 else { return }
            result.disRemainingCapacity = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisBattery:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0xB5, plain.count >= 9 else { return }
            result.disBatterySoc = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisVrlaVoltage:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0xB1, plain.count >= 9 else { return }
            result.disVrlaVoltage = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisBfgVersion:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0x3D, plain.count >= 9 else { return }
            result.meterFirmware = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitColorDisplayVersion:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0xD1, plain.count >= 9 else { return }
            result.colorDisplayVersion = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitCentreControllerVersion:
            let index = try requireReadAck(plain, src: 0x09, len: 9)
            guard index == 0x02, plain.count >= 9 else { return }
            result.centreControllerVersion = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            advanceDisChain()

        case .waitDisConfig:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0x92, plain.count >= 9 else { return }
            result.disConfigRaw = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            afterDisConfigRead()

        case .waitCapacityCompatScan:
            let register = CapacityCompatibilityResolver.registers[capacityScanRegisterIndex]
            let index = try requireReadAck(plain, src: 0x10, len: 9)
            guard index == register, plain.count >= 9 else { return }
            let value = NinebotFrame.readLe16(plain, offset: 7)
            capacityScanValues[capacityScanRegisterIndex][capacityScanRepeatIndex] = value
            capacityScanLastFrames[capacityScanRegisterIndex] = Hex.encode(plain)
            log(String(format: "CAPACITY_COMPAT_RX reg=0x%02X pass=%d value=%d",
                       register, capacityScanRepeatIndex + 1, value))
            clearTimeout()
            advanceCapacityCompatibilityScan()

        case .waitWriteAck:
            // CMD 0x02 is answered by CMD 0x05. The ACK only accelerates the
            // read-back; losing it must never fail the write.
            guard NinebotFrame.isFrame(plain, src: 0x10, dst: 0x3E, cmd: 0x05) else { return }
            result.writeAckSeen = true
            result.writeAckFrame = Hex.encode(plain)
            log("WRITE_ACK=" + result.writeAckFrame)
            scheduleVerifySoon()

        case .waitAfterProfile:
            let index = try requireReadAck(plain, src: 0x10, len: 8)
            guard index == 0x00, plain.count >= 8 else { return }
            result.afterProfile = Int(plain[7])
            clearTimeout()
            guard result.afterProfile == targetProfile else {
                guard profileVerifyAttempts < NinebotFrame.maxProfileVerifyAttempts else {
                    fail(String(format: "连续%d次回读仍为0x%02X，目标为0x%02X",
                                profileVerifyAttempts, result.afterProfile, targetProfile))
                    return
                }
                result.verificationRetried = true
                status(String(format: "暂时仍是旧档位 0x%02X；等待车辆保存后再次回读（%d/%d）…",
                              result.afterProfile, profileVerifyAttempts + 1,
                              NinebotFrame.maxProfileVerifyAttempts))
                guard !profileRetryPending else { return }
                profileRetryPending = true
                scheduleVerify(after: 1.0) { [weak self] in self?.retryProfileVerificationSafely() }
                return
            }
            result.profileReadbackVerified = true
            if result.mode == .capacityScanCompat {
                // Compatibility mode has no trustworthy 0x1C to re-read; the
                // expected core value for the profile is the confirmation.
                result.resolvedAfterCapacityRaw = BfgProfileCatalog.expectedCore(targetProfile)
                beginProfileWatch()
                return
            }
            state = .waitAfterCapacity
            status("Profile回读完成；读取新的 capacity_core…")
            requestCapacityVerification()

        case .waitAfterCapacity:
            let index = try requireReadAck(plain, src: 0x10, len: 9)
            guard index == 0x1C, plain.count >= 9 else { return }
            result.afterCapacityRaw = NinebotFrame.readLe16(plain, offset: 7)
            result.capacityReadbackVerified = true
            result.resolvedAfterCapacityRaw = result.afterCapacityRaw
            clearTimeout()
            beginProfileWatch()

        case .sweepPreRead:
            let sweepIdx = try requireReadAck(plain, src: 0x10, len: 9)
            guard sweepIdx == NinebotFrame.capacityWriteIndex, plain.count >= 9 else { return }
            clearTimeout()
            let sweepNow = NinebotFrame.readLe16(plain, offset: 7)
            if sweepOriginal < 0 {
                // Captured once, never rewritten: every candidate is reverted to
                // this exact value, so it has to be the vehicle's own.
                sweepOriginal = sweepNow
                sweepCandidates = WriteAccessPolicy.sweepCandidates(from: sweepNow)
                result.capacityRatedBefore = sweepNow
                let list = sweepCandidates.map(String.init).joined(separator: " ")
                log("SWEEP_BEGIN 原值=\(sweepNow)，候选 \(sweepCandidates.count) 个（均来自固件表）：\(list)")
                if sweepCandidates.isEmpty {
                    fail("固件表里没有不低于当前值 \(sweepNow) 的候选容量；本次没有发送任何写入指令。")
                    return
                }
            } else if sweepNow != sweepOriginal {
                log(String(format: "SWEEP_ABORT 0x0E 已被改动：期望 %d 实际 %d",
                           sweepOriginal, sweepNow))
                fail(String(format: "0x0E 在试探过程中被改动（期望 %d，实际 %d）；"
                            + "为免继续偏离，试探已中止。请重新连接核对。",
                            sweepOriginal, sweepNow))
                return
            }
            advanceSweep()

        case .sweepTryWrite:
            guard NinebotFrame.isFrame(plain, src: 0x10, dst: 0x3E, cmd: 0x05) else { return }
            sweepAckSeen = true
            log(String(format: "SWEEP_ACK v=%d %@", sweepValue, Hex.encode(plain)))
            clearTimeout()
            readBackSweepValue()

        case .sweepVerify:
            let sweepAfterIdx = try requireReadAck(plain, src: 0x10, len: 9)
            guard sweepAfterIdx == NinebotFrame.capacityWriteIndex, plain.count >= 9 else { return }
            clearTimeout()
            concludeSweepValue(NinebotFrame.readLe16(plain, offset: 7))

        case .sweepRestore:
            guard NinebotFrame.isFrame(plain, src: 0x10, dst: 0x3E, cmd: 0x05) else { return }
            log(String(format: "SWEEP_RESTORE_ACK %@", Hex.encode(plain)))
            clearTimeout()
            verifySweepRestore()

        case .sweepRestoreVerify:
            let sweepRestoreIdx = try requireReadAck(plain, src: 0x10, len: 9)
            guard sweepRestoreIdx == NinebotFrame.capacityWriteIndex, plain.count >= 9 else { return }
            clearTimeout()
            concludeSweepRestore(NinebotFrame.readLe16(plain, offset: 7))

        case .probePreRead:
            let probePre = try requireReadAck(plain, src: 0x10, len: 9)
            guard probePre == probeRegister, plain.count >= 9 else { return }
            clearTimeout()
            probeValue = NinebotFrame.readLe16(plain, offset: 7)
            log(String(format: "PROBE_PREREAD 0x%02X=%d", probeRegister, probeValue))
            proceedProbeWrite()

        case .probeWrite:
            guard NinebotFrame.isFrame(plain, src: 0x10, dst: 0x3E, cmd: 0x05) else { return }
            probeAckSeen = true
            log(String(format: "PROBE_ACK 0x%02X %@", probeRegister, Hex.encode(plain)))
            clearTimeout()
            finishProbeRegister()

        case .probeVerify:
            let probeAfter = try requireReadAck(plain, src: 0x10, len: 9)
            guard probeAfter == probeRegister, plain.count >= 9 else { return }
            clearTimeout()
            concludeProbeRegister(NinebotFrame.readLe16(plain, offset: 7))

        case .waitCapacityPreRead:
            let preIndex = try requireReadAck(plain, src: 0x10, len: 9)
            guard preIndex == NinebotFrame.capacityWriteIndex, plain.count >= 9 else { return }
            clearTimeout()
            capacityBefore = NinebotFrame.readLe16(plain, offset: 7)
            log(String(format: "CAP_WRITE_PREREAD 0x%02X=%d",
                       NinebotFrame.capacityWriteIndex, capacityBefore))
            proceedCapacityWrite()

        case .waitCapacityWriteAck:
            guard NinebotFrame.isFrame(plain, src: 0x10, dst: 0x3E, cmd: 0x05) else { return }
            result.writeAckSeen = true
            result.writeAckFrame = Hex.encode(plain)
            log("CAP_WRITE_ACK=" + result.writeAckFrame)
            scheduleVerify(after: 1.0) { [weak self] in self?.verifyCapacityWriteSafely() }

        case .waitAfterCapacityWrite:
            let index = try requireReadAck(plain, src: 0x10, len: 9)
            guard index == NinebotFrame.capacityWriteIndex, plain.count >= 9 else { return }
            let value = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            if capacityBefore < 0 { capacityBefore = value }
            capacityAfter = value
            result.capacityRatedBefore = capacityBefore
            result.capacityRatedAfter = value
            log(String(format: "CAP_WRITE_READBACK 0x%02X before=%d after=%d target=%d",
                       NinebotFrame.capacityWriteIndex, capacityBefore, value, targetCapacity))
            if value == targetCapacity {
                result.capacityReadbackVerified = true
                beginCapacityWatch()
            } else if capacityRegVerifyAttempts < NinebotFrame.maxCapacityVerifyAttempts {
                result.verificationRetried = true
                scheduleVerify(after: 1.0) { [weak self] in self?.requestCapacityWriteVerify() }
            } else {
                fail(String(format: "连续%d次回读 0x%02X 仍为 %d，目标 %d",
                            capacityRegVerifyAttempts, NinebotFrame.capacityWriteIndex,
                            value, targetCapacity))
            }

        case .watchCapacity:
            // Length differs per register: 0x00 answers with one byte, the
            // capacity words with two. Parsing by the echoed index rather than
            // by a fixed width is what keeps the rotation honest.
            guard let index = try? requireReadAck(plain, src: 0x10, len: 8) else { return }
            clearTimeout()
            let sampled = (index == 0x00)
                ? Int(plain[7])
                : (plain.count >= 9 ? NinebotFrame.readLe16(plain, offset: 7) : -1)
            recordCapacitySample(register: index, value: sampled)
            scheduleCapacityWatchTick(after: Self.watchInterval)

        case .watchAfterWrite:
            // The same read the verify step used; here it is sampled on a
            // timer instead of being asked once and abandoned.
            let index = try requireReadAck(plain, src: 0x10, len: 8)
            guard index == 0x00, plain.count >= 8 else { return }
            clearTimeout()
            recordWatchSample(Int(plain[7]))
            scheduleWatchTick(after: Self.watchInterval)

        case .waitDisWriteAck:
            guard NinebotFrame.isFrame(plain, src: 0x01, dst: 0x3E, cmd: 0x05) else { return }
            result.writeAckSeen = true
            result.writeAckFrame = Hex.encode(plain)
            log("DIS_CONFIG_WRITE_ACK=" + result.writeAckFrame)
            scheduleVerify(after: 0.7) { [weak self] in self?.verifyAfterDisWriteSafely() }

        case .waitDisAfter:
            let index = try requireReadAck(plain, src: 0x01, len: 9)
            guard index == 0x92, plain.count >= 9 else { return }
            result.disConfigAfterRaw = NinebotFrame.readLe16(plain, offset: 7)
            clearTimeout()
            if result.disConfigAfterRaw == result.disConfigTargetRaw {
                result.disConfigReadbackVerified = true
                finish("仪表电压配置已回读为目标值；断电保持仍需实车验证。")
            } else if disVerifyAttempts < NinebotFrame.maxDisVerifyAttempts {
                result.verificationRetried = true
                scheduleVerify(after: 1.0) { [weak self] in self?.retryDisVerificationSafely() }
            } else {
                fail("仪表配置连续回读仍与目标不一致，请重新连接读取当前配置。")
            }

        case .waitDumpScan:
            let module = dumpModules[dumpModuleCursor]
            let length = RegisterReadPlan.probeLength(module: module, index: dumpIndex)
            // A sweep is read-only, so a reply that is not a read acknowledgement
            // is one address that did not answer usefully — not a reason to throw
            // away the other 255. Returning here lets the normal timeout record it
            // and move on. Strictness belongs on the write path, where a malformed
            // frame must never be mistaken for success. On the real vehicle one
            // dashboard address answers with a frame that is not an ack at all,
            // and it used to end the entire snapshot.
            guard let index = try? requireReadAck(plain, src: module, len: 7 + length),
                  index == dumpIndex else { return }
            clearTimeout()
            // Two meter addresses answer with a single byte; reading those as
            // a 16-bit word would index past the end of the frame.
            let value = length >= 2
                ? NinebotFrame.readLe16(plain, offset: 7)
                : Int(plain[7])
            recordDumpValue(module, dumpIndex, value)
            advanceDumpScan()

        case .waitRegisterScan:
            let length = try RegisterReadPlan.length(module: registerScanModule,
                                                     index: registerScanIndex)
            // Same reasoning as the dump above: a census is read-only, so one
            // unparseable reply counts as a timeout rather than a failed sweep.
            guard let index = try? requireReadAck(plain, src: registerScanModule, len: 7 + length),
                  index == registerScanIndex else { return }
            result.registerScanReplies += 1
            // The value is the whole point of a sweep. Logging only the index
            // recorded that an address answered but not what it said, so the
            // adaptation data had to be gathered by the Android build instead.
            let payload = Hex.encode(Array(plain[7..<(7 + length)]))
            let value = length == 1 ? Int(plain[7]) : NinebotFrame.readLe16(plain, offset: 7)
            log(String(format: "REGISTER_READ module=0x%02X index=0x%02X length=%d",
                       registerScanModule, registerScanIndex, length)
                + " data=\(payload) value=\(value)")
            clearTimeout()
            advanceRegisterScan()

        default:
            break
        }
    }

    /// Validates a read acknowledgement and returns its index byte.
    ///
    /// Port of Android's `isReadAckFrom(p, src, index, dataLen)`: a read reply
    /// always carries CMD 0x04 and echoes the requested register in its index
    /// byte. The reply's CMD is fixed here rather than passed in, because
    /// passing the *request's* CMD (0x01) made every reply fail to match — the
    /// whole read chain was dead and no test reached it.
    @discardableResult
    private func requireReadAck(_ plain: [UInt8], src: Int, len: Int) throws -> Int {
        guard NinebotFrame.isFrame(plain, src: src, dst: 0x3E, cmd: 0x04),
              plain.count >= len else {
            throw NSError(domain: "bfg", code: 9, userInfo: [NSLocalizedDescriptionKey:
                "回包格式不符"])
        }
        return Int(plain[6])
    }

    // MARK: - Read chain and write decision

    private func continueAfterCapacityRead() throws {
        // The dashboard chain runs for every operation, read-only included: it
        // is what yields the dashboard voltage and firmware set, and what
        // resolves the communication mode that a later write depends on.
        state = .waitDisDashboardVersion
        send(NinebotFrame.readDisDashboardVersion)
        timeout(.waitDisDashboardVersion, 4, "读取仪表版本无回复")
    }

    /// Walks the dashboard identification chain in the order the Android client
    /// uses, then resolves the communication mode.
    private func advanceDisChain() {
        switch state {
        case .waitDisDashboardVersion:
            state = .waitDisEnergyWh
            send(NinebotFrame.readDisEnergyWh)
            timeout(.waitDisEnergyWh, 4, "读取仪表能量无回复")
        case .waitDisEnergyWh:
            state = .waitDisRemainingCapacity
            send(NinebotFrame.readDisRemainingCapacity)
            timeout(.waitDisRemainingCapacity, 4, "读取剩余容量无回复")
        case .waitDisRemainingCapacity:
            state = .waitDisBattery
            send(NinebotFrame.readDisBattery)
            timeout(.waitDisBattery, 4, "读取仪表电量无回复")
        case .waitDisBattery:
            state = .waitDisVrlaVoltage
            send(NinebotFrame.readDisVrlaVoltage)
            timeout(.waitDisVrlaVoltage, 4, "读取仪表电压无回复")
        case .waitDisVrlaVoltage:
            state = .waitDisBfgVersion
            send(NinebotFrame.readDisBfgVersion)
            timeout(.waitDisBfgVersion, 4, "读取计量版本无回复")
        case .waitDisBfgVersion:
            state = .waitColorDisplayVersion
            send(NinebotFrame.readColorDisplayVersion)
            timeout(.waitColorDisplayVersion, 3, "读取彩屏版本无回复")
        case .waitColorDisplayVersion:
            state = .waitCentreControllerVersion
            send(NinebotFrame.readCentreControllerVersion)
            timeout(.waitCentreControllerVersion, 3, "读取中控版本无回复")
        case .waitCentreControllerVersion:
            state = .waitDisConfig
            send(NinebotFrame.readDisConfig)
            timeout(.waitDisConfig, 4, "读取仪表配置无回复")
        default:
            break
        }
    }

    // MARK: - Capacity compatibility scan

    /// Runs only when the meter firmware is unrecognised or the plain 0x1C
    /// capacity reading is implausible, which is how older vehicles still become
    /// writable instead of being rejected outright.
    private func afterDisConfigRead() {
        if needsCapacityCompatibilityScan() {
            beginCapacityCompatibilityScan()
        } else {
            resolveAndMaybeWrite()
        }
    }

    private func needsCapacityCompatibilityScan() -> Bool {
        let knownMeter = result.meterFirmware == 0x0429 || result.meterFirmware == 0x0286
        let expected = BfgProfileCatalog.expectedCore(result.profileRaw)
        let capacityInvalid = !CapacityCompatibilityResolver.isPlausible(result.bfgCapacity)
            || (expected > 0 && result.bfgCapacity != expected)
        // `expected <= 0` means the table does not recognise this profile byte at
        // all — the case where the repeated probes are the *only* way to learn
        // what the vehicle actually holds. The resolver does not need the table
        // for that (its strongest evidence is agreement between 0x0E and 0x0F).
        return !knownMeter || capacityInvalid || expected <= 0
    }

    private func beginCapacityCompatibilityScan() {
        capacityScanValues = [[Int]](repeating: [Int](repeating: -1, count: 3), count: 5)
        capacityScanLastFrames = [String](repeating: "", count: 5)
        capacityScanRegisterIndex = 0
        capacityScanRepeatIndex = 0
        state = .waitCapacityCompatScan
        log("CAPACITY_COMPAT_SCAN_BEGIN")
        requestCurrentCapacityCompatibilityRegister()
    }

    private func requestCurrentCapacityCompatibilityRegister() {
        let register = CapacityCompatibilityResolver.registers[capacityScanRegisterIndex]
        send(NinebotFrame.readBfgWord(register: register))
        timeout(.waitCapacityCompatScan, 4,
                String(format: "读取兼容容量地址0x%02X无回复", register))
    }

    private func advanceCapacityCompatibilityScan() {
        capacityScanRepeatIndex += 1
        if capacityScanRepeatIndex >= CapacityCompatibilityResolver.repeats {
            capacityScanRepeatIndex = 0
            capacityScanRegisterIndex += 1
        }
        guard capacityScanRegisterIndex < CapacityCompatibilityResolver.registers.count else {
            finishCapacityCompatibilityScan()
            return
        }
        requestCurrentCapacityCompatibilityRegister()
    }

    private func finishCapacityCompatibilityScan() {
        let expected = BfgProfileCatalog.expectedCore(result.profileRaw)
        let scan = CapacityCompatibilityResolver.resolve(expectedCapacity: expected,
                                                         readings: capacityScanValues)
        result.scannedCapacity = scan.selectedCapacity
        result.scannedCapacityRegister = scan.selectedRegister
        result.capacityScanReason = scan.reason
        log("CAPACITY_COMPAT_RESULT selected=\(scan.selectedCapacity) reg=0x\(String(format: "%02X", scan.selectedRegister)) reason=\(scan.reason)")
        resolveAndMaybeWrite()
    }

    // MARK: - Register scan

    /// Starts a full two-pass sweep. The module list comes from the caller
    /// because the cost is dominated by the soft timeout on silent addresses:
    /// sweeping one module before a write is quick, sweeping the whole bus is
    /// a deliberate, slow operation.
    private func beginDumpSweep() {
        dumpModuleCursor = 0
        dumpIndex = 0
        dumpPass = 0
        dumpFirstPass = [:]
        dumpEntries = []
        state = .waitDumpScan
        status("正在读取寄存器快照（第 1 遍）…")
        requestDumpRead()
    }

    private func requestDumpRead() {
        let module = dumpModules[dumpModuleCursor]
        // Progress, because a sweep runs into the minutes and a screen whose text
        // never changes reads as "hung" — which is how a snapshot gets cancelled
        // half way and leaves no file behind at all.
        if dumpIndex % 32 == 0 {
            status("正在读取寄存器快照：模块 0x" + String(format: "%02X", module)
                + " 第 \(dumpPass + 1)/2 遍 \(dumpIndex)/256…")
        }
        send(RegisterReadPlan.probeRequest(module: module, index: dumpIndex))
        timeout(.waitDumpScan, 0.65, "寄存器读取无回复")
    }

    private func recordDumpValue(_ module: Int, _ index: Int, _ value: Int) {
        let key = "\(module):\(index)"
        if dumpPass == 0 {
            dumpFirstPass[key] = value
        } else {
            let first = dumpFirstPass[key]
            dumpEntries.append(RegisterDump.Entry(
                module: module, index: index,
                length: RegisterReadPlan.probeLength(module: module, index: index),
                value: value, stable: first == nil || first == value, responded: true))
        }
    }

    /// Records an address that did not answer. A silent first pass still needs
    /// an entry, so the second pass writes one marked unresponsive.
    private func recordDumpTimeout(_ module: Int, _ index: Int) {
        guard dumpPass == 1 else { return }
        let key = "\(module):\(index)"
        dumpEntries.append(RegisterDump.Entry(
            module: module, index: index,
            length: RegisterReadPlan.probeLength(module: module, index: index),
            value: -1, stable: false, responded: dumpFirstPass[key] != nil))
    }

    private func advanceDumpScan() {
        dumpIndex += 1
        if dumpIndex > RegisterReadPlan.last {
            dumpIndex = RegisterReadPlan.first
            dumpModuleCursor += 1
            if dumpModuleCursor >= dumpModules.count {
                dumpModuleCursor = 0
                dumpPass += 1
                if dumpPass > 1 {
                    finishDump()
                    return
                }
                status("正在复核寄存器快照（第 2 遍）…")
            }
        }
        scheduleVerify(after: 0.05) { [weak self] in
            guard let self, !self.finished, self.state == .waitDumpScan else { return }
            self.requestDumpRead()
        }
    }

    private func finishDump() {
        // The fingerprint comes from the dump itself where it can: a dump taken
        // without walking the DIS chain would otherwise carry no versions at
        // all, and the versions are exactly what identifies the build.
        result.registerDump = RegisterDump(
            serial: result.serial,
            fingerprint: RegisterDump.Fingerprint(
                dashboard: dumpValue(0x01, 0x1A) ?? result.dashboardFirmware,
                colorDisplay: dumpValue(0x01, 0xD1) ?? result.colorDisplayVersion,
                centre: dumpValue(0x09, 0x02) ?? result.centreControllerVersion,
                meter: dumpValue(0x01, 0x3D) ?? result.meterFirmware),
            timestamp: Int64((Date().timeIntervalSince1970 * 1000).rounded()),
            entries: dumpEntries)
        finish("寄存器快照完成：\(dumpEntries.count) 个地址，"
            + "\(dumpEntries.filter(\.responded).count) 个有响应。")
    }

    private func dumpValue(_ module: Int, _ index: Int) -> Int? {
        dumpEntries.first { $0.module == module && $0.index == index && $0.responded }?.value
    }

    private func requestRegisterScan() {
        guard registerScanIndex <= RegisterReadPlan.last else {
            finish(String(format: "只读扫描完成：0x%02X 模块，%d 个地址有响应。",
                          registerScanModule, result.registerScanReplies))
            return
        }
        state = .waitRegisterScan
        if registerScanIndex % 16 == 0 {
            status("正在只读扫描：\(registerScanIndex)/256（可取消）")
        }
        do {
            send(try RegisterReadPlan.request(module: registerScanModule, index: registerScanIndex))
        } catch {
            fail(describe(error))
            return
        }
        // A missing address is normal across a 256-address sweep, so the
        // per-index timeout is soft: it counts and advances.
        timeoutScanRead()
    }

    private func timeoutScanRead() {
        timeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.finished, self.state == .waitRegisterScan else { return }
            self.result.registerScanTimeouts += 1
            self.advanceRegisterScan()
        }
        timeoutWork = work
        queue.asyncAfter(deadline: .now() + 0.65, execute: work)
    }

    private func advanceRegisterScan() {
        registerScanIndex += 1
        scheduleVerify(after: 0.05) { [weak self] in
            guard let self, !self.finished, self.state == .waitRegisterScan else { return }
            self.requestRegisterScan()
        }
    }

    // MARK: - Communication mode and write entry

    private func resolveAndMaybeWrite() {
        let decision = CommunicationModeResolver.resolve(
            profile: result.profileRaw,
            bfgSoc: result.bfgSoc,
            bfgCapacity: result.bfgCapacity,
            disSoc: result.disBatterySoc,
            disVoltage: result.disVrlaVoltage,
            dashboardVersion: result.dashboardFirmware,
            bfgVersion: result.meterFirmware,
            scannedCapacity: result.scannedCapacity)

        result.mode = decision.mode
        result.writeSupported = decision.writeSupported
        result.resolvedBeforeSoc = decision.resolvedSoc
        result.resolvedBeforeCapacityRaw = decision.resolvedCapacity
        log("MODE=\(CommunicationModeResolver.label(decision.mode)) reason=\(decision.reason)")

        switch operation {
        case .writeDisVoltage:
            beginDisVoltageWrite()
        case .sweepCapacityValues:
            guard WriteAccessPolicy.allowsCapacitySweep else {
                fail("容量值试探未开启；本次没有发送任何写入指令。")
                return
            }
            beginSweepRun()

        case .probeRegisterWrites:
            guard WriteAccessPolicy.allowsRegisterProbe else {
                fail("寄存器写入探测未开启；本次没有发送任何写入指令。")
                return
            }
            beginProbeRun()

        case .writeCapacity:
            guard WriteAccessPolicy.isWritableCapacity(targetCapacity) else {
                fail("容量写入未获许可，或目标值超出合理范围（5000–100000 mAh）；"
                    + "本次没有发送写入指令。")
                return
            }
            beginCapacityWrite()

        case .writeProfile:
            // A combination the author never validated is a statement about his
            // test coverage, not about the vehicle in front of the rider. Expert
            // mode proceeds — with every safety rail below still in force — and
            // records in the log that it did so, so the export can never be read
            // as a validated run.
            guard decision.writeSupported || WriteAccessPolicy.allowsUnverifiedCombination() else {
                fail("当前仪表与计量模块组合尚未通过写入验证；"
                    + "本次没有发送写入。请先导出诊断数据用于适配。")
                return
            }
            if !decision.writeSupported {
                log("EXPERT_UNVERIFIED 未验证组合放行：\(decision.reason)")
            }
            beginProfileWrite()
        default:
            finish("车辆数据读取完成；已自动识别通信模式，本次没有写入。")
        }
    }

    private func beginProfileWrite() {
        guard !WriteAccessPolicy.isReadOnlySerial(record.effectiveSn) else {
            fail("该序列号以 N 开头，仅允许读取，不发送任何写入指令。")
            return
        }
        state = .waitWriteAck
        verifyScheduled = false
        profileVerifyAttempts = 0
        capacityVerifyAttempts = 0
        status(String(format: "%@；准备写入 Profile 0x%02X…",
                      CommunicationModeResolver.label(result.mode), targetProfile))
        send(NinebotFrame.writeProfile(targetProfile))
        result.writeCommandSent = true
        // CMD 0x02 should answer with CMD 0x05. Even if that ACK is lost, the
        // value is confirmed by a fresh READ instead of a second WRITE.
        scheduleVerify(after: 2.4) { [weak self] in self?.verifyAfterWriteSafely() }
    }

    /// For `.writeDisVoltage` the operation's target is the nominal voltage the
    /// user picked; the raw register encoding is derived from the current config.
    private func beginDisVoltageWrite() {
        guard !WriteAccessPolicy.isReadOnlySerial(record.effectiveSn) else {
            fail("该序列号以 N 开头，仅允许读取，不发送任何写入指令。")
            return
        }
        guard DashboardWritePolicy.allows(dashboard: result.dashboardFirmware,
                                          colorDisplay: result.colorDisplayVersion,
                                          centre: result.centreControllerVersion,
                                          meter: result.meterFirmware) else {
            fail(DashboardWritePolicy.blockedMessage)
            return
        }
        if expectedDisConfigRaw >= 0 && result.disConfigRaw != expectedDisConfigRaw {
            fail("仪表配置在确认后发生变化；本次未写入，请重新连接读取。")
            return
        }
        let targetRaw: Int
        do {
            targetRaw = try DisVoltageConfig.target(currentRaw: result.disConfigRaw,
                                                    voltage: targetProfile)
        } catch {
            fail(describe(error))
            return
        }
        if DisVoltageConfig.requiresExtraWarning(currentRaw: result.disConfigRaw,
                                                 targetRaw: targetRaw) && !allowUnverifiedDis {
            fail("该仪表配置尚未验证；本次未写入。")
            return
        }
        result.disConfigTargetRaw = targetRaw
        if targetRaw == result.disConfigRaw {
            result.disConfigAfterRaw = targetRaw
            result.disConfigReadbackVerified = true
            finish("仪表已是所选电压档位，无需写入。")
            return
        }
        state = .waitDisWriteAck
        disVerifyAttempts = 0
        status("正在尝试写入仪表电压配置；之后会自动回读…")
        do {
            send(try DisVoltageConfig.writePacket(targetRaw))
        } catch {
            fail(describe(error))
            return
        }
        result.writeCommandSent = true
        log(String(format: "DIS_CONFIG_WRITE before=0x%02X target=0x%02X",
                   result.disConfigRaw, targetRaw))
        // A lost ACK must not cause a second write; verification only re-reads.
        scheduleVerify(after: 2.2) { [weak self] in self?.verifyAfterDisWriteSafely() }
    }

    // MARK: - Write verification

    /// Follow-up work that deliberately outlives `clearTimeout()`: the write
    /// verification chain is triggered by the reply, not by a failure timer.
    private func scheduleVerify(after seconds: Double, _ work: @escaping () -> Void) {
        let item = DispatchWorkItem(block: work)
        verifyWork?.cancel()
        verifyWork = item
        queue.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func scheduleVerifySoon() {
        guard !verifyScheduled, !finished, state == .waitWriteAck else { return }
        verifyScheduled = true
        scheduleVerify(after: 0.8) { [weak self] in self?.verifyAfterWriteSafely() }
    }

    private func verifyAfterWriteSafely() {
        guard !finished, state == .waitWriteAck else { return }
        state = .waitAfterProfile
        requestProfileVerification()
    }

    private func retryProfileVerificationSafely() {
        profileRetryPending = false
        guard !finished, state == .waitAfterProfile else { return }
        requestProfileVerification()
    }

    private func requestProfileVerification() {
        profileRetryPending = false
        profileVerifyAttempts += 1
        if profileVerifyAttempts > 1 { result.verificationRetried = true }
        status(String(format: "写入已发送；正在回读 Profile（%d/%d）…",
                      profileVerifyAttempts, NinebotFrame.maxProfileVerifyAttempts))
        send(NinebotFrame.readProfile)
        timeout(.waitAfterProfile, 4.5, "写入后Profile回读无回复")
    }

    // MARK: - Post-write watch (read-only)

    private func watchElapsed() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds &- watchStart.uptimeNanoseconds)
            / 1_000_000_000
    }

    /// Keeps the link up and re-reads register 0x00 until the window closes.
    private func beginProfileWatch() {
        watchStart = DispatchTime.now()
        watchChangedAt = -1
        watchLastValue = -1
        watchTransitions = []
        state = .watchAfterWrite
        log(String(format: "WATCH_BEGIN 写入已确认；保持连接 %g 秒，每 %g 秒只读回读 0x00",
                   watchDuration, Self.watchInterval))
        status(String(format: "写入已确认；正在观察 %g 秒，看车辆会不会改回去…",
                      watchDuration))
        scheduleWatchTick(after: Self.watchInterval)
    }

    private func scheduleWatchTick(after seconds: Double) {
        watchTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendWatchRead() }
        watchTimer = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func sendWatchRead() {
        guard !finished, state == .watchAfterWrite else { return }
        if watchElapsed() >= watchDuration {
            endProfileWatch()
            return
        }
        send(NinebotFrame.readProfile)
        timeout(.watchAfterWrite, 2.0, "观察窗口回读无回复")
    }

    /// One sample. A change is logged the moment it is seen; sampling continues
    /// to the end of the window so a revert that itself reverts cannot be missed.
    private func recordWatchSample(_ value: Int) {
        let now = watchElapsed()
        var note = ""
        if watchLastValue < 0 {
            note = value == targetProfile ? " (= 目标值)" : " (≠ 目标值)"
        } else if value != watchLastValue {
            if watchChangedAt < 0 { watchChangedAt = now }
            watchTransitions.append(String(format: "T+%.2fs 0x%02X→0x%02X",
                                           now, watchLastValue, value))
            note = String(format: " ← 变化 0x%02X→0x%02X（第 %d 次）",
                          watchLastValue, value, watchTransitions.count)
        }
        watchLastValue = value
        log(String(format: "WATCH T+%6.2fs profile=0x%02X%@", now, value, note))
    }

    // MARK: - Capacity write implementation

    /// Reads 0x0E BEFORE anything is written.
    ///
    /// Without the old value there is nothing to roll back to, so the read is not
    /// an optimisation — it is the precondition. A capacity write that cannot say
    /// what it replaced must not happen at all.
    private func beginCapacityWrite() {
        state = .waitCapacityPreRead
        capacityRegVerifyAttempts = 0
        capacityBefore = -1
        status("正在读取 0x0E 原值（写入前备份）…")
        send(NinebotFrame.readBfgWord(register: NinebotFrame.capacityWriteIndex))
        timeout(.waitCapacityPreRead, 4.5, "写入前读取 0x0E 无回复")
    }

    /// Only reached once the old value is in hand and persisted.
    private func proceedCapacityWrite() {
        guard capacityBefore > 0 else {
            fail("未能读到 0x0E 原值，没有可回滚的备份；本次没有发送写入指令。")
            return
        }
        let frame = NinebotFrame.writeCapacityRated(targetCapacity)
        log(String(format: "CAP_WRITE_BEGIN target=%d addr=0x%02X before=%d frame=%@",
                   targetCapacity, NinebotFrame.capacityWriteIndex, capacityBefore,
                   Hex.encode(frame)))
        status(String(format: "准备把 0x%02X 从 %d 写成 %d…",
                      NinebotFrame.capacityWriteIndex, capacityBefore, targetCapacity))
        state = .waitCapacityWriteAck
        send(frame)
        result.writeCommandSent = true
        scheduleVerify(after: 2.4) { [weak self] in self?.verifyCapacityWriteSafely() }
    }

    private func verifyCapacityWriteSafely() {
        guard !finished, state == .waitCapacityWriteAck else { return }
        state = .waitAfterCapacityWrite
        requestCapacityWriteVerify()
    }

    private func requestCapacityWriteVerify() {
        capacityRegVerifyAttempts += 1
        if capacityRegVerifyAttempts > 1 { result.verificationRetried = true }
        status(String(format: "正在回读 0x%02X（%d/%d）…",
                      NinebotFrame.capacityWriteIndex, capacityRegVerifyAttempts,
                      NinebotFrame.maxCapacityVerifyAttempts))
        send(NinebotFrame.readBfgWord(register: NinebotFrame.capacityWriteIndex))
        timeout(.waitAfterCapacityWrite, 4.5, "容量写入后回读无回复")
    }

    private func beginCapacityWatch() {
        capacityWatchStart = DispatchTime.now()
        capacityWatchTick = 0
        capacityChangedAt = -1
        capacityReverted = false
        capacityMirror = -1
        capacityProfileSeen = -1
        state = .watchCapacity
        log(String(format: "CAP_WATCH_BEGIN 0x0E 已确认 %d；观察 %g 秒，每 %g 秒轮转读 0x0E/0x0F/0x00",
                   capacityAfter, WriteAccessPolicy.watchSeconds(), Self.watchInterval))
        status(String(format: "容量已确认；正在观察 %g 秒，同时盯着档位和镜像寄存器…",
                      WriteAccessPolicy.watchSeconds()))
        scheduleCapacityWatchTick(after: Self.watchInterval)
    }

    private func scheduleCapacityWatchTick(after seconds: Double) {
        capacityWatchTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendCapacityWatchProbe() }
        capacityWatchTimer = work
        queue.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func sendCapacityWatchProbe() {
        guard !finished, state == .watchCapacity else { return }
        if capacityWatchElapsed() >= WriteAccessPolicy.watchSeconds() {
            endCapacityWatch()
            return
        }
        let register = Self.capacityProbeRotation[capacityWatchTick % Self.capacityProbeRotation.count]
        capacityWatchTick += 1
        send(NinebotFrame.readBfgWord(register: register))
        timeout(.watchCapacity, 2.0, "容量观察窗口回读无回复")
    }

    /// One sample. Each register keeps its own last value so a change can be
    /// attributed to the register that actually moved.
    private func recordCapacitySample(register: Int, value: Int) {
        let now = capacityWatchElapsed()
        var note = ""
        switch register {
        case NinebotFrame.capacityWriteIndex:
            if capacityAfter >= 0, value != capacityAfter, capacityChangedAt < 0 {
                capacityChangedAt = now
                capacityReverted = true
                note = String(format: " ← 变化 %d→%d", capacityAfter, value)
            }
            capacityAfter = value
        case 0x0F:
            if capacityMirror >= 0, value != capacityMirror {
                note = String(format: " ← 变化 %d→%d", capacityMirror, value)
                if capacityChangedAt < 0 { capacityChangedAt = now }
            }
            capacityMirror = value
        default:
            if capacityProfileSeen >= 0, value != capacityProfileSeen {
                note = String(format: " ← 变化 0x%02X→0x%02X", capacityProfileSeen, value)
                if capacityChangedAt < 0 { capacityChangedAt = now }
            }
            capacityProfileSeen = value
        }
        log(String(format: "CAP_WATCH T+%6.2fs 0x%02X=%d (profile=%@) %@",
                   now, register, value,
                   capacityProfileSeen < 0 ? "-" : String(format: "0x%02X", capacityProfileSeen),
                   note))
    }

    private func endCapacityWatch() {
        // Recorded even when the value reverted: "what it became" is the
        // finding, and an export that only carried the target would hide it.
        result.capacityRatedBefore = capacityBefore
        result.capacityRatedAfter = capacityAfter
        capacityWatchTimer?.cancel()
        capacityWatchTimer = nil
        log(String(format: "CAP_WATCH_END 0x0E=%d 0x0F=%d profile=%@ changedAt=%@",
                   capacityAfter, capacityMirror,
                   capacityProfileSeen < 0 ? "-" : String(format: "0x%02X", capacityProfileSeen),
                   capacityChangedAt < 0 ? "none" : String(format: "T+%.2fs", capacityChangedAt)))
        if capacityReverted {
            finish(String(format:
                "容量写入 %d mAh 曾生效，但在 T+%.2fs 被车辆改回。详见 CAP_WATCH 行。",
                targetCapacity, capacityChangedAt))
        } else {
            finish(String(format: "容量写入 %d mAh 已确认并保持稳定 %g 秒。",
                          targetCapacity, WriteAccessPolicy.watchSeconds()))
        }
    }

    // MARK: - Register-write probe implementation

    private func beginProbeRun() {
        probeQueue = WriteAccessPolicy.probeRegisterAllowlist
        probeCursor = 0
        probeWritable = []
        probeReadOnly = []
        let names = probeQueue.map { String(format: "0x%02X", $0) }.joined(separator: " ")
        log("PROBE_BEGIN 候选 \(probeQueue.count) 个：\(names)（每个都写回它自己的当前值，车辆状态不变）")
        status("开始探测 \(probeQueue.count) 个容量候选寄存器；每个都写回原值…")
        advanceProbe()
    }

    private func advanceProbe() {
        guard probeCursor < probeQueue.count else {
            endProbeRun()
            return
        }
        probeRegister = probeQueue[probeCursor]
        probeCursor += 1
        probeValue = -1
        probeAckSeen = false
        state = .probePreRead
        status(String(format: "探测 0x%02X（%d/%d）：先读当前值…",
                      probeRegister, probeCursor, probeQueue.count))
        send(NinebotFrame.readBfgWord(register: probeRegister))
        timeout(.probePreRead, 4.5, String(format: "探测 0x%02X 预读无回复", probeRegister))
    }

    /// Writes the value that was just read. Nothing changes if it lands.
    private func proceedProbeWrite() {
        guard probeValue >= 0 else {
            log(String(format: "PROBE_RESULT 0x%02X 读不到当前值，跳过", probeRegister))
            advanceProbe()
            return
        }
        guard let frame = NinebotFrame.writeBfgWord(register: probeRegister, value: probeValue) else {
            log(String(format: "PROBE_RESULT 0x%02X 不在白名单，跳过", probeRegister))
            advanceProbe()
            return
        }
        log(String(format: "PROBE_WRITE 0x%02X value=%d frame=%@",
                   probeRegister, probeValue, Hex.encode(frame)))
        state = .probeWrite
        send(frame)
        result.writeCommandSent = true
        // No ACK is itself an answer, so the timeout advances instead of failing.
        scheduleVerify(after: 2.0) { [weak self] in self?.finishProbeRegister() }
    }

    /// Settles one register and moves to the next.
    private func finishProbeRegister() {
        guard !finished, state == .probeWrite || state == .probeVerify else { return }
        state = .probeVerify
        send(NinebotFrame.readBfgWord(register: probeRegister))
        timeout(.probeVerify, 3.0, String(format: "探测 0x%02X 回读无回复", probeRegister))
    }

    private func concludeProbeRegister(_ after: Int) {
        let accepted = probeAckSeen && after == probeValue
        if accepted {
            probeWritable.append(probeRegister)
        } else {
            probeReadOnly.append(probeRegister)
        }
        log(String(format: "PROBE_RESULT 0x%02X ack=%@ before=%d after=%d → %@",
                   probeRegister, probeAckSeen ? "有" : "无",
                   probeValue, after, accepted ? "可写" : "只读"))
        advanceProbe()
    }

    private func endProbeRun() {
        let w = probeWritable.map { String(format: "0x%02X", $0) }.joined(separator: " ")
        let r = probeReadOnly.map { String(format: "0x%02X", $0) }.joined(separator: " ")
        log("PROBE_END 可写: \(w.isEmpty ? "无" : w) | 只读: \(r.isEmpty ? "无" : r)")
        result.probeWritable = probeWritable
        result.probeReadOnly = probeReadOnly
        if probeWritable.isEmpty {
            finish("探测完成：\(probeQueue.count) 个候选寄存器全部不接受写入。"
                + "容量这条路需要另一条写入路径，详见 PROBE_ 日志。")
        } else {
            finish("探测完成：可写 \(w)；只读 \(r.isEmpty ? "无" : r)。详见 PROBE_ 日志。")
        }
    }

    // MARK: - Capacity sweep implementation

    private func beginSweepRun() {
        // Candidates are derived after the first read, because the list starts at
        // the vehicle's own value. A placeholder keeps the API honest: nothing is
        // written until sweepOriginal is known.
        sweepCandidates = []
        sweepCursor = 0
        sweepOriginal = -1
        sweepAccepted = []
        sweepRefused = []
        state = .sweepPreRead
        status("容量值试探：先读取当前值作为基准…")
        send(NinebotFrame.readBfgWord(register: NinebotFrame.capacityWriteIndex))
        timeout(.sweepPreRead, 4.5, "试探前读取 0x0E 无回复")
    }

    private func advanceSweep() {
        guard sweepCursor < sweepCandidates.count else {
            endSweepRun()
            return
        }
        sweepValue = sweepCandidates[sweepCursor]
        sweepCursor += 1
        sweepAckSeen = false
        guard let frame = NinebotFrame.writeBfgWord(register: NinebotFrame.capacityWriteIndex,
                                                    value: sweepValue) else {
            log(String(format: "SWEEP_RESULT v=%d 帧构造被拒，跳过", sweepValue))
            advanceSweep()
            return
        }
        log(String(format: "SWEEP_TRY v=%d（%d/%d）frame=%@",
                   sweepValue, sweepCursor, sweepCandidates.count, Hex.encode(frame)))
        status(String(format: "试探 %d mAh（%d/%d）…",
                      sweepValue, sweepCursor, sweepCandidates.count))
        state = .sweepTryWrite
        send(frame)
        result.writeCommandSent = true
        scheduleVerify(after: 2.0) { [weak self] in self?.readBackSweepValue() }
    }

    private func readBackSweepValue() {
        guard !finished, state == .sweepTryWrite || state == .sweepVerify else { return }
        state = .sweepVerify
        send(NinebotFrame.readBfgWord(register: NinebotFrame.capacityWriteIndex))
        timeout(.sweepVerify, 3.0, String(format: "试探 %d 回读无回复", sweepValue))
    }

    /// Settles the candidate, then puts the original value back.
    private func concludeSweepValue(_ after: Int) {
        // A value that reads back is accepted even if the ACK was lost; a value
        // that does not is refused even if an ACK arrived. The register is the
        // evidence, the ACK only the first hint.
        let accepted = after == sweepValue
        if accepted { sweepAccepted.append(sweepValue) } else { sweepRefused.append(sweepValue) }
        log(String(format: "SWEEP_RESULT v=%d ack=%@ after=%d → %@",
                   sweepValue, sweepAckSeen ? "有" : "无", after,
                   accepted ? "接受" : "拒绝"))
        restoreSweepValue()
    }

    /// The revert. Everything above is allowed to be inconclusive; this is not.
    private func restoreSweepValue() {
        guard let frame = NinebotFrame.writeBfgWord(register: NinebotFrame.capacityWriteIndex,
                                                    value: sweepOriginal) else {
            fail("无法构造恢复帧；试探中止，0x0E 可能不是原值。")
            return
        }
        log(String(format: "SWEEP_RESTORE %d → %d frame=%@",
                   sweepValue, sweepOriginal, Hex.encode(frame)))
        state = .sweepRestore
        send(frame)
        scheduleVerify(after: 2.0) { [weak self] in self?.verifySweepRestore() }
    }

    private func verifySweepRestore() {
        guard !finished, state == .sweepRestore || state == .sweepRestoreVerify else { return }
        state = .sweepRestoreVerify
        send(NinebotFrame.readBfgWord(register: NinebotFrame.capacityWriteIndex))
        timeout(.sweepRestoreVerify, 3.0, "恢复回读无回复")
    }

    private func concludeSweepRestore(_ restored: Int) {
        guard restored == sweepOriginal else {
            // Stop here. Continuing would walk the register further from where it
            // started, which is the one outcome this mode must never produce.
            log(String(format: "SWEEP_RESTORE_FAILED 期望 %d 实际 %d；中止试探",
                       sweepOriginal, restored))
            fail(String(format: "0x0E 未能恢复到原值 %d（当前 %d）。试探已中止，"
                        + "请用「恢复 0x0E 到备份值」或重新连接核对。",
                        sweepOriginal, restored))
            return
        }
        log(String(format: "SWEEP_RESTORE_OK 0x0E=%d", restored))
        advanceSweep()
    }

    private func endSweepRun() {
        let ok = sweepAccepted.map(String.init).joined(separator: " ")
        let no = sweepRefused.map(String.init).joined(separator: " ")
        log("SWEEP_END 原值=\(sweepOriginal) 接受: \(ok.isEmpty ? "无" : ok) | 拒绝: \(no.isEmpty ? "无" : no)")
        result.sweepAccepted = sweepAccepted
        result.sweepRefused = sweepRefused
        if sweepAccepted.isEmpty {
            finish("试探完成：固件表内的候选值全部被拒绝。详见 SWEEP_ 日志。")
        } else {
            finish("试探完成：接受 \(ok)；拒绝 \(no.isEmpty ? "无" : no)。0x0E 已恢复为 \(sweepOriginal)。")
        }
    }

    private func endProfileWatch() {
        watchTimer?.cancel()
        watchTimer = nil
        if !watchTransitions.isEmpty {
            let trace = watchTransitions.joined(separator: " | ")
            log("WATCH_TRANSITIONS 共 \(watchTransitions.count) 次：\(trace)")
            // One hop reads as a restore; three read as an upstream module
            // rewriting the register. The count is the diagnosis, so it goes in
            // the headline rather than only in the log body.
            finish(String(format:
                "写入 0x%02X 生效过；观察 %g 秒内共 %d 次变化（首次 T+%.2fs）：%@",
                targetProfile, watchDuration, watchTransitions.count,
                watchChangedAt, trace))
        } else {
            finish(String(format: "写入 0x%02X 已确认并保持稳定 %g 秒。",
                          targetProfile, watchDuration))
        }
    }

    private func requestCapacityVerification() {
        capacityVerifyAttempts += 1
        if capacityVerifyAttempts > 1 { result.verificationRetried = true }
        send(NinebotFrame.readCapacity)
        timeout(.waitAfterCapacity, 4.5, "写入后读取容量参数无回复")
    }

    private func verifyAfterDisWriteSafely() {
        guard !finished, state == .waitDisWriteAck else { return }
        state = .waitDisAfter
        requestDisVerification()
    }

    private func retryDisVerificationSafely() {
        guard !finished, state == .waitDisAfter else { return }
        requestDisVerification()
    }

    private func requestDisVerification() {
        disVerifyAttempts += 1
        status(String(format: "仪表写入已发送，正在回读配置（%d/%d）…",
                      disVerifyAttempts, NinebotFrame.maxDisVerifyAttempts))
        send(NinebotFrame.readDisConfig)
        timeout(.waitDisAfter, 4.5, "仪表配置回读无回复")
    }

    /// A post-write disconnect is its own outcome: the command may well have
    /// landed, so it is reported as unconfirmed rather than as a plain failure.
    private func handlePostWriteConnectionLoss() -> Bool {
        guard result.writeCommandSent else { return false }
        switch operation {
        case .writeDisVoltage:
            if result.disConfigReadbackVerified {
                finish("仪表配置已回读确认；随后连接中断。断电保持仍需验证。")
            } else {
                fail("仪表写入指令已发送，但连接中断，结果尚未确认；请重新连接读取当前配置。")
            }
            return true
        case .writeProfile:
            if result.profileReadbackVerified || result.afterProfile == targetProfile {
                finish("Profile 已回读确认；随后连接中断。")
            } else {
                fail("写入指令已发送，但连接中断，结果尚未确认；请重新连接读取当前配置。")
            }
            return true
        case .writeCapacity:
            // Without this the capacity path fell through to `default: false` and
            // a post-write disconnect was reported as an ordinary failure — the
            // one outcome that must never be silent, because the command may well
            // have landed on the register the state-of-charge is computed from.
            if result.capacityReadbackVerified {
                finish("容量寄存器已回读确认；随后连接中断。断电保持仍需验证。")
            } else {
                fail("容量写入指令已发送，但连接中断，结果尚未确认；"
                    + "请重新连接读取 0x0E 当前值。")
            }
            return true
        default:
            return false
        }
    }

    // MARK: - Helpers

    /// Funnels every transport callback onto the client's own queue.
    ///
    /// The central delivers on its own queue while the timeout timers fire on
    /// this one, and the state machine is not otherwise thread-safe. On device
    /// this was a latent race; under the simulator's faster turnaround it is
    /// routinely reachable.
    private func onQueue(_ work: @escaping @Sendable () -> Void) {
        if DispatchQueue.getSpecific(key: BfgBleClient.queueKey) != nil {
            work()
        } else {
            queue.async(execute: work)
        }
    }

    private func wipePassword() {
        for i in 0..<password16.count { password16[i] = 0 }
    }

    private func describe(_ error: Error) -> String {
        if let localized = error as? LocalizedError, let text = localized.errorDescription {
            return text
        }
        return error.localizedDescription
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        // Android used SecureRandom with the same intent: the platform CSPRNG.
        SecureRandom.bytes(count)
    }
}

// MARK: - Transport delegate

extension BfgBleClient: BleTransportDelegate {
    private func handleCentralState(_ poweredOn: Bool) {
        guard !finished else { return }
        if poweredOn {
            if awaitingCentralState {
                awaitingCentralState = false
                clearTimeout()
                beginScan()
            }
        } else if awaitingCentralState || state == .scanning {
            awaitingCentralState = false
            fail(BfgBleClient.bluetoothOffMessage)
        }
    }

    public func bleTransportDidUpdateState(poweredOn: Bool) {
        onQueue { [weak self] in self?.handleCentralState(poweredOn) }
    }

    private func handleDiscover(_ identifier: String, _ name: String) {
        guard !finished, state == .scanning else { return }
        guard let serial = BfgBleClient.serialFromName(name) else { return }

        if operation == .discoverVehicles {
            // Pairing overwrites the vehicle's only key slot, so the user
            // confirms which vehicle to pair from this list.
            if !discoveredVehicles.contains(where: { $0.identifier == identifier }) {
                discoveredVehicles.append((serial, identifier))
                status("已找到 \(discoveredVehicles.count) 台车辆…")
            }
            return
        }

        if !record.effectiveSn.isEmpty,
           record.effectiveSn.caseInsensitiveCompare(serial) != .orderedSame {
            return
        }

        discoveredSerial = serial
        transport.stopScan()
        clearTimeout()
        state = .connecting
        status("已发现 \(serial)；正在连接…")
        crypto = try? Encryption2(bluetoothName: serial)
        guard crypto != nil else {
            fail("加密初始化失败")
            return
        }
        transport.connect(identifier: identifier)
        timeout(.connecting, 12, "连接超时")
    }

    public func bleTransport(didDiscover identifier: String, name: String) {
        onQueue { [weak self] in self?.handleDiscover(identifier, name) }
    }

    private func handleConnect() {
        guard !finished else { return }
        clearTimeout()
        state = .discovering
        status("已连接；正在发现服务…")
        // 6 s is the original's figure, but Android reached this point with a
        // warm GATT cache and discovered unfiltered; a first discovery on iOS has
        // neither, and the transport retries a silent attempt at 3 s. The budget
        // has to be wide enough for a retry to land, so it is widened here.
        timeout(.discovering, 15, "发现服务超时")
    }

    public func bleTransportDidConnect() {
        onQueue { [weak self] in self?.handleConnect() }
    }

    private func handleDisconnect(_ error: Error?) {
        guard !finished else { return }
        if handlePostWriteConnectionLoss() { return }
        fail("连接已断开" + (error.map { "：\($0.localizedDescription)" } ?? ""))
    }

    public func bleTransport(didDisconnect error: Error?) {
        onQueue { [weak self] in self?.handleDisconnect(error) }
    }

    private func handleDiscoverServices(_ error: Error?) {
        guard !finished else { return }
        guard error == nil else {
            fail("发现服务失败：\(describe(error!))")
            return
        }
        clearTimeout()
        state = .subscribing
        status("找到九号BLE通道；开启通知…")
        timeout(.subscribing, 5, "开启通知超时")
    }

    public func bleTransport(didDiscoverServices error: Error?) {
        onQueue { [weak self] in self?.handleDiscoverServices(error) }
    }

    private func handleNotificationState(_ error: Error?) {
        guard !finished, state == .subscribing else { return }
        guard error == nil else {
            fail("开启Notify失败")
            return
        }
        do {
            guard let crypto else { throw BleError.txNotReady }
            let encrypted = try crypto.encryptPreComm(NinebotFrame.preComm)
            guard encrypted.count == 13 else {
                throw NSError(domain: "bfg", code: 10, userInfo: [NSLocalizedDescriptionKey:
                    "PRE_COMM加密长度异常"])
            }
            clearTimeout()
            state = .waitPreComm
            status("Notify已开启；发送 PRE_COMM…")
            sendRaw(encrypted)
            timeout(.waitPreComm, 5, "PRE_COMM无回复")
        } catch {
            fail("PRE_COMM失败：\(describe(error))")
        }
    }

    public func bleTransport(didUpdateNotificationState error: Error?) {
        onQueue { [weak self] in self?.handleNotificationState(error) }
    }

    private func handleReceive(_ data: Data) {
        handleNotify([UInt8](data))
    }

    public func bleTransport(didReceive data: Data) {
        onQueue { [weak self] in self?.handleReceive(data) }
    }

    private func handleWriteResult(_ error: Error?) {
        guard error == nil else {
            fail("写入特征失败：\(describe(error!))")
            return
        }
        if state == .waitDisWriteAck || state == .waitWriteAck {
            // The write itself succeeded; the vehicle's reply is what confirms
            // the value, so nothing is finished here.
            log("写入已发送，等待车辆回执")
        }
    }

    public func bleTransport(didWrite error: Error?) {
        onQueue { [weak self] in self?.handleWriteResult(error) }
    }

    /// Transport facts (negotiated write length, write type, write outcomes)
    /// folded into the same log the rider exports after a failed attempt.
    public func bleTransport(log line: String) {
        onQueue { [weak self] in self?.log(line) }
    }

    /// The vehicle advertises its 14-character serial as the BLE local name.
    /// Android searched the raw advertisement bytes for it; iOS only exposes
    /// the parsed name, so the name itself must be the serial.
    private static func serialFromName(_ name: String) -> String? {
        let pattern = "^[A-Za-z0-9]{14}$"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(name.startIndex..<name.endIndex, in: name)
        guard let match = regex.firstMatch(in: name, range: range),
              match.range == range else { return nil }
        return name.uppercased()
    }
}
