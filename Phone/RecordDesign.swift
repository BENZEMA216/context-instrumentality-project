import SwiftUI
import UIKit

enum RecordDesign {
    static let accent = Color(red: 239 / 255, green: 74 / 255, blue: 61 / 255)
    static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 245 / 255, green: 243 / 255, blue: 239 / 255, alpha: 1)
            : UIColor(red: 37 / 255, green: 35 / 255, blue: 33 / 255, alpha: 1)
    })
    static let background = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 33 / 255, green: 33 / 255, blue: 33 / 255, alpha: 1)
            : UIColor.white
    })
    static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 43 / 255, green: 43 / 255, blue: 43 / 255, alpha: 1)
            : UIColor.white
    })
    static let inset = ink.opacity(0.06)
    static let rule = ink.opacity(0.10)
    static let secondary = ink.opacity(0.64)
    static let good = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 133 / 255, green: 174 / 255, blue: 145 / 255, alpha: 1)
            : UIColor(red: 71 / 255, green: 112 / 255, blue: 94 / 255, alpha: 1)
    })
    static let warning = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 222 / 255, green: 179 / 255, blue: 101 / 255, alpha: 1)
            : UIColor(red: 148 / 255, green: 98 / 255, blue: 22 / 255, alpha: 1)
    })
}

/// A static brand mark. It never implies microphone activity or an audio level.
struct RecordMark: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Circle()
                    .strokeBorder(RecordDesign.ink, lineWidth: max(1, geometry.size.width * 0.035))
                Circle().fill(RecordDesign.ink)
                    .padding(geometry.size.width * 0.22)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

struct RecordPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundStyle(RecordDesign.background)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, minHeight: 54)
            .padding(.horizontal, 16)
            .background(RecordDesign.ink, in: RoundedRectangle(cornerRadius: 17))
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.4)
    }
}

struct RecordSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(RecordDesign.ink)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, minHeight: 48)
            .padding(.horizontal, 16)
            .background(configuration.isPressed ? RecordDesign.inset : .clear,
                        in: RoundedRectangle(cornerRadius: 17))
            .overlay {
                RoundedRectangle(cornerRadius: 17).strokeBorder(RecordDesign.rule)
            }
            .opacity(isEnabled ? 1 : 0.35)
    }
}

extension View {
    func recordListAppearance() -> some View {
        self
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(RecordDesign.background)
            .foregroundStyle(RecordDesign.ink)
            .tint(RecordDesign.ink)
            .listSectionSeparator(.hidden)
    }

    func recordRow() -> some View {
        self
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 7, leading: 24, bottom: 7, trailing: 24))
            .listRowSeparatorTint(RecordDesign.rule)
            .listRowSeparator(.hidden)
    }

    func recordCard() -> some View {
        self
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RecordDesign.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}


/// Compact, independent destination controls shared by the Sync home and picker.
struct CloudConnectionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: String
    let subtitle: String
    let systemImage: String
    var statusSymbol: String? = nil
    var statusColor: Color = RecordDesign.secondary
    var actionTitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            CloudProviderIcon(systemImage: systemImage)
                            Spacer()
                            statusIndicator
                            if actionTitle == nil { chevron }
                        }
                        labels
                        if let actionTitle {
                            Text(actionTitle).font(.caption).foregroundStyle(statusColor)
                        }
                    }
                } else {
                    HStack(spacing: 12) {
                        CloudProviderIcon(systemImage: systemImage)
                        labels
                        statusIndicator
                        if let actionTitle {
                            Text(actionTitle).font(.caption).foregroundStyle(statusColor)
                        } else {
                            chevron
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var labels: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.semibold))
                .foregroundStyle(RecordDesign.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle).font(.caption).foregroundStyle(RecordDesign.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var statusIndicator: some View {
        if let statusSymbol {
            Image(systemName: statusSymbol).font(.system(size: 17))
                .foregroundStyle(statusColor).accessibilityHidden(true)
        }
    }

    private var chevron: some View {
        Image(systemName: "chevron.right").font(.system(size: 11))
            .foregroundStyle(RecordDesign.secondary).accessibilityHidden(true)
    }
}

struct CloudProviderIcon: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage == "triangle" ? "externaldrive" : systemImage)
        .font(.system(size: 23, weight: .regular))
        .foregroundStyle(RecordDesign.ink)
        .frame(width: 40, height: 40)
        .background(RecordDesign.inset, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
    }
}
