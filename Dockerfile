ARG ALPINE_VERSION=3.17.3

FROM ubuntu:22.04 as build
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update
RUN apt-get dist-upgrade -y
RUN apt-get -yq install openjdk-11-jdk-headless unzip
RUN mkdir /dst
COPY . /src
WORKDIR /src
RUN cp -a /src/files/. /dst/
RUN ./gradlew assemble
RUN mv ./build/downloads/thredds*.war thredds.war
RUN mkdir -p /dst/usr/local/tomcat/webapps/thredds
RUN unzip -d /dst/usr/local/tomcat/webapps/thredds thredds.war

FROM alpine:${ALPINE_VERSION}
ARG TIMEZONE=UTC
ARG TOMCAT_MAJOR=9
ARG TOMCAT_VERSION=9.0.74
ENV CATALINA_OPTS="-XX:InitialRAMPercentage=90.0 -XX:MaxRAMPercentage=90.0" \
    JAVA_OPTS="-server -Djava.awt.headless=true -Djava.util.prefs.systemRoot=/usr/local/tomcat/.java -Djava.util.prefs.userRoot=/usr/local/tomcat/.java/.userPrefs -Dtds.content.root.path=${CATALINA_HOME}/content" \
    CATALINA_HOME=/usr/local/tomcat \
    PATH=/usr/local/tomcat/bin:$PATH
COPY --from=build /dst/. /
RUN apk update && \
    apk upgrade && \
    apk add \
      curl \
      gnupg \
      dumb-init \
      fontconfig \
      openjdk11-jre \
      openssl \
      tomcat-native \
      ttf-dejavu \
      tzdata \
    && \
    cp /usr/share/zoneinfo/${TIMEZONE} /etc/localtime && \
    echo "${TIMEZONE}" > /etc/timezone && \
    mkdir -p "$CATALINA_HOME" && cd $CATALINA_HOME && gpg --import < /usr/share/tomcat/9.keys && \
    set -x && \
    export TOMCAT_TGZ_URL="https://www.apache.org/dist/tomcat/tomcat-$TOMCAT_MAJOR/v$TOMCAT_VERSION/bin/apache-tomcat-$TOMCAT_VERSION.tar.gz" && \
    curl -fSL "$TOMCAT_TGZ_URL" -o tomcat.tar.gz && \
    curl -fSL "$TOMCAT_TGZ_URL.asc" -o tomcat.tar.gz.asc && \
    gpg --verify tomcat.tar.gz.asc && \
    tar -xvf tomcat.tar.gz --strip-components=1 && \
    rm bin/*.bat && \
    rm tomcat.tar.gz* && \
    mkdir -p conf/Catalina/localhost && \
    apk del \
      gnupg \
    && \
    mkdir -p ${CATALINA_HOME}/.java/.systemPrefs && \
    mkdir ${CATALINA_HOME}/.java/.userPrefs && \
    chown -R root:root ${CATALINA_HOME} && \
    chmod go-w -R ${CATALINA_HOME} && \
    chmod a+rX -R ${CATALINA_HOME} && \
    for SUBDIR in logs work temp; do mkdir -p ${CATALINA_HOME}/${SUBDIR} && chmod a+rwX -R ${CATALINA_HOME}/${SUBDIR}; done && \
    rm -rf ${CATALINA_HOME}/webapps/* && \
    cp -a /usr/share/tomcat/* /usr/local/tomcat/ && \
    rm -rf /var/cache/apk/*
WORKDIR ${CATALINA_HOME}
USER 65534:65534
EXPOSE 8080 8443
CMD ["/usr/bin/dumb-init", "--", "/usr/local/tomcat/bin/catalina.sh", "run"]
