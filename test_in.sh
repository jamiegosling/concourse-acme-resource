#docker run --rm -i concourse-acme-resource /opt/resource/in . < in_payload.json

#docker run --rm -i jamiegosling/concourse-acme-resource:v0.0.12 /opt/resource/check . < check_payload.json

docker run --rm -i \
  -v /etc/ssl/cert.pem:/etc/ssl/certs/ca-certificates.crt:ro \
  -v $(pwd)/ca2.cer:/usr/local/share/ca-certificates/private.crt:ro \
  --entrypoint /bin/sh \
  jamiegosling/concourse-acme-resource:v2.0.1 \
  -c "update-ca-certificates && /opt/resource/in ." < in_payload.json