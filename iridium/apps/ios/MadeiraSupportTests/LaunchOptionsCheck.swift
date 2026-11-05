import Foundation

@main enum LaunchOptionsCheck {
    static func main() {
        for option in MadeiraResolution.allCases {
            precondition(option.rawValue * 9 == option.height * 16)
            precondition(option.isPreset)
            precondition(option.size.width == Double(option.rawValue))
            precondition(option.size.height == Double(option.height))
        }
        precondition(MadeiraResolution.allCases.map(\.rawValue) == [640, 960, 1280, 1920])
        precondition(MadeiraResolution(rawValue: 0) == nil)
        precondition(MadeiraResolution(rawValue: 100_000) == nil)
        precondition(MadeiraResolution(rawValue: 1280)?.height == 720)

        // Custom sizes: even, inside the ranges, any shape.
        let custom = MadeiraResolution(customWidth: 1099, height: 619)
        precondition(custom?.rawValue == 1098 && custom?.height == 618 && custom?.isPreset == false)
        precondition(MadeiraResolution(customWidth: 1280, height: 1024)?.title == "1280 × 1024")
        precondition(MadeiraResolution(customWidth: 1280, height: 720)?.isPreset == true)
        precondition(MadeiraResolution(customWidth: 319, height: 720) == nil)
        precondition(MadeiraResolution(customWidth: 3842, height: 720) == nil)
        precondition(MadeiraResolution(customWidth: 1280, height: 238) == nil)
        precondition(MadeiraResolution(customWidth: 1280, height: 2162) == nil)

        // The saved setting: presets keep working; a saved height selects a custom size.
        let defaults = UserDefaults.standard
        defer {
            defaults.removeObject(forKey: MadeiraResolution.key)
            defaults.removeObject(forKey: MadeiraResolution.heightKey)
        }
        func choose(_ width: Int, _ height: Int?) -> MadeiraResolution {
            defaults.set(width, forKey: MadeiraResolution.key)
            if let height { defaults.set(height, forKey: MadeiraResolution.heightKey) }
            else { defaults.removeObject(forKey: MadeiraResolution.heightKey) }
            return MadeiraResolution.selected
        }
        defaults.removeObject(forKey: MadeiraResolution.key)
        defaults.removeObject(forKey: MadeiraResolution.heightKey)
        precondition(MadeiraResolution.selected == .standard)
        precondition(choose(1280, nil).height == 720)
        precondition(choose(1280, 0).height == 720)
        precondition(choose(700, nil) == .standard)
        let saved = choose(1366, 768)
        precondition(saved.rawValue == 1366 && saved.height == 768)
        precondition(choose(100, 768) == .standard)
        precondition(choose(1366, 100) == .standard)
        print("Resolution dimensions passed")
    }
}
