-- Loop v1 schema. Holds no personal data: no names, contacts, places tied to a person, routes or times.

CREATE TABLE users (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash bytea UNIQUE NOT NULL,
  handle text NOT NULL,
  created_on date NOT NULL,
  area text NULL,           -- geohash precision 4 (city scale)
  hour smallint NULL CHECK (hour BETWEEN 0 AND 23),
  nearby boolean NOT NULL DEFAULT true,
  same_hour boolean NOT NULL DEFAULT true,
  push_token text NULL,
  push_env text NULL CHECK (push_env IN ('sandbox', 'production'))
);

-- Stored in both directions.
CREATE TABLE friendships (
  a uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  b uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  created_on date NOT NULL,
  PRIMARY KEY (a, b),
  CHECK (a <> b)
);
CREATE INDEX friendships_b ON friendships (b);

CREATE TABLE invites (
  code_hash bytea PRIMARY KEY,
  inviter uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  expires_at timestamptz NOT NULL,
  used boolean NOT NULL DEFAULT false
);
CREATE INDEX invites_inviter ON invites (inviter);

CREATE TABLE circles (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  kind text NOT NULL CHECK (kind IN ('nearby', 'hour')),
  key text NOT NULL,
  month date NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX circles_lookup ON circles (kind, key, month);

CREATE TABLE circle_members (
  circle_id uuid NOT NULL REFERENCES circles(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  PRIMARY KEY (circle_id, user_id)
);
CREATE INDEX circle_members_user ON circle_members (user_id);

CREATE TABLE showups (
  user_id uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  day date NOT NULL,
  kinds smallint NOT NULL,
  PRIMARY KEY (user_id, day)
);

CREATE TABLE cheers (
  circle_key text NOT NULL,
  from_user uuid NOT NULL REFERENCES users(id) ON DELETE CASCADE,
  to_user uuid NULL REFERENCES users(id) ON DELETE CASCADE,
  day date NOT NULL
);
CREATE UNIQUE INDEX cheers_one_per_person ON cheers (from_user, to_user, day) WHERE to_user IS NOT NULL;
CREATE UNIQUE INDEX cheers_one_per_circle ON cheers (circle_key, from_user, day) WHERE to_user IS NULL;
CREATE INDEX cheers_to ON cheers (to_user, day);
CREATE INDEX cheers_key_day ON cheers (circle_key, day);

-- Anonymous map counts. Tags are random per person per month, made on the phone.
CREATE TABLE map_cells (
  g text NOT NULL,
  p smallint NOT NULL,
  month date NOT NULL,
  n int NOT NULL,
  people int NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  PRIMARY KEY (g, month)
);
CREATE INDEX map_cells_query ON map_cells (p, month, lat, lng);

CREATE TABLE map_tags (
  g text NOT NULL,
  month date NOT NULL,
  tag bytea NOT NULL,
  PRIMARY KEY (g, month, tag)
);

CREATE TABLE live_cells (
  g text NOT NULL,
  bucket timestamptz NOT NULL,
  people int NOT NULL,
  n int NOT NULL,
  lat double precision NOT NULL,
  lng double precision NOT NULL,
  PRIMARY KEY (g, bucket)
);
CREATE INDEX live_cells_bucket ON live_cells (bucket, lat, lng);

CREATE TABLE live_tags (
  g text NOT NULL,
  bucket timestamptz NOT NULL,
  tag bytea NOT NULL,
  PRIMARY KEY (g, bucket, tag)
);
