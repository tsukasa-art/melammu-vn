//
//  ContentView.swift
//  Melammu
//
//  Created by nasa on 2026/05/12.
//

import SwiftUI

struct ContentView: View {
    @Environment(LibraryViewModel.self) private var vm
    @State private var selectedGame: Game?

    var body: some View {
        @Bindable var vm = vm
        NavigationSplitView {
            SidebarView(vm: vm, selectedGame: $selectedGame)
        } detail: {
            if let game = selectedGame {
                GameDetailView(game: game)
            } else {
                ContentUnavailableView("ゲームを選択", systemImage: "gamecontroller")
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }
}

#Preview {
    ContentView()
}
