import SwiftUI

/// The game's one typeface: Noto Sans JP (Noto Sans CJK JP), bundled under
/// Resources/Fonts and registered in Info.plist (UIAppFonts). The original draws its
/// text in MS Gothic, which can't be bundled; Noto Sans JP is a free gothic close to it.
enum GameFont {
    static let name = "NotoSansCJKjp-Regular"
}

extension Font {
    /// Text in the game's typeface at a fixed size (sizes here already follow the
    /// window's scale). Only the regular weight is bundled, so heavier weights fall
    /// back to it until a bold face is added to Resources/Fonts.
    static func game(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(GameFont.name, fixedSize: size).weight(weight)
    }
}
