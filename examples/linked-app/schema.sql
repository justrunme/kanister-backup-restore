-- Linked application state: Postgres rows reference S3 objects.
-- generation is the single logical version counter across components.

CREATE TABLE IF NOT EXISTS app_manifest (
  id INT PRIMARY KEY DEFAULT 1 CHECK (id = 1),
  generation BIGINT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS app_objects (
  id SERIAL PRIMARY KEY,
  object_key TEXT NOT NULL UNIQUE,
  sha256 TEXT NOT NULL,
  generation BIGINT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_app_objects_generation ON app_objects (generation);
