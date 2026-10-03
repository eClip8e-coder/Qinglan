import AppKit
import SwiftUI

enum PanelLayout {
    static let width: CGFloat = 320
    static let collapsedHeight: CGFloat = 452
    static let expandedHeight: CGFloat = 490
    static let cornerRadius: CGFloat = 20
    static let cardInset: CGFloat = 14
    static let cardVerticalInset: CGFloat = 10
    static let gap: CGFloat = 8
    static let outerInset: CGFloat = 10
}

@available(macOS 26.0, *)
private struct NativeModuleGlass<Content: View>: NSViewRepresentable {
    let content: Content
    let colorScheme: ColorScheme

    func makeNSView(context: Context) -> HostedModuleGlass<Content> {
        HostedModuleGlass(content: content, colorScheme: colorScheme)
    }

    func updateNSView(_ view: HostedModuleGlass<Content>, context: Context) {
        view.host.rootView = content
        view.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: HostedModuleGlass<Content>, context: Context) -> CGSize? {
        let width = proposal.width ?? PanelLayout.width - 2 * PanelLayout.outerInset
        let measured = nsView.host.sizeThatFits(in: CGSize(width: max(1, width), height: proposal.height ?? 1000))
        return CGSize(width: width, height: measured.height)
    }
}

@available(macOS 26.0, *)
private final class HostedModuleGlass<Content: View>: NSGlassEffectView {
    let host: NSHostingController<Content>

    init(content: Content, colorScheme: ColorScheme) {
        host = NSHostingController(rootView: content)
        host.sizingOptions = []
        super.init(frame: .zero)
        style = .regular
        appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        // Isolate the non-public variant and restrict it to the tested OS.
        // Other versions retain public regular glass instead of guessing a private ABI.
        let setter = NSSelectorFromString("set_variant:")
        if ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27,
           responds(to: setter), responds(to: NSSelectorFromString("_variant")) {
            let regular = value(forKey: "_variant") as? NSNumber
            style = .clear
            let clear = value(forKey: "_variant") as? NSNumber
            // macOS 27 inserts a variant before the earlier published private mapping.
            // Check both public anchors before selecting the visually verified module material.
            if regular?.intValue == 1, clear?.intValue == 2 {
                setValue(9, forKey: "_variant")
                if (value(forKey: "_variant") as? NSNumber)?.intValue != 9 { style = .regular }
            } else {
                style = .regular
            }
        }
        cornerRadius = PanelLayout.cornerRadius
        tintColor = nil
        if #available(macOS 27.0, *) {
            effectIsInteractive = false
        }
        host.view.wantsLayer = true
        host.view.layer?.backgroundColor = NSColor.clear.cgColor
        // Hosting inside contentView keeps text above the system's refraction layers.
        contentView = host.view
    }

    required init?(coder: NSCoder) { fatalError("Not loaded from a nib") }
}

private struct QuietGlassCard: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var colorScheme
    private let shape = RoundedRectangle(cornerRadius: PanelLayout.cornerRadius, style: .continuous)

    func body(content: Content) -> some View {
        if reduceTransparency {
            content.frame(minHeight: PanelLayout.cornerRadius * 2)
                .background(Color(nsColor: .controlBackgroundColor), in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
        } else if #available(macOS 26.0, *) {
            NativeModuleGlass(content: content
                .frame(minHeight: PanelLayout.cornerRadius * 2)
                .environment(\.colorScheme, colorScheme)
                .background((colorScheme == .dark ? Color.black : Color.white).opacity(0.16), in: shape),
                colorScheme: colorScheme)
                .frame(maxWidth: .infinity)
        } else {
            content.frame(minHeight: PanelLayout.cornerRadius * 2)
                .background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
        }
    }
}

extension View {
    func quietGlassCard() -> some View { modifier(QuietGlassCard()) }
}
