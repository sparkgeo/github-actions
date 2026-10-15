-- Masking rules for postgresql_anonymizer (SecOps plan Step 36 Standard,
-- issue #123). Copy to db/anon-rules.sql and edit the column list; the
-- anonymise composite runs this file with psql after restoring the dump
-- (geohash-precision is set as the database setting anon_geo.precision),
-- then anon.anonymize_database().
-- Rule authoring and geohash guidance: docs/anonymisation.md.

-- Helper functions live in public and are declared TRUSTED so anon accepts
-- them as masking functions (anon.restrict_to_trusted_schemas is on).
CREATE OR REPLACE FUNCTION public.anon_geo_truncate(g geometry)
RETURNS geometry LANGUAGE sql STABLE AS $$
  -- snap the point to the centre of its geohash cell: 5 chars is about 4.9 km,
  -- so two readings from the same home land on the same point and no trail remains;
  -- the precision comes from the database setting anon_geo.precision (workflow input)
  SELECT CASE WHEN g IS NULL THEN NULL
              ELSE ST_SetSRID(ST_PointFromGeoHash(ST_GeoHash(ST_Transform(g, 4326), p), p), 4326) END
  FROM (SELECT coalesce(nullif(current_setting('anon_geo.precision', true), ''), '5')::int AS p) AS s
$$;
SECURITY LABEL FOR anon ON FUNCTION public.anon_geo_truncate(geometry) IS 'TRUSTED';

-- Identity and contact
SECURITY LABEL FOR anon ON COLUMN users.first_name IS 'MASKED WITH FUNCTION anon.fake_first_name()';
SECURITY LABEL FOR anon ON COLUMN users.last_name  IS 'MASKED WITH FUNCTION anon.fake_last_name()';
SECURITY LABEL FOR anon ON COLUMN users.email      IS 'MASKED WITH FUNCTION anon.fake_email()';
SECURITY LABEL FOR anon ON COLUMN users.phone      IS 'MASKED WITH FUNCTION anon.random_phone_with_format(''+1 604 555 01##'')';

-- Free text: replace, never redact in place (a redacted note still leaks its length and shape)
SECURITY LABEL FOR anon ON COLUMN users.notes      IS 'MASKED WITH FUNCTION anon.lorem_ipsum( words := 12 )';

-- Government identifiers: drop, there is no realistic fake that is also safe
SECURITY LABEL FOR anon ON COLUMN users.sin        IS 'MASKED WITH VALUE NULL';

-- Geometry: truncate to the geohash cell (anon_geo.precision, from geohash-precision)
SECURITY LABEL FOR anon ON COLUMN users.home            IS 'MASKED WITH FUNCTION public.anon_geo_truncate(home)';
SECURITY LABEL FOR anon ON COLUMN location_events.geom  IS 'MASKED WITH FUNCTION public.anon_geo_truncate(geom)';
