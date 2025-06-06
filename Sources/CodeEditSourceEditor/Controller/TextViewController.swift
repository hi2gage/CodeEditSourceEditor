//
//  TextViewController.swift
//  CodeEditSourceEditor
//
//  Created by Khan Winter on 6/25/23.
//

import AppKit
import CodeEditTextView
import CodeEditLanguages
import SwiftUI
import Combine
import TextFormation

/// # TextViewController
///
/// A view controller class for managing a source editor. Uses ``CodeEditTextView/TextView`` for input and rendering,
/// tree-sitter for syntax highlighting, and TextFormation for live editing completions.
public class TextViewController: NSViewController {
    // swiftlint:disable:next line_length
    public static let cursorPositionUpdatedNotification: Notification.Name = .init("TextViewController.cursorPositionNotification")

    weak var findViewController: FindViewController?

    var scrollView: NSScrollView!

    // SEARCH
    var stackview: NSStackView!
    var searchField: NSTextField!
    var prevButton: NSButton!
    var nextButton: NSButton!

    var textView: TextView!
    var gutterView: GutterView!
    internal var _undoManager: CEUndoManager!
    internal var systemAppearance: NSAppearance.Name?

    package var localEvenMonitor: Any?
    package var isPostingCursorNotification: Bool = false

    /// The string contents.
    public var string: String {
        textView.string
    }

    /// The associated `CodeLanguage`
    public var language: CodeLanguage {
        didSet {
            highlighter?.setLanguage(language: language)
            setUpTextFormation()
        }
    }

    /// The font to use in the `textView`
    public var font: NSFont {
        didSet {
            textView.font = font
            highlighter?.invalidate()
        }
    }

    /// The associated `Theme` used for highlighting.
    public var theme: EditorTheme {
        didSet {
            textView.layoutManager.setNeedsLayout()
            textView.textStorage.setAttributes(
                attributesFor(nil),
                range: NSRange(location: 0, length: textView.textStorage.length)
            )
            textView.selectionManager.selectedLineBackgroundColor = theme.selection
            highlighter?.invalidate()
            gutterView.textColor = theme.text.color.withAlphaComponent(0.35)
            gutterView.selectedLineTextColor = theme.text.color
        }
    }

    /// The visual width of tab characters in the text view measured in number of spaces.
    public var tabWidth: Int {
        didSet {
            paragraphStyle = generateParagraphStyle()
            textView.layoutManager.setNeedsLayout()
            highlighter?.invalidate()
        }
    }

    /// The behavior to use when the tab key is pressed.
    public var indentOption: IndentOption {
        didSet {
            setUpTextFormation()
        }
    }

    /// A multiplier for setting the line height. Defaults to `1.0`
    public var lineHeightMultiple: CGFloat {
        didSet {
            textView.layoutManager.lineHeightMultiplier = lineHeightMultiple
        }
    }

    /// Whether lines wrap to the width of the editor
    public var wrapLines: Bool {
        didSet {
            textView.layoutManager.wrapLines = wrapLines
            scrollView.hasHorizontalScroller = !wrapLines
            textView.textInsets = textViewInsets
        }
    }

    /// The current cursors' positions ordered by the location of the cursor.
    internal(set) public var cursorPositions: [CursorPosition] = []

    /// The editorOverscroll to use for the textView over scroll
    ///
    /// Measured in a percentage of the view's total height, meaning a `0.3` value will result in overscroll
    /// of 1/3 of the view.
    public var editorOverscroll: CGFloat {
        didSet {
            textView.overscrollAmount = editorOverscroll
        }
    }

    /// Whether the code editor should use the theme background color or be transparent
    public var useThemeBackground: Bool

    /// The provided highlight provider.
    public var highlightProviders: [HighlightProviding]

    /// Optional insets to offset the text view and find panel in the scroll view by.
    public var contentInsets: NSEdgeInsets? {
        didSet {
            styleScrollView()
            findViewController?.topPadding = contentInsets?.top
        }
    }

    /// An additional amount to inset text by. Horizontal values are ignored.
    ///
    /// This value does not affect decorations like the find panel, but affects things that are relative to text, such
    /// as line numbers and of course the text itself.
    public var additionalTextInsets: NSEdgeInsets? {
        didSet {
            styleScrollView()
        }
    }

    /// Whether or not text view is editable by user
    public var isEditable: Bool {
        didSet {
            textView.isEditable = isEditable
        }
    }

    /// Whether or not text view is selectable by user
    public var isSelectable: Bool {
        didSet {
            textView.isSelectable = isSelectable
        }
    }

    /// A multiplier that determines the amount of space between characters. `1.0` indicates no space,
    /// `2.0` indicates one character of space between other characters.
    public var letterSpacing: Double = 1.0 {
        didSet {
            textView.letterSpacing = letterSpacing
            highlighter?.invalidate()
        }
    }

    /// The type of highlight to use when highlighting bracket pairs. Leave as `nil` to disable highlighting.
    public var bracketPairEmphasis: BracketPairEmphasis? {
        didSet {
            emphasizeSelectionPairs()
        }
    }

    /// Passthrough value for the `textView`s string
    public var text: String {
        get {
            textView.string
        }
        set {
            self.setText(newValue)
        }
    }

    /// If true, uses the system cursor on macOS 14 or greater.
    public var useSystemCursor: Bool {
        get {
            textView.useSystemCursor
        }
        set {
            if #available(macOS 14, *) {
                textView.useSystemCursor = newValue
            }
        }
    }

    var textCoordinators: [WeakCoordinator] = []

    var highlighter: Highlighter?

    /// The tree sitter client managed by the source editor.
    ///
    /// This will be `nil` if another highlighter provider is passed to the source editor.
    internal(set) public var treeSitterClient: TreeSitterClient?

    package var fontCharWidth: CGFloat { (" " as NSString).size(withAttributes: [.font: font]).width }

    /// Filters used when applying edits..
    internal var textFilters: [TextFormation.Filter] = []

    internal var cancellables = Set<AnyCancellable>()

    /// The trailing inset for the editor. Grows when line wrapping is disabled.
    package var textViewTrailingInset: CGFloat {
        // See https://github.com/CodeEditApp/CodeEditTextView/issues/66
        // wrapLines ? 1 : 48
        0
    }

    package var textViewInsets: HorizontalEdgeInsets {
        HorizontalEdgeInsets(
            left: gutterView.gutterWidth,
            right: textViewTrailingInset
        )
    }

    // MARK: Init

    init(
        string: String,
        language: CodeLanguage,
        font: NSFont,
        theme: EditorTheme,
        tabWidth: Int,
        indentOption: IndentOption,
        lineHeight: CGFloat,
        wrapLines: Bool,
        cursorPositions: [CursorPosition],
        editorOverscroll: CGFloat,
        useThemeBackground: Bool,
        highlightProviders: [HighlightProviding] = [TreeSitterClient()],
        contentInsets: NSEdgeInsets?,
        additionalTextInsets: NSEdgeInsets? = nil,
        isEditable: Bool,
        isSelectable: Bool,
        letterSpacing: Double,
        useSystemCursor: Bool,
        bracketPairEmphasis: BracketPairEmphasis?,
        undoManager: CEUndoManager? = nil,
        coordinators: [TextViewCoordinator] = []
    ) {
        self.language = language
        self.font = font
        self.theme = theme
        self.tabWidth = tabWidth
        self.indentOption = indentOption
        self.lineHeightMultiple = lineHeight
        self.wrapLines = wrapLines
        self.cursorPositions = cursorPositions
        self.editorOverscroll = editorOverscroll
        self.useThemeBackground = useThemeBackground
        self.highlightProviders = highlightProviders
        self.contentInsets = contentInsets
        self.additionalTextInsets = additionalTextInsets
        self.isEditable = isEditable
        self.isSelectable = isSelectable
        self.letterSpacing = letterSpacing
        self.bracketPairEmphasis = bracketPairEmphasis
        self._undoManager = undoManager

        super.init(nibName: nil, bundle: nil)

        let platformGuardedSystemCursor: Bool
        if #available(macOS 14, *) {
            platformGuardedSystemCursor = useSystemCursor
        } else {
            platformGuardedSystemCursor = false
        }

        if let idx = highlightProviders.firstIndex(where: { $0 is TreeSitterClient }),
           let client = highlightProviders[idx] as? TreeSitterClient {
            self.treeSitterClient = client
        }

        self.textView = TextView(
            string: string,
            font: font,
            textColor: theme.text.color,
            lineHeightMultiplier: lineHeightMultiple,
            wrapLines: wrapLines,
            isEditable: isEditable,
            isSelectable: isSelectable,
            letterSpacing: letterSpacing,
            useSystemCursor: platformGuardedSystemCursor,
            delegate: self
        )

        coordinators.forEach {
            $0.prepareCoordinator(controller: self)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Set the contents of the editor.
    /// - Parameter text: The new contents of the editor.
    public func setText(_ text: String) {
        self.textView.setText(text)
        self.setUpHighlighter()
        self.gutterView.setNeedsDisplay(self.gutterView.frame)
    }

    // MARK: Paragraph Style

    /// A default `NSParagraphStyle` with a set `lineHeight`
    package lazy var paragraphStyle: NSMutableParagraphStyle = generateParagraphStyle()

    // MARK: - Reload UI

    func reloadUI() {
        textView.isEditable = isEditable
        textView.isSelectable = isSelectable

        styleScrollView()
        styleTextView()
        styleGutterView()

        highlighter?.invalidate()
    }

    deinit {
        if let highlighter {
            textView.removeStorageDelegate(highlighter)
        }
        highlighter = nil
        highlightProviders.removeAll()
        textCoordinators.values().forEach {
            $0.destroy()
        }
        textCoordinators.removeAll()
        NotificationCenter.default.removeObserver(self)
        cancellables.forEach { $0.cancel() }
        if let localEvenMonitor {
            NSEvent.removeMonitor(localEvenMonitor)
        }
        localEvenMonitor = nil
    }
}

extension TextViewController: GutterViewDelegate {
    public func gutterViewWidthDidUpdate(newWidth: CGFloat) {
        gutterView?.frame.size.width = newWidth
        textView?.textInsets = textViewInsets
    }
}
