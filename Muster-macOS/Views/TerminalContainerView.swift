import SwiftUI
import MusterCore

struct TerminalContainerView: View {
    let checkout: Checkout

    @State private var prInfo: PRInfo?
    @State private var isCheckingPR = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                Text(checkout.name)
                    .fontWeight(.medium)
                Text("•")
                    .foregroundStyle(.secondary)
                Text(checkout.branch)
                    .foregroundStyle(.secondary)

                Spacer()

                PRButton(checkout: checkout, prInfo: prInfo, isLoading: isCheckingPR)

                Text(checkout.path)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(.bar)

            Divider()

            TerminalView(workingDirectory: checkout.path)
        }
        .task {
            await checkForPR()
        }
    }

    private func checkForPR() async {
        isCheckingPR = true
        prInfo = await PRService.findExistingPR(for: checkout)
        isCheckingPR = false
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
