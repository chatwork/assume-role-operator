FROM chatwork/alpine-sdk:3.8

ARG KUBECTL_VERSION=1.11.2
ARG AWS_VERSION=1.16.58

LABEL version="${KUBECTL_VERSION}-${AWS_VERSION}"
LABEL maintainer="sakamoto@chatwork.com"

ADD https://storage.googleapis.com/kubernetes-release/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl /usr/local/bin/kubectl

RUN chmod +x /usr/local/bin/kubectl

ADD entrypoint.sh \
    assumerole.aws.chatwork-crd.yaml \
    /

RUN apk --no-cache add py3-pip jq bash \
    && pip3 install --no-cache-dir --upgrade pip \
    && pip3 install --no-cache-dir awscli==${AWS_VERSION} \
    && chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
