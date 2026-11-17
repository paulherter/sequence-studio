// SPDX-License-Identifier: GPL-3.0-or-later
//! Container reading layer of the Premiere project importer, ported from Swift (Packages/SQPremiereImport:
//! PRZip, PRGzip/rawInflate, RawInflate, PRFastXML, PRObjectTable). Same limits, same error kinds.

pub mod container;
pub mod fastxml;
pub mod inflate;
pub mod zip;

pub use container::{ImportError, Node, ObjectTable};
