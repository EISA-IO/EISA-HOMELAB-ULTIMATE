FROM node:20-alpine

WORKDIR /app
COPY package.json server.js ./

# Run as non-root for defence-in-depth.
RUN addgroup -S app && adduser -S app -G app \
 && chown -R app:app /app

USER app

EXPOSE 8080
ENV NODE_ENV=production \
    PORT=8080 \
    HOST=0.0.0.0

HEALTHCHECK --interval=15s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/healthz >/dev/null 2>&1 || exit 1

CMD ["node", "server.js"]
