-- Keep snapshot cleanup bounded: querying DISTINCT across chunk_data reads the
-- full multi-megabyte history on every save and can exceed Pages Function limits.
CREATE TABLE IF NOT EXISTS lrx_state_snapshots (
  revision INTEGER PRIMARY KEY,
  snapshot_id TEXT NOT NULL UNIQUE
);
