import SwiftUI
import MusterCore

struct TerminalContainerView: View {
    let checkout: Checkout

    @State private var prInfo: PRInfo?
    @State private var isCheckingPR = false

    var body: some View {
        TerminalView(workingDirectory: checkout.path)
            .id(checkout.path)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    HStack(spacing: 6) {
                        Image(systemName: "terminal")
                            .foregroundStyle(.secondary)

                        BreadcrumbSegment(text: "Muster", isLeaf: false)
                        BreadcrumbSeparator()
                        BreadcrumbSegment(text: checkout.repository?.displayName ?? "—", isLeaf: false)
                        BreadcrumbSeparator()
                        BreadcrumbSegment(text: checkout.name, isLeaf: true)

                        Text(checkout.branch)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 4)
                    }
                }
                .sharedBackgroundVisibility(.hidden)

                ToolbarItem(placement: .primaryAction) {
                    PRButton(checkout: checkout, prInfo: prInfo, isLoading: isCheckingPR)
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
            .task(id: checkout.path) {
                await checkForPR()
            }
    }

    private func checkForPR() async {
        isCheckingPR = true
        prInfo = await PRService.findExistingPR(for: checkout)
        isCheckingPR = false
    }
}

private struct BreadcrumbSegment: View {
    let text: String
    let isLeaf: Bool

    var body: some View {
        Text(text)
            .fontWeight(isLeaf ? .semibold : .regular)
            .foregroundStyle(isLeaf ? .primary : .secondary)
            .lineLimit(1)
    }
}

private struct BreadcrumbSeparator: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

struct PRButton: View {
    let checkout: Checkout
    let prInfo: PRInfo?
    let isLoading: Bool

    var body: some View {
        if isLoading {
            ProgressView()
                .scaleEffect(0.6)
                .frame(width: 20, height: 20)
        } else if let pr = prInfo {
            Button {
                NSWorkspace.shared.open(pr.url)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.pull")
                    Text("#\(pr.number)")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help(pr.title)
        } else if let createURL = PRService.createPRURL(for: checkout, defaultBranch: checkout.repository?.defaultBranch ?? "main") {
            Button {
                NSWorkspace.shared.open(createURL)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus.circle")
                    Text("PR")
                        .font(.caption)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .help("Create Pull Request")
        }
    }
}

#Preview {
    TerminalContainerView(
        checkout: Checkout(
            name: "feature-auth",
            path: "/Users/demo/muster/myrepo/feature-auth",
            branch: "feature/auth"
        )
    )
}
