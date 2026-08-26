# Logitech HID++ Battery Design

## Goal

Display battery levels for connected Logitech devices that expose battery data through HID++ but not through the app's existing macOS Bluetooth or standard BLE sources. Support directly connected HID++ devices and HID++ 2.0 devices behind Logitech Unifying, Bolt, and Lightspeed USB receivers.

## Constraints

- The deployment target remains macOS 14 and Swift 5.9.
- Use the native IOKit HID APIs already available to the app; do not add a package, C-library, helper-process, or Logitech software dependency.
- Restrict discovery to Logitech vendor ID `0x046D` and HID collections that support HID++ short (`0x10`, 7-byte) or long (`0x11`, 20-byte) reports.
- Resolve device-specific feature indexes dynamically through HID++ `IRoot` (`0x0000`); never hard-code a feature index.
- Read percentage or protocol-defined level data from Unified Battery (`0x1004`) or Battery Unified Level Status (`0x1000`). When `0x1004` explicitly reports no state-of-charge capability, map its four coarse levels to representative display values: critical `10%`, low `30%`, good `60%`, and full `90%`.
- Do not estimate a percentage from Battery Voltage (`0x1001`) or any other voltage-only feature. A known voltage-only device remains visible with `Battery unavailable` when another collector can identify it.
- A failure in HID discovery or communication must not prevent devices from other collectors from appearing.
- Leave the user's untracked `.vscode/` directory unchanged.

## Architecture

Add `LogitechHIDCollector` as another implementation of `BatteryCollecting` and register it with `DeviceMonitor`. Keep the platform boundary, HID++ transport, and battery feature logic in separate focused units:

- `LogitechHIDDiscovery` wraps `IOHIDManager`, filters and deduplicates Logitech HID++ interfaces, exposes plain device descriptors, and opens matching `IOHIDDevice` objects through a narrow injectable interface.
- `HIDPPTransport` frames short and long reports, allocates a non-zero software ID, serializes requests per HID interface, matches replies by report ID, device index, feature index, function, and software ID, recognizes HID++ protocol errors, and enforces bounded request timeouts.
- `HIDPPBatteryReader` pings targets, resolves feature IDs through `IRoot.GetFeature`, reads supported battery functions, validates responses, and caches resolved feature indexes for subsequent refreshes.
- `LogitechHIDCollector` coordinates interfaces and receiver slots, converts successful readings into `BatteryObservation` values, and isolates failures to the affected target.

Each open HID interface owns one transport actor because HID++ replies and unsolicited notifications share the same report channel. Requests on that interface are serialized, while independent HID interfaces may be collected concurrently.

## Device and Interface Discovery

Create one `IOHIDManager` matching Logitech vendor ID `0x046D`. From its device set, retain interfaces whose report capabilities contain HID++ report ID `0x10` or `0x11`. When macOS exposes multiple collections for the same physical device, group them using transport, vendor ID, product ID, serial number, and registry location, then retain the collection capable of both writing HID++ requests and receiving HID++ replies.

For each retained interface:

1. Probe device index `0xFF` for a directly connected or receiver-level HID++ endpoint.
2. Probe receiver device indexes `1...6` independently to discover active paired devices.
3. Accept a target only after it returns a valid HID++ ping or feature response with matching correlation fields.
4. Cache responsive target indexes and their identity data. Re-probe all receiver slots after reconnection and periodically so newly paired or awakened devices are discovered.

An unanswered receiver slot is normal and does not create a device or an error state. Probes and feature requests use short bounded timeouts so six empty slots cannot stall the app's refresh cycle indefinitely.

## HID++ Data Flow

For every responsive target:

1. Send an `IRoot` protocol-version ping to confirm the target speaks HID++ 2.0 or later.
2. Resolve device name/type feature `0x0005` when available. Fall back to the IOKit product name and HID usage-derived category for a direct device. A receiver child without a usable name is omitted rather than shown as a phantom receiver entry.
3. Ask `IRoot.GetFeature` for `0x1004`. If present, read function `0` capabilities and function `1` status. Use the status byte-zero percentage only when the capabilities state-of-charge bit is set. Otherwise map the status level byte values `1`, `2`, `4`, and `8` to `10%`, `30%`, `60%`, and `90%` respectively.
4. If `0x1004` is absent or returns no usable level, resolve `0x1000` and read function `0`. Its first response parameter is a discharge percentage in `1...100`; `0` means unknown. Ignore its next-threshold and charging-status parameters for menu display.
5. If neither feature yields a valid level, retain a known device observation with a `nil` percentage; do not query or convert voltage-only features.
6. Emit a whole-device `BatteryObservation` with source `.logitechHID` and the current observation time.

HID++ response parsing validates the exact report length, device index, feature index, function/software-ID byte, and parameter bounds. Percentages outside `0...100`, unknown discrete-level values, truncated reports, mismatched replies, and HID++ error packets do not become battery levels.

## Identity, Merging, and Priority

A direct device's HID identity uses its serial number when available, with transport/product/location information as a fallback. A receiver child uses the receiver identity plus its device index so two devices on one receiver cannot collapse into one row.

Add `.logitechHID` to `BatterySource` with higher battery-reading priority than `.coreBluetooth`, `.system`, and `.systemProfiler`. Extend name-based normalization so one Logitech HID group may merge with one uniquely matching macOS Bluetooth group even when their transport identifiers differ. Do not merge when more than one group on either side shares the normalized name.

When groups merge, preserve the existing system/Bluetooth stable ID, name, and category where available, while selecting the fresh Logitech HID battery level. Receiver-only devices retain their Logitech stable ID. Existing component-battery behavior remains unchanged because HID++ readings are whole-device values.

## Caching and Lifecycle

Cache device identity and resolved `(feature ID, feature index)` values per physical interface and device index. A successful steady-state refresh should require only the battery request. Invalidate a target's cache after a HID++ invalid-feature error, target disconnect, interface removal, or failed protocol ping. Invalidate the entire interface cache when macOS removes or reconnects the HID device.

The collector registers input-report and removal callbacks only while the underlying interface is open, closes interfaces during teardown, and resumes pending requests with failure when an interface disappears. Cancellation of a collection cancels its timeout work and cannot leave a continuation or device handle retained indefinitely.

## Failure Handling

Treat these as target-local failures and continue collecting other targets:

- an empty or sleeping receiver slot;
- a target that does not speak HID++ 2.0;
- missing `0x1004` and `0x1000` features;
- a voltage-only target;
- a malformed, mismatched, or unsolicited report;
- a HID++ protocol error;
- a request timeout; or
- removal of an interface during collection.

Discovery/open failures are logged without raw serial numbers or report payloads. The HID collector returns an available empty snapshot when no usable Logitech interface can be opened, because HID access is supplemental and must not change the app's Bluetooth-wide empty-state or permission messaging.

## Testing

Use test-driven development and fake transport/platform boundaries; automated tests must not require Logitech hardware.

Protocol and transport tests cover:

- correct 7-byte and 20-byte request framing;
- non-zero software-ID allocation and reply correlation;
- ignoring unrelated unsolicited reports;
- HID++ error decoding;
- timeout, cancellation, interface-removal, and pending-request cleanup; and
- serialized requests on one interface with independent interfaces able to progress concurrently.

Battery reader tests cover:

- dynamic `IRoot.GetFeature` resolution;
- `0x1004` percentage and discrete-level parsing;
- fallback from absent or unusable `0x1004` to `0x1000`;
- `0x1000` level parsing;
- rejection of invalid percentages, unknown levels, and malformed responses;
- voltage-only devices returning no percentage;
- cached steady-state reads; and
- cache invalidation after protocol errors and reconnection.

Discovery and collector tests cover:

- Logitech vendor and HID++ report-capability filtering;
- deduplication of multiple HID collections;
- direct target index `0xFF` and receiver indexes `1...6`;
- independent handling of responsive, empty, sleeping, and malformed receiver slots;
- distinct stable IDs for multiple devices on one receiver;
- omission of unidentified phantom targets;
- known devices producing `nil` levels when appropriate; and
- one failing interface not suppressing readings from another.

Normalizer and integration tests cover:

- `.logitechHID` precedence over existing sources;
- unique same-name merging with a macOS Bluetooth observation;
- refusal to merge ambiguous same-name devices;
- preservation of system identity/category after merging; and
- monitor behavior when the HID collector returns no observations.

Before completion, run the focused tests, the full `swift test` suite, `Tests/Scripts/build-app-tests.sh`, and a release build. If compatible Logitech hardware is available, perform a non-required manual smoke test for one direct device and one receiver-connected device; automated correctness must not depend on that hardware.
