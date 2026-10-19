import SwiftUI
import AppKit
import PocketKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.arguments.contains("-PocketAudioSelfTest") {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                AudioSelfTestRunner.shared.runIfNeeded()
            }
        }
    }
}

@main
struct PocketAIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        WindowGroup {
            RootSplitView()
                .environment(model)
                .task {
                    AudioSelfTestRunner.shared.runIfNeeded()
                }
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Chat") {
                    model.selectedTab = .chats
                    model.pendingCommand = .newChat
                }
                .keyboardShortcut("n", modifiers: .command)

                Button("New Project") {
                    model.selectedTab = .projects
                    model.pendingCommand = .openTab(.projects)
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])

                Button("Generate Image") {
                    openWindow(id: "image-generation")
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("Command Palette") { openWindow(id: "command-palette") }
                    .keyboardShortcut("k", modifiers: .command)
                Button("Focus Composer") { model.pendingCommand = .focusComposer }
                    .keyboardShortcut("l", modifiers: .command)
                Button("Toggle Inspector") {
                    model.showChatInspector.toggle()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                Button("Stop Generation") { model.pendingCommand = .stopGeneration }
                    .keyboardShortcut(".", modifiers: .command)
                Button("Stop Everything") { model.stopEverything() }
                    .keyboardShortcut(".", modifiers: [.command, .option])
            }
        }

        MenuBarExtra(
            "PocketAI",
            systemImage: model.isGenerating
                ? "bolt.horizontal.circle.fill"
                : (model.serverStatus.running ? "bolt.horizontal.fill" : "bolt.horizontal")
        ) {
            MenuBarContent()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
        }

        Window("Command Palette", id: "command-palette") {
            CommandPaletteView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("Image Generation", id: "image-generation") {
            MacImageGenView()
                .environment(model)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }
}

private final class AudioSelfTestRunner: @unchecked Sendable {
    static let shared = AudioSelfTestRunner()
    private let lock = NSLock()
    private var hasRun = false

    func runIfNeeded() {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-PocketAudioSelfTest"),
              args.indices.contains(index + 1) else {
            return
        }
        lock.lock()
        if hasRun {
            lock.unlock()
            return
        }
        hasRun = true
        lock.unlock()

        let outPath = args[index + 1]
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try? FileManager.default.removeItem(atPath: outPath)
                let parentDir = URL(fileURLWithPath: outPath).deletingLastPathComponent()
                try? FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)

                try PocketKit.AppleTextToSpeechEngine().synthesize(
                    text: "Pocket AI speaks on device.",
                    voice: "en-US",
                    outPath: outPath
                )
                let size = ((try? FileManager.default.attributesOfItem(atPath: outPath))?[.size] as? Int) ?? 0
                FileHandle.standardError.write(Data("AUDIO_SELFTEST_BYTES=\(size)\n".utf8))
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("AUDIO_SELFTEST_ERROR=\(error)\n".utf8))
                exit(1)
            }
        }
    }
}

