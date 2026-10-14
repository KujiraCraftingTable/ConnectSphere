import Foundation
import Testing
@testable import ConnectSphere

/// Highlights: decoding, the viewer's clock, the editor's rules.
@MainActor
struct HighlightTests {
    private func highlight(items: Int) throws -> Highlight {
        let list = (0..<items).map { #"{"id":"i\#($0)","image_url":"/uploads/\#($0).jpg","created_at":"2026-10-15T09:00:00.000Z"}"# }
        let json = #"{"id":"h1","title":"Trips","cover_url":"/uploads/0.jpg","items":[\#(list.joined(separator: ","))]}"#
        return try JSONDecoder.makeISO8601().decode(Highlight.self, from: Data(json.utf8))
    }

    @Test func decodes() throws {
        let h = try highlight(items: 3)
        #expect(h.title == "Trips" && h.items.count == 3 && h.coverUrl == "/uploads/0.jpg")
    }

    @Test func viewerAdvancesEveryFiveSecondsAndEnds() throws {
        let vm = HighlightViewerViewModel(highlight: try highlight(items: 2))
        #expect(!vm.tick(2.5) && vm.index == 0 && vm.progress(0) == 0.5)
        #expect(!vm.tick(2.5) && vm.index == 1)        // on to the second photo
        #expect(vm.progress(0) == 1 && vm.progress(1) == 0)
        #expect(vm.tick(5))                             // the last one finished → close
    }

    @Test func viewerBackAndForth() throws {
        let vm = HighlightViewerViewModel(highlight: try highlight(items: 3))
        #expect(!vm.next() && vm.index == 1)
        vm.previous()
        #expect(vm.index == 0)
        vm.previous()
        #expect(vm.index == 0)
    }

    @Test func editorNeedsATitleAndAPhoto() throws {
        let vm = HighlightEditorViewModel()
        vm.title = "Trips"
        #expect(!vm.canSave)                 // no photo yet
        vm.toggleStory("s1")
        #expect(vm.canSave)
        vm.title = String(repeating: "x", count: 31)
        #expect(!vm.canSave && vm.titleTooLong)

        let edit = HighlightEditorViewModel(editing: try highlight(items: 1))
        #expect(!edit.canSave)               // nothing changed
        edit.title = "Summer"
        #expect(edit.canSave)                // a rename is enough
    }
}
