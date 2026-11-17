// Swift: Deinterlace.swift
//! Source settings > Deinterlace. Interlaced media (a field order) is deinterlaced right after decode by default;
//! the switch belongs to the media item, not to a clip.

use sq_core_model::Project;
use sq_core_time::Id;

/// `extension Project` of Deinterlace.swift.
pub trait DeinterlaceExt {
    /// Whether `id` is interlaced media, and whether its fields are deinterlaced. `None` for progressive or unprobed media.
    fn deinterlace(&self, id: Id) -> Option<bool>;
    /// Turns deinterlacing of `id` on or off, for every clip of it (subclips share their file's setting). Returns whether
    /// anything changed; false for unknown, unprobed and progressive media.
    fn set_deinterlace(&mut self, on: bool, id: Id) -> bool;
}

impl DeinterlaceExt for Project {
    fn deinterlace(&self, id: Id) -> Option<bool> {
        let v = self.media(id)?.info.as_ref()?.video.as_ref().filter(|v| v.is_interlaced())?;
        Some(!v.deinterlace_off)
    }

    fn set_deinterlace(&mut self, on: bool, id: Id) -> bool {
        let Some(item) = self.media(id) else { return false };
        let file = item.subclip.as_ref().map_or(id, |s| s.parent);
        let mut changed = false;
        for m in self.media.iter_mut().filter(|m| m.id == file || m.subclip.as_ref().is_some_and(|s| s.parent == file))
        {
            let Some(v) = m.info.as_mut().and_then(|i| i.video.as_mut()) else { continue };
            if !v.is_interlaced() || v.deinterlace_off != on {
                continue;
            }
            v.deinterlace_off = !on;
            changed = true;
        }
        changed
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use sq_core_model::{MediaFingerprint, MediaInfo, MediaRef, Subclip};
    use sq_core_time::{Time, TimeRange};

    fn project(order: Option<&str>) -> (Project, Id) {
        let mut video = json!({"width": 1920, "height": 1080, "codec": "avc1", "bitDepth": 10, "chroma": "4:2:2",
            "nominalFrameDuration": {"value": 1, "timescale": 25}, "isVariableFrameRate": false});
        if let Some(o) = order {
            video["fieldOrder"] = json!(o);
        }
        let info: MediaInfo =
            serde_json::from_value(json!({"duration": {"value": 10, "timescale": 1}, "video": video}))
                .unwrap_or_else(|e| unreachable!("fixture: {e}"));
        let mut m = MediaRef::new(Id::from_u128(1), "a.mxf", "/a.mxf", MediaFingerprint::new(1));
        m.info = Some(info);
        let id = m.id;
        (Project::new(Id::from_u128(2), "P", vec![m], vec![]), id)
    }
    fn off(p: &Project, id: Id) -> Option<bool> {
        p.media(id).and_then(|m| m.info.as_ref()).and_then(|i| i.video.as_ref()).map(|v| v.deinterlace_off)
    }

    #[test]
    fn set_deinterlace_toggles_interlaced_media_only() {
        let (mut p, id) = project(Some("bottomFirst"));
        assert_eq!(p.deinterlace(id), Some(true));
        assert!(!p.set_deinterlace(true, id)); // already on
        assert!(p.set_deinterlace(false, id));
        assert_eq!(p.deinterlace(id), Some(false));
        assert!(p.set_deinterlace(true, id));
        assert_eq!(off(&p, id), Some(false));
        let (mut q, qid) = project(None);
        assert_eq!(q.deinterlace(qid), None);
        assert!(!q.set_deinterlace(false, qid));
        assert_eq!(off(&q, qid), Some(false));
        assert!(!q.set_deinterlace(false, Id::from_u128(99)));
    }

    #[test]
    fn subclips_follow_their_file() {
        let (mut p, id) = project(Some("topFirst"));
        let mut sub = p.media[0].clone();
        sub.id = Id::from_u128(3);
        sub.name = "sub".into();
        sub.subclip = Some(Subclip { parent: id, range: TimeRange::new(Time::ZERO, Time::new(1, 1)) });
        p.media.push(sub);
        assert!(p.set_deinterlace(false, Id::from_u128(3)));
        assert_eq!(p.deinterlace(id), Some(false));
        assert_eq!(p.deinterlace(Id::from_u128(3)), Some(false));
    }
}
