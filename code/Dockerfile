FROM nginx:alpine
RUN apk add --no-cache python3 su-exec openssl imagemagick && \
    mkdir -p /etc/nginx/ssl && \
    openssl req -x509 -nodes -days 3650 -newkey rsa:2048 \
      -keyout /etc/nginx/ssl/key.pem \
      -out /etc/nginx/ssl/cert.pem \
      -subj "/CN=dmh-ai" 2>/dev/null && \
    wget -qO /usr/share/nginx/html/marked.min.js \
      https://cdn.jsdelivr.net/npm/marked/marked.min.js && \
    wget -qO /usr/share/nginx/html/pdf.min.js \
      https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.min.mjs && \
    wget -qO /usr/share/nginx/html/pdf.worker.min.js \
      https://cdn.jsdelivr.net/npm/pdfjs-dist@4.4.168/build/pdf.worker.min.mjs && \
    wget -qO /usr/share/nginx/html/mammoth.min.js \
      https://cdn.jsdelivr.net/npm/mammoth@1.8.0/mammoth.browser.min.js && \
    wget -qO /usr/share/nginx/html/xlsx.min.js \
      https://cdn.jsdelivr.net/npm/xlsx@0.18.5/dist/xlsx.full.min.js && \
    wget -qO /usr/share/nginx/html/heic2any.min.js \
      https://cdn.jsdelivr.net/npm/heic2any@0.0.4/dist/heic2any.min.js
RUN adduser -D -u 1000 appuser && \
    mkdir -p /data /app && chown appuser:appuser /data /app
COPY backend/server.py /app/server.py
COPY backend/blocked_domains.py /app/blocked_domains.py
COPY backend/constants.py /app/constants.py
COPY index.html /usr/share/nginx/html/
COPY css/ /usr/share/nginx/html/css/
COPY js/ /usr/share/nginx/html/js/
COPY logo.png /usr/share/nginx/html/logo.png
RUN magick /usr/share/nginx/html/logo.png -resize 180x180 /usr/share/nginx/html/apple-touch-icon.png
COPY manifest.json /usr/share/nginx/html/manifest.json
COPY sw.js /usr/share/nginx/html/sw.js
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY start.sh /start.sh
RUN chmod +x /start.sh
EXPOSE 8080
CMD ["/start.sh"]
