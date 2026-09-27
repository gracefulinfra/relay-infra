# Minimal smart-HTTP git server for LOCAL_GIT=1: lighttpd runs git-http-backend over /srv/git.
# Local development only. It has no authentication and is reachable only inside the cluster and via port-forward.
FROM docker.io/library/alpine:3.24@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache git git-daemon lighttpd \
 && adduser -D -u 10001 -h /srv git \
 && mkdir -p /srv/git && chown git:git /srv/git
COPY lighttpd.conf /etc/lighttpd/relay-git.conf
COPY entrypoint.sh /entrypoint.sh
USER 10001
EXPOSE 8080
ENTRYPOINT ["/bin/sh", "/entrypoint.sh"]
