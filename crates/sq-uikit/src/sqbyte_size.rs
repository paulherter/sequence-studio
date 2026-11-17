//! Port of `SQUIKit/Sources/SQUIKit/SQByteSize.swift`.

/// File sizes as text, always American ("25.9 MB", never "25,9 MB"), whatever the Mac's region is.
/// Decimal units like Finder: KB has no decimals, MB and up one.
pub struct SQByteSize;

impl SQByteSize {
    pub fn string(bytes: i64) -> String {
        let units = ["KB", "MB", "GB", "TB", "PB"];
        if bytes.unsigned_abs() < 1000 {
            return if bytes == 1 { "1 byte".to_string() } else { format!("{bytes} bytes") };
        }
        let mut v = bytes as f64 / 1000.0;
        let mut i = 0;
        while (v.abs() >= 999.95 || (i == 0 && v.abs() >= 999.5)) && i < units.len() - 1 {
            v /= 1000.0;
            i += 1;
        }
        let digits = if i == 0 { 0 } else { 1 };
        format!("{v:.digits$} {}", units[i])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn uses_decimal_point_and_file_units() {
        assert_eq!(SQByteSize::string(25_900_000), "25.9 MB");
        assert_eq!(SQByteSize::string(1_500_000_000), "1.5 GB");
        assert!(!SQByteSize::string(2_345_678).contains(','));
    }

    #[test]
    fn small_sizes_are_bytes_and_unit_edges_roll_over() {
        assert_eq!(SQByteSize::string(1), "1 byte");
        assert_eq!(SQByteSize::string(999), "999 bytes");
        assert_eq!(SQByteSize::string(1000), "1 KB");
        assert_eq!(SQByteSize::string(999_500), "1.0 MB");
    }
}
