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
    @ObservedObject var dbManager: DatabaseManager
    
    @State private var isExpanded = false
    @State private var isStemPopoverPresented = false
    @State private var isStemLoading = false
    @State private var stemWords: [Word] = []
    @State private var stemRequestId = UUID()
    
    private func copyToClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        onCopy()
    }

    @ViewBuilder
    private var stemPopoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Related words")
                .font(.headline)
            if isStemLoading {
                ProgressView()
                    .controlSize(.small)
            } else if stemWords.isEmpty {
                Text("No related words found.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ForEach(stemWords) { related in
                    Button(action: {
                        onJumpToWord(related)
                        isStemPopoverPresented = false
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
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .frame(minWidth: 260, maxWidth: 360)
    }

    private var hasStemMatches: Bool {
        word.stemOtherBookCount > 0
    }
    
    private func toggleStemGroup() {
        if isStemPopoverPresented {
            isStemPopoverPresented = false
            return
        }
        let requestId = UUID()
        stemRequestId = requestId
        isStemLoading = true
        dbManager.fetchStemMatches(for: word) { matches in
            guard stemRequestId == requestId else { return }
            var t = Transaction()
            t.animation = nil
            withTransaction(t) {
                self.stemWords = matches
                self.isStemLoading = false
            }
        }
        isStemPopoverPresented = true
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

                if enableRelatedWords && hasStemMatches {
                    Button(action: { toggleStemGroup() }) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 8, height: 8)
                            .padding(.horizontal, 6)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isStemPopoverPresented ? "Hide related words" : "Show related words")
                    .popover(isPresented: $isStemPopoverPresented, arrowEdge: .trailing) {
                        stemPopoverContent
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
            isStemPopoverPresented = false
            isStemLoading = false
            stemWords = []
            stemRequestId = UUID()
        }
        .onChange(of: word.stemOtherBookCount) { _, newValue in
            if newValue <= 0 {
                isStemPopoverPresented = false
                isStemLoading = false
                stemWords = []
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
                    Image(systemName: "doc.on.doc")
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
