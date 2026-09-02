import Foundation
import SwiftUI

enum PetVisualState: String, Codable, CaseIterable {
    case idle
    case running
    case runningLeft = "running-left"
    case runningRight = "running-right"
    case thinking
    case waiting
    case review
    case failed
    case waving
    case jumping
    case recording

    var animationKey: String {
        switch self {
        case .recording:
            return PetVisualState.jumping.rawValue
        case .thinking:
            return PetVisualState.running.rawValue
        default:
            return rawValue
        }
    }

    static func desktopState(from rawValue: String) -> PetVisualState? {
        let normalized = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "_", with: "-")
            .lowercased()

        if let exact = PetVisualState(rawValue: normalized) {
            return exact
        }

        switch normalized {
        case "active", "inprogress", "in-progress", "loading", "working":
            return .running
        case "thinking", "reasoning", "thinking-started", "thinking-start":
            return .thinking
        case "needs-resume", "resuming", "pending", "queued":
            return .waiting
        case "approval", "response", "waitingonapproval", "waiting-on-approval", "waitingonuserinput", "waiting-on-user-input":
            return .review
        case "complete", "completed", "done", "success", "succeeded":
            return .review
        case "error", "failure", "systemerror", "system-error", "cancelled", "canceled":
            return .failed
        case "listening", "mic", "microphone":
            return .recording
        default:
            return nil
        }
    }
}

struct CodexPet: Identifiable, Codable, Equatable {
    let id: String
    let displayName: String
    let description: String
    let imageName: String?
    let spriteVersionNumber: Int?
    let spritePath: String?
    let spriteRevision: String?

    init(
        id: String,
        displayName: String,
        description: String,
        imageName: String? = nil,
        spriteVersionNumber: Int? = nil,
        spritePath: String? = nil,
        spriteRevision: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.description = description
        self.imageName = imageName
        self.spriteVersionNumber = spriteVersionNumber
        self.spritePath = spritePath
        self.spriteRevision = spriteRevision
    }

    static let builtIns: [CodexPet] = [
        CodexPet(id: "codex", displayName: "Codex", description: "The original Codex companion", imageName: "codex-spritesheet-v4"),
        CodexPet(id: "dewey", displayName: "Dewey", description: "A tidy duck for calm workspace days", imageName: "dewey-spritesheet-v4"),
        CodexPet(id: "fireball", displayName: "Fireball", description: "Hot path energy for fast iteration", imageName: "fireball-spritesheet-v4"),
        CodexPet(id: "rocky", displayName: "Rocky", description: "A steady rock when the diff gets large", imageName: "rocky-spritesheet-v4"),
        CodexPet(id: "seedy", displayName: "Seedy", description: "Small green shoots for new ideas", imageName: "seedy-spritesheet-v4"),
        CodexPet(id: "stacky", displayName: "Stacky", description: "A balanced stack for deep work", imageName: "stacky-spritesheet-v4"),
        CodexPet(id: "bsod", displayName: "BSOD", description: "A tiny blue-screen companion", imageName: "bsod-spritesheet-v4"),
        CodexPet(id: "null-signal", displayName: "Null Signal", description: "Quiet signal from the void", imageName: "null-signal-spritesheet-v4")
    ]

    static func pet(id: String?, in pets: [CodexPet] = builtIns) -> CodexPet {
        pets.first { $0.id == id } ?? builtIns[0]
    }

    var spriteRows: Int {
        spriteVersionNumber == 2 ? 11 : 9
    }

    var isRemote: Bool {
        spritePath != nil
    }

    var accentColor: Color {
        switch id {
        case "dewey":
            return Color(red: 1.00, green: 0.79, blue: 0.22)
        case "fireball":
            return Color(red: 1.00, green: 0.31, blue: 0.18)
        case "rocky":
            return Color(red: 0.62, green: 0.67, blue: 0.72)
        case "seedy":
            return Color(red: 0.30, green: 0.84, blue: 0.40)
        case "stacky":
            return Color(red: 0.63, green: 0.45, blue: 1.00)
        case "bsod":
            return Color(red: 0.16, green: 0.48, blue: 1.00)
        case "null-signal":
            return Color(red: 0.67, green: 0.55, blue: 1.00)
        default:
            return Color(red: 0.07, green: 0.66, blue: 1.00)
        }
    }

    var secondaryAccentColor: Color {
        switch id {
        case "dewey":
            return Color(red: 1.00, green: 0.50, blue: 0.16)
        case "fireball":
            return Color(red: 1.00, green: 0.78, blue: 0.18)
        case "rocky":
            return Color(red: 0.85, green: 0.89, blue: 0.92)
        case "seedy":
            return Color(red: 0.73, green: 1.00, blue: 0.36)
        case "stacky":
            return Color(red: 0.30, green: 0.82, blue: 1.00)
        case "bsod":
            return Color(red: 0.36, green: 0.86, blue: 1.00)
        case "null-signal":
            return Color(red: 0.28, green: 0.95, blue: 0.86)
        default:
            return Color(red: 0.34, green: 0.91, blue: 1.00)
        }
    }
}

struct PetFrame: Equatable {
    let row: Int
    let column: Int
    let duration: TimeInterval
}

struct PetAnimation {
    let frames: [PetFrame]
    let loopStartIndex: Int?

    static func animation(for state: PetVisualState) -> PetAnimation {
        animations[state.animationKey] ?? animations["idle"]!
    }

    private static let idleFrames: [PetFrame] = [
        PetFrame(row: 0, column: 0, duration: 1.680),
        PetFrame(row: 0, column: 1, duration: 0.660),
        PetFrame(row: 0, column: 2, duration: 0.660),
        PetFrame(row: 0, column: 3, duration: 0.840),
        PetFrame(row: 0, column: 4, duration: 0.840),
        PetFrame(row: 0, column: 5, duration: 1.920)
    ]

    private static let animations: [String: PetAnimation] = [
        "idle": PetAnimation(frames: idleFrames, loopStartIndex: 0),
        "running-right": appState(row: 1, count: 8, frameMs: 120, finalMs: 220),
        "running-left": appState(row: 2, count: 8, frameMs: 120, finalMs: 220),
        "waving": appState(row: 3, count: 4, frameMs: 140, finalMs: 280),
        "jumping": appState(row: 4, count: 5, frameMs: 140, finalMs: 280),
        "failed": appState(row: 5, count: 8, frameMs: 140, finalMs: 240),
        "waiting": appState(row: 6, count: 6, frameMs: 150, finalMs: 260),
        "running": appState(row: 7, count: 6, frameMs: 120, finalMs: 220),
        "review": loopingAppState(row: 8, count: 6, frameMs: 150, finalMs: 280)
    ]

    private static func appState(row: Int, count: Int, frameMs: Int, finalMs: Int) -> PetAnimation {
        let primary = (0..<count).map { column in
            PetFrame(
                row: row,
                column: column,
                duration: TimeInterval(column == count - 1 ? finalMs : frameMs) / 1000.0
            )
        }
        let prefix = primary + primary + primary
        return PetAnimation(frames: prefix + idleFrames, loopStartIndex: prefix.count)
    }

    private static func loopingAppState(row: Int, count: Int, frameMs: Int, finalMs: Int) -> PetAnimation {
        let frames = (0..<count).map { column in
            PetFrame(
                row: row,
                column: column,
                duration: TimeInterval(column == count - 1 ? finalMs : frameMs) / 1000.0
            )
        }
        return PetAnimation(frames: frames, loopStartIndex: 0)
    }
}
