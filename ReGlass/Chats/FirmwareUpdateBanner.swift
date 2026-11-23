import ReGlassKit
import SwiftUI

/// The home's offer of a firmware update, under the glasses card: the version, how long it takes, and one tap to the
/// Firmware page, where the update is confirmed and started. "Later" puts it away until Meta offers a newer version.
struct FirmwareUpdateBanner: View {
    let update: FirmwareAvailableUpdate
    let open: () -> Void
    let later: () -> Void
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 34

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: iconSize * 0.62, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: iconSize, height: iconSize)
                .background(Circle().fill(Theme.halo).opacity(0.5))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Update for your glasses")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Text("Version \(update.targetVersion) · \(FirmwareUpdateState.estimate(bytes: update.bytes))")
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
            Spacer(minLength: 0)
            Button("Later", action: later)
                .buttonStyle(QuietButtonStyle())
            Button("View", action: open)
                .buttonStyle(CompactPillStyle(kind: .prominent))
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .contentSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}
