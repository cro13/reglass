import SwiftUI

/// The app icon's glasses picture, with a small badge for the Live Activity's state.
/// The extension has its own copy in its asset catalog.
struct ReGlassMark: View {
    /// The badge's SF Symbol, or nil for none.
    var badge: String?
    var size: CGFloat = 44

    var body: some View {
        let corner = RoundedRectangle(cornerRadius: size * 0.225, style: .continuous)
        Image("ReGlassIcon")
            .resizable()
            .scaledToFill()
            .frame(width: size, height: size)
            .clipShape(corner)
            .overlay {
                // A hairline edge, so the tile holds its shape on any wallpaper.
                corner.strokeBorder(ReGlassAlarmLook.ink.opacity(0.12), lineWidth: 0.5)
            }
            .overlay(alignment: .bottomTrailing) {
                if let badge {
                    Image(systemName: badge)
                        .font(.system(size: size * 0.22, weight: .bold))
                        .foregroundStyle(ReGlassAlarmLook.accentText)
                        .frame(width: size * 0.46, height: size * 0.46)
                        .background(Circle().fill(ReGlassAlarmLook.canvas))
                        .overlay(Circle().strokeBorder(ReGlassAlarmLook.fill, lineWidth: 1))
                        .offset(x: size * 0.12, y: size * 0.12)
                }
            }
            .padding(.trailing, badge == nil ? 0 : size * 0.12)   // room for the badge's overhang
            .accessibilityHidden(true)
    }
}
