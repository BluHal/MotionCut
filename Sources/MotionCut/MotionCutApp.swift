import SwiftUI

@main
struct MotionCutApp: App {
    @StateObject private var editor = EditorModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(editor)
                .frame(minWidth: 1000, minHeight: 680)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Video…") { editor.openVideo() }
                    .keyboardShortcut("o")
            }
        }
    }
}
