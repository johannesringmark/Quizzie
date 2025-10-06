//
//  RootView.swift
//  Quizzie
//
//  Created by johannes Ringmark on 2025-10-06.
//

import SwiftUI

private enum Page: Int { case listen, settings }

struct RootView: View {
    @State private var page: Page = .listen

    var body: some View {
        TabView(selection: $page) {
            NavigationStack {
                ContentView()
            }
            .toolbar(.hidden, for: .navigationBar)  
            .tag(Page.listen)

            NavigationStack {
                AppSettingsView()
            }
            .tag(Page.settings)
        }
        .tabViewStyle(.page) // enables swipe between pages
        //.indexViewStyle(.page(backgroundDisplayMode: .never)) // hide the dots (remove if you want dots)
        .ignoresSafeArea(edges: .bottom) // optional, for a full-bleed feel
    }
}
