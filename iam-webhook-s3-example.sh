#!/bin/bash
#set -x

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

AWS_CREDENTIAL_FILE=$HOME_DIR/.aws/credentials
AWS_CONFIG_FILE=$HOME_DIR/.aws/config
#AWS_PROFILE=""
AWS_REGION=us-east-1
OC_CONFIG_FILE=$HOME_DIR/.kube/config
WEBHOOK_DIR=$HOME_DIR/amazon-eks-pod-identity-webhook
ASSETS_DIR=${DIR}/runtime-assets
CLIENT_ID=sts.amazonaws.com
BIN_DIR=${DIR}/bin
POD_IDENTITY_WEBHOOK_NAMESPACE="pod-identity-webhook"
OS=$(echo $(uname) | awk '{print tolower($0)}')

while [[ $# -gt 0 ]]; do
  ARG="$1"
  case $ARG in
    --aws-credentials-file)
      AWS_CREDENTIAL_FILE="$2"
      shift
      shift
      ;;
    --aws-config-file)
      AWS_CONFIG_FILE="$2"
      shift
      shift
      ;;
    --aws-profile)
      AWS_PROFILE="$2"
      shift
      shift
      ;;
    --aws-region)
      AWS_REGION="$2"
      shift
      shift
      ;;
    --aws-output-format)
      AWS_OUTPUT_FORMAT="$2"
      shift
      shift
      ;;
    --oc-config-file)
      OC_CONFIG_FILE="$2"
      shift
      shift
      ;;
    --s3-bucket-name)
      S3_BUCKET_NAME="$2"
      shift
      shift
      ;;
    --oidc-s3-bucket-name)
      OIDC_S3_BUCKET_NAME="$2"
      shift
      shift
      ;;
    *)
      POSITIONAL+=("$1")
      shift
      ;;
  esac
done
set -- "${POSITIONAL[@]}"

# Check if AWS cli tool is installed
command -v aws >/dev/null 2>&1 || { echo >&2 "AWS CLI is required but not installed.  Aborting."; exit 1; } 

# Check if oc cli tool is installed
command -v oc >/dev/null 2>&1 || { echo >&2 "OpenShift CLI is required but not installed.  Aborting."; exit 1; }

# Check if jq tool is installed
command -v jq >/dev/null 2>&1 || { echo >&2 "jq is required but not installed.  Aborting."; exit 1; } 


# Checking AWS Credentials
#if [ ! -e $AWS_CREDENTIAL_FILE ] && [ -z `echo $AWS_ACCESS_KEY_ID` ] && [ -z `echo $AWS_SECRET_ACCESS_KEY`]; then
#  echo "AWS CLI requires a credentials file in ~/.aws/credentials or set as environment variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. Ensure credentials are set appropriately and try again."
#  exit 1
#fi

# Checking AWS configs
#if [ ! -e $AWS_CONFIG_FILE ] || [ -z $AWS_CONFIG_FILE ]; then
#  if [ -z $AWS_REGION ]; then
#    echo "No AWS config was found and AWS region was not specified. Please configure aws cli with default region or specify --region at run time."
#    exit 1
#  fi
#  if [ -z $AWS_OUTPUT_FORMAT ]; then
#    echo "No AWS config was found nor was output format specified at run time. Defaulting to json."
#    AWS_OUTPUT_FORMAT='json'
#  fi
#fi

# Checking OC Configs
#if [ -z `echo $KUBECONFIG` ] && [ -z $OC_CONFIG_FILE ]; then
#  echo "kubeconfig not found. Set kubeconfig environment variable or pass config to command line with --oc-config-file."
#  exit 1
#fi



#Check if bucket name was specified
if [ -z $S3_BUCKET_NAME ] || [ -z $OIDC_S3_BUCKET_NAME ]; then
  echo "--s3-bucket-name and --oidc-s3-bucket-name is required. Aborting."
  exit 1
fi

LOCATIONCONSTRAINT_OPTION=""
HOSTNAME=s3-$AWS_REGION.amazonaws.com
BUCKET_POLICY_NAME=${S3_BUCKET_NAME}-policy
BUCKET_ROLE_NAME=${S3_BUCKET_NAME}-role

# US EAST 1 Modifications
if [ "${AWS_REGION}" != "us-east-1" ]; then
  LOCATIONCONSTRAINT_OPTION="LocationConstraint=${AWS_REGION}"
  HOSTNAME=s3.$AWS_REGION.amazonaws.com
fi

ISSUER_HOSTPATH=$HOSTNAME/$OIDC_S3_BUCKET_NAME

existing_oidc_s3_bucket=$(aws s3api list-buckets --query "Buckets[?Name=='${OIDC_S3_BUCKET_NAME}'].Name | [0]" --out text)
if [ $existing_oidc_s3_bucket == "None" ]; then
echo "Creating OIDC S3 Bucket: '${OIDC_S3_BUCKET_NAME}"
aws s3api create-bucket --bucket $OIDC_S3_BUCKET_NAME --create-bucket-configuration "${LOCATIONCONSTRAINT_OPTION}" > /dev/null
fi

existing_s3_bucket=$(aws s3api list-buckets --query "Buckets[?Name=='${S3_BUCKET_NAME}'].Name | [0]" --out text)
if [ $existing_s3_bucket == "None" ]; then
echo "Creating Application S3 Bucket: '${S3_BUCKET_NAME}'"
aws s3api create-bucket --bucket $S3_BUCKET_NAME --create-bucket-configuration "${LOCATIONCONSTRAINT_OPTION}" > /dev/null
fi


# Create Runtime assets directory if it does not exist
if [ ! -d "${ASSETS_DIR}" ]; then
  mkdir -p ${ASSETS_DIR}
fi

#Get OpenShift keys
PKCS_KEY="sa-signer-pkcs8.pub"
oc get -n openshift-kube-apiserver cm -o json bound-sa-token-signing-certs | jq -r '.data["service-account-001.pub"]' > "${ASSETS_DIR}/${PKCS_KEY}"

if [ $? -ne 0 ]; then
  echo "Error retrieving Kube API Signer CA"
  exit 1
fi

# Create OIDC documents
cat <<EOF > ${ASSETS_DIR}/discovery.json
{
    "issuer": "https://$ISSUER_HOSTPATH",
    "jwks_uri": "https://$ISSUER_HOSTPATH/keys.json",
    "authorization_endpoint": "urn:kubernetes:programmatic_authorization",
    "response_types_supported": [
        "id_token"
    ],
    "subject_types_supported": [
        "public"
    ],
    "id_token_signing_alg_values_supported": [
        "RS256"
    ],
    "claims_supported": [
      "aud",
      "exp",
      "sub",
      "iat",
      "iss",
      "sub"
    ]
}
EOF

if [ ! -f "${BIN_DIR}/self-hosted-${OS}" ]; then
  echo "Could not locate self hosted binary"
  exit 1
fi

"${BIN_DIR}/self-hosted-${OS}" -key "${ASSETS_DIR}/${PKCS_KEY}"  | jq '.keys += [.keys[0]] | .keys[1].kid = ""' > "${ASSETS_DIR}/keys.json"

# Copy files to S3 Bucket
echo "Uploading configurations to OIDC S3 Bucket"
aws s3 cp --acl public-read "${ASSETS_DIR}/discovery.json" s3://$OIDC_S3_BUCKET_NAME/.well-known/openid-configuration > /dev/null
aws s3 cp --acl public-read "${ASSETS_DIR}/keys.json" s3://$OIDC_S3_BUCKET_NAME/keys.json > /dev/null

# Create OIDC Provider
FINGERPRINT=`echo | openssl s_client -servername ${HOSTNAME} -showcerts -connect ${HOSTNAME}:443 2>/dev/null | openssl x509 -fingerprint -noout | sed s/://g | sed 's/.*=//'`

cat <<EOF > ${ASSETS_DIR}/create-open-id-connect-provider.json
{
    "Url": "https://$ISSUER_HOSTPATH",
    "ClientIDList": [
        "$CLIENT_ID"
    ],
    "ThumbprintList": [
        "$FINGERPRINT"
    ]
}
EOF

OIDC_IDENTITY_PROVIDER_ARN=$(aws iam list-open-id-connect-providers --query "OpenIDConnectProviderList[?ends_with(Arn, '/${OIDC_S3_BUCKET_NAME}')]".Arn --out text)

if [ "${OIDC_IDENTITY_PROVIDER_ARN}" != "" ]; then
  echo "Deleting existing open id connect identity provider"
  aws iam delete-open-id-connect-provider --open-id-connect-provider-arn=${OIDC_IDENTITY_PROVIDER_ARN}
fi

echo "Creating Identity Provider"
OIDC_IDENTITY_PROVIDER_ARN=$(aws iam create-open-id-connect-provider --cli-input-json file://${ASSETS_DIR}/create-open-id-connect-provider.json)


cat <<EOF > ${ASSETS_DIR}/trust-policy.json
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Effect": "Allow",
   "Principal": {
    "Federated": "$OIDC_IDENTITY_PROVIDER_ARN"
   },
   "Action": "sts:AssumeRoleWithWebIdentity",
   "Condition": {
     "StringLike": {
       "${ISSUER_HOSTPATH}:sub": "system:serviceaccount:*:*"
    }
   }
  }
 ]
}
EOF

cat <<EOF > ${ASSETS_DIR}/bucket-policy.json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListAllMyBuckets"
      ],
      "Resource": "arn:aws:s3:::*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket"],
      "Resource": ["arn:aws:s3:::$.4{S3_BUCKET_NAME}"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject",
        "s3:DeleteObject"
      ],
      "Resource": ["arn:aws:s3:::${S3_BUCKET_NAME}/*"]
    }
  ]
}
EOF

policy_arn=$(aws iam list-policies --query "Policies[?PolicyName=='${BUCKET_POLICY_NAME}'].{ARN:Arn}" --output text)

if [ "${policy_arn}" != "" ]; then
   # Check to see how many policies we have
  policy_versions=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[] | length(@)")

  if [ $policy_versions -gt 1 ]; then
    oldest_policy_version=$(aws iam list-policy-versions --policy-arn=${policy_arn} --query "Versions[-1].VersionId")

    echo "Deleting Oldest Policy Version: ${oldest_policy_version}"
    aws iam delete-policy-version --policy-arn=${policy_arn} --version-id=${oldest_policy_version}
  fi

  echo "Creating new Policy Version"
  aws iam create-policy-version --policy-arn ${policy_arn} --policy-document file://${ASSETS_DIR}/bucket-policy.json --set-as-default > /dev/null

else
  echo "Creating new IAM Policy: '${BUCKET_POLICY_NAME}"
  policy_arn=$(aws iam create-policy --policy-name ${BUCKET_POLICY_NAME} --policy-document file://${ASSETS_DIR}/bucket-policy.json --query Policy.Arn --output text)
fi

role_arn=$(aws iam list-roles --query "Roles[?RoleName=='${BUCKET_ROLE_NAME}'].{ARN:Arn}" --out text)

if [ "${role_arn}" == "" ]; then
  echo "Creating Assume Role Policy"
  role_arn=$(aws iam create-role --role-name ${BUCKET_ROLE_NAME} --assume-role-policy-document file://${ASSETS_DIR}/trust-policy.json --query Role.Arn --output text)
else
  echo "Updating Assume Role Policy"
  aws iam update-assume-role-policy --role-name ${BUCKET_ROLE_NAME} --policy-document file://${ASSETS_DIR}/trust-policy.json > /dev/null
fi

echo "Attaching Policy to IAM Role"
aws iam attach-role-policy --role-name ${BUCKET_ROLE_NAME} --policy-arn ${policy_arn} > /dev/null

echo "Patching OpenShift Cluster Authentication"
oc patch authentication.config.openshift.io cluster --type "json" -p="[{\"op\": \"replace\", \"path\": \"/spec/serviceAccountIssuer\", \"value\":\"https://${ISSUER_HOSTPATH}\"}]"

echo "Creating Sample Application Resources"
oc apply -f "${DIR}/manifests/sample-app/namespace.yaml"

(
cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    eks.amazonaws.com/role-arn: "${role_arn}"
  name: s3-manager
  namespace: sample-iam-webhook-app
EOF
 ) | oc apply -f-

oc apply -f "${DIR}/manifests/sample-app/deployment.yaml"


echo
echo "Setup Completed Successfully!"