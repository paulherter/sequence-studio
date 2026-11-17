//! Version numbers as the installer compares them: `0.1.2 < 0.2.0 < 0.10.0`, a prerelease is older than its release.

use std::cmp::Ordering;
use std::fmt;

/// `major.minor.patch` with an optional prerelease (`0.2.0-beta.1`). Missing numbers read as 0 (`0.1` is `0.1.0`).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Version {
    pub major: u64,
    pub minor: u64,
    pub patch: u64,
    /// The text after `-`, `None` for a release.
    pub pre: Option<String>,
}

impl Version {
    pub fn new(major: u64, minor: u64, patch: u64) -> Version {
        Version { major, minor, patch, pre: None }
    }

    /// Reads `1`, `1.2`, `1.2.3` and `1.2.3-beta.1` (a `+build` suffix is ignored); `None` for anything else.
    pub fn parse(text: &str) -> Option<Version> {
        let text = text.trim();
        let text = text.split_once('+').map_or(text, |(core, _)| core);
        let (core, pre) = match text.split_once('-') {
            Some((core, pre)) if !pre.is_empty() => (core, Some(pre.to_string())),
            Some(_) => return None,
            None => (text, None),
        };
        let mut parts = core.split('.');
        let mut number = || -> Option<u64> {
            match parts.next() {
                None => Some(0),
                Some(p) if !p.is_empty() && p.bytes().all(|b| b.is_ascii_digit()) => p.parse().ok(),
                Some(_) => None,
            }
        };
        let (major, minor, patch) = (number()?, number()?, number()?);
        if parts.next().is_some() || core.is_empty() {
            return None;
        }
        Some(Version { major, minor, patch, pre })
    }
}

/// Prerelease identifiers by the SemVer rules: numbers below words, numbers by value, words by text, fewer first.
fn compare_pre(a: &str, b: &str) -> Ordering {
    let mut left = a.split('.');
    let mut right = b.split('.');
    loop {
        match (left.next(), right.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(x), Some(y)) => {
                let order = match (x.parse::<u64>(), y.parse::<u64>()) {
                    (Ok(x), Ok(y)) => x.cmp(&y),
                    (Ok(_), Err(_)) => Ordering::Less,
                    (Err(_), Ok(_)) => Ordering::Greater,
                    (Err(_), Err(_)) => x.cmp(y),
                };
                if order != Ordering::Equal {
                    return order;
                }
            }
        }
    }
}

impl Ord for Version {
    fn cmp(&self, other: &Version) -> Ordering {
        (self.major, self.minor, self.patch).cmp(&(other.major, other.minor, other.patch)).then_with(|| {
            match (&self.pre, &other.pre) {
                (None, None) => Ordering::Equal,
                (None, Some(_)) => Ordering::Greater,
                (Some(_), None) => Ordering::Less,
                (Some(a), Some(b)) => compare_pre(a, b),
            }
        })
    }
}

impl PartialOrd for Version {
    fn partial_cmp(&self, other: &Version) -> Option<Ordering> {
        Some(self.cmp(other))
    }
}

impl fmt::Display for Version {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}.{}.{}", self.major, self.minor, self.patch)?;
        match &self.pre {
            Some(pre) => write!(f, "-{pre}"),
            None => Ok(()),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn v(text: &str) -> Version {
        Version::parse(text).unwrap_or_else(|| Version::new(u64::MAX, 0, 0))
    }

    #[test]
    fn numbers_compare_by_value_not_by_text() {
        assert!(v("0.1.2") < v("0.2.0"));
        assert!(v("0.2.0") < v("0.10.0"));
        assert!(v("0.9.0") < v("0.10.0"));
        assert!(v("1.0.0") > v("0.99.99"));
        assert_eq!(v("0.1"), v("0.1.0"));
        assert_eq!(v("2"), Version::new(2, 0, 0));
    }

    #[test]
    fn a_prerelease_is_older_than_its_release_and_orders_by_semver() {
        assert!(v("0.2.0-beta.1") < v("0.2.0"));
        assert!(v("0.2.0-beta.1") > v("0.1.9"));
        assert!(v("0.2.0-alpha") < v("0.2.0-beta"));
        assert!(v("0.2.0-beta.2") < v("0.2.0-beta.10"));
        assert!(v("0.2.0-beta") < v("0.2.0-beta.1"), "fewer identifiers first");
        assert!(v("0.2.0-1") < v("0.2.0-alpha"), "numbers below words");
    }

    #[test]
    fn bad_text_is_refused_and_the_build_suffix_is_ignored() {
        for bad in ["", "a.b.c", "1.2.3.4", "1..2", "1.2.3-", "-1", "1.x"] {
            assert_eq!(Version::parse(bad), None, "{bad:?}");
        }
        assert_eq!(v("0.2.0+build5"), v("0.2.0"));
        assert_eq!(v(" 0.2.0 "), v("0.2.0"));
    }

    #[test]
    fn it_prints_the_three_numbers_and_the_prerelease() {
        assert_eq!(v("0.1").to_string(), "0.1.0");
        assert_eq!(v("0.2.0-beta.1").to_string(), "0.2.0-beta.1");
    }
}
