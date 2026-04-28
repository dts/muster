import Foundation

public enum RemoteHost: Sendable {
    case github(owner: String, repo: String)
    case gitlab(owner: String, repo: String)
    case unknown

    public static func parse(from remoteURL: String) -> RemoteHost {
        var url = remoteURL

        // Normalize URL
        if url.hasSuffix(".git") {
            url = String(url.dropLast(4))
        }

        // SSH format: git@github.com:owner/repo
        if url.hasPrefix("git@github.com:") {
            let path = String(url.dropFirst("git@github.com:".count))
            let parts = path.split(separator: "/")
            if parts.count >= 2 {
                return .github(owner: String(parts[0]), repo: String(parts[1]))
            }
        }

        if url.hasPrefix("git@gitlab.com:") {
            let path = String(url.dropFirst("git@gitlab.com:".count))
            let parts = path.split(separator: "/")
            if parts.count >= 2 {
                return .github(owner: String(parts[0]), repo: String(parts[1]))
            }
        }

        // HTTPS format
        if url.contains("github.com/") {
            if let range = url.range(of: "github.com/") {
                let path = String(url[range.upperBound...])
                let parts = path.split(separator: "/")
                if parts.count >= 2 {
                    return .github(owner: String(parts[0]), repo: String(parts[1]))
                }
            }
        }

        if url.contains("gitlab.com/") {
            if let range = url.range(of: "gitlab.com/") {
                let path = String(url[range.upperBound...])
                let parts = path.split(separator: "/")
                if parts.count >= 2 {
                    return .gitlab(owner: String(parts[0]), repo: String(parts[1]))
                }
            }
        }

        return .unknown
    }
}

public struct PRInfo: Sendable {
    public let number: Int
    public let url: URL
    public let title: String
    public let state: String
}

public enum PRService {
    public static func createPRURL(for checkout: Checkout, defaultBranch: String) -> URL? {
        guard let repo = checkout.repository else { return nil }

        let host = RemoteHost.parse(from: repo.remoteURL)
        let branch = checkout.branch

        switch host {
        case .github(let owner, let repoName):
            // GitHub compare URL for creating PR
            let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
            return URL(string: "https://github.com/\(owner)/\(repoName)/compare/\(defaultBranch)...\(encodedBranch)?expand=1")

        case .gitlab(let owner, let repoName):
            // GitLab merge request URL
            let encodedBranch = branch.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? branch
            return URL(string: "https://gitlab.com/\(owner)/\(repoName)/-/merge_requests/new?merge_request%5Bsource_branch%5D=\(encodedBranch)")

        case .unknown:
            return nil
        }
    }

    public static func findExistingPR(for checkout: Checkout) async -> PRInfo? {
        guard let repo = checkout.repository else { return nil }

        let host = RemoteHost.parse(from: repo.remoteURL)
        let branch = checkout.branch

        switch host {
        case .github(let owner, let repoName):
            return await findGitHubPR(owner: owner, repo: repoName, branch: branch)
        case .gitlab(let owner, let repoName):
            return await findGitLabMR(owner: owner, repo: repoName, branch: branch)
        case .unknown:
            return nil
        }
    }

    private static func findGitHubPR(owner: String, repo: String, branch: String) async -> PRInfo? {
        // Use gh CLI to find PR for branch
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["gh", "pr", "view", branch, "--repo", "\(owner)/\(repo)", "--json", "number,url,title,state"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let number = json["number"] as? Int,
                   let urlString = json["url"] as? String,
                   let url = URL(string: urlString),
                   let title = json["title"] as? String,
                   let state = json["state"] as? String {
                    return PRInfo(number: number, url: url, title: title, state: state)
                }
            }
        } catch {}

        return nil
    }

    private static func findGitLabMR(owner: String, repo: String, branch: String) async -> PRInfo? {
        // Use glab CLI to find MR for branch
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["glab", "mr", "view", branch, "--repo", "\(owner)/\(repo)", "--output", "json"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let iid = json["iid"] as? Int,
                   let urlString = json["web_url"] as? String,
                   let url = URL(string: urlString),
                   let title = json["title"] as? String,
                   let state = json["state"] as? String {
                    return PRInfo(number: iid, url: url, title: title, state: state)
                }
            }
        } catch {}

        return nil
    }
}
