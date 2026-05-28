FROM ubuntu:26.04

LABEL maintainer="Vadim Belov <rust-docker-image@belov.us>"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Disable TTY interaction
ARG DEBIAN_FRONTEND=noninteractive

# Run as root by default
USER root

# Install and setup gosu
# More information at https://github.com/tianon/gosu/blob/master/INSTALL.md
ENV GOSU_VERSION 1.14
RUN set -eux; \
    # save list of currently installed packages for later so we can clean up
    savedAptMark="$(apt-mark showmanual)"; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates wget gnupg2 dirmngr; \
    if gpg --version | grep -q '^gpg (GnuPG) 1\.'; then \
    # "This package provides support for HKPS keyservers." (GnuPG 1.x only)
    apt-get install -y --no-install-recommends gnupg-curl; \
    fi; \
    rm -rf /var/lib/apt/lists/*; \
    \
    dpkgArch="$(dpkg --print-architecture | awk -F- '{ print $NF }')"; \
    wget -O /usr/local/bin/gosu "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch"; \
    wget -O /usr/local/bin/gosu.asc "https://github.com/tianon/gosu/releases/download/$GOSU_VERSION/gosu-$dpkgArch.asc"; \
    \
    # verify the signature
    export GNUPGHOME="$(mktemp -d)"; \
    gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys B42F6819007F00F88E364FD4036A9C25BF357DD4; \
    gpg --batch --verify /usr/local/bin/gosu.asc /usr/local/bin/gosu; \
    command -v gpgconf && gpgconf --kill all || :; \
    rm -rf "$GNUPGHOME" /usr/local/bin/gosu.asc; \
    \
    # clean up fetch dependencies
    apt-mark auto '.*' > /dev/null; \
    [ -z "$savedAptMark" ] || apt-mark manual $savedAptMark; \
    apt-get purge -y --auto-remove -o APT::AutoRemove::RecommendsImportant=false; \
    \
    chmod +x /usr/local/bin/gosu; \
    # verify that the binary works
    gosu --version; \
    gosu nobody true

# Update system packages, install core dependencies
# and generate default locales
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        locales \
        wget \
        curl \
        git \
        sudo \
        libarchive-tools; \
    sed -i 's/^#\s*en_US.UTF-8\s\+UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen; \
    locale-gen en_US.UTF-8; \
    update-locale LANG=en_US.UTF-8; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/*

# Create a default user and group (docker)
# (also sets permissions for the /app volume)
RUN set -eux; \
    if ! getent group docker > /dev/null; then \
        groupadd --system docker; \
    fi; \
    if ! id -u docker > /dev/null 2>&1; then \
        useradd \
            --create-home \
            --home-dir /app \
            --gid docker \
            --shell /bin/false \
            docker; \
    fi; \
    mkdir -p /app; \
    chown -R docker:docker /app

# Expose the /app volume
#VOLUME [ "/app" ]

# Set default environment variables
ENV LANGUAGE en_US.UTF-8
ENV LANG en_US.utf8
ENV TERM xterm
ENV TZ Etc/UTC
ENV PGID 1000
ENV PUID 1000
ENV CHOWN_DIRS "/app,/steamcmd,/usr/share/nginx/html,/var/log/nginx"
ENV ENABLE_PASSWORDLESS_SUDO "false"

# Include Readme and License with each image
COPY LICENSE.md /

# Add base image initialization script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Set the main entry point to our initialization script
ENTRYPOINT ["/entrypoint.sh"]

# Install dependencies which mainly fix issues with libcurl and steamcmd
RUN set -eux; \
    dpkg --add-architecture i386; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libstdc++6:i386 \
        libsdl2-2.0-0:i386; \
    if ! apt-get install -y --no-install-recommends lib32gcc-s1; then \
        apt-get install -y --no-install-recommends lib32gcc1; \
    fi; \
    if ! apt-get install -y --no-install-recommends libcurl4:i386; then \
        apt-get install -y --no-install-recommends libcurl4t64:i386; \
    fi; \
    ls -la /usr/lib/*/libcurl.so*; \
    ln -sf /usr/lib/i386-linux-gnu/libcurl.so.4 /usr/lib/i386-linux-gnu/libcurl.so; \
    ln -sf /usr/lib/i386-linux-gnu/libcurl.so.4 /usr/lib/i386-linux-gnu/libcurl.so.3; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/* /var/tmp/* /tmp/dumps /tmp/*

# Install steamcmd and verify that it is working
RUN mkdir -p /steamcmd && \
    curl -fsSL http://media.steampowered.com/installer/steamcmd_linux.tar.gz \
    | tar -v -C /steamcmd -zx && \
    chmod +x /steamcmd/steamcmd.sh && \
    /steamcmd/steamcmd.sh +login anonymous +quit

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        nginx \
        expect \
        tcl \
        libgdiplus \
        nodejs \
        npm; \
    node --version; \
    npm --version; \
    rm -rf /var/lib/apt/lists/*; \
    rm -fr /usr/share/nginx/html/* /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*

# Install webrcon (specific commit)
COPY nginx_rcon.conf /etc/nginx/nginx.conf
RUN curl -sL https://github.com/Facepunch/webrcon/archive/24b0898d86706723d52bb4db8559d90f7c9e069b.zip | bsdtar -xvf- -C /tmp && \
    mv /tmp/webrcon-24b0898d86706723d52bb4db8559d90f7c9e069b/* /usr/share/nginx/html/ && \
    rm -fr /tmp/webrcon-24b0898d86706723d52bb4db8559d90f7c9e069b

# Customize the webrcon package to fit our needs
COPY fix_conn.sh /tmp/fix_conn.sh

# Create the volume directories
RUN mkdir -p /steamcmd/rust /usr/share/nginx/html /var/log/nginx

# Setup proper shutdown support
COPY shutdown_app/ /app/shutdown_app/
COPY restart_app/ /app/restart_app/
COPY scheduler_app/ /app/scheduler_app/
COPY heartbeat_app/ /app/heartbeat_app/
COPY rcon_app/ /app/rcon_app/
RUN set -eux; \
    npm config set registry https://registry.npmjs.org/; \
    for app_dir in shutdown_app restart_app scheduler_app heartbeat_app rcon_app; do \
        cd "/app/${app_dir}"; \
        npm install --omit=dev; \
    done; \
    ln -s /app/rcon_app/app.js /usr/bin/rcon

# Add the steamcmd installation script
COPY install.txt /app/install.txt

# Copy the Rust startup script
COPY start_rust.sh /app/start.sh

# Copy the Rust update check script
COPY update_check.sh /app/update_check.sh

# Copy extra files
COPY LICENSE.md /app/

# Set the current working directory
WORKDIR /

# Fix permissions
RUN chown -R 1000:1000 \
    /steamcmd \
    /app \
    /usr/share/nginx/html \
    /var/log/nginx

# Expose necessary ports
EXPOSE 8080
EXPOSE 28015
EXPOSE 28016
EXPOSE 28082

# Setup default environment variables for the server
ENV RUST_SERVER_STARTUP_ARGUMENTS "-batchmode -load -nographics +server.secure 1"
ENV RUST_SERVER_IDENTITY "docker"
ENV RUST_SERVER_PORT ""
ENV RUST_SERVER_QUERYPORT ""
ENV RUST_SERVER_SEED "12345"
ENV RUST_SERVER_NAME "Rust Server [DOCKER]"
ENV RUST_SERVER_DESCRIPTION "This is a Rust server running inside a Docker container!"
ENV RUST_SERVER_URL "https://hub.docker.com/r/bvdcode/rust-server/"
ENV RUST_SERVER_BANNER_URL ""
ENV RUST_RCON_WEB "1"
ENV RUST_RCON_PORT "28016"
ENV RUST_RCON_PASSWORD "docker"
ENV RUST_APP_PORT "28082"
ENV RUST_UPDATE_CHECKING "0"
ENV RUST_HEARTBEAT "0"
ENV RUST_UPDATE_BRANCH "public"
ENV RUST_START_MODE "0"
ENV RUST_OXIDE_ENABLED "0"
ENV RUST_OXIDE_UPDATE_ON_BOOT "1"
ENV RUST_RCON_SECURE_WEBSOCKET "0"
ENV RUST_SERVER_WORLDSIZE "3500"
ENV RUST_SERVER_MAXPLAYERS "500"
ENV RUST_SERVER_SAVE_INTERVAL "600"

# Expose the volumes
# VOLUME [ "/steamcmd/rust" ]

# Start the server
CMD [ "bash", "/app/start.sh"]