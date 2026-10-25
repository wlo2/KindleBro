import SwiftUI

struct WordRow: View {
    let word: Word
    let onUpdateStatus: (WordStatus) -> Void
    let onCopy: () -> Void
    let onContextCopy: () -> Void
    let onSelectUsage: (String) -> Void
    let onSelectAll: () -> Void
    let onCopyAll: () -> Void
    let onJumpToWord: (Word) -> Void
    let enableRelatedWords: Bool
    let showBookTitle: Bool
    let dbManager: DatabaseManager // only for fetches; observing it re-rendered every row on any change
    
    @State private var isExpanded = false
    @State private var isRelatedPopoverPresented = false
    @State private var isRelatedLoading = false
    @State private var relatedWords: [Word] = []
    @State private var relatedRequestId = UUID()
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopy()
    }

    @ViewBuilder
    private var relatedPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related words")
                .font(.headline)
            if isRelatedLoading {
                ProgressView()
                    .controlSize(.small)
            } else if relatedWords.isEmpty {
                Text("No related words found.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                ForEach(relatedWords) { related in
                    Button(action: {
                        onJumpToWord(related)
                        isRelatedPopoverPresented = false
                    }) {
                        HStack(spacing: 8) {
                            Text(related.text)
                                .font(.subheadline)
                                .foregroundColor(.primary)
                            if let bookTitle = related.bookTitle {
                                Text("(\(bookTitle))")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            if related.status == .mastered {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.green)
                                    .font(.caption)
                            } else if related.status == .ignored {
                                Image(systemName: "minus.circle")
                                    .foregroundColor(.gray)
                                    .font(.caption)
                            } else {
                                Image(systemName: "book.closed")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                            }
                        }
                        .modifier(HoverHighlight())
                    }
                    .buttonStyle(.plain)
                }
                }
                .padding(.horizontal, -8) // keep row text aligned with the title despite the highlight padding
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 360)
    }

    private var hasRelatedWords: Bool {
        word.relatedBookCount > 0
    }
    
    private func toggleRelatedPopover() {
        if isRelatedPopoverPresented {
            isRelatedPopoverPresented = false
            return
        }
        let requestId = UUID()
        relatedRequestId = requestId
        isRelatedLoading = true
        dbManager.fetchRelatedWords(for: word) { matches in
            guard relatedRequestId == requestId else { return }
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                self.relatedWords = matches
                self.isRelatedLoading = false
            }
        }
        isRelatedPopoverPresented = true
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 4) {
                    Text(word.text)
                        .font(.headline)
                        .strikethrough(word.status != .learning, color: .gray)
                        .foregroundColor(word.status != .learning ? .gray : .primary)
                    
                    if showBookTitle, let bookTitle = word.bookTitle {
                        Text("(\(bookTitle))")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                
                Button(action: { copyToClipboard(word.text) }) {
                    Image(systemName: "doc.on.doc")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                .buttonStyle(.plain)
                .help("Copy word")
                
                if word.usageCount > 1 {
                    Button(action: { 
                        if !isExpanded && word.allUsages.count <= 1 {
                            dbManager.fetchUsages(for: word)
                        }
                        withAnimation { isExpanded.toggle() } 
                    }) {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(8) // Increase hit area
                        .contentShape(Rectangle()) // Ensure the padding area is hit-testable
                    }
                    .buttonStyle(.plain)
                    .help("Show other contexts")
                }

                if enableRelatedWords && hasRelatedWords {
                    Button(action: { toggleRelatedPopover() }) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isRelatedPopoverPresented ? "Hide related words" : "Show related words")
                    .popover(isPresented: $isRelatedPopoverPresented, arrowEdge: .trailing) {
                        relatedPopoverContent
                    }
                    .transaction { $0.animation = nil }
                }
                
                if word.status == .mastered {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.caption)
                } else if word.status == .ignored {
                    Image(systemName: "minus.circle")
                        .foregroundColor(.gray)
                        .font(.caption)
                }
                
                Spacer()
                
                Text(word.date, style: .date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            if let primaryUsageText = word.usage {
                VStack(alignment: .leading, spacing: 6) {
                    // Filter allUsages to find the primary usage object
                    let primaryUsage = word.allUsages.first(where: { $0.text == primaryUsageText })
                    
                    if isExpanded {
                        // In expanded mode, show ALL usages sorted by date
                        ForEach(word.sortedUsages) { usageObj in
                            usageRow(usageObj, isSelected: usageObj.text == primaryUsageText, showStar: true)
                        }
                    } else if let primary = primaryUsage {
                        // In collapsed mode, show the preferred one from the list if available
                        usageRow(primary, isSelected: true, showStar: false)
                    } else {
                        // Fallback: Show the primary text directly if allUsages is empty/fetching
                        Text(primaryUsageText)
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                            .italic()
                            .lineLimit(2)
                    }
                }
            }
            
        }
        .padding(.vertical, 4)
        .onChange(of: word.id) { _, _ in
            // Reset stem UI state when the row is reused for a different word.
            isRelatedPopoverPresented = false
            isRelatedLoading = false
            relatedWords = []
            relatedRequestId = UUID()
        }
        .onChange(of: word.allUsages.count) { _, count in
            // A list refresh brings back only the latest usage; reload the rest if still expanded.
            if isExpanded && count <= 1 { dbManager.fetchUsages(for: word) }
        }
        .onChange(of: word.relatedBookCount) { _, newValue in
            if newValue <= 0 {
                isRelatedPopoverPresented = false
                isRelatedLoading = false
                relatedWords = []
            }
        }
        .contextMenu {
            Button(action: onContextCopy) {
                Label("Copy", systemImage: "doc.on.doc")
            }
            
            if word.status != .mastered {
                Button(action: { onUpdateStatus(.mastered) }) {
                    Label("Mark as Mastered", systemImage: "checkmark.seal")
                }
            }
            
            if word.status != .ignored {
                Button(action: { onUpdateStatus(.ignored) }) {
                    Label("Mark as Ignored", systemImage: "minus.circle")
                }
            }
            
            if word.status != .learning {
                Button(action: { onUpdateStatus(.learning) }) {
                    Label("Mark as Learning", systemImage: "book.closed")
                }
            }
            
            Divider()
            
            Button(action: onSelectAll) {
                Label("Select all Learning words", systemImage: "checklist")
            }
            
            Button(action: onCopyAll) {
                Label("Copy all Learning words", systemImage: "doc.on.doc.fill")
            }
        }
    }
    
    @ViewBuilder
    private func usageRow(_ usageObj: WordUsage, isSelected: Bool, showStar: Bool) -> some View {
        HStack(alignment: .top) {
            // Selection Indicator / Button (only when showStar is true)
            if showStar {
                Button(action: { 
                    if !isSelected {
                        onSelectUsage(usageObj.text)
                        // Auto-collapse after selection
                        withAnimation {
                            isExpanded = false
                        }
                    }
                }) {
                    Image(systemName: isSelected ? "circle.inset.filled" : "circle")
                        .foregroundColor(isSelected ? .blue : .gray.opacity(0.5))
                }
                .buttonStyle(.plain)
                .help(isSelected ? "Selected context" : "Set as preferred context")
            }
            
            VStack(alignment: .leading, spacing: 2) {
                Text(usageObj.text)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            Spacer()
            
            HStack(spacing: 8) {
                if showStar {
                    Text(usageObj.date, style: .date)
                        .font(.caption2)
                        .foregroundColor(.secondary.opacity(0.7))
                }
                
                Button(action: { 
                    var textToCopy = usageObj.text
                    if let bookTitle = word.bookTitle {
                        textToCopy += " «\(bookTitle)»"
                    }
                    copyToClipboard(textToCopy)
                }) {
                    // Quote icon: copies the sentence, unlike the word's doc.on.doc icon
                    Image(systemName: "text.quote")
                        .font(.caption)
                        .foregroundColor(.blue.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Copy usage")
            }
        }
        .padding(.vertical, 2)
    }
}

// Rounded highlight on hover, like native menu and toolbar items, so rows read as clickable.
private struct HoverHighlight: ViewModifier {
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.1 : 0))
            )
            .contentShape(Rectangle()) // whole row, including the gap before the icon, is clickable
            .onHover { isHovered = $0 }
    }
}
