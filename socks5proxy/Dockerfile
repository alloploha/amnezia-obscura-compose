FROM 3proxy/3proxy:latest

COPY 3proxy.base.cfg /opt/obscura/3proxy.base.cfg
COPY entrypoint.sh /opt/obscura/entrypoint.sh

RUN chmod 0755 /opt/obscura/entrypoint.sh \
    && mkdir -p /var/lib/obscura/socks5proxy \
    && chown 65535:65535 /var/lib/obscura/socks5proxy

ENTRYPOINT ["/opt/obscura/entrypoint.sh"]
CMD ["/bin/3proxy", "/etc/3proxy/3proxy.cfg"]
