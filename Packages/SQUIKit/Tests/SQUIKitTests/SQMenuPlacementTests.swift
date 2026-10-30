import Foundation
import Testing
@testable import SQUIKit

@Suite struct SQMenuPlacementTests {
    let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let m = SQMenuLayout.screenMargin

    @Test func shortMenuOpensBelowTheAnchor() {
        let r = SQMenuLayout.placement(content: CGSize(width: 200, height: 300), anchor: CGPoint(x: 100, y: 700), anchorTop: 724, screen: screen)
        #expect(r == CGRect(x: 100, y: 400, width: 200, height: 300))
    }

    @Test func menuFlipsAboveWhenBelowIsTooSmallButAboveFits() {
        let r = SQMenuLayout.placement(content: CGSize(width: 200, height: 300), anchor: CGPoint(x: 100, y: 200), anchorTop: 224, screen: screen)
        #expect(r == CGRect(x: 100, y: 224, width: 200, height: 300))
    }

    @Test func tallMenuIsClampedToTheRoomierSideAndScrolls() {
        // Anchor near the top: below has 700 - 8, above has 900 - 8 - 724 = 168.
        let r = SQMenuLayout.placement(content: CGSize(width: 200, height: 2000), anchor: CGPoint(x: 100, y: 700), anchorTop: 724, screen: screen)
        #expect(r.height == 700 - m)
        #expect(r.minY == m)
        #expect(r.maxY == 700)
    }

    @Test func tallMenuWithoutRoomOnEitherSideFillsTheScreenHeight() {
        let r = SQMenuLayout.placement(content: CGSize(width: 200, height: 2000), anchor: CGPoint(x: 100, y: 150), anchorTop: 170, screen: CGRect(x: 0, y: 0, width: 800, height: 300))
        #expect(r.height == 300 - 2 * m)
        #expect(r.minY == m && r.maxY == 300 - m)
    }

    @Test func menuWithoutControlSlidesIntoTheScreen() {
        let r = SQMenuLayout.placement(content: CGSize(width: 200, height: 300), anchor: CGPoint(x: 100, y: 120), anchorTop: nil, screen: screen)
        #expect(r.minY == m && r.height == 300)
    }

    @Test func frameStaysFullyOnScreenOnAnyAnchor() {
        let screens = [CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 1440, y: -200, width: 1920, height: 1055),
                       CGRect(x: -1280, y: 25, width: 1280, height: 775)]
        for sc in screens {
            let area = sc.insetBy(dx: m, dy: m)
            for h in [100.0, 600, 5000] as [CGFloat] {
                for ax in [sc.minX - 50, sc.midX, sc.maxX - 10] {
                    for ay in [sc.minY + 5, sc.midY, sc.maxY] {
                        for top in [nil, ay + 24] as [CGFloat?] {
                            let r = SQMenuLayout.placement(content: CGSize(width: 220, height: h), anchor: CGPoint(x: ax, y: ay), anchorTop: top, screen: sc)
                            #expect(area.contains(r), "\(sc) \(h) \(ax) \(ay) \(String(describing: top)) -> \(r)")
                            #expect(r.height <= SQMenuLayout.maxHeight(screen: sc))
                        }
                    }
                }
            }
        }
    }

    @Test func releaseOfTheOpeningClickNeverSelects() {
        // Still, short, or quick: ignored even over a row.
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: true, moved: 0, held: 0.05) == .ignore)
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: true, moved: 0, held: 2) == .ignore)
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: true, moved: 2, held: 2) == .ignore)
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: true, moved: 30, held: 0.05) == .ignore)
        // Press-drag-release: moved clearly and after a delay.
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: true, moved: 12, held: 0.4) == .activate)
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: false, moved: 12, held: 0.4) == .dismiss)
    }

    @Test func releaseOverTheAnchorLeavesTheMenuOpen() {
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: false, overAnchor: true, moved: 12, held: 0.5) == .ignore)
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: true, overAnchor: false, moved: 12, held: 0.5) == .activate)
        #expect(SQMenuReleaseRule.outcome(pressedInList: false, overRow: false, overAnchor: false, moved: 12, held: 0.5) == .dismiss)
    }

    @Test func submenuTopFollowsTheParentScroll() {
        let unscrolled = SQMenuLayout.submenuTop(parentMaxY: 800, rowMinY: 300, parentScroll: 0)
        let scrolled = SQMenuLayout.submenuTop(parentMaxY: 800, rowMinY: 300, parentScroll: 120)
        #expect(scrolled == unscrolled + 120)
    }

    @Test func aNewClickInTheListSelectsOnRelease() {
        #expect(SQMenuReleaseRule.outcome(pressedInList: true, overRow: true, moved: 0, held: 0.05) == .activate)
        #expect(SQMenuReleaseRule.outcome(pressedInList: true, overRow: false, moved: 0, held: 1) == .ignore)
    }
}

@Suite struct SQFontSearchTests {
    let fams = ["Helvetica", "Inter Tight", "Inter", "Interstate", "Bebas Neue", "Winter Sans", "Écriture", "Avenir Next"]

    @Test func visibleListMatchesWhatReturnPicks() {
        for q in ["Inter", "inter", "INTER", " inter ", "ecri", "next", "Inter Tight"] {
            var m = SQFontFieldModel(families: fams)
            m.setQuery(q)
            let firstShown = m.rows.compactMap { r -> String? in if case .font(let n, _, _) = r { n } else { nil } }.first
            #expect(m.returnTarget == firstShown, "\(q)")
            #expect(m.returnTarget != nil, "\(q)")
        }
    }

    @Test func exactFamilyRanksFirstAndMatchingIsAnywhere() {
        #expect(SQFontFieldModel.matches(query: "Inter", in: fams).first == "Inter")
        #expect(SQFontFieldModel.matches(query: "ecriture", in: fams) == ["Écriture"])
        #expect(SQFontFieldModel.matches(query: "nter", in: fams).contains("Winter Sans"))
    }

    @Test func aLateResultNeverReplacesANewerOne() {
        var g = SQSearchGuard()
        let first = g.begin()
        #expect(g.isCurrent(first))
        let second = g.begin()
        #expect(!g.isCurrent(first))
        #expect(g.isCurrent(second))
    }
}
