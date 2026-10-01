import LinkPresentation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// What the iPad window is asking or showing on the shared code's behalf: the sheets, questions and file pickers the
/// Mac shows on its window, presented here by the window's root view (see `sceneDialogs`). iPad runs Compositor in one
/// window, with its projects in tabs, so there is one of these.
@MainActor @Observable
final class SceneDialogs {
    static let shared = SceneDialogs()

    struct Sheet: Identifiable {
        let id = UUID()
        let title: String
        let content: AnyView
        /// Swiping the sheet away cancels it, as its Cancel button would.
        let cancel: () -> Void
    }
    var sheet: Sheet?

    struct Question: Identifiable {
        let id = UUID()
        let prompt: Prompt
        let answer: (Int) -> Void
    }
    /// The question showing now; any asked meanwhile wait their turn.
    private(set) var question: Question?
    @ObservationIgnored private var waiting: [Question] = []

    struct FileRequest {
        let types: [UTType]
        let multiple: Bool
        let answer: ([URL]) -> Void
    }
    private(set) var fileRequest: FileRequest?

    struct ExportRequest {
        let file: ExportedFile
        let type: UTType
        let name: String
        let answer: (Bool) -> Void
    }
    private(set) var exportRequest: ExportRequest?

    struct PhotosRequest {
        let answer: ([PhotosPickerItem]) -> Void
    }
    private(set) var photosRequest: PhotosRequest?

    struct MoveRequest {
        let url: URL
        let answer: (URL?) -> Void
    }
    private(set) var moveRequest: MoveRequest?

    /// Shows `content` as a sheet until it finishes, and returns what it finished with (nil if it was swiped away).
    func presentSheet<Result, Content: View>(title: String,
                                             _ content: (@escaping (Result?) -> Void) -> Content) async -> Result? {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Result?) -> Void = { [weak self] result in
                guard !finished else { return }
                finished = true
                self?.sheet = nil
                continuation.resume(returning: result)
            }
            sheet = Sheet(title: title, content: AnyView(content(finish)), cancel: { finish(nil) })
        }
    }

    func ask(_ prompt: Prompt) async -> Int {
        await withCheckedContinuation { continuation in ask(prompt) { continuation.resume(returning: $0) } }
    }

    func ask(_ prompt: Prompt, answer: @escaping (Int) -> Void) {
        let asked = Question(prompt: prompt, answer: answer)
        if question == nil { question = asked } else { waiting.append(asked) }
    }

    func answer(_ index: Int) {
        guard let current = question else { return }
        question = nil
        current.answer(index)
        // The next question waits for this alert to go away.
        if !waiting.isEmpty {
            let next = waiting.removeFirst()
            DispatchQueue.main.async { [weak self] in self?.question = next }
        }
    }

    /// Asks for files with the system's document picker; none when it's cancelled.
    func chooseFiles(_ types: [UTType], multiple: Bool) async -> [URL] {
        await withCheckedContinuation { continuation in
            fileRequest = FileRequest(types: types, multiple: multiple) { continuation.resume(returning: $0) }
        }
    }

    func finishFiles(_ urls: [URL]) {
        guard let request = fileRequest else { return }
        fileRequest = nil
        request.answer(urls)
    }

    /// Asks for photos from the library with the system's photo picker; none when it's cancelled.
    func choosePhotos() async -> [PhotosPickerItem] {
        await withCheckedContinuation { continuation in
            photosRequest = PhotosRequest { continuation.resume(returning: $0) }
        }
    }

    func finishPhotos(_ items: [PhotosPickerItem]) {
        guard let request = photosRequest else { return }
        photosRequest = nil
        request.answer(items)
    }

    /// Moves the file at `url` to a folder the person chooses in Files, and returns where it went (nil if cancelled).
    func chooseMoveDestination(for url: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            moveRequest = MoveRequest(url: url) { continuation.resume(returning: $0) }
        }
    }

    func finishMove(_ url: URL?) {
        guard let request = moveRequest else { return }
        moveRequest = nil
        request.answer(url)
    }

    /// Saves `data` where the person chooses, in Files. False when it was cancelled or couldn't be written.
    func export(_ data: Data, type: UTType, name: String) async -> Bool {
        await withCheckedContinuation { continuation in
            exportRequest = ExportRequest(file: ExportedFile(data: data), type: type, name: name) { continuation.resume(returning: $0) }
        }
    }

    func finishExport(_ saved: Bool) {
        guard let request = exportRequest else { return }
        exportRequest = nil
        request.answer(saved)
    }
}

/// An exported image, handed to the system's Save to Files sheet.
struct ExportedFile: FileDocument {
    static var readableContentTypes: [UTType] { [.png, .jpeg] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

/// The system's share sheet, for the Share button's PNG, which it can save to Photos or Files, send with AirDrop or
/// Messages, or copy. It's handed the finished file. Handed one still to be made, it held up the app for seconds as it
/// opened: it waits for the file on the main thread, which the file needed in order to be made.
enum ShareSheet {
    /// Shows the sheet for the file at `url`, headed `title` and pointing at `anchor`, and returns once it's put away.
    static func present(_ url: URL, title: String, from anchor: UIView?) async {
        let window = anchor?.window ?? UIApplication.shared.connectedScenes.lazy.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        guard let window, var presenter = window.rootViewController else { return }
        while let next = presenter.presentedViewController { presenter = next }
        let sheet = UIActivityViewController(activityItems: [SharedFile(url: url, title: title)], applicationActivities: nil)
        if let popover = sheet.popoverPresentationController {
            if let anchor, anchor.window != nil {
                popover.sourceView = anchor
                popover.sourceRect = anchor.bounds
            } else {
                // The toolbar's trailing end, where the button is.
                popover.sourceView = window
                popover.sourceRect = CGRect(x: window.bounds.maxX - 260, y: window.safeAreaInsets.top, width: 1, height: 44)
            }
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var finished = false
            sheet.completionWithItemsHandler = { _, _, _, _ in
                guard !finished else { return }
                finished = true
                continuation.resume()
            }
            presenter.present(sheet, animated: true)
        }
    }
}

/// The file the share sheet hands on, with what its header shows: the project's name, over the file's, beside the
/// image itself.
private final class SharedFile: NSObject, UIActivityItemSource {
    let url: URL
    let title: String
    init(url: URL, title: String) { self.url = url; self.title = title }

    func activityViewControllerPlaceholderItem(_ controller: UIActivityViewController) -> Any { url }
    func activityViewController(_ controller: UIActivityViewController, itemForActivityType type: UIActivity.ActivityType?) -> Any? { url }
    func activityViewControllerLinkMetadata(_ controller: UIActivityViewController) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = title
        metadata.originalURL = url
        metadata.iconProvider = NSItemProvider(contentsOf: url)
        return metadata
    }
}

/// What the share sheet points at: a view behind the Share button.
final class ShareAnchor {
    weak var view: UIView?
}

struct ShareAnchorView: UIViewRepresentable {
    let anchor: ShareAnchor
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        anchor.view = view
        return view
    }
    func updateUIView(_ view: UIView, context: Context) { anchor.view = view }
}

extension View {
    /// Presents what `dialogs` is asking for.
    func sceneDialogs(_ dialogs: SceneDialogs) -> some View { modifier(SceneDialogsPresenter(dialogs: dialogs)) }
}

private struct SceneDialogsPresenter: ViewModifier {
    let dialogs: SceneDialogs

    func body(content: Content) -> some View {
        content
            .sheet(item: Binding(get: { dialogs.sheet }, set: { if $0 == nil { dialogs.sheet?.cancel() } })) { sheet in
                NavigationStack {
                    sheet.content
                        .navigationTitle(sheet.title)
                        .navigationBarTitleDisplayMode(.inline)
                }
                .presentationSizing(.fitted)
            }
            .alert(dialogs.question?.prompt.title ?? "", isPresented: Binding(get: { dialogs.question != nil }, set: { shown in
                // Dismissed without a button (there is always one): take it as the cancel button.
                if !shown, let question = dialogs.question { dialogs.answer(question.prompt.cancel ?? 0) }
            }), presenting: dialogs.question) { question in
                ForEach(Array(question.prompt.buttons.enumerated()), id: \.offset) { index, title in
                    Button(title, role: index == question.prompt.cancel ? .cancel : nil) { dialogs.answer(index) }
                }
            } message: { question in
                Text(question.prompt.message)
            }
            // Each picker hangs off a view of its own: two on one view, SwiftUI shows only one of them.
            .background {
                Color.clear
                    .fileImporter(isPresented: Binding(get: { dialogs.fileRequest != nil }, set: { shown in
                        // The picker reports what was chosen before it closes; closing with nothing reported is a
                        // cancel, settled once the report has had its chance.
                        if !shown { DispatchQueue.main.async { dialogs.finishFiles([]) } }
                    }), allowedContentTypes: dialogs.fileRequest?.types ?? [.item],
                                  allowsMultipleSelection: dialogs.fileRequest?.multiple ?? false) { result in
                        dialogs.finishFiles((try? result.get()) ?? [])
                    }
            }
            .background {
                Color.clear
                    .fileExporter(isPresented: Binding(get: { dialogs.exportRequest != nil }, set: { shown in
                        if !shown { DispatchQueue.main.async { dialogs.finishExport(false) } }
                    }), document: dialogs.exportRequest?.file, contentType: dialogs.exportRequest?.type ?? .png,
                                  defaultFilename: dialogs.exportRequest?.name) { result in
                        dialogs.finishExport((try? result.get()) != nil)
                    }
            }
            .background {
                Color.clear
                    .photosPicker(isPresented: Binding(get: { dialogs.photosRequest != nil }, set: { shown in
                        // The picker hands over what was chosen as it closes; closing without that is a cancel.
                        if !shown { DispatchQueue.main.async { dialogs.finishPhotos([]) } }
                    }), selection: Binding(get: { [] }, set: { dialogs.finishPhotos($0) }),
                                  matching: .images, preferredItemEncoding: .current)
            }
            .background {
                Color.clear
                    .fileMover(isPresented: Binding(get: { dialogs.moveRequest != nil }, set: { shown in
                        if !shown { DispatchQueue.main.async { dialogs.finishMove(nil) } }
                    }), file: dialogs.moveRequest?.url) { result in
                        dialogs.finishMove(try? result.get())
                    }
            }
    }
}
