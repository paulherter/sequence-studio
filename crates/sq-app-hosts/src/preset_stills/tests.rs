use super::*;
use sq_app_shell::ATLAS_SIZE;
use sq_core_effects::keystone::KeystoneAnchor;
use sq_core_effects::transition::TransitionPresetExt;
use sq_core_time::{Id, Keyframe, Time, Timestamp};
use sq_draw::{Color, DrawList, QuadKind, SoftwareRenderer, Sources};
use sq_editor_session::GraphicPresetCatalog;

/// Renders `list` over an atlas slot made of `uploads` and returns the pixels of the first atlas picture quad's rect
/// (as a flat RGBA list), or none when the list draws no such quad.
pub(crate) fn picture_pixels(
    list: &DrawList,
    width: usize,
    height: usize,
    uploads: Vec<ImageUpload>,
) -> Option<Vec<u8>> {
    let mut atlas = RgbaImage { width: ATLAS_SIZE, height: ATLAS_SIZE, pixels: vec![0; ATLAS_SIZE * ATLAS_SIZE * 4] };
    for ImageUpload { at, image, .. } in uploads {
        let (x, y) = at?;
        for row in 0..image.height {
            let (from, to) = (row * image.width * 4, ((y + row) * ATLAS_SIZE + x) * 4);
            atlas.pixels[to..to + image.width * 4].copy_from_slice(&image.pixels[from..from + image.width * 4]);
        }
    }
    let quad = list.quads().iter().find(|q| q.kind == QuadKind::Image && q.slot as usize == ATLAS_SLOT)?;
    let mut images = vec![None; DrawList::IMAGE_SLOTS];
    images[ATLAS_SLOT] = Some(atlas);
    let clear = Color { r: 0.0, g: 0.0, b: 0.0, a: 1.0 };
    let shot =
        SoftwareRenderer::render(list, width, height, clear, &Sources { atlas: None, video: None, images: &images });
    let r = quad.rect;
    let mut out = Vec::new();
    for y in r.y as usize..(r.y + r.h) as usize {
        for x in r.x as usize..(r.x + r.w) as usize {
            out.extend_from_slice(&shot.pixels[(y * width + x) * 4..(y * width + x) * 4 + 4]);
        }
    }
    Some(out)
}

/// The number of distinct colors in an RGBA run: a flat fill has one, a landscape has hundreds.
pub(crate) fn colors(pixels: &[u8]) -> usize {
    pixels.chunks(4).map(|p| (p[0], p[1], p[2])).collect::<std::collections::BTreeSet<_>>().len()
}

fn keystone(rotation: f64) -> Keystone {
    let mut k = Keystone::new(Id::from_u128(7), "Turn", Time::seconds(1), KeystoneAnchor::Free);
    k.rotation = Some(KeyframeTrack { keys: vec![Keyframe::new(Id::from_u128(1), Time::seconds(1), rotation)] });
    k
}

#[test]
fn a_keystone_still_follows_the_last_key() {
    let (still, turned) = (keystone_still(&keystone(0.0)), keystone_still(&keystone(30.0)));
    assert_eq!(still.len(), WIDTH * HEIGHT * 4);
    assert!(colors(&still) > 100, "the sample landscape is in the still");
    assert_ne!(still, turned, "a turned keystone looks different");
}

#[test]
fn the_cache_packs_a_still_once_and_leaves_an_unshared_cache_empty() {
    let mut cache = StillCache::default();
    assert!(cache.picture("a", || Some(vec![0; WIDTH * HEIGHT * 4])).is_none(), "no atlas yet");
    assert!(!cache.has("a"));
    cache.share_atlas(SharedAtlas::default());
    let first = cache.picture("a", || Some(vec![9; WIDTH * HEIGHT * 4])).expect("packed");
    assert_eq!(cache.picture("a", || None), Some(first), "made once");
    assert_eq!(cache.picture("none", || None), None);
    assert!(cache.has("none"), "a kind without a picture is not retried");
    assert_eq!(cache.take_uploads().len(), 1);
}

#[test]
fn a_transition_preset_has_the_effects_tile_still_and_other_kinds_none() {
    let preset = TransitionPreset::new(sq_core_model::TransitionKind::CrossDissolve, Time::seconds(1));
    let item =
        |kind, payload| PresetItem::new(Id::from_u128(2), kind, "p", Timestamp::from_unix_seconds(0.0), payload, 1);
    let payload = preset.payload().expect("payload");
    let still = preset_still(&item(PresetKind::Transition, payload)).expect("a still");
    assert_eq!(still.len(), WIDTH * HEIGHT * 4);
    assert!(preset_still(&item(PresetKind::Easing, Vec::new())).is_none());
    assert!(preset_still(&item(PresetKind::Transition, b"x".to_vec())).is_none(), "a damaged payload has no picture");
}

/// Points the text renderer at the bundled fonts of the Swift package.
fn use_fonts() {
    let root =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../Packages/SQText/Sources/SQText/Resources/Fonts");
    sq_text::portable_font_match::set_fonts_root(&root);
}

fn differs_from_sample(still: &[u8]) -> bool {
    still.len() == WIDTH * HEIGHT * 4 && still != sample()
}

#[test]
fn a_built_in_graphic_is_drawn_over_the_sample_landscape() {
    use_fonts();
    let first = GraphicPresetCatalog::all();
    assert!(!first.is_empty());
    let drawn = first.iter().filter(|e| graphic_still(&e.id).is_some_and(|s| differs_from_sample(&s))).count();
    assert!(drawn * 2 > first.len(), "most graphics show their shapes or text ({drawn} of {})", first.len());
    assert!(graphic_still("no such graphic").is_none());
}

#[test]
fn a_saved_title_shows_its_text_over_the_landscape() {
    use_fonts();
    use sq_core_edit::timeline_clipboard::{ClipboardEntry, TimelineClipboard};
    use sq_core_model::{Clip, TrackKind};
    use sq_core_time::TimeRange;
    use sq_text::text_generator::TextGenerator;
    use sq_text::text_style::TextStyle;
    use sq_text::text_template::TextTemplate;
    let generator =
        TextGenerator::make_ref(&TextTemplate::new("Title", "Hello", TextStyle::default()), None).expect("ref");
    let id = Id::from_u128(3);
    let mut clip =
        Clip::new(id, "Title", id, TrackKind::Video, TimeRange::new(Time::ZERO, Time::seconds(3)), Time::ZERO);
    clip.generator = Some(generator);
    let block = TitleBlock::new(TimelineClipboard {
        entries: vec![ClipboardEntry { clip, offset: Time::ZERO, lane: 0 }],
        transitions: Vec::new(),
        picture_track_lanes: None,
    })
    .expect("a title block");
    let item = block.preset_item("Title", id, Timestamp::from_unix_seconds(0.0)).expect("item");
    let still = preset_still(&item).expect("a still");
    assert!(differs_from_sample(&still), "the text changed the picture");
}

#[test]
fn a_title_template_tile_shows_its_thumbnail_pixels() {
    let mut png_bytes = Vec::new();
    {
        let mut enc = png::Encoder::new(&mut png_bytes, 4, 2);
        enc.set_color(png::ColorType::Rgba);
        enc.set_depth(png::BitDepth::Eight);
        let mut w = enc.write_header().expect("header");
        w.write_image_data(&[[255u8, 0, 0, 255]; 8].concat()).expect("data");
    }
    let template = one_layer_template();
    let item = TitleTemplatePreset { template, thumbnail: Some(png_bytes) }
        .preset_item("T", Id::from_u128(4), Timestamp::from_unix_seconds(0.0))
        .expect("item");
    let still = preset_still(&item).expect("a still");
    assert_eq!(still.len(), WIDTH * HEIGHT * 4);
    let mid = ((HEIGHT / 2) * WIDTH + WIDTH / 2) * 4;
    assert_eq!(&still[mid..mid + 4], &[255, 0, 0, 255], "the thumbnail's red shows in the middle");
    let bad = TitleTemplatePreset { template: one_layer_template(), thumbnail: None };
    let item = bad.preset_item("T", Id::from_u128(5), Timestamp::from_unix_seconds(0.0)).expect("item");
    assert!(preset_still(&item).is_none(), "no thumbnail, no picture");
}

fn one_layer_template() -> sq_core_model::TitleTemplate {
    use sq_core_model::{SequenceFormat, Timeline, Track, TrackKind};
    let content = Timeline::new(
        Id::from_u128(11),
        "T",
        SequenceFormat::new(sq_core_time::Time::new(1, 30)),
        vec![Track::new(Id::from_u128(12), TrackKind::Video)],
    );
    sq_core_model::TitleTemplate::new(Id::from_u128(13), "T", None, content, Vec::new(), None)
}
