#!/bin/bash
 
HOME_DIR=`eval 'echo $HOME'`
AWS_CREDENTIAL_FILE=$HOME_DIR/.aws/credentials
AWS_CONFIG_FILE=$HOME_DIR/.aws/config
AWS_PROFILE=""
OC_CONFIG_FILE=$HOME_DIR/.kube/config
WEBHOOK_DIR=$HOME_DIR/amazon-eks-pod-identity-webhook

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
command -v aws >/dev/null 2>&1 || { echo >&2 "AWS CLI is required but not installed.  Aborting."; exit 1; } 

# Checking AWS Credentials
if [ ! -e $AWS_CREDENTIAL_FILE ] && [ -z `echo $AWS_ACCESS_KEY_ID` ] && [ -z `echo $AWS_SECRET_ACCESS_KEY`]; then
  echo "AWS CLI requires a credentials file in ~/.aws/credentials or set as environment variables AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY. Ensure credentials are set appropriately and try again."
  exit 1
fi

# Checking AWS configs
if [ ! -e $AWS_CONFIG_FILE ] || [ -z $AWS_CONFIG_FILE ]; then
  if [ -z $AWS_REGION ]; then
    echo "No AWS config was found and AWS region was not specified. Please configure aws cli with default region or specify --region at run time."
    exit 1
  fi
  if [ -z $AWS_OUTPUT_FORMAT ]; then
    echo "No AWS config was found nor was output format specified at run time. Defaulting to json."
    AWS_OUTPUT_FORMAT='json'
  fi
fi

# Checking OC Configs
if [ -z `echo $KUBECONFIG` ] && [ -z $OC_CONFIG_FILE ]; then
  echo "kubeconfig not found. Set kubeconfig environment variable or pass config to command line with --oc-config-file."
  exit 1
fi

#Check if bucket name was specified
if [ -z $S3_BUCKET_NAME ]; then
  echo "--s3-bucket-name is required. Aborting."
  exit 1
fi

#Create S3 Bucket
aws s3api create-bucket --bucket $S3_BUCKET --region $AWS_REGION
export S3_BUCKET=$S3_BUCKET
export HOSTNAME=s3.$AWS_REGION.amazonaws.com
export ISSUER_HOSTPATH=$HOSTNAME/$S3_BUCKET

#Get OpenShift keys
PRIV_KEY="sa-signer.key"
PUB_KEY="sa-signer.key.pub"
PKCS_KEY="sa-signer-pkcs8.pub"
oc get -n openshift-kube-apiserver cm -o json bound-sa-token-signing-certs | jq -r '.data["service-account-001.pub"]' > $PKCS_KEY

# Create OIDC documents
cat <<EOF > discovery.json
{
    "issuer": "https://$ISSUER_HOSTPATH/",
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
        "sub",
        "iss"
    ]
}
EOF

go run $WEBHOOK_DIR/hack/self-hosted/main.go -key $PKCS_KEY  | jq '.keys += [.keys[0]] | .keys[1].kid = ""' > keys.json

# Copy files to S3 Bucket
aws s3 cp --acl public-read ./discovery.json s3://$S3_BUCKET/.well-known/openid-configuration
aws s3 cp --acl public-read ./keys.json s3://$S3_BUCKET/keys.json


# Create OIDC Provider
FINGERPRINT=`echo | openssl s_client -servername s3.us-east-1.amazonaws.com -showcerts -connect s3.us-east-1.amazonaws.com:443 2>/dev/null | openssl x509 -fingerprint -noout | sed s/://g | sed 's/.*=//'`

cat <<EOF > create-open-id-connect-provider.json
{
    "Url": "https://$ISSUER_HOSTPATH",
    "ClientIDList": [
        ""
    ],
    "ThumbprintList": [
        "$FINGERPRINT"
    ]
}
EOF

aws iam create-open-id-connect-provider --cli-input-json file://$HOME_DIR/create-open-id-connect-provider.json
