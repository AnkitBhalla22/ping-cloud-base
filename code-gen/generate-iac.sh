#!/bin/bash

########################################################################################################################
#
# This script may be used to generate the initial Kubernetes configurations to push into an Infrastructure-as-Code
# (IaC) repo for a particular tenant.
#
# The intended audience of this repo is primarily the Ping Professional Services and Support team, with limited access
# granted to Customer administrators. These users may further tweak the IaC code per the tenant's requirements. They
# are expected to have an understanding of Kubernetes manifest files and kustomize, a client-side tool used to make
# further customizations to the initial IaC code generated by this script.
#
# The script generates Kubernetes manifest files for 4 different environments - dev, test, staging and prod. The
# manifest files for these environments contain deployments of both the Ping Cloud stack and the supporting tools
# necessary to provide an end-to-end solution.
#
# ------------------
# Usage instructions
# ------------------
#
# The following mandatory environment variables must be present before running this script:
#
# Variable                    | Purpose
# ----------------------------------------------------------------------------------------------------------------------
# PING_IDENTITY_DEVOPS_USER   | A user with license to run Ping Software
# PING_IDENTITY_DEVOPS_KEY    | The key to the above user
#
# In addition, the following environment variables, if present, will be used for the following purposes:
#
# Variable       | Purpose                                                 | Default  (if not present)
# ----------------------------------------------------------------------------------------------------------------------
# TENANT_NAME    | The name of the tenant, e.g. k8s-icecream. This         | PingPOC
#                | will be used to interpret the Kubernetes cluster        |
#                | for the different CDEs. For example, for the            |
#                | above tenant name, the Kubernetes clusters for          |
#                | the various CDEs are assumed to be                      |
#                | k8s-icecream-prod, k8s-icecream-staging,                |
#                | k8s-icecream-dev and k8s-icecream-test. For             |
#                | PCPT, the cluster name is a required parameter          |
#                | to Container Insights, an AWS-specific logging          |
#                | and monitoring solution.                                |
#                |                                                         |
# TENANT_DOMAIN  | The tenant's domain, e.g. k8s-icecream.com              | eks-poc.au1.ping-lab.cloud
#                |                                                         |
# REGION         | The region where the tenant environment is              | us-east-2
#                | deployed. For PCPT, this is a required parameter        |
#                | to Container Insights, an AWS-specific logging          |
#                | and monitoring solution.                                |
#                |                                                         |
# SIZE           | Size of the environment, which pertains to the          | small
#                | number of user identities. Legal values are             |
#                | small, medium or large.                                 |
#                |                                                         |
# IAC_REPO_URL   | The URL of the IaC repository                           | https://github.com/pingidentity/ping-cloud-base
#                |                                                         |
# TLS_CERT_ARN   | For PCPT, this specifies the ARN of the                 | An arbitrary valid certificate ARN, so the
#                | certificate generated by ACM. This ARN will be          | generated configuration is still valid.
#                | set as the value of the annotation                      |
#                | "service.beta.kubernetes.io/aws-load-balancer-ssl-cert" |
#                | on the ingress service objects so TLS is terminated at  |
#                | the load balancers.                                     |
#
########################################################################################################################

##########################################################################
# Substitute variables in all template files in the provided directory.
#
# Arguments
#   ${1} -> The directory that contains the template files.
##########################################################################

# The list of variables in the template files that will be substituted.
VARS='${PING_IDENTITY_DEVOPS_USER_BASE64}
${PING_IDENTITY_DEVOPS_KEY_BASE64}
${TENANT_DOMAIN}
${REGION}
${SIZE}
${TLS_CERT_ARN}
${CLUSTER_NAME}
${IAC_REPO_URL}
${KUSTOMIZE_BASE}'

substitute_vars() {
  SUBST_DIR=${1}
  for FILE in $(find "${SUBST_DIR}" -type f); do
    EXTENSION="${FILE##*.}"
    if test "${EXTENSION}" = 'tmpl'; then
      TARGET_FILE="${FILE%.*}"
      envsubst "${VARS}" < "${FILE}" > "${TARGET_FILE}"
      rm -f "${FILE}"
    fi
  done
}

##########################################################################
# Verify that required environment variables are set.
#
# Arguments
#   ${*} -> The list of required environment variables.
##########################################################################
check_env_vars() {
  STATUS=0
  for NAME in ${*}; do
    VALUE="${!NAME}"
    if test -z "${VALUE}"; then
      echo "${NAME} environment variable must be set"
      STATUS=1
    fi
  done
  return ${STATUS}
}

# Ensure that the DEVOPS key and user are exported as environment variables.
check_env_vars "PING_IDENTITY_DEVOPS_USER" "PING_IDENTITY_DEVOPS_KEY"
if test ${?} -ne 0; then
  exit 1
fi

# Use defaults for other variables, if not present.
export SIZE="${SIZE:-small}"
export TENANT_NAME="${TENANT_NAME:-PingPOC}"
export TENANT_DOMAIN="${TENANT_DOMAIN:-eks-poc.au1.ping-lab.cloud}"
export TLS_CERT_ARN="${TLS_CERT_ARN:-arn:aws:acm:us-east-2:123456789012:certificate/12345678-1234-1234-1234-123456789012}"
export REGION="${REGION:-us-east-2}"
export IAC_REPO_URL="${IAC_REPO_URL:-https://github.com/pingidentity/ping-cloud-base}"

# Print out the values being used for each variable.
echo "Using SIZE: ${SIZE}"
echo "Using TENANT_NAME: ${TENANT_NAME}"
echo "Using TENANT_DOMAIN: ${TENANT_DOMAIN}"
echo "Using TLS_CERT_ARN: ${TLS_CERT_ARN}"
echo "Using REGION: ${REGION}"
echo "Using IAC_REPO_URL: ${IAC_REPO_URL}"

SCRIPT_HOME=$(cd $(dirname ${0}); pwd)
TEMPLATES_HOME="${SCRIPT_HOME}/templates"

# Copy the shared cluster tools to the sandbox directory and substitute its variables first.
SANDBOX_DIR=/tmp/sandbox/k8s-configs
rm -rf "${SANDBOX_DIR}"
mkdir -p "${SANDBOX_DIR}"

cp -r "${TEMPLATES_HOME}/cluster-tools" "${SANDBOX_DIR}"
substitute_vars "${SANDBOX_DIR}"

# Next build up the directory for each environment.
ENVIRONMENTS='dev test staging prod'

PING_CLOUD_DIR="${SANDBOX_DIR}/ping-cloud"
mkdir -p "${PING_CLOUD_DIR}"

# These are exported as secrets, which are base64 encoded version of the user and key.
export PING_IDENTITY_DEVOPS_USER_BASE64=$(echo ${PING_IDENTITY_DEVOPS_USER} | base64)
export PING_IDENTITY_DEVOPS_KEY_BASE64=$(echo ${PING_IDENTITY_DEVOPS_KEY} | base64)

for ENV in ${ENVIRONMENTS}; do
  ENV_DIR="${PING_CLOUD_DIR}/${ENV}"
  cp -r "${TEMPLATES_HOME}"/ping-cloud/"${ENV}" "${ENV_DIR}"

  test "${ENV}" = 'prod' &&
    export KUSTOMIZE_BASE="${ENV}/${SIZE}" ||
    export KUSTOMIZE_BASE="${ENV}"

  # The k8s cluster name will be PingPoc-dev, PingPoc-test, etc. for the different CDEs
  export CLUSTER_NAME=${TENANT_NAME}-${ENV}

  substitute_vars "${ENV_DIR}"
done

echo "Push the k8s-configs directory under ${SANDBOX_DIR} into the IaC repo onto these branches: dev test staging master"