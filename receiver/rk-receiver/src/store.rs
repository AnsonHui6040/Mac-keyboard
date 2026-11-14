//! Where the paired phones and the configuration live. The platform shells provide the real ones (Credential Manager,
//! Secret Service); the memory versions serve the tests.

use crate::config::{hex, unhex, Config};
use rk_core::identity::{is_valid_name, PairedPhone, PhoneIdentity, PhonePlatform, MAX_PHONES};
use rk_core::secret::PairKey;
use std::sync::{Arc, Mutex, MutexGuard};
use thiserror::Error;

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum StoreError {
    /// Eight phones are stored and this one is new.
    #[error("the phone list is full")]
    Full,
    #[error("storage failed: {0}")]
    Backend(String),
}

pub trait PhoneStore: Send {
    fn phones(&self) -> Vec<PairedPhone>;
    /// Stores the phone; one with the same id is replaced (§4). A ninth phone is `Full`.
    fn save(&mut self, p: PairedPhone) -> Result<(), StoreError>;
    fn delete(&mut self, id: &[u8; 16]) -> Result<(), StoreError>;
}

pub trait ConfigStore: Send {
    fn save(&mut self, config: &Config) -> Result<(), StoreError>;
}

/// The list logic every store shares: replace by id, refuse a ninth.
pub fn upsert(list: &mut Vec<PairedPhone>, phone: PairedPhone) -> Result<(), StoreError> {
    if let Some(slot) = list.iter_mut().find(|p| p.identity.id == phone.identity.id) {
        *slot = phone;
        return Ok(());
    }
    if list.len() >= MAX_PHONES {
        return Err(StoreError::Full);
    }
    list.push(phone);
    Ok(())
}

/// What a platform key store keeps for one phone: the identity and the pair key, as JSON. The platform decides where.
pub fn encode_record(phone: &PairedPhone) -> Vec<u8> {
    serde_json::json!({
        "id": hex(&phone.identity.id),
        "name": phone.identity.name,
        "platform": phone.identity.platform.as_str(),
        "key": hex(phone.pair_key.expose()),
    })
    .to_string()
    .into_bytes()
}

/// The phone in a record, `None` when it is not one this program wrote.
pub fn decode_record(bytes: &[u8]) -> Option<PairedPhone> {
    let value: serde_json::Value = serde_json::from_slice(bytes).ok()?;
    let name = value.get("name")?.as_str()?;
    if !is_valid_name(name) {
        return None;
    }
    Some(PairedPhone {
        identity: PhoneIdentity {
            id: unhex::<16>(value.get("id")?.as_str()?)?,
            name: name.to_string(),
            platform: PhonePlatform::from_wire(value.get("platform")?.as_str()?)?,
        },
        pair_key: PairKey::new(unhex::<32>(value.get("key")?.as_str()?)?),
    })
}

/// A configuration store that saves nothing and says so: used when the settings file on disk is unreadable and could not be
/// moved aside, so that nothing ever overwrites it.
#[derive(Debug, Default)]
pub struct RefusingConfigStore;

impl ConfigStore for RefusingConfigStore {
    fn save(&mut self, _: &Config) -> Result<(), StoreError> {
        Err(StoreError::Backend("settings file is protected".into()))
    }
}

/// Phones in memory. Clones share one list so a test can look at what the application stored.
#[derive(Debug, Clone, Default)]
pub struct MemoryPhoneStore {
    list: Arc<Mutex<Vec<PairedPhone>>>,
}

impl MemoryPhoneStore {
    pub fn new() -> Self {
        Self::default()
    }

    fn list(&self) -> MutexGuard<'_, Vec<PairedPhone>> {
        self.list.lock().unwrap_or_else(|p| p.into_inner())
    }
}

impl PhoneStore for MemoryPhoneStore {
    fn phones(&self) -> Vec<PairedPhone> {
        self.list().clone()
    }

    fn save(&mut self, p: PairedPhone) -> Result<(), StoreError> {
        upsert(&mut self.list(), p)
    }

    fn delete(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        self.list().retain(|p| &p.identity.id != id);
        Ok(())
    }
}

/// Remembers the last configuration it was asked to save.
#[derive(Debug, Clone, Default)]
pub struct MemoryConfigStore {
    last: Arc<Mutex<Option<Config>>>,
}

impl MemoryConfigStore {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn last(&self) -> Option<Config> {
        self.last.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}

impl ConfigStore for MemoryConfigStore {
    fn save(&mut self, config: &Config) -> Result<(), StoreError> {
        *self.last.lock().unwrap_or_else(|p| p.into_inner()) = Some(config.clone());
        Ok(())
    }
}

/// A slow, real key store (Credential Manager, Secret Service): the cache in front of it reads it once.
pub trait PhoneBackend: Send {
    fn load(&self) -> Vec<PairedPhone>;
    fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError>;
    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError>;
}

/// Keeps the phone list in memory and goes to the backend only on the first read and on every change. The application asks
/// for the list on every tray refresh, which on a key store means decrypting every secret every time.
pub struct CachedPhoneStore<B: PhoneBackend> {
    backend: B,
    cache: Mutex<Option<Vec<PairedPhone>>>,
}

impl<B: PhoneBackend> CachedPhoneStore<B> {
    pub fn new(backend: B) -> Self {
        Self { backend, cache: Mutex::new(None) }
    }

    /// The cached list, read from the backend the first time it is needed.
    fn cached(&self) -> MutexGuard<'_, Option<Vec<PairedPhone>>> {
        let mut guard = self.cache.lock().unwrap_or_else(|p| p.into_inner());
        if guard.is_none() {
            *guard = Some(self.backend.load());
        }
        guard
    }
}

impl<B: PhoneBackend> PhoneStore for CachedPhoneStore<B> {
    fn phones(&self) -> Vec<PairedPhone> {
        self.cached().clone().unwrap_or_default()
    }

    fn save(&mut self, p: PairedPhone) -> Result<(), StoreError> {
        let mut next = self.phones();
        upsert(&mut next, p.clone())?;
        self.backend.put(&p)?;
        *self.cache.lock().unwrap_or_else(|e| e.into_inner()) = Some(next);
        Ok(())
    }

    fn delete(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        self.backend.remove(id)?;
        if let Some(list) = self.cache.lock().unwrap_or_else(|e| e.into_inner()).as_mut() {
            list.retain(|p| &p.identity.id != id);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rk_core::identity::{PhoneIdentity, PhonePlatform};
    use rk_core::secret::PairKey;

    fn phone(n: u8) -> PairedPhone {
        PairedPhone {
            identity: PhoneIdentity { id: [n; 16], name: format!("p{n}"), platform: PhonePlatform::Ios },
            pair_key: PairKey::new([n; 32]),
        }
    }

    #[test]
    fn saving_the_same_id_replaces_and_a_ninth_phone_is_refused() {
        let mut store = MemoryPhoneStore::new();
        for n in 1..=8 {
            store.save(phone(n)).unwrap();
        }
        assert_eq!(store.save(phone(9)), Err(StoreError::Full));
        let mut renamed = phone(3);
        renamed.identity.name = "renamed".into();
        store.save(renamed).unwrap();
        assert_eq!(store.phones().len(), 8);
        assert_eq!(store.phones()[2].identity.name, "renamed");
    }

    #[derive(Clone, Default)]
    struct CountingBackend {
        stored: Arc<Mutex<Vec<PairedPhone>>>,
        loads: Arc<Mutex<u32>>,
    }

    impl PhoneBackend for CountingBackend {
        fn load(&self) -> Vec<PairedPhone> {
            *self.loads.lock().unwrap() += 1;
            self.stored.lock().unwrap().clone()
        }
        fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError> {
            upsert(&mut self.stored.lock().unwrap(), phone.clone())
        }
        fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
            self.stored.lock().unwrap().retain(|p| &p.identity.id != id);
            Ok(())
        }
    }

    #[test]
    fn the_cached_store_reads_its_backend_once_however_often_it_is_asked() {
        let backend = CountingBackend::default();
        backend.stored.lock().unwrap().push(phone(1));
        let mut store = CachedPhoneStore::new(backend.clone());
        store.save(phone(2)).unwrap(); // the first change loads the list once
        for _ in 0..100 {
            assert_eq!(store.phones().len(), 2);
        }
        store.delete(&[1; 16]).unwrap();
        assert_eq!(store.phones().iter().map(|p| p.identity.id[0]).collect::<Vec<_>>(), vec![2]);
        assert_eq!(*backend.loads.lock().unwrap(), 1);
        assert_eq!(backend.stored.lock().unwrap().len(), 1, "the backend saw both changes");
    }

    #[test]
    fn reading_alone_loads_the_backend_only_once() {
        let backend = CountingBackend::default();
        let store = CachedPhoneStore::new(backend.clone());
        for _ in 0..100 {
            store.phones();
        }
        assert_eq!(*backend.loads.lock().unwrap(), 1);
    }

    #[test]
    fn a_failed_backend_write_leaves_the_cache_unchanged() {
        struct Refusing;
        impl PhoneBackend for Refusing {
            fn load(&self) -> Vec<PairedPhone> {
                Vec::new()
            }
            fn put(&mut self, _: &PairedPhone) -> Result<(), StoreError> {
                Err(StoreError::Backend("no".into()))
            }
            fn remove(&mut self, _: &[u8; 16]) -> Result<(), StoreError> {
                Err(StoreError::Backend("no".into()))
            }
        }
        let mut store = CachedPhoneStore::new(Refusing);
        assert!(store.save(phone(1)).is_err());
        assert!(store.phones().is_empty());
    }

    #[test]
    fn a_record_round_trips_the_identity_and_the_key() {
        let original = phone(4);
        assert_eq!(decode_record(&encode_record(&original)), Some(original));
    }

    #[test]
    fn records_that_are_not_ours_are_ignored() {
        assert_eq!(decode_record(b"not json"), None);
        assert_eq!(decode_record(br#"{"id":"00","name":"x","platform":"ios","key":"00"}"#), None);
        let mut record = String::from_utf8(encode_record(&phone(1))).unwrap();
        record = record.replace("ios", "palm");
        assert_eq!(decode_record(record.as_bytes()), None);
    }

    #[test]
    fn the_refusing_store_never_saves() {
        let config = Config::new([1; 16], rk_core::identity::HostPlatform::Windows);
        assert!(RefusingConfigStore.save(&config).is_err());
    }

    #[test]
    fn delete_removes_only_that_phone() {
        let mut store = MemoryPhoneStore::new();
        store.save(phone(1)).unwrap();
        store.save(phone(2)).unwrap();
        store.delete(&[1; 16]).unwrap();
        assert_eq!(store.phones().iter().map(|p| p.identity.id[0]).collect::<Vec<_>>(), vec![2]);
    }
}
