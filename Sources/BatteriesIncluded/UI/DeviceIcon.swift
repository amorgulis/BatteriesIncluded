import SwiftUI

struct DeviceIcon: View {
    let category: DeviceCategory

    var body: some View {
        Image(systemName: Self.symbol(for: category))
    }

    static func symbol(for category: DeviceCategory) -> String {
        switch category {
        case .headphones:
            "headphones"
        case .mouse:
            "computermouse"
        case .keyboard:
            "keyboard"
        case .trackpad:
            "rectangle.and.hand.point.up.left"
        case .gameController:
            "gamecontroller"
        case .other:
            "hifispeaker"
        }
    }
}
