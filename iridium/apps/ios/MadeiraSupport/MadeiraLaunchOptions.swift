import Foundation

/// The size of the virtual monitor a game sees. Four 16:9 presets, or a custom
/// width and height. `rawValue` is the width, as it was when this was an enum
/// of the four presets.
struct MadeiraResolution: Equatable {
    /// UserDefaults key for the width (the key the presets always used).
    static let key = "IridiumRenderWidth"
    /// UserDefaults key for a custom height. 0 or unset: the height follows the
    /// width at 16:9 and only the preset widths are accepted.
    static let heightKey = "IridiumRenderHeight"
    static let presetWidths = [640, 960, 1280, 1920]
    static let widthRange = 320...3840
    static let heightRange = 240...2160
    static let standard = MadeiraResolution(width: 960, height: 540)
    static var allCases: [MadeiraResolution] { presetWidths.map { MadeiraResolution(width: $0, height: $0 * 9 / 16) } }

    let rawValue: Int
    let height: Int

    private init(width: Int, height: Int) { rawValue = width; self.height = height }

    /// A 16:9 resolution for a width; nil when the width is outside `widthRange`.
    init?(rawValue: Int) {
        guard Self.widthRange.contains(rawValue) else { return nil }
        self.init(width: rawValue, height: rawValue * 9 / 16)
    }

    /// A custom resolution. Both sizes are rounded down to even numbers; nil
    /// unless they fall inside `widthRange` and `heightRange`.
    init?(customWidth: Int, height: Int) {
        let evenWidth = customWidth & ~1, evenHeight = height & ~1
        guard Self.widthRange.contains(evenWidth), Self.heightRange.contains(evenHeight) else { return nil }
        self.init(width: evenWidth, height: evenHeight)
    }

    /// The saved resolution. A saved height means a custom size; without one
    /// the width must be one of the presets. Anything else is the standard size.
    static var selected: Self {
        let defaults = UserDefaults.standard
        let width = defaults.integer(forKey: key), height = defaults.integer(forKey: heightKey)
        if height > 0 { return Self(customWidth: width, height: height) ?? .standard }
        return presetWidths.contains(width) ? Self(width: width, height: width * 9 / 16) : .standard
    }

    var isPreset: Bool { Self.presetWidths.contains(rawValue) && height == rawValue * 9 / 16 }
    var title: String { "\(rawValue) × \(height)" }
    var size: CGSize { CGSize(width: Double(rawValue), height: Double(height)) }
}
