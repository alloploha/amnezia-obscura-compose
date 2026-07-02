FROM alpine:3.20 AS xray-fetch

ARG XRAY_RELEASE="v25.8.3"

RUN apk add --no-cache ca-certificates curl unzip

RUN curl -fsSL "https://github.com/XTLS/Xray-core/releases/download/${XRAY_RELEASE}/Xray-linux-64.zip" -o /tmp/xray.zip \
    && unzip /tmp/xray.zip xray -d /out \
    && chmod 0755 /out/xray \
    && rm -f /tmp/xray.zip

FROM alpine:3.20

RUN apk add --no-cache bash ca-certificates openssl

RUN mkdir -p /opt/amnezia/xray /opt/obscura /var/lib/obscura/xray

COPY --from=xray-fetch /out/xray /usr/local/bin/xray

COPY entrypoint.sh /opt/obscura/entrypoint.sh
COPY healthcheck.sh /opt/obscura/healthcheck.sh
COPY server.template.json /opt/obscura/server.template.json
COPY client.template.json /opt/obscura/client.template.json

RUN sed -i 's/\r$//' /opt/obscura/entrypoint.sh /opt/obscura/healthcheck.sh \
    && chmod 0755 /opt/obscura/entrypoint.sh /opt/obscura/healthcheck.sh

ENTRYPOINT ["/opt/obscura/entrypoint.sh"]
CMD ["xray", "run", "-config", "/opt/amnezia/xray/server.json"]
