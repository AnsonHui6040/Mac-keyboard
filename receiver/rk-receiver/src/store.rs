//! Where the paired phones and the configuration live. The platform shells provide the real ones (Credential Manager,
//! Secret Service); the memory versions serve the tests.

use crate::config::{hex, unhex, Config};
use rk_core::identity::{is_valid_name, PairedPhone, PhoneIdentity, PhonePlatform, MAX_PHONES};
use rk_core::secret::PairKey;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};
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
    /// The list could not be read from its key store (a locked keyring): `phones()` is empty for now and it is read again
    /// later. Stores that cannot be unavailable keep the default.
    fn unavailable(&self) -> bool {
        false
    }
    /// The user asked for something that needs the keys (to pair): a key store that is locked may ask them to unlock it now,
    /// and is read again at once. It never waits for the answer. Stores that cannot be locked keep the default.
    fn unlock_keys(&self) {}
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
    /// An error means "could not be read", which is not the same as "no phones".
    fn load(&self) -> Result<Vec<PairedPhone>, StoreError>;
    /// The next `load` may ask the user to unlock the key store; until this is called none does (a retry every few seconds
    /// must never raise a prompt). Must not wait for the user.
    fn unlock(&self) {}
    /// A read that was started earlier has finished and its answer is waiting: the next `load` returns it at once. The
    /// store then does not sit out its back-off first.
    fn answer_ready(&self) -> bool {
        false
    }
    fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError>;
    fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError>;
}

/// How long a key store that could not be read is left alone before the next try.
const RETRY_AFTER: Duration = Duration::from_secs(5);

#[derive(Default)]
struct Cache {
    phones: Option<Vec<PairedPhone>>,
    failed_at: Option<Instant>,
}

/// Keeps the phone list in memory and goes to the backend only on the first read and on every change. The application asks
/// for the list on every tray refresh, which on a key store means decrypting every secret every time.
///
/// A read that fails is not remembered as "no phones": the list stays unknown and is read again, at most once per
/// `retry_after`, so a keyring that is unlocked later shows its phones without a restart.
pub struct CachedPhoneStore<B: PhoneBackend> {
    backend: B,
    cache: Mutex<Cache>,
    retry_after: Duration,
}

impl<B: PhoneBackend> CachedPhoneStore<B> {
    pub fn new(backend: B) -> Self {
        Self { backend, cache: Mutex::new(Cache::default()), retry_after: RETRY_AFTER }
    }

    pub fn with_retry_after(mut self, retry_after: Duration) -> Self {
        self.retry_after = retry_after;
        self
    }

    /// The cache, with the list read from the backend when it is not known yet and the last failure is old enough.
    fn cached(&self) -> MutexGuard<'_, Cache> {
        let mut guard = self.cache.lock().unwrap_or_else(|p| p.into_inner());
        let due = guard.failed_at.is_none_or(|at| at.elapsed() >= self.retry_after) || self.backend.answer_ready();
        if guard.phones.is_none() && due {
            match self.backend.load() {
                Ok(list) => {
                    guard.phones = Some(list);
                    guard.failed_at = None;
                }
                Err(_) => guard.failed_at = Some(Instant::now()),
            }
        }
        guard
    }
}

impl<B: PhoneBackend> PhoneStore for CachedPhoneStore<B> {
    fn phones(&self) -> Vec<PairedPhone> {
        self.cached().phones.clone().unwrap_or_default()
    }

    fn unavailable(&self) -> bool {
        self.cached().phones.is_none()
    }

    fn unlock_keys(&self) {
        self.backend.unlock();
        self.cache.lock().unwrap_or_else(|p| p.into_inner()).failed_at = None;
    }

    fn save(&mut self, p: PairedPhone) -> Result<(), StoreError> {
        let Some(mut next) = self.cached().phones.clone() else { return Err(StoreError::Backend("key store unavailable".into())) };
        upsert(&mut next, p.clone())?;
        self.backend.put(&p)?;
        self.cache.lock().unwrap_or_else(|e| e.into_inner()).phones = Some(next);
        Ok(())
    }

    fn delete(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
        self.backend.remove(id)?;
        if let Some(list) = self.cache.lock().unwrap_or_else(|e| e.into_inner()).phones.as_mut() {
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
        fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
            *self.loads.lock().unwrap() += 1;
            Ok(self.stored.lock().unwrap().clone())
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
            fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
                Ok(Vec::new())
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

    /// A key store that cannot be read until `heal()` (a locked keyring).
    #[derive(Clone, Default)]
    struct Locked {
        inner: CountingBackend,
        healed: Arc<Mutex<bool>>,
    }

    impl PhoneBackend for Locked {
        fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
            if *self.healed.lock().unwrap() {
                self.inner.load()
            } else {
                *self.inner.loads.lock().unwrap() += 1;
                Err(StoreError::Backend("locked".into()))
            }
        }
        fn put(&mut self, phone: &PairedPhone) -> Result<(), StoreError> {
            self.inner.put(phone)
        }
        fn remove(&mut self, id: &[u8; 16]) -> Result<(), StoreError> {
            self.inner.remove(id)
        }
    }

    #[test]
    fn a_failed_load_is_not_cached_and_the_next_look_after_the_backoff_reads_again() {
        let locked = Locked::default();
        locked.inner.stored.lock().unwrap().push(phone(1));
        let store = CachedPhoneStore::new(locked.clone()).with_retry_after(Duration::ZERO);
        assert!(store.phones().is_empty());
        assert!(store.unavailable(), "the list could not be read");
        *locked.healed.lock().unwrap() = true;
        assert_eq!(store.phones().len(), 1, "the phones are there as soon as the key store opens");
        assert!(!store.unavailable());
        // Every look while it was unknown tried again (no backoff here); once read it is not read again.
        let reads = *locked.inner.loads.lock().unwrap();
        assert_eq!(store.phones().len(), 1);
        assert_eq!(*locked.inner.loads.lock().unwrap(), reads);
    }

    #[test]
    fn within_the_backoff_a_failed_key_store_is_not_asked_again() {
        let locked = Locked::default();
        let store = CachedPhoneStore::new(locked.clone()).with_retry_after(Duration::from_secs(3600));
        for _ in 0..50 {
            assert!(store.phones().is_empty());
            assert!(store.unavailable());
        }
        assert_eq!(*locked.inner.loads.lock().unwrap(), 1);
    }

    #[test]
    fn the_user_asking_to_unlock_reaches_the_backend_and_ends_the_backoff() {
        #[derive(Clone, Default)]
        struct Counting {
            unlocks: Arc<Mutex<u32>>,
            loads: Arc<Mutex<u32>>,
        }
        impl PhoneBackend for Counting {
            fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
                *self.loads.lock().unwrap() += 1;
                Err(StoreError::Backend("locked".into()))
            }
            fn put(&mut self, _: &PairedPhone) -> Result<(), StoreError> {
                Err(StoreError::Backend("locked".into()))
            }
            fn remove(&mut self, _: &[u8; 16]) -> Result<(), StoreError> {
                Err(StoreError::Backend("locked".into()))
            }
            fn unlock(&self) {
                *self.unlocks.lock().unwrap() += 1;
            }
        }
        let backend = Counting::default();
        let store = CachedPhoneStore::new(backend.clone()).with_retry_after(Duration::from_secs(3600));
        assert!(store.unavailable());
        assert!(store.unavailable());
        assert_eq!(*backend.loads.lock().unwrap(), 1, "inside the back-off");
        store.unlock_keys();
        assert_eq!(*backend.unlocks.lock().unwrap(), 1);
        assert!(store.unavailable());
        assert_eq!(*backend.loads.lock().unwrap(), 2, "the next look reads again at once");
    }

    #[test]
    fn a_read_that_has_finished_is_picked_up_at_once_not_after_the_backoff() {
        // The user unlocked the keyring a moment after the first look failed: saving the phone must not be refused.
        struct Late {
            answered: Arc<Mutex<bool>>,
        }
        impl PhoneBackend for Late {
            fn load(&self) -> Result<Vec<PairedPhone>, StoreError> {
                if *self.answered.lock().unwrap() { Ok(vec![phone(1)]) } else { Err(StoreError::Backend("pending".into())) }
            }
            fn put(&mut self, _: &PairedPhone) -> Result<(), StoreError> {
                Ok(())
            }
            fn remove(&mut self, _: &[u8; 16]) -> Result<(), StoreError> {
                Ok(())
            }
            fn answer_ready(&self) -> bool {
                *self.answered.lock().unwrap()
            }
        }
        let answered = Arc::new(Mutex::new(false));
        let mut store = CachedPhoneStore::new(Late { answered: answered.clone() }).with_retry_after(Duration::from_secs(3600));
        assert!(store.unavailable());
        *answered.lock().unwrap() = true;
        store.save(phone(2)).unwrap();
        assert_eq!(store.phones().len(), 2);
    }

    #[test]
    fn a_phone_is_not_saved_while_the_list_cannot_be_read() {
        // Saving now would make the cache believe the new phone is the only one.
        let locked = Locked::default();
        locked.inner.stored.lock().unwrap().push(phone(1));
        let mut store = CachedPhoneStore::new(locked.clone()).with_retry_after(Duration::ZERO);
        assert!(store.save(phone(2)).is_err());
        assert_eq!(locked.inner.stored.lock().unwrap().len(), 1, "nothing was written");
        *locked.healed.lock().unwrap() = true;
        store.save(phone(2)).unwrap();
        assert_eq!(store.phones().len(), 2);
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
