# Batteries Included Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a directly distributed macOS 14+ menu-bar app that shows live battery levels for currently connected Bluetooth devices, including separate component levels when available.

**Architecture:** A SwiftUI `MenuBarExtra` observes a main-actor `DeviceMonitor`. Independent Core Bluetooth and macOS system collectors emit observations into a pure `BatteryNormalizer`, which produces immutable menu presentation state and isolates compatibility-sensitive discovery code from the UI.

**Tech Stack:** Swift 5.9, Swift Package Manager, SwiftUI, Observation, CoreBluetooth, IOBluetooth, IOKit, OSLog, XCTest, `xcodebuild`, and a shell-based `.app` bundling script.

**Spec:** `docs/superpowers/specs/2026-08-22-batteries-included-design.md`

## Global Constraints

- Target macOS 14 Sonoma or newer.
- Ship as a menu-bar-only app with no Dock icon.
- List only devices macOS currently reports as connected.
- Refresh every 30 seconds and immediately when the menu opens or the user selects `Refresh`.
- Never connect to a peripheral solely to obtain a routine battery reading.
- Keep unsupported connected devices visible as `Battery unavailable`.
- Show multi-component values in left, right, case, then alphabetical custom-component order.
- Reject percentages outside the inclusive 0–100 range.
- Treat readings older than 60 seconds as stale.
- Prefer a direct standard BLE Battery Service reading when competing timestamps differ by no more than one second.
- Do not add notifications, history, disconnected-device persistence, settings, renaming, or support for macOS 13 and earlier.
- Add no third-party runtime dependencies.

---

## Planned File Structure

```text
Package.swift                                  Swift package, targets, platform, linked frameworks
Sources/BatteriesIncluded/App/BatteriesIncludedApp.swift
Sources/BatteriesIncluded/App/AppCommands.swift
Sources/BatteriesIncluded/Model/BatteryModels.swift
Sources/BatteriesIncluded/Model/BatteryNormalizer.swift
Sources/BatteriesIncluded/Monitoring/BatteryCollecting.swift
Sources/BatteriesIncluded/Monitoring/DeviceMonitor.swift
Sources/BatteriesIncluded/Collectors/CoreBluetoothCollector.swift
Sources/BatteriesIncluded/Collectors/SystemBluetoothCollector.swift
Sources/BatteriesIncluded/UI/BatteryMenuView.swift
Sources/BatteriesIncluded/UI/DeviceRowView.swift
Sources/BatteriesIncluded/UI/DeviceIcon.swift
Sources/BatteriesIncluded/Support/SettingsOpening.swift
Sources/BatteriesIncluded/Support/SystemLogging.swift
Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift
Tests/BatteriesIncludedTests/DeviceMonitorTests.swift
Tests/BatteriesIncludedTests/MenuPresentationTests.swift
scripts/build-app.sh                           Build and assemble Batteries Included.app
Resources/Info.plist                           LSUIElement, identifier, Bluetooth usage copy
```

The model and normalizer are framework-free value logic. Collectors own source-specific APIs. `DeviceMonitor` owns refresh orchestration but not discovery details. Views consume presentation models and contain no Bluetooth logic.

---

### Task 1: Package Scaffold and Domain Model

**Files:**
- Create: `Package.swift`
- Create: `Sources/BatteriesIncluded/Model/BatteryModels.swift`
- Create: `Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift`

**Interfaces:**
- Produces: `BatteryComponent`, `BatterySource`, `DeviceCategory`, `BatteryObservation`, `DeviceBattery`, `BluetoothAvailability`, and `MenuState`.
- Consumes: Nothing; this is the base task.

- [ ] **Step 1: Write the initial model test**

Create `Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift`:

```swift
import XCTest
@testable import BatteriesIncluded

final class BatteryNormalizerTests: XCTestCase {
    func testKnownComponentsHaveDeterministicOrder() {
        let values: [BatteryComponent] = [.custom("Stem"), .case, .right, .left, .whole]
        XCTAssertEqual(values.sorted(), [.whole, .left, .right, .case, .custom("Stem")])
    }
}
```

- [ ] **Step 2: Run the test to verify the package is missing**

Run: `swift test --filter BatteryNormalizerTests/testKnownComponentsHaveDeterministicOrder`

Expected: FAIL because `Package.swift` and the referenced types do not exist.

- [ ] **Step 3: Create the package and minimal domain types**

Create `Package.swift` with one executable target and one test target:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BatteriesIncluded",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "BatteriesIncluded", targets: ["BatteriesIncluded"])],
    targets: [
        .executableTarget(
            name: "BatteriesIncluded",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("IOBluetooth"),
                .linkedFramework("IOKit")
            ]
        ),
        .testTarget(name: "BatteriesIncludedTests", dependencies: ["BatteriesIncluded"])
    ]
)
```

Create `BatteryModels.swift`. Define:

```swift
import Foundation

enum BatteryComponent: Hashable, Sendable, Comparable {
    case whole, left, right, `case`, custom(String)

    private var sortKey: (Int, String) {
        switch self {
        case .whole: (0, "")
        case .left: (1, "")
        case .right: (2, "")
        case .case: (3, "")
        case .custom(let label): (4, label.localizedLowercase)
        }
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.sortKey < rhs.sortKey
    }
}

enum BatterySource: Int, Sendable, Equatable { case system = 0, coreBluetooth = 1 }
enum DeviceCategory: Sendable, Equatable { case headphones, mouse, keyboard, trackpad, gameController, other }
enum BluetoothAvailability: Sendable, Equatable { case available, poweredOff, permissionDenied, unavailable }

struct BatteryObservation: Sendable, Equatable {
    let sourceID: String
    let stableID: String?
    let name: String
    let isConnected: Bool
    let category: DeviceCategory?
    let component: BatteryComponent
    let percentage: Int?
    let source: BatterySource
    let observedAt: Date
}

struct DeviceBattery: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let category: DeviceCategory
    let levels: [(component: BatteryComponent, percentage: Int)]

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.category == rhs.category &&
        lhs.levels.map { "\($0.component):\($0.percentage)" } == rhs.levels.map { "\($0.component):\($0.percentage)" }
    }
}

enum MenuState: Sendable, Equatable {
    case loading
    case devices([DeviceBattery])
    case noDevices
    case bluetoothOff
    case permissionDenied
    case unavailable
}
```

- [ ] **Step 4: Run the model test**

Run: `swift test --filter BatteryNormalizerTests/testKnownComponentsHaveDeterministicOrder`

Expected: PASS.

- [ ] **Step 5: Commit the scaffold and model**

```bash
git add Package.swift Sources/BatteriesIncluded/Model/BatteryModels.swift Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift
git commit -m "feat: add battery domain model"
```

---

### Task 2: Observation Normalization

**Files:**
- Create: `Sources/BatteriesIncluded/Model/BatteryNormalizer.swift`
- Modify: `Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift`

**Interfaces:**
- Consumes: `BatteryObservation`, `DeviceBattery`, `BatteryComponent`, and `BatterySource` from Task 1.
- Produces: `BatteryNormalizer.normalize(_:now:) -> [DeviceBattery]`.

- [ ] **Step 1: Add failing normalization tests**

Append tests using a local helper that constructs observations. Cover all rules with explicit assertions:

```swift
private func observation(
    id: String = "device-1", stableID: String? = "stable-1",
    name: String = "AirPods Pro", connected: Bool = true,
    component: BatteryComponent = .whole, percentage: Int? = 50,
    source: BatterySource = .system, age: TimeInterval = 0
) -> BatteryObservation {
    .init(sourceID: id, stableID: stableID, name: name, isConnected: connected,
          category: .headphones, component: component, percentage: percentage,
          source: source, observedAt: Date(timeIntervalSince1970: 1_000 - age))
}

func testRejectsInvalidAndStalePercentagesButKeepsDevice() {
    let observations = [
        observation(component: .left, percentage: -1),
        observation(component: .right, percentage: 101),
        observation(component: .case, percentage: 70, age: 61)
    ]
    let result = BatteryNormalizer().normalize(
        observations, now: Date(timeIntervalSince1970: 1_000)
    )
    XCTAssertEqual(result.count, 1)
    XCTAssertTrue(result[0].levels.isEmpty)
}

func testMergesMatchingStableIDsAndOrdersComponents() {
    let result = BatteryNormalizer().normalize([
        observation(id: "system", component: .case, percentage: 60),
        observation(id: "ble", component: .right, percentage: 70, source: .coreBluetooth),
        observation(id: "ble", component: .left, percentage: 80, source: .coreBluetooth)
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result[0].levels.map(\.component), [.left, .right, .case])
}

func testPrefersBLEReadingWithinOneSecond() {
    let result = BatteryNormalizer().normalize([
        observation(percentage: 90, source: .system),
        observation(percentage: 80, source: .coreBluetooth, age: 1)
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(result[0].levels[0].percentage, 80)
}

func testDoesNotMergeAmbiguousDevicesWithoutStableID() {
    let result = BatteryNormalizer().normalize([
        observation(id: "one", stableID: nil, name: "Headphones"),
        observation(id: "two", stableID: nil, name: "Headphones")
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(result.count, 2)
}

func testDropsDisconnectedObservations() {
    let result = BatteryNormalizer().normalize([
        observation(connected: false)
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertTrue(result.isEmpty)
}
```

- [ ] **Step 2: Run the normalizer tests to verify failure**

Run: `swift test --filter BatteryNormalizerTests`

Expected: FAIL because `BatteryNormalizer` is undefined.

- [ ] **Step 3: Implement the pure normalizer**

Create `BatteryNormalizer.swift` with `struct BatteryNormalizer`. Filter disconnected observations, group by `stableID` when present and otherwise by the source-qualified `sourceID`, retain every connected group even if it has no valid levels, and choose one observation per component. A valid reading is `0...100` and no more than 60 seconds old. For competing readings, choose the newer unless timestamps are within one second, in which case choose the larger `BatterySource.rawValue`. Sort component tuples using `BatteryComponent.<` and sort devices case-insensitively by name with `id` as the tie-breaker.

Use these exact entry points:

```swift
struct BatteryNormalizer: Sendable {
    func normalize(_ observations: [BatteryObservation], now: Date = .now) -> [DeviceBattery]
}
```

Derive the normalized ID as `stable:<stableID>` when available, or `<source.rawValue>:<sourceID>` otherwise. Select the first nonempty name and first non-nil category in newest-observation order; fall back to `Unknown Device` and `.other`.

- [ ] **Step 4: Run all normalizer tests**

Run: `swift test --filter BatteryNormalizerTests`

Expected: PASS for ordering, validation, staleness, precedence, identity, and connection tests.

- [ ] **Step 5: Commit the normalizer**

```bash
git add Sources/BatteriesIncluded/Model/BatteryNormalizer.swift Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift
git commit -m "feat: normalize battery observations"
```

---

### Task 3: Collector Protocol and System Collector

**Files:**
- Create: `Sources/BatteriesIncluded/Monitoring/BatteryCollecting.swift`
- Create: `Sources/BatteriesIncluded/Collectors/SystemBluetoothCollector.swift`
- Create: `Tests/BatteriesIncludedTests/SystemBluetoothCollectorTests.swift`

**Interfaces:**
- Consumes: `BatteryObservation` and `BluetoothAvailability` from Task 1.
- Produces: `BatteryCollecting.collect() async -> CollectorSnapshot`, `CollectorSnapshot`, `SystemDeviceReading`, and `SystemBluetoothCollector`.

- [ ] **Step 1: Write failing system-mapping tests**

Create tests for a pure mapping seam rather than macOS hardware:

```swift
import XCTest
@testable import BatteriesIncluded

final class SystemBluetoothCollectorTests: XCTestCase {
    func testMapsConnectedMultiComponentDevice() {
        let reading = SystemDeviceReading(
            address: "AA-BB", name: "Buds", isConnected: true,
            category: .headphones,
            percentages: [.left: 81, .right: 79, .case: 55]
        )
        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)
        XCTAssertEqual(observations.map(\.component), [.left, .right, .case])
        XCTAssertTrue(observations.allSatisfy(\.isConnected))
    }

    func testMapsUnsupportedConnectedDeviceWithNilLevel() {
        let reading = SystemDeviceReading(
            address: "CC-DD", name: "Speaker", isConnected: true,
            category: .other, percentages: [:]
        )
        let observations = SystemBluetoothCollector.map(reading, now: .distantPast)
        XCTAssertEqual(observations.count, 1)
        XCTAssertNil(observations[0].percentage)
    }
}
```

- [ ] **Step 2: Run the system collector tests to verify failure**

Run: `swift test --filter SystemBluetoothCollectorTests`

Expected: FAIL because collector types do not exist.

- [ ] **Step 3: Define collection interfaces and pure system readings**

Create `BatteryCollecting.swift`:

```swift
struct CollectorSnapshot: Sendable {
    let availability: BluetoothAvailability
    let observations: [BatteryObservation]
}

protocol BatteryCollecting: Sendable {
    func collect() async -> CollectorSnapshot
}
```

Define `SystemDeviceReading` in `SystemBluetoothCollector.swift` with address, name, connection, category, and `[BatteryComponent: Int?]`. Implement `static map(_:now:)` so a connected device with no component values emits one `.whole` observation with `nil`; disconnected readings emit no observations.

- [ ] **Step 4: Implement native connected-device discovery**

Implement `SystemBluetoothCollector` as an `actor`. Enumerate `IOBluetoothDevice.pairedDevices()`, cast to `[IOBluetoothDevice]`, and retain only `isConnected()`. Use the Bluetooth address as both `sourceID` and `stableID` after uppercasing and replacing `-` with `:`. Map major device class and name hints to `DeviceCategory`.

Read battery values defensively from the device object and matching I/O registry services. Keep compatibility-sensitive keys in one constant table:

```swift
private let componentKeys: [(BatteryComponent, [String])] = [
    (.left, ["BatteryPercentLeft", "batteryPercentLeft"]),
    (.right, ["BatteryPercentRight", "batteryPercentRight"]),
    (.case, ["BatteryPercentCase", "batteryPercentCase"]),
    (.whole, ["BatteryPercent", "BatteryPercentSingle", "batteryPercent"])
]
```

Use Objective-C runtime/KVC only after checking selector availability, catch Objective-C-incompatible absence by reading dictionary/property representations instead of force-unwrapping, and release every `io_object_t` returned by IOKit. Match registry entries to a device only by normalized Bluetooth address; do not merge by display name.

Set availability to `.permissionDenied` when `CBManager.authorization == .denied` or `.restricted`, `.poweredOff` when the Bluetooth host controller reports off, `.unavailable` when no host controller exists, and `.available` otherwise. Return connected devices with nil levels even when registry lookup fails.

- [ ] **Step 5: Run collector tests and compile with strict concurrency checks**

Run: `swift test -Xswiftc -strict-concurrency=complete --filter SystemBluetoothCollectorTests`

Expected: PASS with no errors; warnings about imported pre-concurrency Apple types must be locally contained with `@preconcurrency import`, not by disabling strict concurrency globally.

- [ ] **Step 6: Commit system collection**

```bash
git add Sources/BatteriesIncluded/Monitoring/BatteryCollecting.swift Sources/BatteriesIncluded/Collectors/SystemBluetoothCollector.swift Tests/BatteriesIncludedTests/SystemBluetoothCollectorTests.swift
git commit -m "feat: collect system Bluetooth battery data"
```

---

### Task 4: Core Bluetooth Collector

**Files:**
- Create: `Sources/BatteriesIncluded/Collectors/CoreBluetoothCollector.swift`
- Create: `Tests/BatteriesIncludedTests/CoreBluetoothCollectorTests.swift`

**Interfaces:**
- Consumes: `BatteryCollecting`, `CollectorSnapshot`, and domain types from Tasks 1 and 3.
- Produces: `CoreBluetoothCollector`, `BLEDeviceReading`, and `CoreBluetoothCollector.map(_:now:)`.

- [ ] **Step 1: Write failing BLE mapping tests**

```swift
import XCTest
@testable import BatteriesIncluded

final class CoreBluetoothCollectorTests: XCTestCase {
    func testMapsStandardBatteryLevelCharacteristic() {
        let reading = BLEDeviceReading(
            identifier: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            name: "Heart Rate Strap", isConnected: true, batteryLevel: 72
        )
        let result = CoreBluetoothCollector.map(reading, now: .distantPast)
        XCTAssertEqual(result.single?.component, .whole)
        XCTAssertEqual(result.single?.percentage, 72)
        XCTAssertEqual(result.single?.source, .coreBluetooth)
    }

    func testDoesNotReportDisconnectedPeripheral() {
        let reading = BLEDeviceReading(identifier: UUID(), name: "Sensor", isConnected: false, batteryLevel: 50)
        XCTAssertTrue(CoreBluetoothCollector.map(reading, now: .distantPast).isEmpty)
    }
}
```

- [ ] **Step 2: Run BLE tests to verify failure**

Run: `swift test --filter CoreBluetoothCollectorTests`

Expected: FAIL because BLE collector types do not exist.

- [ ] **Step 3: Add BLE mapping seam**

Define `BLEDeviceReading` with UUID, name, connected flag, and optional level. Implement `static map(_:now:)` to create a `.whole` observation whose stable ID is the UUID string. Invalid percentages remain observations and are rejected later by the normalizer.

- [ ] **Step 4: Implement non-invasive Core Bluetooth collection**

Implement `CoreBluetoothCollector` as an actor-backed `CBCentralManagerDelegate` bridge using a private serial dispatch queue. Use Battery Service UUID `180F` and Battery Level characteristic UUID `2A19`. On each collection:

1. Translate authorization and manager state to `BluetoothAvailability`.
2. Call `retrieveConnectedPeripherals(withServices: [CBUUID(string: "180F")])`.
3. Include only peripherals whose state is `.connected`.
4. Use cached characteristic values already discovered during the app lifetime.
5. Never call `connect(_:options:)` from the 30-second collection path.
6. If an already connected peripheral exposes the service, discover/read `2A19`; retain delegate updates in the actor cache.
7. Bound collection waiting to two seconds so a peripheral cannot stall the menu.

Bridge delegate callbacks into the actor with `Task { await ... }`, resume each collection continuation exactly once, and clear pending continuations on timeout or powered-off transitions.

- [ ] **Step 5: Run BLE tests and the full suite**

Run: `swift test -Xswiftc -strict-concurrency=complete`

Expected: PASS with no continuation misuse or strict-concurrency errors.

- [ ] **Step 6: Commit BLE collection**

```bash
git add Sources/BatteriesIncluded/Collectors/CoreBluetoothCollector.swift Tests/BatteriesIncludedTests/CoreBluetoothCollectorTests.swift
git commit -m "feat: collect standard BLE battery levels"
```

---

### Task 5: Refresh Orchestration and Menu-State Presentation

**Files:**
- Create: `Sources/BatteriesIncluded/Monitoring/DeviceMonitor.swift`
- Create: `Tests/BatteriesIncludedTests/DeviceMonitorTests.swift`
- Create: `Tests/BatteriesIncludedTests/MenuPresentationTests.swift`

**Interfaces:**
- Consumes: `[any BatteryCollecting]`, `BatteryNormalizer`, `CollectorSnapshot`, and `MenuState`.
- Produces: `@MainActor @Observable final class DeviceMonitor`, `start()`, `stop()`, and `refresh()`.

- [ ] **Step 1: Write failing monitor tests with fixture collectors**

Create `DeviceMonitorTests.swift` with an actor fixture:

```swift
import XCTest
@testable import BatteriesIncluded

private actor FixtureCollector: BatteryCollecting {
    let snapshot: CollectorSnapshot
    init(_ snapshot: CollectorSnapshot) { self.snapshot = snapshot }
    func collect() async -> CollectorSnapshot { snapshot }
}

@MainActor
final class DeviceMonitorTests: XCTestCase {
    func testRefreshCombinesCollectorsAndPublishesDevices() async {
        let now = Date()
        let device = BatteryObservation(
            sourceID: "one", stableID: "one", name: "Mouse", isConnected: true,
            category: .mouse, component: .whole, percentage: 84,
            source: .system, observedAt: now
        )
        let monitor = DeviceMonitor(
            collectors: [FixtureCollector(.init(availability: .available, observations: [device]))],
            now: { now }
        )
        await monitor.refresh()
        guard case .devices(let devices) = monitor.state else { return XCTFail("Expected devices") }
        XCTAssertEqual(devices.first?.levels.first?.percentage, 84)
    }

    func testPermissionDenialWinsWhenNoDevicesAreReadable() async {
        let monitor = DeviceMonitor(
            collectors: [FixtureCollector(.init(availability: .permissionDenied, observations: []))]
        )
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .permissionDenied)
    }

    func testBluetoothOffWinsOverGenericEmptyState() async {
        let monitor = DeviceMonitor(
            collectors: [FixtureCollector(.init(availability: .poweredOff, observations: []))]
        )
        await monitor.refresh()
        XCTAssertEqual(monitor.state, .bluetoothOff)
    }
}
```

In `MenuPresentationTests.swift`, assert exact component text:

```swift
func testComponentSummaryUsesBalancedCopy() {
    let levels: [(BatteryComponent, Int)] = [(.left, 82), (.right, 76), (.case, 64)]
    XCTAssertEqual(DeviceBattery.componentSummary(levels), "Left 82% · Right 76% · Case 64%")
}
```

- [ ] **Step 2: Run monitor tests to verify failure**

Run: `swift test --filter DeviceMonitorTests`

Expected: FAIL because `DeviceMonitor` does not exist.

- [ ] **Step 3: Implement deterministic refresh orchestration**

Create a main-actor Observation model:

```swift
import Foundation
import Observation

@MainActor @Observable
final class DeviceMonitor {
    private(set) var state: MenuState = .loading
    private(set) var isRefreshing = false

    init(
        collectors: [any BatteryCollecting],
        normalizer: BatteryNormalizer = .init(),
        refreshInterval: Duration = .seconds(30),
        now: @escaping @Sendable () -> Date = Date.init
    )

    func start()
    func stop()
    func refresh() async
}
```

`refresh()` guards against overlapping cycles, collects all sources concurrently with a task group, normalizes the combined observations, and publishes `.devices` when any connected devices exist. If none exist, precedence is permission denied, powered off, unavailable, then no devices. Collector failure must be represented as an `.unavailable` snapshot rather than a thrown error.

`start()` creates one cancellable task that refreshes immediately and sleeps for the injected interval. `stop()` cancels and nils it. The deinitializer cancels the task. Preserve the previous device state while `isRefreshing` is true; replace it only when the cycle completes.

Add `DeviceBattery.componentSummary(_:)` as a pure formatter with labels `Battery`, `Left`, `Right`, `Case`, and the exact custom label.

- [ ] **Step 4: Test immediate, periodic, and non-overlapping refreshes**

Add a controllable collector with an invocation counter and continuation. Assert that `start()` invokes once immediately, a manual `refresh()` during an active cycle does not invoke again, and `stop()` prevents subsequent scheduled work. Use a 10-millisecond injected interval in the scheduling test; never wait on the production 30-second interval.

- [ ] **Step 5: Run monitor and presentation tests**

Run: `swift test --filter DeviceMonitorTests && swift test --filter MenuPresentationTests`

Expected: PASS for state precedence, combination, summary copy, scheduling, and overlap protection.

- [ ] **Step 6: Commit monitoring**

```bash
git add Sources/BatteriesIncluded/Monitoring/DeviceMonitor.swift Tests/BatteriesIncludedTests/DeviceMonitorTests.swift Tests/BatteriesIncludedTests/MenuPresentationTests.swift Sources/BatteriesIncluded/Model/BatteryModels.swift
git commit -m "feat: orchestrate live battery refreshes"
```

---

### Task 6: Balanced SwiftUI Menu and App Lifecycle

**Files:**
- Create: `Sources/BatteriesIncluded/App/BatteriesIncludedApp.swift`
- Create: `Sources/BatteriesIncluded/App/AppCommands.swift`
- Create: `Sources/BatteriesIncluded/UI/BatteryMenuView.swift`
- Create: `Sources/BatteriesIncluded/UI/DeviceRowView.swift`
- Create: `Sources/BatteriesIncluded/UI/DeviceIcon.swift`
- Create: `Sources/BatteriesIncluded/Support/SettingsOpening.swift`
- Create: `Sources/BatteriesIncluded/Support/SystemLogging.swift`
- Modify: `Tests/BatteriesIncludedTests/MenuPresentationTests.swift`

**Interfaces:**
- Consumes: `DeviceMonitor`, `MenuState`, and `DeviceBattery`.
- Produces: executable `@main BatteriesIncludedApp`, balanced menu UI, settings opener, and logging categories.

- [ ] **Step 1: Add failing display-model tests**

Add assertions for user-facing labels and symbols through pure helpers:

```swift
func testUnavailableDeviceShowsExpectedLabel() {
    let device = DeviceBattery(id: "x", name: "Speaker", category: .other, levels: [])
    XCTAssertEqual(device.primaryBatteryText, "Battery unavailable")
}

func testDeviceSymbols() {
    XCTAssertEqual(DeviceIcon.symbol(for: .headphones), "headphones")
    XCTAssertEqual(DeviceIcon.symbol(for: .mouse), "computermouse")
    XCTAssertEqual(DeviceIcon.symbol(for: .keyboard), "keyboard")
}
```

- [ ] **Step 2: Run presentation tests to verify failure**

Run: `swift test --filter MenuPresentationTests`

Expected: FAIL because `primaryBatteryText` and `DeviceIcon` do not exist.

- [ ] **Step 3: Implement presentation helpers and row view**

Implement `primaryBatteryText`: no levels yields `Battery unavailable`; a single `.whole` yields `<n>%`; multiple/component readings use `componentSummary`. Implement `DeviceIcon.symbol(for:)` with SF Symbols: headphones, computermouse, keyboard, rectangle.and.hand.point.up.left, gamecontroller, and hifispeaker.

Build `DeviceRowView` as a `Label` with a two-line `VStack`: device name and component summary when there are multiple component values. Put a single whole-device percentage in a trailing monospaced-digit `Text`. Keep the row native-sized; do not add progress bars.

- [ ] **Step 4: Build all menu states and footer actions**

`BatteryMenuView` switches over `MenuState`:

- `.loading`: `ProgressView("Reading batteries…")`
- `.devices`: one `DeviceRowView` per device
- `.noDevices`: `Label("No Bluetooth devices connected", systemImage: "wave.3.right")`
- `.bluetoothOff`: `Label("Bluetooth is off", systemImage: "antenna.radiowaves.left.and.right.slash")`
- `.permissionDenied`: explanatory text plus `Button("Open System Settings")`
- `.unavailable`: `Label("Bluetooth unavailable", systemImage: "exclamationmark.triangle")`

After a divider, add `Refresh`, `About Batteries Included`, another divider, and `Quit`. Disable Refresh only while a refresh is active. `Refresh` starts `Task { await monitor.refresh() }`; About calls `NSApplication.shared.orderFrontStandardAboutPanel(nil)`; Quit calls `NSApplication.shared.terminate(nil)`.

Implement `SettingsOpening` with `NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)` and return a Boolean so failure can be logged.

- [ ] **Step 5: Wire the menu-bar-only application**

Create:

```swift
@main
struct BatteriesIncludedApp: App {
    @State private var monitor = DeviceMonitor(collectors: [
        SystemBluetoothCollector(), CoreBluetoothCollector()
    ])

    var body: some Scene {
        MenuBarExtra("Batteries Included", systemImage: "battery.75percent") {
            BatteryMenuView(monitor: monitor)
                .task { monitor.start() }
                .onAppear { Task { await monitor.refresh() } }
        }
        .menuBarExtraStyle(.menu)
    }
}
```

Put About and Quit behavior behind small functions in `AppCommands.swift`. Add `Logger` values in `SystemLogging.swift` under subsystem `com.batteriesincluded.app` with categories `monitor`, `system-bluetooth`, and `core-bluetooth`. Log source errors and state transitions without raw characteristic payloads.

- [ ] **Step 6: Run tests and compile the executable**

Run: `swift test -Xswiftc -strict-concurrency=complete && swift build -c release`

Expected: all tests PASS and `.build/release/BatteriesIncluded` is produced.

- [ ] **Step 7: Commit the app UI**

```bash
git add Sources/BatteriesIncluded Tests/BatteriesIncludedTests/MenuPresentationTests.swift
git commit -m "feat: add balanced menu bar interface"
```

---

### Task 7: App Bundle, Signing Inputs, and End-to-End Verification

**Files:**
- Create: `Resources/Info.plist`
- Create: `scripts/build-app.sh`
- Modify: `.gitignore`
- Create: `README.md`

**Interfaces:**
- Consumes: release executable from Task 6.
- Produces: `dist/Batteries Included.app` ready for local ad-hoc signing or Developer ID signing through environment inputs.

- [ ] **Step 1: Write the bundle metadata**

Create `Resources/Info.plist` with:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleDisplayName</key><string>Batteries Included</string>
  <key>CFBundleExecutable</key><string>BatteriesIncluded</string>
  <key>CFBundleIdentifier</key><string>com.batteriesincluded.app</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Batteries Included</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Batteries Included reads battery levels from your connected Bluetooth devices.</string>
  <key>NSHumanReadableCopyright</key><string>Copyright © 2026</string>
</dict></plist>
```

- [ ] **Step 2: Create a deterministic bundling script**

Create executable `scripts/build-app.sh` with `set -euo pipefail`. It must:

1. Resolve the repository root relative to the script.
2. Run `swift build -c release`.
3. Remove only the exact root-local path `dist/Batteries Included.app` after validating it begins with `<repo>/dist/`.
4. Create `Contents/MacOS` and `Contents/Resources`.
5. Copy `.build/release/BatteriesIncluded` and `Resources/Info.plist` into the bundle.
6. Sign with `${CODE_SIGN_IDENTITY:--}` using `/usr/bin/codesign --force --options runtime --timestamp=none --sign`.
7. Verify with `/usr/bin/codesign --verify --deep --strict --verbose=2`.

Do not perform notarization in this script because credentials are user-specific. Add `dist/` to `.gitignore`.

- [ ] **Step 3: Document build, run, signing, and notarization commands**

Create `README.md` with requirements, `swift test`, `scripts/build-app.sh`, and `open 'dist/Batteries Included.app'`. Explain that ad-hoc signing is the default for local testing. Document Developer ID use as:

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
xcrun notarytool submit 'dist/Batteries Included.app.zip' --keychain-profile batteries-included --wait
xcrun stapler staple 'dist/Batteries Included.app'
```

State the best-effort compatibility limitation explicitly: macOS and the peripheral must expose a battery value; unsupported connected devices show `Battery unavailable`.

- [ ] **Step 4: Build and inspect the app bundle**

Run:

```bash
chmod +x scripts/build-app.sh
scripts/build-app.sh
plutil -lint 'dist/Batteries Included.app/Contents/Info.plist'
codesign --verify --deep --strict --verbose=2 'dist/Batteries Included.app'
```

Expected: build succeeds, plist reports `OK`, and codesign verification exits 0.

- [ ] **Step 5: Run the entire automated suite**

Run: `swift test -Xswiftc -strict-concurrency=complete`

Expected: all tests PASS with no strict concurrency errors.

- [ ] **Step 6: Perform macOS 14 manual acceptance checks**

Launch `dist/Batteries Included.app` and verify:

1. No Dock icon appears and the menu-bar icon does.
2. The menu opens with the balanced device-row layout.
3. A supported connected device shows a percentage.
4. A multi-component audio device shows separate left/right/case values when exposed.
5. An unsupported connected device remains listed as `Battery unavailable`.
6. Disconnecting a device removes it after refresh; connecting one adds it.
7. Turning Bluetooth off shows `Bluetooth is off`; turning it on recovers.
8. Denying Bluetooth permission shows the explanation and the System Settings button opens Bluetooth privacy settings.
9. `Refresh`, `About Batteries Included`, and `Quit` work.

Record unavailable hardware cases in the commit message notes; do not claim an unperformed device-specific check passed.

- [ ] **Step 7: Commit packaging and documentation**

```bash
git add Resources/Info.plist scripts/build-app.sh README.md .gitignore
git commit -m "build: package Batteries Included macOS app"
```

---

## Final Verification

- [ ] Run `swift test -Xswiftc -strict-concurrency=complete` and confirm all tests pass.
- [ ] Run `scripts/build-app.sh` and confirm bundle and signature verification succeed.
- [ ] Run `git status --short` and confirm only deliberately untracked local artifacts remain.
- [ ] Compare the finished menu against every acceptance criterion in `docs/superpowers/specs/2026-08-22-batteries-included-design.md`.
- [ ] Commit any verification-only fixes in focused commits before handing off the build.
