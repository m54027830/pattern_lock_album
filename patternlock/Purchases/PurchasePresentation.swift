import SwiftUI

@MainActor extension View {
    func purchaseOffer(isPresented: Binding<Bool>, initialOffer: PurchaseOffer = .standard,
                       purchases: PurchaseStore? = nil,
                       onDismiss: (() -> Void)? = nil) -> some View {
        modifier(PurchasePresentation(isPresented: isPresented, initialOffer: initialOffer, onDismiss: onDismiss, purchases: purchases))
    }

    func purchaseOffer(item: Binding<FreeTierLimit?>) -> some View {
        purchaseOffer(isPresented: Binding(get: { item.wrappedValue != nil }, set: {
            if !$0 { item.wrappedValue = nil }
        }))
    }
}

/// Keeps the caller's presentation active across two separate sheet lifecycles.
@MainActor struct PurchasePresentation: ViewModifier {
    @Binding var isPresented: Bool
    let initialOffer: PurchaseOffer
    let onDismiss: (() -> Void)?
    @State private var flow: PurchaseFlow
    let purchases: PurchaseStore

    init(isPresented: Binding<Bool>, initialOffer: PurchaseOffer, onDismiss: (() -> Void)? = nil,
         purchases: PurchaseStore? = nil, flow: PurchaseFlow? = nil) {
        _isPresented = isPresented
        self.initialOffer = initialOffer
        self.onDismiss = onDismiss
        self.purchases = purchases ?? .shared
        _flow = State(initialValue: flow ?? PurchaseFlow(offer: nil))
    }

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
