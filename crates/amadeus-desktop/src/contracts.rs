use std::sync::mpsc::Sender;
use std::time::Duration;

use amadeus_core::{ComputerActivity, PerceptionEvent};

pub trait ForegroundResolver: Send + Sync {
    fn current_activity(&self) -> Option<ComputerActivity>;
}

pub trait IdleDetector: Send + Sync {
    fn idle_duration(&self) -> Duration;

    fn is_idle(&self, threshold: Duration) -> bool {
        self.idle_duration() >= threshold
    }
}

pub trait PerceptionSink: Send {
    fn accept(&mut self, event: PerceptionEvent);
}

impl<F> PerceptionSink for F
where
    F: FnMut(PerceptionEvent) + Send,
{
    fn accept(&mut self, event: PerceptionEvent) {
        self(event);
    }
}

pub struct ObserverHandle {
    stop_tx: Sender<()>,
    pause_tx: Sender<bool>,
}

impl ObserverHandle {
    pub(crate) fn new(stop_tx: Sender<()>, pause_tx: Sender<bool>) -> Self {
        Self { stop_tx, pause_tx }
    }

    pub fn pause(&self) {
        let _ = self.pause_tx.send(true);
    }

    pub fn resume(&self) {
        let _ = self.pause_tx.send(false);
    }

    pub fn stop(self) {
        let _ = self.stop_tx.send(());
    }
}

impl Drop for ObserverHandle {
    fn drop(&mut self) {
        let _ = self.stop_tx.send(());
    }
}
