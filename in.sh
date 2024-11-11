#!/bin/bash

set -e
exec 3>&1 # make stdout available as file descriptor 3 for the result
exec 1>&2 # redirect all output to stderr for logging
# Read the input JSON from stdin
input="$(cat <&0)"

# Extract the values from the JSON
domain=$(jq -r '.source.domain' <<< "$input")
ca_cert_b64=$(jq -r '.source.ca_certificate' <<< "$input")
version=$(jq -r '.version.ref' <<< "$input")
s3_bucket=$(jq -r '.source.s3_bucket' <<< "$input")
aws_access_key_id=$(jq -r '.source.aws_access_key_id' <<< "$input")
aws_secret_access_key=$(jq -r '.source.aws_secret_access_key' <<< "$input")
aws_role_arn=$(jq -r '.source.aws_role_arn' <<< "$input")
aws_region=$(jq -r '.source.aws_region' <<< "$input")

destination_dir=$1

# # Decode and save the custom CA certificate to a file
# echo "$ca_cert_b64" | base64 -d > "/usr/local/share/ca-certificates/custom-ca.crt"
# echo "$ca_cert_b64" | base64 -d > /etc/ssl/certs/ca-certificates.crt

# # Update the system's certificate trust store
# update-ca-certificates

assume_role() {
    local AWS_ACCESS_KEY_ID="$1"
    local AWS_SECRET_ACCESS_KEY="$2"
    local aws_role_arn="$3"
    local aws_region="$4"

    echo "Assuming role $aws_role_arn"

    aws configure set aws_access_key_id $AWS_ACCESS_KEY_ID
    aws configure set aws_secret_access_key $AWS_SECRET_ACCESS_KEY
    aws configure set aws_default_region $aws_region

    local ASSUME_ROLE_OUTPUT=$(aws sts assume-role --role-arn $aws_role_arn --role-session-name acme-resource-session --duration-seconds 900)

    # Extract the credentials from the AssumeRole output
    local ASSUMED_ACCESS_KEY_ID=$(echo $ASSUME_ROLE_OUTPUT | jq -r .Credentials.AccessKeyId)
    local ASSUMED_SECRET_ACCESS_KEY=$(echo $ASSUME_ROLE_OUTPUT | jq -r .Credentials.SecretAccessKey)
    local ASSUMED_SESSION_TOKEN=$(echo $ASSUME_ROLE_OUTPUT | jq -r .Credentials.SessionToken)

    aws configure set aws_access_key_id $ASSUMED_ACCESS_KEY_ID
    aws configure set aws_secret_access_key $ASSUMED_SECRET_ACCESS_KEY
    aws configure set aws_session_token $ASSUMED_SESSION_TOKEN
}

check_bucket_for_certificates() {
    local bucket="$1"
    local domain="$2"

    echo "Checking for certificates for $domain in S3 bucket $bucket"
    # aws s3 ls "s3://${bucket}/certificates/${domain}_ecc" > /dev/null
    aws s3 ls "s3://${bucket}/certificates/${domain}_ecc"
    exit_code=$?
    echo $exit_code
    if [ $exit_code -eq 0 ]; then
        echo "Certificate found in S3 bucket"
        aws s3 cp "s3://${bucket}/certificates/${domain}_ecc" "${destination_dir}/${domain}_ecc" --recursive
        return 0
    else
        echo "Certificate not found in S3 bucket"
        return 1
    fi
}

generate_certificate_hash() {
    local cert_file="$1"
    local b64_cert=$(base64 -w 0 "$cert_file")
    echo -n "$b64_cert" | sha256sum | awk '{print $1}'
}



echo $domain
echo $alt_domains
echo "looking for $version"
assume_role "$aws_access_key_id" "$aws_secret_access_key" "$aws_role_arn" "$aws_region"

#get certificates (they should already exist from check)
check_bucket_for_certificates "$s3_bucket" "$domain"
cert_hash=$(generate_certificate_hash "${destination_dir}/${domain}_ecc/$domain.cer")

if [ "$cert_hash" == "$version" ]; then
    echo "Found version $version in S3 bucket"
    # echo "{ \"ref\" : [ \"${cert_hash}\" ]}" >&3
    jq -n --arg cert_hash "$cert_hash" '{version: { ref: $cert_hash}}' >&3

else
    echo "Version $version does not exist in S3 bucket"
    exit 1
fi
