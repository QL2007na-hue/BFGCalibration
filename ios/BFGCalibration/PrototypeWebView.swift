import Foundation
import SwiftUI
// Only for `UIApplication.openSettingsURLString`, which the Bluetooth-off prompt
// needs; SwiftUI does not re-export it.
import UIKit
// WebKit has not yet been fully annotated for Swift concurrency, so importing
// it without this produces a Sendable-related warning on every build.
@preconcurrency import WebKit
import BFGCore

/// Hosts `bfg-calibration-flow.html` in a WKWebView.
///
/// The page is the presentation layer. Android injected a Java object named
/// `BfgNative` with `addJavascriptInterface`; WKWebView has no equivalent, so a
/// `WKUserScript` installs a shim with the same shape at document start. The
/// page keeps calling `window.BfgNative.action(action, value)` unchanged.
///
/// The page has been adapted for iOS: features that only existed to drive the
/// Android root / virtual-container credential path were removed rather than
/// left as dead buttons.
struct PrototypeWebView: UIViewRepresentable {
    let coordinator: PrototypeCoordinator

    func makeCoordinator() -> PrototypeCoordinator { coordinator }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.userContentController.addUserScript(PrototypeCoordinator.bridgeShim)
        config.userContentController.add(coordinator, name: "BfgNative")
        // The page is fully self-contained: no network, no external assets,
        // no localStorage. Nothing needs to be enabled beyond JavaScript.
        config.defaultWebpagePreferences.allowsContentJavaScript = true

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = coordinator
        webView.isOpaque = false
        webView.scrollView.bounces = false
        coordinator.attach(webView)

        if let url = Bundle.main.url(forResource: "bfg-calibration-flow", withExtension: "html") {
            webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) { }

    /// Declaring the size explicitly stops SwiftUI from sizing the representable
    /// to the web view's intrinsic content size, which can show the page in a
    /// band rather than filling the window.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: WKWebView,
                      context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? uiView.bounds.width,
               height: proposal.height ?? uiView.bounds.height)
    }
}

/// Receives `BfgNative.action(...)` calls, drives the BLE client, and pushes
/// state back with `bfgNativeUpdate` / `bfgNativeGo`.
final class PrototypeCoordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {

    /// Installed before any page script runs so the page never sees a missing
    /// `BfgNative`. Argument coercion matches Android's `String(value)`.
    static let bridgeShim = WKUserScript(
        source: """
        window.BfgNative = {
            action: function (action, value) {
                window.webkit.messageHandlers.BfgNative.postMessage({
                    action: String(action),
                    value: value === undefined || value === null ? '' : String(value)
                });
            }
        };
        """,
        injectionTime: .atDocumentStart,
        forMainFrameOnly: true)

    /// A write the user has chosen but not yet confirmed through the risk gate.
    private struct PendingWrite {
        let isDashboard: Bool
        let voltage: Int
        let capacityMah: Int
        /// Meter target profile byte, or -1 for a dashboard write.
        let profile: Int
        /// Wording used by the gate and the result screen.
        let restoreLabel: String?
        /// The dashboard config the user based this choice on, so a value that
        /// moved underneath them aborts instead of being overwritten.
        let expectedDisConfigRaw: Int
        /// Set once the user accepted an unvalidated dashboard voltage encoding.
        var allowUnverifiedDis: Bool = false
        /// Gate stage: a dashboard write passes two gates, the meter one.
        var stage: Int = 0
    }

    /// The risk gate is timed by this side. The page renders it and counts down
    /// for the user, but `TimedRiskGate` decides whether the confirmation is
    /// accepted, so the wait cannot be skipped on a stale or replayed tap.
    private struct RiskGate {
        let nonce: Int
        let readyAtMillis: Int64
        let seconds: Int
    }

    private let backupStore = BackupStore()

    private weak var webView: WKWebView?
    private var client: BfgBleClient?
    private var pageReady = false
    /// The operation the live client is running, so its result can be routed.
    private var activeOperation: BfgBleClient.Operation = .readOnly
    /// Retained for the diagnostic export; the page only ever shows the last line.
    private var diagnosticLog: [String] = []
    /// Start of the diagnostic timeline. Every question this log has been asked
    /// is a *relative* one — "how long after the write did the value change
    /// back" — and a wall clock answers that only after arithmetic, while a
    /// clock adjustment mid-run can make the sequence run backwards. Monotonic,
    /// so the deltas are always real.
    private var logClock = DispatchTime.now()
    private var logClockStarted = false
    /// Ticks the pairing screen's "seconds remaining" figure while a scan runs.
    private var scanCountdown: DispatchWorkItem?
    private var scanSecondsLeft = 0

    /// Result of the last completed read, which every write is derived from.
    private var lastRead: BfgBleClient.Result?
    private var pendingWrite: PendingWrite?
    /// Set only after the rider explicitly accepts the read-only-serial default
    /// for this session; see WriteAccessPolicy.allowsReadOnlySerials. It lives on
    /// the coordinator, never on PendingWrite: a private stored property there
    /// would demote the struct's memberwise initialiser to private and break
    /// every construction site.
    private var allowReadOnlySerialWrite = false
    /// The action parked on the read-only-serial confirmation, run once it is
    /// given. A closure rather than a replayed value, because two different flows
    /// — a parameter write and a restore — can be the thing being confirmed.
    private var pendingSerialWaivedAction: (() -> Void)?
    /// Set for one write flow after the owner approves writing a profile byte the
    /// static table does not agree with. See the pre-write table check.
    private var offTableApproved = false
    /// The pre-write snapshot parked on that approval, replayed once it is given.
    private var pendingOffTableDump: RegisterDump?
    /// Throttle for the on-disk copy of the diagnostic trail.
    private var lastPersist = Date.distantPast
    /// A dashboard write parked on the unvalidated-encoding warning.
    private var pendingUnverified: PendingWrite?

    /// The delayed re-read the original runs after a confirmed write.
    ///
    /// A write's own read-back proves the value landed; the vehicle can still be
    /// catching up on the remaining capacity, so the value is read again a few
    /// seconds later rather than trusted immediately.
    private struct PostWriteCheck {
        let expectedProfile: Int
        let expectedDisConfig: Int
        var attempts: Int = 0
    }
    private var postWriteCheck: PostWriteCheck?
    private var postWriteTimer: DispatchWorkItem?
    /// Where the last write was aimed, kept so the page's "re-check" button can
    /// re-run the verification without a new write.
    private var lastPostWriteTarget: (profile: Int, disConfig: Int, isDashboard: Bool)?
    /// The payload of a write the user asked to retry, replayed only after a
    /// fresh read has been put back in front of them.
    private var pendingRetryRequest: String?

    /// What a register sweep is for, so its result can be routed.
    private enum DumpPurpose { case preWrite, postWrite, adaptation }
    private var dumpPurpose: DumpPurpose?
    /// The snapshot taken immediately before a write, which the write is
    /// measured against afterwards.
    private var preWriteDump: RegisterDump?
    private var lastAdaptationDump: RegisterDump?
    /// Where the last snapshot was written, so it can be handed to the share
    /// sheet without guessing its timestamped name.
    private var lastDumpURL: URL?
    private var previousAdaptationDump: RegisterDump?
    private var gate: RiskGate?
    private var gateNonce = 0
    /// Meter gates accepted in this session, keyed by serial and target profile,
    /// so a repeated write to the same target does not re-ask. Never persisted.
    private var approvedMeterGates = Set<String>()

    /// State mirrored into the page. Keys match the field names the HTML reads.
    private var state: [String: Any] = [
        "appVersion": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
        "connected": false,
        "vehicles": [],
        "readOnlyVehicle": false,
        "firstBackupValid": false,
        "recentBackupValid": false,
        "disBackupValid": false,
        "dumpReady": false,
        "disBackup": "未保存",
        "backupAlternativesDiffer": false,
        "firstBackup": "尚未建立",
        "recentBackup": "尚无写入前快照",
        "lastConfirmedTarget": "尚无已确认的写入",
        "scanReplies": 0,
        "scanTimeouts": 0,
        // Dark is the primary look. Send `false` to use the light theme, or
        // derive it from traitCollection.userInterfaceStyle to follow the
        // system instead.
        "dark": true
    ]

    func attach(_ webView: WKWebView) {
        self.webView = webView
    }

    // MARK: - Native -> JS

    /// Sends the current state to the page.
    ///
    /// The keys below are **directives to the page, not state this side owns**:
    /// the page's own `go()` and `close-modal` clear `screen` and `modal`, and it
    /// reports navigation back through `screen` / `modal-state`. Keeping a copy
    /// here means the *next* push — a bare status update is enough — re-sends it,
    /// which drags the rider back to a page they already left, or re-opens a
    /// dialog they just closed. On the settings screen that made every
    /// navigation bounce back and the home button unreachable.
    ///
    /// So each directive is sent exactly once and then removed from the state —
    /// removed, not overwritten with NSNull: a null one is itself a directive,
    /// and the page obeys it by rendering the home screen.
    static let oneShotKeys = ["screen", "modal", "errorMessage", "result", "writeGate"]

    private func pushState() {
        guard pageReady, let webView else { return }
        // payload is a value copy, taken before the directives are consumed.
        let payload = state
        // Remove the directive; never leave NSNull behind. A lingering
        // "screen": null is copied into the page's own state by its
        // Object.assign, and a null screen has no branch in the page's render
        // switch, so it falls through to the home template. The next unrelated
        // push — a status line, the one-second scan countdown — then repatriated
        // the rider to the home screen from wherever they were.
        //
        // An explicit state["modal"] = NSNull() still sends its null exactly
        // once, which is how a dialog is deliberately closed. What must not
        // survive is the implicit null this loop used to write.
        for key in Self.oneShotKeys { state.removeValue(forKey: key) }
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.bfgNativeUpdate && window.bfgNativeUpdate(\(json));")
    }

    private func goTo(_ screen: String) {
        guard pageReady, let webView else { return }
        webView.evaluateJavaScript("window.bfgNativeGo && window.bfgNativeGo('\(screen)');")
    }

    // MARK: - JS -> Native

    func userContentController(_ controller: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any],
              let action = body["action"] as? String else { return }
        let value = body["value"] as? String ?? ""
        handle(action: action, value: value)
    }

    private func handle(action: String, value: String) {
        switch action {
        case "pair-scan", "refresh-vehicles":
            startDiscovery()

        case "begin-pair":
            pair()

        case "begin-connect", "refresh-read":
            refreshRead()

        case "post-write-reread":
            requestPostWriteReread()

        case "start-repair":
            pair()

        case "pair-select":
            // The page mirrors the tapped serial into `vehicleSn`, so the index
            // itself carries no information the native side needs.
            break

        case "scan-dis", "scan-bfg":
            scan(module: action == "scan-dis" ? RegisterReadPlan.dashboard
                                              : RegisterReadPlan.meter)

        case "do-write":
            requestWrite(value: value)

        case "retry-write":
            requestRetryWrite(value: value)

        case "confirm-unverified-dis":
            confirmUnverifiedDashboardWrite()

        case "confirm-nserial-write":
            confirmReadOnlySerialWrite()

        case "confirm-offtable-write":
            confirmOffTableWrite()

        case "restore-first":
            requestRestore(first: true)

        case "restore-prewrite":
            requestRestore(first: false)

        case "restore-dis":
            requestDashboardRestore()

        case "write-gate-confirm":
            confirmGate(value: value)

        case "write-gate-cancel":
            pendingWrite = nil
            gate = nil

        case "cancel":
            // Captured before the teardown: whether this cancel aborted a write
            // flow decides where the rider has to land.
            let wroteAnything = activeOperation == .writeProfile
                || activeOperation == .writeDisVoltage
            let abortedWriteFlow = pendingWrite != nil
                || dumpPurpose == .preWrite
                || wroteAnything
            client?.cancel()
            client = nil
            dumpPurpose = nil
            pendingWrite = nil
            pendingUnverified = nil
            gate = nil
            state["busyMessage"] = NSNull()
            // Cancelling used to leave the page on the write-progress screen with
            // nothing on it. The back arrow sends a cancel and then deliberately
            // does not navigate, the client's own cancel never calls the listener
            // back, and that screen's caption falls back to a waiting line — so
            // the rider could not reach settings, could not export the log and
            // could not get home. A cancel has to end somewhere final and say so.
            if abortedWriteFlow {
                // Accurate in both directions: before the write frame goes out we
                // can promise nothing was written; once it may have gone out we
                // must not.
                state["errorMessage"] = wroteAnything
                    ? "已取消。写入指令可能已经发出，请重新读取车辆参数确认当前配置后再决定下一步。"
                    : "已取消；本次没有发送任何写入指令，车辆参数未改变。"
                state["screen"] = "review"
                state["modal"] = "operation-failed"
            }
            pushState()

        case "show-license":
            state["modal"] = "license"
            state["licenseText"] = Self.licenseText() ?? "未找到使用声明文件。"
            pushState()

        case "export-diag":
            exportDiagnostics()

        case "share-diagnostic":
            shareDiagnosticFile()

        case "share-dump":
            shareLatestDumpFile()

        case "dump-registers":
            startAdaptationDump()

        case "compare-dump":
            compareWithLastDump()

        case "clear-data":
            clearLocalData()

        case "open-bluetooth-settings":
            openSystemSettings()

        case "open-website":
            openWebsite()

        case "screen", "modal-state", "select-vehicle":
            // Purely presentational, and the page already handled it locally.
            // `screen`/`modal-state` are the page reporting its own navigation
            // back; nothing needs to be kept in sync, because `pushState()`
            // sends those as one-shot directives rather than holding them.
            break

        default:
            // Actions that only existed for the Android root / credential path
            // are no longer reachable from the page, and are ignored if a stale
            // call still arrives.
            break
        }
    }

    /// The page's "打开蓝牙设置" button, and the only way out of the Bluetooth-off
    /// dialog. iOS has no URL that reaches the Bluetooth pane directly, so this
    /// opens the app's own settings, one tap from there.
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// 打开官网。交给 Safari，因此不受 App 内 ATS 限制。
    private func openWebsite() {
        guard let url = URL(string: "http://8.137.15.226/9lz/") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Vehicle discovery

    private func startDiscovery() {
        state["vehicles"] = []
        state["pairScanning"] = true
        pushState()
        startClient(record: placeholderRecord(serial: ""), operation: .discoverVehicles)
        startScanCountdown()
    }

    /// Drives the "约 N 秒后结束" figure on the pairing screen from the same
    /// window the client is actually scanning for. Without it the page sat on a
    /// hard 0 for the whole scan.
    private func startScanCountdown() {
        stopScanCountdown()
        scanSecondsLeft = Int(BfgBleClient.discoveryWindow)
        state["pairScanSeconds"] = scanSecondsLeft
        pushState()
        tickScanCountdown()
    }

    private func tickScanCountdown() {
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.scanSecondsLeft = max(0, self.scanSecondsLeft - 1)
            self.state["pairScanSeconds"] = self.scanSecondsLeft
            self.pushState()
            if self.scanSecondsLeft > 0 {
                self.tickScanCountdown()
            } else {
                self.scanCountdown = nil
            }
        }
        scanCountdown = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: item)
    }

    private func stopScanCountdown() {
        scanCountdown?.cancel()
        scanCountdown = nil
    }

    // MARK: - BLE operations

    private var serial: String { state["vehicleSn"] as? String ?? "" }

    private func pair() {
        goTo("pair-progress")
        // An empty serial lets the client take the first vehicle that advertises
        // a valid name; a set one pins the scan to the row the user tapped.
        startClient(record: placeholderRecord(serial: serial), operation: .pairAndRead)
    }

    /// A sweep of one module.
    ///
    /// This used to run the single-pass census, which reported only how many
    /// addresses answered and wrote nothing anywhere — so a finished scan left
    /// the rider with no file and nothing to share, which is what the buttons
    /// appeared to promise. It now runs the same two-pass snapshot the full
    /// sweep does, for a single module: real values, real stability, a JSON in
    /// Documents and a share button on the completing dialog.
    private func scan(module: Int) {
        dumpPurpose = .adaptation
        startClient(record: placeholderRecord(serial: serial),
                    operation: .dumpRegisters, dumpModules: [module])
    }

    private func refreshRead() {
        startClient(record: placeholderRecord(serial: serial), operation: .readOnly)
    }

    /// Turns the picker's `(voltage, capacity)` choice into a concrete target and
    /// then re-reads the vehicle, because a write may not proceed without a
    /// fresh pre-write snapshot.
    private func requestWrite(value: String) {
        guard let lastRead else {
            writeFailure("车辆数据尚未读取完成，请重新连接后再试。")
            return
        }
        // The original refuses N-prefixed serials outright because it never
        // validated them. That is a default, not a property of this vehicle, and
        // the owner is the one who can tell the difference — so ask once, state
        // the consequence, and keep every other rail in place.
        // One approval covers one write flow, never the session.
        offTableApproved = false
        pendingOffTableDump = nil
        if WriteAccessPolicy.isReadOnlySerial(serial), !allowReadOnlySerialWrite {
            pendingSerialWaivedAction = { [weak self] in self?.requestWrite(value: value) }
            state["errorMessage"] = "该车辆序列号以 N 开头。原版工具把这类序列号一律视为只读，"
                + "因为它从未验证过这些车型——这台车就是其一。"
                + "继续只会写入计量模块的电压与容量，写前仍会整片快照、仍需通过风险门、"
                + "写后仍会全量比对，随时可以回滚到写入前的值。"
            state["modal"] = "nserial-write"
            pushState()
            return
        }

        guard let request = Self.parseWriteRequest(value) else {
            writeFailure("目标参数无效，请重新选择电压和容量。")
            return
        }

        let isDashboard = request.type == "dashboard"
        var profile = -1

        if isDashboard {
            guard lastRead.dashboardNominalVoltage > 0, lastRead.disConfigRaw >= 0 else {
                writeFailure("仪表电压配置没有读取到，请重新连接车辆。")
                return
            }
            do {
                let target = try DisVoltageConfig.target(currentRaw: lastRead.disConfigRaw,
                                                         voltage: request.voltage)
                guard target != lastRead.disConfigRaw else {
                    writeFailure("仪表已经是所选电压档位，本次没有发送写入。")
                    return
                }
                if DisVoltageConfig.requiresExtraWarning(currentRaw: lastRead.disConfigRaw,
                                                         targetRaw: target) {
                    // This encoding family has no in-vehicle validation; the user
                    // must accept that explicitly before any frame is sent.
                    pendingUnverified = PendingWrite(isDashboard: true,
                                                     voltage: request.voltage,
                                                     capacityMah: request.capacityMah,
                                                     profile: -1,
                                                     restoreLabel: nil,
                                                     expectedDisConfigRaw: lastRead.disConfigRaw)
                    state["errorMessage"] = "这组仪表配置尚无实车验证，请确认可以恢复原参数后继续。"
                    state["modal"] = "unverified-dis"
                    pushState()
                    return
                }
            } catch {
                writeFailure(error.localizedDescription)
                return
            }
        } else {
            let voltageCode = BfgProfileCatalog.voltageCode(forVoltage: request.voltage)
            let currentIndex = lastRead.profileRaw < 0 ? -1 : (lastRead.profileRaw >> 4) & 0xF
            // profileIndex resolves a table *index*, not the byte that goes on the
            // wire. The wire byte carries the index in its high nibble and the
            // voltage code in its low nibble, so the shift is not optional: using
            // the bare index sent 0x05 where 0x50 was meant — an illegal voltage
            // code, not merely the wrong capacity — and the vehicle rejected every
            // write, reading back its old value four times in a row. This is why
            // no write ever landed on the real vehicle.
            // profileByte, not profileIndex: the index alone is not the byte that
            // goes on the wire, and using it sent 0x05 where 0x50 was meant — an
            // illegal voltage code, so the vehicle rejected every write and read
            // back its old value. Two unit tests now pin this down.
            profile = BfgProfileCatalog.profileByte(requestedMilliAh: request.capacityMah,
                                                    voltageCode: voltageCode,
                                                    preferring: currentIndex)
            guard profile >= 0 else {
                writeFailure("所选容量未适配，请重新选择电压和容量。")
                return
            }
            guard lastRead.writeSupported else {
                writeFailure("当前仪表与计量模块组合尚未通过写入验证；"
                    + "本次没有发送写入。请先导出诊断数据用于适配。")
                return
            }
            guard backupStore.firstBackup(serial: serial).valid else {
                writeFailure("首次原参数备份尚未建立，本次没有发送写入指令。"
                    + "请先返回连接车辆读取一次，再回来写入。")
                return
            }
        }

        pendingWrite = PendingWrite(isDashboard: isDashboard,
                                    voltage: request.voltage,
                                    capacityMah: request.capacityMah,
                                    profile: profile,
                                    restoreLabel: nil,
                                    expectedDisConfigRaw: lastRead.disConfigRaw)
        beginPreWriteRead()
    }

    /// The owner's answer to "this table does not describe your vehicle".
    ///
    /// Replays the parked pre-write branch with the same snapshot. The approval
    /// flag carries it past the table check and on to the risk gate — the write
    /// itself is unchanged, still one profile byte, still snapshotted first and
    /// still compared afterwards.
    private func confirmOffTableWrite() {
        guard let dump = pendingOffTableDump else { return }
        pendingOffTableDump = nil
        offTableApproved = true
        state["modal"] = NSNull()
        pushState()
        handleDump(dump, purpose: .preWrite)
    }

    /// The owner's answer to the read-only-serial default.
    private func confirmReadOnlySerialWrite() {
        guard let action = pendingSerialWaivedAction else { return }
        pendingSerialWaivedAction = nil
        allowReadOnlySerialWrite = true
        WriteAccessPolicy.allowsReadOnlySerials = true
        // The page gates the write button on these two, so they have to follow
        // the decision or the rider confirms and then finds the button disabled.
        state["readOnlyVehicle"] = false
        if let read = lastRead { state["writeSupported"] = read.writeSupported }
        state["modal"] = NSNull()
        pushState()
        action()
    }

    /// The page's "still try" answer to the unvalidated-encoding warning.
    private func confirmUnverifiedDashboardWrite() {
        guard var pending = pendingUnverified else { return }
        pendingUnverified = nil
        pending.allowUnverifiedDis = true
        pendingWrite = pending
        beginPreWriteRead()
    }

    /// A write may not proceed without a fresh pre-write snapshot, so the read
    /// happens first and the gate opens only once it has been stored.
    private func beginPreWriteRead() {
        state["modal"] = NSNull()
        state["writeStage"] = "precheck"
        pushState()
        startClient(record: placeholderRecord(serial: serial), operation: .compareRead)
    }

    /// The page's "try again" after a failed write.
    ///
    /// The original re-reads and then puts the confirmation back in front of the
    /// user, rather than writing again on the strength of the earlier choice.
    private func requestRetryWrite(value: String) {
        pendingRetryRequest = value
        goTo("connect-progress")
        startClient(record: placeholderRecord(serial: serial), operation: .compareRead)
    }

    /// Re-runs the post-write verification against the previous write's target.
    /// Reads only — this never re-sends the write.
    private func requestPostWriteReread() {
        guard let target = lastPostWriteTarget else {
            refreshRead()
            return
        }
        postWriteCheck = PostWriteCheck(expectedProfile: target.profile,
                                        expectedDisConfig: target.disConfig)
        goTo("post-write-check")
        startClient(record: placeholderRecord(serial: serial), operation: .compareRead)
    }

    /// Restores the dashboard's original `0x92` bytes.
    ///
    /// Kept separate from the meter restore because the dashboard encoding is
    /// independent of the BFG profile, and the original refuses to touch it when
    /// the stored bytes belong to a different config family — writing them would
    /// change a value whose meaning it cannot confirm.
    private func requestDashboardRestore() {
        guard !WriteAccessPolicy.isReadOnlySerial(serial) else {
            state["errorMessage"] = "该序列号以 N 开头，仅允许读取，不发送任何写入指令。"
            state["modal"] = "restore-unavailable"
            pushState()
            return
        }
        let stored = backupStore.disConfigBackup(serial: serial)
        guard DisVoltageConfig.nominalVoltage(stored) >= 0 else {
            state["errorMessage"] = "没有首次仪表配置备份，请先连接车辆读取。"
            state["modal"] = "restore-unavailable"
            pushState()
            return
        }
        guard let read = lastRead else {
            state["errorMessage"] = "请先连接并读取车辆数据。"
            state["modal"] = "restore-unavailable"
            pushState()
            return
        }
        guard (stored & 0xF0) == (read.disConfigRaw & 0xF0) else {
            state["errorMessage"] = "当前仪表配置与首次备份不属于同一组，已停止自动恢复。"
            state["modal"] = "restore-unavailable"
            pushState()
            return
        }
        pendingWrite = PendingWrite(isDashboard: true,
                                    voltage: DisVoltageConfig.nominalVoltage(stored),
                                    capacityMah: 0,
                                    profile: -1,
                                    restoreLabel: "首次仪表配置",
                                    expectedDisConfigRaw: read.disConfigRaw)
        beginPreWriteRead()
    }

    /// Takes the pre-write snapshot. Everything the write-time safety checks
    /// need rides on it: the restore path, the static-table agreement test, and
    /// the baseline for spotting changes the write was not meant to make.
    private func beginPreWriteDump(_ pending: PendingWrite) {
        preWriteDump = nil
        dumpPurpose = .preWrite
        let module = pending.isDashboard ? RegisterDump.dashboardModule
                                         : RegisterDump.meterModule
        state["busyMessage"] = "正在读取寄存器快照（写入前备份）…"
        pushState()
        startClient(record: placeholderRecord(serial: serial),
                    operation: .dumpRegisters, dumpModules: [module])
    }

    private func handleDump(_ dump: RegisterDump, purpose: DumpPurpose) {
        state["busyMessage"] = NSNull()
        refreshBackupState(serial: serial)

        switch purpose {
        case .preWrite:
            guard let pending = pendingWrite else {
                // The write was cancelled while its snapshot ran. The busy caption
                // was already cleared above, so returning here left the progress
                // screen blank and unexitable; end the flow visibly instead.
                state["errorMessage"] = "已取消；本次没有发送任何写入指令，车辆参数未改变。"
                state["screen"] = "review"
                state["modal"] = "operation-failed"
                pushState()
                return
            }
            let module = pending.isDashboard ? RegisterDump.dashboardModule
                                             : RegisterDump.meterModule

            // A module that did not read back completely is not backed up, and
            // an incomplete backup is not a way back.
            // The target and the addresses a rollback depends on have to be
            // readable and stable. Addresses the vehicle simply never answers are
            // recorded in the snapshot but must not by themselves veto the write:
            // demanding all 256 made writing impossible on real hardware, where
            // this vehicle leaves 37 addresses of the meter permanently silent.
            let required = pending.isDashboard ? [0x92] : [0x00, 0x0E, 0x0F, 0x1C]
            let unreadable = required.filter { index in
                guard let entry = dump.entry(module: module, index: index) else { return true }
                return !(entry.responded && entry.stable)
            }
            guard unreadable.isEmpty else {
                writeFailure("写入前未能稳定读到关键寄存器（"
                    + unreadable.map { String(format: "0x%02X", $0) }.joined(separator: "、")
                    + "），备份不完整，本次没有发送写入指令。请保持车辆开机后重试。")
                return
            }

            // The static table is an assumption about the firmware. If the
            // vehicle contradicts it, writing from the table would put the
            // wrong capacity on the vehicle — the failure that damages modules.
            if !pending.isDashboard, !offTableApproved,
               case .disagrees(let expected, let reported) = dump.agreement() {
                // Refusing outright is right for someone who simply wants their
                // battery set, but it leaves no way to *establish* the real
                // mapping — and for a model the author never saw, that mapping is
                // the whole problem. So state the discrepancy in numbers, park the
                // write, and let the owner decide. Nothing else is relaxed: the
                // snapshot is already taken, the risk gate still runs, and the
                // result is still compared afterwards and can be rolled back.
                pendingOffTableDump = dump
                state["errorMessage"] = "本车型的容量映射与静态表不同：表把档位 0x"
                    + String(format: "%02X", pending.profile) + " 读作 \(expected)mAh，"
                    + "你的车报的是 \(reported)mAh。照表写入得不到你选的容量，"
                    + "车会按它自己的表来解释这个档位编号。"
                    + "继续的话仍然只写一个档位字节：写前快照已保存，风险门与写后全量比对照常，随时可回滚。"
                state["modal"] = "offtable-write"
                pushState()
                return
            }

            preWriteDump = dump
            pushState()
            openGate()

        case .adaptation:
            // Routed to `saveAdaptationDump` before reaching here.
            break

        case .postWrite:
            guard let before = preWriteDump, let check = lastPostWriteTarget else { return }
            let changes = dump.changes(from: before)
            let expectedModule = check.isDashboard ? RegisterDump.dashboardModule
                                                   : RegisterDump.meterModule
            let expectedIndex = check.isDashboard ? 0x92 : 0x00
            let collateral = changes.filter {
                !($0.module == expectedModule && $0.index == expectedIndex)
            }
            if collateral.isEmpty {
                // Only a clean comparison earns the "confirmed" record: the sweep
                // exists to catch a write that reached further than intended, and
                // a target that landed alongside collateral damage is not a
                // successful write.
                if let target = lastPostWriteTarget, target.profile >= 0 {
                    backupStore.saveLastConfirmed(serial: dump.serial,
                                                  profile: target.profile)
                }
                refreshBackupState(serial: dump.serial)
                showWriteSuccess(capacityPending: false)
                state["errorMessage"] = "写入后比对：除目标地址外无其他寄存器变化。"
                pushState()
            } else {
                let list = collateral.prefix(8).map {
                    String(format: "0x%02X/0x%02X %d→%d", $0.module, $0.index,
                           $0.before, $0.after)
                }.joined(separator: "；")
                state["errorMessage"] = "⚠ 写入后检测到\(collateral.count)处目标之外的寄存器变化："
                    + list + "。这说明本次写入波及了预期之外的地址，"
                    + "请立即导出寄存器快照，并在查明原因前停止继续写入。"
                // Deliberately not `write-success`: this is the earliest signal
                // that the write reached further than intended, and it used to be
                // presented under a success dialog.
                state["screen"] = "review"
                state["result"] = NSNull()
                state["modal"] = "write-collateral"
                pushState()
            }
        }
    }

    private func requestRestore(first: Bool) {
        let backup = first ? backupStore.firstBackup(serial: serial)
                           : backupStore.prewriteBackup(serial: serial)
        // A restore is its own write flow and must earn its own approval: without
        // this, an override given for a parameter write leaked into the restore
        // path, which would then skip the table check entirely.
        offTableApproved = false
        pendingOffTableDump = nil

        guard backup.valid else {
            // The settings screen has no error area, so a message written here is
            // never seen: the button simply looked dead. Anything that stops a
            // restore has to say so in a dialog.
            state["errorMessage"] = "当前车辆没有可用备份。请先连接车辆读取一次 —— 备份在读取成功时建立。"
            state["modal"] = "operation-failed"
            pushState()
            return
        }
        if WriteAccessPolicy.isReadOnlySerial(serial), !allowReadOnlySerialWrite {
            pendingSerialWaivedAction = { [weak self] in self?.requestRestore(first: first) }
            state["errorMessage"] = "该车辆序列号以 N 开头。原版工具把这类序列号一律视为只读。"
                + "恢复会把备份里的档位写回计量模块，因此同样需要你确认一次；"
                + "确认后本次会话的写入一并放开。"
            state["modal"] = "nserial-write"
            pushState()
            return
        }
        pendingWrite = PendingWrite(isDashboard: false,
                                    voltage: BfgProfileCatalog.nominalVoltage(backup.profile),
                                    capacityMah: backup.capacity,
                                    profile: backup.profile,
                                    restoreLabel: first ? "首次原参数" : "最近写入前参数",
                                    expectedDisConfigRaw: lastRead?.disConfigRaw ?? -1)
        beginPreWriteRead()
    }

    private func startClient(record: DeviceRecord, operation: BfgBleClient.Operation,
                             targetProfile: Int = -1,
                             expectedDisConfigRaw: Int = -1,
                             allowUnverifiedDis: Bool = false,
                             dumpModules: [Int] = []) {
        client?.cancel()
        activeOperation = operation
        let newClient = BfgBleClient(record: record, operation: operation,
                                     targetProfile: targetProfile,
                                     expectedDisConfigRaw: expectedDisConfigRaw,
                                     allowUnverifiedDis: allowUnverifiedDis,
                                     dumpModules: dumpModules,
                                     transport: CoreBluetoothTransport(),
                                     credentialStore: KeychainCredentialStore.shared,
                                     listener: self)
        client = newClient
        newClient.start()
    }

    private func placeholderRecord(serial: String) -> DeviceRecord {
        // On iOS the serial is the identity; there is no MAC and no password to
        // import, so the record carries only what the scan can learn.
        DeviceRecord(id: -1, mac: "", sn: serial, name: serial, deviceType: "",
                     password16: [UInt8](repeating: 0, count: 16), source: "ios_pairing")
    }

    // MARK: - Risk gate

    /// Opens the next confirmation gate for the pending write.
    private func openGate() {
        guard let pending = pendingWrite else { return }
        if !pending.isDashboard,
           approvedMeterGates.contains("\(serial):\(pending.profile)") {
            // This vehicle and target were already accepted in this session; the
            // meter warning is asked once per target, not once per write.
            startWrite(pending)
            return
        }
        if !pending.isDashboard {
            // The meter dialog is only worth showing if the snapshot it
            // promises can actually be read back.
            let snapshot = backupStore.prewriteBackup(serial: serial)
            guard snapshot.valid,
                  snapshot.profile == lastRead?.profileRaw,
                  snapshot.capacity == lastRead?.displayBeforeCapacity else {
                writeFailure("本次写入前备份未能核实，没有发送写入指令。"
                    + "请重新连接并读取车辆。")
                return
            }
        } else {
            // The dashboard gets the same treatment. What a restore would have to
            // put back is the 0x92 config captured immediately before this write,
            // so it must be present and still agree with the vehicle's reading —
            // otherwise there is no way back and nothing is sent.
            guard let current = lastRead?.disConfigRaw, current >= 0,
                  DisVoltageConfig.nominalVoltage(current) >= 0,
                  backupStore.prewriteDisConfig(serial: serial) == current else {
                writeFailure("本次写入前备份未能核实，没有发送写入指令。"
                    + "请重新连接并读取车辆。")
                return
            }
        }

        let seconds: Int
        if pending.isDashboard {
            seconds = pending.stage == 0 ? TimedRiskGate.dashboardSeconds : 0
        } else {
            seconds = TimedRiskGate.meterSeconds
        }

        gateNonce += 1
        let readyAt = Self.uptimeMillis() + Int64(seconds) * 1000
        gate = RiskGate(nonce: gateNonce, readyAtMillis: readyAt, seconds: seconds)

        let content = Self.gateContent(pending: pending, seconds: seconds, nonce: gateNonce)
        state["writeGate"] = content
        pushState()
    }

    private func confirmGate(value: String) {
        guard let pending = pendingWrite, let gate else { return }
        guard let confirmation = Self.parseGateConfirmation(value),
              confirmation.nonce == gate.nonce else {
            return
        }
        guard TimedRiskGate.canProceed(elapsedRealtime: Self.uptimeMillis(),
                                       readyAt: gate.readyAtMillis,
                                       checked: confirmation.checked) else {
            return
        }

        if pending.isDashboard && pending.stage == 0 {
            // The dashboard write passes two gates in a row, as on Android.
            pendingWrite?.stage = 1
            self.gate = nil
            openGate()
            return
        }

        if !pending.isDashboard {
            approvedMeterGates.insert("\(serial):\(pending.profile)")
        }
        self.gate = nil
        state["writeGate"] = NSNull()
        startWrite(pending)
    }

    private func startWrite(_ pending: PendingWrite) {
        state["writeStage"] = "writing"
        pushState()
        let record = placeholderRecord(serial: serial)
        if pending.isDashboard {
            startClient(record: record, operation: .writeDisVoltage,
                        targetProfile: pending.voltage,
                        expectedDisConfigRaw: pending.expectedDisConfigRaw,
                        allowUnverifiedDis: pending.allowUnverifiedDis)
        } else {
            startClient(record: record, operation: .writeProfile,
                        targetProfile: pending.profile)
        }
    }

    private func writeFailure(_ message: String) {
        state["result"] = "failure"
        state["errorMessage"] = message
        state["screen"] = "review"
        state["modal"] = "write-failure"
        state["busyMessage"] = NSNull()
        pendingWrite = nil
        gate = nil
        pushState()
    }

    // MARK: - Diagnostics

    private func exportDiagnostics() {
        // Android wrote a file and shared it through FileProvider. iOS writes to
        // the app's Documents directory; reaching it needs the file-sharing keys
        // in Info.plist *and* a share path that does not depend on the Files app
        // at all, which is what the button on the dialog is for.
        let url = Self.documentsDirectory().appendingPathComponent("bfg-diagnostic.txt")
        let text = diagnosticReport()
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            state["errorMessage"] = "\(url.lastPathComponent) · \(text.count) 字节，"
                + "可在「文件」App 的本应用目录中找到，或直接用下面的分享按钮发出去。"
        } catch {
            state["errorMessage"] = "诊断导出失败：\(error.localizedDescription)"
        }
        state["modal"] = "diagnostic-exported"
        pushState()
    }

    // MARK: - Sharing exports

    /// Hands a file to the system share sheet.
    ///
    /// The Files app is not a route that always exists — before this app
    /// declared file sharing its Documents directory did not appear there at
    /// all, so an export wrote the file and left the rider with no way to get it
    /// off the phone. Sharing from the app itself is the path that always works,
    /// and it is one tap instead of a folder hunt.
    private func share(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else {
            state["errorMessage"] = "文件不存在，请先导出一次。"
            state["modal"] = "dump-complete"
            pushState()
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene }).first,
              var presenter = (scene.windows.first(where: { $0.isKeyWindow })
                                ?? scene.windows.first)?.rootViewController
        else { return }
        while let presented = presenter.presentedViewController { presenter = presented }
        let activity = UIActivityViewController(activityItems: [url],
                                                applicationActivities: nil)
        if let popover = activity.popoverPresentationController {
            popover.sourceView = presenter.view
            popover.sourceRect = CGRect(x: presenter.view.bounds.midX,
                                        y: presenter.view.bounds.midY, width: 0, height: 0)
        }
        presenter.present(activity, animated: true)
    }

    private func shareDiagnosticFile() {
        share(Self.documentsDirectory().appendingPathComponent("bfg-diagnostic.txt"))
    }

    private func shareLatestDumpFile() {
        guard let url = lastDumpURL else {
            state["errorMessage"] = "还没有寄存器快照，请先导出一次。"
            state["modal"] = "dump-complete"
            pushState()
            return
        }
        share(url)
    }

    /// Everything the log had, plus the state a driver-side problem needs:
    /// which vehicle, what was last read, and which build produced it.
    private func diagnosticReport() -> String {
        var lines = [
            "BFG iOS diagnostic",
            "time      \(Self.timestamp())",
            "app       \(state["appVersion"] ?? "?")",
            "vehicle   \(serial.isEmpty ? "(未连接)" : serial)",
            "mode      \(state["writeType"] ?? "-")",
            "supported write=\(state["writeSupported"] ?? "-") "
                + "dashboard=\(state["dashboardWriteSupported"] ?? "-")",
            "read      soc=\(state["soc"] ?? "-") voltage=\(state["batteryVoltage"] ?? "-") "
                + "meter=\(state["meterVoltage"] ?? "-") capacity=\(state["meterCapacity"] ?? "-")",
            "firmware  meter=\(state["meterFirmware"] ?? "-") dashboard=\(state["dashboardFirmware"] ?? "-") "
                + "color=\(state["colorDisplayFirmware"] ?? "-") centre=\(state["centreFirmware"] ?? "-")",
            "scan      replies=\(state["scanReplies"] ?? "-") timeouts=\(state["scanTimeouts"] ?? "-")",
            "",
            "--- log (\(diagnosticLog.count) lines) ---"
        ]
        lines.append(contentsOf: diagnosticLog)
        return lines.joined(separator: "\n") + "\n"
    }

    /// A deliberate, slow sweep of the whole reachable bus, for adapting the
    /// tool to this vehicle rather than for guarding a write.
    private func startAdaptationDump() {
        // The versions live in the dashboard and centre modules, so those have
        // to be included for the fingerprint to identify the build.
        dumpPurpose = .adaptation
        state["busyMessage"] = "正在读取寄存器快照（可能需要数分钟）…"
        pushState()
        startClient(record: placeholderRecord(serial: serial),
                    operation: .dumpRegisters,
                    dumpModules: [RegisterDump.dashboardModule, 0x09,
                                  RegisterDump.meterModule])
    }

    private func saveAdaptationDump(_ dump: RegisterDump) {
        previousAdaptationDump = lastAdaptationDump
        lastAdaptationDump = dump
        let name = "bfg-dump-\(dump.serial)-\(dump.timestamp).json"
        let url = Self.documentsDirectory().appendingPathComponent(name)
        do {
            try dump.json().write(to: url, options: .atomic)
            lastDumpURL = url
            state["errorMessage"] = "\(name) · \(dump.entries.count) 个地址，"
                + "\(dump.respondedCount) 个有响应 · 指纹 \(dump.fingerprint.identifier)"
        } catch {
            state["errorMessage"] = "快照写入失败：\(error.localizedDescription)"
        }
        // Only a *second* dump gives the compare button something to say. Leaving
        // this true forever both outlived a vehicle change and offered a
        // comparison whose only possible answer was "这是第一份快照".
        state["dumpReady"] = previousAdaptationDump != nil
        state["modal"] = "dump-complete"
        state["busyMessage"] = NSNull()
        pushState()
    }

    /// Compares the latest sweep against the previous one. This is the check
    /// that answers "did anything move that should not have".
    private func compareWithLastDump() {
        guard let latest = lastAdaptationDump else {
            state["errorMessage"] = "还没有寄存器快照可对比，请先导出一次。"
            state["modal"] = "dump-complete"
            pushState()
            return
        }
        guard let previous = previousAdaptationDump else {
            state["errorMessage"] = "这是第一份快照，已作为基线。"
            state["modal"] = "dump-complete"
            pushState()
            return
        }
        let changes = latest.changes(from: previous)
        if changes.isEmpty {
            state["errorMessage"] = "两份快照完全一致（\(latest.entries.count) 个地址）。"
        } else {
            let list = changes.prefix(10).map {
                String(format: "0x%02X/0x%02X %d→%d",
                       $0.module, $0.index, $0.before, $0.after)
            }.joined(separator: "；")
            state["errorMessage"] = "发现 \(changes.count) 处变化：\(list)"
        }
        state["modal"] = "dump-complete"
        pushState()
    }

    private func clearLocalData() {
        KeychainCredentialStore.shared.deleteAll()
        backupStore.clear(serial: serial)
        lastRead = nil
        pendingWrite = nil
        pendingUnverified = nil
        // The in-memory snapshots go too: keeping them would leave the compare
        // button offering a comparison against data the rider just asked to
        // forget, for the same reason the stored backups are dropped.
        lastAdaptationDump = nil
        previousAdaptationDump = nil
        state["dumpReady"] = false
        state["vehicles"] = []
        state["connected"] = false
        state["errorMessage"] = "已清除本机保存的配对凭据与备份。再次使用需要重新配对。"
        state["modal"] = "data-cleared"
        refreshBackupState(serial: serial)
        pushState()
    }

    private static func licenseText() -> String? {
        guard let url = Bundle.main.url(forResource: "license", withExtension: "txt") else {
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// Mirrors `BfgProfileCatalog` into the picker's shape. The page holds no
    /// table of its own, so the options have to come from the same source the
    /// write itself resolves against — otherwise the user could pick a capacity
    /// the write path would then reject.
    private static func capacityOptions() -> (all: [Double], byVoltage: [String: [Double]]) {
        var byVoltage: [String: [Double]] = [:]
        var all: [Double] = []
        for voltage in [48, 60, 72] {
            let code = BfgProfileCatalog.voltageCode(forVoltage: voltage)
            var options: [Double] = []
            for index in 0...0xF {
                let milliAmpHours = BfgProfileCatalog.expectedCore((index << 4) | code)
                guard milliAmpHours > 0 else { continue }
                let ampHours = Double(milliAmpHours) / 1000
                if !options.contains(ampHours) { options.append(ampHours) }
            }
            options.sort()
            byVoltage[String(voltage)] = options
            for value in options where !all.contains(value) { all.append(value) }
        }
        all.sort()
        return (all, byVoltage)
    }

    private static func documentsDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: Date())
    }

    // MARK: - Payload parsing

    private struct WriteRequest {
        let type: String
        let voltage: Int
        let capacityMah: Int
    }

    private static func parseWriteRequest(_ value: String) -> WriteRequest? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String,
              let voltage = object["voltage"] as? Int else { return nil }
        // The page sends amp-hours as a decimal; the table is in milliamp-hours.
        let capacityAh = (object["capacity"] as? Double) ?? Double(object["capacity"] as? Int ?? 0)
        return WriteRequest(type: type, voltage: voltage,
                            capacityMah: Int((capacityAh * 1000).rounded()))
    }

    private static func parseGateConfirmation(_ value: String) -> (nonce: Int, checked: Bool)? {
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let nonce = object["nonce"] as? Int else { return nil }
        return (nonce, (object["checked"] as? Bool) ?? false)
    }

    /// Wording ported from the Android dialogs, including the two-stage
    /// dashboard warning.
    private static func gateContent(pending: PendingWrite, seconds: Int,
                                    nonce: Int) -> [String: Any] {
        var content: [String: Any] = ["nonce": nonce, "seconds": seconds]
        if pending.isDashboard {
            if pending.stage == 0 {
                content["title"] = "仪表盘永久写入 · 高风险"
                content["intro"] = "本次将写入仪表盘的持久配置，目标为 \(pending.voltage)V。"
                    + "已读取到指定的四项固件版本，但版本匹配不代表这次写入安全。"
                    + "请停车并核对车辆、电池和备份后再决定。"
                content["critical"] = "已知在老车型上，写入仪表盘配置后曾发生计量模块损坏。"
                    + "不同车辆的寄存器位置和含义可能不同，无法保证写入结果。"
                    + "写入可能使车辆无法启动、仪表显示异常或计量模块损坏。"
                    + "即使备份了原参数，也可能无法恢复。"
                    + "更换原装计量模块后，仪表盘仍可能再次下发配置，使新模块再次受损。"
                content["acknowledgement"] = "我已阅读并理解上述已知损坏案例和不可逆风险"
                content["action"] = "继续查看最后提醒"
            } else {
                content["title"] = "再次劝告：仍可能造成损坏"
                content["intro"] = "若不确定车辆配置，请取消并保持只读。"
                    + "备份和回读都不能保证断电后的安全性或恢复成功。"
                content["critical"] = "请勿把写入当作维修或官方校准。"
                    + "本人确认仍要继续，并愿意承担因本人选择错误参数或操作不当造成的损失；"
                    + "本确认不排除依法享有的权利。"
                content["acknowledgement"] = "我仍决定写入，并理解上述风险"
                content["action"] = "我执意写入"
            }
        } else {
            let verb = pending.restoreLabel == nil ? "写入" : "恢复"
            content["title"] = pending.restoreLabel == nil ? "临时写入计量模块"
                                                           : "确认恢复\(pending.restoreLabel!)"
            content["intro"] = "目标 \(pending.voltage)V · "
                + BackupStore.Backup.formatCapacity(pending.capacityMah)
            content["critical"] = verb == "写入"
                ? "断电后可能恢复原参数。写入可能失败或造成数据显示异常，备份不保证恢复。"
                // A restore is the same write to the same place; targeting an
                // older value does not make it safer, so the wording carries the
                // same weight as the dashboard path rather than less.
                : "恢复同样是把参数写进车辆，不会因为目标是较早的参数而更安全。"
                  + "写入可能失败，或造成车辆无法启动、仪表显示异常、计量模块损坏；"
                  + "即使已备份原参数，也可能无法恢复。"
            content["acknowledgement"] = "我已核对车辆与目标参数，并了解上述风险"
            content["action"] = "继续写入"
        }
        return content
    }

    /// Monotonic milliseconds, matching Android's `SystemClock.elapsedRealtime`
    /// so a wall-clock adjustment cannot shorten the wait.
    private static func uptimeMillis() -> Int64 {
        Int64((ProcessInfo.processInfo.systemUptime * 1000).rounded())
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        // The picker has to be usable before the first read, so the options are
        // seeded from the profile table rather than waiting for a connection.
        let options = Self.capacityOptions()
        state["availableCapacities"] = options.all
        state["capacityByVoltage"] = options.byVoltage
        pushState()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Matches the Android client, which refused every in-page navigation.
        decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
    }
}

// MARK: - BLE listener

extension PrototypeCoordinator: BfgBleClient.Listener {
    /// Every listener callback arrives on the client's own BLE queue, but `state`
    /// and WKWebView are main-thread-only. Delivering them in place meant the
    /// page could be updated — and `state` mutated — from a background queue,
    /// which is how a status line or a failure notice goes missing and leaves
    /// the page showing a fallback caption instead. Each callback hops first.
    func bleClient(didUpdateStatus status: String) { onMain { self.handleStatus(status) } }

    func bleClient(didLog line: String) { onMain { self.handleLog(line) } }

    func bleClient(didFinish result: BfgBleClient.Result) { onMain { self.handleFinish(result) } }

    func bleClient(didFailWith message: String) { onMain { self.handleFailure(message) } }

    /// Runs `work` on the main thread, without a second hop when already there.
    private func onMain(_ work: @escaping () -> Void) {
        if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) }
    }

    /// Keeps a copy of the trail on disk while a run is in flight.
    ///
    /// The log lives in memory and only the settings screen can export it, so a
    /// run that stalls somewhere it cannot be left takes its own evidence with
    /// it: the rider is stuck on a spinner, cannot reach settings, and a force
    /// quit erases everything. Writing it out as the run proceeds means the file
    /// in Documents is always the story so far — reachable from the Files app
    /// even while the UI is wedged. Throttled, because the transport logs two
    /// lines per frame.
    private func persistDiagnosticIfActive() {
        guard !diagnosticLog.isEmpty else { return }
        let now = Date()
        // Six seconds, not two: the buffer now holds twenty thousand lines, and
        // re-joining a megabyte of text every couple of seconds while a sweep is
        // running is work the main thread cannot spare.
        guard now.timeIntervalSince(lastPersist) > 6 else { return }
        lastPersist = now
        let text = diagnosticReport()
        let url = Self.documentsDirectory().appendingPathComponent("bfg-diagnostic.txt")
        DispatchQueue.global(qos: .utility).async {
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func handleStatus(_ status: String) {
        state["busyMessage"] = status
        // Status lines are the only record of *how far* a run got. Without them
        // an export shows the radio's chatter but not whether the client ever
        // reached "已发现 …；正在连接…", which is the first thing worth knowing.
        handleLog("[STATUS] " + status)
        pushState()
    }

    private func handleLog(_ line: String) {
        // Surfaced through the page's log area when present.
        state["logLine"] = line
        // Stamp every stored line with seconds since the first one. The real
        // vehicle's one confirmed write was accepted, read back at the new
        // value, and then silently reverted — and the export could not say
        // *when*, so the revert could not be told apart from a slow write. A
        // timestamp on each line is what makes "reverted at T+4.1s" a fact
        // instead of a guess.
        if !logClockStarted { logClockStarted = true; logClock = DispatchTime.now() }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- logClock.uptimeNanoseconds) / 1_000_000_000
        let stamped = String(format: "T+%8.2fs  %@", elapsed, line)
        // Bounded so a long session cannot grow without limit; the tail is the
        // part that matters when something went wrong. The bound is generous
        // because the BLE transport logs one line per write and per received
        // frame: those lines are the only evidence a real vehicle leaves behind,
        // and a truncated log is the same as no log when the break is early.
        diagnosticLog.append(stamped)
        // 4000 was not enough. A single pre-write sweep emits one line per frame —
        // well over a thousand — so a failed write followed by "export a snapshot"
        // pushed the failure itself out of the buffer. That is exactly what
        // happened on the real vehicle: the log arrived with no write frame and no
        // read-back sequence in it, and the question it was sent to answer could
        // not be answered. The bound exists only to stop unbounded growth; the
        // export is written to a file, so size costs nothing that matters.
        if diagnosticLog.count > 20000 {
            diagnosticLog.removeFirst(diagnosticLog.count - 20000)
        }
        persistDiagnosticIfActive()
    }

    private func handleFinish(_ result: BfgBleClient.Result) {
        state["pairScanning"] = false
        stopScanCountdown()

        if activeOperation == .discoverVehicles {
            state["vehicles"] = result.discoveredVehicles.map {
                ["sn": $0.serial, "detail": "点击选择这台车"]
            }
            state["busyMessage"] = NSNull()
            pushState()
            goTo("pair-list")
            return
        }

        // Post-write re-check: a plain read whose result decides whether the
        // vehicle has settled or needs reading again.
        if postWriteCheck != nil, pendingWrite == nil, !result.writeCommandSent {
            handlePostWriteCheck(result)
            return
        }

        if let purpose = dumpPurpose, let dump = result.registerDump {
            dumpPurpose = nil
            if purpose == .adaptation {
                saveAdaptationDump(dump)
            } else {
                handleDump(dump, purpose: purpose)
            }
            return
        }

        // A retried write: the read is only there to put the confirmation back
        // in front of the user with current values.
        if let retry = pendingRetryRequest, pendingWrite == nil, !result.writeCommandSent {
            pendingRetryRequest = nil
            lastRead = result
            if let request = Self.parseWriteRequest(retry) {
                state["writeType"] = request.type
                state["voltage"] = request.voltage
                state["capacity"] = Double(request.capacityMah) / 1000
            }
            state["result"] = NSNull()
            state["errorMessage"] = ""
            state["busyMessage"] = NSNull()
            state["screen"] = "write"
            state["modal"] = "write-confirm"
            pushState()
            return
        }

        lastRead = result
        state["connected"] = true
        state["vehicleSn"] = result.serial
        // The page prints these verbatim, so they are formatted the same way the
        // Android client formatted them rather than passed through as raw values.
        state["soc"] = DisplayFormatter.soc(result.displaySoc)
        state["batteryVoltage"] = DisplayFormatter.batteryVoltage(result.disVrlaVoltage)
        state["meterVoltage"] = DisplayFormatter.voltageName(result.profileRaw)
        state["dashboardVoltage"] = DisplayFormatter.nominalVoltage(result.dashboardNominalVoltage)
        // After a write the meaningful figures are the post-write ones; showing
        // the pre-write values would make a successful write look like a no-op.
        let wrote = result.writeCommandSent
        let meterCapacity = wrote ? result.displayAfterCapacity : result.displayBeforeCapacity
        // On a firmware the tool could not resolve, the figure still comes from
        // the vehicle — only its meaning is unconfirmed. Say so rather than
        // presenting it as a verified reading.
        state["meterCapacity"] = result.capacityIsUnverified
            ? DisplayFormatter.capacityShort(meterCapacity) + "（未验证）"
            : DisplayFormatter.capacityShort(meterCapacity)
        state["dashboardCapacity"] = DisplayFormatter.capacityShort(result.disRemainingCapacity)
        state["remainingCapacity"] = DisplayFormatter.capacityShort(result.disRemainingCapacity)
        state["meterFirmware"] = DisplayFormatter.firmwareVersion(result.meterFirmware)
        state["dashboardFirmware"] = DisplayFormatter.firmwareVersion(result.dashboardFirmware)
        state["colorDisplayFirmware"] = DisplayFormatter.firmwareVersion(result.colorDisplayVersion)
        state["centreFirmware"] = DisplayFormatter.firmwareVersion(result.centreControllerVersion)

        // A read-only serial is refused by the client as well; mirroring it here
        // keeps the page from offering a write that would only fail later.
        let readOnly = WriteAccessPolicy.isReadOnlySerial(result.serial)
        state["readOnlyVehicle"] = readOnly
        state["writeSupported"] = result.writeSupported && !readOnly
        state["dashboardWriteSupported"] = !readOnly
            && DashboardWritePolicy.allows(dashboard: result.dashboardFirmware,
                                           colorDisplay: result.colorDisplayVersion,
                                           centre: result.centreControllerVersion,
                                           meter: result.meterFirmware)
            && DisVoltageConfig.nominalVoltage(result.disConfigRaw) > 0

        // The capacity picker has no table of its own on the page; the options
        // come from the same profile table the write resolves against.
        let options = Self.capacityOptions()
        state["availableCapacities"] = options.all
        state["capacityByVoltage"] = options.byVoltage
        let shownProfile = wrote && result.afterProfile >= 0 ? result.afterProfile : result.profileRaw
        if shownProfile >= 0 {
            // These are the *vehicle's* values, not the rider's choice — they must
            // not travel under the same keys. They used to be pushed as
            // voltage/capacity, which is exactly where the write page keeps the
            // selection, so every status push after the confirmation overwrote the
            // choice with the vehicle's current value. The frame had already been
            // built from the real choice, so the write was correct while the screen
            // said otherwise: a 46Ah write displayed as 26Ah on the real vehicle and
            // looked like the tool had written the wrong capacity.
            state["vehicleVoltage"] = BfgProfileCatalog.nominalVoltage(shownProfile)
            state["vehicleCapacity"] = Double(BfgProfileCatalog.expectedCore(shownProfile)) / 1000
        }

        state["scanReplies"] = result.registerScanReplies
        state["scanTimeouts"] = result.registerScanTimeouts
        state["busyMessage"] = NSNull()

        // The permanent backups have to exist before a write can even be
        // considered: requestWrite refuses without a first-parameter backup, and
        // that backup was only ever created inside the pre-write snapshot — which
        // happens *after* that refusal. On a vehicle that had never been written
        // the check could therefore never pass and the entire write path was
        // unreachable, which is exactly how it behaved on the real vehicle.
        //
        // A plain read is the right moment to establish them: it is the only
        // point where the original values are read with no write in flight. Both
        // calls fill an empty slot only and never overwrite, so a later read can
        // never turn a genuine original into a post-write value — and the
        // dashboard backup has to exist before any dashboard write, or that
        // write would have no way back.
        if result.profileRaw >= 0, result.displayBeforeCapacity > 0 {
            backupStore.saveFirstBackupIfAbsent(serial: result.serial,
                                                profile: result.profileRaw,
                                                capacity: result.displayBeforeCapacity)
        }
        backupStore.saveDisConfigBackupIfAbsent(serial: result.serial, raw: result.disConfigRaw)
        refreshBackupState(serial: result.serial)

        // "Last confirmed" is deliberately NOT recorded here. A write's own
        // read-back proves the value landed, but the delayed re-check and the
        // post-write sweep can still contradict it; recording now would leave the
        // settings screen advertising a target that later turned out wrong.

        // A completed write ends the flow; a read that ran only to produce the
        // pre-write snapshot hands over to the risk gate instead.
        if pendingWrite != nil, !result.writeCommandSent {
            guard let pending = pendingWrite else { return }

            // The dashboard config the user confirmed against must still be the
            // one on the vehicle; anything else means the basis of the choice
            // has moved, so nothing is sent.
            if pending.isDashboard, pending.expectedDisConfigRaw >= 0,
               result.disConfigRaw != pending.expectedDisConfigRaw {
                writeFailure("写入前发现仪表配置已变化，本次没有发送写入指令。"
                    + "请重新核对当前参数后再试。")
                return
            }

            // Nothing may be written unless the values that would be needed to
            // get back are actually present.
            let backupReady = pending.isDashboard
                ? (result.disConfigRaw >= 0
                    && DisVoltageConfig.nominalVoltage(result.disConfigRaw) > 0
                    && DashboardWritePolicy.allows(dashboard: result.dashboardFirmware,
                                                   colorDisplay: result.colorDisplayVersion,
                                                   centre: result.centreControllerVersion,
                                                   meter: result.meterFirmware))
                : (result.profileRaw >= 0
                    && result.displayBeforeCapacity > 0
                    && result.writeSupported)
            guard backupReady else {
                writeFailure("写入前未能完整读取并保存原参数，本次没有发送写入指令。"
                    + "请保持车辆开机后重试。")
                return
            }

            guard backupStore.savePrewriteSnapshot(serial: result.serial,
                                                   profile: result.profileRaw,
                                                   capacity: result.displayBeforeCapacity,
                                                   disConfigRaw: result.disConfigRaw) else {
                writeFailure("写入前未能完整读取并保存原参数，本次没有发送写入指令。"
                    + "请保持车辆开机后重试。")
                return
            }
            refreshBackupState(serial: result.serial)
            pushState()
            beginPreWriteDump(pending)
            return
        }

        pendingWrite = nil
        pendingUnverified = nil
        pushState()

        guard result.writeCommandSent else {
            // A plain read ends on the page that shows what was read *and* carries
            // the write entry. It used to return home, which has neither: the
            // rider saw a successful connection and then nothing, and the write
            // flow was unreachable — reported, correctly, as "there is no option".
            goTo("review")
            return
        }
        guard result.profileReadbackVerified || result.disConfigReadbackVerified else {
            goTo("post-write-check")
            return
        }

        // The write's own read-back confirmed the value; the original still
        // waits and reads again, because a vehicle can lag on the remaining
        // capacity even after the profile has changed.
        lastPostWriteTarget = (result.afterProfile, result.disConfigAfterRaw,
                               activeOperation == .writeDisVoltage)
        postWriteCheck = PostWriteCheck(expectedProfile: result.afterProfile,
                                        expectedDisConfig: result.disConfigAfterRaw)
        goTo("post-write-check")
        schedulePostWriteRead(after: 5)
    }

    /// Decides whether the delayed read settled the write, needs another, or
    /// contradicts it. Reads only — a failed check never retries the write.
    private func handlePostWriteCheck(_ result: BfgBleClient.Result) {
        guard var check = postWriteCheck else { return }
        check.attempts += 1
        postWriteCheck = check

        lastRead = result
        state["vehicleSn"] = result.serial
        state["busyMessage"] = NSNull()
        refreshBackupState(serial: result.serial)

        let matches = PostWriteCheckPolicy.targetMatches(
            actualProfile: result.profileRaw,
            expectedProfile: check.expectedProfile,
            actualDisRaw: result.disConfigRaw,
            expectedDisRaw: check.expectedDisConfig)
        let pending = PostWriteCheckPolicy.capacityPending(
            soc: result.displaySoc,
            remainingCapacityRaw: result.disRemainingCapacity)

        if PostWriteCheckPolicy.shouldRetry(readsCompleted: check.attempts,
                                            targetMatches: matches,
                                            capacityPending: pending) {
            goTo("post-write-check")
            schedulePostWriteRead(after: 3)
            return
        }

        postWriteCheck = nil
        guard matches else {
            writeFailure("二次核对后，车辆返回的档位仍与目标不一致。"
                + "本次写入未确认成功；请核对当前参数后再尝试。")
            return
        }
        // Final check: sweep the module again and confirm that the only thing
        // that moved is the address that was written. Anything else changing is
        // the clearest early sign that a write reached further than intended.
        if preWriteDump != nil {
            dumpPurpose = .postWrite
            state["busyMessage"] = "正在比对写入后的寄存器快照…"
            pushState()
            let module = (lastPostWriteTarget?.isDashboard ?? false)
                ? RegisterDump.dashboardModule : RegisterDump.meterModule
            startClient(record: placeholderRecord(serial: serial),
                        operation: .dumpRegisters, dumpModules: [module])
            return
        }

        // With no snapshot to sweep, the read-back is the only evidence there is,
        // so that alone is what gets recorded as confirmed.
        if check.expectedProfile >= 0 {
            backupStore.saveLastConfirmed(serial: result.serial,
                                          profile: check.expectedProfile)
        }
        refreshBackupState(serial: result.serial)
        showWriteSuccess(capacityPending: pending)
    }

    private func showWriteSuccess(capacityPending pending: Bool) {
        state["result"] = "success"
        state["modal"] = "write-success"
        state["errorMessage"] = pending
            ? "目标档位已回读确认。剩余容量暂未更新，请稍后重新读取。"
            : "二次核对完成，车辆已返回目标档位和最新剩余容量。"
        state["busyMessage"] = NSNull()
        pushState()
    }

    private func schedulePostWriteRead(after seconds: Double) {
        postWriteTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.postWriteCheck != nil else { return }
            self.startClient(record: self.placeholderRecord(serial: self.serial),
                             operation: .compareRead)
        }
        postWriteTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    private func handleFailure(_ message: String) {
        // Read before the teardown below: which step of a multi-step flow died
        // decides where the rider has to land to see it.
        let failedPostWriteCheck = postWriteCheck != nil
        let wasWriting = pendingWrite != nil

        state["errorMessage"] = message
        state["busyMessage"] = NSNull()
        state["pairScanning"] = false
        stopScanCountdown()
        pendingWrite = nil
        pendingUnverified = nil
        gate = nil
        // A parked post-write check must not outlive the attempt: a stale one
        // would make the next plain read look like a verification pass.
        postWriteCheck = nil
        postWriteTimer?.cancel()
        postWriteTimer = nil

        // Leaving the progress screen is the point of this handler. A progress
        // screen renders a spinner and a fallback caption and nothing else, so a
        // failure that only writes `errorMessage` looks like an operation still
        // running — the rider sees "正在连接车辆并读取寄存器" forever and the
        // reason it stopped is never displayed anywhere.
        if wasWriting {
            writeFailure(message)
            return
        }
        if failedPostWriteCheck {
            state["screen"] = "post-write-check"
            state["modal"] = "verification-incomplete"
            pushState()
            return
        }
        if message == BfgBleClient.bluetoothOffMessage {
            state["screen"] = "home"
            state["modal"] = "bluetooth-off"
            pushState()
            return
        }
        switch activeOperation {
        case .registerScan:
            // The scan result screen prints the message verbatim and offers the
            // log export, which is what a failed sweep needs.
            state["screen"] = "scan-result"
            state["modal"] = NSNull()
        case .dumpRegisters:
            state["screen"] = "settings"
            state["modal"] = "dump-complete"
        case .pairAndRead:
            state["screen"] = "pair-ready"
            state["modal"] = "operation-failed"
        case .readOnly, .compareRead, .discoverVehicles, .writeProfile, .writeDisVoltage:
            state["screen"] = "home"
            state["modal"] = "operation-failed"
        }
        pushState()
    }

    private func refreshBackupState(serial: String) {
        let first = backupStore.firstBackup(serial: serial)
        let recent = backupStore.prewriteBackup(serial: serial)
        state["firstBackupValid"] = first.valid
        state["recentBackupValid"] = recent.valid
        state["backupAlternativesDiffer"] = backupStore.alternativesDiffer(serial: serial)
        state["firstBackup"] = first.description
        state["recentBackup"] = recent.description
        let disBackup = backupStore.disConfigBackup(serial: serial)
        state["disBackupValid"] = DisVoltageConfig.nominalVoltage(disBackup) >= 0
        state["disBackup"] = DisVoltageConfig.nominalVoltage(disBackup) >= 0
            ? "\(DisVoltageConfig.nominalVoltage(disBackup))V · 0x" + String(disBackup, radix: 16).uppercased()
            : "未保存"
        state["readOnlyVehicle"] = WriteAccessPolicy.isReadOnlySerial(serial)
        let confirmed = backupStore.lastConfirmedProfile(serial: serial)
        state["lastConfirmedTarget"] = confirmed < 0
            ? "尚无已确认的写入"
            : "\(BfgProfileCatalog.nominalVoltage(confirmed))V · "
                + BackupStore.Backup.formatCapacity(BfgProfileCatalog.expectedCore(confirmed))
    }
}
