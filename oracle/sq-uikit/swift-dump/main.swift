// Dumps the mascot numbers the Swift tests do not pin: the random generator, the easings and a player trace per animation.
// Output (TAB separated, doubles as 16 hex digits of their bit pattern): rng/ease/trace records, see mascot.tsv header.
import Foundation

func h(_ d: Double) -> String { String(d.bitPattern, radix: 16).leftPad(16) }
extension String { func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self } }

let args = CommandLine.arguments
guard args.count == 2, let json = FileManager.default.contents(atPath: args[1]) else { fatalError("usage: dump pip-anim.json") }
let lib = try SQMascotLibrary(json: json)

print("# mascot oracle from the frozen Swift SQMascotModel/SQMascotPlayer. rng: seed, index, bits. ease: name, t, bits.")
print("# trace: anim, seed, frame (dt 16.7 ms each), resting, blinkCount, busy, then bits of tx, sy, sx, rot, blink, esp, hide.")
for seed in [1, 42, 20261105] as [UInt64] {
    var r = SQMascotRandom(seed: seed)
    for i in 0..<6 { print("rng\t\(seed)\t\(i)\t\(h(r.next()))") }
}
let eases: [(String, SQMascotEase)] = [("lin", .lin), ("io", .io), ("in", .in), ("out", .out), ("back", .back), ("pop", .pop), ("spring", .spring)]
for (name, e) in eases { for t in [0.0, 0.1, 0.37, 0.5, 0.9, 1.0] { print("ease\t\(name)\t\(h(t))\t\(h(e.value(t)))") } }
for a in SQMascotAnim.allCases {
    var p = SQMascotPlayer(animation: lib.animation(a), idle: lib.idle, seed: 7)
    p.start()
    var frame = 0
    let marks: Set<Int> = [1, 10, 60, 200, 600, 1500, 4000]
    while frame < 4000 {
        let pose = p.advance(16.7)
        frame += 1
        if marks.contains(frame) {
            let f = [pose[.tx], pose[.sy], pose[.sx], pose[.rot], pose.blink, pose[.esp], pose[.hide]].map(h).joined(separator: "\t")
            print("trace\t\(a.rawValue)\t7\t\(frame)\t\(p.resting)\t\(p.blinkCount)\t\(p.isBusy)\t\(f)")
        }
    }
}
