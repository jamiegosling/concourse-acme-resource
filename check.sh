#!/bin/bash

# set -e
exec 3>&1 # make stdout available as file descriptor 3 for the result
exec 1>&2 # redirect all output to stderr for logging
# Read the input JSON from stdin
input="$(cat <&0)"

# Extract the values from the JSON
domain=$(jq -r '.source.domain' <<< "$input")
alt_domains=$(jq -r '.source.alt_domains | join(",")' <<< "$input")
renew_days=$(jq -r '.source.renew_days' <<< "$input")
certificate_url=$(jq -r '.source.certificate_url' <<< "$input")
ca_cert_b64=$(jq -r '.source.ca_certificate' <<< "$input")
s3_bucket=$(jq -r '.source.s3_bucket' <<< "$input")
aws_access_key_id=$(jq -r '.source.aws_access_key_id' <<< "$input")
aws_secret_access_key=$(jq -r '.source.aws_secret_access_key' <<< "$input")
aws_role_arn=$(jq -r '.source.aws_role_arn' <<< "$input")
aws_region=$(jq -r '.source.aws_region' <<< "$input")

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
        aws s3 cp "s3://${bucket}/certificates/${domain}_ecc" "$HOME/.acme.sh/${domain}_ecc" --recursive
        return 0
    else
        echo "Certificate not found in S3 bucket"
        return 1
    fi
}

# Function to generate/renew certificate and provide output
generate_certificate() {
    local domain="$1"
    local certificate_url="$2"
    local alt_domains="$3"

    echo "$alt_domains"
    if [ "$alt_domains" == "" ]; then
        /opt/resource/./acme.sh --issue --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please -d "$domain" --server "$certificate_url" >&2
    else
        /opt/resource/./acme.sh --issue --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please -d "$domain" $alt_domains --server "$certificate_url" >&2
    fi
    exit_code=$?
    echo "exit code: $exit_code"
    local cert_dir="$HOME/.acme.sh/${domain}_ecc"
    local cert_file="$cert_dir/$domain.cer"
    local key_file="$cert_dir/$domain.key"
    local b64_cert=$(base64 -w 0 "$cert_file")
    local b64_key=$(base64 -w 0 "$key_file")
    local cert_hash=$(echo -n "$b64_cert" | sha256sum | awk '{print $1}')

    #update certificates in s3 bucket
    if [ $exit_code -eq 0 ]; then
        echo "certificate has changed, uploading to s3"
        aws s3 cp --recursive "$cert_dir" "s3://${s3_bucket}/certificates/${domain}_ecc"
    elif [ $exit_code -eq 2 ]; then
        echo "certificate has not changed, not uploading to s3"
    else
        echo "error generating certificate"
        exit 1
    fi
    jq -n --arg cert_hash "$cert_hash" '[{ref: $cert_hash}]' >&3



}

generate_domains() {
    local domain_list=$1
    local formatted_domains=""

    # Split the domain list by commas (if any) and loop over each domain
    IFS=',' read -ra domains <<< "$domain_list"

    # If domain_list is empty or has one domain, handle both cases
    for domain in "${domains[@]}"; do
        formatted_domains+=" -d $domain"
    done

    # Return the formatted domain string
    echo "$formatted_domains" | xargs
}

echo $domain
echo $alt_domains
assume_role "$aws_access_key_id" "$aws_secret_access_key" "$aws_role_arn" "$aws_region"

#get certificates if they exist
check_bucket_for_certificates "$s3_bucket" "$domain"
# generate a command we can use in acme from our alternate names
if [ "$alt_domains" == "null" ]; then
    echo "no alternate domains required"
    alt_domain_cmd=""
else
    echo "generating command for alternate domains"
    alt_domain_cmd=$(generate_domains "$alt_domains")
fi
#we can always call this because acme will decide when to generate a new certificate
generate_certificate "$domain" "$certificate_url" "$alt_domain_cmd"