//! Joins the application to the outside world: the link channels, the tray, the clock and the UDP socket of the Wi-Fi assist.

use crate::app::{App, Effect};
use crate::clock::Clock;
use crate::ui::{UiCommand, UiEvent};
use crate::wifi::WifiCommand;
use rk_ble::{LinkCommand, LinkEvent};
use std::io;
use std::net::{SocketAddr, SocketAddrV4};
use std::sync::Arc;
use std::time::Duration;
use tokio::net::UdpSocket;
use tokio::sync::mpsc;

/// Where tray updates go; the shell implements it for its window system.
pub trait UiSink: Send + 'static {
    fn send(&self, event: UiEvent);
}

/// Room for one datagram. A pointer packet is 41 bytes (§8.1); anything that fills this much is not one and is dropped by
/// the application on its length.
const WIFI_BUFFER_LEN: usize = 64;
/// After a receive error the loop waits this long before it listens again, so that an error that repeats cannot spin.
const WIFI_ERROR_PAUSE: Duration = Duration::from_millis(5);

/// What one wait on the Wi-Fi socket gave.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum WifiRecv {
    Datagram(usize, SocketAddr),
    Error(io::ErrorKind),
}

/// Runs the application until the tray says `Quit` or a channel closes. Returns once the farewell (`bye`, `Disconnect`) has
/// been handed to the link.
///
/// One UDP socket, bound to every interface on a port the system picks, serves the Wi-Fi assist (§8.6). If it cannot be
/// made the receiver runs without Wi-Fi and says so once in the log; nothing else is affected.
pub async fn run(
    app: App,
    link_events: mpsc::Receiver<LinkEvent>,
    link_commands: mpsc::Sender<LinkCommand>,
    ui_commands: mpsc::UnboundedReceiver<UiCommand>,
    ui: impl UiSink,
    clock: Arc<dyn Clock>,
) {
    let wifi = UdpSocket::bind("0.0.0.0:0").await;
    run_with_wifi(app, link_events, link_commands, ui_commands, ui, clock, wifi).await;
}

/// `run` with the Wi-Fi socket (or the reason there is none) supplied by the caller.
pub async fn run_with_wifi(
    mut app: App,
    mut link_events: mpsc::Receiver<LinkEvent>,
    link_commands: mpsc::Sender<LinkCommand>,
    mut ui_commands: mpsc::UnboundedReceiver<UiCommand>,
    ui: impl UiSink,
    clock: Arc<dyn Clock>,
    wifi: io::Result<UdpSocket>,
) {
    let mut effects = app.start();
    let wifi = match wifi {
        Ok(socket) => Some(socket),
        Err(error) => {
            app.on_wifi_unavailable(error.kind());
            None
        }
    };
    let mut buf = [0u8; WIFI_BUFFER_LEN];
    loop {
        if !dispatch(effects, &link_commands, &ui, wifi.as_ref(), &mut app).await {
            return;
        }
        let wait = app.next_wake_ms().map(|at| Duration::from_millis(at.saturating_sub(clock.mono_ms())));
        let (next, quit) = tokio::select! {
            event = link_events.recv() => match event {
                Some(event) => (app.on_link(event), false),
                None => return,
            },
            command = ui_commands.recv() => match command {
                Some(command) => {
                    let quit = command == UiCommand::Quit;
                    (app.on_ui(command), quit)
                }
                None => return,
            },
            received = next_datagram(wifi.as_ref(), &mut buf) => match received {
                WifiRecv::Datagram(len, from) => (app.on_wifi_datagram(from, &buf[..len]), false),
                WifiRecv::Error(kind) => {
                    app.on_wifi_io("recv", kind);
                    (Vec::new(), false)
                }
            },
            () = sleep_or_forever(wait) => (app.on_tick(), false),
        };
        let delivered = dispatch(next, &link_commands, &ui, wifi.as_ref(), &mut app).await;
        if quit || !delivered {
            return;
        }
        effects = Vec::new();
    }
}

async fn sleep_or_forever(wait: Option<Duration>) {
    match wait {
        Some(duration) => tokio::time::sleep(duration).await,
        None => std::future::pending().await,
    }
}

/// The next datagram on the Wi-Fi socket; never ready without one.
async fn next_datagram(socket: Option<&UdpSocket>, buf: &mut [u8]) -> WifiRecv {
    match socket {
        Some(socket) => recv_datagram(socket, buf).await,
        None => std::future::pending().await,
    }
}

/// One datagram and where it came from, or the kind of error that stopped the wait. On Windows an earlier send to a closed
/// port comes back here as `ConnectionReset`; like every other error it is reported and the next wait follows, after a
/// short pause so that nothing can spin.
async fn recv_datagram(socket: &UdpSocket, buf: &mut [u8]) -> WifiRecv {
    match socket.recv_from(buf).await {
        Ok((len, from)) => WifiRecv::Datagram(len, from),
        Err(error) => {
            tokio::time::sleep(WIFI_ERROR_PAUSE).await;
            WifiRecv::Error(error.kind())
        }
    }
}

/// Sends `bytes` to each target. A target that cannot be reached gives an error kind and the others still get theirs.
async fn send_wifi(socket: &UdpSocket, targets: &[SocketAddrV4], bytes: &[u8]) -> Vec<io::ErrorKind> {
    let mut errors = Vec::new();
    for target in targets {
        if let Err(error) = socket.send_to(bytes, target).await {
            errors.push(error.kind());
        }
    }
    errors
}

/// Hands effects on. `false` when the link has gone away.
async fn dispatch(effects: Vec<Effect>, link: &mpsc::Sender<LinkCommand>, ui: &impl UiSink, wifi: Option<&UdpSocket>, app: &mut App) -> bool {
    for effect in effects {
        match effect {
            Effect::Link(command) => {
                if link.send(command).await.is_err() {
                    return false;
                }
            }
            Effect::Ui(event) => ui.send(event),
            Effect::Wifi(WifiCommand::Send { to, bytes }) => {
                if let Some(socket) = wifi {
                    for kind in send_wifi(socket, &to, &bytes).await {
                        app.on_wifi_io("send", kind);
                    }
                }
            }
        }
    }
    true
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::app::AppDeps;
    use crate::clock::SystemClock;
    use crate::config::Config;
    use crate::log::{Level, Logger, MemorySink};
    use crate::random::SequenceRandom;
    use crate::store::{MemoryConfigStore, MemoryPhoneStore};
    use rk_ble::{DeviceKey, Route};
    use rk_core::identity::HostPlatform;
    use rk_inject::RecordingInjector;
    use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
    use std::sync::Mutex;

    #[derive(Clone, Default)]
    struct CollectUi(Arc<Mutex<Vec<UiEvent>>>);

    impl UiSink for CollectUi {
        fn send(&self, event: UiEvent) {
            self.0.lock().unwrap().push(event);
        }
    }

    fn app() -> App {
        let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
        App::new(AppDeps {
            config: Config::new([9; 16], HostPlatform::Windows),
            platform: HostPlatform::Windows,
            store: Box::new(MemoryPhoneStore::new()),
            config_store: Box::new(MemoryConfigStore::new()),
            injector: Box::new(RecordingInjector::new()),
            clock: clock.clone(),
            random: Box::new(SequenceRandom::default()),
            logger: Logger::new(Box::new(MemorySink::new()), clock, Level::Info),
            pair_at_start: false,
        })
    }

    #[tokio::test]
    async fn link_events_become_link_commands_and_quit_ends_the_loop() {
        let (event_tx, event_rx) = mpsc::channel(8);
        let (command_tx, mut command_rx) = mpsc::channel(8);
        let (ui_tx, ui_rx) = mpsc::unbounded_channel();
        let collected = CollectUi::default();
        let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
        let task = tokio::spawn(run(app(), event_rx, command_tx, ui_rx, collected.clone(), clock));

        // Nobody is paired, so a connection through the selected UUID fails at once: authFailed, hang up, hold off.
        event_tx.send(LinkEvent::Connected { conn: 1, device: DeviceKey(5), route: Route::Selected, mtu: 185 }).await.unwrap();
        assert!(matches!(command_rx.recv().await, Some(LinkCommand::Write(_))));
        assert_eq!(command_rx.recv().await, Some(LinkCommand::Disconnect));
        assert!(matches!(command_rx.recv().await, Some(LinkCommand::Hold { .. })));

        ui_tx.send(UiCommand::Quit).unwrap();
        task.await.unwrap();
        assert!(collected.0.lock().unwrap().iter().any(|e| matches!(e, UiEvent::State(_))));
    }

    #[tokio::test]
    async fn the_pairing_window_closes_by_itself_through_the_timer() {
        let (event_tx, event_rx) = mpsc::channel(8);
        let (command_tx, mut command_rx) = mpsc::channel(8);
        let (ui_tx, ui_rx) = mpsc::unbounded_channel();
        let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
        let task = tokio::spawn(run(app(), event_rx, command_tx, ui_rx, CollectUi::default(), clock));
        ui_tx.send(UiCommand::StartPairing).unwrap();
        assert_eq!(command_rx.recv().await, Some(LinkCommand::SetPairingScan(true)));
        ui_tx.send(UiCommand::Quit).unwrap();
        assert_eq!(command_rx.recv().await, Some(LinkCommand::SetPairingScan(false)));
        task.await.unwrap();
        drop(event_tx);
    }

    // ---- Wi-Fi assist: the UDP socket

    fn loopback_target(socket: &UdpSocket) -> SocketAddrV4 {
        match socket.local_addr().unwrap() {
            SocketAddr::V4(addr) => addr,
            SocketAddr::V6(_) => panic!("an IPv4 socket"),
        }
    }

    #[tokio::test]
    async fn a_send_command_puts_the_same_datagram_on_the_wire_for_every_target() {
        let (a, b) = (UdpSocket::bind("127.0.0.1:0").await.unwrap(), UdpSocket::bind("127.0.0.1:0").await.unwrap());
        let ours = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let errors = send_wifi(&ours, &[loopback_target(&a), loopback_target(&b)], &[7; 41]).await;
        assert_eq!(errors, vec![]);
        for socket in [&a, &b] {
            let mut buf = [0u8; 64];
            let (n, from) = tokio::time::timeout(Duration::from_secs(2), socket.recv_from(&mut buf)).await.unwrap().unwrap();
            assert_eq!((&buf[..n], from), (&[7u8; 41][..], ours.local_addr().unwrap()));
        }
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_target_that_cannot_be_sent_to_is_an_error_kind_and_the_others_still_get_their_datagram() {
        let good = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let ours = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        // A broadcast address needs SO_BROADCAST, which this socket does not set: the send is refused.
        let refused = SocketAddrV4::new(Ipv4Addr::BROADCAST, 9);
        let errors = send_wifi(&ours, &[refused, loopback_target(&good)], &[1; 41]).await;
        assert_eq!(errors.len(), 1, "one error, for the one target");
        let mut buf = [0u8; 64];
        let (n, _) = tokio::time::timeout(Duration::from_secs(2), good.recv_from(&mut buf)).await.unwrap().unwrap();
        assert_eq!(n, 41);
    }

    #[tokio::test]
    async fn a_datagram_is_received_with_the_address_it_came_from() {
        let ours = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let theirs = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        theirs.send_to(&[3; 41], ours.local_addr().unwrap()).await.unwrap();
        let mut buf = [0u8; WIFI_BUFFER_LEN];
        match recv_datagram(&ours, &mut buf).await {
            WifiRecv::Datagram(n, from) => assert_eq!((n, from), (41, theirs.local_addr().unwrap())),
            WifiRecv::Error(kind) => panic!("a datagram was waiting, got {kind:?}"),
        }
    }

    fn app_with_logs() -> (App, MemorySink) {
        let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
        let sink = MemorySink::new();
        let app = App::new(AppDeps {
            config: Config::new([9; 16], HostPlatform::Windows),
            platform: HostPlatform::Windows,
            store: Box::new(MemoryPhoneStore::new()),
            config_store: Box::new(MemoryConfigStore::new()),
            injector: Box::new(RecordingInjector::new()),
            clock: clock.clone(),
            random: Box::new(SequenceRandom::default()),
            logger: Logger::new(Box::new(sink.clone()), clock, Level::Debug),
            pair_at_start: false,
        });
        (app, sink)
    }

    #[tokio::test]
    async fn datagrams_reach_the_application_and_a_socket_does_not_keep_the_loop_from_ending() {
        let (app, logs) = app_with_logs();
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let addr = socket.local_addr().unwrap();
        let (_event_tx, event_rx) = mpsc::channel(8);
        let (command_tx, _command_rx) = mpsc::channel(8);
        let (ui_tx, ui_rx) = mpsc::unbounded_channel();
        let clock: Arc<dyn Clock> = Arc::new(SystemClock::new());
        let task = tokio::spawn(run_with_wifi(app, event_rx, command_tx, ui_rx, CollectUi::default(), clock, Ok(socket)));

        // Nobody is connected and nothing is probed, so the application drops it, and says why.
        UdpSocket::bind("127.0.0.1:0").await.unwrap().send_to(&[3; 41], addr).await.unwrap();
        let heard = async {
            loop {
                if logs.lines().iter().any(|l| l.contains("ev=wifi_drop") && l.contains("why=no_probing")) {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        };
        tokio::time::timeout(Duration::from_secs(3), heard).await.expect("the application was handed the datagram");

        ui_tx.send(UiCommand::Quit).unwrap();
        tokio::time::timeout(Duration::from_secs(3), task).await.expect("the loop ends on quit").unwrap();
    }
}
