#!/bin/bash

# Copyright Splunk Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -exuo pipefail

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
REPO_DIR="$( cd "$SCRIPT_DIR/../../.." && pwd )"
OUTPUT_DIR="${REPO_DIR}/dist"

ARCH="${1:-amd64}"
DOCKER_REPO="${2:-docker.io}"
CI="${CI:-false}"
USE_REGISTRY_CACHE="${USE_REGISTRY_CACHE:-yes}"
PUSH_CACHE="${PUSH_CACHE:-no}"

DOCKER_OPTS="--platform linux/${ARCH} -f ${SCRIPT_DIR}/../Dockerfile --build-arg ARCH=${ARCH} --build-arg DOCKER_REPO=${DOCKER_REPO} ${SCRIPT_DIR}/.."
IMAGE_NAME="agent-bundle"
OUTPUT="${IMAGE_NAME}_linux_${ARCH}.tar.gz"
output_tar=$(basename "$OUTPUT" .gz)

CACHE_REPO="quay.io/signalfx/agent-bundle-stage-cache"
CACHE_DIR="${REPO_DIR}/.cache/buildx/${IMAGE_NAME}-${ARCH}"
CACHE_TEMP_DIR=""
CACHE_FROM_OPTS=""
CACHE_TO_OPTS=""
BUILDER=""

ALL_STAGES=$( grep '^FROM .* AS .*' ${SCRIPT_DIR}/../Dockerfile | sed -e 's/.* AS //' )

export DOCKER_BUILDKIT=1

if [[ "$CI" = "true" ]]; then
    # create and use the docker-container builder for caching when running in github or gitlab
    docker buildx create --name $IMAGE_NAME --driver docker-container || true
    BUILDER="--builder ${IMAGE_NAME}"
    DOCKER_OPTS="$BUILDER $DOCKER_OPTS"
fi

if [[ "$PUSH_CACHE" = "yes" ]]; then
    # build and push inline cache images for each stage
    for stage in $ALL_STAGES; do
        stage_image="${CACHE_REPO}:stage-${stage}-${ARCH}"
        docker buildx build \
            --tag $stage_image \
            --target $stage \
            --push \
            --cache-to=type=inline \
            $DOCKER_OPTS
        # This command is only available internally, but the image is
        # pushed only from internal CI, so it's safe to leave it here.
        artifact-ci sign docker $stage_image
    done
else
    if [[ -d "$CACHE_DIR" ]]; then
        # only use the restored CI cache if it exists to save time and disk space
        CACHE_FROM_OPTS="--cache-from=type=local,src=${CACHE_DIR}"
        USE_REGISTRY_CACHE="no"
    fi
    if [[ "$CI" = "true" && "${BUNDLE_CACHE_HIT:-}" != "true" ]]; then
        # only export local build cache to replace the existing CI cache when there are changes
        CACHE_TEMP_DIR="$(mktemp -d)"
        CACHE_TO_OPTS="--cache-to=type=local,mode=max,dest=${CACHE_TEMP_DIR}"
    fi
fi

if [[ "$USE_REGISTRY_CACHE" = "yes" ]]; then
    # use registry cache images from each stage
    for stage in $ALL_STAGES; do
        stage_image="${CACHE_REPO}:stage-${stage}-${ARCH}"
        CACHE_FROM_OPTS="${CACHE_FROM_OPTS} --cache-from=type=registry,ref=${stage_image}"
    done
fi

# build and save the agent bundle image
docker buildx build \
    --tag ${IMAGE_NAME}:${ARCH} \
    --load \
    $CACHE_TO_OPTS \
    $CACHE_FROM_OPTS \
    $DOCKER_OPTS

cid=$(docker create --platform linux/${ARCH} ${IMAGE_NAME}:${ARCH} true)

tmpdir=$(mktemp -d)
mkdir ${tmpdir}/${IMAGE_NAME}

trap "docker rm -f $cid; rm -rf $tmpdir; rm -f $output_tar" EXIT

docker export $cid | tar -C ${tmpdir}/${IMAGE_NAME} -xf -
rm -rf ${tmpdir}/${IMAGE_NAME}/{proc,sys,dev,etc} ${tmpdir}/${IMAGE_NAME}/.dockerenv
mkdir -p "$OUTPUT_DIR"
(cd $tmpdir && tar -zcf ${OUTPUT_DIR}/${OUTPUT} *)

if [[ -n "$CACHE_TEMP_DIR" && -d "$CACHE_TEMP_DIR" ]]; then
    # replace cache directory with the current build to avoid snowballing
    mkdir -p "$CACHE_DIR"
    rm -rf "$CACHE_DIR"
    mv "$CACHE_TEMP_DIR" "$CACHE_DIR"
fi

if [[ -n "$BUILDER" ]]; then
    # clean up the builder to reclaim space
    docker buildx prune --force $BUILDER
fi
