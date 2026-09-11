import Foundation
#if os(iOS)
import UIKit
#endif

/// Central haptic feedback for the instrument.
/// All calls are safe no-ops on unsupported platforms (unit tests, macOS).
enum Haptics {
    /// Light tick — used for beat-aligned interactions and selection changes.
    static func tap() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    /// Medium thump — used for toggles that change the mix (mute/solo).
    static func toggle() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }

    /// Discrete selection click — used when switching patterns.
    static func selection() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        #endif
    }
}