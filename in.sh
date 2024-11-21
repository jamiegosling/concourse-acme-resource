#!/bin/bash
#in
set -e

exec 3>&1 # Make stdout available as file descriptor 3 for the result
exec 1>&2 # Redirect all output to stderr for logging

# Read the input JSON from stdin
input="$(cat <&0)"

# Extract the values from the JSON
domain=$(jq -r '.source.domain' <<< "$input")
ca_cert_b64=$(jq -r '.source.ca_certificate' <<< "$input")
version_ref=$(jq -r '.version.ref' <<< "$input")
s3_bucket=$(jq -r '.source.s3_bucket' <<< "$input")
aws_access_key_id=$(jq -r '.source.aws_access_key_id' <<< "$input")
aws_secret_access_key=$(jq -r '.source.aws_secret_access_key' <<< "$input")
aws_role_arn=$(jq -r '.source.aws_role_arn' <<< "$input")
aws_region=$(jq -r '.source.aws_region' <<< "$input")

# this is the directory concourse provides for the output
destination_dir=$1

assume_role() {
    local AWS_ACCESS_KEY_ID="$1"
    local AWS_SECRET_ACCESS_KEY="$2"
    local aws_role_arn="$3"
    local aws_region="$4"

    echo "Assuming role $aws_role_arn"

    aws configure set aws_access_key_id "$AWS_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$AWS_SECRET_ACCESS_KEY"
    aws configure set aws_default_region "$aws_region"

    local ASSUME_ROLE_OUTPUT
    ASSUME_ROLE_OUTPUT=$(aws sts assume-role --role-arn "$aws_role_arn" --role-session-name acme-resource-session --duration-seconds 900)

    # Extract the credentials from the AssumeRole output
    local ASSUMED_ACCESS_KEY_ID
    ASSUMED_ACCESS_KEY_ID=$(echo "$ASSUME_ROLE_OUTPUT" | jq -r .Credentials.AccessKeyId)
    local ASSUMED_SECRET_ACCESS_KEY
    ASSUMED_SECRET_ACCESS_KEY=$(echo "$ASSUME_ROLE_OUTPUT" | jq -r .Credentials.SecretAccessKey)
    local ASSUMED_SESSION_TOKEN
    ASSUMED_SESSION_TOKEN=$(echo "$ASSUME_ROLE_OUTPUT" | jq -r .Credentials.SessionToken)

    aws configure set aws_access_key_id "$ASSUMED_ACCESS_KEY_ID"
    aws configure set aws_secret_access_key "$ASSUMED_SECRET_ACCESS_KEY"
    aws configure set aws_session_token "$ASSUMED_SESSION_TOKEN"
}

find_zip_by_version() {
    local bucket="$1"
    local version="$2"
    local domain="$3"
    echo "Searching for zip file with VersionId $version in bucket $bucket"
    
    aws s3api get-object --bucket "$bucket" --key "certificates/${domain}_ecc.zip" --version-id "$version" ${domain}_ecc.zip
    exit_code=$?

    if [ $exit_code -ne 0 ]; then
        echo "Failed to download zip file with VersionId $version from bucket $bucket"
        exit 1
    fi
    #unzip the version fetched in the directory provided by concourse
    unzip ${domain}_ecc.zip -d $destination_dir
}

echo "Domain: $domain"
echo "Looking for version with VersionId: $version_ref"

assume_role "$aws_access_key_id" "$aws_secret_access_key" "$aws_role_arn" "$aws_region"

# Find the zip file with the given VersionId
find_zip_by_version "$s3_bucket" "$version_ref" "$domain"

# Output the ref
jq -n --arg version "$version_ref" '{version: { ref: $version}}' >&3