FROM alpine:latest

RUN apk --update --no-cache add wget jq curl bash openssl socat ca-certificates aws-cli

ADD in.sh /opt/resource/in
ADD check.sh /opt/resource/check
ADD acme.sh /opt/resource/acme.sh
RUN chmod +x /opt/resource/*