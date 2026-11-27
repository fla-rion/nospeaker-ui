# noSpeakerUI

A SwiftUI wrapper for the [noSpeaker](https://github.com/os6/nospeaker) haptic synthesizer — turn your MacBook Force Touch trackpad into a musical instrument.

## Features

- **Text-to-Speech**: Type any text and hear it through the trackpad.
- **Keyboard Synthesizer**: Play notes with your computer keyboard or on-screen piano (C3–C5).
- **MIDI File Player**: Load any `.mid` file or choose from 10 built-in classical pieces.
- **Core MIDI Input**: Connect any Core MIDI-compatible device.
- **Theremin Mode**: Slide a control to glide between 100 Hz and 4,000 Hz.
- **10 Instrument Presets**: Piano, Organ, Guitar, Violin, Flute, Trumpet, Bass, Xylophone, Harpsichord, Theremin.
- **Welcome Melody**: A short arpeggio plays on every launch.
- **Auto-Updater**: Checks GitHub releases and downloads updates with a progress bar.

## Built-in Pieces (Public Domain, Mutopia Project)

| # | Piece | Composer | Difficulty |
|---|-------|----------|------------|
| 1 | Für Elise | Beethoven | Medium |
| 2 | Mondscheinsonate | Beethoven | Advanced |
| 3 | Kanon in D | Pachelbel | Easy |
| 4 | Türkischer Marsch | Mozart | Medium |
| 5 | The Entertainer | Joplin | Medium |
| 6 | Gymnopédie Nr. 1 | Satie | Easy |
| 7 | Swan Lake Theme | Tchaikovsky | Easy |
| 8 | Ode an die Freude | Beethoven | Easy |
| 9 | Eine Kleine Nachtmusik | Mozart | Medium |
| 10 | Vivaldi: Frühling | Vivaldi | Advanced |

## Requirements

- macOS 12 or later
- Force Touch trackpad (built-in MacBook 2015+ or Magic Trackpad 2+)
- For MIDI input: any Core MIDI-compatible device

## Installation

1. Download `noSpeakerUI-vX.X.dmg` from [Releases](https://github.com/fla-rion/nospeaker-ui/releases).
2. Open the DMG and drag noSpeakerUI to Applications.
3. Launch and enjoy — place the MacBook on a table for best sound.

## Building from Source

```bash
git clone https://github.com/fla-rion/nospeaker-ui
cd nospeaker-ui
./build-app.sh
open build/noSpeakerUI.app
```

Requires Xcode Command Line Tools (`xcode-select --install`).

## Credits

- [noSpeaker](https://github.com/os6/nospeaker) by Cody Collier (MIT License)
- Classical MIDI files from the [Mutopia Project](https://www.mutopiaproject.org) (Public Domain)

## License

MIT
