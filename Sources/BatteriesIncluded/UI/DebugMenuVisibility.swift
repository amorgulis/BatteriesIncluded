import AppKit

/// Keep the opening's modifier choice even when SwiftUI rebuilds menu items.
@MainActor
final class DebugMenuVisibility {
    static let exportTitle = "Export Debug Snapshot…"
    private var observers: [NSObjectProtocol] = []
    private let visibilityByMenu = NSMapTable<NSMenu, NSNumber>.weakToStrongObjects()

    init(modifierFlags: @escaping @MainActor () -> NSEvent.ModifierFlags = { NSEvent.modifierFlags }) {
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didAddItemNotification,
                     NSMenu.didChangeItemNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, let menu = notification.object as? NSMenu else { return }
                    if notification.name == NSMenu.didBeginTrackingNotification {
                        self.visibilityByMenu.setObject(
                            NSNumber(value: modifierFlags().contains(.option)), forKey: menu)
                    }
                    let showsDebug = self.visibilityByMenu.object(forKey: menu)?.boolValue ?? false
                    for item in menu.items where item.title == Self.exportTitle {
                        // Changing hidden state emits another change notification.
                        if item.isHidden == showsDebug {
                            item.isHidden = !showsDebug
                        }
                    }
                }
            })
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
