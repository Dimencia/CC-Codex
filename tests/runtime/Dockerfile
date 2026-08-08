FROM eclipse-temurin:21-jre-jammy

ARG NEOFORGE_VERSION=21.1.234
ARG CC_TWEAKED_VERSION=1.120.0

ENV NEOFORGE_VERSION=${NEOFORGE_VERSION}
ENV CC_TWEAKED_VERSION=${CC_TWEAKED_VERSION}

WORKDIR /server

RUN apt-get update \
    && apt-get install --no-install-recommends -y ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl --fail --location --retry 3 --retry-all-errors \
        "https://maven.neoforged.net/releases/net/neoforged/neoforge/${NEOFORGE_VERSION}/neoforge-${NEOFORGE_VERSION}-installer.jar" \
        --output /tmp/neoforge-installer.jar \
    && java -jar /tmp/neoforge-installer.jar --installServer /server \
    && rm -f /tmp/neoforge-installer.jar \
    && mkdir -p /server/mods

RUN curl --fail --location --retry 3 --retry-all-errors \
        "https://maven.squiddev.cc/cc/tweaked/cc-tweaked-1.21.1-forge/${CC_TWEAKED_VERSION}/cc-tweaked-1.21.1-forge-${CC_TWEAKED_VERSION}.jar" \
        --output "/server/mods/cc-tweaked-1.21.1-forge-${CC_TWEAKED_VERSION}.jar"

COPY fixture/eula.txt /server/eula.txt
COPY fixture/server.properties /server/server.properties
COPY fixture/user_jvm_args.txt /server/user_jvm_args.txt
COPY fixture/world /server/world
COPY run.sh /usr/local/bin/cc-codex-runtime-test

RUN chmod +x /usr/local/bin/cc-codex-runtime-test

ENTRYPOINT ["/usr/local/bin/cc-codex-runtime-test"]
