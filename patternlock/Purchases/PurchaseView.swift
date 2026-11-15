import SwiftUI
import UIKit

struct PurchaseView: View {
    let offer: PurchaseOffer
    let purchases: PurchaseStore
    let close: () -> Void
    let showRegularOffer: () -> Void
    @State private var scene: UIWindowScene?

    private var isSpecial: Bool { offer == .special }
    private var product: LifetimeProduct? { isSpecial ? purchases.specialProduct : purchases.product }
    private var loadingPrice: Bool { isSpecial ? purchases.loadingSpecialProduct : purchases.loadingProduct }
    private var ink: Color { isSpecial ? .white : AlbumTheme.ink }
    private var secondary: Color { isSpecial ? .white.opacity(0.78) : AlbumTheme.secondary }
    private var accent: Color { isSpecial ? SpecialOfferStyle.gold : AlbumTheme.accent }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    hero
                    benefitsCard
                    purchaseControls
                    if isSpecial, !purchases.isUnlimited { countdown }
                    feedback
                    Button(purchases.isRestoring ? String(localized: "Restoring…") : String(localized: "Restore purchases")) {
                        Task { await purchases.restore() }
                    }.disabled(purchases.busy).accessibilityIdentifier("restorePurchases")
                    Text(String(localized: "Your purchase is tied to your Apple Account. Restoring a purchase restores Unlimited access; your photos are restored separately from your saved backup."))
                        .font(.caption).foregroundStyle(secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .foregroundStyle(ink)
            .background {
                if isSpecial { SpecialOfferBackdrop() }
                else { AlbumTheme.background.ignoresSafeArea() }
            }
            .navigationTitle(isSpecial ? String(localized: "Pro Special Offer") : "Pattern Unlimited")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(isSpecial ? SpecialOfferStyle.plum : AlbumTheme.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(isSpecial ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close"), action: close)
                        .disabled(purchases.busy || purchases.status == .checking)
                        .accessibilityIdentifier("closePurchaseOffer")
                }
            }
            .background(PurchaseSceneReader { scene = $0 })
            .task {
                await purchases.start()
                if purchases.isUnlimited { close(); return }
                async let regular: Void = purchases.loadProduct()
                async let special: Void = purchases.loadSpecialProduct()
                _ = await (regular, special)
            }
            .onChange(of: purchases.isUnlimited) { _, purchased in
                // PurchaseStore finishes the verified transaction before enabling Close.
                if purchased && !purchases.busy { close() }
            }
            .onChange(of: purchases.busy) { _, busy in
                if !busy && purchases.isUnlimited { close() }
            }
        }
        .tint(accent)
        // Scope the offer's appearance to its own content. A presentation-level
        // preference can leave the presenting settings sheet in dark appearance.
        .environment(\.colorScheme, isSpecial ? .dark : .light)
        .interactiveDismissDisabled()
        .presentationDragIndicator(.hidden)
    }

    private var hero: some View {
        VStack(spacing: 16) {
            if isSpecial {
                SpecialOfferArtwork().frame(height: 96)
            } else {
                Image(systemName: purchases.isUnlimited ? "checkmark.seal" : "sparkles.rectangle.stack")
                    .font(.system(size: 50, weight: .ultraLight)).foregroundStyle(accent).padding(.top, 12)
            }
            Text(purchases.isUnlimited ? String(localized: "All yours.") : (isSpecial ? String(localized: "A special price.\nAll of Pro.") : String(localized: "More room.\nOne purchase.")))
                .font(.system(size: 32, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
            Text(purchases.isUnlimited ? String(localized: "Pattern Unlimited is unlocked.") : String(localized: "Unlimited vaults, items, and sharing.\nPay once. No subscription."))
                .font(.subheadline).foregroundStyle(secondary).multilineTextAlignment(.center)
        }
    }

    @ViewBuilder private var purchaseControls: some View {
        if purchases.isUnlimited {
            Label(String(localized: "One-time purchase"), systemImage: "checkmark.circle.fill").foregroundStyle(accent)
            Button(String(localized: "Done"), action: close).buttonStyle(.borderedProminent)
        } else {
            VStack(spacing: 14) {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let expired = isSpecial && purchases.specialOffers.remainingSeconds(at: context.date) == 0
                    if isSpecial, !expired, let discount = purchases.specialDiscount {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 12) { regularPrice(discount); savingsBadge(discount) }
                            VStack(spacing: 8) { regularPrice(discount); savingsBadge(discount) }
                        }
                        .accessibilityIdentifier("specialOfferDiscount")
                    }
                    Button {
                        Task { await purchases.purchase(in: scene, offer: offer) }
                    } label: {
                        HStack(spacing: 10) {
                            if purchases.isPurchasing { ProgressView().tint(.white) }
                            Text(expired ? String(localized: "Special offer ended") : (product.map { String(localized: "Unlock once · \($0.displayPrice)") } ?? (loadingPrice ? String(localized: "Loading price…") : String(localized: "Purchase unavailable"))))
                                .font(.headline)
                            if isSpecial && !expired { Image(systemName: "sparkles").accessibilityHidden(true) }
                        }
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 22).padding(.vertical, 20)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .foregroundStyle(.white)
                        .background {
                            Capsule().fill(LinearGradient(colors: [SpecialOfferStyle.red, SpecialOfferStyle.deepRed], startPoint: .topLeading, endPoint: .bottomTrailing))
                        }
                        .overlay { Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1) }
                        .shadow(color: SpecialOfferStyle.red.opacity(isSpecial ? 0.4 : 0.18), radius: isSpecial ? 18 : 8, y: 6)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .disabled(expired || product == nil || purchases.busy || purchases.status == .checking)
                    .opacity(expired || product == nil ? 0.5 : 1)
                    .accessibilityIdentifier(isSpecial ? "buySpecialOffer" : "buyUnlimited")
                    if expired {
                        Button(String(localized: "View regular offer"), action: showRegularOffer).disabled(purchases.busy)
                    }
                }
                if loadingPrice { ProgressView(String(localized: "Loading App Store price…")) }
                if product == nil && !loadingPrice {
                    Button(String(localized: "Try loading price again")) {
                        Task {
                            if isSpecial { await purchases.loadSpecialProduct() }
                            else { await purchases.loadProduct() }
                        }
                    }
                }
            }
        }
    }

    private func regularPrice(_ discount: SpecialOfferDiscount) -> some View {
        Text(discount.regularDisplayPrice).strikethrough()
            .font(.subheadline).foregroundStyle(secondary)
            .accessibilityLabel(String(localized: "Regular price: \(discount.regularDisplayPrice)"))
    }

    private func savingsBadge(_ discount: SpecialOfferDiscount) -> some View {
        Text(String(localized: "Save \(discount.formattedPercentage)"))
            .font(.subheadline.weight(.bold)).foregroundStyle(SpecialOfferStyle.plum)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(SpecialOfferStyle.gold, in: Capsule())
    }

    private var countdown: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let remaining = purchases.specialOffers.remainingSeconds(at: context.date)
            Label(remaining > 0 ? String(localized: "Offer ends in \(SpecialOfferStore.countdown(remaining))") : String(localized: "Special offer ended"), systemImage: "timer")
                .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(accent)
                .padding(.horizontal, 18).padding(.vertical, 10)
                .background(accent.opacity(0.1), in: Capsule())
                .overlay { Capsule().strokeBorder(accent.opacity(0.3), lineWidth: 1) }
                .accessibilityIdentifier("specialOfferCountdown")
        }
    }

    private var benefitsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(String(localized: "Included with Pattern Unlimited"))
                .font(.headline)
            benefit(String(localized: "Unlimited vaults"), icon: "rectangle.stack",
                    detail: String(localized: "Free: 3 vaults."))
            Divider().overlay(ink.opacity(0.12))
            benefit(String(localized: "Unlimited items per vault"), icon: "photo.stack",
                    detail: String(localized: "Free: 5 items per vault."))
            Divider().overlay(ink.opacity(0.12))
            benefit(String(localized: "Create and share vaults"), icon: "person.2",
                    detail: String(localized: "Share over iCloud with a private phrase. Set expiration dates, open limits, export permissions, and locking on screen capture."))
            Text(String(localized: "Opening a shared vault is free."))
                .font(.caption).foregroundStyle(secondary)
        }.padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("unlimitedBenefits")
            .background {
                if isSpecial {
                    RoundedRectangle(cornerRadius: 22).fill(.white.opacity(0.08))
                        .overlay { RoundedRectangle(cornerRadius: 22).strokeBorder(SpecialOfferStyle.gold.opacity(0.25), lineWidth: 1) }
                } else {
                    Color.clear.vaultMetalSurface(in: RoundedRectangle(cornerRadius: 22))
                }
            }
    }

    @ViewBuilder private var feedback: some View {
        if let message = purchases.message { Text(message).font(.subheadline).multilineTextAlignment(.center) }
        if let error = purchases.error { Text(error).font(.subheadline).foregroundStyle(isSpecial ? Color(red: 1, green: 0.72, blue: 0.72) : .red).multilineTextAlignment(.center) }
        if isSpecial, let error = purchases.specialProductError { Text(error).font(.subheadline).foregroundStyle(Color(red: 1, green: 0.72, blue: 0.72)).multilineTextAlignment(.center) }
    }

    private func benefit(_ title: String, icon: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(accent)
                .frame(width: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(secondary)
            }.fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .combine)
    }
}

private struct PurchaseSceneReader: UIViewRepresentable {
    let update: (UIWindowScene?) -> Void
    func makeUIView(context: Context) -> SceneView { let view = SceneView(); view.update = update; return view }
    func updateUIView(_ view: SceneView, context: Context) { view.update = update }
    final class SceneView: UIView {
        var update: ((UIWindowScene?) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            let scene = window?.windowScene
            Task { @MainActor [weak self] in self?.update?(scene) }
        }
    }
}
