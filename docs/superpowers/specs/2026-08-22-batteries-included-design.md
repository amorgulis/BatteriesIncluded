# Batteries Included — Design Specification

## Summary

Batteries Included is a directly distributed macOS 14+ menu-bar app that displays live battery levels for currently connected Bluetooth devices. It supports any device whose battery data can be obtained through Bluetooth services or macOS system properties. Support is best-effort: connected devices without readable battery data remain visible and are labeled `Battery unavailable`.

The first release focuses on a fast, readable status menu. It does not include battery notifications, history, disconnected devices, a settings window, or a Dock icon.

## Product Experience

The app runs as a menu-bar-only application. Its menu-bar item uses a simple battery/accessory symbol. Opening the menu immediately requests fresh readings and presents one row per currently connected Bluetooth device.

Each row contains:

- An icon representing the device category when known.
- The device's display name.
- A battery percentage when available.
- A secondary component line for multi-component devices, such as `Left 82% · Right 76% · Case 64%`.

Devices without readable battery information show `Battery unavailable`. When no Bluetooth devices are connected, the menu shows `No Bluetooth devices connected`.

The menu footer contains:

- `Refresh`
- `About Batteries Included`
- `Quit`

Battery data refreshes approximately every 30 seconds while the app is running. Opening the menu or selecting `Refresh` requests an immediate update. The normal refresh mechanism must avoid repeatedly connecting to peripherals solely to obtain a battery reading; it uses system-known values and already-available Bluetooth services.

## Architecture

The app is implemented in Swift as a native macOS 14+ application. SwiftUI provides the menu-bar interface through `MenuBarExtra`, with AppKit integration only where macOS lifecycle or system-settings behavior requires it.

`DeviceMonitor` owns the current presentation state and coordinates independent battery-data collectors. Each collector conforms to a shared protocol and produces source observations without knowledge of the UI.

### CoreBluetoothCollector

`CoreBluetoothCollector` observes Bluetooth Low Energy peripherals and reads the standard Battery Service when it is exposed through an already accessible connection. It reports whole-device or component-specific values when the peripheral supplies enough information to distinguish them.

### SystemBluetoothCollector

`SystemBluetoothCollector` discovers Bluetooth devices macOS considers connected and reads battery properties made available through native macOS Bluetooth and I/O registry facilities. Any use of system interfaces with weaker compatibility guarantees remains isolated in this collector so future macOS changes do not affect the rest of the app.

### BatteryNormalizer

`BatteryNormalizer` merges collector observations into stable device records. It removes duplicates only when identifiers confidently refer to the same physical device, prefers fresh component-specific data over less-specific data, validates percentages, and applies deterministic component ordering.

### DeviceMonitor

`DeviceMonitor` runs collection cycles, passes observations through the normalizer, publishes immutable menu state, and retains the last valid reading only for the duration of a short in-progress refresh. Devices are removed once the current collection confirms they are no longer connected. The app does not persist device history between launches.

## Data Model

A collector observation contains:

- A source-specific device identifier and any stable system identifier available for matching.
- Display name.
- Connected state.
- Optional device category.
- Battery component: whole device, left, right, case, or another source-provided label.
- Optional percentage from 0 through 100.
- Collector source.
- Observation timestamp.

The normalized presentation model groups component readings under one device. Known components appear in the order left, right, case, then any source-provided components in stable alphabetical order. Invalid values are discarded rather than displayed. If all values for a connected device are absent or invalid, the device remains visible with `Battery unavailable`.

When two sources provide the same component, the normalizer selects the freshest valid reading. If their timestamps differ by no more than one second, a direct standard Bluetooth Battery Service value takes precedence over a system-cached value. Readings older than 60 seconds are stale and are not displayed.

## Permissions and Failure Handling

Collector failures are independent. A failure in one collector does not block results from another, crash the app, or remove devices reported successfully elsewhere.

If Bluetooth access is denied, the menu shows a concise permission explanation and an `Open System Settings` action. When Bluetooth is powered off, the empty state explicitly says `Bluetooth is off` instead of implying that no devices exist. Transient read failures preserve the previous fresh value during the active refresh, after which normal staleness rules apply.

Operational details are recorded with Apple's unified logging. Logs must not contain device payloads beyond identifiers and names already visible to the user, and diagnostic information is not shown in the normal menu.

## Distribution

The first release is distributed directly as a signed and notarized app rather than through the Mac App Store. This permits the layered native collection strategy while still delivering a standard macOS installation experience.

## Testing and Acceptance Criteria

Unit tests cover:

- Rejection of percentages outside the inclusive 0–100 range.
- Duplicate-device merging and non-merging when identity is ambiguous.
- Source precedence and freshness behavior.
- Whole-device and component-specific readings.
- Left, right, case, and custom-component ordering.
- Connected, unavailable, empty, Bluetooth-off, and permission-denied menu states.

Collector protocols support deterministic fixture implementations so `DeviceMonitor` and the presentation model can be tested without Bluetooth hardware.

The release candidate is manually verified on macOS 14 or newer with multiple real device types where available, including a standard BLE battery-service device, a multi-component audio device, and a device whose level is supplied by macOS system properties. Verification covers launch, live refresh, manual refresh, connection and disconnection, Bluetooth off/on, denied permission, unavailable battery data, About, and Quit.

The first version is successful when it:

- Runs without a Dock icon and remains available from the menu bar.
- Lists only devices macOS currently reports as connected.
- Shows valid live battery values from either collector without duplicate device rows.
- Shows separate component levels where the source exposes them.
- Keeps unsupported connected devices visible as `Battery unavailable`.
- Handles unavailable collectors, Bluetooth state changes, and permissions without crashing.

## Explicitly Out of Scope

- Low-battery notifications.
- Battery history, charts, or analytics.
- Remembering disconnected or previously seen devices.
- A preferences window or configurable refresh interval.
- Device renaming.
- iOS, iPadOS, or versions of macOS earlier than 14.
- Guaranteed battery support for devices that expose no battery information to macOS or through accessible Bluetooth services.
