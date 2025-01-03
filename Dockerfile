#####
#
# Building OCI compatible container using buildkit
# ================================================
#
# Start buildkitd in podman, see https://github.com/moby/buildkit/blob/master/README.md#podman
#
# Install buildctl from https://github.com/moby/buildkit/releases
#
# ```bash
# if [ "true" != "$(podman inspect buildkitd 2>>/dev/null | jq '.[].State.Running' 2>>/dev/null)" ]; then
#   podman run --rm --name buildkitd -d --privileged docker.io/moby/buildkit
# fi
# buildctl --addr=podman-container://buildkitd build --frontend dockerfile.v0  --local context=. --local dockerfile=. --output type=oci,name=localhost/tds | podman load
# ```
#
#
# Run the container
# =================
#
# If you'd like to have OpenTelemetry(OTEL) enabled, either set up your own stack, or create an account with for example https://uptrace.dev
#
# ```bash
# echo "OTEL_EXPORTER_OTLP_HEADERS=uptrace-dsn=https://YOUR_OWN_KEY@api.uptrace.dev?grpc=4317\nOTEL_JAVAAGENT_ENABLED=true" > otel.env
# ```
#
# Run the container
#
# ```bash
# touch otel.env
# podman run --env-file=otel.env --sysctl net.ipv6.conf.all.disable_ipv6=1 -p 8080:8080 localhost/tds:latest
# ```
#
#####
ARG UBUNTU_VERSION=24.04         # LTS release from https://releases.ubuntu.com/
ARG JAVA_VERSION=17              # https://docs.unidata.ucar.edu/tds/current/userguide/install_java_tomcat.html
ARG TOMCAT_VERSION=10.1.34       # https://tomcat.apache.org/download-10.cgi
ARG TOMCAT_NATIVE_VERSION=2.0.8  # https://tomcat.apache.org/download-native.cgi
ARG OTEL_AGENT_VERSION=2.11.0    # https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases

FROM docker.io/ubuntu:${UBUNTU_VERSION} AS common_base
ARG DEBIAN_FRONTEND=noninteractive
ARG JAVA_VERSION
RUN --mount=type=cache,sharing=private,target=/var/lib/apt/lists \
    apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get -yqq install --no-install-recommends \
      curl \
      dumb-init \
      fontconfig \
      fontconfig \
      fonts-dejavu \
      libapr1 \
      libnetcdf19 \
      libssl3 \
      netcdf-bin \
      openjdk-${JAVA_VERSION}-jre-headless \
      openssl \
      tzdata \
    && apt-get clean && \
    ln -sf /usr/share/zoneinfo/Etc/UTC /etc/localtime && \
    ln -sf /usr/bin/bash /bin/sh   # For bash substring manipulation

FROM common_base AS build_tds
ARG DEBIAN_FRONTEND=noninteractive
ARG JAVA_VERSION
WORKDIR /src
RUN --mount=type=cache,sharing=private,target=/var/lib/apt/lists \
    --mount=type=cache,target=/src/.gradle \
    apt-get update && \
    apt-get -yqq install --no-install-recommends \
      libnetcdf-dev \
      openjdk-${JAVA_VERSION}-jdk-headless \
      unzip \
    && apt-get clean
COPY build.gradle .
RUN eval $(cat build.gradle | grep gradleVersion | sed -e 's/ //g' | awk '{print "export " $0}') && curl -qsS -o /tmp/gradle.zip -L https://services.gradle.org/distributions/gradle-${gradleVersion}-bin.zip
RUN mkdir /opt/gradle && unzip -d /opt/gradle /tmp/gradle.zip
RUN ln -s /opt/gradle/* /opt/gradle/current
COPY . .
RUN cp -a /src/.docker/thredds/. /
RUN /opt/gradle/current/bin/gradle assemble --no-daemon --build-cache
RUN mkdir -p /usr/local/tomcat/webapps/thredds
RUN unzip -d /usr/local/tomcat/webapps/thredds ./build/downloads/thredds*.war
RUN mkdir -p /usr/local/tomcat/content
RUN chmod 777 /usr/local/tomcat/content

FROM common_base AS build_tcnative
ARG JAVA_VERSION
ARG TOMCAT_NATIVE_VERSION
ENV CATALINA_HOME=/usr/local/tomcat
ENV JAVA_HOME=/usr/lib/jvm/java-${JAVA_VERSION}-openjdk-amd64
RUN --mount=type=cache,sharing=private,target=/var/lib/apt/lists \
    apt-get update && \
    apt-get -yqq install --no-install-recommends \
      build-essential \
      gnupg \
      libapr1-dev \
      libssl-dev \
      openjdk-${JAVA_VERSION}-jdk-headless \
    && apt-get clean
WORKDIR /src
COPY .docker/tomcat/usr/share/tomcat/tomcat-connectors.keys ./
RUN gpg --import < ./tomcat-connectors.keys
RUN export TGZ_URL="https://dlcdn.apache.org/tomcat/tomcat-connectors/native/${TOMCAT_NATIVE_VERSION}/source/tomcat-native-${TOMCAT_NATIVE_VERSION}-src.tar.gz" && \
    curl -qsfSL "$TGZ_URL" -o tomcat.tar.gz && \
    curl -qsfSL "$TGZ_URL.asc" -o tomcat.tar.gz.asc && \
    gpg --verify tomcat.tar.gz.asc && \
    tar -xvf tomcat.tar.gz --strip-components=1
RUN mkdir -p "${CATALINA_HOME}"
RUN cd native && ./configure --with-java-home=$JAVA_HOME --prefix=$CATALINA_HOME && make && make install

FROM common_base AS tomcat
ARG DEBIAN_FRONTEND=noninteractive
ARG TOMCAT_VERSION
ENV CATALINA_OPTS="--add-exports java.base/jdk.internal.ref=ALL-UNNAMED --add-exports java.base/sun.nio.ch=ALL-UNNAMED --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED --add-exports jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED --add-opens jdk.compiler/com.sun.tools.javac=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.reflect=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED"
ENV JAVA_OPTS="-server -Djava.awt.headless=true -Djava.util.prefs.systemRoot=/usr/local/tomcat/.java -Djava.util.prefs.userRoot=/usr/local/tomcat/.java/.userPrefs -XX:+HeapDumpOnOutOfMemoryError"
ENV CATALINA_HOME=/usr/local/tomcat
ENV PATH=/usr/local/tomcat/bin:$PATH
ENV LD_LIBRARY_PATH=$CATALINA_HOME/lib
COPY .docker/tomcat/. /
RUN --mount=type=cache,sharing=private,target=/var/lib/apt/lists \
    apt-get update && \
    apt-get -yqq install --no-install-recommends \
      gnupg \
    && apt-get clean && \
    mkdir -p "/usr/local/tomcat" && \
    cd /usr/local/tomcat && \
    gpg --import < /usr/share/tomcat/${TOMCAT_VERSION//.*}.keys && \
    set -x && \
    export TOMCAT_TGZ_URL="https://www.apache.org/dist/tomcat/tomcat-${TOMCAT_VERSION//.*}/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz" && \
    curl -qsfSL "$TOMCAT_TGZ_URL" -o tomcat.tar.gz && \
    curl -qsfSL "$TOMCAT_TGZ_URL.asc" -o tomcat.tar.gz.asc && \
    gpg --verify tomcat.tar.gz.asc && \
    tar -xvf tomcat.tar.gz --strip-components=1 && \
    rm bin/*.bat && \
    rm tomcat.tar.gz* && \
    mkdir -p conf/Catalina/localhost && \
    apt-get -yqq remove \
      gnupg \
    && \
    mkdir -p /usr/local/tomcat/.java/.systemPrefs && \
    mkdir /usr/local/tomcat/.java/.userPrefs && \
    chown -R root:root /usr/local/tomcat && \
    chmod go-w -R /usr/local/tomcat && \
    chmod a+rX -R /usr/local/tomcat && \
    for SUBDIR in logs work temp; do mkdir -p /usr/local/tomcat/${SUBDIR} && chmod a+rwX -R /usr/local/tomcat/${SUBDIR}; done && \
    rm -rf /usr/local/tomcat/webapps/* && \
    cp -a /usr/share/tomcat/* /usr/local/tomcat/
COPY --from=build_tcnative ${CATALINA_HOME}/lib/. ${CATALINA_HOME}/lib/
WORKDIR /usr/local/tomcat
USER 65534:65534
EXPOSE 8080/tcp
EXPOSE 8443/tcp
CMD ["/usr/bin/dumb-init", "--", "/usr/local/tomcat/bin/catalina.sh", "run"]

FROM tomcat AS tomcat_with_otel
ARG OTEL_AGENT_VERSION
ENV CATALINA_OPTS="${CATALINA_OPTS} -javaagent:/usr/local/share/java/opentelemetry-javaagent.jar"
ENV OTEL_RESOURCE_ATTRIBUTES=service.name=tomcat,service.version=${TOMCAT_VERSION}
ENV OTEL_TRACES_EXPORTER=otlp
ENV OTEL_METRICS_EXPORTER=otlp
ENV OTEL_LOGS_EXPORTER=otlp
ENV OTEL_EXPORTER_OTLP_COMPRESSION=gzip
ENV OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=DELTA
ENV OTEL_EXPORTER_OTLP_METRICS_DEFAULT_HISTOGRAM_AGGREGATION=BASE2_EXPONENTIAL_BUCKET_HISTOGRAM
# Using grpc on port 4317 as grpc is more efficient than http/protobuf
ENV OTEL_EXPORTER_OTLP_PROTOCOL=grpc
ENV OTEL_EXPORTER_OTLP_ENDPOINT=https://otlp.uptrace.dev:4317
# NOTE: Override OTEL_EXPORTER_OTLP_HEADERS for your instance
ENV OTEL_EXPORTER_OTLP_HEADERS="uptrace-dsn=https://REPLACE_ME@api.uptrace.dev?grpc=4317"
# Avoid trying to send OpenTelemetry (OTEL) without proper configuration
ENV OTEL_JAVAAGENT_ENABLED=false
USER 0:0
RUN export OTEL_AGENT_URL="https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v${OTEL_AGENT_VERSION}/opentelemetry-javaagent.jar" && \
    mkdir -p /usr/local/share/java && \
    curl -o /usr/local/share/java/opentelemetry-javaagent.jar -qsSL "${OTEL_AGENT_URL}"
USER 65534:65534

FROM tomcat_with_otel AS tds
ENV JAVA_OPTS="${JAVA_OPTS} -Dtds.content.root.path=/usr/local/tomcat/content"
COPY --from=build_tds /usr/local/tomcat/. /usr/local/tomcat/
