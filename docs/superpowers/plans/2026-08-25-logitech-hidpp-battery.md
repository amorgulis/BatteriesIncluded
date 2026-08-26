# Logitech HID++ Battery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display battery levels for direct Logitech HID++ devices and HID++ 2.0 devices behind Unifying, Bolt, and Lightspeed receivers.

**Architecture:** Add an IOKit discovery layer, a serialized request/reply actor per HID interface, and a battery reader that dynamically resolves HID++ features. Publish its results through the existing collector and normalizer pipeline, with Logitech readings preferred and uniquely merged into matching macOS Bluetooth rows.

**Tech Stack:** Swift 5.9, macOS 14, IOKit/IOHIDManager, Swift Concurrency, XCTest, Swift Package Manager

**Spec:** `docs/superpowers/specs/2026-08-25-logitech-hidpp-battery-design.md`

## Global Constraints

- Keep macOS 14 and Swift 5.9 support.
- Add no dependency, helper process, or Logitech software requirement.
- Match vendor `0x046D` and HID++ report IDs `0x10`/`0x11` only.
- Resolve feature indexes through `IRoot`; never hard-code them.
- Read `0x1004`, then `0x1000`; never derive percentage from voltage.
- Map `0x1004` coarse levels `1/2/4/8` to `10/30/60/90` percent.
- HID failures must not alter Bluetooth-wide availability messaging.
- Leave `.vscode/` untouched.

---

### Task 1: Source priority and cross-source normalization

**Files:**
- Modify: `Sources/BatteriesIncluded/Model/BatteryModels.swift:21-25`
- Modify: `Sources/BatteriesIncluded/Model/BatteryNormalizer.swift:32-68`
- Modify: `Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift`

**Interfaces:**
- Produces: `BatterySource.logitechHID`
- Produces: unique same-name merge from one Logitech HID group into one non-HID group

- [ ] **Step 1: Write failing tests**

Add a `category` argument to the existing test helper, then add:

```swift
func testPrefersFreshLogitechHIDReading() {
    let result = BatteryNormalizer().normalize([
        observation(percentage: 83, source: .coreBluetooth),
        observation(percentage: 61, source: .logitechHID)
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(result.single?.levels.single?.percentage, 61)
}

func testMergesUniqueLogitechGroupAndPreservesSystemIdentity() {
    let result = BatteryNormalizer().normalize([
        observation(id: "AA:BB", stableID: "AA:BB", name: "MX Master 3S",
                    percentage: nil, source: .system, category: .mouse),
        observation(id: "receiver:1", stableID: "receiver:1", name: "MX Master 3S",
                    percentage: 61, source: .logitechHID, category: nil)
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.single?.id, "stable:AA:BB")
    XCTAssertEqual(result.single?.category, .mouse)
    XCTAssertEqual(result.single?.levels.single?.percentage, 61)
}

func testDoesNotMergeAmbiguousLogitechName() {
    let result = BatteryNormalizer().normalize([
        observation(id: "system", stableID: "system", name: "MX Keys", source: .system),
        observation(id: "hid-1", stableID: "hid-1", name: "MX Keys", source: .logitechHID),
        observation(id: "hid-2", stableID: "hid-2", name: "MX Keys", source: .logitechHID)
    ], now: Date(timeIntervalSince1970: 1_000))
    XCTAssertEqual(result.count, 3)
}
```

- [ ] **Step 2: Verify RED**

Run `swift test --filter BatteryNormalizerTests`.

Expected: compilation fails because `.logitechHID` is missing.

- [ ] **Step 3: Implement minimal normalization behavior**

```swift
enum BatterySource: Int, Sendable, Equatable {
    case systemProfiler = -1
    case system = 0
    case coreBluetooth = 1
    case logitechHID = 2
}
```

In the existing per-name merge loop, retain the current system/CoreBluetooth case. Add a second case that requires exactly two groups and exactly one group whose source set is `[.logitechHID]`; append that group into the non-HID group so its stable ID is preserved. Sort keys before selection and refuse all names with more than two groups.

- [ ] **Step 4: Verify GREEN**

Run `swift test --filter BatteryNormalizerTests && swift test`.

Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/BatteriesIncluded/Model/BatteryModels.swift Sources/BatteriesIncluded/Model/BatteryNormalizer.swift Tests/BatteriesIncludedTests/BatteryNormalizerTests.swift
git commit -m "feat: prioritize Logitech HID battery readings"
```

---

### Task 2: HID++ packet codec

**Files:**
- Create: `Sources/BatteriesIncluded/Logitech/HIDPPPacket.swift`
- Create: `Tests/BatteriesIncludedTests/HIDPPPacketTests.swift`

**Interfaces:**
- Produces: `HIDPPReportKind`, `HIDPPPacket`, `HIDPPError`

- [ ] **Step 1: Write failing byte-level tests**

```swift
func testBuildsShortRootGetFeatureRequest() throws {
    let packet = try HIDPPPacket.request(kind: .short, deviceIndex: 1,
        featureIndex: 0, functionID: 0, softwareID: 0x0D,
        parameters: [0x10, 0x04])
    XCTAssertEqual(packet.bytes, [0x10, 1, 0, 0x0D, 0x10, 0x04, 0])
}

func testBuildsLongFunctionOneRequest() throws {
    let packet = try HIDPPPacket.request(kind: .long, deviceIndex: 0xFF,
        featureIndex: 7, functionID: 1, softwareID: 0x0D, parameters: [])
    XCTAssertEqual(packet.bytes.count, 20)
    XCTAssertEqual(Array(packet.bytes.prefix(4)), [0x11, 0xFF, 7, 0x1D])
}

func testResponseCorrelationUsesAllHeaderFields() throws {
    let packet = try HIDPPPacket.request(kind: .long, deviceIndex: 1,
        featureIndex: 7, functionID: 1, softwareID: 0x0D, parameters: [])
    XCTAssertTrue(packet.matchesResponse([0x11, 1, 7, 0x1D] + .init(repeating: 0, count: 16)))
    XCTAssertFalse(packet.matchesResponse([0x11, 2, 7, 0x1D] + .init(repeating: 0, count: 16)))
}
```

Also test invalid function/software IDs, oversized parameters, truncated reports, unrelated notifications, and HID++ long error `0xFF` with error code `0x06`.

- [ ] **Step 2: Verify RED**

Run `swift test --filter HIDPPPacketTests`; expect missing-type compilation failures.

- [ ] **Step 3: Implement the codec**

```swift
enum HIDPPReportKind: UInt8, Sendable {
    case short = 0x10, long = 0x11
    var length: Int { self == .short ? 7 : 20 }
}

enum HIDPPError: Error, Sendable, Equatable {
    case invalidPacket, invalidFeatureIndex, timeout, disconnected
    case protocolError(UInt8)
}

struct HIDPPPacket: Sendable, Equatable {
    let bytes: [UInt8]
    static func request(kind: HIDPPReportKind, deviceIndex: UInt8,
        featureIndex: UInt8, functionID: UInt8, softwareID: UInt8,
        parameters: [UInt8]) throws -> Self
    var parameters: ArraySlice<UInt8> { get }
    func matchesResponse(_ response: [UInt8]) -> Bool
    func protocolError(in response: [UInt8]) -> HIDPPError?
}
```

Pad to exactly 7 or 20 bytes. Encode byte 3 as `(functionID << 4) | softwareID`. Require exact response length and matching report/device/feature/function-software fields. Map error code `0x06` to `.invalidFeatureIndex` and preserve unknown codes.

- [ ] **Step 4: Verify GREEN and commit**

Run `swift test --filter HIDPPPacketTests`, then:

```bash
git add Sources/BatteriesIncluded/Logitech/HIDPPPacket.swift Tests/BatteriesIncludedTests/HIDPPPacketTests.swift
git commit -m "feat: add HID++ packet codec"
```

---

### Task 3: Battery feature reader

**Files:**
- Create: `Sources/BatteriesIncluded/Logitech/HIDPPBatteryReader.swift`
- Create: `Tests/BatteriesIncludedTests/HIDPPBatteryReaderTests.swift`

**Interfaces:**
- Consumes: `HIDPPRequesting.send(_:)`
- Produces: `HIDPPFallbackIdentity`, `HIDPPDeviceReading`, `HIDPPBatteryReading`

- [ ] **Step 1: Write a scripted requester and failing tests**

Test dynamic `0x1004` lookup, function-0 capabilities, function-1 percentage, discrete mapping, fallback to `0x1000`, zero/invalid rejection, voltage-only nil percentage, unnamed child omission, cache reuse, and invalid-feature eviction. Representative assertions:

```swift
let reading = try await reader.read(deviceIndex: 1, fallbackIdentity: identity)
XCTAssertEqual(reading?.percentage, 73) // 0x1004 state-of-charge
XCTAssertEqual(requester.requestedFeatureIDs, [0x1004])

XCTAssertEqual(discreteReading?.percentage, 60) // level byte 0x04
XCTAssertEqual(legacyReading?.percentage, 50)   // 0x1000 byte zero
XCTAssertNil(voltageOnlyReading?.percentage)
XCTAssertFalse(requester.requestedFeatureIDs.contains(0x1001))
```

- [ ] **Step 2: Verify RED**

Run `swift test --filter HIDPPBatteryReaderTests`; expect missing-type failures.

- [ ] **Step 3: Implement exact interfaces and parsing**

```swift
protocol HIDPPRequesting: Sendable {
    func send(_ packet: HIDPPPacket) async throws -> [UInt8]
}

struct HIDPPFallbackIdentity: Sendable, Equatable {
    let stableID: String
    let name: String?
    let category: DeviceCategory?
    let isReceiverChild: Bool
}

struct HIDPPDeviceReading: Sendable, Equatable {
    let deviceIndex: UInt8
    let stableID: String
    let name: String
    let category: DeviceCategory?
    let percentage: Int?
}

protocol HIDPPBatteryReading: Sendable {
    func read(deviceIndex: UInt8,
        fallbackIdentity: HIDPPFallbackIdentity) async throws -> HIDPPDeviceReading?
}

actor HIDPPBatteryReader: HIDPPBatteryReading {
    init(requester: any HIDPPRequesting)
    func read(deviceIndex: UInt8,
        fallbackIdentity: HIDPPFallbackIdentity) async throws -> HIDPPDeviceReading?
    func invalidate(deviceIndex: UInt8)
    func invalidateAll()
}
```

`IRoot.GetFeature` sends the big-endian feature ID to feature index `0`, function `0`. For `0x1004`, call function `0`, check capabilities parameter 1 bit `0x02`, then call function `1`. Accept byte-zero `0...100` only with that bit; otherwise map level byte `[1:10, 2:30, 4:60, 8:90]`. For `0x1000` function `0`, accept byte zero `1...100`; zero is unknown. Query device-name feature `0x0005` for unnamed receiver children and omit them if still unnamed. Never query `0x1001`.

- [ ] **Step 4: Verify GREEN and commit**

Run `swift test --filter HIDPPBatteryReaderTests`, then:

```bash
git add Sources/BatteriesIncluded/Logitech/HIDPPBatteryReader.swift Tests/BatteriesIncludedTests/HIDPPBatteryReaderTests.swift
git commit -m "feat: read HID++ battery features"
```

---

### Task 4: Serialized per-interface transport

**Files:**
- Create: `Sources/BatteriesIncluded/Logitech/HIDPPTransport.swift`
- Create: `Tests/BatteriesIncludedTests/HIDPPTransportTests.swift`

**Interfaces:**
- Consumes: `HIDPPDeviceIO.write(_:)`
- Produces: `HIDPPTransport: HIDPPRequesting`

- [ ] **Step 1: Write failing lifecycle tests**

With a fake writer and callback injection, verify: matching response completes; mismatched report does not; timeout removes pending work; cancellation resumes once; removal fails active and queued requests; two requests serialize on one transport; two transports can progress concurrently.

```swift
let task = Task { try await transport.send(request) }
await io.waitForWrite()
await transport.receive([0x11, 1, 7, 0x1D, 73] + .init(repeating: 0, count: 15))
XCTAssertEqual(try await task.value[4], 73)
XCTAssertEqual(await transport.pendingRequestCount, 0)
```

- [ ] **Step 2: Verify RED**

Run `swift test --filter HIDPPTransportTests`; expect missing-type failures.

- [ ] **Step 3: Implement the transport actor**

```swift
protocol HIDPPDeviceIO: Sendable {
    func write(_ report: [UInt8]) throws
}

actor HIDPPTransport: HIDPPRequesting {
    init(io: any HIDPPDeviceIO, timeout: Duration = .milliseconds(250))
    func send(_ packet: HIDPPPacket) async throws -> [UInt8]
    func receive(_ report: [UInt8])
    func interfaceRemoved()
    var pendingRequestCount: Int { get }
}
```

Use an internal FIFO and one active checked continuation. Start its timeout only after a successful write. Route response, protocol error, timeout, cancellation, and removal through one `finishActive(with:)` method that cancels the timeout and resumes exactly once. Removal also drains the FIFO with `.disconnected`.

- [ ] **Step 4: Verify GREEN and commit**

Run `swift test --filter HIDPPTransportTests`, then:

```bash
git add Sources/BatteriesIncluded/Logitech/HIDPPTransport.swift Tests/BatteriesIncludedTests/HIDPPTransportTests.swift
git commit -m "feat: add serialized HID++ transport"
```

---

### Task 5: IOKit discovery and callback bridge

**Files:**
- Create: `Sources/BatteriesIncluded/Logitech/LogitechHIDDiscovery.swift`
- Create: `Sources/BatteriesIncluded/Logitech/IOKitHIDDevice.swift`
- Create: `Tests/BatteriesIncludedTests/LogitechHIDDiscoveryTests.swift`
- Modify: `Sources/BatteriesIncluded/Support/SystemLogging.swift`

**Interfaces:**
- Produces: `LogitechHIDInterfaceDescriptor`, `LogitechHIDInterface`, `LogitechHIDDiscovering`

- [ ] **Step 1: Write failing pure policy tests**

Test Logitech filtering, required bidirectional HID++ reports, collection deduplication preferring long-report support, serial identity, location fallback, distinct receiver-slot IDs, direct product-name fallback, nil receiver-child fallback name, and mouse/keyboard category mapping.

```swift
func fixture(
    vendorID: Int = 0x046D,
    input: Set<UInt8>,
    output: Set<UInt8>,
    physicalKey: String = "usb:046d:c548:serial"
) -> LogitechHIDInterfaceDescriptor {
    .init(
        id: "\(physicalKey):\(input.sorted())",
        physicalKey: physicalKey,
        vendorID: vendorID,
        productID: 0xC548,
        serialNumber: "serial",
        locationID: 1,
        transport: "USB",
        productName: "MX Fixture",
        primaryUsagePage: 1,
        primaryUsage: 2,
        inputReportIDs: input,
        outputReportIDs: output
    )
}

let candidates = [
    fixture(vendorID: 0x046D, input: [0x11], output: [0x11]),
    fixture(vendorID: 0x1234, input: [0x11], output: [0x11]),
    fixture(vendorID: 0x046D, input: [0x01], output: [0x01])
]
XCTAssertEqual(LogitechHIDDiscoveryPolicy.select(candidates).count, 1)
XCTAssertNotEqual(descriptor.identity(deviceIndex: 1), descriptor.identity(deviceIndex: 2))
```

- [ ] **Step 2: Verify RED**

Run `swift test --filter LogitechHIDDiscoveryTests`; expect missing-type failures.

- [ ] **Step 3: Implement the pure descriptor/policy layer**

```swift
struct LogitechHIDInterfaceDescriptor: Sendable, Equatable, Identifiable {
    let id: String
    let physicalKey: String
    let vendorID: Int
    let productID: Int
    let serialNumber: String?
    let locationID: Int?
    let transport: String?
    let productName: String?
    let primaryUsagePage: Int?
    let primaryUsage: Int?
    let inputReportIDs: Set<UInt8>
    let outputReportIDs: Set<UInt8>
    func identity(deviceIndex: UInt8) -> HIDPPFallbackIdentity
}

enum LogitechHIDDiscoveryPolicy {
    static func select(_ candidates: [LogitechHIDInterfaceDescriptor])
        -> [LogitechHIDInterfaceDescriptor]
}

struct LogitechHIDInterface: Sendable {
    let descriptor: LogitechHIDInterfaceDescriptor
    let transport: HIDPPTransport
}

protocol LogitechHIDDiscovering: Sendable {
    func interfaces() async -> [LogitechHIDInterface]
}
```

- [ ] **Step 4: Implement native IOKit adapter**

Create one `IOHIDManager` matching `kIOHIDVendorIDKey = 0x046D`. Extract properties and report elements, apply the pure policy, open selected devices, and allocate callback buffers using `kIOHIDMaxInputReportSizeKey`. Wrap `IOHIDDevice` in an `@unchecked Sendable` final class with lock-protected callback lifetime. Write reports with `IOHIDDeviceSetReport`; forward input/removal callbacks to `HIDPPTransport.receive`/`interfaceRemoved` via `Task`. Close devices and manager during teardown. Add `SystemLogging.logitechHID`; never log serials or raw packets.

- [ ] **Step 5: Verify GREEN and commit**

Run `swift test --filter LogitechHIDDiscoveryTests && swift build`, then:

```bash
git add Sources/BatteriesIncluded/Logitech/LogitechHIDDiscovery.swift Sources/BatteriesIncluded/Logitech/IOKitHIDDevice.swift Sources/BatteriesIncluded/Support/SystemLogging.swift Tests/BatteriesIncludedTests/LogitechHIDDiscoveryTests.swift
git commit -m "feat: discover Logitech HID++ interfaces"
```

---

### Task 6: Collector, receiver probing, and app wiring

**Files:**
- Create: `Sources/BatteriesIncluded/Collectors/LogitechHIDCollector.swift`
- Create: `Tests/BatteriesIncludedTests/LogitechHIDCollectorTests.swift`
- Modify: `Sources/BatteriesIncluded/App/BatteriesIncludedApp.swift:5-7`
- Modify: `README.md`

**Interfaces:**
- Consumes: `LogitechHIDDiscovering`, `HIDPPBatteryReading`
- Produces: `LogitechHIDCollector: BatteryCollecting`

- [ ] **Step 1: Write failing orchestration tests**

With fake discovery/readers, verify index order `[0xFF,1,2,3,4,5,6]`, direct plus two distinct receiver observations, nil battery for a known voltage-only device, omission of unknown children, healthy slots surviving other slot failures, deduplication by stable ID, concurrent interfaces, and `.available` empty snapshots for discovery failure.

```swift
let snapshot = await collector.collect()
XCTAssertEqual(snapshot.availability, .available)
XCTAssertEqual(Set(snapshot.observations.compactMap(\.stableID)),
               ["direct", "receiver:1", "receiver:2"])
XCTAssertNil(snapshot.observations.first { $0.name == "G Headset" }?.percentage)
```

- [ ] **Step 2: Verify RED**

Run `swift test --filter LogitechHIDCollectorTests`; expect missing-type failures.

- [ ] **Step 3: Implement collector**

```swift
actor LogitechHIDCollector: BatteryCollecting {
    init(
        discovery: any LogitechHIDDiscovering = LogitechHIDDiscovery(),
        readerFactory: @escaping @Sendable (HIDPPTransport) -> any HIDPPBatteryReading = {
            HIDPPBatteryReader(requester: $0)
        },
        now: @escaping @Sendable () -> Date = { .now }
    )
    func collect() async -> CollectorSnapshot
}
```

For each interface, read indexes `[0xFF,1,2,3,4,5,6]`; use a task group across interfaces. Convert each result to one connected `.whole` observation with source/stable ID `.logitechHID`/`reading.stableID`. Deduplicate by stable ID, sort by name then ID, isolate errors per target, and always return `.available`.

- [ ] **Step 4: Wire and document**

```swift
@State private var monitor = DeviceMonitor(collectors: [
    SystemBluetoothCollector(), CoreBluetoothCollector(),
    LogitechHIDCollector(), SystemProfilerCollector()
])
```

Update `README.md` with direct/receiver HID++ support and the voltage-only `Battery unavailable` behavior.

- [ ] **Step 5: Verify GREEN and commit**

Run:

```bash
swift test --filter LogitechHIDCollectorTests
swift test
Tests/Scripts/build-app-tests.sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/logitech-hid-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/logitech-hid-swiftpm-cache swift build -c release
git diff --check
```

Then:

```bash
git add Sources/BatteriesIncluded/Collectors/LogitechHIDCollector.swift Sources/BatteriesIncluded/App/BatteriesIncludedApp.swift Tests/BatteriesIncludedTests/LogitechHIDCollectorTests.swift README.md
git commit -m "feat: display Logitech HID++ battery levels"
```

---

### Task 7: Final verification and review

**Files:**
- Review: all changes since spec commit `ba02cf0`

**Interfaces:**
- Produces: final verification evidence and resolved review findings

- [ ] **Step 1: Run complete verification**

```bash
env CLANG_MODULE_CACHE_PATH=/private/tmp/logitech-hid-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/logitech-hid-swiftpm-cache swift test
Tests/Scripts/build-app-tests.sh
env CLANG_MODULE_CACHE_PATH=/private/tmp/logitech-hid-clang-cache SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/logitech-hid-swiftpm-cache swift build -c release
git diff --check ba02cf0..HEAD
```

Expected: every command exits `0`.

- [ ] **Step 2: Review against the spec**

Inspect `git diff ba02cf0..HEAD`. Confirm every constraint has a test; no voltage conversion, raw packet logging, or serial logging exists; callback buffers and handles outlive callbacks; continuations resume exactly once; failures remain target-local; and `.vscode/` remains untouched.

- [ ] **Step 3: Resolve findings test-first**

For each behavioral finding, add one failing focused test, run it to verify RED, implement the smallest fix, then rerun its focused suite and the full verification commands. If no findings exist, change nothing.

- [ ] **Step 4: Commit review fixes only if needed**

```bash
git add Sources/BatteriesIncluded Tests/BatteriesIncludedTests README.md
git commit -m "fix: harden Logitech HID++ battery support"
```
