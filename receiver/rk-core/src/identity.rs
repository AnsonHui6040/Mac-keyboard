//! Host and phone identities (protocol v4 §4).

use crate::secret::PairKey;
use sha2::{Digest, Sha256};
use thiserror::Error;

/// Length of `hostId` and `phoneId` in bytes (§4).
pub const ID_LEN: usize = 16;
/// Longest name on the wire, in UTF-8 bytes (§4).
pub const MAX_NAME_BYTES: usize = 32;
/// Most phones a host stores, and so the most HMACs one `helloReply` costs (§4 storage, §6.2).
pub const MAX_PHONES: usize = 8;

/// A host platform string (§4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HostPlatform {
    Mac,
    Windows,
    Linux,
}

/// A phone platform string (§4).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PhonePlatform {
    Ios,
    Android,
}

impl HostPlatform {
    /// The wire string.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Mac => "mac",
            Self::Windows => "windows",
            Self::Linux => "linux",
        }
    }
    /// The platform for a wire string; `None` when the protocol does not list it.
    pub fn from_wire(s: &str) -> Option<Self> {
        match s {
            "mac" => Some(Self::Mac),
            "windows" => Some(Self::Windows),
            "linux" => Some(Self::Linux),
            _ => None,
        }
    }
}

impl PhonePlatform {
    /// The wire string.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Ios => "ios",
            Self::Android => "android",
        }
    }
    /// The platform for a wire string; `None` when the protocol does not list it.
    pub fn from_wire(s: &str) -> Option<Self> {
        match s {
            "ios" => Some(Self::Ios),
            "android" => Some(Self::Android),
            _ => None,
        }
    }
}

/// Why a received identity was refused (§5.2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum IdentityError {
    #[error("id is not 16 bytes")]
    BadId,
    #[error("name is empty or longer than 32 UTF-8 bytes")]
    BadName,
}

/// The host side of a pairing (§4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HostIdentity {
    pub id: [u8; ID_LEN],
    pub name: String,
    pub platform: HostPlatform,
}

/// The phone side of a pairing (§4).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PhoneIdentity {
    pub id: [u8; ID_LEN],
    pub name: String,
    pub platform: PhonePlatform,
}

impl HostIdentity {
    /// Checks what a pairing received (§5.2): a 16-byte id and a valid name.
    pub fn from_wire(id: &[u8], name: &str, platform: HostPlatform) -> Result<Self, IdentityError> {
        let (id, name) = check(id, name)?;
        Ok(Self { id, name, platform })
    }
}

impl PhoneIdentity {
    /// Checks what a pairing received (§5.2): a 16-byte id and a valid name.
    pub fn from_wire(id: &[u8], name: &str, platform: PhonePlatform) -> Result<Self, IdentityError> {
        let (id, name) = check(id, name)?;
        Ok(Self { id, name, platform })
    }
}

/// A phone a host is paired with and the key they share (§4 storage).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PairedPhone {
    pub identity: PhoneIdentity,
    pub pair_key: PairKey,
}

fn check(id: &[u8], name: &str) -> Result<([u8; ID_LEN], String), IdentityError> {
    let id: [u8; ID_LEN] = id.try_into().map_err(|_| IdentityError::BadId)?;
    if !is_valid_name(name) {
        return Err(IdentityError::BadName);
    }
    Ok((id, name.to_string()))
}

/// The longest prefix of `name` that fits in 32 UTF-8 bytes, cut on a scalar boundary (§4 rule 2). A character made of
/// several scalars may be cut in two; the result is always valid UTF-8. An empty result means the caller uses its default.
pub fn clamp_name(name: &str) -> String {
    let mut end = 0;
    for (index, c) in name.char_indices() {
        let next = index + c.len_utf8();
        if next > MAX_NAME_BYTES {
            break;
        }
        end = next;
    }
    name[..end].to_string()
}

/// A name that may travel and be stored: not empty, at most 32 UTF-8 bytes (§4 rule 1).
pub fn is_valid_name(name: &str) -> bool {
    !name.is_empty() && name.len() <= MAX_NAME_BYTES
}

/// `SHA-256(utf8(name) ‖ 0x00 ‖ utf8(platform))` (§5.3). The zero byte keeps `"ab"+"c"` apart from `"a"+"bc"`.
pub fn identity_hash(name: &str, platform: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(name.as_bytes());
    hasher.update([0u8]);
    hasher.update(platform.as_bytes());
    hasher.finalize().into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn short_names_are_left_alone() {
        assert_eq!(clamp_name("書房的 Mac"), "書房的 Mac");
        assert_eq!(clamp_name(""), "");
        let exactly_32 = "a".repeat(32);
        assert_eq!(clamp_name(&exactly_32), exactly_32);
    }

    #[test]
    fn eleven_cjk_characters_are_cut_to_ten() {
        let clamped = clamp_name(&"測".repeat(11));
        assert_eq!(clamped, "測".repeat(10));
        assert_eq!(clamped.len(), 30);
    }

    #[test]
    fn a_joined_emoji_may_be_cut_between_scalars() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
        let input = format!("a{}", family.repeat(8));
        assert_eq!(input.len(), 145);
        let clamped = clamp_name(&input);
        assert_eq!(clamped.len(), 30);
        assert_eq!(clamped, format!("a{family}\u{1F468}\u{200D}\u{1F469}"));
    }

    #[test]
    fn a_scalar_that_would_cross_the_limit_is_dropped_whole() {
        // 31 ASCII bytes then a 3-byte character: 34 > 32, so only the ASCII stays.
        let input = format!("{}書", "a".repeat(31));
        assert_eq!(clamp_name(&input), "a".repeat(31));
        // 30 ASCII bytes then a 3-byte character does not fit either (33), but a 2-byte one does (32).
        assert_eq!(clamp_name(&format!("{}書", "a".repeat(30))), "a".repeat(30));
        assert_eq!(clamp_name(&format!("{}é", "a".repeat(30))), format!("{}é", "a".repeat(30)));
    }

    #[test]
    fn names_are_valid_from_one_to_thirty_two_bytes() {
        assert!(!is_valid_name(""));
        assert!(is_valid_name("a"));
        assert!(is_valid_name(&"a".repeat(32)));
        assert!(!is_valid_name(&"a".repeat(33)));
        assert!(!is_valid_name(&"測".repeat(11)), "33 bytes");
    }

    #[test]
    fn a_received_identity_is_never_repaired() {
        let id = [7u8; 16];
        assert!(HostIdentity::from_wire(&id, "Mac", HostPlatform::Mac).is_ok());
        assert_eq!(HostIdentity::from_wire(&id[..15], "Mac", HostPlatform::Mac), Err(IdentityError::BadId));
        assert_eq!(HostIdentity::from_wire(&[id.as_slice(), &[0]].concat(), "Mac", HostPlatform::Mac), Err(IdentityError::BadId));
        assert_eq!(HostIdentity::from_wire(&id, "", HostPlatform::Mac), Err(IdentityError::BadName));
        assert_eq!(HostIdentity::from_wire(&id, &"a".repeat(33), HostPlatform::Linux), Err(IdentityError::BadName));
        assert_eq!(PhoneIdentity::from_wire(&id, "", PhonePlatform::Ios), Err(IdentityError::BadName));
        assert_eq!(PhoneIdentity::from_wire(&[], "x", PhonePlatform::Ios), Err(IdentityError::BadId));
        assert!(PhoneIdentity::from_wire(&id, "Anson 的 iPhone", PhonePlatform::Ios).is_ok());
    }

    #[test]
    fn platform_strings_are_exactly_the_listed_ones() {
        for p in [HostPlatform::Mac, HostPlatform::Windows, HostPlatform::Linux] {
            assert_eq!(HostPlatform::from_wire(p.as_str()), Some(p));
        }
        for p in [PhonePlatform::Ios, PhonePlatform::Android] {
            assert_eq!(PhonePlatform::from_wire(p.as_str()), Some(p));
        }
        for bad in ["", "Mac", "MAC", "macos", "ios ", "iOS"] {
            assert_eq!(HostPlatform::from_wire(bad), None, "{bad:?}");
        }
        for bad in ["", "Android", "ipados", "mac", "windows"] {
            assert_eq!(PhonePlatform::from_wire(bad), None, "{bad:?}");
        }
        assert_eq!(PhonePlatform::from_wire("linux"), None);
        assert_eq!(HostPlatform::from_wire("ios"), None);
    }

    #[test]
    fn identity_hash_separates_name_from_platform() {
        assert_ne!(identity_hash("ab", "c"), identity_hash("a", "bc"));
        let hex: String = identity_hash("書房的 Mac", "mac").iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "efb4d023cf489be4b50541916b46f8488ed72c3187928b8922b36708fa40b66b");
    }
}
