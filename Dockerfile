ARG UBUNTU_VERSION=24.04
ARG JAVA_VERSION=17
ARG TOMCAT_VERSION=10.1.34

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
      libnetcdf-dev \
      libtcnative-1 \
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
RUN --mount=type=cache,sharing=private,target=/var/lib/apt/lists \
    apt-get update && \
    apt-get -yqq install --no-install-recommends \
      openjdk-${JAVA_VERSION}-jdk-headless \
      unzip \
    && apt-get clean
COPY build.gradle .
RUN eval $(cat build.gradle | grep gradleVersion | sed -e 's/ //g' | awk '{print "export " $0}') && curl -qsS -o /tmp/gradle.zip -L https://services.gradle.org/distributions/gradle-${gradleVersion}-bin.zip
RUN mkdir /opt/gradle && unzip -d /opt/gradle /tmp/gradle.zip
RUN ln -s /opt/gradle/* /opt/gradle/current
COPY . /src
WORKDIR /src
RUN cp -a /src/.docker/thredds/. /
RUN /opt/gradle/current/bin/gradle assemble --no-daemon
RUN mkdir -p /usr/local/tomcat/webapps/thredds
RUN unzip -d /usr/local/tomcat/webapps/thredds ./build/downloads/thredds*.war
RUN mkdir -p /usr/local/tomcat/content
RUN chmod 777 /usr/local/tomcat/content

FROM common_base AS tomcat
ARG DEBIAN_FRONTEND=noninteractive
ARG TOMCAT_VERSION
ENV CATALINA_OPTS="--add-exports java.base/jdk.internal.ref=ALL-UNNAMED --add-exports java.base/sun.nio.ch=ALL-UNNAMED --add-exports jdk.unsupported/sun.misc=ALL-UNNAMED --add-exports jdk.compiler/com.sun.tools.javac.file=ALL-UNNAMED --add-opens jdk.compiler/com.sun.tools.javac=ALL-UNNAMED --add-opens java.base/java.lang=ALL-UNNAMED --add-opens java.base/java.lang.reflect=ALL-UNNAMED --add-opens java.base/java.io=ALL-UNNAMED --add-opens java.base/java.util=ALL-UNNAMED" \
    JAVA_OPTS="-server -Djava.awt.headless=true -Djava.util.prefs.systemRoot=/usr/local/tomcat/.java -Djava.util.prefs.userRoot=/usr/local/tomcat/.java/.userPrefs -XX:+HeapDumpOnOutOfMemoryError" \
    CATALINA_HOME=/usr/local/tomcat \
    PATH=/usr/local/tomcat/bin:$PATH
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
WORKDIR /usr/local/tomcat
USER 65534:65534
EXPOSE 8080/tcp
EXPOSE 8443/tcp
CMD ["/usr/bin/dumb-init", "--", "/usr/local/tomcat/bin/catalina.sh", "run"]

FROM tomcat AS tds
ENV JAVA_OPTS="${JAVA_OPTS} -Dtds.content.root.path=/usr/local/tomcat/content"
COPY --from=build_tds /usr/local/tomcat/. /usr/local/tomcat/
