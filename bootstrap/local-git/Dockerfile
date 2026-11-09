# Minimal smart-HTTP git server for LOCAL_GIT=1: lighttpd runs git-http-backend over /srv/git.
# Local development only. It has no authentication and is reachable only inside the cluster and via port-forward.
FROM docker.io/library/alpine:3.24@sha256:f59abe656b692d901e184be3445e084786602108599d2a51d229c0f5a48c71bf
RUN apk add --no-cache git git-daemon lighttpd \
 && adduser -D -u 10001 -h /srv git \
 && mkdir -p /srv/git && chown git:git /srv/git
COPY lighttpd.conf /etc/lighttpd/relay-git.conf
COPY entrypoint.sh /entrypoint.sh
USER 10001
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
