import SwiftUI

extension Color {
    // Future-retro hardware palette: charcoal chassis, warm Roland-style orange, and LCD green.
    static let gbInk = Color(red: 0.055, green: 0.070, blue: 0.075)
    static let gbDeep = Color(red: 0.105, green: 0.135, blue: 0.145)
    static let gbMid = Color(red: 0.30, green: 0.37, blue: 0.38)
    static let gbLight = Color(red: 0.95, green: 0.96, blue: 0.90)
    static let gbGlow = Color(red: 0.55, green: 0.86, blue: 0.63)
    static let plastic = Color(red: 0.045, green: 0.052, blue: 0.058)
    static let plasticRaised = Color(red: 0.125, green: 0.145, blue: 0.155)
    static let plasticHighlight = Color(red: 0.28, green: 0.31, blue: 0.32)
    static let amber = Color(red: 1.0, green: 0.48, blue: 0.06)
    static let linkedOrange = Color(red: 1.0, green: 0.25, blue: 0.05)
    static let arcadeRed = Color(red: 0.92, green: 0.12, blue: 0.10)
    static let arcadePurple = Color(red: 0.30, green: 0.21, blue: 0.43)
    static let arcadePink = Color(red: 0.92, green: 0.22, blue: 0.39)

    static let drumKick = Color(red: 0.94, green: 0.25, blue: 0.10)
    static let drumSnare = Color(red: 0.25, green: 0.55, blue: 0.88)
    static let drumHiHat = Color(red: 0.25, green: 0.78, blue: 0.55)
    static let drumPerc = Color(red: 0.95, green: 0.58, blue: 0.08)
    static let mutedText = Color(red: 0.62, green: 0.68, blue: 0.65)

    static let screen = Color(red: 0.78, green: 0.88, blue: 0.70)
    static let screenShadow = Color(red: 0.25, green: 0.36, blue: 0.26)
    static let panelLine = Color.white.opacity(0.12)
    static let panelInset = Color.black.opacity(0.26)
}

struct PocketBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.08, green: 0.09, blue: 0.10), Color.plastic, Color(red: 0.025, green: 0.028, blue: 0.032)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.amber.opacity(0.10), Color.clear],
                center: .topTrailing,
                startRadius: 5,
                endRadius: 280
            )
            RadialGradient(
                colors: [Color.gbGlow.opacity(0.06), Color.clear],
                center: .bottomLeading,
                startRadius: 10,
                endRadius: 340
            )
            // A quiet hardware grain keeps the cabinet dimensional without competing with controls.
            Canvas { context, size in
                for y in stride(from: 0, through: size.height, by: 8) {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(Color.white.opacity(0.018))
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct ArcadePressStyle: ButtonStyle {
    var scale: CGFloat = 0.96

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.035 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.76), value: configuration.isPressed)
    }
}

struct ArcadeShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.plasticRaised.opacity(0.72), Color.plastic.opacity(0.96)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.plasticHighlight.opacity(0.72), lineWidth: 1.5)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.035), lineWidth: 1)
                            .padding(3)
                    )
                    .shadow(color: Color.black.opacity(0.48), radius: 20, y: 12)
            )
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

struct LCDPanel<Content: View>: View {
    let title: String?
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 10, weight: .black, design: .monospaced))
                        .tracking(0.9)
                        .lineLimit(1)
                        .minimumScaleFactor(0.62)
                        .foregroundStyle(Color.gbInk.opacity(0.82))
                    Rectangle()
                        .fill(Color.screenShadow.opacity(0.45))
                        .frame(height: 2)
                }
                .padding(.bottom, 1)
            }
            content()
        }
        .padding(10)
        .background(
            LinearGradient(
                colors: [Color.screen, Color.gbLight, Color.screen.opacity(0.92)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.gbInk.opacity(0.72), lineWidth: 1.5)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.white.opacity(0.48), lineWidth: 1)
                .padding(2)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.30), radius: 6, y: 3)
    }
}

struct PixelButton: View {
    let title: String
    let systemImage: String?
    let accent: Color
    let action: () -> Void

    init(_ title: String, systemImage: String? = nil, accent: Color = .gbLight, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .black))
                }
                Text(title)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(0.4)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .foregroundStyle(Color.gbInk)
            .padding(.horizontal, 14)
            .frame(minWidth: 44, minHeight: 44)
            .background(
                LinearGradient(colors: [accent, accent.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.gbInk, lineWidth: 1.5)
            )
            .shadow(color: Color.black.opacity(0.28), radius: 3, y: 2)
        }
        .buttonStyle(ArcadePressStyle())
    }
}

struct LCDText: View {
    let text: String
    let size: CGFloat

    var body: some View {
        Text(text)
            .font(.system(size: size, weight: .black, design: .monospaced))
            .foregroundStyle(Color.gbInk)
    }
}
