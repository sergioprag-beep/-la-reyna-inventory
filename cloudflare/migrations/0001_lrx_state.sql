CREATE TABLE IF NOT EXISTS lrx_state_meta (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  revision INTEGER NOT NULL,
  object_key TEXT NOT NULL,
  updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS lrx_state_chunks (
  snapshot_id TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  chunk_data TEXT NOT NULL,
  PRIMARY KEY (snapshot_id, chunk_index)
);

CREATE TABLE IF NOT EXISTS lrx_resources (
  resource_path TEXT NOT NULL,
  chunk_index INTEGER NOT NULL,
  content_type TEXT NOT NULL,
  chunk_data BLOB NOT NULL,
  PRIMARY KEY (resource_path, chunk_index)
);
