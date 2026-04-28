import Foundation
import AppKit
import Observation
import UserNotifications
import MusterCore
import MusterShellProtocol

@MainActor
@Observable
final class AttentionState {
    var unreadBells: Int = 0
    var lastNotification: (title: String?, body: String, at: Date)?
    var currentTitle: String?
    var currentCwd: String?
    var lastExitCode: Int32?
    var hasUnread: Bool { unreadBells > 0 || lastNotification != nil }
}

@MainActor
@Observable
final class AttentionStore {
    static let shared = AttentionStore()

    private(set) var states: [UUID: AttentionState] = [:]
    private var subscribed = false
    private var focusedSessionId: UUID?

    func startIfNeeded() {
        guard !subscribed else { return }
        subscribed = true
        Task { [weak self] in
            for await event in await ShellHostClient.shared.events {
                await self?.handle(event: event)
            }
        }
        requestNotificationPermissionIfNeeded()
    }

    func setFocused(_ checkoutId: UUID?) {
        focusedSessionId = checkoutId
        if let id = checkoutId {
            let s = ensureState(for: id)
            s.unreadBells = 0
            s.lastNotification = nil
            Task { await ShellHostClient.shared.markRead(sessionId: id) }
        }
    }

    /// Read-only accessors — do not create state on read.
    func unreadBells(for checkoutId: UUID) -> Int {
        states[checkoutId]?.unreadBells ?? 0
    }

    func hasUnread(for checkoutId: UUID) -> Bool {
        states[checkoutId]?.hasUnread ?? false
    }

    func currentTitle(for checkoutId: UUID) -> String? {
        states[checkoutId]?.currentTitle
    }

    func lastExitCode(for checkoutId: UUID) -> Int32? {
        states[checkoutId]?.lastExitCode
    }

    private func ensureState(for checkoutId: UUID) -> AttentionState {
        if let s = states[checkoutId] { return s }
        let s = AttentionState()
        states[checkoutId] = s
        return s
    }

    func discard(checkoutId: UUID) {
        states.removeValue(forKey: checkoutId)
        if focusedSessionId == checkoutId { focusedSessionId = nil }
    }

    private func handle(event: AttentionEvent) {
        let st = ensureState(for: event.sessionId)
        let isFocused = (focusedSessionId == event.sessionId) && NSApp.isActive

        switch event.kind {
        case .bell:
            if !isFocused {
                st.unreadBells += 1
                bounceDockIfBackground()
            }
        case .notify(let title, let body):
            st.lastNotification = (title, body, event.timestamp)
            if !isFocused {
                postSystemNotification(title: title ?? "Muster", body: body)
                bounceDockIfBackground()
            }
        case .titleChanged(let t):
            st.currentTitle = t
        case .cwdChanged(let path):
            st.currentCwd = path
        case .promptMark(let kind, let exitCode):
            if kind == .commandEnd, let code = exitCode {
                st.lastExitCode = code
                if code != 0 && !isFocused {
                    bounceDockIfBackground()
                }
            }
        case .exited(let code):
            st.lastExitCode = code
        }
    }

    private func bounceDockIfBackground() {
        guard !NSApp.isActive else { return }
        NSApp.requestUserAttention(.informationalRequest)
    }

    private func postSystemNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }

    private func requestNotificationPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }
}

private extension ShellSession {
    var sessionIdString: String { sessionId.uuidString }
}
