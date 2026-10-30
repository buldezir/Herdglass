import Foundation
import HerdrClient
import Testing
@testable import Herdglass

/// The cell under the pointer is worked out here because libghostty has no
/// call for it, from a padding it has no getter for either. A row off by one
/// clicks the wrong item in every program that takes the mouse.
struct TerminalGridTests {
    /// 80x24 at 16x34 px cells, with ghostty's default 2pt padding at 2x and the
    /// leftover pixels on the right and bottom, as unbalanced padding leaves them.
    private func grid(left: Double = 4, top: Double = 4) -> TerminalSession.Grid {
        var grid = TerminalSession.Grid(
            columns: 80, rows: 24, cellWidth: 16, cellHeight: 34,
            width: 80 * 16 + 4 + 4 + 7, height: 24 * 34 + 4 + 4 + 11
        )
        grid.origin = CGPoint(x: left, y: top)
        return grid
    }

    @Test func aPointIsInTheCellLibghosttyWouldPutItIn() {
        let grid = grid()
        #expect(grid.cell(atPixelX: 4, y: 4) == .init(column: 0, row: 0))
        #expect(grid.cell(atPixelX: 19.9, y: 37.9) == .init(column: 0, row: 0))
        #expect(grid.cell(atPixelX: 20, y: 38) == .init(column: 1, row: 1))
        // The padding belongs to the first cell, not to a cell before it.
        #expect(grid.cell(atPixelX: 0, y: 0) == .init(column: 0, row: 0))
    }

    @Test func aDragOffTheGridClampsToItsEdge() {
        let grid = grid()
        #expect(grid.cell(atPixelX: -50, y: -50) == .init(column: 0, row: 0))
        #expect(grid.cell(atPixelX: 10_000, y: 10_000) == .init(column: 79, row: 23))
    }

    /// `read_text` and `ime_point` as libghostty computes them (Surface.zig's
    /// `dumpTextLocked` and `imePointScaled`), in points at `scale`.
    private func answers(left: Double, top: Double, baseline: Double, cursorRow: Double, scale: Double = 2)
        -> (firstCell: CGPoint, cursorBottom: Double) {
        let cellHeight = 34.0
        return (
            CGPoint(x: left / scale, y: (cellHeight - baseline + top) / scale),
            ((cursorRow + 1) * cellHeight + top) / scale
        )
    }

    @Test func thePaddingIsReadBackFromWhatLibghosttyReports() {
        let grid = grid()
        for (left, top, baseline, cursorRow) in [(4.0, 4.0, 8.0, 0.0), (4, 4, 8, 23), (4, 9, 0, 12), (12, 2, 33, 5)] {
            let (firstCell, cursorBottom) = answers(left: left, top: top, baseline: baseline, cursorRow: cursorRow)
            let origin = grid.origin(firstCellTopLeft: firstCell, cursorBottom: cursorBottom, scale: 2)
            #expect(origin == CGPoint(x: left, y: top), "left \(left) top \(top) baseline \(baseline) row \(cursorRow)")
        }
    }

    @Test func anAnswerThatCannotBeRightFallsBackToTheLeftPadding() {
        let grid = grid()
        // A top past the spare height cannot be the padding.
        let origin = grid.origin(firstCellTopLeft: CGPoint(x: 2, y: 40), cursorBottom: 40 + 17, scale: 2)
        #expect(origin == CGPoint(x: 4, y: 4))
        // `read_text` answers -1 when the cell is not in the viewport.
        #expect(grid.origin(firstCellTopLeft: CGPoint(x: -1, y: -1), cursorBottom: 0, scale: 2) == .zero)
    }
}
