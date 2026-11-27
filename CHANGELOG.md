# Changelog

All notable changes to noSpeakerUI are documented here.
Format: [Keep a Changelog](https://keepachangelog.com/en/1.0.0/).

## [1.9.0] - 2026-11-27
### Added
- DAW Integration: virtual Core MIDI destination "noSpeakerUI Haptic Synth" — route notes directly from Logic Pro, Ableton Live, GarageBand, or any Core MIDI application
- DAW tab: status indicator, setup instructions for Logic/Ableton, MIDI channel → instrument mapping, clock indicator
- MIDI channel mapping: Ch 1-10 select instrument presets; velocity controls haptic strength
- Supported MIDI CCs: #7 Volume, #11 Expression, #123 All Notes Off
- MIDI Clock display (sync from DAW shown in DAW tab)
### Updated
- README.md: complete rewrite with DAW integration guide, MIDI channel table, Ableton/Logic setup steps

## [1.8.1] - 2026-11-27
### Fixed
- Shared single HapticEngine between SpeakerController and MIDIPlayer (was two separate instances causing hardware race condition)
- Visualizer throttled to 30 Hz (was 100 Hz, causing excessive MainActor load)
- Fixed retain cycle (missing weak self) in HapticEngine render loop closure

## [1.8.0] - 2026-11-27
### Added
- Presets: save/load instrument+tempo+volume+octave+legato settings as named JSON presets
- Frequency Visualizer: live bar chart of active haptic frequencies in MIDI and Keyboard tabs
- Sustain Pedal: hold Space to sustain notes after key release
- Dark/Light/Auto mode switcher for the app UI
- Multi-Trackpad: use built-in + external Magic Trackpad simultaneously (split melody/harmony)
### Fixed
- Keyboard "k" key now correctly maps to C5 (was B4)
- CertificateInstaller no longer blocks the UI while security dialog is open
- Output log now trims itself at 100,000 characters to prevent memory growth
- Tab switch no longer leaves notes hanging (all keys released on tab change)
- BookwormReader sentence splitting is now O(n) instead of O(n²)

## [1.7.0] - 2026-11-27
### Added
- 📖 Bookworm tab: load .txt, .rtf, or .pdf files and read them aloud via the trackpad haptic motor
- Sentence-by-sentence playback with current sentence display
- Voice selection and reading speed control
- Easter egg: plays a jingle when the word "nospeaker" is detected in the loaded text

## [1.5.1] - 2026-11-27
### Fixed
- Keyboard notes sustain until their key is released, including legato transitions
- MIDI notes use their actual note-off timing and log file loading and parse errors
- Built-in MIDI resources resolve from the app bundle and selected MIDI presets are logged during playback
- MIDI file selection and playback state updates run through the main actor

## [1.5.0] - 2026-11-27
### Added
- Extended frequency mode up to 8000 Hz (experimental, above 4 kHz gets buzzier)
- Frequency mode picker: Standard (100–4000 Hz) vs Extended (100–8000 Hz)
- Polyphony limit setting (1–4 voices)
- Note flash: piano keys light up during MIDI playback
- Debug mode: render loop jitter display
### Improved
- Render loop tightened to 10ms (100 Hz) from 20ms — twice the time resolution
- Polyphonic mixing: frequency-domain normalization, melody gets 60% strength budget
- MIDI multi-track: melody/harmony separation, smart voice dropping above 4 simultaneous notes
- Fast passages (< 150ms notes): staccato override ignores legato setting
- Render timer now uses DispatchSource with userInteractive QoS for < 2ms jitter

## [1.4.0] - 2026-11-27
### Added
- True polyphony: up to 4 simultaneous notes mixed in a single 20ms render loop
- Octave switching: shift keyboard range from C1 to C7 (Cmd+Up/Down shortcuts)
- Transpose control for MIDI playback (±12 semitones)
- Legato mode with configurable portamento glide time (0–200ms)
- Multi-track MIDI support (Format 0 and 1, all tracks merged)
- MIDI tempo change events (meta 0x51) now respected
- Loop mode for MIDI file playback
- Current note display during MIDI playback
### Improved
- MIDI file player handles polyphonic passages correctly
- Consecutive overlapping notes trigger auto-legato

## [1.3.0] - 2026-11-27
### Added
- Welcome melody (C4–C5 arpeggio) plays on every app launch
- Full updater: checks GitHub releases, shows changelog, downloads DMG with progress bar
- README.md with complete documentation, feature list, build instructions
### Improved
- Instrument timbres now use direct MultitouchSupport API with harmonic partials per instrument
- Piano, violin, guitar, organ, trumpet, bass, xylophone, harpsichord, theremin all have distinct tone shapes

## [1.2.0] - 2026-11-27
### Added
- MIDI file player tab with play/pause/stop and progress bar
- 10 built-in classical pieces (Public Domain, Mutopia Project)
- File open dialog for custom .mid files
- 10 instrument presets (Piano, Organ, Guitar, Violin, Flute, Trumpet, Bass, Xylophone, Harpsichord, Theremin)
- Tempo control (50%–200%) and strength slider

## [1.1.0] - 2026-11-27
### Added
- Keyboard synthesizer tab: on-screen piano C3–C5, computer keyboard mapping (a/w/s/e/d/f/t/g/y/h/u/j/k)
- Core MIDI input with source picker (note-on/off → haptic playback)
- Theremin mode: horizontal slider 100–4000 Hz with 10 Hz debounce
- Dark mode and plain mode toggles
- External Magic Trackpad toggle (--external flag)

## [1.0.0] - 2026-11-26
### Added
- Initial SwiftUI wrapper for the noSpeaker CLI
- Text-to-speech via any installed macOS voice
- Voice picker populated from macOS system voices
- Speak, Sweep, Demo, and Stop buttons
- Live stdout/stderr log view
- Auto-update checker (simple version comparison)
