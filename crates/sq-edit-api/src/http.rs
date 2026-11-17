// Swift: HTTP.swift
//! Minimal HTTP/1.1 request and response types for the edit API.

use serde::Serialize;
use std::collections::HashMap;

/// A parsed request.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HTTPRequest {
    /// Method as sent.
    pub method: String,
    /// Path without the query string.
    pub path: String,
    /// Header names lowercased.
    pub headers: HashMap<String, String>,
    /// Body bytes.
    pub body: Vec<u8>,
}

/// A response; every response closes the connection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct HTTPResponse {
    /// Status code.
    pub status: u16,
    /// JSON body.
    pub body: Vec<u8>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct ErrorBody<'a> {
    error: &'a str,
    #[serde(skip_serializing_if = "Option::is_none")]
    operation_index: Option<usize>,
}

impl HTTPResponse {
    /// A response with a JSON body (keys sorted, `{}` when encoding fails).
    pub fn json(status: u16, value: &impl Serialize) -> HTTPResponse {
        // serde_json maps are ordered by key (no `preserve_order`), like Swift's `.sortedKeys`.
        let body = serde_json::to_value(value).and_then(|v| serde_json::to_vec(&v)).unwrap_or_else(|_| b"{}".to_vec());
        HTTPResponse { status, body }
    }

    /// `{"error": message, "operationIndex"?: n}`.
    pub fn error(status: u16, message: &str, operation_index: Option<usize>) -> HTTPResponse {
        Self::json(status, &ErrorBody { error: message, operation_index })
    }

    fn reason(s: u16) -> &'static str {
        match s {
            200 => "OK",
            400 => "Bad Request",
            401 => "Unauthorized",
            403 => "Forbidden",
            404 => "Not Found",
            405 => "Method Not Allowed",
            409 => "Conflict",
            411 => "Length Required",
            413 => "Payload Too Large",
            422 => "Unprocessable Content",
            431 => "Request Header Fields Too Large",
            503 => "Service Unavailable",
            _ => "Error",
        }
    }

    /// HTTP/1.1 wire form; every response closes the connection.
    pub fn serialized(&self) -> Vec<u8> {
        let mut head = format!("HTTP/1.1 {} {}\r\n", self.status, Self::reason(self.status));
        head += &format!("Content-Type: application/json; charset=utf-8\r\nContent-Length: {}\r\n", self.body.len());
        head += "Cache-Control: no-store\r\nConnection: close\r\n\r\n";
        let mut out = head.into_bytes();
        out.extend_from_slice(&self.body);
        out
    }
}

/// What the parser made of the bytes read so far.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ParseResult {
    /// More bytes are needed.
    Incomplete,
    /// The request and the number of bytes it used.
    Complete(HTTPRequest, usize),
    /// Respond with this status and close.
    Invalid(u16),
}

/// Minimal HTTP/1.1 request parser: Content-Length bodies only (no chunked), bounded header and body size.
pub struct HTTPParser;

/// Foundation's `CharacterSet.whitespaces`: tab and the Unicode Zs category.
pub(crate) fn is_blank(c: char) -> bool {
    matches!(c as u32, 0x09 | 0x20 | 0xA0 | 0x1680 | 0x2000..=0x200A | 0x202F | 0x205F | 0x3000)
}

fn find(data: &[u8], needle: &[u8]) -> Option<usize> {
    data.windows(needle.len()).position(|w| w == needle)
}

impl HTTPParser {
    /// Largest header block accepted.
    pub const MAX_HEADER_BYTES: usize = 16 * 1024;

    /// Parses the bytes read so far; `max_body` bounds the Content-Length.
    pub fn parse(data: &[u8], max_body: usize) -> ParseResult {
        let Some(end) = find(data, b"\r\n\r\n") else {
            return if data.len() > Self::MAX_HEADER_BYTES {
                ParseResult::Invalid(431)
            } else {
                ParseResult::Incomplete
            };
        };
        if end > Self::MAX_HEADER_BYTES {
            return ParseResult::Invalid(431);
        }
        let Ok(head) = std::str::from_utf8(&data[..end]) else { return ParseResult::Invalid(400) };
        let mut lines = head.split("\r\n");
        let first = lines.next().unwrap_or("");
        let parts: Vec<&str> = first.split(' ').filter(|p| !p.is_empty()).collect();
        if parts.len() != 3 || !parts[2].starts_with("HTTP/1.") || !parts[1].starts_with('/') {
            return ParseResult::Invalid(400);
        }
        let mut headers: HashMap<String, String> = HashMap::new();
        for l in lines {
            let Some(colon) = l.find(':') else { return ParseResult::Invalid(400) };
            let name = l[..colon].trim_matches(is_blank).to_lowercase();
            let value = l[colon + 1..].trim_matches(is_blank).to_string();
            if name.is_empty() {
                return ParseResult::Invalid(400);
            }
            if headers.contains_key(&name) && (name == "host" || name == "content-length") {
                return ParseResult::Invalid(400); // smuggling
            }
            headers.insert(name, value);
        }
        if headers.contains_key("transfer-encoding") {
            return ParseResult::Invalid(411);
        }
        let mut length = 0_usize;
        if let Some(cl) = headers.get("content-length") {
            match cl.parse::<i64>() {
                Ok(n) if n >= 0 => length = usize::try_from(n).unwrap_or(usize::MAX),
                _ => return ParseResult::Invalid(400),
            }
        }
        if length > max_body {
            return ParseResult::Invalid(413);
        }
        let body_start = end + 4;
        if data.len() - body_start < length {
            return ParseResult::Incomplete;
        }
        let body = data[body_start..body_start + length].to_vec();
        let target = parts[1];
        let path = target.split('?').next().unwrap_or(target).to_string();
        let request = HTTPRequest { method: parts[0].to_string(), path, headers, body };
        ParseResult::Complete(request, body_start + length)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_request_with_body() {
        let raw =
            "POST /v1/commit HTTP/1.1\r\nHost: 127.0.0.1:9\r\nContent-Length: 2\r\nAuthorization: Bearer t\r\n\r\n{}";
        let ParseResult::Complete(r, n) = HTTPParser::parse(raw.as_bytes(), 100) else { panic!("no parse") };
        assert!(r.method == "POST" && r.path == "/v1/commit" && r.body == b"{}");
        assert!(r.headers["host"] == "127.0.0.1:9" && r.headers["authorization"] == "Bearer t");
        assert_eq!(n, raw.len());
    }

    #[test]
    fn incomplete_until_body_arrives() {
        let raw = "POST /v1/commit HTTP/1.1\r\nContent-Length: 10\r\n\r\n{}";
        assert_eq!(HTTPParser::parse(raw.as_bytes(), 100), ParseResult::Incomplete);
    }

    #[test]
    fn rejects_oversize_body_and_headers() {
        let raw = "POST /x HTTP/1.1\r\nContent-Length: 1000\r\n\r\n";
        assert_eq!(HTTPParser::parse(raw.as_bytes(), 100), ParseResult::Invalid(413));
        let huge = format!("GET /x HTTP/1.1\r\nX: {}", "a".repeat(20_000));
        assert_eq!(HTTPParser::parse(huge.as_bytes(), 100), ParseResult::Invalid(431));
        assert_eq!(HTTPParser::parse(b"garbage\r\n\r\n", 100), ParseResult::Invalid(400));
        let chunked = "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n";
        assert_eq!(HTTPParser::parse(chunked.as_bytes(), 100), ParseResult::Invalid(411));
    }

    #[test]
    fn duplicate_host_or_length_is_refused_and_the_query_is_cut() {
        let dup = "GET /x HTTP/1.1\r\nHost: a\r\nhost: b\r\n\r\n";
        assert_eq!(HTTPParser::parse(dup.as_bytes(), 100), ParseResult::Invalid(400));
        let q = "GET /v1/state?x=1 HTTP/1.1\r\nHost: a\r\n\r\n";
        assert!(matches!(HTTPParser::parse(q.as_bytes(), 100), ParseResult::Complete(r, _) if r.path == "/v1/state"));
    }

    #[test]
    fn response_wire_form_closes_the_connection() {
        let text = String::from_utf8(HTTPResponse::error(404, "x", Some(2)).serialized()).unwrap_or_default();
        assert!(text.starts_with("HTTP/1.1 404 Not Found\r\n") && text.contains("Connection: close\r\n"));
        assert!(text.ends_with(r#"{"error":"x","operationIndex":2}"#));
    }
}
