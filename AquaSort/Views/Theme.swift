import SwiftUI

extension Color {
    // Arcade palette: deep cabinet blues, bright screen tones, and high-energy controls.
    static let gbInk = Color(red: 0.04, green: 0.12, blue: 0.18)
    static let gbDeep = Color(red: 0.07, green: 0.23, blue: 0.34)
    static let gbMid = Color(red: 0.24, green: 0.58, blue: 0.70)
    static let gbLight = Color(red: 0.98, green: 0.99, blue: 0.94)
    static let gbGlow = Color(red: 0.25, green: 0.91, blue: 0.78)
    static let plastic = Color(red: 0.025, green: 0.07, blue: 0.13)
    static let plasticRaised = Color(red: 0.08, green: 0.29, blue: 0.42)
    static let plasticHighlight = Color(red: 0.18, green: 0.46, blue: 0.58)
    static let amber = Color(red: 1.0, green: 0.76, blue: 0.08)
    static let linkedOrange = Color(red: 1.0, green: 0.32, blue: 0.12)
    static let arcadeRed = Color(red: 0.96, green: 0.12, blue: 0.20)
    static let arcadePurple = Color(red: 0.56, green: 0.23, blue: 0.92)
    static let arcadePink = Color(red: 1.0, green: 0.24, blue: 0.62)

    static let drumKick = Color(red: 1.0, green: 0.30, blue: 0.12)
    static let drumSnare = Color(red: 0.20, green: 0.58, blue: 0.94)
    static let drumHiHat = Color(red: 0.18, green: 0.88, blue: 0.68)
    static let drumPerc = Color(red: 1.0, green: 0.72, blue: 0.08)
    static let mutedText = Color(red: 0.54, green: 0.76, blue: 0.80)

    static let screen = Color(red: 0.84, green: 0.98, blue: 0.88)
    static let screenShadow = Color(red: 0.18, green: 0.42, blue: 0.43)
}

struct PocketBackdrop: View {
    var body: some View {
        ZStack {
            Color.plastic
            LinearGradient(
                colors: [Color.gbDeep.opacity(0.78), Color.plastic, Color.arcadePurple.opacity(0.18)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            RadialGradient(
                colors: [Color.gbGlow.opacity(0.18), Color.clear],
                center: .topTrailing,
                startRadius: 10,
                endRadius: 330
            )
            Canvas { context, size in
                for x in stride(from: 0, through: size.width, by: 6) {
                    context.fill(
                        Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                        with: .color(Color.gbGlow.opacity(0.025))
                    )
                }
                for y in stride(from: 0, through: size.height, by: 6) {
                    context.fill(
                        Path(CGRect(x: 0, y: y, width: size.width, height: 1)),
                        with: .color(Color.white.opacity(0.012))
                    )
                }
            }
            .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

struct ArcadePressStyle: ButtonStyle {
    var scale: CGFloat = 0.94

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.spring(response: 0.18, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

struct ArcadeShell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.plastic.opacity(0.88))
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color.plasticHighlight.opacity(0.72), lineWidth: 2)
                    )
                    .shadow(color: Color.black.opacity(0.45), radius: 18, y: 10)
            )
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
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
                        .tracking(1.1)
                        .lineLimit(1)
                        .minimumScaleFactor(0.68)
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
                colors: [Color.screen, Color.gbLight, Color.screen.opacity(0.94)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gbInk.opacity(0.72), lineWidth: 2)
        )
        .overlay(alignment: .top) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.48), lineWidth: 1)
                .padding(2)
                .allowsHitTesting(false)
        }
        .shadow(color: Color.black.opacity(0.28), radius: 5, y: 3)
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
                        .font(.system(size: 13, weight: .black))
                }
                Text(title)
                    .font(.system(size: 12, weight: .black, design: .monospaced))
                    .tracking(0.5)
            }
            .foregroundStyle(Color.gbInk)
            .padding(.horizontal, 14)
            .frame(minHeight: 38)
            .background(
                LinearGradient(colors: [accent, accent.opacity(0.78)], startPoint: .top, endPoint: .bottom)
            )
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.gbInk, lineWidth: 2)
            )
            .shadow(color: Color.black.opacity(0.25), radius: 3, y: 3)
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
