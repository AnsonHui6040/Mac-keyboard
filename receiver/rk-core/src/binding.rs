//! Which central the phone talks to, and what a `hello` from each central means (protocol v4 §1.5, §6.3).

use crate::identity::ID_LEN;
use crate::message::ControlMessage;
use crate::pairing::NONCE_LEN;

/// What a subscription does to the binding (§1.5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BindOutcome {
    /// This central is now the bound one: start a fresh handshake or attempt for it.
    Bound,
    /// Another central subscribed while the bound one is locked: ignore it.
    Refused,
}

/// What to do with a `hello` written to `control` (§6.3).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HelloDisposition {
    /// Feed it to the handshake of the bound central.
    Handshake,
    /// Notify one plain `notSelected` to the central that wrote it, keep no state.
    ReplyNotSelected,
    Ignore,
}

/// The one central the phone serves, by whatever identifier the adapter uses for a central.
#[derive(Debug, Clone)]
pub struct CentralBinding<C: Copy + Eq> {
    subscribed: Option<C>,
}

impl<C: Copy + Eq> CentralBinding<C> {
    /// Nothing bound.
    pub fn new() -> Self {
        Self { subscribed: None }
    }
    /// The bound central.
    pub fn subscribed(&self) -> Option<C> {
        self.subscribed
    }
    /// A central subscribed to `event`. `locked` means the bound connection is authenticated (§1.5).
    pub fn subscribe(&mut self, central: C, locked: bool) -> BindOutcome {
        match self.subscribed {
            Some(current) if current != central && locked => BindOutcome::Refused,
            _ => {
                self.subscribed = Some(central);
                BindOutcome::Bound
            }
        }
    }
    /// `true` when the bound central left.
    pub fn unsubscribe(&mut self, central: C) -> bool {
        if self.subscribed == Some(central) {
            self.subscribed = None;
            true
        } else {
            false
        }
    }
    /// Decides what a `hello` means (§6.3 rows 1 to 6). `current_host_id` is `None` without a current host.
    pub fn hello_disposition(
        &mut self,
        central: C,
        hello: &ControlMessage,
        current_host_id: Option<[u8; 16]>,
        locked: bool,
    ) -> HelloDisposition {
        let ControlMessage::Hello { host_id, host_nonce } = hello else {
            return HelloDisposition::Ignore;
        };
        let is_bound = self.subscribed == Some(central);
        // Row 1: a hello that is not well formed goes to the handshake (which fails it) only from the bound central.
        if host_id.len() != ID_LEN || host_nonce.len() != NONCE_LEN {
            return if is_bound { HelloDisposition::Handshake } else { HelloDisposition::Ignore };
        }
        // Row 2: meant for another host, or there is no current host.
        if current_host_id.as_ref().map(<[u8; 16]>::as_slice) != Some(host_id.as_slice()) {
            if is_bound {
                self.subscribed = None;
            }
            return HelloDisposition::ReplyNotSelected;
        }
        // Rows 3 and 4: the bound central; the handshake tells a first hello from a second.
        if is_bound {
            return HelloDisposition::Handshake;
        }
        // Row 5: another central while the bound connection is authenticated.
        if locked {
            return HelloDisposition::Ignore;
        }
        // Row 6: another central while the bound connection is not authenticated yet: it takes over.
        self.subscribed = Some(central);
        HelloDisposition::Handshake
    }
    /// Only writes from the bound central go to the handshake or pairing reducer.
    pub fn should_accept_write(&self, central: C) -> bool {
        self.subscribed == Some(central)
    }
    /// Releases the binding (Bluetooth turned off, or any reset).
    pub fn clear(&mut self) {
        self.subscribed = None;
    }
}

impl<C: Copy + Eq> Default for CentralBinding<C> {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const HOST: [u8; 16] = [0x11; 16];
    const OTHER_HOST: [u8; 16] = [0x22; 16];

    fn hello(host_id: &[u8]) -> ControlMessage {
        ControlMessage::Hello { host_id: host_id.to_vec(), host_nonce: vec![0xA0; 16] }
    }

    fn binding_with(central: u8) -> CentralBinding<u8> {
        let mut b = CentralBinding::new();
        assert_eq!(b.subscribe(central, false), BindOutcome::Bound);
        b
    }

    #[test]
    fn the_first_subscriber_is_bound_and_only_it_may_write() {
        let mut b = CentralBinding::new();
        assert_eq!(b.subscribe(1u8, false), BindOutcome::Bound);
        assert!(b.should_accept_write(1));
        assert!(!b.should_accept_write(2));
    }

    #[test]
    fn another_central_cannot_replace_a_locked_connection_but_can_replace_an_unlocked_one() {
        let mut b = binding_with(1);
        assert_eq!(b.subscribe(2, true), BindOutcome::Refused);
        assert_eq!(b.subscribed(), Some(1));
        assert_eq!(b.subscribe(2, false), BindOutcome::Bound);
        assert_eq!(b.subscribed(), Some(2));
    }

    #[test]
    fn the_bound_central_subscribing_again_rebinds_even_when_locked() {
        let mut b = binding_with(1);
        assert_eq!(b.subscribe(1, true), BindOutcome::Bound);
        assert_eq!(b.subscribed(), Some(1));
    }

    #[test]
    fn unsubscribe_of_another_central_changes_nothing_and_of_the_bound_one_releases() {
        let mut b = binding_with(1);
        assert!(!b.unsubscribe(2));
        assert_eq!(b.subscribed(), Some(1));
        assert!(b.unsubscribe(1));
        assert_eq!(b.subscribed(), None);
        let mut b = binding_with(1);
        b.clear();
        assert_eq!(b.subscribed(), None);
    }

    #[test]
    fn row_1_a_malformed_hello_goes_to_the_handshake_only_from_the_bound_central() {
        let mut b = binding_with(1);
        for bad in [
            hello(&HOST[..15]),
            hello(&[HOST.as_slice(), &[0]].concat()),
            ControlMessage::Hello { host_id: HOST.to_vec(), host_nonce: vec![0; 15] },
            ControlMessage::Hello { host_id: HOST.to_vec(), host_nonce: vec![0; 17] },
        ] {
            assert_eq!(b.hello_disposition(1, &bad, Some(HOST), false), HelloDisposition::Handshake);
            assert_eq!(b.hello_disposition(2, &bad, Some(HOST), false), HelloDisposition::Ignore);
            assert_eq!(b.hello_disposition(2, &bad, Some(OTHER_HOST), true), HelloDisposition::Ignore, "never notSelected");
        }
        assert_eq!(b.subscribed(), Some(1));
    }

    #[test]
    fn row_2_a_hello_for_another_host_gets_not_selected_and_a_bound_central_is_released() {
        let mut b = binding_with(1);
        assert_eq!(b.hello_disposition(1, &hello(&OTHER_HOST), Some(HOST), false), HelloDisposition::ReplyNotSelected);
        assert_eq!(b.subscribed(), None, "the bound central has to try again for the right host");
    }

    #[test]
    fn row_2_not_selected_for_another_central_does_not_disturb_an_authenticated_connection() {
        let mut b = binding_with(1);
        assert_eq!(b.hello_disposition(2, &hello(&OTHER_HOST), Some(HOST), true), HelloDisposition::ReplyNotSelected);
        assert_eq!(b.subscribed(), Some(1));
        // Also for an unlocked binding: a mismatched hello from a stranger keeps it.
        assert_eq!(b.hello_disposition(2, &hello(&OTHER_HOST), Some(HOST), false), HelloDisposition::ReplyNotSelected);
        assert_eq!(b.subscribed(), Some(1));
    }

    #[test]
    fn row_2_a_phone_with_no_current_host_answers_every_well_formed_hello_with_not_selected() {
        let mut b = CentralBinding::new();
        assert_eq!(b.hello_disposition(1u8, &hello(&HOST), None, false), HelloDisposition::ReplyNotSelected);
        assert_eq!(b.subscribed(), None);
    }

    #[test]
    fn rows_3_and_4_a_matching_hello_from_the_bound_central_goes_to_the_handshake_each_time() {
        let mut b = binding_with(1);
        assert_eq!(b.hello_disposition(1, &hello(&HOST), Some(HOST), false), HelloDisposition::Handshake);
        assert_eq!(b.hello_disposition(1, &hello(&HOST), Some(HOST), true), HelloDisposition::Handshake, "the second one fails there");
    }

    #[test]
    fn row_5_a_matching_hello_from_another_central_is_ignored_while_authenticated() {
        let mut b = binding_with(1);
        assert_eq!(b.hello_disposition(2, &hello(&HOST), Some(HOST), true), HelloDisposition::Ignore);
        assert_eq!(b.subscribed(), Some(1));
    }

    #[test]
    fn row_6_a_matching_hello_from_another_central_takes_over_an_unauthenticated_binding() {
        let mut b = binding_with(1);
        assert_eq!(b.hello_disposition(2, &hello(&HOST), Some(HOST), false), HelloDisposition::Handshake);
        assert_eq!(b.subscribed(), Some(2));
        assert!(!b.should_accept_write(1));
    }

    #[test]
    fn anything_that_is_not_a_hello_is_ignored() {
        let mut b = binding_with(1);
        assert_eq!(b.hello_disposition(1, &ControlMessage::Bye, Some(HOST), false), HelloDisposition::Ignore);
        assert_eq!(b.hello_disposition(1, &ControlMessage::AuthFailed, None, false), HelloDisposition::Ignore);
    }
}
