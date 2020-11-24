#!/bin/bash

# Requirments:
# doctl -> https://github.com/digitalocean/doctl/releases
# jq -> https://github.com/stedolan/jq/releases

# Settings
#TOKEN='REPLACE_ME_WITH_REAL_TOKEN'
#REGISTRY_NAME='REPLACE_ME_WITH_REGISTRY_NAME'
HDR="Content-Type: application/json" # GET Headers
REG_URI="https://api.digitalocean.com/v2/registry/${REGISTRY_NAME:-exampleregistry}"
KEEP_DAYS=5
IGNORE_TAGS='develop\|master\|\release' # 'release\|stable' will exclude both tags
IGNORE_REPOS='nginx' # define repos to skip
KEEP_UNIXTIME=$(date +%s --date="${KEEP_DAYS} days ago") #Example: date +%s --date="21 days ago"

# Bash colors
BLUE='\033[0;34m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
NC='\033[0m' # No color

# Begin
ALL_REPOS=$(curl -s -X GET -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories" | jq -r '.repositories[].name')

# Find manifests for ignoring
for repo in ${ALL_REPOS[@]}
do
  (echo ${repo} | grep -v ${IGNORE_REPOS} > /dev/null ) || continue
  echo -e "${YELLOW}CURRENT REPO: ${repo}${NC}"
  ALL_RESPONSE=$(curl -s -XGET -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories/${repo}/tags?page=1&per_page=200")
  TOTAL_TAGS=$(echo ${ALL_RESPONSE} | jq -r '.meta.total')
  TOTAL_PAGES=$((1))
  if [[ ${TOTAL_TAGS} -gt 200 ]]; then
    TOTAL_PAGES=$((TOTAL_TAGS / 200 + 1))
  fi
  for ((page=1; page<=$((TOTAL_PAGES)); page++))
  do
    THIS_PAGE_RESPONSE=$(curl -s -XGET -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories/${repo}/tags?page=${page}&per_page=200")
    THIS_PAGE_TOTAL_TAGS=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[]?.tag?" | wc -l | xargs`
    for ((tag=0; tag<$((THIS_PAGE_TOTAL_TAGS)); tag++))
    do
      CURRENT_TAG=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[${tag}]?.tag?"`
      CURRENT_DATE=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[${tag}]?.updated_at?"`
      CURRENT_MANIFEST=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[${tag}]?.manifest_digest?"`
      echo ${CURRENT_TAG} | grep -v ${IGNORE_TAGS} > /dev/null
      rs=$?
      if [[ ${rs} -eq 1 ]]; then
        IGNORE_MANIFESTS+=(${CURRENT_MANIFEST})
        echo -e "${GREEN}Manifest tag: ${CURRENT_MANIFEST} has been added to ignoring manifest rule${NC}"
        continue
      fi
    done
  done
done

# Find targets for cleaning up
for repo in ${ALL_REPOS[@]}
do
  (echo ${repo} | grep -v ${IGNORE_REPOS} >> /dev/null)|| continue
  echo -e "${YELLOW}CURRENT REPO: ${repo}${NC}"
  ALL_RESPONSE=$(curl -s -XGET -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories/${repo}/tags?page=1&per_page=200")
  TOTAL_TAGS=$(echo ${ALL_RESPONSE} | jq -r '.meta.total')
  echo -e "${GREEN}Total tags on this repo ${TOTAL_TAGS} ${NC}"
  TOTAL_PAGES=$((1))
  if [[ ${TOTAL_TAGS} -gt 200 ]]; then
    TOTAL_PAGES=$((TOTAL_TAGS / 200 + 1))
  fi
  echo -e "${GREEN}Total pages on this repo ${TOTAL_PAGES} ${NC}"
  for ((page=1; page<=$((TOTAL_PAGES)); page++))
  do
    THIS_PAGE_RESPONSE=$(curl -s -XGET -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories/${repo}/tags?page=${page}&per_page=200")
    THIS_PAGE_TOTAL_TAGS=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[]?.tag?" | wc -l | xargs`
    echo -e "${YELLOW}Page: ${page} of ${TOTAL_PAGES} ${NC}"
    echo -e "${YELLOW}THIS PAGE TOTAL TAGS: ${THIS_PAGE_TOTAL_TAGS} ${NC}"
    for ((tag=0; tag<$((THIS_PAGE_TOTAL_TAGS)); tag++))
    do
      CURRENT_TAG=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[${tag}]?.tag?"`
      CURRENT_DATE=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[${tag}]?.updated_at?"`
      CURRENT_MANIFEST=`echo ${THIS_PAGE_RESPONSE} | jq -r ".tags[${tag}]?.manifest_digest?"`
      unixtime=$(date +%s --date=${CURRENT_DATE})
      echo -e "${GREEN}Current tag: ${CURRENT_TAG} ${NC}"
      echo ${CURRENT_TAG} | grep -v ${IGNORE_TAGS} > /dev/null
      rs=$?
      if [[ ${rs} -eq 1 ]]; then
        echo -e "${GREEN}This tag: ${CURRENT_TAG} will be skipped due to ignoring tags rule${NC}"
        IGNORE_MANIFESTS+=(${CURRENT_MANIFEST})
        continue
      fi
      if [[ " ${IGNORE_MANIFESTS[@]} " =~ " ${CURRENT_MANIFEST} " ]]; then
        echo -e "${GREEN} This tag: ${CURRENT_TAG} will be skipped due to ignoring manifest rule: ${CURRENT_MANIFEST} ${NC}"
        continue
      fi
      if [[ ${unixtime} -lt ${KEEP_UNIXTIME} ]]; then
        echo -e "${BLUE}This tag creation date: ${CURRENT_DATE} ${RED}Found target for deleting due to the age. ${NC}"
        echo -e "${RED} Old tag: ${CURRENT_TAG} ${NC}"
        echo -e "${RED} Old manifest: ${CURRENT_MANIFEST} ${NC}"
        CLEANUP_REPOS+=("${repo}")
        CLEANUP_TAGS+=("${CURRENT_TAG}")
        CLEANUP_MANIFESTS+=(${CURRENT_MANIFEST})
      fi
    done
  done
done

#We do not delete manifests which should be ignored because of ignore tags had the same manifests
#So let's doing additional checks for manifests
for manifest in ${IGNORE_MANIFESTS[@]} #ignore
  do
    CLEANUP_MANIFESTS=("${CLEANUP_MANIFESTS[@]/$manifest}")
  done

#Deleting container tags
for ((i=0; i<${#CLEANUP_REPOS[@]}; i++))
do
  echo -e "${RED}Deleting tag: ${GREEN}${CLEANUP_TAGS[i]}${RED} from repository: ${YELLOW}${CLEANUP_REPOS[i]} ${NC}"
  curl -s -X DELETE -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories/${CLEANUP_REPOS[i]}/tags/${CLEANUP_TAGS[i]}"
  echo -e "${RED}Deleting manifest: ${GREEN}${CLEANUP_MANIFESTS[i]}${RED} from repository: ${YELLOW}${CLEANUP_REPOS[i]} ${NC}"
  curl -s -X DELETE -H "${HDR}" -H "Authorization: Bearer ${TOKEN}" "${REG_URI}/repositories/${CLEANUP_REPOS[i]}/digests/${CLEANUP_MANIFESTS[i]}"
done

#Starting garbage collection
doctl registry garbage-collection get-active || (
  echo "There is no active garbage-collection jobs found"
  echo "Starting new one"
  doctl registry garbage-collection start
)
