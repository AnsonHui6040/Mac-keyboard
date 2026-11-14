//! Joins the application to the outside world: the link channels, the tray and the clock.

use crate::app::{App, Effect};
use crate::clock::Clock;
use crate::ui::{UiCommand, UiEvent};
use rk_ble::{LinkCommand, LinkEvent};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

/// Where tray updates go; the shell implements it for its window system.
pub trait UiSink: Send + 'static {
    fn send(&self, event: UiEvent);
}

/// Runs the application until the tray says `Quit` or a channel closes. Returns once the farewell (`bye`, `Disconnect`) has
/// been handed to the link.
pub async fn run(
    mut app: App,
    mut link_events: mpsc::Receiver<LinkEvent>,
    link_commands: mpsc::Sender<LinkCommand>,
    mut ui_commands: mpsc::UnboundedReceiver<UiCommand>,
    ui: impl UiSink,
    clock: Arc<dyn Clock>,
) {
    let mut effects = app.start();
    loop {
        if !dispatch(effects, &link_commands, &ui).await {
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
            () = sleep_or_forever(wait) => (app.on_tick(), false),
        };
        let delivered = dispatch(next, &link_commands, &ui).await;
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

/// Hands effects on. `false` when the link has gone away.
async fn dispatch(effects: Vec<Effect>, link: &mpsc::Sender<LinkCommand>, ui: &impl UiSink) -> bool {
    for effect in effects {
        match effect {
            Effect::Link(command) => {
                if link.send(command).await.is_err() {
                    return false;
                }
            }
            Effect::Ui(event) => ui.send(event),
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
}
