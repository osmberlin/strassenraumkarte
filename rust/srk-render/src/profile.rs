//! Per-tile stage timing (best-effort; enabled via `--profile`).

use serde::Serialize;
use std::time::{Duration, Instant};

/// Mutable accumulator threaded through render/paint helpers.
#[derive(Default, Clone, Copy, Debug)]
pub struct StageTimers {
    pub sql_ms: u64,
    pub paint_ms: u64,
    pub shapeburst_ms: u64,
    pub shadow_ms: u64,
    pub encode_ms: u64,
}

impl StageTimers {
    pub fn merge(&mut self, other: &StageTimers) {
        self.sql_ms += other.sql_ms;
        self.paint_ms += other.paint_ms;
        self.shapeburst_ms += other.shapeburst_ms;
        self.shadow_ms += other.shadow_ms;
        self.encode_ms += other.encode_ms;
    }

    pub fn record(&mut self, slot: &mut u64, elapsed: Duration) {
        *slot += elapsed.as_millis() as u64;
    }
}

/// Run `f` and add elapsed ms to `slot` when profiling is enabled.
pub fn time_stage<F, R>(timers: &mut Option<&mut StageTimers>, slot: StageSlot, f: F) -> R
where
    F: FnOnce() -> R,
{
    match timers.as_deref_mut() {
        Some(t) => {
            let start = Instant::now();
            let out = f();
            let ms = start.elapsed().as_millis() as u64;
            match slot {
                StageSlot::Sql => t.sql_ms += ms,
                StageSlot::Paint => t.paint_ms += ms,
                StageSlot::Shapeburst => t.shapeburst_ms += ms,
                StageSlot::Shadow => t.shadow_ms += ms,
                StageSlot::Encode => t.encode_ms += ms,
            }
            out
        }
        None => f(),
    }
}

#[derive(Clone, Copy)]
pub enum StageSlot {
    Sql,
    Paint,
    Shapeburst,
    Shadow,
    Encode,
}

/// Aggregated stage totals written to `timing.json` when `--profile` is set.
#[derive(Serialize, Default, Clone, Debug)]
pub struct StageProfile {
    pub sql_ms: u64,
    pub paint_ms: u64,
    pub shapeburst_ms: u64,
    pub shadow_ms: u64,
    pub encode_ms: u64,
}

impl From<StageTimers> for StageProfile {
    fn from(t: StageTimers) -> Self {
        Self {
            sql_ms: t.sql_ms,
            paint_ms: t.paint_ms,
            shapeburst_ms: t.shapeburst_ms,
            shadow_ms: t.shadow_ms,
            encode_ms: t.encode_ms,
        }
    }
}
