// SPDX-License-Identifier: GPL-3.0-or-later
//! Identifiers: Swift `UUID`, written uppercase like `uuidString`. Logic never makes random ids itself; it takes an
//! `IdSource` (the app passes a random one, tests a sequential one).

use serde::{Deserialize, Deserializer, Serialize, Serializer};
use std::fmt;
use uuid::Uuid;

/// A UUID. Displays and serializes as the uppercase hyphenated form; orders like that string.
#[derive(Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
pub struct Id(Uuid);

impl Id {
    /// All zeros.
    pub const NIL: Id = Id(Uuid::nil());

    /// From the 128-bit big-endian value.
    pub const fn from_u128(v: u128) -> Id {
        Id(Uuid::from_u128(v))
    }

    /// The fixed ids Swift builds as `"00000000-0000-0000-0000-%012d"` (built-in presets): the decimal digits of `n`
    /// read as hex. Panics for `n >= 10^12`, where the Swift string is no UUID and the code traps.
    pub const fn fixed(n: u64) -> Id {
        assert!(n < 1_000_000_000_000, "fixed id needs at most 12 digits");
        let (mut v, mut rest, mut shift) = (0u128, n, 0);
        while rest > 0 {
            v |= ((rest % 10) as u128) << shift;
            rest /= 10;
            shift += 4;
        }
        Id(Uuid::from_u128(v))
    }

    /// Parses the hyphenated form in any case, like Swift `UUID(uuidString:)`; other forms give `None`.
    pub fn parse(s: &str) -> Option<Id> {
        if s.len() != 36 {
            return None;
        }
        Uuid::try_parse(s).ok().map(Id)
    }

    /// The 128-bit big-endian value.
    pub const fn as_u128(self) -> u128 {
        self.0.as_u128()
    }
}

impl fmt::Display for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut buf = Uuid::encode_buffer();
        f.write_str(self.0.hyphenated().encode_upper(&mut buf))
    }
}

impl fmt::Debug for Id {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

impl Serialize for Id {
    fn serialize<S: Serializer>(&self, s: S) -> Result<S::Ok, S::Error> {
        s.collect_str(self)
    }
}

impl<'de> Deserialize<'de> for Id {
    fn deserialize<D: Deserializer<'de>>(d: D) -> Result<Id, D::Error> {
        let s = <std::borrow::Cow<'de, str>>::deserialize(d)?;
        Id::parse(&s).ok_or_else(|| serde::de::Error::custom(format!("invalid UUID string: {s}")))
    }
}

/// Where new ids come from. Logic takes `&mut dyn IdSource` wherever Swift calls `UUID()`.
pub trait IdSource {
    /// A fresh id.
    fn next_id(&mut self) -> Id;
}

/// Deterministic ids 1, 2, 3, ... for tests and oracle replays.
#[derive(Debug, Default)]
pub struct SequentialIds {
    last: u128,
}

impl IdSource for SequentialIds {
    fn next_id(&mut self) -> Id {
        self.last += 1;
        Id::from_u128(self.last)
    }
}

/// Ids from the system's random source: what the app uses for every id that can reach a saved project (sequential ids
/// repeat from one session to the next and made two clips of one sequence share an id).
#[derive(Clone, Copy, Debug, Default)]
pub struct RandomIds;

impl IdSource for RandomIds {
    fn next_id(&mut self) -> Id {
        let mut bytes = [0u8; 16];
        if getrandom::fill(&mut bytes).is_err() {
            // shortcut: a failing system source falls back to the clock; ids only need to differ within a run.
            let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(1, |d| d.as_nanos());
            bytes = now.to_le_bytes();
        }
        Id::from_u128(u128::from_le_bytes(bytes))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn displays_uppercase_and_parses_any_case() {
        let id = Id::parse("a1b2c3d4-0000-0000-0000-00000000000f").unwrap();
        assert_eq!(id.to_string(), "A1B2C3D4-0000-0000-0000-00000000000F");
        assert_eq!(Id::parse(&id.to_string()), Some(id));
        assert_eq!(Id::parse("a1b2c3d40000000000000000000000000f"), None);
    }

    #[test]
    fn fixed_ids_match_the_swift_format() {
        assert_eq!(Id::fixed(11).to_string(), "00000000-0000-0000-0000-000000000011");
        assert_eq!(Id::fixed(0), Id::NIL);
    }

    #[test]
    fn sequential_ids_count_up() {
        let mut s = SequentialIds::default();
        assert_eq!(s.next_id(), Id::from_u128(1));
        assert_eq!(s.next_id(), Id::from_u128(2));
    }
}
