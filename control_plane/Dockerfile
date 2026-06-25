# syntax=docker/dockerfile:1

# --- build stage ---------------------------------------------------------
FROM elixir:1.17-alpine AS build

# Build tooling for native deps.
RUN apk add --no-cache build-base git

WORKDIR /app

ENV MIX_ENV=prod

# Install hex + rebar.
RUN mix local.hex --force && mix local.rebar --force

# Fetch and compile dependencies (cached layer).
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Compile-time config.
COPY config config

# Application source.
COPY priv priv
COPY lib lib

# Assets (Phoenix 1.7 / esbuild + tailwind). Safe no-op if absent.
COPY asset[s] assets
RUN mix assets.deploy || true

# Build the release.
RUN mix compile
COPY rel rel
RUN mix release

# --- runtime stage -------------------------------------------------------
FROM alpine:3.20 AS runtime

# Runtime libs required by the BEAM release.
RUN apk add --no-cache libstdc++ openssl ncurses-libs libgcc \
    && addgroup -S bunk \
    && adduser -S -G bunk bunk

WORKDIR /app

ENV MIX_ENV=prod \
    LANG=C.UTF-8 \
    HOME=/app

# Copy the self-contained release built above.
COPY --from=build --chown=bunk:bunk /app/_build/prod/rel/control_plane ./

USER bunk

ENTRYPOINT ["/app/bin/control_plane"]
CMD ["start"]
