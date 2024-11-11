This is a concourse resource for helping to manage certificates using acme.sh.  There is a check script (to check and fetch a new certificate if there is one) and an in script (to fetch the current certificate for use in a concourse pipeline).  It uses S3 to store the certificates, and requires a IAM user which have a key and secret to assume an IAM role to write to the S3 bucket.

Check usage

Check takes the following payload:

Payload
```
{
    "source": {        
        "domain": "my.domain",
        "alt_domains": ["alt1.my.domain", "alt2.my.domain"],
        "certificate_url": "acme server url",
        "aws_region": "eu-west-1",
        "s3_bucket": "bucket to store certs",
        "aws_access_key_id": "access_ke_id for assuming role",
        "aws_secret_access_key": "access_key for assuming role",
        "aws_role_arn": "arn:aws:iam::123456:role/role-with-s3-bucket-access"
}
```
It will issue a certificate if none exists in the s3 bucket in the path `certificates/my.domain_ecc/*`, copy this certificate to the bucket and emit a version.  This version will remain the same unless there is a change to the domains (eg. and additonal alt domain is added or removed), or the acme 'next renew time is passed', where a new certificate will be issued and a new version returned.

In usage

In takes the following payload:

```
{
    "source": {        
        "domain": "my.domain",
        "certificate_url": "acme server url",
        "aws_region": "eu-west-1",
        "s3_bucket": "bucket to store certs",
        "aws_access_key_id": "access_ke_id for assuming role",
        "aws_secret_access_key": "access_key for assuming role",
        "aws_role_arn": "arn:aws:iam::123456:role/role-with-s3-bucket-access"
    "params": {
    },
    "version" : { "ref" :"46491c5...." }
}
```

It will check the S3 bucket for the certificate referenced by the version ref (by getting the cert from the bucket and checking the hash is the same).  If the certificate exists, it will be copied and made available for use in a pipeline.  If it doesn't exist, the resource will exit with a 1 and show an error on concourse.

Example usage

```
resource_types:
resource_types:
- name: acme
  type: docker-image
  source:
    repository: jamiegosling/concourse-acme-resource
    tag: v0.0.12

resources:
- name: my-certificate
  type: acme
  check_every: never
  source:
    domain: my.domain
    alt_domains:
      - sub1.my.domain
      - sub2.my.domain
    certificate_url: https://my.acme.server/request
    aws_region: eu-west-1
    s3_bucket: ((ENV))-deployment-s3
    aws_access_key_id: "((KEY))"
    aws_secret_access_key: "((SECRET))"
    aws_role_arn: arn:aws:iam::((ACCOUNT)):role/deployment-role

- name: build-image
  type: registry-image
  source:
    repository: registry.url/((IMAGE))
    username: ((registry-robot.name))
    password: ((registry-robot.secret))

jobs:
- name: certificate-renewal
  serial: true
  public: false
  plan:
    - get: my-certificate
      trigger: false
    - get: build-image
    - task: renew-cert
      image: build-image
      config:
        platform: linux
        inputs:
          - name: my-certificate
        run:
          path: /bin/sh
          args: 
            - -c
            - |
              ls
              ls -R my-certificate/
```