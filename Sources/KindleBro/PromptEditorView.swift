import SwiftUI

struct PromptEditorView: View {
    @Binding var prompt: String
    @Environment(\.dismiss) var dismiss
    
    // Local state to hold edits before saving
    @State private var editedPrompt: String = ""
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Edit Copy Prompt")
                .font(.headline)
            
            Text("This text will be prepended to your selection when using 'Prompt Copy'.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            TextEditor(text: $editedPrompt)
                .font(.body)
                .padding(4)
                .background(Color(nsColor: .controlBackgroundColor))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
                .frame(minHeight: 100)
            
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                
                Spacer()
                
                Button("Save") {
                    prompt = editedPrompt
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
        .frame(minWidth: 500, maxWidth: 800, minHeight: 300, maxHeight: 600)
        .frame(width: 600, height: 400) // Default size
        .onAppear {
            editedPrompt = prompt
        }
    }
}
