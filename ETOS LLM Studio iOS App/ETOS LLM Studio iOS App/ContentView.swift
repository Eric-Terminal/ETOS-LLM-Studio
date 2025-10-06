// ============================================================================
// ContentView.swift
// ============================================================================
// ETOS LLM Studio iOS App 主视图文件
//
// 定义内容:
// - App 的根视图
// - (当前为默认模板内容)
// ============================================================================

import SwiftUI

struct ContentView: View {
    @State private var showAboutSheet = false

    var body: some View {
        NavigationView {
            VStack {
                Image(systemName: "globe")
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                Text("Hello, world!")
            }
            .padding()
            .navigationTitle("ETOS LLM Studio")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        showAboutSheet = true
                    }) {
                        Image(systemName: "info.circle")
                    }
                }
            }
            .sheet(isPresented: $showAboutSheet) {
                AboutView()
            }
        }
    }
}

#Preview {
    ContentView()
}