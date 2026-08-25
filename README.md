# Batteries Included

Batteries Included is a macOS 14+ menu-bar app that displays battery levels
for currently connected Bluetooth devices and Logitech devices that support
HID++ through a USB receiver or direct USB connection.

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

Battery support is best-effort: macOS, the connected peripheral, or Logitech's
HID++ protocol must expose a battery value. Connected devices without a
readable value remain visible as `Battery unavailable`.
