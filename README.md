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

## Controls and settings

### General

- **Voice** chooses any voice installed in macOS. Enter text and select **Speak** (or press Command–Return) to read it.
- **Sweep** and **Demo** run the corresponding noSpeaker CLI demonstrations. **Stop** terminates active CLI and haptic output.
- **Dark** and **Plain** pass the matching display modes to noSpeaker. **External trackpad** passes `--external` for a connected Magic Trackpad.
- **Output** shows whether the CLI process is running and its live stdout/stderr log.
- **Help** opens this settings guide. **Check for Updates** checks the GitHub releases page.

### Keyboard

The on-screen piano and computer keyboard play the selected instrument. Hold **A W S E D F T G Y H U J K** to play chromatic notes from C of the selected octave through B. The default is C4–B4. Use **<<** and **>>** or **Command–Up / Command–Down** to select C1–B1 through C7–B7. The range is limited to octaves 1–7. The instrument picker sets the timbre. **Legato** glides into a newly played note; **Portamento Time** sets glide duration from 0 to 200 ms (default 40 ms).

### MIDI player

Select a built-in piece or use **Open File…** to load a Standard MIDI file. Format 0 and Format 1 files are supported; track events are merged and tempo changes are applied. Polyphonic note-ons are mixed together. **Play/Pause** controls playback and **Stop** resets it. The progress bar and current note/instrument label show playback position. **Instrument** selects the sound; **Tempo** ranges from 50% to 200%; **Strength** changes haptic intensity. **Transpose** shifts notes up or down by up to 12 semitones. **Loop** repeats the piece. **Legato** and **Portamento Time** set transitions between overlapping notes. Tip: Convert sheet music to MIDI at musescore.com.

### MIDI input

Enable **MIDI Input**, select a connected Core MIDI source, and press **Refresh** if a device was connected after launch. Note-on starts the matching MIDI pitch; note-off releases it. Multiple notes can sound together.

### Theremin

Drag the slider between **100 Hz** and **4,000 Hz**. To keep updates responsive, the control ignores movements smaller than 10 Hz. Release the slider to stop the tone.

### Instrument presets

Piano uses a struck, bright tone; Organ sustains layered harmonics; Guitar has a plucked second harmonic; Violin has a rich sustained tone; Flute is soft and fundamental-focused; Trumpet emphasizes bright odd harmonics; Bass adds a subharmonic; Xylophone uses an inharmonic partial; Harpsichord is crisp and bright; Theremin is a smooth pure tone.

### Updates

The updater checks the project's GitHub releases for a newer version. Available updates show release notes and provide a DMG download with progress. Open the downloaded DMG, then move noSpeakerUI into Applications to install it.

See [CHANGELOG.md](CHANGELOG.md) for release history.
