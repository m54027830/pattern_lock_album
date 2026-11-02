import SwiftUI
import UIKit

struct PurchaseView: View {
    var reason: FreeTierLimit?
    @State private var purchases = PurchaseStore.shared
    @State private var scene: UIWindowScene?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    Image(systemName: purchases.isUnlimited ? "checkmark.seal" : "sparkles.rectangle.stack")
                        .font(.system(size: 50, weight: .ultraLight)).foregroundStyle(AlbumTheme.accent).padding(.top, 16)
                    VStack(spacing: 12) {
                        Text(purchases.isUnlimited ? "All yours." : "More room.\nOne purchase.")
                            .font(.system(size: 32, weight: .semibold, design: .rounded)).multilineTextAlignment(.center)
                        Text(purchases.isUnlimited ? "Pattern Unlimited is unlocked." : "Unlimited albums, photos, and videos.\nPay once. No subscription.")
                            .font(.subheadline).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                    }
                    if let reason, !purchases.isUnlimited {
                        Text(reason.localizedDescription).font(.subheadline).multilineTextAlignment(.center)
                            .padding(16).frame(maxWidth: .infinity).background(AlbumTheme.track, in: RoundedRectangle(cornerRadius: 18))
                    }
                    VStack(spacing: 18) {
                        HStack { Text("Included"); Spacer(); Text("Free"); Text("Unlimited").frame(width: 88) }
                            .font(.caption.weight(.semibold)).foregroundStyle(AlbumTheme.secondary)
                        comparison("Albums", free: "3")
                        Divider()
                        comparison("Photos/videos per album", free: "5")
                    }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 22))
                    Text("Each pattern opens one album. Folders share that album’s photo and video limit. All privacy features are included in the free version.")
                        .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                    if purchases.isUnlimited {
                        Label("One-time purchase", systemImage: "checkmark.circle.fill").foregroundStyle(AlbumTheme.accent)
                        Button("Done") { dismiss() }.buttonStyle(.borderedProminent)
                    } else {
                        Button {
                            Task { await purchases.purchase(in: scene) }
                        } label: {
                            HStack {
                                if purchases.isPurchasing { ProgressView().tint(.white) }
                                Text(purchases.product.map { "Unlock once · \($0.displayPrice)" } ?? (purchases.loadingProduct ? "Loading price…" : "Purchase unavailable"))
                                    .font(.headline)
                            }.frame(maxWidth: .infinity).padding(20).foregroundStyle(.white)
                                .background(AlbumTheme.accent, in: RoundedRectangle(cornerRadius: 20))
                        }
                        .disabled(purchases.product == nil || purchases.busy || purchases.status == .checking)
                        .opacity(purchases.product == nil ? 0.5 : 1)
                        .accessibilityIdentifier("buyUnlimited")
                        if purchases.loadingProduct { ProgressView("Loading App Store price…") }
                        if purchases.product == nil && !purchases.loadingProduct {
                            Button("Try loading price again") { Task { await purchases.loadProduct() } }
                        }
                    }
                    if let message = purchases.message { Text(message).font(.subheadline).multilineTextAlignment(.center) }
                    if let error = purchases.error { Text(error).font(.subheadline).foregroundStyle(.red).multilineTextAlignment(.center) }
                    Button(purchases.isRestoring ? "Restoring…" : "Restore purchases") {
                        Task { await purchases.restore() }
                    }.disabled(purchases.busy).accessibilityIdentifier("restorePurchases")
                    Text("Your purchase is tied to your Apple Account. Restoring a purchase restores Unlimited access; your photos are restored separately from your saved backup.")
                        .font(.caption).foregroundStyle(AlbumTheme.secondary).multilineTextAlignment(.center)
                }.padding(24).frame(maxWidth: 540).frame(maxWidth: .infinity)
            }
            .background(AlbumTheme.background)
            .navigationTitle("Pattern Unlimited").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
            .background(PurchaseSceneReader { scene = $0 })
            .task { await purchases.start(); if !purchases.isUnlimited { await purchases.loadProduct() } }
        }.tint(AlbumTheme.accent).preferredColorScheme(.light)
    }

    private func comparison(_ title: String, free: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(free).font(.subheadline.monospacedDigit())
            Image(systemName: "infinity").font(.title3).foregroundStyle(AlbumTheme.accent).frame(width: 88)
                .accessibilityLabel("Unlimited")
        }
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
