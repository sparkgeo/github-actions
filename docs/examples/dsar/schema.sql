-- Small PostGIS schema the example DSAR scripts and the harness test run
-- against (docs/dsar.md). users holds the subject, location_events the trail,
-- audit_log keeps a row per action that must survive erasure anonymised.
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE TABLE IF NOT EXISTS users (
  id uuid PRIMARY KEY,
  email text NOT NULL UNIQUE,
  full_name text NOT NULL,
  phone text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS location_events (
  id bigserial PRIMARY KEY,
  user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  at timestamptz NOT NULL,
  geom geometry(Point, 4326) NOT NULL
);
CREATE TABLE IF NOT EXISTS audit_log (
  id bigserial PRIMARY KEY,
  subject_id uuid,
  actor text,
  action text NOT NULL,
  detail jsonb,
  at timestamptz NOT NULL DEFAULT now()
);
