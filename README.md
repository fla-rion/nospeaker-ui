# noSpeakerUI

A SwiftUI wrapper for the [noSpeaker](https://github.com/os6/nospeaker) haptic synthesizer — turn your MacBook Force Touch trackpad into a musical instrument. Fully integrates with Logic Pro, Ableton Live, and any Core MIDI application.

## Features

- **Text-to-Speech**: Type text, hear it through the trackpad
- **Keyboard Synthesizer**: On-screen piano (C1–C7) + computer keyboard (A W S E D F T G Y H U J K), sustain pedal (Space), octave switching (Cmd+↑↓)
- **MIDI File Player**: 10 built-in classical pieces + load any .mid file. Tempo, transpose, loop, legato, polyphony control
- **Core MIDI Input**: Connect any MIDI keyboard or controller
- **Theremin Mode**: Slider from 100 Hz to 4,000 Hz
- **10 Instrument Presets**: Piano, Organ, Guitar, Violin, Flute, Trumpet, Bass, Xylophone, Harpsichord, Theremin
- **Multi-Trackpad**: Built-in + external Magic Trackpad simultaneously (melody/harmony split)
- **DAW Integration**: Virtual MIDI port "noSpeakerUI Haptic Synth" — route notes from Logic Pro, Ableton, GarageBand
- **Presets**: Save/load instrument configurations as named presets
- **Frequency Visualizer**: Live bar chart of active haptic frequencies
- **Bookworm**: Load .txt/.rtf/.pdf files and read them aloud via the trackpad
- **Welcome Melody**: Arpeggio jingle on every launch
- **Auto-Updater**: Downloads new versions from GitHub with progress bar
- **Extended Frequency Mode**: 100–8,000 Hz (experimental)

## DAW Integration (Logic Pro / Ableton)

noSpeakerUI registers a virtual Core MIDI destination automatically at launch. No driver installation required.

### Logic Pro
1. Create a Software Instrument track
2. In the track header, click the MIDI In selector
3. Choose **noSpeakerUI Haptic Synth**
4. Play the keyboard or trigger from the piano roll — the trackpad plays every note

### Ableton Live
1. Open Preferences → Link, Tempo & MIDI → MIDI Ports
2. Find **noSpeakerUI Haptic Synth** under Output
3. Enable **Track** for that port
4. Set any MIDI track's output to noSpeakerUI Haptic Synth
5. Record or play back — the trackpad responds in real time

### MIDI Channel → Instrument Mapping
| Channel | Instrument |
|---------|-----------|
| 1 | Piano |
| 2 | Organ |
| 3 | Guitar |
| 4 | Violin |
| 5 | Flute |
| 6 | Trumpet |
| 7 | Bass |
| 8 | Xylophone |
| 9 | Harpsichord |
| 10 | Percussion |

### Supported MIDI Messages
- **Note On/Off** — plays haptic notes
- **Program Change** — selects instrument preset (0–9)
- **CC #7 / #11** — Volume / Expression (scales haptic strength)
- **CC #123 / #120** — All Notes Off / All Sound Off
- **MIDI Clock** — displayed in DAW tab (sync indicator)

## Requirements
- macOS 12 or later
- Force Touch trackpad (built-in MacBook 2015+ or Magic Trackpad 2+)

## Installation
1. Download `noSpeakerUI-vX.X.dmg` from [Releases](https://github.com/fla-rion/nospeaker-ui/releases)
2. Open the DMG and drag noSpeakerUI to Applications
3. Double-click **Zertifikat installieren.command** in the DMG to trust the app certificate (once)
4. Launch and enjoy

## Building from Source
```bash
git clone https://github.com/fla-rion/nospeaker-ui
cd nospeaker-ui
./build-app.sh
open build/noSpeakerUI.app
```

## Credits
- [noSpeaker](https://github.com/os6/nospeaker) by Cody Collier (MIT)
- Classical MIDI files from [Mutopia Project](https://www.mutopiaproject.org) (Public Domain)

## License
MIT
