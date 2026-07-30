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
    @EnvironmentObject private var store: CapturedStore

    var body: some View {
        ZStack {
            VisualEffectBackground(material: .hudWindow)

            if store.items.isEmpty {
                Text("Nickel")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(store.items.reversed()) { item in
                            CapturedCard(item: item)
                        }
                    }
                    .padding(12)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

private struct CapturedCard: View {
    let item: CapturedStore.Item

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.text)
                .font(.system(size: 13))
                .lineLimit(4)
                .foregroundStyle(.primary)

            if let app = item.app {
                Text(app)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.white.opacity(0.08)))
    }
}
