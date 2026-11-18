# Статические сборки jq/curl/xz для COPY в контейнерные образы ElasticSearch.
#
# Собираются статически (musl, Alpine), поэтому переносимы в ЛЮБОЙ целевой образ
# (в т.ч. ubuntu focal с glibc 2.31) без рантайм-зависимостей. Архитектура образа
# = архитектура билдера; мультиарх-манифест собирает workflow (нативные раннеры GH).
#
# Версии и sha256 зафиксированы в ARG ниже (одновременно и pin, и контроль
# целостности: build падает на несовпадении суммы). Порядок апгрейда: поменять
# пару версия+сумма, прогнать локально, опубликовать git-тег vX.Y.Z.
#
# Локальная проверка: docker build -t statickit-local . (архитектура хоста)

FROM alpine:3.22 AS build

ARG JQ_VERSION=1.8.2
ARG JQ_SHA256=71b8d6e8f5fe81f6c6d0d110e3892251f6ce76ed095abd315e26e6e1193af3af
ARG XZ_VERSION=5.8.4
ARG XZ_SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9
ARG CURL_VERSION=8.23.0
ARG CURL_SHA256=e3de77cfa6367083c776a26647fc9f633b538c06c3baa73d931a252ac8f72b49
ARG OPENSSL_VERSION=3.6.5
ARG OPENSSL_SHA256=a2157c2830efdec3788939b00c9b0638306d3f0bbb76dc4832ee503bb397df98

RUN apk add --no-cache \
        build-base linux-headers pkgconf autoconf automake libtool m4 \
        curl ca-certificates tar xz zlib-dev zlib-static

WORKDIR /src

# Скачивание с обязательной сверкой sha256: публичный mirror доверия не даёт.
RUN set -eu; \
    fetch() { curl -fsSL --retry 3 -o "$2" "$1"; echo "$3  $2" | sha256sum -c -; }; \
    fetch "https://github.com/jqlang/jq/releases/download/jq-${JQ_VERSION}/jq-${JQ_VERSION}.tar.gz" jq.tar.gz "$JQ_SHA256"; \
    fetch "https://github.com/tukaani-project/xz/releases/download/v${XZ_VERSION}/xz-${XZ_VERSION}.tar.gz" xz.tar.gz "$XZ_SHA256"; \
    fetch "https://github.com/curl/curl/releases/download/curl-$(echo "$CURL_VERSION" | tr . _)/curl-${CURL_VERSION}.tar.gz" curl.tar.gz "$CURL_SHA256"; \
    fetch "https://github.com/openssl/openssl/releases/download/openssl-${OPENSSL_VERSION}/openssl-${OPENSSL_VERSION}.tar.gz" openssl.tar.gz "$OPENSSL_SHA256"; \
    tar -xf jq.tar.gz; tar -xf xz.tar.gz; tar -xf curl.tar.gz; tar -xf openssl.tar.gz

# OpenSSL — статический бэкенд TLS для curl (no-shared: в бинарь curl войдёт всё нужное).
# --libdir=lib обязателен: linux-x86_64 по умолчанию ставит .a и pkgconfig в
# lib64 (на aarch64 — lib), и все пути ниже (/opt/ossl/lib, PKG_CONFIG_PATH)
# тогда не совпадают на двух арках (проверено: amd64 падал «cannot find -lssl»).
RUN set -eu; cd openssl-${OPENSSL_VERSION}; \
    ./Configure --prefix=/opt/ossl --openssldir=/etc/ssl --libdir=lib no-shared no-tests no-ui-console; \
    make -j"$(nproc)"; make install_sw

# LDFLAGS=-all-static: бинарь линкуется через libtool, а libtool съедает
# -static как собственный флаг и не передаёт его gcc (проверено: с -static
# выходит динамический бинарь). -all-static же libtool разворачивает в -static
# для компилятора — тот же приём, что в релизном build.sh jq.
RUN set -eu; cd xz-${XZ_VERSION}; \
    ./configure --disable-shared --enable-static --disable-xzdec --disable-lzmadec \
        --disable-lzma-links --disable-scripts --disable-doc; \
    make -j"$(nproc)" LDFLAGS=-all-static

RUN set -eu; cd jq-${JQ_VERSION}; \
    ./configure; \
    make -j"$(nproc)" LDFLAGS=-all-static

# Статика: curl линкует бинарь тоже через libtool (--mode=link для libcurl.la),
# поэтому -all-static вместо -static (libtool съедает -static). LDFLAGS в make
# перекрывает baked-значение — -L отдаём заново. На configure-этапе -L нужен для
# проб детекции openssl (пробы — прямой gcc, без libtool).
RUN set -eu; cd curl-${CURL_VERSION}; \
    export PKG_CONFIG_PATH=/opt/ossl/lib/pkgconfig; \
    ./configure --enable-static --disable-shared \
        --with-openssl --with-ca-path=/etc/ssl/certs --with-ca-bundle=/etc/ssl/certs/ca-certificates.crt \
        --without-libpsl --without-libidn2 --without-brotli --without-zstd \
        --without-nghttp2 --without-nghttp3 --without-ngtcp2 \
        LDFLAGS="-L/opt/ossl/lib" LIBS="-lssl -lcrypto -lz -lm -lpthread"; \
    make -j"$(nproc)" LDFLAGS="-all-static -L/opt/ossl/lib"

RUN set -eu; mkdir -p /tools; \
    cp xz-${XZ_VERSION}/src/xz/xz /tools/xz; \
    cp jq-${JQ_VERSION}/jq /tools/jq; \
    cp curl-${CURL_VERSION}/src/curl /tools/curl; \
    chmod 0755 /tools/*; \
    file /tools/*; \
    # Страховка: любой несобранно-статический бинарь должен уронить сборку,
    # иначе в целевой focal-образ попадёт неработающий файл.
    # (file печатает 'statically linked' либо 'static-pie linked' — допускаем оба.)
    if file /tools/* | grep -v 'static.*linked'; then echo 'ERROR: нестатический бинарь' >&2; exit 1; fi; \
    /tools/xz --version; /tools/jq --version; /tools/curl --version | head -1

FROM scratch
COPY --from=build /tools/ /tools/
# Тексты лицензий компонентов (jq/oniguruma MIT, curl, xz 0BSD, OpenSSL
# Apache-2.0) едут в образе: статическая линковка = распространение, а
# Apache-2.0 требует текст лицензии рядом с бинарём.
COPY LICENSES/ /tools/licenses/
LABEL org.opencontainers.image.title="statickit" \
      org.opencontainers.image.description="Static jq/curl/xz tool binaries for container images" \
      org.opencontainers.image.source="https://github.com/Wu-Wu/statickit"
