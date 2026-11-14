import SwiftUI

struct ClipboardPasteButton: View {
    @Binding var text: String

    var body: some View {
        // The system control reads the clipboard only after an explicit tap.
        PasteButton(payloadType: String.self) { strings in
            guard let pastedText = strings.first else { return }
            text = pastedText
        }
        .labelStyle(.titleAndIcon)
        .buttonBorderShape(.capsule)
        .tint(AlbumTheme.accent)
        .fixedSize()
        .frame(minHeight: 44)
        .accessibilityIdentifier("clipboardPasteButton")
    }
}

private struct ClipboardPasteModifier: ViewModifier {
    @Binding var text: String
    let belowField: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    func body(content: Content) -> some View {
        if belowField || dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .trailing, spacing: 8) {
                content
                ClipboardPasteButton(text: $text)
            }
        } else {
            HStack(spacing: 12) {
                content
                ClipboardPasteButton(text: $text)
            }
        }
    }
}

extension View {
    func clipboardPasteButton(text: Binding<String>, belowField: Bool = false) -> some View {
        modifier(ClipboardPasteModifier(text: text, belowField: belowField))
    }
}
