import SwiftUI

// MARK: - Status presentation

extension OnboardingChecks.Status {
    var label: String {
        switch self {
        case .satisfied:     "Ready"
        case .missing:       "Needed"
        case .notDetermined: "Pending"
        case .blocked:       "Blocked"
        case .notApplicable: "Not Applicable"
        }
    }

    var tint: Color {
        switch self {
        case .satisfied:     SP.accent
        case .blocked:       SP.danger
        case .notApplicable: SP.textTertiary
        default:             SP.warning
        }
    }

    /// State is never carried by colour alone, so every resolved state also has
    /// a glyph and the row carries a word.
    var symbol: String {
        switch self {
        case .satisfied:     "checkmark"
        case .blocked:       "xmark"
        case .missing:       "arrow.down"
        case .notDetermined: "questionmark"
        case .notApplicable: "minus"
        }
    }
}

struct StatusDot: View {
    let status: OnboardingChecks.Status

    var body: some View {
        ZStack {
            Circle()
                .fill(status == .satisfied ? status.tint : status.tint.opacity(0.16))
                .frame(width: 18, height: 18)
            if status != .satisfied {
                Circle()
                    .strokeBorder(status.tint.opacity(0.55), lineWidth: 1)
                    .frame(width: 18, height: 18)
            }
            Image(systemName: status.symbol)
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(status == .satisfied ? .black : status.tint)
        }
        .animation(Motion.state, value: status)
        .accessibilityLabel(status.label)
    }
}

// MARK: - Headings and prose

struct StepHeading: View {
    let eyebrow: String
    let title: String
    let subtitle: String
    var status: OnboardingChecks.Status?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            HStack(spacing: Space.sm) {
                Text(eyebrow)
                    .font(Typo.micro)
                    .tracking(1.4)
                    .foregroundStyle(SP.accent)
                if let status, status != .notApplicable {
                    HStack(spacing: Space.xs) {
                        Image(systemName: status.symbol)
                            .font(.system(size: 8, weight: .semibold))
                        Text(status.label)
                    }
                    .font(Typo.micro)
                    .foregroundStyle(status.tint)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(status.tint.opacity(0.13)))
                }
            }
            Text(title)
                .font(Typo.title(28))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Text(subtitle)
                .font(Typo.copy)
                .foregroundStyle(SP.textSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(SP.accent)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.control).fill(SP.accent.opacity(0.10)))
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(Typo.label)
                Text(detail)
                    .font(Typo.caption)
                    .foregroundStyle(SP.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }
}

struct InfoNote: View {
    let icon: String
    var tint: Color = SP.textTertiary
    let text: String

    private var isNeutral: Bool { tint == SP.textTertiary }

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .padding(.top, 1)
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(isNeutral ? SP.textTertiary : tint)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.control)
                .fill(isNeutral ? Color.white.opacity(0.035) : tint.opacity(0.09))
        )
    }
}

// MARK: - Status row

/// One dependency, its live state, and whatever action can resolve it.
struct StatusRow<Action: View>: View {
    let icon: String
    let title: String
    let detail: String
    let status: OnboardingChecks.Status
    @ViewBuilder let action: () -> Action

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(status.isSatisfied ? SP.accent : SP.textSecondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title).font(Typo.label)
                Text(detail)
                    .font(Typo.caption)
                    .foregroundStyle(SP.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Space.sm)
            action()
            StatusDot(status: status)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(SP.surfaceHi))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control).strokeBorder(
                status.isSatisfied ? SP.accent.opacity(0.30) : SP.divider
            )
        )
        .animation(Motion.state, value: status)
    }
}

// MARK: - Copyable shell command

struct CommandBlock: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: Space.md) {
            Text("$")
                .font(Typo.mono)
                .foregroundStyle(SP.textTertiary)
            Text(command)
                .font(Typo.mono)
                .foregroundStyle(SP.textPrimary)
                .textSelection(.enabled)
            Spacer(minLength: Space.sm)
            Button(copied ? "Copied" : "Copy Command") { copy() }
                .buttonStyle(MiniButtonStyle(filled: copied))
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color.black.opacity(0.45)))
        .overlay(RoundedRectangle(cornerRadius: Radius.control).strokeBorder(SP.divider))
    }

    private func copy() {
        OnboardingChecks.copyToClipboard(command)
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            copied = false
        }
    }
}
