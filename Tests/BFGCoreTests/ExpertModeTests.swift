import XCTest
@testable import BFGCore

/// Expert mode releases *policy* limits and nothing else.
///
/// The rails that actually prevent a brick — the two-pass pre-write snapshot,
/// the check that it was saved, the single-byte write to one fixed address, the
/// read-back and the two rollback paths — are structural, not policy, and are
/// not reachable from this switch. These tests pin the release surface and the
/// safety surface separately so a later change cannot quietly widen the first.
final class ExpertModeTests: XCTestCase {

    override func setUp() {
        super.setUp()
        WriteAccessPolicy.expertMode = false
        WriteAccessPolicy.allowsReadOnlySerials = false
    }

    override func tearDown() {
        WriteAccessPolicy.expertMode = false
        WriteAccessPolicy.allowsReadOnlySerials = false
        super.tearDown()
    }

    // MARK: - Defaults: every limit is on

    func testPolicyLimitsAreOnByDefault() {
        XCTAssertTrue(WriteAccessPolicy.isReadOnlySerial("N1234567890123"))
        XCTAssertFalse(WriteAccessPolicy.allowsUnverifiedCombination())
        XCTAssertFalse(WriteAccessPolicy.allowsOffTableCapacity())
        XCTAssertFalse(WriteAccessPolicy.allowsPartialBackup())
    }

    /// The case that prompted the switch: a 3U-prefixed vehicle is refused, but
    /// not because of its prefix — the prefix rule only knows about N. What
    /// stopped it was the unvalidated-combination check, which is why releasing
    /// only the prefix rule would have changed nothing for that vehicle.
    func testThreeUPrefixIsNotWhatBlocksIt() {
        XCTAssertFalse(WriteAccessPolicy.isReadOnlySerial("3U1234567890123"))
        XCTAssertFalse(WriteAccessPolicy.allowsUnverifiedCombination())
    }

    func testMeterWarningCoversUnknownVersionsByDefault() {
        XCTAssertFalse(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0286))
        XCTAssertFalse(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0429))
        XCTAssertTrue(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0426))
    }

    func testDefaultsMatchTheOriginalGateAndWatch() {
        XCTAssertEqual(WriteAccessPolicy.riskGateSeconds(isDashboard: true),
                       TimedRiskGate.dashboardSeconds)
        XCTAssertEqual(WriteAccessPolicy.riskGateSeconds(isDashboard: false),
                       TimedRiskGate.meterSeconds)
        XCTAssertEqual(WriteAccessPolicy.watchSeconds(), 30)
    }

    // MARK: - Expert mode: the policy limits are released

    func testExpertModeReleasesEveryPolicyLimit() {
        WriteAccessPolicy.expertMode = true
        XCTAssertFalse(WriteAccessPolicy.isReadOnlySerial("N1234567890123"))
        XCTAssertTrue(WriteAccessPolicy.allowsUnverifiedCombination())
        XCTAssertTrue(WriteAccessPolicy.allowsOffTableCapacity())
        XCTAssertTrue(WriteAccessPolicy.allowsPartialBackup())
        XCTAssertFalse(WriteAccessPolicy.needsMeterCompatibilityWarning(0x0426))
    }

    /// A released limit must cost the rider *more* waiting time, not less: the
    /// gate is what makes a mis-tap reversible.
    func testExpertModeWaitsLongerNotShorter() {
        WriteAccessPolicy.expertMode = true
        XCTAssertGreaterThan(WriteAccessPolicy.riskGateSeconds(isDashboard: true),
                             TimedRiskGate.dashboardSeconds)
        XCTAssertGreaterThan(WriteAccessPolicy.riskGateSeconds(isDashboard: false),
                             TimedRiskGate.meterSeconds)
        XCTAssertGreaterThan(WriteAccessPolicy.watchSeconds(), 30)
    }

    /// Session scope is a safety property, not a convenience: nothing may
    /// persist the switch, or the next rider of the phone would inherit it.
    func testExpertModeIsNeverPersisted() {
        WriteAccessPolicy.expertMode = true
        XCTAssertNil(UserDefaults.standard.object(forKey: "expertMode"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "WriteAccessPolicy.expertMode"))
        XCTAssertNil(UserDefaults.standard.object(forKey: "expert_mode"))
    }

    /// The pre-existing single-serial waiver must stay independent, so releasing
    /// one vehicle never silently releases the unvalidated-combination rule too.
    func testLegacySerialWaiverStaysIndependent() {
        WriteAccessPolicy.allowsReadOnlySerials = true
        XCTAssertFalse(WriteAccessPolicy.isReadOnlySerial("N1234567890123"))
        XCTAssertFalse(WriteAccessPolicy.allowsUnverifiedCombination())
        XCTAssertFalse(WriteAccessPolicy.allowsPartialBackup())
    }
}
