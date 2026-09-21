# Batteries Included

Batteries Included is a macOS 14+ menu-bar app that displays battery levels
for currently connected Bluetooth devices and Logitech devices that expose
battery information over HID++.

## Requirements

- macOS 14 or later
- Xcode command-line tools with Swift 5.9 or later

## Develop and run

Run the automated suite with:

```bash
swift test
Tests/Scripts/build-app-tests.sh
```

Build a signed app bundle, then launch it with:

```bash
scripts/build-app.sh
open 'dist/Batteries Included.app'
```

The build script uses ad-hoc signing by default, which is appropriate for
local testing. It does not notarize the bundle because notarization
credentials are specific to each distributor.

For Developer ID distribution, supply your signing identity and then submit
the zipped app bundle with your configured notarytool keychain profile:

```bash
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' scripts/build-app.sh
rm -f 'dist/Batteries Included.app.zip'
ditto -c -k --keepParent 'dist/Batteries Included.app' 'dist/Batteries Included.app.zip'
xcrun notarytool submit 'dist/Batteries Included.app.zip' --keychain-profile batteries-included --wait
xcrun stapler staple 'dist/Batteries Included.app'
rm -f 'dist/Batteries Included.app.zip'
ditto -c -k --keepParent 'dist/Batteries Included.app' 'dist/Batteries Included.app.zip'
```

The archive submitted to Apple contains the unstapled app. Recreating it after
stapling produces the final distributable archive containing the notarization
ticket.

Battery support is best-effort: macOS and the connected peripheral must expose
a battery value. Logitech HID++ 1.0 and 2.0 devices can report either exact
percentages or coarse levels such as `Good` and `Low`. Bluetooth devices without
a readable value remain visible as `Battery unavailable`.

Supported Logitech reports also expose charging state. The menu shows
`⚡ Charging`, `Fully charged`, or `Discharging` when the device explicitly
reports that state. Unknown or unsupported charging state adds no indicator;
a 100% battery level alone does not imply that charging has completed.
Charging status refreshes with battery levels (every 30 seconds or via Refresh).

Bluetooth charging support uses two sources when available:

- The optional BLE Battery Level Status characteristic (`0x2BED`) reports
  charging or discharging directly. Devices exposing only Battery Level
  (`0x2A19`) still report percentages, but their charging state is unknown.
- macOS accessory power reports can supply charging/full states for connected
  Bluetooth accessories, including separate left, right, and case batteries.
  Accessory lookup is optional and checked at runtime because Apple exposes
  it through a private API.

Each component's charging indicator appears beside its own level. Missing,
malformed, or stale status is not inferred from a battery percentage or from
external power alone. Device and firmware support determines which states
are available; this does not make charging detection universal.

Protocol references: [Bluetooth Battery Service 1.1](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/BAS_v1.1/out/en/index-en.html),
[GATT characteristic formats](https://btprodspecificationrefs.blob.core.windows.net/gatt-specification-supplement/GATT_Specification_Supplement.pdf),
and Apple's [accessory power API](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSourcesPrivate.h)
and [accessory keys](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPSKeysPrivate.h).
