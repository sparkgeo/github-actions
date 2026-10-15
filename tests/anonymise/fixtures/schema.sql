-- Sample PostGIS schema with one seeded subject (Jane) and one bystander, used
-- by tests/anonymise/run.sh and documented in docs/anonymisation.md as the
-- re-identification spot check.
CREATE TABLE users (
  id serial PRIMARY KEY,
  first_name text, last_name text, email text, phone text, notes text, sin text,
  home geometry(Point, 4326)
);
CREATE TABLE location_events (
  id serial PRIMARY KEY,
  user_id int REFERENCES users (id),
  at timestamptz,
  geom geometry(Point, 4326)
);
INSERT INTO users (first_name, last_name, email, phone, notes, sin, home) VALUES
  ('Jane', 'Doe', 'jane.doe@acme-client.com', '+1 604 731 2222', 'Called about billing; lives near Kits Beach', '130 529 475', ST_SetSRID(ST_MakePoint(-123.1565, 49.2733), 4326)),
  ('Bob', 'Example', 'bob@example.org', '+1 604 555 0199', 'VIP, prefers email', NULL, ST_SetSRID(ST_MakePoint(-123.1207, 49.2827), 4326));
INSERT INTO location_events (user_id, at, geom) VALUES
  (1, '2026-10-01T08:00:00Z', ST_SetSRID(ST_MakePoint(-123.1565, 49.2733), 4326)),
  (1, '2026-10-01T08:30:00Z', ST_SetSRID(ST_MakePoint(-123.1610, 49.2710), 4326)),
  (1, '2026-10-01T09:00:00Z', ST_SetSRID(ST_MakePoint(-123.1402, 49.2820), 4326));
