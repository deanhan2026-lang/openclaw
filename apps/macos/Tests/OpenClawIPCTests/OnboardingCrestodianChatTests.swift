import Foundation
import OpenClawKit
import Testing
@testable import OpenClaw

private actor CrestodianGatewayConfig {
    private var token = "a"

    func snapshotToken() -> String {
        self.token
    }

    func setToken(_ token: String) {
        self.token = token
    }
}

private actor CrestodianSessionRecorder {
    private var sessionIDs: [String] = []

    func record(_ sessionID: String) {
        self.sessionIDs.append(sessionID)
    }

    func snapshot() -> [String] {
        self.sessionIDs
    }
}

private actor CrestodianRequestGate {
    private var consumed = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func waitIfFirst() async -> Bool {
        guard !self.consumed else { return false }
        self.consumed = true
        if !self.released {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
            }
        }
        return true
    }

    func release() {
        self.released = true
        self.continuation?.resume()
        self.continuation = nil
    }
}

private func crestodianSessionID(from message: URLSessionWebSocketTask.Message) -> String? {
    let data: Data? = switch message {
    case let .data(data): data
    case let .string(string): string.data(using: .utf8)
    @unknown default: nil
    }
    guard let data,
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          object["method"] as? String == "crestodian.chat",
          let params = object["params"] as? [String: Any]
    else { return nil }
    return params["sessionId"] as? String
}

private func crestodianResponse(id: String) -> Data {
    Data(
        """
        {
          "type": "res",
          "id": "\(id)",
          "ok": true,
          "payload": {
            "sessionId": "test-session",
            "reply": "ready",
            "action": "none",
            "sensitive": false
          }
        }
        """.utf8)
}

@Suite(.serialized)
@MainActor
struct OnboardingCrestodianChatTests {
    @Test func `gateway reset invalidates queued send and restart tasks`() async throws {
        let session = GatewayTestWebSocketSession()
        let url = try #require(URL(string: "ws://example.invalid"))
        let gateway = GatewayConnection(
            configProvider: { (url: url, token: nil, password: nil) },
            sessionBox: WebSocketSessionBox(session: session))
        let chat = CrestodianOnboardingChatModel(gateway: gateway)
        let state = OnboardingCrestodianChatState()
        state.chat = chat
        var replyCount = 0
        var handoffCount = 0
        chat.onReplyReceived = { replyCount += 1 }
        chat.onAgentHandoff = { handoffCount += 1 }
        chat.input = "route-bound secret"
        state.isPresented = true

        let sendTask = try #require(chat.send())
        let restartTask = try #require(chat.restartAfterError())
        state.resetForGatewayChange()
        await sendTask.value
        await restartTask.value

        #expect(session.snapshotMakeCount() == 0)
        #expect(chat.messages.isEmpty)
        #expect(replyCount == 0)
        #expect(handoffCount == 0)
        #expect(!state.isPresented)
        #expect(state.chat !== chat)
        #expect(chat.send() == nil)
        #expect(chat.restartAfterError() == nil)
    }

    @Test func `chat session stays bound to its original gateway route`() async throws {
        let config = CrestodianGatewayConfig()
        let recorder = CrestodianSessionRecorder()
        let session = GatewayTestWebSocketSession(taskFactory: {
            GatewayTestWebSocketTask(sendHook: { task, message, sendIndex in
                guard sendIndex > 0,
                      let id = GatewayWebSocketTestSupport.requestID(from: message)
                else { return }
                if let sessionID = crestodianSessionID(from: message) {
                    await recorder.record(sessionID)
                }
                task.emitReceiveSuccess(.data(crestodianResponse(id: id)))
            })
        })
        let url = try #require(URL(string: "ws://example.invalid"))
        let gateway = GatewayConnection(
            configProvider: {
                let token = await config.snapshotToken()
                return (url: url, token: token, password: nil)
            },
            sessionBox: WebSocketSessionBox(session: session))
        let chat = CrestodianOnboardingChatModel(gateway: gateway)

        await chat.startIfNeeded()
        #expect(chat.messages.map(\.text) == ["ready"])
        #expect(session.snapshotMakeCount() == 1)
        #expect(session.latestTask()?.snapshotSendCount() == 2)
        let routeASessionIDs = await recorder.snapshot()
        #expect(routeASessionIDs.count == 1)
        let routeASessionID = try #require(routeASessionIDs.first)

        await config.setToken("b")
        chat.input = "must stay on route a"
        let sendTask = try #require(chat.send())
        await sendTask.value

        #expect(session.snapshotMakeCount() == 1)
        #expect(session.latestTask()?.snapshotSendCount() == 2)
        #expect(chat.messages.map(\.text) == ["ready", "must stay on route a"])
        #expect(chat.errorMessage == "The Gateway connection changed. Restart Crestodian to reconnect.")
        #expect(await recorder.snapshot() == [routeASessionID])

        let restartTask = try #require(chat.restartAfterError())
        await restartTask.value

        #expect(session.snapshotMakeCount() == 2)
        #expect(session.latestTask()?.snapshotSendCount() == 2)
        #expect(chat.messages.map(\.text) == ["ready"])
        #expect(chat.errorMessage == nil)
        let sessionIDs = await recorder.snapshot()
        #expect(sessionIDs.count == 2)
        #expect(sessionIDs.first == routeASessionID)
        #expect(sessionIDs.last != routeASessionID)
    }

    @Test func `cancelled initial request exposes restart and recovers`() async throws {
        let requestGate = CrestodianRequestGate()
        let session = GatewayTestWebSocketSession(taskFactory: {
            GatewayTestWebSocketTask(sendHook: { task, message, sendIndex in
                guard sendIndex > 0,
                      let id = GatewayWebSocketTestSupport.requestID(from: message)
                else { return }
                if sendIndex == 1, await requestGate.waitIfFirst() {
                    throw CancellationError()
                }
                task.emitReceiveSuccess(.data(crestodianResponse(id: id)))
            })
        })
        let url = try #require(URL(string: "ws://example.invalid"))
        let gateway = GatewayConnection(
            configProvider: { (url: url, token: nil, password: nil) },
            sessionBox: WebSocketSessionBox(session: session))
        let chat = CrestodianOnboardingChatModel(gateway: gateway)

        let startTask = Task { await chat.startIfNeeded() }
        var requestStarted = false
        for _ in 0..<1000 {
            if session.latestTask()?.snapshotSendCount() == 2 {
                requestStarted = true
                break
            }
            await Task.yield()
        }
        try #require(requestStarted)
        startTask.cancel()
        await requestGate.release()
        await startTask.value

        #expect(chat.errorMessage == "Crestodian was interrupted. Restart to try again.")
        #expect(!chat.isSending)
        #expect(chat.messages.isEmpty)

        let restartTask = try #require(chat.restartAfterError())
        await restartTask.value

        #expect(chat.errorMessage == nil)
        #expect(chat.messages.map(\.text) == ["ready"])
        #expect(session.snapshotMakeCount() == 2)
        #expect(session.latestTask()?.snapshotSendCount() == 2)
    }
}
