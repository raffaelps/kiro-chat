import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Necessário quando rodando via `swift run` (sem bundle .app).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

@main
struct KiroChatApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = ChatViewModel()
    @StateObject private var updater = Updater()

    var body: some Scene {
        WindowGroup("Kiro Chat") {
            ContentView()
                .environmentObject(model)
                .environmentObject(updater)
                .frame(minWidth: 820, minHeight: 520)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Verificar atualizações…") { updater.check(userInitiated: true) }
            }
            CommandGroup(after: .newItem) {
                Button("Novo canal…") { model.showNewChannel = true }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Adicionar bots…") { model.showAddBots = true }
                    .keyboardShortcut("b", modifiers: [.command, .shift])
                Button("Conectar bots do Kiro…") { model.showSetup = true }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(updater)
                .preferredColorScheme(.dark)
                .tint(Theme.accent)
        }
    }
}
