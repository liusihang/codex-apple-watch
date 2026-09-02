import SwiftUI

private let codexPetFrameAspect: CGFloat = 192.0 / 208.0
private let pickerVisibleItemLimit = 6

struct CompanionRootView: View {
    @ObservedObject var model: CompanionViewModel

    var body: some View {
        CompanionWatchContent(model: model)
        .background(.black)
        .ignoresSafeArea()
        ._statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .sheet(isPresented: $model.showingPicker) {
            ProjectChatPickerView(model: model)
        }
        .sheet(isPresented: $model.showingOnboarding) {
            OnboardingView(model: model)
        }
        .sheet(item: $model.messageReader) { message in
            MessageReaderView(
                message: message,
                reply: {
                    model.replyToCurrentMessage()
                }
            )
        }
        .sheet(isPresented: $model.showingConversation) {
            ConversationReaderView(model: model)
        }
    }
}

private struct CompanionWatchContent: View {
    @ObservedObject var model: CompanionViewModel
    @State private var crownValue = 0.0
    @State private var crownStep = 0
    @FocusState private var isCrownFocused: Bool

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black

                if !model.isVoiceModeActive {
                    if model.hasPetAnnouncement {
                        ActiveTaskPetView(model: model, canvasSize: proxy.size)
                            .transition(.scale(scale: 0.92).combined(with: .opacity))
                    } else {
                        VStack(spacing: 5) {
                            PetControlButton(
                                pet: model.selectedPet,
                                spriteData: model.spriteData(for: model.selectedPet),
                                state: model.petDisplayState,
                                size: petSize(in: proxy.size),
                                label: model.primaryShortcutLabel,
                                identifier: "primary-hand-gesture-shortcut",
                                isPrimaryHandShortcut: true,
                                action: {
                                    model.performPrimaryShortcut()
                                },
                                longPress: {
                                    model.showPicker()
                                }
                            )

                            CurrentChatPreview(
                                title: model.currentChatTitle,
                                subtitle: model.currentChatSubtitle,
                                isEnabled: model.canOpenCurrentChat,
                                action: model.openSelectedChat
                            )
                        }
                            .transition(.scale(scale: 0.84).combined(with: .opacity))
                    }
                }

                if model.isVoiceModeActive {
                    VoiceModeOverlay(
                        levels: model.waveformLevels,
                        tint: model.selectedPet.accentColor,
                        secondaryTint: model.selectedPet.secondaryAccentColor
                    ) {
                        model.stopRecording()
                    }
                    .transition(.opacity)
                }

                if let transcript = model.transcriptReview {
                    TranscriptReviewView(
                        transcript: transcript,
                        close: {
                            model.dismissTranscript()
                        },
                        send: {
                            model.sendTranscript(transcript)
                        }
                    )
                    .transition(.opacity)
                    .zIndex(2)
                }

            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .contentShape(Rectangle())
            .focusable(true, interactions: .edit)
            .focusEffectDisabled()
            .focused($isCrownFocused)
            .digitalCrownRotation(
                $crownValue,
                from: -10_000,
                through: 10_000,
                by: 1,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .onAppear {
                isCrownFocused = true
            }
            .onChange(of: crownValue) { _, newValue in
                let newStep = Int(newValue.rounded())
                guard newStep != crownStep else { return }
                model.rotateCrown(delta: newStep - crownStep)
                crownStep = newStep
            }
        }
        .foregroundStyle(.white)
        .animation(.easeInOut(duration: 0.16), value: model.isVoiceModeActive)
        .animation(.easeInOut(duration: 0.16), value: model.hasPetAnnouncement)
    }

    private func petSize(in size: CGSize) -> CGSize {
        let maxHeight = size.height * 0.52
        let maxWidth = size.width * 0.62
        let width = min(maxWidth, maxHeight * codexPetFrameAspect)
        return CGSize(width: width, height: width / codexPetFrameAspect)
    }
}

private struct CurrentChatPreview: View {
    let title: String
    let subtitle: String
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Text(subtitle)
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: 178)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityIdentifier("current-chat-preview")
        .accessibilityLabel("Current chat, \(title), \(subtitle)")
    }
}

private struct ActiveTaskPetView: View {
    @ObservedObject var model: CompanionViewModel
    let canvasSize: CGSize

    var body: some View {
        let cardWidth = min(canvasSize.width * 0.92, 196)
        let petWidth = min(canvasSize.width * 0.42, 88)

        VStack(alignment: .center, spacing: 7) {
            PetControlButton(
                pet: model.selectedPet,
                spriteData: model.spriteData(for: model.selectedPet),
                state: model.petDisplayState,
                size: CGSize(width: petWidth, height: petWidth / codexPetFrameAspect),
                label: "Start voice",
                identifier: "mascot-voice-button",
                isPrimaryHandShortcut: false,
                action: {
                    model.beginRecording()
                },
                longPress: {
                    model.showPicker()
                }
            )

            ActiveTaskCard(
                title: model.petMessageTitle,
                message: model.petMessageBody,
                state: model.visualState,
                isUnread: model.hasUnreadMessage,
                width: cardWidth,
                openMessage: {
                    model.openCurrentMessage()
                }
            )
        }
        .frame(width: cardWidth, alignment: .center)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.petMessageTitle). \(model.petMessageBody)")
    }
}

private struct PetControlButton: View {
    let pet: CodexPet
    let spriteData: Data?
    let state: PetVisualState
    let size: CGSize
    let label: String
    let identifier: String
    let isPrimaryHandShortcut: Bool
    let action: () -> Void
    let longPress: () -> Void

    @State private var suppressTap = false
    @State private var resetTask: Task<Void, Never>?

    var body: some View {
        Button {
            guard !suppressTap else {
                suppressTap = false
                return
            }
            action()
        } label: {
            CodexPetSpriteView(pet: pet, state: state, spriteData: spriteData)
                .frame(width: size.width, height: size.height)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.45)
                .onEnded { _ in
                    suppressTap = true
                    longPress()
                    resetTask?.cancel()
                    resetTask = Task {
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        await MainActor.run {
                            suppressTap = false
                        }
                    }
                }
        )
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
        .primaryHandGestureShortcut(isEnabled: isPrimaryHandShortcut)
        .primaryAccessibilityQuickAction(
            label: label,
            action: action,
            isEnabled: isPrimaryHandShortcut
        )
        .onDisappear {
            resetTask?.cancel()
            resetTask = nil
        }
    }
}

private extension View {
    @ViewBuilder
    func primaryHandGestureShortcut(isEnabled: Bool = true) -> some View {
        if #available(watchOS 11.0, *) {
            handGestureShortcut(.primaryAction, isEnabled: isEnabled)
        } else {
            self
        }
    }

    @ViewBuilder
    func primaryAccessibilityQuickAction(label: String, action: @escaping () -> Void, isEnabled: Bool = true) -> some View {
        if isEnabled {
            accessibilityQuickAction(style: .prompt) {
                Button(label, action: action)
            }
        } else {
            self
        }
    }
}

private struct ProjectChatPickerView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAllProjects = false
    @State private var showsAllChats = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        Label("Bridge Settings", systemImage: "network")
                    }
                    .accessibilityIdentifier("bridge-settings-link")
                }

                Section {
                    Button {
                        model.startNewChat()
                        dismiss()
                    } label: {
                        Label("New Chat", systemImage: "square.and.pencil")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .accessibilityIdentifier("picker-new-chat-button")
                }

                if !model.unreadPickerItems.isEmpty {
                    Section("Unread") {
                        directRows(model.unreadPickerItems)
                    }
                }

                if !model.pinnedPickerItems.isEmpty {
                    Section("Pinned") {
                        ForEach(model.pinnedPickerItems) { item in
                            pickerRow(for: item)
                        }
                    }
                }

                Section("Projects") {
                    if model.projectPickerItems.count > pickerVisibleItemLimit && !showsAllProjects {
                        ViewAllButton(
                            title: "View all",
                            remainingCount: model.projectPickerItems.count - pickerVisibleItemLimit,
                            accessibilityIdentifier: "view-all-projects"
                        ) {
                            showsAllProjects = true
                        }
                    }
                    ForEach(visibleProjects) { project in
                        NavigationLink {
                            ProjectChatsView(
                                model: model,
                                project: project,
                                dismissPicker: {
                                    dismiss()
                                }
                            )
                        } label: {
                            PickerItemRow(
                                item: project,
                                isSelected: model.isSelectedPickerItem(project),
                                showsDisclosure: true
                            )
                        }
                    }
                }

                if !model.directChatPickerItems.isEmpty {
                    Section("Chats") {
                        if model.directChatPickerItems.count > pickerVisibleItemLimit && !showsAllChats {
                            ViewAllButton(
                                title: "View all",
                                remainingCount: model.directChatPickerItems.count - pickerVisibleItemLimit,
                                accessibilityIdentifier: "view-all-chats"
                            ) {
                                showsAllChats = true
                            }
                        }
                        directRows(visibleDirectChats)
                    }
                }

                Section("Mascot") {
                    ForEach(model.availablePets) { pet in
                        Button {
                            model.selectPet(pet)
                            dismiss()
                        } label: {
                            MascotPickerRow(
                                pet: pet,
                                isSelected: pet == model.selectedPet,
                                spriteData: model.spriteData(for: pet)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("mascot-picker-\(pet.id)")
                    }
                }
            }
            .navigationTitle("Switch")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private var visibleProjects: [CodexPickerItem] {
        visibleItems(model.projectPickerItems, isExpanded: showsAllProjects)
    }

    private var visibleDirectChats: [CodexPickerItem] {
        visibleItems(model.directChatPickerItems, isExpanded: showsAllChats)
    }

    private func visibleItems(_ items: [CodexPickerItem], isExpanded: Bool) -> [CodexPickerItem] {
        isExpanded ? items : Array(items.prefix(pickerVisibleItemLimit))
    }

    @ViewBuilder
    private func directRows(_ items: [CodexPickerItem]) -> some View {
        ForEach(items) { item in
            pickerRow(for: item)
        }
    }

    @ViewBuilder
    private func pickerRow(for item: CodexPickerItem) -> some View {
        if model.isProjectPickerItem(item) {
            NavigationLink {
                ProjectChatsView(
                    model: model,
                    project: item,
                    dismissPicker: {
                        dismiss()
                    }
                )
            } label: {
                PickerItemRow(
                    item: item,
                    isSelected: model.isSelectedPickerItem(item),
                    showsDisclosure: true
                )
            }
        } else {
            Button {
                dismiss()
                Task { @MainActor in
                    model.openChat(item)
                }
            } label: {
                PickerItemRow(
                    item: item,
                    isSelected: model.isSelectedPickerItem(item),
                    showsDisclosure: false
                )
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("picker-chat-\(item.id)")
        }
    }
}

private struct OnboardingView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showsAllProjects = false
    @State private var showsAllChats = false

    var body: some View {
        NavigationStack {
            List {
                Section("Connection") {
                    NavigationLink {
                        SettingsView(model: model)
                    } label: {
                        Label("Bridge Settings", systemImage: "network")
                    }
                    .accessibilityIdentifier("onboarding-bridge-settings-link")
                }

                Section("Mascot") {
                    ForEach(model.availablePets) { pet in
                        Button {
                            model.selectPet(pet)
                        } label: {
                            MascotPickerRow(
                                pet: pet,
                                isSelected: pet == model.selectedPet,
                                spriteData: model.spriteData(for: pet)
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("onboarding-mascot-\(pet.id)")
                    }
                }

                Section("Projects") {
                    if model.projectPickerItems.isEmpty {
                        Text("Waiting for projects")
                            .font(.system(size: 13, weight: .regular, design: .rounded))
                            .foregroundStyle(.secondary)
                    } else {
                        if model.projectPickerItems.count > pickerVisibleItemLimit && !showsAllProjects {
                            ViewAllButton(
                                title: "View all",
                                remainingCount: model.projectPickerItems.count - pickerVisibleItemLimit,
                                accessibilityIdentifier: "onboarding-view-all-projects"
                            ) {
                                showsAllProjects = true
                            }
                        }
                        ForEach(visibleProjects) { project in
                            NavigationLink {
                                ProjectChatsView(
                                    model: model,
                                    project: project,
                                    dismissPicker: finish
                                )
                            } label: {
                                PickerItemRow(
                                    item: project,
                                    isSelected: model.isSelectedPickerItem(project),
                                    showsDisclosure: true
                                )
                            }
                        }
                    }
                }

                if !model.directChatPickerItems.isEmpty {
                    Section("Chats") {
                        if model.directChatPickerItems.count > pickerVisibleItemLimit && !showsAllChats {
                            ViewAllButton(
                                title: "View all",
                                remainingCount: model.directChatPickerItems.count - pickerVisibleItemLimit,
                                accessibilityIdentifier: "onboarding-view-all-chats"
                            ) {
                                showsAllChats = true
                            }
                        }
                        ForEach(visibleDirectChats) { chat in
                            Button {
                                model.selectPickerItem(chat)
                                finish()
                            } label: {
                                PickerItemRow(
                                    item: chat,
                                    isSelected: model.isSelectedPickerItem(chat),
                                    showsDisclosure: false
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Section {
                    Button {
                        finish()
                    } label: {
                        Label("Done", systemImage: "checkmark")
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                    }
                    .accessibilityIdentifier("onboarding-done-button")
                }
            }
            .navigationTitle("Set Up")
        }
    }

    private var visibleProjects: [CodexPickerItem] {
        visibleItems(model.projectPickerItems, isExpanded: showsAllProjects)
    }

    private var visibleDirectChats: [CodexPickerItem] {
        visibleItems(model.directChatPickerItems, isExpanded: showsAllChats)
    }

    private func visibleItems(_ items: [CodexPickerItem], isExpanded: Bool) -> [CodexPickerItem] {
        isExpanded ? items : Array(items.prefix(pickerVisibleItemLimit))
    }

    private func finish() {
        model.completeOnboarding()
        dismiss()
    }
}

private struct ViewAllButton: View {
    let title: String
    let remainingCount: Int
    let accessibilityIdentifier: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text("\(remainingCount) more")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 3)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct MascotPickerRow: View {
    let pet: CodexPet
    let isSelected: Bool
    let spriteData: Data?

    var body: some View {
        HStack(spacing: 8) {
            CodexPetSpriteView(pet: pet, state: .idle, isAnimationEnabled: false, spriteData: spriteData)
                .frame(width: 26, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(pet.displayName)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Text(pet.description)
                    .font(.system(size: 11, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(pet.accentColor)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isSelected ? "\(pet.displayName), selected" : pet.displayName)
    }
}

private struct ProjectChatsView: View {
    @ObservedObject var model: CompanionViewModel
    let project: CodexPickerItem
    let dismissPicker: () -> Void
    @State private var showsAllChats = false

    var body: some View {
        let chats = model.chatItems(for: project)
        let visibleChats = showsAllChats ? chats : Array(chats.prefix(pickerVisibleItemLimit))

        List {
            if chats.isEmpty {
                Text("No chats")
                    .font(.system(size: 13, weight: .regular, design: .rounded))
                    .foregroundStyle(.secondary)
            } else {
                if chats.count > pickerVisibleItemLimit && !showsAllChats {
                    ViewAllButton(
                        title: "View all",
                        remainingCount: chats.count - pickerVisibleItemLimit,
                        accessibilityIdentifier: "view-all-project-chats"
                    ) {
                        showsAllChats = true
                    }
                }
                ForEach(visibleChats) { chat in
                    Button {
                        dismissPicker()
                        Task { @MainActor in
                            model.openChat(chat)
                        }
                    } label: {
                        PickerItemRow(
                            item: chat,
                            isSelected: model.isSelectedPickerItem(chat),
                            showsDisclosure: false
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("picker-chat-\(chat.id)")
                }
            }

            Section {
                Button {
                    model.startNewChat(in: project)
                    dismissPicker()
                } label: {
                    Label("New Chat", systemImage: "square.and.pencil")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                }
                .accessibilityIdentifier("project-new-chat-button")
            }
        }
        .navigationTitle(project.title)
    }
}

private struct PickerItemRow: View {
    let item: CodexPickerItem
    let isSelected: Bool
    var showsDisclosure = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbolName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(symbolColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                if let subtitle = item.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
            } else if showsDisclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var symbolName: String {
        let section = item.section?.lowercased()
        let kind = item.kind?.lowercased()
        if section == "unread" || item.unread == true {
            return "circle.fill"
        }
        if section == "pinned" || item.pinned == true {
            return "pin.fill"
        }
        if kind == "project" || section == "projects" {
            return "folder.fill"
        }
        return "text.bubble.fill"
    }

    private var symbolColor: Color {
        let section = item.section?.lowercased()
        if section == "unread" || item.unread == true {
            return .blue
        }
        if section == "pinned" || item.pinned == true {
            return .yellow
        }
        return .secondary
    }

    private var accessibilityLabel: String {
        if let subtitle = item.subtitle, !subtitle.isEmpty {
            return "\(item.title). \(subtitle)"
        }
        return item.title
    }
}

private struct ActiveTaskCard: View {
    let title: String
    let message: String
    let state: PetVisualState
    let isUnread: Bool
    let width: CGFloat
    let openMessage: () -> Void

    var body: some View {
        Button(action: openMessage) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                    .padding(.trailing, 22)

                MarkdownText(
                    markdown: message,
                    size: 12.5,
                    lineLimit: 4,
                    minimumScaleFactor: 0.78,
                    foregroundOpacity: 0.92
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("active-message-body")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .primaryHandGestureShortcut()
        .primaryAccessibilityQuickAction(
            label: "Open message",
            action: openMessage
        )
        .accessibilityLabel("Open message")
        .accessibilityIdentifier("active-message-card")
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .frame(width: width)
        .frame(minHeight: 72)
        .background(Color.white.opacity(0.13))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .topTrailing) {
            ActiveTaskGlyph(state: state, isUnread: isUnread)
                .frame(width: 18, height: 18)
                .padding(.top, 7)
                .padding(.trailing, 7)
                .allowsHitTesting(false)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.12), lineWidth: 1)
        }
    }
}

private struct ActiveTaskGlyph: View {
    let state: PetVisualState
    let isUnread: Bool

    var body: some View {
        switch state {
        case .failed:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.red)
        case .review:
            if isUnread {
                Circle()
                    .fill(.blue)
                    .frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            } else {
                Color.clear
            }
        default:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(.secondary)
                .scaleEffect(0.78)
        }
    }
}

private struct MessageReaderView: View {
    let message: ReadableMessage
    let reply: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if showsInlineTitle {
                            Text(message.title)
                                .font(.system(size: 17, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .accessibilityIdentifier("message-reader-title")
                        }

                        MarkdownText(markdown: message.body, size: 15, lineSpacing: 3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityIdentifier("message-reader-body")

                        Button(action: reply) {
                            Label("Reply", systemImage: "mic.fill")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.top, 4)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .accessibilityIdentifier("message-reader-scroll")
            }
            .background(.black)
            .navigationTitle(navigationTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
    }

    private var usesTitleAsNavigationTitle: Bool {
        wordCount(message.body) > 20
    }

    private var showsInlineTitle: Bool {
        !usesTitleAsNavigationTitle && !message.title.isEmpty
    }

    private var navigationTitle: String {
        usesTitleAsNavigationTitle ? message.title : "Message"
    }

    private func wordCount(_ text: String) -> Int {
        text.split { character in
            character.isWhitespace || character.isNewline
        }.count
    }
}

private struct ConversationReaderView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let conversation = model.conversation {
                    if let entries = conversation.entries {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                if conversation.hasMore {
                                    Text("Showing the latest 20 messages")
                                        .font(.system(size: 10, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                }

                                if entries.isEmpty {
                                    Text(conversation.error ?? "No messages in this chat")
                                        .font(.system(size: 13, weight: .regular, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .center)
                                        .padding(.vertical, 20)
                                } else {
                                    ForEach(entries) { entry in
                                        ConversationEntryView(entry: entry)
                                    }
                                }

                                Button {
                                    model.replyToConversation()
                                } label: {
                                    Label("Reply", systemImage: "mic.fill")
                                        .font(.system(size: 14, weight: .bold, design: .rounded))
                                        .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(.borderedProminent)
                                .padding(.top, 4)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 10)
                        }
                    } else {
                        ProgressView("Loading chat")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .background(.black)
            .navigationTitle(model.conversation?.title ?? "Conversation")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        model.closeConversation()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
            }
        }
        .accessibilityIdentifier("conversation-reader")
    }
}

private struct ConversationEntryView: View {
    let entry: ConversationEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.role == "user" ? "You" : "Codex")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(entry.role == "user" ? .blue : .green)
            MarkdownText(markdown: entry.text, size: 13, lineSpacing: 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(9)
        .background(
            entry.role == "user" ? Color.blue.opacity(0.16) : Color.white.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(entry.role == "user" ? "You" : "Codex"): \(entry.text)")
    }
}

private struct TranscriptReviewView: View {
    let transcript: VoiceTranscript
    let close: () -> Void
    let send: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 10) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(transcript.title)
                            .font(.system(size: 17, weight: .bold, design: .rounded))

                        MarkdownText(markdown: transcript.text, size: 15, lineSpacing: 3)
                            .accessibilityIdentifier("transcript-review-body")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)
                }
                .padding(.top, 24)

                Button(action: send) {
                    Text("Send")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("transcript-review")

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(Color.white.opacity(0.14))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
            .padding(.trailing, 8)
        }
        .background(.black)
    }
}

private struct VoiceModeOverlay: View {
    let levels: [Double]
    let tint: Color
    let secondaryTint: Color
    let stop: () -> Void

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                MicrophoneWaveformView(
                    levels: levels,
                    tint: tint,
                    secondaryTint: secondaryTint
                )
                    .frame(
                        width: min(proxy.size.width * 0.70, 150),
                        height: min(proxy.size.height * 0.28, 58)
                    )
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: stop)
        }
    }
}

private struct MicrophoneWaveformView: View {
    let levels: [Double]
    let tint: Color
    let secondaryTint: Color

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 2
            let count = max(levels.count, 1)
            let barWidth = max(2, (proxy.size.width - CGFloat(count - 1) * spacing) / CGFloat(count))

            HStack(alignment: .center, spacing: spacing) {
                ForEach(levels.indices, id: \.self) { index in
                    let level = min(1, max(0.03, levels[index]))
                    Capsule(style: .continuous)
                        .fill(index.isMultiple(of: 2) ? tint : secondaryTint)
                        .frame(width: barWidth, height: max(3, proxy.size.height * level))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .accessibilityLabel("Microphone waveform")
        .accessibilityIdentifier("microphone-waveform")
    }
}

private struct MarkdownText: View {
    let markdown: String
    let size: CGFloat
    var weight: Font.Weight = .regular
    var lineLimit: Int?
    var lineSpacing: CGFloat = 0
    var minimumScaleFactor: CGFloat = 1
    var foregroundOpacity: Double = 1

    var body: some View {
        Text(CodexMarkdownRenderer.attributedString(
            markdown,
            size: size,
            weight: weight,
            foregroundOpacity: foregroundOpacity
        ))
        .lineLimit(lineLimit)
        .lineSpacing(lineSpacing)
        .minimumScaleFactor(minimumScaleFactor)
    }

}

enum CodexMarkdownRenderer {
    static func attributedString(
        _ markdown: String,
        size: CGFloat,
        weight: Font.Weight = .regular,
        foregroundOpacity: Double = 1
    ) -> AttributedString {
        var output: AttributedString
        do {
            output = try AttributedString(markdown: markdown)
        } catch {
            output = AttributedString(markdown)
        }

        output.font = .system(size: size, weight: weight, design: .rounded)
        output.foregroundColor = .primary.opacity(foregroundOpacity)

        let runs = output.runs.map { run in
            (
                range: run.range,
                intent: run.inlinePresentationIntent,
                link: run.link
            )
        }

        for run in runs {
            if let intent = run.intent {
                if intent.contains(.code) {
                    output[run.range].font = .system(size: size * 0.93, weight: .medium, design: .monospaced)
                    output[run.range].foregroundColor = .cyan
                    output[run.range].backgroundColor = .white.opacity(0.13)
                } else if intent.contains(.stronglyEmphasized) {
                    output[run.range].font = .system(size: size, weight: .semibold, design: .rounded)
                } else if intent.contains(.emphasized) {
                    output[run.range].font = .system(size: size, weight: weight, design: .rounded).italic()
                }
            }

            if run.link != nil {
                output[run.range].foregroundColor = .cyan
            }
        }

        return output
    }
}

private struct SettingsView: View {
    @ObservedObject var model: CompanionViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 8) {
            TextField("Bridge URL", text: $model.serverURLString)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier("bridge-url-field")

            SecureField("Bridge Token", text: $model.bridgeToken)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)
                .accessibilityIdentifier("bridge-token-field")

            Button {
                model.connect()
                dismiss()
            } label: {
                Label("Connect", systemImage: "bolt.horizontal.fill")
            }
            .accessibilityIdentifier("bridge-connect-button")

            Button {
                dismiss()
            } label: {
                Label("Done", systemImage: "checkmark")
            }
        }
        .padding()
    }
}

#Preview {
    CompanionRootView(model: CompanionViewModel())
}
