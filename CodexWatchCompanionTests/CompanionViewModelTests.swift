import Foundation
import WatchKit
import XCTest
@testable import CodexWatchCompanion

@MainActor
final class CompanionViewModelTests: XCTestCase {
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var socket: MockSocket!
    private var audio: MockAudio!
    private var runtime: MockRuntimeKeeper!
    private var haptics: MockHaptics!
    private var storedBridgeToken: String?

    override func setUp() {
        super.setUp()
        defaultsSuiteName = "CompanionViewModelTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        socket = MockSocket()
        audio = MockAudio()
        runtime = MockRuntimeKeeper()
        haptics = MockHaptics()
        storedBridgeToken = nil
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        defaults = nil
        defaultsSuiteName = nil
        socket = nil
        audio = nil
        runtime = nil
        haptics = nil
        storedBridgeToken = nil
        super.tearDown()
    }

    func testSendTranscriptSendsTrimmedMessageAndShowsSendingFeedback() {
        let model = makeModel()
        let transcript = VoiceTranscript(title: "Transcript", text: "  Send `inlineCode` now.  ")

        model.sendTranscript(transcript)

        XCTAssertEqual(model.statusTitle, "Sending")
        XCTAssertEqual(model.statusBody, "Send `inlineCode` now.")
        XCTAssertEqual(model.visualState, .running)
        XCTAssertEqual(haptics.played, [.start])
        XCTAssertEqual(socket.sentMessages.last?.type, "transcript-send")
        XCTAssertEqual(socket.sentMessages.last?.text, "Send `inlineCode` now.")
        XCTAssertEqual(socket.sentMessages.last?.state, PetVisualState.running.rawValue)
    }

    func testEmptyTranscriptDoesNotSendAndPlaysFailure() {
        let model = makeModel()

        model.sendTranscript(VoiceTranscript(title: "Transcript", text: "   "))

        XCTAssertTrue(socket.sentMessages.isEmpty)
        XCTAssertEqual(haptics.played, [.failure])
    }

    func testTranscriptEventOpensReviewAndNotifiesOnce() async {
        let model = makeModel()

        socket.emit(BridgeMessage(type: "transcript", title: "Transcript", text: "Hello **watch**."))
        await Task.yield()

        XCTAssertEqual(model.transcriptReview?.text, "Hello **watch**.")
        XCTAssertEqual(model.visualState, .idle)
        XCTAssertEqual(haptics.played, [.notification])
    }

    func testReplyAndFailureStateHapticsAreDeduped() async {
        let model = makeModel()
        let reply = BridgeMessage(type: "state", state: "review", title: "Codex replied", body: "Done")

        socket.emit(reply)
        socket.emit(reply)
        socket.emit(BridgeMessage(type: "state", state: "failed", title: "Send failed", body: "No chat"))
        await Task.yield()

        XCTAssertEqual(model.statusTitle, "Send failed")
        XCTAssertEqual(model.visualState, .failed)
        XCTAssertEqual(haptics.played, [.notification, .failure])
    }

    func testStatePreviewCanOpenFullTextFromSocketMessage() async {
        let model = makeModel()
        let fullReply = "This response sends transcripts into Codex chats without losing the full markdown body."

        socket.emit(BridgeMessage(
            type: "state",
            state: "review",
            title: "Codex replied",
            body: "This response sends transcripts into Codex ch...",
            text: fullReply
        ))
        await Task.yield()

        XCTAssertEqual(model.petMessageBody, "This response sends transcripts into Codex ch...")
        XCTAssertTrue(model.hasUnreadMessage)
        XCTAssertEqual(model.petDisplayState, .review)

        model.openCurrentMessage()

        XCTAssertEqual(model.messageReader?.body, fullReply)
        XCTAssertFalse(model.hasUnreadMessage)
        XCTAssertEqual(model.petDisplayState, .idle)
    }

    func testUnreadReplyRestoresAfterRelaunchUntilRead() async {
        let model = makeModel()
        let fullReply = "Persist this unread reply while the watch app is closed."
        XCTAssertFalse(model.hasUnreadMessage)

        socket.emit(BridgeMessage(
            type: "state",
            state: "review",
            title: "Codex replied",
            body: "Persist this unread reply...",
            text: fullReply
        ))
        await Task.yield()

        let restored = makeModel()
        XCTAssertEqual(restored.visualState, .review)
        XCTAssertTrue(restored.hasUnreadMessage)
        XCTAssertEqual(restored.petMessageReaderBody, fullReply)

        restored.openCurrentMessage()
        XCTAssertEqual(socket.sentMessages.last?.type, "message-read")

        let afterRead = makeModel()
        XCTAssertFalse(afterRead.hasUnreadMessage)
        XCTAssertFalse(afterRead.hasReadableMessage)
    }

    func testThinkingStateRestoresAndSurvivesBridgeReadyReconnect() async {
        let model = makeModel()
        XCTAssertEqual(model.visualState, .idle)

        socket.emit(BridgeMessage(
            type: "state",
            state: "thinking",
            title: "Codex is thinking",
            body: "Working on it"
        ))
        await Task.yield()

        let restored = makeModel()
        XCTAssertEqual(restored.visualState, .thinking)
        XCTAssertEqual(restored.petMessageTitle, "Codex is thinking")
        XCTAssertEqual(restored.petMessageBody, "Working on it")

        restored.connect()
        XCTAssertEqual(restored.visualState, .thinking)
        XCTAssertEqual(socket.sentMessages.last?.type, "hello")
        XCTAssertEqual(socket.sentMessages.last?.state, PetVisualState.thinking.rawValue)

        socket.emit(BridgeMessage(type: "state", state: "idle", title: "Codex", body: "Bridge ready"))
        await Task.yield()
        XCTAssertEqual(restored.visualState, .thinking)
        XCTAssertEqual(restored.petMessageBody, "Working on it")
    }

    func testSelectingChatAdvertisesSelectionThroughSocket() {
        let model = makeModel()
        let item = CodexPickerItem(
            id: "thread-1",
            title: "Chat",
            subtitle: "Just now",
            kind: "chat",
            section: "chats",
            project: "project:/tmp/demo",
            chat: "thread-1",
            projectIndex: 2,
            chatIndex: 4
        )

        model.selectPickerItem(item)

        XCTAssertEqual(model.crownTarget, .chat)
        XCTAssertEqual(socket.sentMessages.last?.type, "chat-selected")
        XCTAssertEqual(socket.sentMessages.last?.project, "project:/tmp/demo")
        XCTAssertEqual(socket.sentMessages.last?.chat, "thread-1")
        XCTAssertEqual(socket.sentMessages.last?.chatIndex, 4)
        XCTAssertFalse(model.hasPetAnnouncement)
        XCTAssertEqual(model.visualState, .idle)
        XCTAssertEqual(model.petDisplayState, .waving)
    }

    func testSelectionTickOnlyMatchesExactProjectAndChat() {
        let model = makeModel()
        let selected = CodexPickerItem(
            id: "thread-selected",
            title: "Selected Chat",
            kind: "chat",
            section: "chats",
            project: "project:/tmp/selected",
            chat: "thread-selected",
            projectIndex: 1,
            chatIndex: 0
        )
        let sameIndexDifferentProject = CodexPickerItem(
            id: "thread-other-project",
            title: "Other Project Chat",
            kind: "chat",
            section: "chats",
            project: "project:/tmp/other",
            chat: "thread-other-project",
            projectIndex: 2,
            chatIndex: 0
        )
        let sameIndexProject = CodexPickerItem(
            id: "project-same-index",
            title: "Other Project",
            kind: "project",
            section: "projects",
            project: "project:/tmp/other",
            projectIndex: 1
        )

        model.selectPickerItem(selected)

        XCTAssertTrue(model.isSelectedPickerItem(selected))
        XCTAssertFalse(model.isSelectedPickerItem(sameIndexDifferentProject))
        XCTAssertFalse(model.isSelectedPickerItem(sameIndexProject))
    }

    func testNewChatSelectionAdvertisesAndCarriesThroughSend() {
        let model = makeModel()
        let project = CodexPickerItem(
            id: "project-demo",
            title: "Demo",
            subtitle: "/tmp/demo",
            kind: "project",
            section: "projects",
            project: "project:/tmp/demo",
            projectIndex: 3
        )

        model.startNewChat(in: project)

        XCTAssertEqual(model.crownTarget, .chat)
        XCTAssertEqual(socket.sentMessages.last?.type, "chat-selected")
        XCTAssertEqual(socket.sentMessages.last?.action, "new-chat")
        XCTAssertEqual(socket.sentMessages.last?.project, "project:/tmp/demo")
        XCTAssertEqual(socket.sentMessages.last?.newChat, true)
        XCTAssertFalse(model.isSelectedPickerItem(CodexPickerItem(
            id: "existing",
            title: "Existing",
            kind: "chat",
            section: "chats",
            project: "project:/tmp/demo",
            chat: "thread-existing",
            projectIndex: 3,
            chatIndex: 0
        )))

        model.sendTranscript(VoiceTranscript(title: "Transcript", text: "Start a new one."))

        XCTAssertEqual(socket.sentMessages.last?.type, "transcript-send")
        XCTAssertEqual(socket.sentMessages.last?.newChat, true)
        XCTAssertTrue(socket.sentMessages.last?.chat?.hasPrefix("new-chat:") == true)
    }

    func testOnboardingShowsOnFirstLaunchAndCanBeCompleted() {
        let model = makeModel()

        XCTAssertTrue(model.showingOnboarding)

        model.completeOnboarding()

        XCTAssertFalse(model.showingOnboarding)
        XCTAssertFalse(makeModel().showingOnboarding)
    }

    func testRotatingCrownAnimatesPetWithoutOpeningMessageLayout() {
        let model = makeModel()

        model.rotateCrown(delta: 1)

        XCTAssertFalse(model.hasPetAnnouncement)
        XCTAssertEqual(model.visualState, .idle)
        XCTAssertEqual(model.petDisplayState, .waving)
        XCTAssertEqual(socket.sentMessages.last?.type, "chat-selected")
    }

    func testSelectingMascotAdvertisesPetSelection() {
        let model = makeModel()
        let pet = CodexPet.builtIns.first { $0.id == "fireball" }!

        model.selectPet(pet)

        XCTAssertEqual(model.selectedPet.id, "fireball")
        XCTAssertEqual(model.statusTitle, "Fireball")
        XCTAssertEqual(socket.sentMessages.last?.type, "pet-selected")
        XCTAssertEqual(socket.sentMessages.last?.pet, "fireball")
    }

    func testDesktopPetStatesAreRecognized() {
        XCTAssertEqual(PetVisualState.desktopState(from: "running-left"), .runningLeft)
        XCTAssertEqual(PetVisualState.desktopState(from: "running-right"), .runningRight)
        XCTAssertEqual(PetVisualState.desktopState(from: "loading"), .running)
        XCTAssertEqual(PetVisualState.desktopState(from: "thinking"), .thinking)
        XCTAssertEqual(PetVisualState.desktopState(from: "reasoning"), .thinking)
        XCTAssertEqual(PetVisualState.desktopState(from: "waitingOnApproval"), .review)
        XCTAssertEqual(PetVisualState.desktopState(from: "systemError"), .failed)
    }

    func testIncomingDesktopStateAliasesUpdateWatchState() async {
        let model = makeModel()

        socket.emit(BridgeMessage(type: "state", state: "running-left", title: "Moving", body: "Left"))
        await Task.yield()
        XCTAssertEqual(model.visualState, .runningLeft)

        socket.emit(BridgeMessage(type: "state", state: "approval", title: "Approval", body: "Confirm change"))
        await Task.yield()
        XCTAssertEqual(model.visualState, .review)

        socket.emit(BridgeMessage(type: "state", state: "thinking", title: "Codex is thinking", body: "Working on it"))
        await Task.yield()
        XCTAssertEqual(model.visualState, .thinking)
        XCTAssertEqual(model.petDisplayState, .thinking)
        XCTAssertEqual(model.petMessageBody, "Working on it")
    }

    func testPrimaryShortcutOpensCurrentReadableMessage() {
        let model = makeModel()

        model.applyUITestScenario("markdown")
        model.performPrimaryShortcut()

        XCTAssertEqual(model.messageReader?.title, "Markdown")
        XCTAssertTrue(model.messageReader?.body.contains("inlineCode") == true)
        XCTAssertFalse(audio.didStart)
    }

    func testPrimaryShortcutStartsVoiceWhenNoReadableMessageExists() {
        let model = makeModel()

        model.performPrimaryShortcut()

        XCTAssertTrue(audio.didStart)
        XCTAssertTrue(model.isVoiceModeActive)
        XCTAssertEqual(model.visualState, .recording)
        XCTAssertEqual(socket.sentMessages.last?.type, "mic-start")
    }

    func testReplyingFromMessageReaderStartsVoiceMode() {
        let model = makeModel()

        model.applyUITestScenario("markdown")
        model.openCurrentMessage()
        XCTAssertNotNil(model.messageReader)

        model.replyToCurrentMessage()

        XCTAssertNil(model.messageReader)
        XCTAssertTrue(audio.didStart)
        XCTAssertTrue(model.isVoiceModeActive)
        XCTAssertEqual(model.visualState, .recording)
    }

    func testUITestScenariosSetDeterministicVisibleStates() {
        let model = makeModel()

        model.applyUITestScenario("error")
        XCTAssertEqual(model.statusTitle, "Bridge error")
        XCTAssertEqual(model.statusBody, "Reconnect failed")
        XCTAssertEqual(model.visualState, .failed)

        model.applyUITestScenario("voice")
        XCTAssertTrue(model.isVoiceModeActive)
        XCTAssertEqual(model.visualState, .recording)
        XCTAssertGreaterThan(model.waveformLevels.max() ?? 0, 0.8)
    }

    func testBridgeConfigurationPersistsAcrossModelRecreation() {
        let model = makeModel()
        model.serverURLString = "wss://watch.example.com/codex-watch"
        model.bridgeToken = "saved-secret"

        let restored = makeModel()

        XCTAssertEqual(restored.serverURLString, "wss://watch.example.com/codex-watch")
        XCTAssertEqual(restored.bridgeToken, "saved-secret")
    }

    func testConnectPassesConfiguredURLAndTokenToSocket() {
        let model = makeModel()
        model.serverURLString = "wss://watch.example.com/codex-watch"
        model.bridgeToken = "watch-secret"

        model.connect()

        XCTAssertEqual(socket.connectedURL?.absoluteString, "wss://watch.example.com/codex-watch")
        XCTAssertEqual(socket.connectedToken, "watch-secret")
        XCTAssertEqual(socket.sentMessages.last?.type, "hello")
    }

    func testConnectRejectsNonWebSocketSchemes() {
        let model = makeModel()
        model.serverURLString = "https://watch.example.com/codex-watch"

        model.connect()

        XCTAssertNil(socket.connectedURL)
        XCTAssertEqual(model.statusTitle, "Invalid URL")
    }

    func testWebSocketTargetMapsSecureAndPlainFallbacks() {
        let secure = WebSocketTarget(url: URL(string: "WSS://watch.example.com/codex-watch")!)
        let plain = WebSocketTarget(url: URL(string: "ws://127.0.0.1:17842/codex-watch")!)

        XCTAssertTrue(secure?.usesTLS == true)
        XCTAssertEqual(secure?.httpURL(endpoint: "poll", clientID: "watch")?.absoluteString,
                       "https://watch.example.com/codex-watch/poll?client=watch")
        XCTAssertTrue(plain?.usesTLS == false)
        XCTAssertEqual(plain?.httpURL(endpoint: "message", clientID: "watch")?.absoluteString,
                       "http://127.0.0.1:17842/codex-watch/message?client=watch")
        XCTAssertNil(WebSocketTarget(url: URL(string: "https://watch.example.com/codex-watch")!))
    }

    func testBridgeAuthorizationBuildsWebSocketAndHTTPHeaders() {
        let authorization = BridgeAuthorization(token: "  watch-secret  ")!
        let target = WebSocketTarget(url: URL(string: "wss://watch.example.com/codex-watch")!)!
        let handshake = authorization.webSocketHandshakeRequest(target: target, key: "test-key")
        let request = authorization.request(url: target.httpURL(endpoint: "poll", clientID: "watch")!)

        XCTAssertTrue(handshake.contains("Authorization: Bearer watch-secret\r\n"))
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer watch-secret")

        let empty = BridgeAuthorization(token: "   ")!
        XCTAssertFalse(empty.webSocketHandshakeRequest(target: target, key: "test-key").contains("Authorization:"))
        XCTAssertNil(empty.request(url: URL(string: "https://watch.example.com")!).value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(BridgeAuthorization(token: "bad\r\ntoken"))
    }

    private func makeModel() -> CompanionViewModel {
        CompanionViewModel(
            socket: socket,
            audio: audio,
            runtimeKeeper: runtime,
            haptics: haptics,
            defaults: defaults,
            bridgeTokenLoader: { [weak self] in self?.storedBridgeToken },
            bridgeTokenSaver: { [weak self] token in self?.storedBridgeToken = token }
        )
    }
}

private final class MockSocket: WatchSocketClienting {
    var onMessage: ((BridgeMessage) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?
    var sentMessages: [BridgeMessage] = []
    var didDisconnect = false
    var connectedURL: URL?
    var connectedToken: String?

    func connect(to url: URL, token: String, hello: BridgeMessage) {
        connectedURL = url
        connectedToken = token
        sentMessages.append(hello)
        onStateChange?(.connected)
    }

    func disconnect() {
        didDisconnect = true
        onStateChange?(.disconnected)
    }

    func send(_ message: BridgeMessage) {
        sentMessages.append(message)
    }

    func emit(_ message: BridgeMessage) {
        onMessage?(message)
    }
}

private final class MockAudio: WatchAudioStreaming {
    var permissionAllowed = true
    var didStart = false
    var didStop = false

    func requestPermission(_ completion: @escaping (Bool) -> Void) {
        completion(permissionAllowed)
    }

    func start(onChunk: @escaping (AudioChunk) -> Void) throws {
        didStart = true
    }

    func stop() {
        didStop = true
    }
}

private final class MockRuntimeKeeper: WatchRuntimeKeeping {
    var didStart = false
    var didStop = false

    func start() {
        didStart = true
    }

    func stop() {
        didStop = true
    }
}

private final class MockHaptics: WatchHapticPlaying {
    var played: [WKHapticType] = []

    func play(_ type: WKHapticType) {
        played.append(type)
    }
}
