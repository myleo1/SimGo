# ---- Build stage: compile chan-quectel ----
FROM ubuntu:24.04 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    ca-certificates \
    git \
    autoconf \
    automake \
    libtool \
    pkg-config \
    asterisk-dev \
    libsqlite3-dev \
    libasound2-dev \
    && rm -rf /var/lib/apt/lists/*

RUN git clone --depth 1 https://github.com/myleo1/asterisk-chan-quectel-lts.git /tmp/chan-quectel

WORKDIR /tmp/chan-quectel

RUN ./bootstrap

RUN MODULE_DIR="/usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/asterisk/modules" \
    && ASTERISK_VER=$(dpkg-query -W -f='${Version}' asterisk-dev | sed 's/.*://' | sed 's/~.*//') \
    && ./configure DESTDIR=${MODULE_DIR} --with-astversion=${ASTERISK_VER} \
    && make \
    && mkdir -p ${MODULE_DIR} \
    && make install \
    && cp ${MODULE_DIR}/chan_quectel.so /tmp/chan_quectel.so

# ---- Runtime stage ----
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    asterisk \
    asterisk-dev \
    ca-certificates \
    libasound2t64 \
    libsqlite3-0 \
    python3 \
    python3-requests \
    python3-socks \
    && rm -rf /var/lib/apt/lists/*

# Copy compiled chan-quectel module to correct arch path
COPY --from=builder /tmp/chan_quectel.so /tmp/chan_quectel.so
RUN cp /tmp/chan_quectel.so /usr/lib/$(dpkg-architecture -qDEB_HOST_MULTIARCH)/asterisk/modules/chan_quectel.so

# Asterisk directories
RUN mkdir -p /etc/asterisk/templates /etc/asterisk/scripts /etc/asterisk/certs \
    /var/log/asterisk /var/lib/asterisk/smsdb

# Timezone
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

EXPOSE 52060/tcp 42077-42126/udp

COPY start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/start.sh"]
