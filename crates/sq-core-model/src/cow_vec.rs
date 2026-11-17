//! `CowVec<T>`: a vector with copy-on-write sharing, the Rust twin of a Swift array inside a value snapshot.

use std::fmt;
use std::hash::{Hash, Hasher};
use std::ops::{Deref, DerefMut};
use std::sync::Arc;

use serde::{Deserialize, Deserializer, Serialize, Serializer};

/// A `Vec<T>` behind an `Arc`. `clone()` copies a pointer; the first mutable access of a shared copy clones the
/// elements (`Arc::make_mut`), so an undo snapshot costs only the lists an edit really touches.
pub struct CowVec<T>(Arc<Vec<T>>);

impl<T> CowVec<T> {
    /// An empty list.
    pub fn new() -> Self {
        CowVec(Arc::new(Vec::new()))
    }

    /// True when both handles share one allocation (nothing was copied since the clone).
    pub fn ptr_eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0)
    }
}

impl<T> Clone for CowVec<T> {
    fn clone(&self) -> Self {
        CowVec(Arc::clone(&self.0))
    }
}

impl<T> Default for CowVec<T> {
    fn default() -> Self {
        Self::new()
    }
}

impl<T> Deref for CowVec<T> {
    type Target = Vec<T>;
    fn deref(&self) -> &Vec<T> {
        &self.0
    }
}

impl<T: Clone> DerefMut for CowVec<T> {
    fn deref_mut(&mut self) -> &mut Vec<T> {
        Arc::make_mut(&mut self.0)
    }
}

impl<T: fmt::Debug> fmt::Debug for CowVec<T> {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_list().entries(self.0.iter()).finish()
    }
}

impl<T: PartialEq> PartialEq for CowVec<T> {
    fn eq(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.0, &other.0) || *self.0 == *other.0
    }
}

impl<T: PartialEq> PartialEq<Vec<T>> for CowVec<T> {
    fn eq(&self, other: &Vec<T>) -> bool {
        *self.0 == *other
    }
}

impl<T: Eq> Eq for CowVec<T> {}

impl<T: PartialOrd> PartialOrd for CowVec<T> {
    fn partial_cmp(&self, other: &Self) -> Option<std::cmp::Ordering> {
        self.0.partial_cmp(&other.0)
    }
}

impl<T: Ord> Ord for CowVec<T> {
    fn cmp(&self, other: &Self) -> std::cmp::Ordering {
        self.0.cmp(&other.0)
    }
}

impl<T: Hash> Hash for CowVec<T> {
    fn hash<H: Hasher>(&self, state: &mut H) {
        self.0.hash(state);
    }
}

impl<T> From<Vec<T>> for CowVec<T> {
    fn from(v: Vec<T>) -> Self {
        CowVec(Arc::new(v))
    }
}

impl<T: Clone> From<CowVec<T>> for Vec<T> {
    fn from(v: CowVec<T>) -> Self {
        Arc::try_unwrap(v.0).unwrap_or_else(|shared| (*shared).clone())
    }
}

impl<T> FromIterator<T> for CowVec<T> {
    fn from_iter<I: IntoIterator<Item = T>>(iter: I) -> Self {
        CowVec(Arc::new(iter.into_iter().collect()))
    }
}

impl<T: Clone> IntoIterator for CowVec<T> {
    type Item = T;
    type IntoIter = std::vec::IntoIter<T>;
    fn into_iter(self) -> Self::IntoIter {
        Vec::from(self).into_iter()
    }
}

impl<'a, T> IntoIterator for &'a CowVec<T> {
    type Item = &'a T;
    type IntoIter = std::slice::Iter<'a, T>;
    fn into_iter(self) -> Self::IntoIter {
        self.0.iter()
    }
}

impl<'a, T: Clone> IntoIterator for &'a mut CowVec<T> {
    type Item = &'a mut T;
    type IntoIter = std::slice::IterMut<'a, T>;
    fn into_iter(self) -> Self::IntoIter {
        Arc::make_mut(&mut self.0).iter_mut()
    }
}

impl<T: Clone> Extend<T> for CowVec<T> {
    fn extend<I: IntoIterator<Item = T>>(&mut self, iter: I) {
        Arc::make_mut(&mut self.0).extend(iter);
    }
}

impl<T: Serialize> Serialize for CowVec<T> {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        self.0.serialize(serializer)
    }
}

impl<'de, T: Deserialize<'de>> Deserialize<'de> for CowVec<T> {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        Vec::deserialize(deserializer).map(CowVec::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clone_then_mutate_leaves_original_unchanged() {
        let a: CowVec<i32> = vec![1, 2, 3].into();
        let mut b = a.clone();
        assert!(a.ptr_eq(&b));
        b.push(4);
        b[0] = 9;
        assert_eq!(*a, vec![1, 2, 3]);
        assert_eq!(*b, vec![9, 2, 3, 4]);
        assert!(!a.ptr_eq(&b));
    }

    #[test]
    fn unique_mutation_does_not_copy() {
        let mut a: CowVec<i32> = vec![1, 2, 3].into();
        let before = a.as_ptr();
        a.push(4);
        a[0] = 7;
        a.sort();
        assert_eq!(a.len(), 4);
        // Pushing may reallocate the buffer, but the Arc itself stays unique: no second owner appeared.
        let _ = before;
        assert_eq!(Arc::strong_count(&a.0), 1);
        let mut c = a.clone();
        let shared = a.as_ptr();
        drop(a);
        // Last owner left: mutation reuses the buffer.
        c[0] = 1;
        assert_eq!(c.as_ptr(), shared);
    }

    #[test]
    fn equality_fast_path_and_element_compare() {
        struct Loud(i32, bool);
        impl Clone for Loud {
            fn clone(&self) -> Self {
                Loud(self.0, self.1)
            }
        }
        impl PartialEq for Loud {
            fn eq(&self, _: &Self) -> bool {
                false // never equal: only the pointer check can make two lists equal
            }
        }
        let a: CowVec<Loud> = vec![Loud(1, true)].into();
        let b = a.clone();
        assert!(a == b);
        let c: CowVec<Loud> = vec![Loud(1, true)].into();
        assert!(a != c);
        let x: CowVec<i32> = vec![1, 2].into();
        let y: CowVec<i32> = vec![1, 2].into();
        assert!(x == y && !x.ptr_eq(&y));
        assert_ne!(x, CowVec::from(vec![1, 3]));
    }

    #[test]
    fn serde_round_trip_is_a_plain_list() {
        let a: CowVec<i32> = vec![1, 2, 3].into();
        let json = serde_json::to_string(&a).unwrap_or_default();
        assert_eq!(json, serde_json::to_string(&vec![1, 2, 3]).unwrap_or_default());
        let back: CowVec<i32> = serde_json::from_str(&json).unwrap_or_default();
        assert_eq!(back, a);
    }

    #[test]
    fn iteration_collect_default_ord_hash() {
        let a: CowVec<i32> = (1..4).collect();
        assert_eq!((&a).into_iter().sum::<i32>(), 6);
        assert_eq!(a.clone().into_iter().collect::<Vec<_>>(), vec![1, 2, 3]);
        assert!(CowVec::<i32>::default().is_empty());
        let bigger: CowVec<i32> = vec![1, 3].into();
        assert!(a < bigger);
        let mut s = std::collections::HashSet::new();
        s.insert(a.clone());
        assert!(s.contains(&a));
        assert_eq!(format!("{a:?}"), "[1, 2, 3]");
    }
}
