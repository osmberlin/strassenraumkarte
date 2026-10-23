//! Per-worker prepared statement cache for stable layer SQL strings.

use std::collections::HashMap;

use anyhow::Result;
use postgres::types::ToSql;
use postgres::{Client, Row, Statement};

use crate::profile::{StageSlot, StageTimers};

/// Lazily prepares layer SQL once per worker thread.
#[derive(Default)]
pub struct PreparedCache {
    index: HashMap<String, usize>,
    statements: Vec<Statement>,
}

impl PreparedCache {
    fn idx_for(&mut self, client: &mut Client, sql: &str) -> Result<usize> {
        if let Some(&idx) = self.index.get(sql) {
            return Ok(idx);
        }
        let stmt = client.prepare(sql)?;
        let idx = self.statements.len();
        self.statements.push(stmt);
        self.index.insert(sql.to_string(), idx);
        Ok(idx)
    }
}

/// Run a prepared query, timing under `StageSlot::Sql` when profiling.
pub fn query_prep(
    client: &mut Client,
    cache: &mut PreparedCache,
    timers: &mut Option<&mut StageTimers>,
    sql: &str,
    params: &[&(dyn ToSql + Sync)],
) -> Result<Vec<Row>> {
    let idx = cache.idx_for(client, sql)?;
    let stmt = &cache.statements[idx];
    crate::profile::time_stage(timers, StageSlot::Sql, || client.query(stmt, params))
        .map_err(Into::into)
}
