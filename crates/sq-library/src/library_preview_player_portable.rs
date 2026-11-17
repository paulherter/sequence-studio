// Swift: LibraryPreviewPlayerPortable.swift
//! The Library preview player: same API as the Mac's, with the sound behind the [`PreviewSound`] trait (the app installs
//! an FFmpeg decode and cpal output, so the sound is the same on Mac, Windows and Linux). Without a backend selecting an
//! item only records it. The viewer's picture is the host's concern.
//! Swift: `@Observable`; here `version` counts every change and views poll it.

use crate::library_preview_math::{self, PreviewMode};
use crate::watched_folder::LibraryEntryID;
use std::path::Path;

/// What the sound backend says about the loaded file.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct SoundState {
    /// Length in seconds; 0 while the file is still being decoded.
    pub duration: f64,
    /// Where the sound is now, seconds.
    pub position: f64,
    /// Sound is coming out.
    pub playing: bool,
    /// Why the file cannot be played.
    pub error: Option<String>,
}

/// The sound of the preview: one file at a time. Calls return at once; decoding runs behind it.
pub trait PreviewSound {
    /// Loads `path` (replaces the previous file).
    fn load(&mut self, path: &Path);
    /// Starts at the current position.
    fn play(&mut self);
    /// Holds at the current position.
    fn pause(&mut self);
    /// Moves to `seconds` (playing continues from there when it was playing).
    fn seek(&mut self, seconds: f64);
    /// Output level 0...1 (0 when muted).
    fn set_gain(&mut self, gain: f32);
    /// Drops the file and stops.
    fn unload(&mut self);
    /// The state now.
    fn poll(&mut self) -> SoundState;
}

/// The Library preview player state.
pub struct LibraryPreviewPlayer {
    current_item_id: Option<LibraryEntryID>,
    mode: Option<PreviewMode>,
    is_playing: bool,
    seconds: f64,
    duration: f64,
    error_message: Option<String>,
    version: u64,
    /// Playback volume 0...1.
    pub volume: f32,
    /// Video previews start muted.
    pub video_muted: bool,
    /// Audio previews do not.
    pub audio_muted: bool,
    /// Called before playback starts (the app pauses other players).
    pub on_will_play: Option<Box<dyn FnMut()>>,
    sound: Option<Box<dyn PreviewSound>>,
}

impl Default for LibraryPreviewPlayer {
    fn default() -> Self {
        LibraryPreviewPlayer {
            current_item_id: None,
            mode: None,
            is_playing: false,
            seconds: 0.0,
            duration: 0.0,
            error_message: None,
            version: 0,
            volume: 0.8,
            video_muted: true,
            audio_muted: false,
            on_will_play: None,
            sound: None,
        }
    }
}

impl LibraryPreviewPlayer {
    /// A player with nothing selected.
    pub fn new() -> LibraryPreviewPlayer {
        Self::default()
    }

    /// Counts every change of the state below.
    pub fn version(&self) -> u64 {
        self.version
    }

    /// The selected item.
    pub fn current_item_id(&self) -> Option<&LibraryEntryID> {
        self.current_item_id.as_ref()
    }

    /// Preview kind of the selected item.
    pub fn mode(&self) -> Option<PreviewMode> {
        self.mode
    }

    /// Playing now.
    pub fn is_playing(&self) -> bool {
        self.is_playing
    }

    /// Playhead in seconds.
    pub fn seconds(&self) -> f64 {
        self.seconds
    }

    /// Length in seconds (0 when unknown).
    pub fn duration(&self) -> f64 {
        self.duration
    }

    /// Why the item cannot be previewed.
    pub fn error_message(&self) -> Option<&str> {
        self.error_message.as_deref()
    }

    /// The mute switch that belongs to the current mode.
    pub fn is_muted(&self) -> bool {
        if self.mode == Some(PreviewMode::Video) { self.video_muted } else { self.audio_muted }
    }

    /// Playhead as 0...1 of the duration.
    pub fn fraction(&self) -> f64 {
        if self.duration > 0.0 { (self.seconds / self.duration).clamp(0.0, 1.0) } else { 0.0 }
    }

    /// The sound backend the app installs (Mac, Windows and Linux alike).
    pub fn set_sound(&mut self, sound: Box<dyn PreviewSound>) {
        self.sound = Some(sound);
    }

    fn gain(&self) -> f32 {
        if self.is_muted() { 0.0 } else { self.volume }
    }

    /// Selects an item; only records it (no file known, so no sound).
    pub fn select(&mut self, id: LibraryEntryID, mode: Option<PreviewMode>) {
        self.current_item_id = Some(id);
        self.mode = mode;
        self.version += 1;
    }

    /// Selects an item and starts its sound: audio and video play at once (video starts muted), images show larger.
    pub fn select_file(&mut self, id: LibraryEntryID, mode: Option<PreviewMode>, path: &Path) {
        self.select(id, mode);
        self.seconds = 0.0;
        self.duration = 0.0;
        self.is_playing = false;
        self.error_message = None;
        if matches!(mode, Some(PreviewMode::Audio | PreviewMode::Video))
            && let Some(sound) = self.sound.as_mut()
        {
            sound.load(path);
            self.play();
        }
    }

    /// Starts the sound (the app pauses other players first).
    pub fn play(&mut self) {
        if self.sound.is_none() || self.current_item_id.is_none() || self.mode == Some(PreviewMode::Image) {
            return;
        }
        if self.duration > 0.0 && self.seconds >= self.duration - 0.05 {
            self.seek(0.0);
        }
        if let Some(f) = self.on_will_play.as_mut() {
            f();
        }
        let gain = self.gain();
        if let Some(s) = self.sound.as_mut() {
            s.set_gain(gain);
            s.play();
        }
        self.is_playing = true;
        self.version += 1;
    }

    /// Stops playing.
    pub fn pause(&mut self) {
        if let Some(s) = self.sound.as_mut() {
            s.pause();
        }
        self.is_playing = false;
        self.version += 1;
    }

    /// Plays or pauses.
    pub fn toggle_play_pause(&mut self) {
        if self.is_playing { self.pause() } else { self.play() }
    }

    /// Once per frame: takes the position, length and errors of the sound and keeps the output level current.
    pub fn tick(&mut self) {
        let gain = self.gain();
        let Some(s) = self.sound.as_mut() else { return };
        if self.current_item_id.is_none() {
            return;
        }
        s.set_gain(gain);
        let st = s.poll();
        let ended = self.is_playing && !st.playing && st.duration > 0.0 && st.position >= st.duration - 0.05;
        let playing = self.is_playing && st.playing && !ended;
        // The position moves every frame and only the bar draws it: it does not count as a change of the model.
        let changed = (st.duration, playing, &st.error) != (self.duration, self.is_playing, &self.error_message);
        self.seconds = st.position;
        self.duration = st.duration;
        self.is_playing = playing;
        self.error_message = st.error;
        if changed {
            self.version += 1;
        }
    }

    /// Moves the playhead, clamped to the duration.
    pub fn seek(&mut self, t: f64) {
        self.seconds = library_preview_math::skip_target(t, 0.0, self.duration);
        if let Some(s) = self.sound.as_mut() {
            s.seek(self.seconds);
        }
        self.version += 1;
    }

    /// Seeks to a 0...1 fraction (only when the duration is known).
    pub fn scrub(&mut self, fraction: f64) {
        if self.duration > 0.0 {
            self.seek(fraction.clamp(0.0, 1.0) * self.duration);
        }
    }

    /// Moves the playhead by `delta` seconds.
    pub fn skip(&mut self, delta: f64) {
        self.seek(library_preview_math::skip_target(self.seconds, delta, self.duration));
    }

    /// Clears the selection.
    pub fn stop(&mut self) {
        if let Some(s) = self.sound.as_mut() {
            s.unload();
        }
        *self = LibraryPreviewPlayer {
            sound: self.sound.take(),
            volume: self.volume,
            video_muted: self.video_muted,
            audio_muted: self.audio_muted,
            on_will_play: self.on_will_play.take(),
            version: self.version + 1,
            ..LibraryPreviewPlayer::default()
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use sq_core_time::Id;

    #[test]
    fn image_selection_has_no_error_and_stop_clears() {
        let id = LibraryEntryID { folder_id: Id::fixed(1), relative_path: "a.wav".into() };
        let mut p = LibraryPreviewPlayer::new();
        p.select(id.clone(), Some(PreviewMode::Image));
        assert!(p.current_item_id() == Some(&id) && p.error_message().is_none());
        let seen = p.version();
        p.stop();
        assert!(p.current_item_id().is_none() && p.version() > seen);
    }

    #[test]
    fn video_starts_muted_audio_does_not() {
        let p = LibraryPreviewPlayer::new();
        assert!(p.video_muted && !p.audio_muted);
    }

    use std::cell::RefCell;
    use std::rc::Rc;

    #[derive(Default)]
    struct Fake {
        log: Rc<RefCell<Vec<String>>>,
        state: Rc<RefCell<SoundState>>,
    }

    impl PreviewSound for Fake {
        fn load(&mut self, path: &Path) {
            self.log.borrow_mut().push(format!("load {}", path.display()));
        }
        fn play(&mut self) {
            self.log.borrow_mut().push("play".into());
            self.state.borrow_mut().playing = true;
        }
        fn pause(&mut self) {
            self.log.borrow_mut().push("pause".into());
            self.state.borrow_mut().playing = false;
        }
        fn seek(&mut self, seconds: f64) {
            self.log.borrow_mut().push(format!("seek {seconds}"));
            self.state.borrow_mut().position = seconds;
        }
        fn set_gain(&mut self, _: f32) {}
        fn unload(&mut self) {
            self.log.borrow_mut().push("unload".into());
        }
        fn poll(&mut self) -> SoundState {
            self.state.borrow().clone()
        }
    }

    type Rig = (LibraryPreviewPlayer, Rc<RefCell<Vec<String>>>, Rc<RefCell<SoundState>>);

    fn with_sound() -> Rig {
        let f = Fake::default();
        let (log, state) = (Rc::clone(&f.log), Rc::clone(&f.state));
        let mut p = LibraryPreviewPlayer::new();
        p.set_sound(Box::new(f));
        (p, log, state)
    }

    fn id() -> LibraryEntryID {
        LibraryEntryID { folder_id: Id::fixed(1), relative_path: "a.wav".into() }
    }

    #[test]
    fn an_audio_item_loads_and_plays_at_once_and_follows_the_sound() {
        let (mut p, log, state) = with_sound();
        p.select_file(id(), Some(PreviewMode::Audio), Path::new("/lib/a.wav"));
        assert_eq!(*log.borrow(), ["load /lib/a.wav", "play"]);
        assert!(p.is_playing());
        *state.borrow_mut() = SoundState { duration: 4.0, position: 1.0, playing: true, error: None };
        p.tick();
        assert_eq!((p.duration(), p.seconds(), p.fraction()), (4.0, 1.0, 0.25));
        p.scrub(0.5);
        assert_eq!(log.borrow().last().map(String::as_str), Some("seek 2"));
        p.toggle_play_pause();
        assert!(!p.is_playing() && log.borrow().last().map(String::as_str) == Some("pause"));
    }

    #[test]
    fn the_end_of_the_file_stops_the_player_and_play_starts_over() {
        let (mut p, log, state) = with_sound();
        p.select_file(id(), Some(PreviewMode::Audio), Path::new("a.wav"));
        *state.borrow_mut() = SoundState { duration: 2.0, position: 2.0, playing: false, error: None };
        p.tick();
        assert!(!p.is_playing());
        p.play();
        assert!(log.borrow().iter().any(|l| l == "seek 0") && p.is_playing());
    }

    #[test]
    fn images_make_no_sound_and_errors_show() {
        let (mut p, log, state) = with_sound();
        p.select_file(id(), Some(PreviewMode::Image), Path::new("a.png"));
        assert!(log.borrow().is_empty() && !p.is_playing());
        p.select_file(id(), Some(PreviewMode::Audio), Path::new("bad.wav"));
        *state.borrow_mut() = SoundState { error: Some("cannot decode".into()), ..SoundState::default() };
        p.tick();
        assert_eq!(p.error_message(), Some("cannot decode"));
    }

    #[test]
    fn stop_unloads_the_sound_and_keeps_the_backend() {
        let (mut p, log, _) = with_sound();
        p.select_file(id(), Some(PreviewMode::Audio), Path::new("a.wav"));
        p.stop();
        assert_eq!(log.borrow().last().map(String::as_str), Some("unload"));
        p.select_file(id(), Some(PreviewMode::Audio), Path::new("b.wav"));
        assert!(log.borrow().iter().any(|l| l == "load b.wav"));
    }

    #[test]
    fn seek_and_skip_clamp_at_zero() {
        let mut p = LibraryPreviewPlayer::new();
        p.seek(-4.0);
        p.skip(5.0);
        assert_eq!(p.seconds(), 5.0);
    }
}
