import SwiftUI

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.state = .active
        view.blendingMode = .behindWindow
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
    }
}

struct PanelView: View {
    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)
            Text("Nickel")
                .font(.title2)
                .foregroundStyle(.secondary)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
