# Stage 1 — compile Elixir release
FROM elixir:alpine AS builder
RUN apk add --no-cache build-base git sqlite-dev gettext wget tar
WORKDIR /build
COPY backend/mix.exs backend/mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile

# Override the precompiled vec0.so bundled by the sqlite_vec hex package.
# Upstream's v0.1.5 `linux-aarch64.tar.gz` release ships a 32-bit ARM
# binary by mistake (verified: same SHA the hex package pins, but
# e_machine = 0x28 = EM_ARM). On aarch64-musl hosts it can't be
# dlopen'd → `Exqlite.Error: no such module: vec0` → boot crash loop.
# Compiling from upstream source is deterministic across architectures
# and side-steps the broken release artifact entirely. See
# specs/known_issues.md.
ARG SQLITE_VEC_VERSION=0.1.5
RUN cd /tmp && \
    wget -qO- https://github.com/asg017/sqlite-vec/archive/refs/tags/v${SQLITE_VEC_VERSION}.tar.gz | tar xz && \
    cd sqlite-vec-${SQLITE_VEC_VERSION} && \
    # musl libc lacks BSD's `u_int8_t`; without it gcc silently falls back
    # to `int` for the dependent `uint8_t` typedef, breaking pointer types
    # downstream. stdint.h already provides uint{8,16,64}_t directly, so
    # the BSD-compat typedefs are redundant — drop them.
    sed -i '/typedef u_int8_t uint8_t;/d; /typedef u_int16_t uint16_t;/d; /typedef u_int64_t uint64_t;/d' sqlite-vec.c && \
    VERSION=$(cat VERSION) DATE=$(date +%FT%TZ%z) SOURCE= envsubst < sqlite-vec.h.tmpl > sqlite-vec.h && \
    cc -fPIC -shared -O3 sqlite-vec.c -o vec0.so && \
    cp vec0.so /build/deps/sqlite_vec/priv/${SQLITE_VEC_VERSION}/vec0.so

COPY backend/ .
RUN MIX_ENV=prod mix release --overwrite

# Stage 2 — resize logo (imagemagick stays out of the runtime image)
FROM alpine:3 AS assets
RUN apk add --no-cache imagemagick
COPY logo.png /tmp/logo.png
RUN magick /tmp/logo.png -resize 180x180 /tmp/apple-touch-icon.png

# Stage 3 — minimal runtime
FROM alpine:3
RUN apk add --no-cache \
      su-exec openssl libstdc++ libgcc ncurses-libs bash \
      ffmpeg imagemagick poppler-utils pandoc docker-cli openssh-keygen \
      vips-tools && \
    mkdir -p /app/ssl && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout /app/ssl/key.pem \
      -out /app/ssl/cert.pem \
      -subj "/CN=dmh-ai" 2>/dev/null
RUN mkdir -p /app/static && \
    wget -qO /app/static/marked.min.js \
      https://cdn.jsdelivr.net/npm/marked/marked.min.js && \
    wget -qO /app/static/pdf.min.js \
      https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.min.mjs && \
    wget -qO /app/static/pdf.worker.min.js \
      https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.worker.min.mjs && \
    wget -qO /app/static/mammoth.min.js \
      https://cdn.jsdelivr.net/npm/mammoth@1.8.0/mammoth.browser.min.js && \
    wget -qO /app/static/xlsx.min.js \
      https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js && \
    wget -qO /app/static/heic2any.min.js \
      https://cdn.jsdelivr.net/npm/heic2any@0.0.4/dist/heic2any.min.js
RUN adduser -D -u 1000 appuser && mkdir -p /data && \
    chown -R appuser:appuser /app/ssl
COPY --from=builder /build/_build/prod/rel/dmh_ai /app
COPY index.html /app/static/
COPY css/ /app/static/css/
COPY js/ /app/static/js/
COPY logo.png /app/static/logo.png
COPY wf-icon.png /app/static/wf-icon.png
COPY --from=assets /tmp/apple-touch-icon.png /app/static/apple-touch-icon.png
COPY manifest.json /app/static/manifest.json
COPY sw.js /app/static/sw.js
COPY start.sh /start.sh
RUN chmod +x /start.sh
EXPOSE 8080
EXPOSE 8443
CMD ["/start.sh"]
