import Testing
@testable import OpenClaw

@Suite(.serialized)
@MainActor
struct OnboardingAISetupTests {
    @Test func `candidate failure keeps friendly summary and exact detail`() {
        let failure = OnboardingAISetupModel.failure(
            label: "Codex CLI",
            status: "auth",
            error: "Codex login expired (request 42)")

        #expect(failure.summary == "Codex CLI is installed, but the login didn’t work. Sign in again, then retry.")
        #expect(failure.detail == "Codex login expired (request 42)")
        #expect(failure.copyText == "Codex login expired (request 42)")
    }

    @Test func `candidate failure omits empty detail`() {
        let failure = OnboardingAISetupModel.failure(
            label: "Codex CLI",
            status: "timeout",
            error: "  ")

        #expect(failure.summary == "Codex CLI didn’t answer in time.")
        #expect(failure.detail == nil)
        #expect(failure.copyText == failure.summary)
    }

    @Test func `transport failure preserves original detail`() {
        let failure = OnboardingAISetupModel.transportFailure(
            "Gateway request failed: connection reset")

        #expect(failure.summary == "Gateway request failed: connection reset")
        #expect(failure.detail == "Gateway request failed: connection reset")
    }
}
