FROM 3proxy/3proxy:busybox

COPY 3proxy.base.cfg /opt/obscura/3proxy.base.cfg
COPY entrypoint.sh /opt/obscura/entrypoint.sh
COPY healthcheck.sh /opt/obscura/healthcheck.sh

RUN sed -i 's/\r$//' /opt/obscura/entrypoint.sh /opt/obscura/healthcheck.sh /opt/obscura/3proxy.base.cfg \
    && chmod 0755 /opt/obscura/entrypoint.sh /opt/obscura/healthcheck.sh \
    && mkdir -p /var/lib/obscura/socks5proxy \
    && chown 65535:65535 /var/lib/obscura/socks5proxy

ENTRYPOINT ["/opt/obscura/entrypoint.sh"]
CMD ["/bin/3proxy", "/usr/local/3proxy/conf/3proxy.cfg"]
