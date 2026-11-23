import AppKit
import SwiftUI

/// Shows what Simmer saw and did.
struct DebugLogView: View {
    let log: Log

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.lines) { line in
                            Text(line.text)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onAppear { scrollToEnd(proxy) }
                .onChange(of: log.lines.last?.id) { scrollToEnd(proxy) }
            }
            Divider()
            HStack {
                Button("Copy All") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.allText, forType: .string)
                }
                Button("Clear") { log.clear() }
                Spacer()
                Button("Show Log File") {
                    NSWorkspace.shared.activateFileViewerSelecting([log.fileURL])
                }
            }
            .padding(8)
        }
        .frame(minWidth: 560, minHeight: 320)
    }

    private func scrollToEnd(_ proxy: ScrollViewProxy) {
        if let last = log.lines.last {
            proxy.scrollTo(last.id, anchor: .bottom)
        }
    }
}
