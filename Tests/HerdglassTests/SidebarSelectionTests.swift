import AppKit
import Testing
@testable import Herdglass

/// A space under a collapsed host has no row, and `NSOutlineView` answers a
/// collapse over the selected row by selecting nothing. The window can still be
/// showing that space — the overlay lands on one, and folding away the host
/// you are in hides one — so the host's row has to stand in for it, and none
/// of that may reach the window as a selection the user made.
@MainActor
struct SidebarSelectionTests {
    private let sidebar = SidebarView(frame: NSRect(x: 0, y: 0, width: 250, height: 600))
    private var outline: NSOutlineView {
        func find(_ view: NSView) -> NSOutlineView? {
            (view as? NSOutlineView) ?? view.subviews.lazy.compactMap(find).first
        }
        return find(sidebar)!
    }

    private var selectedRow: String? {
        outline.selectedRow >= 0 ? outline.item(atRow: outline.selectedRow) as? String : nil
    }

    private static func model(selecting id: String) -> SidebarModel {
        func row(_ id: String, _ kind: SidebarModel.Kind) -> SidebarModel.Row {
            SidebarModel.Row(id: id, kind: kind, title: id, subtitle: "")
        }
        var model = SidebarModel()
        model.hosts = [row("A", .host), row("B", .host)]
        model.spaces = ["A": [row("A/1", .space), row("A/2", .space)], "B": [row("B/1", .space)]]
        model.selectedId = id
        return model
    }

    @Test func collapsingTheSelectedSpacesHostSelectsTheHostAndExpandingGivesItBack() {
        var reported: [String] = []
        sidebar.onSelectHost = { id, _ in reported.append(id) }
        sidebar.onSelectSpace = { id, _ in reported.append(id) }
        sidebar.apply(Self.model(selecting: "A/2"))
        #expect(selectedRow == "A/2")

        outline.collapseItem("A")
        #expect(selectedRow == "A")
        #expect(sidebar.collapsedHosts == ["A"])
        // The next snapshot leaves it there.
        sidebar.apply(Self.model(selecting: "A/2"))
        #expect(selectedRow == "A")

        outline.expandItem("A")
        sidebar.apply(Self.model(selecting: "A/2"))
        #expect(selectedRow == "A/2")
        #expect(reported.isEmpty)
    }

    @Test func landingOnAHiddenSpaceSelectsItsHost() {
        var reported: [String] = []
        sidebar.onSelectHost = { id, _ in reported.append(id) }
        sidebar.onSelectSpace = { id, _ in reported.append(id) }
        sidebar.apply(Self.model(selecting: "B/1"))
        outline.collapseItem("A")
        #expect(selectedRow == "B/1")

        sidebar.apply(Self.model(selecting: "A/1"))
        #expect(selectedRow == "A")
        #expect(reported.isEmpty)
    }

    @Test func onlyAHostTheUserFoldsOrUnfoldsIsAChange() {
        var changes = 0
        sidebar.onCollapsedHostsChange = { changes += 1 }
        // `apply` expands every host on a reload; none of that is the user's.
        sidebar.apply(Self.model(selecting: "B/1"))
        #expect(changes == 0)
        outline.collapseItem("A")
        outline.expandItem("A")
        #expect(changes == 2)
    }
}
