import Foundation
import Security
import WatchKit

protocol WatchHapticPlaying: AnyObject {
    func play(_ type: WKHapticType)
}

final class WatchHaptics: WatchHapticPlaying {
    func play(_ type: WKHapticType) {
        WKInterfaceDevice.current().play(type)
    }
}

enum BridgeTokenKeychain {
    private static let service = Bundle.main.bundleIdentifier ?? "dev.codexwatchcompanion"
    private static let account = "bridge-auth-token"

    static func load() -> String? {
        var query = baseQuery
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ token: String) {
        if token.isEmpty {
            SecItemDelete(baseQuery as CFDictionary)
            return
        }

        let data = Data(token.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData: data] as CFDictionary
        )
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            print("CodexWatch keychain update failed \(updateStatus)")
            return
        }

        var item = baseQuery
        item[kSecValueData] = data
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        if addStatus != errSecSuccess {
            print("CodexWatch keychain add failed \(addStatus)")
        }
    }

    private static var baseQuery: [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
    }
}

enum CrownSelectionTarget: String, Codable {
    case project
    case chat

    var next: CrownSelectionTarget {
        switch self {
        case .project:
            return .chat
        case .chat:
            return .project
        }
    }
}

struct CodexPickerSection: Identifiable {
    let id: String
    let title: String
    let items: [CodexPickerItem]
}

struct VoiceTranscript: Identifiable {
    let id = UUID()
    let title: String
    let text: String
}

struct ReadableMessage: Identifiable {
    let id = UUID()
    let title: String
    let body: String
}

private struct PersistedVisibleTask: Codable {
    let state: String
    let title: String
    let body: String
    let fullBody: String?
    let hasUnreadMessage: Bool
    let signature: String
}

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published var serverURLString: String {
        didSet {
            defaults.set(serverURLString, forKey: "serverURLString")
        }
    }
    @Published var bridgeToken: String {
        didSet {
            saveBridgeToken(bridgeToken)
        }
    }
    @Published private(set) var connectionState: ConnectionState = .disconnected
    @Published private(set) var selectedPet: CodexPet
    @Published private(set) var visualState: PetVisualState = .idle
    @Published private(set) var feedbackVisualState: PetVisualState?
    @Published private(set) var hasUnreadMessage = false
    @Published private(set) var statusTitle = "Codex"
    @Published private(set) var statusBody = "Offline"
    @Published private(set) var statusFullBody: String?
    @Published private(set) var isRecording = false
    @Published private(set) var isVoiceModeActive = false
    @Published private(set) var waveformLevels = Array(repeating: 0.03, count: 24)
    @Published private(set) var crownTarget: CrownSelectionTarget
    @Published private(set) var projectIndex: Int
    @Published private(set) var chatIndex: Int
    @Published private(set) var pickerItems: [CodexPickerItem] = []
    @Published var transcriptReview: VoiceTranscript?
    @Published var messageReader: ReadableMessage?
    @Published var showingPicker = false
    @Published var showingOnboarding = false

    var hasPetAnnouncement: Bool {
        guard !isVoiceModeActive else { return false }
        if visualState != .idle {
            return true
        }
        let inactiveBodies = ["", "Offline", "Linked", "Bridge linked", "Bridge ready", "Pet synced", "Digital Crown"]
        return !inactiveBodies.contains(statusBody)
    }

    var petDisplayState: PetVisualState {
        if visualState == .review && !hasUnreadMessage {
            return feedbackVisualState ?? .idle
        }
        return feedbackVisualState ?? visualState
    }

    var petMessageTitle: String {
        if !statusTitle.isEmpty && statusTitle != "Codex" {
            return statusTitle
        }

        switch visualState {
        case .thinking:
            return "Thinking"
        case .waiting:
            return "Thinking"
        case .running, .runningLeft, .runningRight:
            return "Working"
        case .review:
            return "Ready"
        case .failed:
            return "Needs attention"
        case .waving, .jumping:
            return selectedPet.displayName
        case .idle, .recording:
            return selectedPet.displayName
        }
    }

    var petMessageBody: String {
        let trimmed = statusBody.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && trimmed != "Linked" && trimmed != "Offline" {
            return trimmed
        }

        switch visualState {
        case .thinking:
            return "Working on it"
        case .waiting:
            return "Waiting for Codex"
        case .running, .runningLeft, .runningRight:
            return "Task in progress"
        case .review:
            return "Tap into Codex to review"
        case .failed:
            return "Open Codex for details"
        case .waving, .jumping:
            return crownTarget == .project ? selectedProjectID : selectedChatID
        case .idle, .recording:
            return connectionState.title
        }
    }

    var petMessageReaderBody: String {
        let trimmedFull = statusFullBody?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedFull.isEmpty {
            return trimmedFull
        }
        return petMessageBody
    }

    var pickerSections: [CodexPickerSection] {
        [
            CodexPickerSection(id: "unread", title: "Unread", items: pickerItems.filter(isUnread)),
            CodexPickerSection(id: "pinned", title: "Pinned", items: pickerItems.filter { isPinned($0) && !isUnread($0) }),
            CodexPickerSection(id: "projects", title: "Projects", items: pickerItems.filter(isProjectListItem)),
            CodexPickerSection(id: "chats", title: "Chats", items: pickerItems.filter(isChatListItem))
        ].filter { !$0.items.isEmpty }
    }

    var unreadPickerItems: [CodexPickerItem] {
        pickerItems.filter(isUnread)
    }

    var pinnedPickerItems: [CodexPickerItem] {
        pickerItems.filter { isPinned($0) && !isUnread($0) }
    }

    var projectPickerItems: [CodexPickerItem] {
        pickerItems.filter(isProjectListItem)
    }

    var directChatPickerItems: [CodexPickerItem] {
        pickerItems.filter(isChatListItem)
    }

    var primaryShortcutLabel: String {
        hasReadableMessage ? "Open message" : "Start voice"
    }

    var hasReadableMessage: Bool {
        hasPetAnnouncement && !petMessageBody.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private let socket: WatchSocketClienting
    private let audio: WatchAudioStreaming
    private let runtimeKeeper: WatchRuntimeKeeping
    private let haptics: WatchHapticPlaying
    private let defaults: UserDefaults
    private let saveBridgeToken: (String) -> Void
    private var isRecordRequestPending = false
    private var recordingRequested = false
    private var feedbackTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var lastHapticSignature: String?
    private var reconnectAttempt = 0
    private var shouldReconnect = true
    private static let persistedVisibleTaskKey = "persistedVisibleTask"
    private static let readVisibleTaskSignatureKey = "readVisibleTaskSignature"
    private static let didCompleteOnboardingKey = "didCompleteOnboarding"
    private static let newChatIDPrefix = "new-chat:"
    private var selectedProjectOverride: String? {
        didSet {
            storeOptional(selectedProjectOverride, key: "selectedProjectID")
        }
    }
    private var selectedChatOverride: String? {
        didSet {
            storeOptional(selectedChatOverride, key: "selectedChatID")
        }
    }

    private var selectedProjectID: String {
        selectedProjectOverride ?? "project-\(projectIndex + 1)"
    }

    private var selectedChatID: String {
        selectedChatOverride ?? "chat-\(chatIndex + 1)"
    }

    private var selectedNewChat: Bool {
        selectedChatOverride?.hasPrefix(Self.newChatIDPrefix) == true
    }

    private static let preferredServerURLString = "ws://codex-watch.local:17842/codex-watch"

    private var capabilities: [String] {
        [
            "codex-pets",
            "mic-stream-pcm-f32le",
            "tap-to-talk",
            "digital-crown-project-chat",
            "project-chat-picker",
            "new-chat"
        ]
    }

    init(
        socket: WatchSocketClienting = WatchSocketClient(),
        audio: WatchAudioStreaming = WatchAudioStreamer(),
        runtimeKeeper: WatchRuntimeKeeping = WatchRuntimeKeeper(),
        haptics: WatchHapticPlaying = WatchHaptics(),
        defaults: UserDefaults = .standard,
        bridgeTokenLoader: () -> String? = BridgeTokenKeychain.load,
        bridgeTokenSaver: @escaping (String) -> Void = BridgeTokenKeychain.save,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.socket = socket
        self.audio = audio
        self.runtimeKeeper = runtimeKeeper
        self.haptics = haptics
        self.defaults = defaults
        self.saveBridgeToken = bridgeTokenSaver

        let environmentURL = environment["CODEX_WATCH_SERVER_URL"]
        let savedURL = defaults.string(forKey: "serverURLString")
        self.serverURLString = environmentURL ?? savedURL ?? Self.preferredServerURLString
        let environmentToken = environment["CODEX_WATCH_AUTH_TOKEN"]
        self.bridgeToken = environmentToken ?? bridgeTokenLoader() ?? ""
        if let environmentURL {
            defaults.set(environmentURL, forKey: "serverURLString")
        }
        if let environmentToken {
            bridgeTokenSaver(environmentToken)
        }

        let petID = defaults.string(forKey: "selectedPetID")
        self.selectedPet = CodexPet.pet(id: petID)
        self.projectIndex = defaults.integer(forKey: "selectedProjectIndex")
        self.chatIndex = defaults.integer(forKey: "selectedChatIndex")
        let savedTarget = defaults.string(forKey: "crownTarget")
        self.crownTarget = CrownSelectionTarget(rawValue: savedTarget ?? "") ?? .chat
        self.selectedProjectOverride = defaults.string(forKey: "selectedProjectID")
        self.selectedChatOverride = defaults.string(forKey: "selectedChatID")
        self.pickerItems = Self.defaultPickerItems(projectIndex: projectIndex, chatIndex: chatIndex)
        restorePersistedVisibleTask()
        self.showingOnboarding = !defaults.bool(forKey: Self.didCompleteOnboardingKey)
            && !ProcessInfo.processInfo.arguments.contains("--ui-testing")

        socket.onStateChange = { [weak self] state in
            Task { @MainActor in
                self?.handleConnectionState(state)
            }
        }

        socket.onMessage = { [weak self] message in
            Task { @MainActor in
                self?.handle(message)
            }
        }
    }

    func startRuntimeSession() {
        runtimeKeeper.start()
    }

    func connectIfPossible() {
        shouldReconnect = true
        guard connectionState == .disconnected else { return }
        connect()
    }

    func connect() {
        shouldReconnect = true
        reconnectTask?.cancel()
        reconnectTask = nil

        let candidate = serverURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = URL(string: candidate)
        let scheme = url?.scheme?.lowercased()
        guard let url, url.host != nil, scheme == "ws" || scheme == "wss" else {
            shouldReconnect = false
            statusTitle = "Invalid URL"
            statusBody = candidate
            visualState = .failed
            return
        }
        if !hasPersistentVisibleTask {
            statusTitle = selectedPet.displayName
            statusBody = "Linking"
            visualState = .waiting
        }
        socket.connect(
            to: url,
            token: bridgeToken,
            hello: envelope(type: "hello", state: visualState, items: pickerItems)
        )
    }

    func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        stopRecording()
        socket.disconnect()
        statusTitle = selectedPet.displayName
        statusBody = "Offline"
        visualState = .idle
        clearPersistedVisibleTask()
    }

    private func handleConnectionState(_ state: ConnectionState) {
        connectionState = state

        switch state {
        case .connected:
            resetReconnect()
            if !isVoiceModeActive && !hasPersistentVisibleTask {
                statusTitle = selectedPet.displayName
                visualState = .idle
                statusBody = state.title
            }
        case .connecting:
            if !isVoiceModeActive && !hasPersistentVisibleTask {
                statusTitle = selectedPet.displayName
                visualState = .waiting
                statusBody = state.title
            }
        case .disconnected:
            if isRecording || isRecordRequestPending || isVoiceModeActive {
                cancelRecordingAfterConnectionLoss()
            }
            if shouldReconnect {
                if !hasPersistentVisibleTask {
                    statusTitle = "Bridge error"
                    statusBody = "Reconnecting"
                    visualState = .waiting
                }
                scheduleReconnect()
            } else {
                statusTitle = selectedPet.displayName
                statusBody = state.title
                if !isVoiceModeActive {
                    visualState = .idle
                }
                clearPersistedVisibleTask()
            }
        }
    }

    private func scheduleReconnect() {
        guard shouldReconnect, reconnectTask == nil else { return }

        let delay = reconnectDelayNanoseconds()
        reconnectAttempt += 1
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard let self else { return }
                self.reconnectTask = nil
                guard self.shouldReconnect, self.connectionState == .disconnected else { return }
                self.connect()
            }
        }
    }

    private func resetReconnect() {
        reconnectAttempt = 0
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func reconnectDelayNanoseconds() -> UInt64 {
        let delays: [UInt64] = [
            750_000_000,
            1_500_000_000,
            3_000_000_000,
            6_000_000_000,
            12_000_000_000
        ]
        return delays[min(reconnectAttempt, delays.count - 1)]
    }

    private func cancelRecordingAfterConnectionLoss() {
        recordingRequested = false
        isRecordRequestPending = false
        if isRecording {
            audio.stop()
            isRecording = false
        }
        isVoiceModeActive = false
        resetWaveform()
    }

    func cyclePet() {
        guard let index = CodexPet.builtIns.firstIndex(of: selectedPet) else {
            selectPet(CodexPet.builtIns[0])
            return
        }
        selectPet(CodexPet.builtIns[(index + 1) % CodexPet.builtIns.count])
    }

    func selectPet(_ pet: CodexPet) {
        selectedPet = pet
        defaults.set(selectedPet.id, forKey: "selectedPetID")
        statusTitle = selectedPet.displayName
        socket.send(envelope(type: "pet-selected", state: visualState))
    }

    func showPicker() {
        guard !isVoiceModeActive else { return }
        showingPicker = true
        socket.send(BridgeMessage(
            type: "picker-opened",
            pet: selectedPet.id,
            state: visualState.rawValue,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            action: "open",
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            items: pickerItems,
            newChat: selectedNewChat
        ))
    }

    func completeOnboarding() {
        defaults.set(true, forKey: Self.didCompleteOnboardingKey)
        showingOnboarding = false
    }

    func selectPickerItem(_ item: CodexPickerItem) {
        let target = pickerTarget(for: item)
        crownTarget = target
        defaults.set(crownTarget.rawValue, forKey: "crownTarget")

        if let projectIndex = item.projectIndex {
            self.projectIndex = wrappedIndex(projectIndex)
            defaults.set(self.projectIndex, forKey: "selectedProjectIndex")
        }
        if let chatIndex = item.chatIndex {
            self.chatIndex = wrappedIndex(chatIndex)
            defaults.set(self.chatIndex, forKey: "selectedChatIndex")
        }
        if let project = item.project, !project.isEmpty {
            selectedProjectOverride = project
        } else if target == .project {
            selectedProjectOverride = nil
        }
        if let chat = item.chat, !chat.isEmpty {
            selectedChatOverride = chat
        } else if target == .chat {
            selectedChatOverride = nil
        }

        showingPicker = false
        let selectionBody = item.subtitle ?? (target == .project ? selectedProjectID : selectedChatID)
        statusTitle = item.title
        statusBody = "Digital Crown"
        socket.send(BridgeMessage(
            type: target == .project ? "project-selected" : "chat-selected",
            pet: selectedPet.id,
            state: visualState.rawValue,
            title: item.title,
            body: selectionBody,
            capabilities: capabilities,
            target: target.rawValue,
            action: "select",
            index: target == .project ? projectIndex : chatIndex,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: false
        ))
        pulseFeedback(target == .project ? .jumping : .waving)
    }

    func startNewChat(in project: CodexPickerItem? = nil) {
        crownTarget = .chat
        defaults.set(crownTarget.rawValue, forKey: "crownTarget")

        let resolvedProject = project ?? selectedProjectItemForNewChat()
        if let projectIndex = resolvedProject?.projectIndex {
            self.projectIndex = wrappedIndex(projectIndex)
            defaults.set(self.projectIndex, forKey: "selectedProjectIndex")
        }
        if let projectID = resolvedProject?.project, !projectID.isEmpty {
            selectedProjectOverride = projectID
        }

        let projectID = selectedProjectID
        selectedChatOverride = Self.newChatID(for: projectID)
        chatIndex = 0
        defaults.set(chatIndex, forKey: "selectedChatIndex")

        showingPicker = false
        statusTitle = "New Chat"
        statusBody = "Digital Crown"
        socket.send(BridgeMessage(
            type: "chat-selected",
            pet: selectedPet.id,
            state: visualState.rawValue,
            title: "New Chat",
            body: resolvedProject?.subtitle ?? projectID,
            capabilities: capabilities,
            target: CrownSelectionTarget.chat.rawValue,
            action: "new-chat",
            index: chatIndex,
            project: projectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: true
        ))
        pulseFeedback(.waving)
    }

    func performPrimaryShortcut() {
        if hasReadableMessage {
            openCurrentMessage()
        } else if !isVoiceModeActive {
            beginRecording()
        }
    }

    func openCurrentMessage() {
        guard hasReadableMessage else { return }
        let title = petMessageTitle
        let body = petMessageBody
        messageReader = ReadableMessage(
            title: title,
            body: petMessageReaderBody
        )
        hasUnreadMessage = false
        markCurrentVisibleTaskRead()
        socket.send(envelope(type: "message-read", state: .idle, title: title, body: body))
    }

    func replyToCurrentMessage() {
        messageReader = nil
        beginRecording()
    }

    func chatItems(for project: CodexPickerItem) -> [CodexPickerItem] {
        guard let projectID = project.project else { return [] }
        return pickerItems.filter { item in
            isChatListItem(item) && item.project == projectID
        }
    }

    func isSelectedPickerItem(_ item: CodexPickerItem) -> Bool {
        if pickerTarget(for: item) == .project {
            if let project = item.project, !project.isEmpty {
                return project == selectedProjectID
            }
            return selectedProjectOverride == nil && item.projectIndex == projectIndex
        }
        if selectedNewChat {
            return false
        }
        if let chat = item.chat, !chat.isEmpty {
            guard chat == selectedChatID else { return false }
            if let project = item.project, !project.isEmpty {
                return project == selectedProjectID
            }
            return true
        }
        return selectedChatOverride == nil
            && item.chatIndex == chatIndex
            && projectMatchesSelection(item.project)
    }

    func isProjectPickerItem(_ item: CodexPickerItem) -> Bool {
        pickerTarget(for: item) == .project
    }

    func beginRecording() {
        guard !isRecording, !isRecordRequestPending else { return }
        recordingRequested = true
        isRecordRequestPending = true
        isVoiceModeActive = true
        resetWaveform()
        visualState = .recording
        audio.requestPermission { [weak self] allowed in
            guard let self else { return }
            self.isRecordRequestPending = false
            if allowed && self.recordingRequested {
                self.startRecording()
            } else if !allowed {
                self.recordingRequested = false
                self.isVoiceModeActive = false
                self.statusTitle = "Mic blocked"
                self.statusBody = "Permission denied"
                self.visualState = .failed
            } else {
                self.isVoiceModeActive = false
                self.visualState = self.connectionState == .connected ? .idle : .idle
            }
        }
    }

    func stopRecording() {
        recordingRequested = false
        isRecordRequestPending = false
        guard isVoiceModeActive || isRecording else { return }
        if isRecording {
            audio.stop()
            isRecording = false
            socket.send(envelope(type: "mic-stop", state: visualState))
            isVoiceModeActive = false
            statusTitle = "Transcribing"
            statusBody = "Processing audio"
            visualState = .running
            return
        }
        isVoiceModeActive = false
        statusTitle = selectedPet.displayName
        statusBody = connectionState == .connected ? "Linked" : "Offline"
        visualState = .idle
    }

    func dismissTranscript() {
        transcriptReview = nil
        messageReader = nil
        statusTitle = selectedPet.displayName
        statusBody = connectionState == .connected ? "Bridge ready" : "Offline"
        visualState = .idle
        clearPersistedVisibleTask()
    }

    func sendTranscript(_ transcript: VoiceTranscript) {
        let text = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            haptics.play(.failure)
            return
        }

        haptics.play(.start)
        transcriptReview = nil
        messageReader = nil
        statusTitle = "Sending"
        statusBody = text
        visualState = .running
        persistVisibleTaskIfNeeded()
        socket.send(BridgeMessage(
            type: "transcript-send",
            pet: selectedPet.id,
            state: PetVisualState.running.rawValue,
            title: transcript.title,
            body: text,
            text: text,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            action: "send",
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    func rotateCrown(delta: Int) {
        guard delta != 0 else { return }
        let boundedDelta = max(-24, min(24, delta))

        switch crownTarget {
        case .project:
            projectIndex = wrappedIndex(projectIndex + boundedDelta)
            selectedProjectOverride = nil
            defaults.set(projectIndex, forKey: "selectedProjectIndex")
            advertiseSelection(type: "project-selected", delta: boundedDelta)
        case .chat:
            chatIndex = wrappedIndex(chatIndex + boundedDelta)
            selectedChatOverride = nil
            defaults.set(chatIndex, forKey: "selectedChatIndex")
            advertiseSelection(type: "chat-selected", delta: boundedDelta)
        }

        pulseFeedback(.waving)
    }

    func toggleCrownTarget() {
        crownTarget = crownTarget.next
        defaults.set(crownTarget.rawValue, forKey: "crownTarget")
        advertiseSelection(type: "selection-focus", delta: nil)
        pulseFeedback(.jumping)
    }

    func applyUITestScenario(_ scenario: String?) {
        guard let scenario else { return }

        connectionState = .connected
        isRecording = false
        isRecordRequestPending = false
        recordingRequested = false
        feedbackVisualState = nil
        hasUnreadMessage = false
        transcriptReview = nil
        messageReader = nil
        statusFullBody = nil
        showingPicker = false
        showingOnboarding = false
        resetWaveform()

        switch scenario {
        case "idle":
            statusTitle = selectedPet.displayName
            statusBody = "Bridge ready"
            visualState = .idle
        case "markdown":
            statusTitle = "Markdown"
            statusBody = "Use **bold**, `inlineCode`, and [docs](https://example.com) from the watch."
            visualState = .review
            hasUnreadMessage = true
        case "long-message":
            statusTitle = "Codex replied"
            statusBody = "This is a longer markdown reply with more than twenty words so the message reader should move the title into the navigation bar and leave the body to start immediately. It keeps enough body text on screen to prove that the reply control belongs to the scroll content instead of being pinned over the bottom edge."
            visualState = .review
            hasUnreadMessage = true
        case "reader":
            statusTitle = "Codex replied"
            statusBody = "This is a longer markdown reply with `inlineCode`, **bold text**, and enough content to make the reader feel like a real Codex response."
            visualState = .review
            messageReader = ReadableMessage(
                title: "Codex replied",
                body: "This is a longer markdown reply with `inlineCode`, **bold text**, and enough content to make the reader feel like a real Codex response. The reply button lives at the bottom of the scroll view."
            )
        case "thinking":
            statusTitle = "Codex is thinking"
            statusBody = "Working on it"
            visualState = .thinking
        case "error":
            statusTitle = "Bridge error"
            statusBody = "Reconnect failed"
            visualState = .failed
        case "transcript":
            transcriptReview = VoiceTranscript(
                title: "Transcript",
                text: "Ship `inlineCode` with **bold** confidence."
            )
            statusTitle = selectedPet.displayName
            statusBody = "Bridge ready"
            visualState = .idle
        case "voice":
            waveformLevels = [0.12, 0.42, 0.2, 0.72, 0.36, 0.88, 0.44, 0.66, 0.24, 0.52, 0.18, 0.38]
            isVoiceModeActive = true
            visualState = .recording
            statusTitle = "Listening"
            statusBody = selectedPet.displayName
        case "picker":
            pickerItems = []
            showingPicker = true
            statusTitle = selectedPet.displayName
            statusBody = "Bridge ready"
            visualState = .idle
        case "picker-many":
            pickerItems = Self.manyPickerItems()
            showingPicker = true
            statusTitle = selectedPet.displayName
            statusBody = "Bridge ready"
            visualState = .idle
        case "onboarding":
            pickerItems = Self.manyPickerItems()
            showingOnboarding = true
            statusTitle = selectedPet.displayName
            statusBody = "Bridge ready"
            visualState = .idle
        default:
            break
        }
    }

    private func startRecording() {
        do {
            try audio.start { [weak self] chunk in
                Task { @MainActor in
                    guard let self, self.isRecording else { return }
                    self.pushAudioLevel(chunk.level)
                    self.socket.send(self.envelope(
                        type: "mic-chunk",
                        state: .recording,
                        sampleRate: chunk.sampleRate,
                        channels: chunk.channels,
                        encoding: chunk.encoding,
                        data: chunk.data.base64EncodedString(),
                        bytes: chunk.data.count
                    ))
                }
            }
            socket.send(envelope(type: "mic-start", state: .recording))
            isRecording = true
            isVoiceModeActive = true
            statusTitle = "Listening"
            statusBody = selectedPet.displayName
            visualState = .recording
        } catch {
            recordingRequested = false
            isRecordRequestPending = false
            isVoiceModeActive = false
            statusTitle = "Mic error"
            statusBody = error.localizedDescription
            visualState = .failed
            isRecording = false
        }
    }

    private func handle(_ message: BridgeMessage) {
        switch message.type {
        case "state":
            if let items = message.items {
                updatePickerItems(items)
            }
            if let pet = message.pet {
                selectedPet = CodexPet.pet(id: pet)
            }
            if message.project != nil || message.chat != nil || message.projectIndex != nil || message.chatIndex != nil || message.newChat != nil {
                applySelection(message)
            }
            if let state = message.state, let visual = PetVisualState.desktopState(from: state) {
                if shouldIgnoreReadReplay(message, visual: visual) || shouldIgnoreGenericIdle(message, visual: visual) {
                    return
                }
                visualState = isVoiceModeActive ? .recording : visual
                hasUnreadMessage = visual == .review
            }
            if let title = message.title, title != "Codex" {
                statusTitle = title
            } else if !isRecording {
                statusTitle = selectedPet.displayName
            }
            statusBody = message.body ?? statusBody
            statusFullBody = message.text ?? message.body ?? statusFullBody
            persistVisibleTaskIfNeeded()
            playFeedback(for: message)
        case "error":
            statusTitle = "Bridge error"
            playHaptic(.failure, signature: "error:\(message.body ?? "unknown")")
            if connectionState == .disconnected && shouldReconnect {
                if !hasPersistentVisibleTask {
                    statusBody = reconnectingStatusBody(for: message.body)
                    visualState = .waiting
                }
                scheduleReconnect()
            } else {
                statusBody = message.body ?? "Unknown"
                visualState = .failed
            }
        case "pong":
            statusBody = "Linked"
        case "picker-items":
            updatePickerItems(message.items ?? [])
        case "transcript":
            let text = message.text ?? message.body ?? ""
            transcriptReview = VoiceTranscript(
                title: message.title ?? "Transcript",
                text: text.isEmpty ? "No transcript text was returned." : text
            )
            playHaptic(.notification, signature: "transcript:\(text.prefix(96))")
            statusTitle = selectedPet.displayName
            statusBody = connectionState == .connected ? "Bridge ready" : "Offline"
            visualState = .idle
            clearPersistedVisibleTask()
        case "selection", "selection-focus", "project-selected", "chat-selected":
            applySelection(message)
        default:
            statusBody = message.text ?? message.body ?? statusBody
        }
    }

    private func envelope(
        type: String,
        state: PetVisualState,
        title: String? = nil,
        body: String? = nil,
        sampleRate: Double? = nil,
        channels: Int? = nil,
        encoding: String? = nil,
        data: String? = nil,
        bytes: Int? = nil,
        items: [CodexPickerItem]? = nil
    ) -> BridgeMessage {
        BridgeMessage(
            type: type,
            pet: selectedPet.id,
            state: state.rawValue,
            title: title,
            body: body,
            sampleRate: sampleRate,
            channels: channels,
            encoding: encoding,
            data: data,
            bytes: bytes,
            capabilities: capabilities,
            target: crownTarget.rawValue,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            items: items,
            newChat: selectedNewChat
        )
    }

    private func advertiseSelection(type: String, delta: Int?) {
        socket.send(BridgeMessage(
            type: type,
            pet: selectedPet.id,
            state: visualState.rawValue,
            body: "Digital Crown",
            capabilities: capabilities,
            target: crownTarget.rawValue,
            action: actionName(for: delta),
            delta: delta,
            index: crownTarget == .project ? projectIndex : chatIndex,
            project: selectedProjectID,
            chat: selectedChatID,
            projectIndex: projectIndex,
            chatIndex: chatIndex,
            newChat: selectedNewChat
        ))
    }

    private func applySelection(_ message: BridgeMessage) {
        if let target = message.target, let value = CrownSelectionTarget(rawValue: target) {
            crownTarget = value
            defaults.set(value.rawValue, forKey: "crownTarget")
        }
        if let projectIndex = message.projectIndex {
            self.projectIndex = wrappedIndex(projectIndex)
            defaults.set(self.projectIndex, forKey: "selectedProjectIndex")
        }
        if let chatIndex = message.chatIndex {
            self.chatIndex = wrappedIndex(chatIndex)
            defaults.set(self.chatIndex, forKey: "selectedChatIndex")
        }
        if let project = message.project, !project.isEmpty {
            selectedProjectOverride = project
        }
        if let chat = message.chat, !chat.isEmpty {
            selectedChatOverride = chat
        } else if message.newChat == false {
            selectedChatOverride = nil
        }
        if message.newChat == false, let chat = message.chat, !chat.hasPrefix(Self.newChatIDPrefix) {
            selectedChatOverride = chat
        }
    }

    private func selectedProjectItemForNewChat() -> CodexPickerItem? {
        if let exact = projectPickerItems.first(where: { $0.project == selectedProjectID }) {
            return exact
        }
        if selectedProjectOverride == nil {
            return projectPickerItems.first(where: { $0.projectIndex == projectIndex }) ?? projectPickerItems.first
        }
        return projectPickerItems.first
    }

    private func updatePickerItems(_ items: [CodexPickerItem]) {
        pickerItems = items
    }

    private func isUnread(_ item: CodexPickerItem) -> Bool {
        item.section?.lowercased() == "unread" || item.unread == true
    }

    private func isPinned(_ item: CodexPickerItem) -> Bool {
        item.section?.lowercased() == "pinned" || item.pinned == true
    }

    private func isProjectListItem(_ item: CodexPickerItem) -> Bool {
        guard !isUnread(item), !isPinned(item) else { return false }
        let section = item.section?.lowercased()
        return section == "projects" || section == "project" || pickerTarget(for: item) == .project
    }

    private func isChatListItem(_ item: CodexPickerItem) -> Bool {
        guard !isUnread(item), !isPinned(item) else { return false }
        let section = item.section?.lowercased()
        return section == "chats" || section == "chat" || pickerTarget(for: item) == .chat
    }

    private func pickerTarget(for item: CodexPickerItem) -> CrownSelectionTarget {
        let kind = item.kind?.lowercased()
        let section = item.section?.lowercased()
        if kind == "project" || section == "projects" || (item.project != nil && item.chat == nil) {
            return .project
        }
        return .chat
    }

    private func actionName(for delta: Int?) -> String {
        guard let delta, delta != 0 else { return "focus" }
        return delta > 0 ? "next" : "previous"
    }

    private func projectMatchesSelection(_ project: String?) -> Bool {
        guard let project, !project.isEmpty else {
            return true
        }
        return project == selectedProjectID
    }

    private static func newChatID(for project: String) -> String {
        "\(newChatIDPrefix)\(project)"
    }

    private func reconnectingStatusBody(for errorBody: String?) -> String {
        guard let errorBody else { return "Reconnecting" }
        if errorBody.localizedCaseInsensitiveContains("offline") {
            return "Watch network offline"
        }
        return "Reconnecting"
    }

    private func wrappedIndex(_ index: Int) -> Int {
        let count = 100
        return (index % count + count) % count
    }

    private func resetWaveform() {
        waveformLevels = Array(repeating: 0.03, count: waveformLevels.count)
    }

    private func pushAudioLevel(_ level: Double) {
        waveformLevels.removeFirst()
        waveformLevels.append(level)
    }

    private func playFeedback(for message: BridgeMessage) {
        let title = message.title ?? ""
        let state = message.state ?? ""
        let body = message.body ?? ""

        if state == PetVisualState.failed.rawValue {
            playHaptic(.failure, signature: "failed:\(title):\(body.prefix(96))")
        } else if title == "Codex replied" {
            playHaptic(.notification, signature: "reply:\(body.prefix(96))")
        } else if state == PetVisualState.thinking.rawValue || title == "Codex started" || title == "Codex is thinking" {
            playHaptic(.success, signature: "started:\(selectedChatID):\(body.prefix(96))")
        }
    }

    private func playHaptic(_ type: WKHapticType, signature: String) {
        guard lastHapticSignature != signature else { return }
        lastHapticSignature = signature
        haptics.play(type)
    }

    private func pulseFeedback(_ state: PetVisualState) {
        guard !isVoiceModeActive else { return }
        feedbackTask?.cancel()
        feedbackVisualState = state
        feedbackTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 650_000_000)
            await MainActor.run {
                guard let self, !self.isVoiceModeActive else { return }
                self.feedbackVisualState = nil
            }
        }
    }

    private var hasPersistentVisibleTask: Bool {
        persistentVisibleTaskState != nil
    }

    private var persistentVisibleTaskState: PetVisualState? {
        switch visualState {
        case .review:
            return hasUnreadMessage ? .review : nil
        case .thinking, .running, .runningLeft, .runningRight:
            return visualState
        case .idle, .waiting, .failed, .waving, .jumping, .recording:
            return nil
        }
    }

    private func restorePersistedVisibleTask() {
        guard
            let data = defaults.data(forKey: Self.persistedVisibleTaskKey),
            let task = try? JSONDecoder().decode(PersistedVisibleTask.self, from: data),
            let state = PetVisualState.desktopState(from: task.state)
        else { return }

        visualState = state
        statusTitle = task.title
        statusBody = task.body
        statusFullBody = task.fullBody
        hasUnreadMessage = task.hasUnreadMessage && state == .review
    }

    private func persistVisibleTaskIfNeeded() {
        guard let state = persistentVisibleTaskState else { return }
        let signature = visibleTaskSignature(
            state: state,
            title: petMessageTitle,
            body: petMessageBody,
            fullBody: petMessageReaderBody
        )
        if state != .review {
            defaults.removeObject(forKey: Self.readVisibleTaskSignatureKey)
        }
        let task = PersistedVisibleTask(
            state: state.rawValue,
            title: petMessageTitle,
            body: petMessageBody,
            fullBody: petMessageReaderBody,
            hasUnreadMessage: hasUnreadMessage,
            signature: signature
        )
        guard let data = try? JSONEncoder().encode(task) else { return }
        defaults.set(data, forKey: Self.persistedVisibleTaskKey)
    }

    private func clearPersistedVisibleTask() {
        defaults.removeObject(forKey: Self.persistedVisibleTaskKey)
    }

    private func markCurrentVisibleTaskRead() {
        let signature = visibleTaskSignature(
            state: visualState,
            title: petMessageTitle,
            body: petMessageBody,
            fullBody: petMessageReaderBody
        )
        defaults.set(signature, forKey: Self.readVisibleTaskSignatureKey)
        clearPersistedVisibleTask()
    }

    private func shouldIgnoreGenericIdle(_ message: BridgeMessage, visual: PetVisualState) -> Bool {
        guard visual == .idle, hasPersistentVisibleTask else { return false }
        let title = message.title ?? ""
        let body = message.body ?? ""
        return title.isEmpty || title == "Codex" || body == "Bridge linked" || body == "Bridge ready" || body == "Linked"
    }

    private func shouldIgnoreReadReplay(_ message: BridgeMessage, visual: PetVisualState) -> Bool {
        guard visual == .review, let readSignature = defaults.string(forKey: Self.readVisibleTaskSignatureKey) else {
            return false
        }
        let signature = visibleTaskSignature(
            state: visual,
            title: message.title ?? "",
            body: message.body ?? "",
            fullBody: message.text ?? message.body ?? ""
        )
        if signature == readSignature {
            clearPersistedVisibleTask()
            return true
        }
        return false
    }

    private func visibleTaskSignature(state: PetVisualState, title: String, body: String, fullBody: String?) -> String {
        [
            state.rawValue,
            title.trimmingCharacters(in: .whitespacesAndNewlines),
            body.trimmingCharacters(in: .whitespacesAndNewlines),
            (fullBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        ].joined(separator: "\u{1f}")
    }

    private func storeOptional(_ value: String?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private static func defaultPickerItems(projectIndex: Int, chatIndex: Int) -> [CodexPickerItem] {
        [
            CodexPickerItem(
                id: "unread-chat-\(chatIndex + 1)",
                title: "Latest Codex reply",
                subtitle: "chat-\(chatIndex + 1)",
                kind: "chat",
                section: "unread",
                project: "project-\(projectIndex + 1)",
                chat: "chat-\(chatIndex + 1)",
                projectIndex: projectIndex,
                chatIndex: chatIndex,
                unread: true
            ),
            CodexPickerItem(
                id: "pinned-project-\(projectIndex + 1)",
                title: "Pinned project",
                subtitle: "project-\(projectIndex + 1)",
                kind: "project",
                section: "pinned",
                project: "project-\(projectIndex + 1)",
                projectIndex: projectIndex,
                pinned: true
            ),
            CodexPickerItem(
                id: "project-1",
                title: "Project 1",
                subtitle: "project-1",
                kind: "project",
                section: "projects",
                project: "project-1",
                projectIndex: 0
            ),
            CodexPickerItem(
                id: "project-2",
                title: "Project 2",
                subtitle: "project-2",
                kind: "project",
                section: "projects",
                project: "project-2",
                projectIndex: 1
            ),
            CodexPickerItem(
                id: "chat-1",
                title: "Chat 1",
                subtitle: "project-\(projectIndex + 1)",
                kind: "chat",
                section: "chats",
                project: "project-\(projectIndex + 1)",
                chat: "chat-1",
                projectIndex: projectIndex,
                chatIndex: 0
            ),
            CodexPickerItem(
                id: "chat-2",
                title: "Chat 2",
                subtitle: "project-\(projectIndex + 1)",
                kind: "chat",
                section: "chats",
                project: "project-\(projectIndex + 1)",
                chat: "chat-2",
                projectIndex: projectIndex,
                chatIndex: 1
            )
        ]
    }

    private static func manyPickerItems() -> [CodexPickerItem] {
        var items: [CodexPickerItem] = []
        for projectIndex in 0..<8 {
            let projectID = "project-\(projectIndex + 1)"
            items.append(CodexPickerItem(
                id: projectID,
                title: "Project \(projectIndex + 1)",
                subtitle: "~/Projects/project-\(projectIndex + 1)",
                kind: "project",
                section: "projects",
                project: projectID,
                projectIndex: projectIndex
            ))
            for chatIndex in 0..<8 {
                items.append(CodexPickerItem(
                    id: "\(projectID)-chat-\(chatIndex + 1)",
                    title: "Chat \(chatIndex + 1)",
                    subtitle: "Project \(projectIndex + 1)",
                    kind: "chat",
                    section: "chats",
                    project: projectID,
                    chat: "\(projectID)-chat-\(chatIndex + 1)",
                    projectIndex: projectIndex,
                    chatIndex: chatIndex
                ))
            }
        }
        return items
    }
}
