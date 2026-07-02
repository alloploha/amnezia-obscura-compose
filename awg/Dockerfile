FROM amneziavpn/amneziawg-go:latest

RUN apk add --no-cache bash iproute2 iptables python3

RUN mkdir -p /opt/amnezia/awg /opt/obscura /var/lib/obscura/awg

COPY entrypoint.sh /opt/obscura/entrypoint.sh
COPY healthcheck.sh /opt/obscura/healthcheck.sh
COPY awg0.template.conf /opt/obscura/awg0.template.conf
COPY client.template.conf /opt/obscura/client.template.conf

RUN sed -i 's/\r$//' /opt/obscura/entrypoint.sh /opt/obscura/healthcheck.sh \
    && chmod 0755 /opt/obscura/entrypoint.sh /opt/obscura/healthcheck.sh

ENTRYPOINT ["/opt/obscura/entrypoint.sh"]
CMD ["tail", "-f", "/dev/null"]
