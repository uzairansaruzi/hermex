import WatchKit

enum WatchHaptics {
    static func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}
