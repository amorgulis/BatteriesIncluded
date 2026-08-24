# Private Bluetooth Battery Collector Design

## Goal

Display battery percentages that macOS knows but does not expose through the app's existing public sources. The immediate target is the connected `Keychron K1 Max (work)`, whose percentage appears in macOS while `IOBluetoothDevice`, I/O Registry, `system_profiler`, and CoreBluetooth's standard Battery Service do not return it.

## Constraints

- The app may use undocumented Apple APIs and remains a directly distributed app rather than a Mac App Store product.
- The collector must use the app's existing Bluetooth authorization and must not require Full Disk Access, root privileges, or an Apple-only entitlement.
- Existing public collectors remain functional and authoritative.
- Failure of the private API must never prevent the menu from showing other devices.
- The deployment target remains macOS 14.

## Architecture

Add `PrivateBluetoothBatteryCollector` behind the existing `BatteryCollecting` interface. The collector dynamically loads the relevant Apple private Bluetooth framework and resolves classes and selectors at runtime. The production target does not statically link private framework symbols.

Private runtime interaction is isolated behind a narrow bridge protocol. The bridge returns plain device readings containing address, name, connection state, category, and optional whole-device battery percentage. The collector validates and maps those readings into existing `BatteryObservation` values.

The collector is registered with `DeviceMonitor` alongside the current system, CoreBluetooth, and system-profiler collectors.

## Data Flow

1. Resolve the private framework and required runtime entry points.
2. Enumerate Bluetooth devices known to the private manager.
3. Retain only currently connected devices.
4. Normalize Bluetooth addresses to uppercase colon-separated form.
5. Accept only integer battery values in `0...100`.
6. Emit whole-device observations keyed by normalized Bluetooth address.
7. Merge with existing observations through `BatteryNormalizer`.

Public/native readings take precedence when valid. Private readings fill gaps and take precedence over unavailable observations. Device identity remains address-based so a private Keychron reading merges with the existing IOBluetooth keyboard row.

## Failure Handling

The collector returns an available snapshot with no observations when:

- the private framework is absent;
- a class or selector is unavailable;
- enumeration fails;
- access is denied by an unavailable entitlement;
- a device has no valid percentage; or
- macOS changes the private object layout.

Failures are logged without device-sensitive values. No fallback reads protected preference files and no workflow asks the user for Full Disk Access.

Before enabling the collector in app composition, a one-time live diagnostic must demonstrate that the private interface returns the connected Keychron percentage under the app's normal execution privileges. If it cannot, implementation stops and the next design candidate is a Keychron-specific HID adapter.

## Testing

Test the bridge-independent mapping and normalization behavior with controlled readings:

- connected Keychron with a valid percentage;
- disconnected device;
- missing, negative, and greater-than-100 values;
- address normalization;
- private API unavailable;
- missing selectors and runtime failures;
- public source precedence over private readings;
- private reading replacing an unavailable public observation; and
- merging the private reading into the address-based keyboard row.

Use test-driven development for production behavior. Run the focused collector tests, the live Keychron diagnostic, the full Swift test suite, release build, property-list validation, and code-signature verification before delivering the rebuilt app.
