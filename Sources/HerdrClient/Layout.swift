import Foundation

/// How Herdr splits a tab. `right` puts the second pane beside the first,
/// `down` puts it underneath — the same two directions `pane.split` accepts.
public enum SplitDirection: String, Codable, Sendable {
    case right
    case down
}

/// A neighbour direction, as `pane.focus_direction` and `pane.resize` take it.
/// Wider than `SplitDirection`, which only names the two ways a split is made.
public enum PaneDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

/// What `pane.focus_direction` answers: the pane Herdr moved the focus to, and
/// whether it moved at all (`changed` is false with `reason` `no_neighbor` when
/// the direction leads off the edge of the split).
///
/// A GUI client needs the id, not just the acknowledgement: its own selection —
/// the accent border and the keyboard — is its own, and only follows the server
/// when it is told where the server went.
public struct PaneFocus: Codable, Sendable {
    public var changed: Bool
    public var focusedPaneId: String
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case changed
        case focusedPaneId = "focused_pane_id"
        case reason
    }
}

/// The split tree of one tab, as returned by `layout.export`.
///
/// The flat `layouts` array in `session.snapshot` carries cell rectangles and a
/// list of splits, but not how they nest; this is the shape a GUI can actually
/// build nested split views from.
public struct LayoutTree: Codable, Sendable {
    public var workspaceId: String
    public var tabId: String
    public var zoomed: Bool
    public var focusedPaneId: String
    public var root: LayoutNode

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case zoomed
        case focusedPaneId = "focused_pane_id"
        case root
    }

    public var paneIds: [String] { root.paneIds }
}

/// One node of a tab's split tree: either a pane or a split of two subtrees.
public indirect enum LayoutNode: Codable, Sendable {
    case pane(paneId: String?, label: String?, cwd: String?)
    case split(direction: SplitDirection, ratio: Double, first: LayoutNode, second: LayoutNode)

    enum CodingKeys: String, CodingKey {
        case type, direction, ratio, first, second, label, cwd
        case paneId = "pane_id"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(
                paneId: try container.decodeIfPresent(String.self, forKey: .paneId),
                label: try container.decodeIfPresent(String.self, forKey: .label),
                cwd: try container.decodeIfPresent(String.self, forKey: .cwd)
            )
        case "split":
            self = .split(
                direction: try container.decode(SplitDirection.self, forKey: .direction),
                ratio: try container.decode(Double.self, forKey: .ratio),
                first: try container.decode(LayoutNode.self, forKey: .first),
                second: try container.decode(LayoutNode.self, forKey: .second)
            )
        case let other:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "unknown layout node type \(other)"
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let paneId, let label, let cwd):
            try container.encode("pane", forKey: .type)
            try container.encodeIfPresent(paneId, forKey: .paneId)
            try container.encodeIfPresent(label, forKey: .label)
            try container.encodeIfPresent(cwd, forKey: .cwd)
        case .split(let direction, let ratio, let first, let second):
            try container.encode("split", forKey: .type)
            try container.encode(direction, forKey: .direction)
            try container.encode(ratio, forKey: .ratio)
            try container.encode(first, forKey: .first)
            try container.encode(second, forKey: .second)
        }
    }

    /// Panes in display order — first child before second, all the way down.
    public var paneIds: [String] {
        switch self {
        case .pane(let paneId, _, _):
            return paneId.map { [$0] } ?? []
        case .split(_, _, let first, let second):
            return first.paneIds + second.paneIds
        }
    }

    public var isSplit: Bool {
        if case .split = self { return true }
        return false
    }

    /// Structure without ratios. Rebuilding the view hierarchy is only needed
    /// when this changes; a new ratio just moves a divider.
    public var structureSignature: String {
        switch self {
        case .pane(let paneId, _, _):
            return "p(\(paneId ?? "-"))"
        case .split(let direction, _, let first, let second):
            return "s(\(direction.rawValue),\(first.structureSignature),\(second.structureSignature))"
        }
    }

    /// The `layout.set_split_ratio` path to this node: one bool per descent,
    /// `false` into `first`, `true` into `second`.
    public func path(toPane paneId: String) -> [Bool]? {
        switch self {
        case .pane(let id, _, _):
            return id == paneId ? [] : nil
        case .split(_, _, let first, let second):
            if let path = first.path(toPane: paneId) { return [false] + path }
            if let path = second.path(toPane: paneId) { return [true] + path }
            return nil
        }
    }
}

/// A tab's layout as it appears in `session.snapshot`: cell rectangles and a
/// flat list of splits. Used to notice that a tab's layout changed without
/// asking for the tree on every poll.
public struct LayoutSummary: Codable, Sendable {
    public struct Rect: Codable, Sendable, Equatable {
        public var x: Int
        public var y: Int
        public var width: Int
        public var height: Int
    }

    public struct Pane: Codable, Sendable {
        public var paneId: String
        public var focused: Bool
        public var rect: Rect

        enum CodingKeys: String, CodingKey {
            case paneId = "pane_id"
            case focused, rect
        }
    }

    public struct Split: Codable, Sendable {
        public var id: String
        public var direction: SplitDirection
        public var ratio: Double
        public var rect: Rect
    }

    public var workspaceId: String
    public var tabId: String
    public var zoomed: Bool
    public var focusedPaneId: String
    public var panes: [Pane]
    public var splits: [Split]

    enum CodingKeys: String, CodingKey {
        case workspaceId = "workspace_id"
        case tabId = "tab_id"
        case zoomed
        case focusedPaneId = "focused_pane_id"
        case panes, splits
    }

    /// Everything about this layout that would change what the GUI draws:
    /// which panes exist, how they nest, and the ratios. Ratios are rounded so
    /// a redraw is not triggered by float noise the user cannot see.
    public var signature: String {
        let panes = panes.map(\.paneId).joined(separator: ",")
        let splits = splits
            .map { "\($0.id):\($0.direction.rawValue):\(Int(($0.ratio * 1000).rounded()))" }
            .joined(separator: ",")
        return "\(zoomed)|\(panes)|\(splits)"
    }
}
