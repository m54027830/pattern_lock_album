import SwiftUI
import UIKit

/// Adapted from the secure-text-field container in the Mrs. GREEN APPLE app.
/// UIKit does not document protecting arbitrary content this way. Keep the
/// dependency on its canvas hierarchy here and verify it on supported devices.
struct ScreenshotProtectedContent<Content: View>: UIViewControllerRepresentable {
    @Environment(\.self) private var environment
    let content: Content
    var preventsDismissal = false

    func makeUIViewController(context: Context) -> ScreenshotProtectionController<Content> {
        ScreenshotProtectionController(content: content, environment: environment)
    }

    func updateUIViewController(_ controller: ScreenshotProtectionController<Content>, context: Context) {
        controller.host.rootView = ProtectedEnvironmentContent(content: content, values: environment)
        controller.preventsDismissal = preventsDismissal
        controller.updateDismissalPolicy()
    }
}

struct ProtectedEnvironmentContent<Content: View>: View {
    var content: Content
    var values: EnvironmentValues
    var body: some View { content.environment(\.self, values) }
}

final class ScreenshotProtectionController<Content: View>: UIViewController {
    let host: UIHostingController<ProtectedEnvironmentContent<Content>>
    let container = ScreenshotProtectionView()
    var preventsDismissal = false

    init(content: Content, environment: EnvironmentValues) {
        host = UIHostingController(rootView: ProtectedEnvironmentContent(content: content, values: environment))
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .white
        container.frame = view.bounds
        container.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(container)
        addChild(host)
        host.view.backgroundColor = .clear
        container.setContent(host.view)
        host.didMove(toParent: self)
    }

    override var childForStatusBarStyle: UIViewController? { host }
    override var childForStatusBarHidden: UIViewController? { host }
    override var childForHomeIndicatorAutoHidden: UIViewController? { host }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        updateDismissalPolicy()
    }

    func updateDismissalPolicy() {
        var ancestor: UIViewController? = self
        while let controller = ancestor {
            controller.isModalInPresentation = preventsDismissal
            ancestor = controller.parent
        }
    }
}

final class ScreenshotProtectionView: UIView {
    let field = ScreenshotPassthroughTextField()
    private(set) var secureCanvas: UIView?
    private(set) var contentView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .white
        field.isSecureTextEntry = true
        field.backgroundColor = .clear
        field.borderStyle = .none
        field.textColor = .clear
        field.tintColor = .clear
        field.clipsToBounds = true
        field.isAccessibilityElement = false
        addSubview(field)
        field.frame = bounds
        field.layoutIfNeeded()
        // Do not silently fall back to an unprotected subview if UIKit changes.
        secureCanvas = field.subviews.first { String(describing: type(of: $0)).contains("CanvasView") }
        secureCanvas?.isUserInteractionEnabled = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(_ content: UIView) {
        contentView?.removeFromSuperview()
        contentView = content
        guard let secureCanvas else { return }
        secureCanvas.addSubview(content)
        content.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        field.passthroughView = content
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        field.frame = bounds
        field.layoutIfNeeded()
        secureCanvas?.frame = field.bounds
        contentView?.frame = secureCanvas?.bounds ?? .zero
    }
}

final class ScreenshotPassthroughTextField: UITextField {
    weak var passthroughView: UIView?
    override var canBecomeFirstResponder: Bool { false }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard !isHidden, alpha > 0.01, isUserInteractionEnabled,
              bounds.contains(point), let passthroughView else { return nil }
        return passthroughView.hitTest(passthroughView.convert(point, from: self), with: event)
    }
}

extension View {
    func screenshotProtected() -> some View {
        ScreenshotProtectedPresentation(content: self)
    }

    func protectedInteractiveDismissDisabled(_ disabled: Bool = true) -> some View {
        interactiveDismissDisabled(disabled)
            .transformPreference(ScreenshotPresentationKey.self) { $0.preventsDismissal = disabled }
    }

    func protectedPresentationDetents(_ detents: Set<PresentationDetent>) -> some View {
        presentationDetents(detents)
            .transformPreference(ScreenshotPresentationKey.self) { $0.detents = detents }
    }

    func protectedPresentationDragIndicator(_ visibility: Visibility) -> some View {
        presentationDragIndicator(visibility)
            .transformPreference(ScreenshotPresentationKey.self) { $0.dragIndicator = visibility }
    }

    func protectedPreferredColorScheme(_ scheme: ColorScheme?) -> some View {
        preferredColorScheme(scheme)
            .transformPreference(ScreenshotPresentationKey.self) { $0.colorScheme = scheme }
    }

    func protectedSheet<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                      @ViewBuilder content: @escaping () -> Content) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) { content().screenshotProtected() }
    }

    func protectedSheet<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                         @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        sheet(item: item, onDismiss: onDismiss) { content($0).screenshotProtected() }
    }

    func protectedFullScreenCover<Content: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                                @ViewBuilder content: @escaping () -> Content) -> some View {
        fullScreenCover(isPresented: isPresented, onDismiss: onDismiss) { content().screenshotProtected() }
    }

    func protectedFullScreenCover<Item: Identifiable, Content: View>(item: Binding<Item?>, onDismiss: (() -> Void)? = nil,
                                                                   @ViewBuilder content: @escaping (Item) -> Content) -> some View {
        fullScreenCover(item: item, onDismiss: onDismiss) { content($0).screenshotProtected() }
    }
}

/// Presentation preferences need to cross the additional hosting-controller
/// boundary, just like the environment and dismiss action do in the other direction.
private struct ScreenshotProtectedPresentation<Content: View>: View {
    let content: Content
    @State private var presentation = ScreenshotPresentationPreferences()

    var body: some View {
        ScreenshotProtectedContent(content: content.onPreferenceChange(ScreenshotPresentationKey.self) { presentation = $0 },
                                   preventsDismissal: presentation.preventsDismissal ?? false)
            .ignoresSafeArea(.container)
            .interactiveDismissDisabled(presentation.preventsDismissal ?? false)
            .presentationDetents(presentation.detents ?? [.large])
            .presentationDragIndicator(presentation.dragIndicator ?? .automatic)
            .preferredColorScheme(presentation.colorScheme)
    }
}

private struct ScreenshotPresentationPreferences: Equatable {
    var preventsDismissal: Bool?
    var detents: Set<PresentationDetent>?
    var dragIndicator: Visibility?
    var colorScheme: ColorScheme?
}

private struct ScreenshotPresentationKey: PreferenceKey {
    static let defaultValue = ScreenshotPresentationPreferences()
    static func reduce(value: inout ScreenshotPresentationPreferences, nextValue: () -> ScreenshotPresentationPreferences) {
        let next = nextValue()
        if let flag = next.preventsDismissal { value.preventsDismissal = flag }
        if let detents = next.detents { value.detents = detents }
        if let indicator = next.dragIndicator { value.dragIndicator = indicator }
        if let scheme = next.colorScheme { value.colorScheme = scheme }
    }
}
