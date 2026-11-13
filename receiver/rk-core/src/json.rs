//! The JSON subset protocol v4 uses (§3.1): a value type, a canonical serializer and a strict parser.

use base64::engine::general_purpose::STANDARD;
use base64::Engine;
use std::collections::BTreeMap;
use thiserror::Error;
use uuid::Uuid;

/// A JSON value. Integers never pass through floating point; a number with a fraction or exponent is `Float`.
#[derive(Debug, Clone, PartialEq)]
pub enum Json {
    Null,
    Bool(bool),
    Int(i128),
    /// A number that is not an integer or does not fit 64 bits; the protocol has none, so the value is not kept.
    Float,
    Str(String),
    Array(Vec<Json>),
    /// Keys sort by UTF-8 byte value, which is the order the serializer writes them in (§3.1).
    Object(BTreeMap<String, Json>),
}

/// Why a byte string is not JSON this crate accepts.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("not valid JSON")]
pub struct JsonError;

impl Json {
    /// An object from key and value pairs.
    pub fn object<'a>(entries: impl IntoIterator<Item = (&'a str, Json)>) -> Json {
        Json::Object(entries.into_iter().map(|(k, v)| (k.to_string(), v)).collect())
    }

    /// Bytes as a base64 string (§3.1).
    pub fn bytes(bytes: &[u8]) -> Json {
        Json::Str(STANDARD.encode(bytes))
    }

    /// A UUID as an uppercase 36-character string (§3.1).
    pub fn uuid(id: &Uuid) -> Json {
        Json::Str(id.hyphenated().encode_upper(&mut Uuid::encode_buffer()).to_string())
    }

    /// An unsigned integer.
    pub fn uint(n: u64) -> Json {
        Json::Int(i128::from(n))
    }

    /// A signed integer.
    pub fn int(n: i64) -> Json {
        Json::Int(i128::from(n))
    }

    /// A string value.
    pub fn string(s: &str) -> Json {
        Json::Str(s.to_string())
    }

    /// Canonical bytes: sorted keys, no whitespace, protocol escapes (§3.1).
    pub fn to_bytes(&self) -> Vec<u8> {
        let mut out = Vec::new();
        self.write(&mut out);
        out
    }

    fn write(&self, out: &mut Vec<u8>) {
        match self {
            Json::Null => out.extend_from_slice(b"null"),
            Json::Bool(true) => out.extend_from_slice(b"true"),
            Json::Bool(false) => out.extend_from_slice(b"false"),
            Json::Int(n) => out.extend_from_slice(n.to_string().as_bytes()),
            // The protocol has no non-integer numbers and the parser keeps none; a value built by hand cannot reach here.
            Json::Float => out.extend_from_slice(b"null"),
            Json::Str(s) => write_string(out, s),
            Json::Array(items) => {
                out.push(b'[');
                for (i, item) in items.iter().enumerate() {
                    if i > 0 {
                        out.push(b',');
                    }
                    item.write(out);
                }
                out.push(b']');
            }
            Json::Object(map) => {
                out.push(b'{');
                for (i, (key, value)) in map.iter().enumerate() {
                    if i > 0 {
                        out.push(b',');
                    }
                    write_string(out, key);
                    out.push(b':');
                    value.write(out);
                }
                out.push(b'}');
            }
        }
    }

    /// Parses a document. Integers outside 64 bits and non-integers become `Float`; anything that is not JSON is an error.
    pub fn parse(bytes: &[u8]) -> Result<Json, JsonError> {
        let value: serde_json::Value = serde_json::from_slice(bytes).map_err(|_| JsonError)?;
        Ok(Self::from_value(value))
    }

    fn from_value(value: serde_json::Value) -> Json {
        use serde_json::Value;
        match value {
            Value::Null => Json::Null,
            Value::Bool(b) => Json::Bool(b),
            Value::Number(n) => match (n.as_u64(), n.as_i64()) {
                (Some(u), _) => Json::Int(i128::from(u)),
                (None, Some(i)) => Json::Int(i128::from(i)),
                (None, None) => Json::Float,
            },
            Value::String(s) => Json::Str(s),
            Value::Array(items) => Json::Array(items.into_iter().map(Self::from_value).collect()),
            Value::Object(map) => Json::Object(map.into_iter().map(|(k, v)| (k, Self::from_value(v))).collect()),
        }
    }

    /// The member of an object, `None` for other values or a missing key.
    pub fn get(&self, key: &str) -> Option<&Json> {
        self.as_object()?.get(key)
    }

    /// The members of an object.
    pub fn as_object(&self) -> Option<&BTreeMap<String, Json>> {
        match self {
            Json::Object(map) => Some(map),
            _ => None,
        }
    }

    /// The string value.
    pub fn as_str(&self) -> Option<&str> {
        match self {
            Json::Str(s) => Some(s),
            _ => None,
        }
    }

    /// The boolean value.
    pub fn as_bool(&self) -> Option<bool> {
        match self {
            Json::Bool(b) => Some(*b),
            _ => None,
        }
    }

    /// An integer that fits `u64`.
    pub fn as_u64(&self) -> Option<u64> {
        match self {
            Json::Int(n) => u64::try_from(*n).ok(),
            _ => None,
        }
    }

    /// An integer that fits `i64`.
    pub fn as_i64(&self) -> Option<i64> {
        match self {
            Json::Int(n) => i64::try_from(*n).ok(),
            _ => None,
        }
    }

    /// A base64 string with padding and no characters outside the standard alphabet (§3.1).
    pub fn as_bytes(&self) -> Option<Vec<u8>> {
        STANDARD.decode(self.as_str()?).ok()
    }

    /// A 36-character UUID string, either case (§3.1).
    pub fn as_uuid(&self) -> Option<Uuid> {
        let s = self.as_str()?;
        if s.len() != 36 {
            return None;
        }
        Uuid::try_parse(s).ok()
    }
}

/// Writes a string with the escapes of §3.1: `/` becomes `\/`, control characters become `\b \t \n \f \r` or lowercase
/// `\u00xx`, everything else (including non-ASCII) is written as it is.
fn write_string(out: &mut Vec<u8>, s: &str) {
    out.push(b'"');
    let mut buf = [0u8; 4];
    for c in s.chars() {
        match c {
            '"' => out.extend_from_slice(b"\\\""),
            '\\' => out.extend_from_slice(b"\\\\"),
            '/' => out.extend_from_slice(b"\\/"),
            '\u{8}' => out.extend_from_slice(b"\\b"),
            '\t' => out.extend_from_slice(b"\\t"),
            '\n' => out.extend_from_slice(b"\\n"),
            '\u{c}' => out.extend_from_slice(b"\\f"),
            '\r' => out.extend_from_slice(b"\\r"),
            c if (c as u32) < 0x20 => out.extend_from_slice(format!("\\u{:04x}", c as u32).as_bytes()),
            c => out.extend_from_slice(c.encode_utf8(&mut buf).as_bytes()),
        }
    }
    out.push(b'"');
}

#[cfg(test)]
mod tests {
    use super::*;

    fn text(j: &Json) -> String {
        String::from_utf8(j.to_bytes()).unwrap()
    }

    #[test]
    fn keys_are_written_in_utf8_byte_order_without_whitespace() {
        let j = Json::object([("b", Json::uint(1)), ("a", Json::Bool(true)), ("B", Json::Null), ("é", Json::uint(2)), ("_0", Json::uint(3))]);
        // "B" (0x42) < "_0" (0x5F) < "a" < "b" < "é" (0xC3 0xA9)
        assert_eq!(text(&j), r#"{"B":null,"_0":3,"a":true,"b":1,"é":2}"#);
    }

    #[test]
    fn keys_sort_by_utf8_bytes_not_utf16_units() {
        // U+FF61 is EF BD A1 in UTF-8 and one UTF-16 unit (0xFF61); U+1F600 is F0 9F 98 80 and the surrogates D83D DE00.
        // UTF-8 order puts U+FF61 first, UTF-16 order would put U+1F600 first.
        let j = Json::object([("\u{1F600}", Json::uint(2)), ("\u{FF61}", Json::uint(1))]);
        assert_eq!(text(&j), "{\"\u{FF61}\":1,\"\u{1F600}\":2}");
    }

    #[test]
    fn slash_and_control_characters_use_the_protocol_escapes() {
        let s = "a/b\"c\\d\u{8}\u{9}\u{a}\u{c}\u{d}\u{0}\u{1f}\u{7f}é書🙂\u{2028}";
        assert_eq!(text(&Json::string(s)), "\"a\\/b\\\"c\\\\d\\b\\t\\n\\f\\r\\u0000\\u001f\u{7f}é書🙂\u{2028}\"");
    }

    #[test]
    fn control_characters_without_a_short_form_use_lowercase_hex() {
        assert_eq!(text(&Json::string("\u{1b}\u{e}")), "\"\\u001b\\u000e\"");
    }

    #[test]
    fn base64_slash_is_escaped_and_padding_is_kept() {
        // 0xFB 0xFF 0xBF encodes to "+/+/".
        assert_eq!(text(&Json::bytes(&[0xFB, 0xFF, 0xBF])), r#""+\/+\/""#);
        assert_eq!(text(&Json::bytes(&[1])), r#""AQ==""#);
        assert_eq!(text(&Json::bytes(&[])), r#""""#);
    }

    #[test]
    fn uuids_are_written_in_capitals() {
        let id = Uuid::parse_str("0f8fad5b-d9cb-469f-a165-70867728950e").unwrap();
        assert_eq!(text(&Json::uuid(&id)), "\"0F8FAD5B-D9CB-469F-A165-70867728950E\"");
    }

    #[test]
    fn integers_cover_the_whole_u64_range_without_floating_point() {
        assert_eq!(text(&Json::uint(u64::MAX)), "18446744073709551615");
        assert_eq!(text(&Json::int(i64::MIN)), "-9223372036854775808");
        let parsed = Json::parse(b"18446744073709551615").unwrap();
        assert_eq!(parsed.as_u64(), Some(u64::MAX));
        assert_eq!(parsed.as_i64(), None);
        assert_eq!(Json::parse(b"9007199254740993").unwrap().as_u64(), Some(9_007_199_254_740_993), "2^53 + 1 survives");
        assert_eq!(Json::parse(b"-5").unwrap().as_i64(), Some(-5));
        assert_eq!(Json::parse(b"-5").unwrap().as_u64(), None);
    }

    #[test]
    fn numbers_that_are_not_64_bit_integers_are_not_integers() {
        for doc in ["5.0", "5e0", "1E2", "0.5", "18446744073709551616", "-9223372036854775809", "-0.0"] {
            let j = Json::parse(doc.as_bytes()).unwrap();
            assert_eq!(j.as_u64(), None, "{doc}");
            assert_eq!(j.as_i64(), None, "{doc}");
        }
    }

    #[test]
    fn base64_must_be_padded_standard_alphabet() {
        let get = |s: &str| Json::string(s).as_bytes();
        assert_eq!(get("AQ=="), Some(vec![1]));
        assert_eq!(get("AQ"), None, "no padding");
        assert_eq!(get("AQ=="), Some(vec![1]));
        assert_eq!(get("+/+/"), Some(vec![0xFB, 0xFF, 0xBF]));
        assert_eq!(get("-_-_"), None, "URL-safe alphabet");
        assert_eq!(get("AQ==\n"), None, "whitespace");
        assert_eq!(get("A Q=="), None);
        assert_eq!(get("AQ=*"), None);
        assert_eq!(Json::Int(1).as_bytes(), None);
    }

    #[test]
    fn uuids_are_read_in_either_case_and_only_in_the_36_character_form() {
        let want = Uuid::parse_str("0F8FAD5B-D9CB-469F-A165-70867728950E").unwrap();
        assert_eq!(Json::string("0F8FAD5B-D9CB-469F-A165-70867728950E").as_uuid(), Some(want));
        assert_eq!(Json::string("0f8fad5b-d9cb-469f-a165-70867728950e").as_uuid(), Some(want));
        assert_eq!(Json::string("0f8fad5bd9cb469fa16570867728950e").as_uuid(), None, "no hyphens");
        assert_eq!(Json::string("{0f8fad5b-d9cb-469f-a165-70867728950e}").as_uuid(), None, "braces");
        assert_eq!(Json::string("0F8FAD5B-D9CB-469F-A165-70867728950").as_uuid(), None);
        assert_eq!(Json::string("not a uuid").as_uuid(), None);
    }

    #[test]
    fn parser_accepts_any_key_order_and_any_json_escape() {
        let j = Json::parse(br#" { "b" : "\u00e9\/\ud83d\ude42" , "a" : [ 1 , null ] } "#).unwrap();
        assert_eq!(j.get("b").and_then(Json::as_str), Some("é/🙂"));
        assert_eq!(j.get("a"), Some(&Json::Array(vec![Json::Int(1), Json::Null])));
    }

    #[test]
    fn parser_rejects_what_is_not_json() {
        for doc in [&b""[..], b"{", b"{} {}", b"{\"a\":}", b"\xEF\xBB\xBF{}", b"{\"a\":\"\\ud800\"}", b"{\"a\":\"\xff\"}", b"[1,]", b"nul"] {
            assert!(Json::parse(doc).is_err(), "{:?}", String::from_utf8_lossy(doc));
        }
    }

    #[test]
    fn accessors_do_not_convert_between_types() {
        assert_eq!(Json::string("1").as_u64(), None);
        assert_eq!(Json::uint(1).as_str(), None);
        assert_eq!(Json::uint(1).as_bool(), None);
        assert_eq!(Json::Bool(true).as_bool(), Some(true));
        assert!(Json::Null.get("a").is_none());
    }

    #[test]
    fn serializing_what_was_parsed_gives_the_canonical_form() {
        let j = Json::parse(br#"{ "z" : 1, "a" : "x/y" }"#).unwrap();
        assert_eq!(text(&j), r#"{"a":"x\/y","z":1}"#);
    }
}
