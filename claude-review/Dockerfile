# Image for the claude-review CI job.
# Swap the base for an internal mirror if your runners can't reach Docker Hub, e.g.
#   FROM <your-registry>/node/stack:24-ci
FROM node:24-alpine
# bash is required — the review scripts use bash-only features (BASH_SOURCE, $'\n')
RUN apk add --no-cache git jq curl bash
RUN npm install -g @anthropic-ai/claude-code
