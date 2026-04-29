import SwiftUI

struct OperationSidebarRow: View {
    let operation: Operation

    var body: some View {
        HStack(spacing: 8) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(operation.title)
                    .lineLimit(1)
                if !operation.statusMessage.isEmpty {
                    Text(operation.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch operation.status {
        case .running:
            ProgressView().controlSize(.mini)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}

struct OperationDetailView: View {
    let operation: Operation
    @Binding var selection: SidebarSelection?
    @State private var store = OperationStore.shared

    private func dismissAndSelectNext() {
        let operations = store.operations
        if let currentIndex = operations.firstIndex(where: { $0 === operation }) {
            if currentIndex + 1 < operations.count {
                selection = .operation(operations[currentIndex + 1])
            } else if currentIndex > 0 {
                selection = .operation(operations[currentIndex - 1])
            } else {
                selection = nil
            }
        }
        store.dismiss(operation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(operation.title)
                        .fontWeight(.medium)
                    if let subtitle = operation.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if !operation.statusMessage.isEmpty {
                        Text(operation.statusMessage)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    if case .failed(let reason) = operation.status {
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    }
                }
                Spacer()
                if operation.status.isTerminal {
                    Button("Dismiss") {
                        dismissAndSelectNext()
                    }
                    .controlSize(.small)
                }
            }
            .padding(12)
            .background(.bar)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(operation.lines.enumerated()), id: \.offset) { idx, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(idx)
                        }
                    }
                    .padding(10)
                }
                .background(Color(NSColor.textBackgroundColor))
                .onChange(of: operation.lines.count) { _, _ in
                    if let last = operation.lines.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch operation.status {
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .imageScale(.large)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .imageScale(.large)
        }
    }
}
