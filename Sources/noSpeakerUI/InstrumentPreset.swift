import Foundation

enum InstrumentPreset: String, CaseIterable, Identifiable {
    case piano = "Piano", organ = "Organ", guitar = "Guitar", violin = "Violin", flute = "Flute"
    case trumpet = "Trumpet", bass = "Bass", xylophone = "Xylophone", harpsichord = "Harpsichord", theremin = "Theremin"
    var id: String { rawValue }
    struct Partial { let multiplier: Double; let amplitude: Double }
    var partials: [Partial] {
        switch self {
        case .piano: [Partial(multiplier: 1, amplitude: 1), Partial(multiplier: 2, amplitude: 0.3), Partial(multiplier: 1.5, amplitude: 0.15)]
        case .organ: [Partial(multiplier: 1, amplitude: 1), Partial(multiplier: 2, amplitude: 0.5), Partial(multiplier: 3, amplitude: 0.25)]
        case .violin: [Partial(multiplier: 1, amplitude: 0.8), Partial(multiplier: 2, amplitude: 0.6), Partial(multiplier: 3, amplitude: 0.4)]
        case .guitar: [Partial(multiplier: 1, amplitude: 1), Partial(multiplier: 2, amplitude: 0.4)]
        case .flute, .theremin: [Partial(multiplier: 1, amplitude: 1)]
        case .trumpet: [Partial(multiplier: 1, amplitude: 1), Partial(multiplier: 3, amplitude: 0.5), Partial(multiplier: 5, amplitude: 0.25)]
        case .bass: [Partial(multiplier: 1, amplitude: 1), Partial(multiplier: 0.5, amplitude: 0.4)]
        case .xylophone: [Partial(multiplier: 1, amplitude: 1), Partial(multiplier: 2.76, amplitude: 0.4)]
        case .harpsichord: [Partial(multiplier: 1, amplitude: 0.8), Partial(multiplier: 2, amplitude: 0.6), Partial(multiplier: 4, amplitude: 0.3)]
        }
    }
    var attackTime: Double { switch self { case .violin, .flute, .organ, .theremin: 0.04; default: 0 } }
    var decayTime: Double { switch self { case .piano, .guitar, .xylophone, .harpsichord: 0.08; default: 0 } }
    var strength: Double { switch self { case .bass: 0.9; case .flute: 0.65; default: 0.8 } }
    var harmonicOffset: Int { switch self { case .organ, .violin, .trumpet: 12; case .guitar: 7; default: 0 } }
    var noteDurationMultiplier: Double { switch self { case .xylophone, .piano, .harpsichord: 0.8; default: 1.0 } }
}
