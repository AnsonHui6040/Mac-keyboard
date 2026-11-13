//! Advertised and GATT UUIDs (protocol v4 §1).

use sha2::{Digest, Sha256};
use uuid::Uuid;

/// The primary GATT service (§1.1).
pub const GATT_SERVICE_UUID: Uuid = Uuid::from_u128(0x706AA642_68A3_41FA_889D_24E30709B0D0);
/// Phone to host notifications (§1.1).
pub const EVENT_CHARACTERISTIC_UUID: Uuid = Uuid::from_u128(0xC7FC0313_53E7_4DCD_B75F_2AE66FE9C586);
/// Host to phone writes (§1.1).
pub const CONTROL_CHARACTERISTIC_UUID: Uuid = Uuid::from_u128(0x320468E2_53B6_4B6A_88EC_AE2752415818);
/// What the pairing screen advertises (§1.2).
pub const PAIRING_ADVERT_UUID: Uuid = Uuid::from_u128(0x6BA36ECB_1BF9_49C1_B98D_37402247F356);

/// The UUID a keyboard advertises for the host it types to (§1.3): the first 16 bytes of
/// `SHA-256("rk-select" ‖ hostId)` with the version nibble set to 4 and the variant bits to `10`.
pub fn select_uuid(host_id: &[u8; 16]) -> Uuid {
    let mut hasher = Sha256::new();
    hasher.update(b"rk-select");
    hasher.update(host_id);
    let digest = hasher.finalize();
    let mut b = [0u8; 16];
    b.copy_from_slice(&digest[..16]);
    b[6] = (b[6] & 0x0F) | 0x40;
    b[8] = (b[8] & 0x3F) | 0x80;
    Uuid::from_bytes(b)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn select_uuid_of_the_protocol_example_host() {
        let host_id: [u8; 16] = core::array::from_fn(|i| i as u8);
        assert_eq!(select_uuid(&host_id).to_string().to_uppercase(), "521F2AE3-477F-4EE0-9A40-14E35E4D35EE");
    }

    #[test]
    fn different_hosts_get_different_uuids_and_none_is_the_pairing_uuid() {
        let a = select_uuid(&[1; 16]);
        let b = select_uuid(&[2; 16]);
        assert_ne!(a, b);
        assert_ne!(a, PAIRING_ADVERT_UUID);
        assert_ne!(a, GATT_SERVICE_UUID);
    }
}
