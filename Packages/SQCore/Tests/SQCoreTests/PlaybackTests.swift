import Testing
@testable import SQCore

@Suite struct PlaybackTests {
    enum Step { case press(ShuttleKey), release(ShuttleKey), hold(ShuttleKey) }

    static func run(_ steps: [Step]) -> (Shuttle, [ShuttleAction]) {
        var s = Shuttle()
        var out: [ShuttleAction] = []
        for st in steps {
            switch st {
            case .press(let k): out.append(s.press(k))
            case .release(let k): out.append(s.release(k))
            case .hold(let k): out.append(s.holdElapsed(k))
            }
        }
        return (s, out)
    }

    @Test func rateBasics() {
        #expect(PlaybackRate(2, 4) == PlaybackRate(1, 2))
        #expect(PlaybackRate(1, -4) == PlaybackRate(-1, 4))
        #expect(PlaybackRate(-2).isReverse)
        #expect(PlaybackRate(-2).magnitude == PlaybackRate(2))
        #expect(PlaybackRate(0, 5) == .zero)
        #expect(PlaybackRate.zero.isPaused)
    }

    @Test func sequences() {
        typealias C = (String, [Step], PlaybackRate)
        let cases: [C] = [
            ("L", [.press(.l)], PlaybackRate(1)),
            ("L L", [.press(.l), .press(.l)], PlaybackRate(2)),
            ("L L L", [.press(.l), .press(.l), .press(.l)], PlaybackRate(4)),
            ("L x4", Array(repeating: .press(.l), count: 4), PlaybackRate(8)),
            ("L x5 capped", Array(repeating: .press(.l), count: 5), PlaybackRate(8)),
            ("J J", [.press(.j), .press(.j)], PlaybackRate(-2)),
            ("L L J decelerates", [.press(.l), .press(.l), .press(.j)], PlaybackRate(1)),
            ("L J at 1x reverses", [.press(.l), .press(.j)], PlaybackRate(-1)),
            ("J J L decelerates", [.press(.j), .press(.j), .press(.l)], PlaybackRate(-1)),
            ("J L at -1x reverses", [.press(.j), .press(.l)], PlaybackRate(1)),
            ("L L L J", [.press(.l), .press(.l), .press(.l), .press(.j)], PlaybackRate(2)),
            ("L L L J J", [.press(.l), .press(.l), .press(.l), .press(.j), .press(.j)], PlaybackRate(1)),
            ("L L L J J J", [.press(.l), .press(.l), .press(.l), .press(.j), .press(.j), .press(.j)], PlaybackRate(-1)),
            ("L L L J K", [.press(.l), .press(.l), .press(.l), .press(.j), .press(.k)], .zero),
            ("L K", [.press(.l), .press(.k)], .zero),
            ("K+L held", [.press(.k), .press(.l), .hold(.l)], PlaybackRate(1, 4)),
            ("K+J held", [.press(.k), .press(.j), .hold(.j)], PlaybackRate(-1, 4)),
            ("K+L held, release L", [.press(.k), .press(.l), .hold(.l), .release(.l)], .zero),
            ("K+L held, release K", [.press(.k), .press(.l), .hold(.l), .release(.k)], PlaybackRate(1)),
            ("K+tap L", [.press(.k), .press(.l), .release(.l)], .zero),
        ]
        for (name, steps, expected) in cases {
            let (s, _) = Self.run(steps)
            #expect(s.rate == expected, "\(name)")
        }
    }

    @Test func tapsStepOneFrame() {
        let (_, a) = Self.run([.press(.k), .press(.l), .release(.l)])
        #expect(a == [.setRate(.zero), .step(1), .none])
        let (_, b) = Self.run([.press(.k), .press(.j), .release(.j)])
        #expect(b == [.setRate(.zero), .step(-1), .none])
    }

    @Test func holdWithoutKIsIgnored() {
        let (s, a) = Self.run([.press(.l), .hold(.l)])
        #expect(a.last == ShuttleAction.none)
        #expect(s.rate == .forward)
    }

    @Test func followsNudgedRateAndClampsAtEight() {
        // The app layer changed the speed (Shift+L): doubling must never pass 8x, a rate of 5 goes to 8 not 10.
        for (start, expected) in [(PlaybackRate(3), PlaybackRate(6)), (PlaybackRate(5), PlaybackRate(8)), (PlaybackRate(7), PlaybackRate(8)),
                                  (PlaybackRate(-5), PlaybackRate(-8)), (PlaybackRate(9, 2), PlaybackRate(8))] {
            var s = Shuttle()
            s.adopt(start)
            #expect(s.press(start.isForward ? .l : .j) == .setRate(expected), "\(start)")
        }
        // 1.25x (Shift+L from a stop) then J: slows to 1x, then reverses.
        var s = Shuttle()
        s.adopt(PlaybackRate(5, 4))
        #expect(s.press(.j) == .setRate(PlaybackRate(1)))
        #expect(s.press(.j) == .setRate(PlaybackRate(-1)))
    }

    /// Focus loss (Cmd-Tab with K held): the key up goes to another app. Afterwards L must play, not step a frame.
    @Test func allKeysReleasedForgetsHeldK() {
        var s = Shuttle()
        _ = s.press(.k)
        #expect(s.allKeysReleased() == .none)
        #expect(s.press(.l) == .setRate(PlaybackRate(1)))
    }

    /// Slow mode (K + L held) ends when the keys are lost: playback stops instead of crawling on at 1/4.
    @Test func allKeysReleasedStopsSlowMode() {
        var s = Shuttle()
        _ = s.press(.k)
        _ = s.press(.l)
        #expect(s.holdElapsed(.l) == .setRate(PlaybackRate(1, 4)))
        #expect(s.allKeysReleased() == .setRate(.zero))
        #expect(s.rate == .zero)
        #expect(s.allKeysReleased() == .none)
    }

    /// Plain L play keeps running when the window loses focus (only the held state goes).
    @Test func allKeysReleasedKeepsNormalPlayback() {
        var s = Shuttle()
        _ = s.press(.l)
        #expect(s.allKeysReleased() == .none)
        #expect(s.rate == PlaybackRate(1))
        #expect(s.press(.l) == .setRate(PlaybackRate(2)))
    }
}
