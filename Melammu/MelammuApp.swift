//
//  MelammuApp.swift
//  Melammu
//
//  Created by nasa on 2026/05/12.
//

import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // Wired up from the App scene once the view model exists. Both run on the
    // main thread (applicationShouldTerminate is always main-thread).
    var isGameRunning: () -> Bool = { false }

    // Quitting Melammu takes the running game with it (willTerminate kills the
    // prefix). Confirm first so an accidental Cmd+Q doesn't drop the player out
    // of a game mid-scene.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isGameRunning() else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "ゲームが起動中です"
        alert.informativeText = "Melammu を終了すると、起動中のゲームも一緒に終了します。よろしいですか？"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "終了する")    // first = default (Return)
        alert.addButton(withTitle: "キャンセル")   // .escape
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }
}

@main
struct MelammuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var vm = LibraryViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vm)
                .onAppear {
                    appDelegate.isGameRunning = { MainActor.assumeIsolated { vm.isGameRunning } }
                }
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("サムネ撮影") {
                    if let game = vm.lastLaunchedGame {
                        vm.takeSnap(for: game)
                    }
                }
                .keyboardShortcut("s", modifiers: [.option, .shift])
                .disabled(vm.lastLaunchedGame == nil)

                // Reachable while Melammu is key; the Cmd+Shift+K global hotkey
                // covers the case where a frozen game holds the foreground.
                Button("ゲームを強制終了") { vm.forceQuit() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])
                    .disabled(!vm.isGameRunning)
            }
        }
    }
}
