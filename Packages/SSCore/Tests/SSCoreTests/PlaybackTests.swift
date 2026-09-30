import Testing
@testable import SSCore

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
            ("L L J", [.press(.l), .press(.l), .press(.j)], PlaybackRate(-1)),
            ("J J L", [.press(.j), .press(.j), .press(.l)], PlaybackRate(1)),
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
}
