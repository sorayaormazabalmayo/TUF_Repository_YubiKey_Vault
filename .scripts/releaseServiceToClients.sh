#!/bin/bash
#
# Setting the variables that are going to be used

repo_owner="sorayaormazabalmayo"

# Step 1: Getting the latest changes from remote
git pull 

# Step 2: Enforce strict error handling
set -eo pipefail 

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

# Step 6: Checking that the provided service and commit had not been compromised

# Before releasing the update to clients, verify the integrity of the release.
# Compare the hash from the GitHub Release with the one from GAR (Google Artifact Registry)
# to ensure there has been no man-in-the-middle attack and that both point to the same release.

# Getting the hash associated with the commit 

curl -s -H "Accept: application/vnd.github.v3+json" \
     "https://api.github.com/repos/$repo_owner/$service/tags"

tag=$(curl -s -H "Accept: application/vnd.github.v3+json" \
    "https://api.github.com/repos/$repo_owner/$service/tags" | jq -r 'map(select(.commit.sha == "'$commit_hash'")) | .[0].name')

if [[ -z "$tag" || "$tag" == "null" ]]; then
    echo "❌ No tag found for commit $commit_hash"
    exit 1
fi
echo "🔍 Tag associated with commit $commit_hash: $tag"

# Downloading the .zip from GitHub
mkdir GitHubRelease
wget -P GitHubRelease https://github.com/sorayaormazabalmayo/$service/releases/download/$tag/$service.zip

# Unzip GitHubRelease/$service.zip -d GitHubRelease

# Getting the sha256
sha256_GitHubRelease=$(sha256sum GitHubRelease/$service.zip | awk '{print $1}')
size_GitHubRelease=$(stat --format="%s" GitHubRelease/$service.zip)

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
    $service:$tag:$service.zip \
    --verbosity=debug

# Rename the downloaded file
mv GARRelease/* GARRelease/$service.zip

sha256_GARRelease=$(sha256sum GARRelease/$service.zip | awk '{print $1}')
size_GARRelease=$(stat --format="%s" GARRelease/$service.zip)

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

# Step 7: Creating the branch sign/ for updating the -index that is going to be provided to the client
branch_name="sign/$commit_hash"
git branch $branch_name
echo "Changed to branch $branch_name"

# Step 8: Going to the targets repository, exactly to the folder of the service that wants to be modified
cd targets/${service}

# Step 9: Setting the variables for modifying the index.json
new_bytes=$size_GARRelease
new_path="https://artifactregistry.googleapis.com/download/v1/projects/polished-medium-445107-i9/locations/europe-southwest1/repositories/nebula-storage/files/$service:$tag:$service.zip:download?alt=media"
new_sha256=$sha256_GARRelease
new_version=$tag
new_release_date=$(TZ="Europe/Madrid" date +"%Y.%m.%d.%H.%M.%S")
json_file="${service}-index.json"

# Step 10: Creating the new target json that will allow the client to download the last artifact
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

# Step 11: Showing the commands so that the developer can push the changes 
echo "🚨 Commands for releasing the changes applied in commit $commit_hash to clients 🚨"
echo "git checkout $branch_name"
echo "git add ."
echo "git commit -m "$tag""
echo "git push origin $branch_name"
