import SwiftUI

struct StreamingOutputView: View {
    let lines: [String]
    var height: CGFloat = 200

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(idx)
                    }
                }
                .padding(8)
            }
            .frame(height: height)
            .background(Color(NSColor.textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color(NSColor.separatorColor))
            )
            .onChange(of: lines.count) { _, _ in
                if let last = lines.indices.last {
                    proxy.scrollTo(last, anchor: .bottom)
                }
            }
        }
    }
}
