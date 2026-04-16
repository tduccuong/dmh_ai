# Stage 1 — compile Elixir release
FROM elixir:alpine AS builder
RUN apk add --no-cache build-base git
WORKDIR /build
COPY backend/mix.exs backend/mix.lock* ./
RUN mix local.hex --force && mix local.rebar --force
RUN mix deps.get --only prod
RUN MIX_ENV=prod mix deps.compile
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
      ffmpeg imagemagick poppler-utils pandoc && \
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
COPY --from=builder /build/_build/prod/rel/dmhai /app
COPY index.html /app/static/
COPY css/ /app/static/css/
COPY js/ /app/static/js/
COPY logo.png /app/static/logo.png
COPY --from=assets /tmp/apple-touch-icon.png /app/static/apple-touch-icon.png
COPY manifest.json /app/static/manifest.json
COPY sw.js /app/static/sw.js
COPY start.sh /start.sh
RUN chmod +x /start.sh
EXPOSE 8080
EXPOSE 8443
CMD ["/start.sh"]
