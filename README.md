openshift-aws-iam-webhook-integration
===================================

Integration with AWS IAM Roles for accessing resources using the AWS Security Token Service (STS) in OpenShift using [bound service accounts](https://docs.openshift.com/container-platform/4.4/authentication/bound-service-account-tokens.html)

## Overview

The contents within the repository prepare an Amazon Web Services (AWS) and OpenShift Container Platform (OCP) environment to participate in [Fine grained IAM Roles for Service Accounts](https://aws.amazon.com/blogs/opensource/introducing-fine-grained-iam-roles-service-accounts/). This enables access to AWS services through the use of a service account bound to an AWS IAM role instead of using hard coded keys.

This integration is enabled to the use of a [MutatingWebhookConfiguration](https://kubernetes.io/docs/reference/access-authn-authz/extensible-admission-controllers/) and [aws-pod-identity-webhook](https://github.com/openshift/aws-pod-identity-webhook) project that is built into OpenShit. 

As part of the deployment of the webhook, any `ServiceAccount` in any project that is annotated with a a specific key (`eks.amazonaws.com` for this specific implementation) containing an IAM role will have a STS token automatically injected into all pods that make use of the Service Account. 

### Demonstration of Functionality

To demonstrate this type of integration, an simple application that contains the `awscli` tool will be deployed to showcase how it can access the contents of a specific AWS bucket with read and write access. These assets will be deployed in a separate project called `sample-iam-webhook-app`. A service account will be annotated with the name of the role that has a fine grained set of permissions to access this bucket.

## Components

### AWS

To enable integration between OpenShift and AWS, an OIDC Identity Provider is used in order to enable service accounts to assume IAM roles. A portion of the configuration to the OIDC Identity Provider is stored in separate publicly accessible S3 bucket. 

Any IAM role that is used by applications in OpenShift using this functionality need to include a 

In total, the following AWS resources are created to not only support the baseline functionality to enable supporting assuming IAM Roles for applications, but also the demonstration application itself:

* 2 S3 Buckets
    * Assets to support the OIDC Identity Provider
    * Demonstration of accessing an S3 bucket by an application within OpenShift
* 1 OIDC Identity Provider
* 1 Policy to grant access to the aforementioned application S3 bucket
* 1 IAM Role
    * Association to the proceeding Policy
    * Trust Policy referencing the OIDC identity provider

By default, the Trust Policy that is configured allows access to bind to the IAM role from any Service Account that is created within OpenShift as shown below:

```
{
 "Version": "2012-10-17",
 "Statement": [
  {
   "Effect": "Allow",
   "Principal": {
    "Federated": "<OIDC_PROVIDER_ARN>"
   },
   "Action": "sts:AssumeRoleWithWebIdentity"
   "Condition": {
     "StringLike": {
       "<OIDC_ENDPOINT>:sub": "system:serviceaccount:*:*"
    }
   }
  }
 ]
}
```

Additional configurations can be applied to the trust policy to restrict to either a specific namespace or namespaces along with a Service Account within a a namespace. 

### OpenShift

The primary integration between OpenShift and AWS is through a flag set in the in the [kube-apiserver](https://kubernetes.io/docs/reference/command-line-tools-reference/kube-apiserver/) with a reference to the OIDC Identity Provider endpoint created previously. Within OpenShift, this is configured on the `Authentication` resource field `serviceAccountIssuer` as shown below:

```
apiVersion: config.openshift.io/v1
kind: Authentication
metadata:
  annotations:
    release.openshift.io/create-only: "true"
  name: cluster
spec:
  serviceAccountIssuer: https://s3.us-east-1.amazonaws.com/my-oidc-bucket
status:
  integratedOAuthMetadata:
    name: oauth-openshift
```

Finally, an application to demonstrate this functionality is deployed in a project called `sample-iam-webhook-app`. A service account is annotated with the ARN of the IAM role that has been configured with the appropriate access policies as shown below:

```
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    sts.amazonaws.com/role-arn: "<ROLE_ARN>"
  name: s3-manager
  namespace: sample-iam-webhook-app
```

With all of those components in place, an application can that is able to consume an AWS token is deployed using the previously created service account.

## Running the Project

### Prerequisites

The following are a set of prerequisites prior to deploying the sample project

1. Access to AWS to manage IAM permissions and S3 buckets
2. AWS CLI installed and configured
3. OpenShift Command Line Tool installed
4. `cluster-admin` privileged on the OpenShift Environment
3. JQ

A script called [iam-webhook-s3-example.sh](iam-webhook-s3-example.sh) is used to deploy the solution. The following arguments are required:

1. `--s3-bucket-name` - Name of the S3 bucket to be created and accessed by the application
2. `--oidc-s3-bucket-name` - Name of the OIDC S3 bucket to be created to store OIDC configuration
3. `--aws-region` - Name of the AWS region to target

### Script Execution

Execute the script

```
$ ./iam-webhook-s3-example.sh --s3-bucket-name <bucket_name> --oidc-s3-bucket-name <oidc_bucket_name> --aws-region <aws_region>
```

### Verification

Once complete, the two projects will have been created along with the various assets that contain the webhook pod in the `pod-identity-webhook` project and the `sample-iam-webhook-app` containing the sample application.

Change in to the `sample-iam-webhook-app` project:

```
$ oc project sample-iam-webhook-app
```

Verify a pod is running and confirm that the AWS token has been mounted into the pod:

```
$ oc get pod -l app.kubernetes.io/component=app -o yaml
```

Of importance is the Service Account Token that is automatically injected into the pod by the webhook:

```
volumes:
- name: aws-iam-token
  projected:
    defaultMode: 420
    sources:
    - serviceAccountToken:
        audience: sts.amazonaws.com
        expirationSeconds: 86400
        path: token
  ```

  Along with the associated `volumeMount`

  ```
- mountPath: /var/run/secrets/eks.amazonaws.com/serviceaccount
  name: aws-iam-token
  readOnly: true
  ```

The following environment variable are also injected:

```
env:
  - name: AWS_ROLE_ARN
    value: <arn>
  - name: AWS_WEB_IDENTITY_TOKEN_FILE
    value: /var/run/secrets/eks.amazonaws.com/serviceaccount/token
```

The AWS CLI that is part of this sample application leverages the `AWS_WEB_IDENTITY_TOKEN_FILE` environment variable during execution for requests requiring authentication.

Confirm the ability to validate the integration of the solution by removing into the running pod:

```
$ oc rsh $(oc get pod -l app.kubernetes.io/component=app -o jsonpath='{ .items[*].metadata.name }')
```

Verify the ability to list S3 buckets:

```
$ aws s3 ls
```

Verify that a file can be written to the bucket.

echo "Testing" > /tmp/test.txt

Upload the file to the bucket

```
$ aws s3 cp /tmp/test.txt s3://<bucketname>/test.txt
```

## Troubleshooting

There may be circumstances for which the integration will not succeed as expected. The following are common solutions to resolve these issues:

### Various exceptions when executing AWS CLI commands in the pod

There is the potential for a race condition to occur when the appropriate Service Account token is not injected into the application pod properly. This will resolve the pod mutation from not occurring or the proper token from being injected. To resolve this issue, perform the following tasks.

1. Delete the webhook

```
$ oc delete pod -n pod-identity-webhook  -l=app.kubernetes.io/component=webhook --all
```

2. Delete the application pod

```
$ oc delete pod -n sample-iam-webhook-app  -l=app.kubernetes.io/component=app --all
```

3. Retry the desired action

### OpenShift 4.4, 4.5, 4.6

Initial support for AWS Security Token Service (STS) was added in OpenShift 4.4. Full integration was added in OpenShift 4.7 and can be used on this branch. For OpenShift version 4.4, 4.5 and 4.6, please use the [v4.4](https://github.com/sabre1041/openshift-aws-iam-webhook-integration/tree/v4.4) tag which contains the assets to deploy the Pod Identity Webhook to support the capabilities for these versions. 

