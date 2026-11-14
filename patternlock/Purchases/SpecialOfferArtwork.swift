import SwiftUI

enum SpecialOfferStyle {
    static let plum = Color(red: 0.19, green: 0.055, blue: 0.18)
    static let gold = Color(red: 1, green: 0.83, blue: 0.46)
    static let red = Color(red: 0.88, green: 0.09, blue: 0.19)
    static let deepRed = Color(red: 0.66, green: 0.025, blue: 0.12)
}

struct SpecialOfferBackdrop: View {
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                LinearGradient(colors: [SpecialOfferStyle.plum, Color(red: 0.35, green: 0.08, blue: 0.20), SpecialOfferStyle.plum], startPoint: .topLeading, endPoint: .bottomTrailing)
                Circle().fill(SpecialOfferStyle.gold.opacity(0.12)).blur(radius: 55)
                    .frame(width: 270, height: 270).position(x: geometry.size.width * 0.85, y: 80)
                Circle().fill(SpecialOfferStyle.red.opacity(0.2)).blur(radius: 65)
                    .frame(width: 300, height: 300).position(x: 20, y: geometry.size.height * 0.7)
            }
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct SpecialOfferArtwork: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Circle().fill(SpecialOfferStyle.gold.opacity(0.25)).frame(width: 100, height: 100).blur(radius: 22)
            Circle().strokeBorder(SpecialOfferStyle.gold.opacity(0.25), lineWidth: 1).frame(width: 86, height: 86)
            Image(systemName: "gift.fill")
                .font(.system(size: 46, weight: .medium))
                .foregroundStyle(LinearGradient(colors: [.white, SpecialOfferStyle.gold], startPoint: .top, endPoint: .bottom))
                .shadow(color: SpecialOfferStyle.gold.opacity(0.35), radius: 12)
                .phaseAnimator(reduceMotion ? [false] : [false, true]) { content, lifted in
                    content.offset(y: lifted ? -3 : 3).rotationEffect(.degrees(lifted ? -5 : 5))
                } animation: { _ in .easeInOut(duration: 2.8) }
            ForEach(0..<8) { index in
                let angle = Double(index) * .pi / 4
                Image(systemName: index.isMultiple(of: 2) ? "sparkle" : "circle.fill")
                    .font(.system(size: index.isMultiple(of: 2) ? 15 : 4, weight: .light))
                    .foregroundStyle(SpecialOfferStyle.gold)
                    .phaseAnimator(reduceMotion ? [false] : [false, true]) { content, lit in
                        content
                            .opacity(lit ? 1 : 0.45)
                            .scaleEffect(lit ? 1.12 : 0.8)
                            .offset(x: cos(angle) * (lit ? 112 : 100), y: sin(angle) * (lit ? 40 : 34))
                    } animation: { _ in .easeInOut(duration: 1.7 + Double(index) * 0.14) }
            }
        }.frame(maxWidth: .infinity).allowsHitTesting(false).accessibilityHidden(true)
    }
}
