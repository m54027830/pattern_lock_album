import SwiftUI

extension View {
    func purchaseOffer(isPresented: Binding<Bool>, initialOffer: PurchaseOffer = .standard,
                       onDismiss: (() -> Void)? = nil) -> some View {
        modifier(PurchasePresentation(isPresented: isPresented, initialOffer: initialOffer, onDismiss: onDismiss))
    }

    func purchaseOffer(item: Binding<FreeTierLimit?>) -> some View {
        purchaseOffer(isPresented: Binding(get: { item.wrappedValue != nil }, set: {
            if !$0 { item.wrappedValue = nil }
        }))
    }
}

/// Keeps the caller's presentation active across two separate sheet lifecycles.
private struct PurchasePresentation: ViewModifier {
    @Binding var isPresented: Bool
    let initialOffer: PurchaseOffer
    let onDismiss: (() -> Void)?
    @State private var flow = PurchaseFlow(offer: nil)
    @State private var purchases = PurchaseStore.shared

    func body(content: Content) -> some View {
        content
            .sheet(item: $flow.offer, onDismiss: {
                if flow.presentationDidDismiss(purchases: purchases) {
                    isPresented = false
                    onDismiss?()
                }
            }) { offer in
                PurchaseView(offer: offer, purchases: purchases,
                             close: { flow.close(purchases: purchases) },
                             showRegularOffer: { flow.showRegularOffer() })
            }
            .onChange(of: isPresented, initial: true) { _, presented in
                if presented { flow.present(initialOffer) }
                else { flow.cancel() }
            }
    }
}
