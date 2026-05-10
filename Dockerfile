FROM alpine:latest AS rq-build

ARG TZ=UTC
ENV TZ=${TZ}

ENV RQ_VERSION=1.0.2
WORKDIR /root/

RUN apk update \
    && apk add --no-cache upx \
    && wget https://github.com/dflemstr/rq/releases/download/v${RQ_VERSION}/rq-v${RQ_VERSION}-x86_64-unknown-linux-musl.tar.gz \
    && tar -xvf rq-v1.0.2-x86_64-unknown-linux-musl.tar.gz \
    && upx --brute rq

FROM alpine:latest

COPY --from=rq-build /root/rq /usr/local/bin

ENV HOME_DIR=/opt/crontab
RUN apk add --no-cache --virtual .run-deps gettext jq bash tini curl knot-utils bind-tools tzdata \
    && mkdir -p ${HOME_DIR} \
    && adduser -D -h ${HOME_DIR} appuser \
    && chown -R appuser:appuser ${HOME_DIR} \
    && cp -r -f /usr/share/zoneinfo/${TZ} /etc/localtime


COPY docker-entrypoint /
ENTRYPOINT ["/sbin/tini", "--", "/docker-entrypoint"]

HEALTHCHECK --interval=5s --timeout=3s \
    CMD ps aux | grep '[c]rond' || exit 1

CMD ["crond", "-f", "-d", "6", "-c", "/etc/crontabs"]