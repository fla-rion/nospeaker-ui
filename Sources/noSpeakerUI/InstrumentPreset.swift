import Foundation

enum InstrumentPreset: String, CaseIterable, Identifiable {
    case piano = "Piano", organ = "Organ", guitar = "Guitar", violin = "Violin", flute = "Flute"
    case trumpet = "Trumpet", bass = "Bass", xylophone = "Xylophone", harpsichord = "Harpsichord", theremin = "Theremin"
    var id: String { rawValue }
    var attackTime: Double { switch self { case .violin, .flute, .organ, .theremin: 0.04; default: 0 } }
    var decayTime: Double { switch self { case .piano, .guitar, .xylophone, .harpsichord: 0.08; default: 0 } }
    var strength: Double { switch self { case .bass: 0.9; case .flute: 0.65; default: 0.8 } }
    var harmonicOffset: Int { switch self { case .organ, .violin, .trumpet: 12; case .guitar: 7; default: 0 } }
    var noteDurationMultiplier: Double { switch self { case .xylophone, .piano, .harpsichord: 0.8; default: 1.0 } }
}
