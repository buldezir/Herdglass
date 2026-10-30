import Testing
@testable import Herdglass

/// ⌥⌘↑/↓ and the overlay walk one list of spaces, and a collapsed host takes
/// its spaces off it — so the space on screen is not always on the list it is
/// being walked from. A step from there has to go to the host's neighbours,
/// not back to an end, and a look that never stepped must not land anywhere.
struct SpaceWalkTests {
    private typealias Origin = SpaceSwitcherModel.Origin

    @Test func aTileStepsToItsNeighboursAndWraps() {
        #expect(Origin.tile(1).index(steppedBy: 1, count: 4) == 2)
        #expect(Origin.tile(1).index(steppedBy: -1, count: 4) == 0)
        #expect(Origin.tile(3).index(steppedBy: 1, count: 4) == 0)
        #expect(Origin.tile(0).index(steppedBy: -1, count: 4) == 3)
        #expect(Origin.tile(2).index(steppedBy: 0, count: 4) == 2)
    }

    /// The window is on a collapsed host whose place in the sidebar is above
    /// the third listed space: down is that space, up is the one before it.
    @Test func betweenTwoTilesStepsToTheTileOnThatSide() {
        #expect(Origin.between(2).index(steppedBy: 1, count: 4) == 2)
        #expect(Origin.between(2).index(steppedBy: -1, count: 4) == 1)
    }

    /// No host selected, or the collapsed host is first or last: the walk
    /// steps in from whichever end it is heading away from.
    @Test func betweenAtAnEndStepsInFromThatEnd() {
        #expect(Origin.between(0).index(steppedBy: 1, count: 4) == 0)
        #expect(Origin.between(0).index(steppedBy: -1, count: 4) == 3)
        #expect(Origin.between(4).index(steppedBy: 1, count: 4) == 0)
        #expect(Origin.between(4).index(steppedBy: -1, count: 4) == 3)
    }

    /// A ⌥⌘ hold opens the overlay without stepping. From between two tiles
    /// that highlights nothing, and letting go of nothing switches nothing.
    @Test func notSteppingFromBetweenTwoTilesIsNoTile() {
        #expect(Origin.between(2).index(steppedBy: 0, count: 4) == nil)
        #expect(Origin.tile(0).index(steppedBy: 1, count: 0) == nil)
    }
}
