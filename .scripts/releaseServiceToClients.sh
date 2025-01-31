#!/bin/bash
#
# Setting the variables that are going to be used

repo_owner="sorayaormazabalmayo"

# Step 1: Getting the latest changes from remote
git pull 

# Step 2: Enforce strict error handling
set -eo pipefail  # Fail the script if any command in a pipeline fails.

# Step 3: Read environment variables
read -r service <<< "${SERVICE:-}"
read -r commit_hash <<< "${HASH:-}"

# Ensure variables are correctly read
echo "🚀 The service that wants to be changed is '${service}' with commit '${commit_hash}' 🚀"

# Step 4: Validate that SERVICE is set
if [[ -z "${service}" ]]; then
  echo "❌ ERROR: No SERVICE provided! Run: SERVICE=value HASH=value make release ❌"
  exit 1
fi

# Step 5: Validate that HASH is set
if [[ -z "${commit_hash}" ]]; then
  echo "❌ ERROR: No HASH provided! Run: SERVICE=value HASH=value make release ❌"
  exit 1
fi

# Step 6: Checking if the service provided is an existing service 

current_service_names=$(find targets -mindepth 1 -maxdepth 1 -type d -printf "%f\n")

found=false

for current_service in $current_service_names; do
  if [[ "$current_service" == "${service}" ]]; then
    echo "This service currently exists"
    found=true
    break
  else 
    echo "This service currently does not exist"
  fi
done

## Now, before releasing the updates to the clients, I would like to ensure that there has not been any man in the middle. 
## For doing so, the hash from GitHub Release and the GAR are going to be compared.
## Also, in this way, we will ensure that we are referring to the same release. 

# Getting the hash associated with the commit 

tag=$(curl -s -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$repo_owner/$service/tags" | jq -r 'map(select(.commit.sha == "'$commit_hash'")) | .[0].name')

# Error Handling
if [[ -z "$tag" || "$tag" == "null" ]]; then
    echo "❌ No tag found for commit $commit_hash"
    exit 1
fi

echo "🔍 Tag associated with commit $commit_hash: $tag"

# Downloading the .zip from GitHub

mkdir GitHubRelease
wget -P GitHubRelease https://github.com/sorayaormazabalmayo/tunnel-integration/releases/download/$tag/tunnel-integration.zip

# Unzip the .zip into the same directory
unzip GitHubRelease/tunnel-integration.zip -d GitHubRelease

# Getting the sha256

sha256_GitHubRelease=$(sha256sum GitHubRelease/build/$service | awk '{print $1}')
size_GitHubRelease=$(stat --format="%s" GitHubRelease/build/$service)

rm -rf GitHubRelease

echo "The digest (sha256) of the GitHub Release is: $sha256_GitHubRelease"
echo "File size: $size_GitHubRelease bytes"

# Downloading the file from GAR
mkdir GARRelease

gcloud artifacts files download \
    --project=polished-medium-445107-i9 \
    --location=europe-southwest1 \
    --repository=nebula-storage \
    --destination=GARRelease \
    $service:$tag:$service \
    --verbosity=debug

# Rename the downloaded file
mv GARRelease/* GARRelease/$service

sha256_GARRelease=$(sha256sum GARRelease/$service | awk '{print $1}')
size_GARRelease=$(stat --format="%s" GARRelease/$service)

echo "The digest (sha256) of the GitHub Release is: $sha256_GARRelease"
echo "File size: $size_GARRelease bytes"

rm -rf GARRelease

# Validate SHA256 comparison
if [[ -z "$sha256_GitHubRelease" || -z "$sha256_GARRelease" ]]; then
    echo "❌ ERROR: One of the hashes is missing, cannot verify integrity!"
    exit 1
fi

if [[ "$sha256_GitHubRelease" == "$sha256_GARRelease" ]]; then 
    echo "✅ The digest from GitHub matches the one from GAR. No one has compromised the repository ✅"
else 
    echo "❌ Someone has compromised the repository ❌"
    exit 1
fi

## Creating the branch sign/ for updating the -index that is going to be provided to the client

branch_name="sign/$commit_hash"
git branch $branch_name

echo "Changed to branch $branch_name"

## Going to the targets repository, exactly to the folder of the service that wants to be modified

cd targets/${service}

## Setting the variables for modifying the index.json

new_bytes=$size_GARRelease
new_path="https://artifactregistry.googleapis.com/download/v1/projects/polished-medium-445107-i9/locations/europe-southwest1/repositories/nebula-storage/files/$service:$tag:$service:download?alt=media"
new_sha256=$sha256_GARRelease
new_version=$tag
new_release_date=$(TZ="Europe/Madrid" date +"%Y.%m.%d.%H.%M.%S")
json_file="${service}-index.json"

if [[ -f "$json_file" ]]; then
  echo "✏️ Overwriting existing $json_file"
  jq -n --arg service "$service" \
        --arg bytes "$new_bytes" \
        --arg path "$new_path" \
        --arg sha256 "$new_sha256" \
        --arg version "$new_version" \
        --arg release_date "$new_release_date" \
        '{($service): {bytes: $bytes, path: $path, hashes: {sha256: $sha256}, version: $version, "release-date": $release_date}}' \
        > "$json_file"
else
  echo "📄 Creating new $json_file"
  jq -n --arg service "$service" \
        --arg bytes "$new_bytes" \
        --arg path "$new_path" \
        --arg sha256 "$new_sha256" \
        --arg version "$new_version" \
        --arg release_date "$new_release_date" \
        '{($service): {bytes: $bytes, path: $path, hashes: {sha256: $sha256}, version: $version, "release-date": $release_date}}' \
        > "$json_file"
fi


echo "✅ Updated JSON File: $json_file"
cat "$json_file"  # Print the final JSON for verification
echo " "
## Showing the commands so that the developer can push the changes himself/herself
echo "🚨 Commands for releasing the changes applied in commit $commit_hash to clients 🚨"
echo "git checkout $branch_name"
echo "git add."
echo "git commit -m "$tag""
echo "git push origin $branch_name"
