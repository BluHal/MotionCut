import SwiftUI

@main
struct MotionCutApp: App {
    @StateObject private var editor = StudioModel()

    var body: some Scene {
        WindowGroup {
            StudioView()
                .environmentObject(editor)
                .frame(minWidth: 1120, minHeight: 760)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") { editor.newProject() }
                    .keyboardShortcut("n")
                Button("Import Media…") { editor.importMediaPanel() }
                    .keyboardShortcut("o")
                Button("Open Project…") { editor.openProjectPanel() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
                Button("Save Project") { editor.saveProject() }
                    .keyboardShortcut("s")
            }
            CommandGroup(after: .pasteboard) {
                Button("Select All Timeline Clips") { editor.selectAllClips() }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Split at Playhead") { editor.splitAtPlayhead() }
                    .keyboardShortcut("b")
                Button("Cut Before Playhead") { editor.trimAtPlayhead(removeBefore: true) }
                    .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
                Button("Cut After Playhead") { editor.trimAtPlayhead(removeBefore: false) }
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                Button("Delete Clip") { editor.deleteSelected(ripple: false) }
                    .keyboardShortcut(.delete, modifiers: [.command])
                Button("Ripple Delete") { editor.deleteSelected(ripple: true) }
                    .keyboardShortcut(.delete, modifiers: [.command, .shift])
                Button("Undo") { editor.undo() }.keyboardShortcut("z")
                Button("Redo") { editor.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }
}
