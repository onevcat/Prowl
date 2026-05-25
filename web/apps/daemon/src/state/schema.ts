export const schemaSql = `
CREATE TABLE IF NOT EXISTS repos (
  id TEXT PRIMARY KEY,
  path TEXT NOT NULL UNIQUE,
  display_name TEXT,
  appearance_json TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS worktrees (
  id TEXT PRIMARY KEY,
  repo_id TEXT NOT NULL REFERENCES repos(id) ON DELETE CASCADE,
  path TEXT NOT NULL,
  branch TEXT,
  status TEXT,
  task_status TEXT,
  metadata_json TEXT,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS custom_actions (
  id TEXT PRIMARY KEY,
  repo_id TEXT REFERENCES repos(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  command TEXT NOT NULL,
  shortcut TEXT,
  icon TEXT,
  output_mode TEXT NOT NULL DEFAULT 'currentPane',
  ordering INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS settings (
  key TEXT PRIMARY KEY,
  value_json TEXT NOT NULL
);
`;
