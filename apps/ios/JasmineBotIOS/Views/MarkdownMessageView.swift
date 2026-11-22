import SwiftUI
import JasmineMobileCore

struct MarkdownMessageView: View {
    let rawText: String
    var isUserBubble: Bool = false

    private var blocks: [MarkdownBlock] {
        ChatMessageItem.parseMarkdownBlocks(rawText)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            inlineText(text)
                .font(headingFont(level))
                .fontWeight(.bold)
                .padding(.top, level <= 2 ? 4 : 2)

        case .paragraph(let text):
            inlineText(text)
                .font(.callout)
                .lineSpacing(3)

        case .listItem(let bullet, let text):
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(bullet)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(isUserBubble ? Color.white.opacity(0.85) : Color.secondary)
                inlineText(text)
                    .font(.callout)
                    .lineSpacing(2.5)
            }

        case .blockquote(let text):
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isUserBubble ? Color.white.opacity(0.6) : Color.accentColor.opacity(0.75))
                    .frame(width: 3)
                inlineText(text)
                    .font(.footnote)
                    .foregroundStyle(isUserBubble ? Color.white.opacity(0.92) : Color.secondary)
            }
            .padding(.vertical, 2)

        case .codeBlock(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let lang, !lang.isEmpty {
                    HStack {
                        Text(lang)
                            .font(.caption2.monospaced().weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.18))
                }
                ScrollView(.horizontal, showsIndicators: true) {
                    Text(code)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(isUserBubble ? Color.white : Color.primary)
                        .textSelection(.enabled)
                        .padding(10)
                }
            }
            .background(
                isUserBubble ? Color.black.opacity(0.22) : Color.black.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 10)
            )

        case .table(let headers, let rows):
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Array(headers.enumerated()), id: \.offset) { colIdx, h in
                            inlineText(h)
                                .font(.caption.weight(.bold))
                                .frame(minWidth: colIdx == 0 ? 110 : 150, maxWidth: 230, alignment: .leading)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                        }
                    }
                    .background(Color.primary.opacity(0.08))

                    ForEach(Array(rows.enumerated()), id: \.offset) { rIdx, row in
                        Divider()
                        HStack(alignment: .top, spacing: 0) {
                            ForEach(0..<headers.count, id: \.self) { colIdx in
                                let cell = colIdx < row.count ? row[colIdx] : ""
                                inlineText(cell)
                                    .font(.caption)
                                    .frame(minWidth: colIdx == 0 ? 110 : 150, maxWidth: 230, alignment: .leading)
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 6)
                            }
                        }
                        .background(rIdx.isMultiple(of: 2) ? Color.clear : Color.primary.opacity(0.03))
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Color.primary.opacity(0.14), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 9))
            }
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title3
        case 2: return .headline
        case 3: return .subheadline
        default: return .callout
        }
    }

    private func inlineText(_ markdown: String) -> Text {
        if let attr = try? AttributedString(
            markdown: markdown,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(attr)
        }
        return Text(markdown)
    }
}
