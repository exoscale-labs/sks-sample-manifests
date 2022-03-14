FROM alpine:3.15

ARG HELM_VERSION=3.8.1
ARG KUBECTL_VERSION=1.23.4
ARG EXOSCALE_CLI_VERSION=1.51.2

# Install helm (latest release)
# ENV BASE_URL="https://storage.googleapis.com/kubernetes-helm"
ENV BASE_URL="https://get.helm.sh"
ENV TAR_FILE="helm-v${HELM_VERSION}-linux-amd64.tar.gz"
RUN apk add --update --no-cache curl ca-certificates bash git && \
    curl -sL ${BASE_URL}/${TAR_FILE} | tar -xvz && \
    mv linux-amd64/helm /usr/bin/helm && \
    chmod +x /usr/bin/helm && \
    rm -rf linux-amd64

RUN curl -sLO https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl && \
    mv kubectl /usr/bin/kubectl && \
    chmod +x /usr/bin/kubectl

RUN curl -sLO https://github.com/exoscale/cli/releases/download/v${EXOSCALE_CLI_VERSION}/exoscale-cli_${EXOSCALE_CLI_VERSION}_linux_amd64.tar.gz && \
    tar xzf exoscale-cli_${EXOSCALE_CLI_VERSION}_linux_amd64.tar.gz && \
    mv exo /usr/bin/exo && \
    chmod +x /usr/bin/exo

RUN apk add --update --no-cache jq

RUN addgroup -S app && adduser -S -G app app

USER app

ENTRYPOINT ["/bin/sh"]