FROM nginx:alpine
RUN apk add --no-cache python3 && \
    wget -qO /usr/share/nginx/html/marked.min.js \
      https://cdn.jsdelivr.net/npm/marked/marked.min.js
RUN mkdir -p /data /app
COPY backend/server.py /app/server.py
COPY index.html /usr/share/nginx/html/
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY start.sh /start.sh
RUN chmod +x /start.sh
EXPOSE 8080
CMD ["/start.sh"]
