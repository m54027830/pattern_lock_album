import SwiftUI

struct SpecialOfferBanner: View {
    var isStandalone = true
    @State private var purchases = PurchaseStore.shared
    @State private var showingOffer = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if purchases.status == .free, purchases.specialOffers.showsBanner(at: context.date) {
                Button { showingOffer = true } label: {
                    offerLabel
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: 240, minHeight: 52, alignment: .leading)
                    .foregroundStyle(AlbumTheme.ink)
                    .vaultMetalSurface(in: RoundedRectangle(cornerRadius: 20))
                    .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(AlbumTheme.accent.opacity(0.25), lineWidth: 1) }
                    .shadow(color: AlbumTheme.ink.opacity(0.12), radius: 12, y: 4)
                    .contentShape(RoundedRectangle(cornerRadius: 20))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("specialOfferBanner")
                .accessibilityLabel(String(localized: "Pro Special Offer"))
                .accessibilityValue(String(localized: "Offer ends in \(SpecialOfferStore.countdown(purchases.specialOffers.remainingSeconds(at: context.date)))"))
                .accessibilityHint(String(localized: "View offer"))
                .padding(.horizontal, isStandalone ? 16 : 0)
                .padding(.vertical, isStandalone ? 8 : 0)
                .frame(maxWidth: isStandalone ? .infinity : nil, alignment: .leading)
            }
        }
        .purchaseOffer(isPresented: $showingOffer, initialOffer: .special)
        .onChange(of: purchases.isUnlimited) { _, purchased in if purchased { showingOffer = false } }
    }

    private var offerLabel: some View {
        HStack(spacing: 8) {
            Image(systemName: "tag.fill").foregroundStyle(AlbumTheme.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(localized: "Pro Special Offer")).font(.footnote.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Label(SpecialOfferStore.countdown(purchases.specialOffers.remainingSeconds()), systemImage: "timer")
                    .font(.caption.monospacedDigit()).foregroundStyle(AlbumTheme.secondary)
            }
        }
    }
}
