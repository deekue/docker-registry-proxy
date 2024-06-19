FROM alpine:3.20.0 as base

# If set to 1, enables building debug version of nginx, which is super-useful, but also heavy to build.
ARG DEBUG_IMAGE="0"

# apk upgrade in a separate layer (musl is huge)
RUN apk upgrade --no-cache --update

# apk packages required for both build and runtime
RUN apk add --no-cache --update \
      bash \
      ca-certificates-bundle \
      coreutils \
      curl \
      libssl3 \
      openssl \
      pcre \
      tzdata \
      zlib 

# apk packages required for both debug build and debug runtime
RUN if [[ "a$DEBUG_IMAGE" == "a1" ]] ; then echo "Debug build ENABLED." \
 && apk add --no-cache --update \
      libffi \
      libstdc++ \
      py3-certifi \
      py3-idna \
      py3-six \
      python3 \
    ; else echo "Debug build disabled." ; fi

# add path for pip installed binaries (debug build)
ENV PATH="/opt/venv/bin:$PATH"

################################################################################
FROM base as build

# If set to 1, enables building debug version of nginx, which is super-useful, but also heavy to build.
ARG DEBUG_IMAGE="0"

# nginx 1.25.5 is the latest version supported by connect module
ENV NGINX_VERSION=1.25.5
ENV PROXY_CONNECT_MODULE_PATCH=proxy_connect_rewrite_102101.patch
ENV PROXY_CONNECT_MODULE_PATH="/usr/src/ngx_http_proxy_connect_module"
ENV pkgdir=/build/nginx
ENV MITMWEB_VERSION=10.3.1

# apk packages required for build
RUN apk add --no-cache --update \
      gcc \
      git \
      libc-dev \
      linux-headers \
      make \
      openssl-dev \
      patch \
      pcre-dev \
      zlib-dev

# apk packages required for debug build
RUN if [[ "a$DEBUG_IMAGE" == "a1" ]] ; then \
      echo "Debug build ENABLED." ; \
      apk add --no-cache --update \
        bsd-compat-headers \
        cargo \
        g++ \
        libffi-dev \
        openssl-dev \
        py3-pip \
        py3-setuptools \
        py3-wheel \
        python3-dev \
        su-exec \
      ; else echo "Debug build disabled." ; fi

WORKDIR /usr/src

# nginx layer
ENV CONFIG="\
		--prefix=/etc/nginx \
		--sbin-path=/usr/sbin/nginx \
		--modules-path=/usr/lib/nginx/modules \
		--conf-path=/etc/nginx/nginx.conf \
		--error-log-path=/var/log/nginx/error.log \
		--http-log-path=/var/log/nginx/access.log \
		--pid-path=/var/run/nginx.pid \
		--lock-path=/var/run/nginx.lock \
		--http-client-body-temp-path=/var/cache/nginx/client_temp \
		--http-proxy-temp-path=/var/cache/nginx/proxy_temp \
		--http-fastcgi-temp-path=/var/cache/nginx/fastcgi_temp \
		--http-uwsgi-temp-path=/var/cache/nginx/uwsgi_temp \
		--http-scgi-temp-path=/var/cache/nginx/scgi_temp \
		--user=nginx \
		--group=nginx \
		--with-http_ssl_module \
		--with-http_realip_module \
		--with-http_addition_module \
		--with-http_sub_module \
		--with-http_gunzip_module \
		--with-http_gzip_static_module \
		--with-http_random_index_module \
		--with-http_secure_link_module \
		--with-http_stub_status_module \
		--with-http_auth_request_module \
		--with-threads \
		--with-stream \
		--with-stream_ssl_module \
		--with-stream_ssl_preread_module \
		--with-stream_realip_module \
		--with-http_slice_module \
		--with-compat \
		--with-file-aio \
		--with-http_v2_module \
		--add-module=$PROXY_CONNECT_MODULE_PATH \
	" 

RUN mkdir -p "$pkgdir"/etc/nginx/conf.d/ "$pkgdir"/usr/share/nginx/html/ "$pkgdir"/usr/lib/nginx/modules \
 && curl -fSL https://nginx.org/download/nginx-$NGINX_VERSION.tar.gz -o nginx.tar.gz \
 && git clone --depth=1 https://github.com/chobits/ngx_http_proxy_connect_module.git "$PROXY_CONNECT_MODULE_PATH" \
 && tar -zxC /usr/src -f nginx.tar.gz \
 && cd /usr/src/nginx-$NGINX_VERSION \
 && patch -p1 < "$PROXY_CONNECT_MODULE_PATH/patch/$PROXY_CONNECT_MODULE_PATCH" \
 && { echo "Building RELEASE" && ./configure $CONFIG  && make -j$(getconf _NPROCESSORS_ONLN) && make DESTDIR="$pkgdir" install; } \
 && rm -rf "$pkgdir"/etc/nginx/html/ "$pkgdir"/var/run \
 && install -m644 html/index.html "$pkgdir"/usr/share/nginx/html/ \
 && install -m644 html/50x.html "$pkgdir"/usr/share/nginx/html/ \
 && strip "$pkgdir"/usr/sbin/nginx*

RUN if [ "a$DEBUG_IMAGE" == "a1" ] ; then \
    echo "Building DEBUG" \
 && cd /usr/src/nginx-$NGINX_VERSION \
 && ./configure $CONFIG --with-debug \
 && make -j$(getconf _NPROCESSORS_ONLN) \
 && install -m755 objs/nginx "$pkgdir"/usr/sbin/nginx-debug \
  ; else echo "Not building debug" ; fi

# Build mitmproxy via pip. This is heavy, takes minutes do build and creates a 90mb+ layer. Oh well.
WORKDIR /opt/venv
RUN if [[ "a$DEBUG_IMAGE" == "a1" ]] ; then \
    echo "Debug build ENABLED." \
 && python3 -m venv /opt/venv \
 && /opt/venv/bin/pip --disable-pip-version-check install --use-pep517 --prefer-binary --no-cache-dir mitmproxy==$MITMWEB_VERSION \
 && mitmproxy --version \
 && mitmweb --version \
  ; else echo "Debug build disabled." ; fi

################################################################################
FROM base as registry-proxy

# If set to 1, enables mitmproxy, which helps a lot in debugging, but is super heavy to build.
ARG DEBUG_IMAGE

# Link image to original repository on GitHub
LABEL org.opencontainers.image.source https://github.com/rpardini/docker-registry-proxy

# copy nginx from build layer
COPY --from=build /build/nginx /
# copy mitmweb from build layer
COPY --from=build /opt/venv /opt/venv

# Create the cache directory and CA directory
RUN mkdir -p /docker_mirror_cache /ca \
 && addgroup -S nginx \
 && adduser -D -S -h /var/cache/nginx -s /sbin/nologin -G nginx nginx \
  \
 # forward request and error logs to docker log collector
 && ln -sf /dev/stdout /var/log/nginx/access.log \
 && ln -sf /dev/stderr /var/log/nginx/error.log \
 && ln -s /usr/lib/nginx/modules /etc/nginx/modules

# Add our configuration
COPY nginx.conf nginx.manifest.common.conf nginx.manifest.stale.conf /etc/nginx/

# Add our very hackish entrypoint and ca-building scripts
# Add Liveliness Probe script for CoreWeave
COPY entrypoint.sh create_ca_cert.sh liveliness.sh /

# Expose it as a volume, so cache can be kept external to the Docker image
VOLUME /docker_mirror_cache

# Expose /ca as a volume. Users are supposed to volume mount this, as to preserve it across restarts.
# Actually, its required; if not, then docker clients will reject the CA certificate when the proxy is run the second time
VOLUME /ca

# Clients should only use 3128, not anything else.
EXPOSE 3128

# In debug mode, 8081 exposes the mitmweb interface (for incoming requests from Docker clients)
EXPOSE 8081
# In debug-hub mode, 8082 exposes the mitmweb interface (for outgoing requests to DockerHub)
EXPOSE 8082

# Required for mitmproxy
ENV LANG=en_US.UTF-8

## Default envs.
# A space delimited list of registries we should proxy and cache; this is in addition to the central DockerHub.
ENV REGISTRIES="k8s.gcr.io gcr.io quay.io"
# List of registries requiring a special TCP port
ENV REGISTRIES_CUSTOM_PORT="registry-1.docker.io:443"
# A space delimited list of registry:user:password to inject authentication for
ENV AUTH_REGISTRIES="some.authenticated.registry:oneuser:onepassword another.registry:user:password"
# Should we verify upstream's certificates? Default to true.
ENV VERIFY_SSL="true"
# Enable debugging mode; this inserts mitmproxy/mitmweb between the CONNECT proxy and the caching layer
ENV DEBUG="false"
# Enable debugging mode; this inserts mitmproxy/mitmweb between the caching layer and DockerHub's registry
ENV DEBUG_HUB="false"
# Enable nginx debugging mode; this uses nginx-debug binary and enabled debug logging, which is VERY verbose so separate setting
ENV DEBUG_NGINX="false"
# Enable slow caching tier; this allows caching in a secondary cache path on e.g a larger slower disk; for known URIs defined in SLOW_TIER_URIS
ENV SLOW_TIER_ENABLED="false"
# Statically define worker_processes; defaults to auto
ENV WORKER_PROCESSES="auto"

# Manifest caching tiers. Disabled by default, to mimick 0.4/0.5 behaviour.
# Setting it to true enables the processing of the ENVs below.
# Once enabled, it is valid for all registries, not only DockerHub.
# The envs *_REGEX represent a regex fragment, check entrypoint.sh to understand how they're used (nginx ~ location, PCRE syntax).
ENV ENABLE_MANIFEST_CACHE="false"

# 'Primary' tier defaults to 10m cache for frequently used/abused tags.
# - People publishing to production via :latest (argh) will want to include that in the regex
# - Heavy pullers who are being ratelimited but don't mind getting outdated manifests should (also) increase the cache time here
ENV MANIFEST_CACHE_PRIMARY_REGEX="(stable|nightly|production|test)"
ENV MANIFEST_CACHE_PRIMARY_TIME="10m"

# 'Secondary' tier defaults any tag that has 3 digits or dots, in the hopes of matching most explicitly-versioned tags.
# It caches for 60d, which is also the cache time for the large binary blobs to which the manifests refer.
# That makes them effectively immutable. Make sure you're not affected; tighten this regex or widen the primary tier.
ENV MANIFEST_CACHE_SECONDARY_REGEX="(.*)(\d|\.)+(.*)(\d|\.)+(.*)(\d|\.)+"
ENV MANIFEST_CACHE_SECONDARY_TIME="60d"

# The default cache duration for manifests that don't match either the primary or secondary tiers above.
# In the default config, :latest and other frequently-used tags will get this value.
ENV MANIFEST_CACHE_DEFAULT_TIME="1h"

# This lists the registries hosts for which manifests caching is disabled
ENV MANIFEST_CACHE_EXCLUDE_HOSTS="privat.registry.io"

# Should we allow actions different than pull, default to false.
ENV ALLOW_PUSH="false"

# If push is allowed, buffering requests can cause issues on slow upstreams.
# If you have trouble pushing, set this to false first, then fix remainig timouts.
# Default is true to not change default behavior.
ENV PROXY_REQUEST_BUFFERING="true"

# Force HTTP/1.1 upstream connections, for http2 upstream that returns 426 Upgrade Required
ENV FORCE_UPSTREAM_HTTP_1_1="false"

# Stream data; reduce TTFB
# Effectively disables caching
# Default is true to not change default behavior.
ENV PROXY_BUFFERING="true"

# Should we allow overridding with own authentication, default to false.
ENV ALLOW_OWN_AUTH="false"

# Should we allow push only with own authentication, default to false.
ENV ALLOW_PUSH_WITH_OWN_AUTH="false"


# Timeouts
# ngx_http_core_module
ENV SEND_TIMEOUT="60s"
ENV CLIENT_BODY_TIMEOUT="60s"
ENV CLIENT_HEADER_TIMEOUT="60s"
ENV KEEPALIVE_TIMEOUT="300s"
# ngx_http_proxy_module
ENV PROXY_READ_TIMEOUT="60s"
ENV PROXY_CONNECT_TIMEOUT="60s"
ENV PROXY_SEND_TIMEOUT="60s"
# ngx_http_proxy_connect_module - external module
ENV PROXY_CONNECT_READ_TIMEOUT="60s"
ENV PROXY_CONNECT_CONNECT_TIMEOUT="60s"
ENV PROXY_CONNECT_SEND_TIMEOUT="60s"

# Did you want a shell? Sorry, the entrypoint never returns, because it runs nginx itself. Use 'docker exec' if you need to mess around internally.
ENTRYPOINT ["/entrypoint.sh"]
