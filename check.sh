#!/bin/bash
#check
set -e

exec 3>&1 # Make stdout available as file descriptor 3 for the result
exec 1>&2 # Redirect all output to stderr for logging

# Read the input JSON from stdin
input="$(cat <&0)"

# Extract the values from the JSON
domain=$(jq -r '.source.domain' <<< "$input")
alt_domains=$(jq -r '.source.alt_domains | join(",")' <<< "$input")
renew_days=$(jq -r '.source.renew_days' <<< "$input")
certificate_url=$(jq -r '.source.certificate_url' <<< "$input")
ca_cert_b64=$(jq -r '.source.ca_certificate' <<< "$input")
s3_bucket=$(jq -r '.source.s3_bucket' <<< "$input")
aws_role_arn=$(jq -r '.source.aws_role_arn' <<< "$input")
# these need to be exported for the aws cli to use them
export AWS_ACCESS_KEY_ID=$(jq -r '.source.aws_access_key_id' <<< "$input")
export AWS_SECRET_ACCESS_KEY=$(jq -r '.source.aws_secret_access_key' <<< "$input")
export AWS_DEFAULT_REGION=$(jq -r '.source.aws_region' <<< "$input")

# Directory to store certificates temporarily
temp_dir=$(mktemp -d)
cleanup() {
    rm -rf "$temp_dir"
}
trap cleanup EXIT

assume_role() {
    local aws_role_arn="$1"
    local timestamp=$(date +%s)
    echo "Assuming role $aws_role_arn"

    local ASSUME_ROLE_OUTPUT
    ASSUME_ROLE_OUTPUT=$(aws sts assume-role --role-arn "$aws_role_arn" --role-session-name "acme-resource-session-${timestamp}" --duration-seconds 900)

    # Extract the credentials from the AssumeRole output
    local ASSUMED_ACCESS_KEY_ID
    ASSUMED_ACCESS_KEY_ID=$(echo "$ASSUME_ROLE_OUTPUT" | jq -r .Credentials.AccessKeyId)
    local ASSUMED_SECRET_ACCESS_KEY
    ASSUMED_SECRET_ACCESS_KEY=$(echo "$ASSUME_ROLE_OUTPUT" | jq -r .Credentials.SecretAccessKey)
    local ASSUMED_SESSION_TOKEN
    ASSUMED_SESSION_TOKEN=$(echo "$ASSUME_ROLE_OUTPUT" | jq -r .Credentials.SessionToken)

    export AWS_ACCESS_KEY_ID="$ASSUMED_ACCESS_KEY_ID"
    export AWS_SECRET_ACCESS_KEY="$ASSUMED_SECRET_ACCESS_KEY"
    export AWS_SESSION_TOKEN="$ASSUMED_SESSION_TOKEN"
}

list_versions() {
    local bucket="$1"
    local key="$2"

    # echo "Listing all versions for key: $key in bucket: $bucket"

    # Initialize variables
    continuation_token=""
    versions=()

    while : ; do
        if [ -z "$continuation_token" ]; then
            response=$(aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --query 'Versions[].VersionId' --output text)
        else
            response=$(aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --continuation-token "$continuation_token" --query 'Versions[].VersionId' --output text)
        fi

        # Add versions to the array
        while IFS= read -r version; do
            # Remove surrounding quotes
            clean_version=${version//\"/}
            versions+=("$clean_version")
        done <<< "$response"

        # Check if there's a NextContinuationToken
        continuation_token=$(aws s3api list-object-versions --bucket "$bucket" --prefix "$key" --query 'NextContinuationToken' --output text)
        if [ "$continuation_token" == "None" ] || [ -z "$continuation_token" ]; then
            break
        fi
    done
    unique_versions=($(printf "%s\n" "${versions[@]}"))
    reversed_versions=($(printf "%s\n" "${unique_versions[@]}" | awk '{lines[NR]=$0} END {for (i=NR; i>0; i--) print lines[i]}'))
    # echo "${unique_versions[@]}"
    echo "${reversed_versions[@]}"
}

# Concourse can cachce resource versions, so we need to check if the version in the cache is the latest
check_for_cached() {
    local bucket="$1"
    local domain="$2"

    # Define the key for the certificate bundle
    s3_key="certificates/${domain}_ecc.zip"

    echo "Checking for cached version..."
    cached_version=$(cat /version)
    latest_version=$(aws s3api head-object --bucket "$bucket" --key "$s3_key" | jq -r '.VersionId')
    echo "cached version: $cached_version"
    echo "latest version: $latest_version"
    if [ -f "/version" ]; then
        echo "There is a version cached, checking for newer in S3..."
        if [ $cached_version == $latest_version ]; then
            echo "Cache is latest version, nothing to get from S3"
            return 0
        else
            echo "Newer version available in S3, continue with check"
            return 1
        fi
    else
        echo "No version cached, continue with check"
        return 1
    fi
}

check_bucket_for_certificates() {
    local bucket="$1"
    local domain="$2"
    local cert_dir="$HOME/.acme.sh/${domain}_ecc"
    echo "Checking for certificates for $domain in S3 bucket $bucket"

    # Define the key for the certificate bundle
    s3_key="certificates/${domain}_ecc.zip"

    # Check if the object exists
    #if aws s3api head-object --bucket "$bucket" --key "$s3_key" > /dev/null 2>&1; then
    if aws s3api head-object --bucket "$bucket" --key "$s3_key" | jq -r '.VersionId' > /version 2>&1; then
        aws s3 cp "s3://${bucket}/${s3_key}" "${domain}_ecc.zip"
        mkdir -p $cert_dir
        unzip -o "${domain}_ecc.zip" -d "$cert_dir"
        echo "Certificate bundle found in S3 bucket"
        return 0
    else
        echo "Certificate bundle not found in S3 bucket"
        return 1
    fi
}

generate_certificate() {
    local domain="$1"
    local certificate_url="$2"
    local alt_domains="$3"

    cd "$temp_dir"
    echo "Alt Domains: $alt_domains"
    set +e
    if [ -z "$alt_domains" ] || [ "$alt_domains" == "null" ]; then
        /opt/resource/./acme.sh --issue --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please -d "$domain" --server "$certificate_url" >&2
    else
        /opt/resource/./acme.sh --issue --dns --yes-I-know-dns-manual-mode-enough-go-ahead-please -d "$domain" $alt_domains --server "$certificate_url" >&2
    fi
    exit_code=$?
    set -e
    echo "acme.sh exit code: $exit_code"

    local cert_dir="$HOME/.acme.sh/${domain}_ecc"
    local cert_file="$cert_dir/$domain.cer"
    local key_file="$cert_dir/$domain.key"

    if [ "$exit_code" -eq 0 ]; then
        echo "Certificate has changed, preparing to upload to S3"
        # Create a zip archive of the certificate directory
        zip_file="$temp_dir/${domain}_ecc.zip"
        zip -j -r "$zip_file" "$cert_dir"/*

        # Upload the zip to S3
        aws s3 cp "$zip_file" "s3://${s3_bucket}/certificates/${domain}_ecc.zip"

        # Retrieve the version of the uploaded zip
        version=$(aws s3api head-object --bucket "$s3_bucket" --key "certificates/${domain}_ecc.zip" --query VersionId --output text)
        # Remove quotes from version if present
        version=${version//\"/}

        echo "version of uploaded zip: $version"

    elif [ "$exit_code" -eq 2 ]; then
        echo "Certificate has not changed"
    else
        echo "Error generating certificate"
        exit 1
    fi
}

generate_domains() {
    local domain_list="$1"
    local formatted_domains=""

    # Split the domain list by commas
    IFS=',' read -ra domains <<< "$domain_list"

    for domain in "${domains[@]}"; do
        formatted_domains+=" -d $domain"
    done

    # Return the formatted domain string
    echo "$formatted_domains" | xargs
}

# Main Execution Flow

echo "Domain: $domain"
echo "Alt Domains: $alt_domains"

assume_role "$aws_role_arn"

set +e
check_for_cached "$s3_bucket" "$domain"
cached=$?
set -e

if [ $cached -eq 1 ]; then
    # Check if the certificate bundle exists
    check_bucket_for_certificates "$s3_bucket" "$domain" || true

fi

# Generate a command we can use in acme from our alternate names
if [ -z "$alt_domains" ] || [ "$alt_domains" == "null" ]; then
    echo "No alternate domains required"
    alt_domain_cmd=""
else
    echo "Generating command for alternate domains"
    alt_domain_cmd=$(generate_domains "$alt_domains")
fi

# Generate or renew the certificate
generate_certificate "$domain" "$certificate_url" "$alt_domain_cmd"

# After uploading, list all versions and output them as versions
s3_key="certificates/${domain}_ecc.zip"
versions=$(list_versions "$s3_bucket" "$s3_key")

if [ -z "$versions" ]; then
    echo "No versions found for key: $s3_key"
    jq -n '[]' >&3
    exit 0
fi

# Prepare the JSON array of versions
version_array=""
for version in $versions; do
    version_array=$(printf '%s{"ref":"%s"},' "$version_array" "$version")
done

# Remove trailing comma and wrap in square brackets
version_array="[${version_array%,}]"

# Output the JSON
echo "$version_array" | jq '.' >&3