FROM alpine:3
RUN apk add --no-cache \
      bash curl wget python3 py3-pip jq git \
      nodejs npm make gcc g++ musl-dev \
      ca-certificates tzdata
RUN pip3 install --no-cache-dir requests httpx --break-system-packages 2>/dev/null || \
    pip3 install --no-cache-dir requests httpx
RUN adduser -D -u 1000 sandbox
WORKDIR /data
CMD ["tail", "-f", "/dev/null"]
